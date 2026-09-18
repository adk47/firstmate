#!/usr/bin/env bash
# fm-fable-runway.sh - read-only Fable-runway monitor.
#
# Usage:
#   fm-fable-runway.sh
#   fm-fable-runway.sh --help
#
# Prints exactly one line and exits 0 for GREEN/YELLOW and 2 for RED:
#
#   fable-runway: overall=<S> fable_state=<S> pool_state=<S> fable_remaining=<n>%
#     fable_burn=<n>x fable_exhaustion=<iso|unknown>(<n>h)
#     pool_routable=<r>/<c> pool_exhausted=<n> pool_capable=<names|none>
#     pool_tracked=<names|none> pool_unprojected=<names|none>
#     pool_exhaustion=<n>h fable_reason=<token> pool_reason=<token>
#
# Two independent runways are reported, because the supervisor reads its own
# credential while the fleet draws from the account pool, and they do not fail
# together:
#
#   fable_state  the supervisor's own credential, from quota-axi's
#                `model:fable` window: percentRemaining, pace.burnMultiple, and
#                the runway's projectedExhaustedAt.
#   pool_state   the better-ccflare account pool at FM_FABLE_RUNWAY_POOL_URL
#                (GET /health and GET /api/accounts). Its routable count is the
#                primary signal, and its per-account Fable windows refine it.
#
# Both runways use the same documented thresholds:
#
#   RED     projected exhaustion under 2h, or remaining under 10 percent
#   YELLOW  projected exhaustion under 6h, or remaining under 25 percent
#   GREEN   neither
#
# The pool adds its own capacity counts, which are the captain's stated
# thresholds: RED at 1 or fewer routable accounts, YELLOW at 3 or fewer.
#
# The overall state is the worst of the two. A runway that cannot be measured is
# RED with a reason, never GREEN, because an unreadable runway is exactly the
# case a failover monitor must not hide. The optional pool is the one exception:
# a home without better-ccflare is a normal firstmate home, so an unreachable or
# unconfigured pool is UNKNOWN and leaves the overall state to the supervisor's
# own runway.
#
# The pool's routable counts decide the verdict on their own, so a pool whose
# accounts expose no Fable-scoped window at all is still judged by them: the
# missing window suppresses the projection fields, never the verdict.
#
# Fable-capable means usable, with readable windows, none of them spent, and a
# Fable-scoped window among them. An account with no Fable window may well be
# routable, but nothing about it says the fleet can draw Fable from it, so it is
# neither named in pool_capable nor counted against the no-capable-account RED.
#
# Per-account pool exhaustion is projected from each account's weekly windows:
# assuming a week runs seven days up to its resets_at, the average burn since
# the window opened is extrapolated to 100 percent, with the elapsed portion
# floored at six hours so a burst in a freshly opened week is not read as
# imminent exhaustion.
#
# An account's runway is the sooner of its Fable-scoped week and its all-models
# weekly_all week, because whichever wall it reaches first is the one that stops
# it serving Fable. Reading the Fable window alone would report a full week of
# runway for an account sitting one percent under its all-models wall, and the
# pool would go from GREEN straight to no_fable_capable_account with no warning
# in between. The five-hour session window is not projected: it refills through
# the day, so it is a pause rather than a wall.
#
# The pool projection reported is the best remaining one - the longest such
# exhaustion among Fable-capable accounts with a projection - because the pool
# keeps serving while any capable account still has room, and the time rule
# counts how many of them are projected to outlast the 2h and 6h thresholds
# rather than taking the soonest. That is the same pace model quota-axi reports
# as burnMultiple, and it deliberately under-weights a recent ramp, so the
# pool's routable counts stay the primary signal and the projection is reported
# as a refinement. An account whose windows are not readable is excluded from
# the count rather than assumed healthy.
#
# A capable account whose weeks cannot be placed - a resets_at a full week or
# more out, or one carrying a non-UTC offset, on both windows - has no
# projection, and it may have any amount of runway left. It is named in
# pool_unprojected and it suppresses the time rule rather than letting the
# accounts that happen to be projectable decide RED on their own; pool_reason
# then reads exhaustion_unprojectable. The routable counts still decide, so the
# pool is never judged only by the part of its capable set that could be
# measured.
#
# Read-only: this never writes fleet state, never mutates the pool, and never
# prints a credential or an account email. It reads quota-axi and the local
# pool's HTTP API only.
#
# Every external call is clamped, because the watcher kills a check that runs
# past FM_CHECK_TIMEOUT and a killed check prints nothing and records nothing -
# for a failover monitor, going silently dark is the worst failure. No single
# call may exceed CALL_CAP seconds, nor a quarter of what is left of
# FM_CHECK_TIMEOUT once that cap is reserved as margin, so the four calls this
# makes still fit even when an operator raises FM_CHECK_TIMEOUT. Both the cap
# and the per-call bounds are fixed constants rather than knobs: an override
# could only weaken the bound it exists to enforce. On a default home that is 5
# seconds for each quota-axi call and 4 for each pool fetch.
#
# Test seams (all optional; production reads the live sources):
#   FM_FABLE_RUNWAY_NOW                    epoch seconds to use as "now"
#   FM_FABLE_RUNWAY_QUOTA_JSON             file holding a quota-axi JSON snapshot
#   FM_FABLE_RUNWAY_POOL_URL               pool base URL (default http://127.0.0.1:8080)
#   FM_FABLE_RUNWAY_POOL_HEALTH_JSON       file holding a pool /health snapshot
#   FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON     file holding a pool /api/accounts snapshot
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

state_valid() {
  case "${1-}" in
    GREEN|YELLOW|RED|UNKNOWN) return 0 ;;
    *) return 1 ;;
  esac
}

# worst_state <a> <b>: print the more urgent of two states. UNKNOWN never wins,
# because an unmeasured optional runway must not mask a measured one.
worst_state() {
  local a=$1 b=$2 s
  for s in RED YELLOW GREEN UNKNOWN; do
    if [ "$a" = "$s" ] || [ "$b" = "$s" ]; then
      printf '%s\n' "$s"
      return 0
    fi
  done
  printf 'UNKNOWN\n'
}

now_epoch() {
  case "${FM_FABLE_RUNWAY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FABLE_RUNWAY_NOW" ;;
  esac
}

# --- supervisor runway (quota-axi) ------------------------------------------

# The Fable window is the claude provider's `model:fable` window; its projected
# exhaustion lives on the matching effectiveAvailability entry's runway. Every
# unreadable case is RED by name, so the reason token says exactly which read
# failed.
IFS= read -r -d '' FABLE_JQ <<'JQ' || true
def norm: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z");
def to_epoch: try (norm | fromdateiso8601) catch null;
[.providers[]? | select(.provider == "claude")] | first as $p |
if $p == null then
  ["RED", "-", "-", "-", "-", "no_claude_provider"]
else
  ($p.windows // [] | map(select(.id == "model:fable")) | first) as $w |
  ($p.quotaSemantics.effectiveAvailability // [] | map(select(.scope == "model:fable")) | first) as $a |
  if $w == null or (($w.percentRemaining | type) != "number") then
    ["RED", "-", "-", "-", "-", "no_readable_model_fable_window"]
  else
    $w.percentRemaining as $rem |
    ($w.pace.burnMultiple // null) as $burn |
    ($a.runway.projectedExhaustedAt // null) as $exh |
    ($a.runway.status // "unknown") as $rs |
    (if $exh == null then null else ($exh | to_epoch) end) as $exhe |
    (if $exhe == null then null else (($exhe - $now) / 3600) end) as $hrs |
    (if $rs == "exhausted_now" then "RED"
     elif ($hrs != null and $hrs < 2) then "RED"
     elif $rem < 10 then "RED"
     elif ($hrs != null and $hrs < 6) then "YELLOW"
     elif $rem < 25 then "YELLOW"
     else "GREEN" end) as $st |
    [ $st,
      ($rem | tostring),
      (if $burn == null then "-" else ($burn | tostring) end),
      (if $exh == null then "-" else $exh end),
      (if $hrs == null then "-" else ($hrs | tostring) end),
      (if $st == "RED" then
         (if $rs == "exhausted_now" then "exhausted_now"
          elif ($hrs != null and $hrs < 2) then "exhaustion_under_2h"
          else "remaining_under_10_percent" end)
       elif $st == "YELLOW" then
         (if ($hrs != null and $hrs < 6) then "exhaustion_under_6h"
          else "remaining_under_25_percent" end)
       else "has_runway" end)
    ]
  end
end | @tsv
JQ

fable_read() {
  local json=''
  if [ -n "${FM_FABLE_RUNWAY_QUOTA_JSON:-}" ]; then
    if [ -f "$FM_FABLE_RUNWAY_QUOTA_JSON" ] && [ ! -L "$FM_FABLE_RUNWAY_QUOTA_JSON" ]; then
      json=$(cat -- "$FM_FABLE_RUNWAY_QUOTA_JSON" 2>/dev/null) || json=''
    else
      printf 'RED\t-\t-\t-\t-\tquota_snapshot_unavailable\n'
      return 0
    fi
  else
    local timeout=$QUOTA_TIMEOUT
    if ! command -v quota-axi >/dev/null 2>&1; then
      printf 'RED\t-\t-\t-\t-\tquota_axi_not_installed\n'
      return 0
    fi
    if ! fm_quota_axi_compatible "$timeout" >/dev/null 2>&1; then
      printf 'RED\t-\t-\t-\t-\tquota_axi_version_unreadable_or_below_floor\n'
      return 0
    fi
    json=$(fm_run_timed "$timeout" quota-axi --provider claude --json --no-credential-refresh \
      2>/dev/null </dev/null) || json=''
    if [ -z "$json" ]; then
      printf 'RED\t-\t-\t-\t-\tquota_axi_read_failed\n'
      return 0
    fi
  fi
  if ! printf '%s' "$json" | fm_quota_json_valid; then
    printf 'RED\t-\t-\t-\t-\tquota_axi_json_not_recognized\n'
    return 0
  fi
  printf '%s' "$json" | jq -r --argjson now "$NOW" "$FABLE_JQ" 2>/dev/null \
    || printf 'RED\t-\t-\t-\t-\tquota_axi_json_not_readable\n'
}

# --- account pool (better-ccflare) ------------------------------------------

# Per-account exhaustion is projected from the Fable-scoped weekly window. A
# seven-day week ending at resets_at gives the elapsed portion of the window, and
# the average burn over that portion extrapolates the same way quota-axi's
# burnMultiple does. A window with no readable resets_at or percent contributes
# no projection rather than a guessed one, and a window that has opened but
# cannot be placed in its week is unprojectable rather than floored. A window
# reporting no burn at all is readable and maximally healthy, so it projects the
# whole seven-day week rather than dropping out of the counts the verdict is
# taken from - there is no burn rate left to measure, so where the week started
# does not matter. An untouched account is the pool's steady state, so that case
# is settled before the window is placed at all.
IFS= read -r -d '' POOL_JQ <<'JQ' || true
def norm: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z");
def to_epoch: try (norm | fromdateiso8601) catch null;
def limits($a): ($a.usageData.limits // []);
def fable_limit($a):
  limits($a)
  | map(select(.kind == "weekly_scoped"
               and (((.scope.model.display_name // "") | ascii_downcase) == "fable")))
  | first;
def weekly_all_limit($a):
  limits($a) | map(select(.kind == "weekly_all")) | first;
def usable($a): (($a.paused // false) | not) and (($a.tokenStatus // "") == "valid");
def windows_known($a):
  (limits($a) | length) > 0
  and all(limits($a)[]; ((.percent | type) == "number"));
def capable($a):
  usable($a) and windows_known($a) and (fable_limit($a) != null)
  and all(limits($a)[]; (.percent < 100));
def hours_to($lim):
  if $lim == null or (($lim.resets_at | type) != "string") then null
  else ($lim.resets_at | to_epoch) as $r |
    ($lim.percent // null) as $pct |
    if $r == null or ($pct | type) != "number" then null
    else ($r - 604800) as $start |
      (($now - $start) / 3600) as $raw |
      if $pct <= 0 then (604800 / 3600)
      elif $raw <= 0 then null
      else (if $raw < 6 then 6 else $raw end) as $elapsed |
        ((100 - $pct) * $elapsed / $pct) end
    end
  end;
def account_hours($a):
  [hours_to(fable_limit($a)), hours_to(weekly_all_limit($a))]
  | map(select(. != null))
  | if length == 0 then null else min end;
def account_name($a):
  if ($a.name | type) == "string" and $a.name != ""
  then ($a.name | gsub("[ ,\t]"; "_")) else "unnamed" end;
def named($list): [$list[] | account_name(.)] | join(",");
. as $accts |
($accts | map(select(fable_limit(.) != null))) as $trackedAccts |
($trackedAccts | length) as $tracked |
($accts | map(select(capable(.)))) as $cap |
($cap | map({acct: ., hrs: account_hours(.)})) as $capHrs |
($capHrs | map(select(.hrs != null)) | map(.hrs)) as $hrs |
($capHrs | map(select(.hrs == null)) | map(.acct)) as $unproj |
(if ($hrs | length) == 0 then null else ($hrs | max) end) as $phrs |
($hrs | map(select(. >= 2)) | length) as $past2 |
($hrs | map(select(. >= 6)) | length) as $past6 |
# A capable account whose week cannot be placed may have any amount of runway
# left, so it must not let the accounts that happen to be projectable decide the
# time rule alone. It suppresses that rule instead, and is named on the line.
(if ($hrs | length) == 0 then "unprojectable"
 elif ($unproj | length) > 0 then
   (if $past6 == 0 then "unprojectable" else "none" end)
 elif $past2 == 0 then "red"
 elif $past6 == 0 then "yellow"
 else "none" end) as $time |
named($cap) as $names |
named($trackedAccts) as $trackedNames |
named($unproj) as $unprojNames |
($health.pool.routable // null) as $routable |
($health.pool.configured // null) as $configured |
($health.pool.usage_exhausted // null) as $exhausted |
# The routable count is the primary signal, so it decides first and decides
# alone when no account exposes a Fable-scoped window. The per-account windows
# only refine a verdict the counts already reached.
(if ($routable | type) != "number" then
   {state: "UNKNOWN", reason: "health_did_not_report_routable"}
 elif $routable <= 1 then
   {state: "RED", reason: "routable_at_or_below_1"}
 elif $tracked == 0 then
   (if $routable <= 3 then
      {state: "YELLOW", reason: "routable_at_or_below_3"}
    else
      {state: "GREEN", reason: "routable_only_without_fable_window"}
    end)
 elif ($cap | length) == 0 then
   {state: "RED", reason: "no_fable_capable_account"}
 elif $time == "red" then
   {state: "RED", reason: "exhaustion_under_2h"}
 elif $routable <= 3 then
   {state: "YELLOW", reason: "routable_at_or_below_3"}
 elif $time == "yellow" then
   {state: "YELLOW", reason: "exhaustion_under_6h"}
 elif $time == "unprojectable" then
   {state: "GREEN", reason: "exhaustion_unprojectable"}
 else
   {state: "GREEN", reason: "has_fable_capacity"}
 end) as $verdict |
[ $verdict.state,
  (if ($routable | type) == "number" then ($routable | tostring) else "-" end),
  (if ($configured | type) == "number" then ($configured | tostring) else "-" end),
  (if ($exhausted | type) == "number" then ($exhausted | tostring) else "-" end),
  (if $names == "" then "none" else $names end),
  (if $trackedNames == "" then "none" else $trackedNames end),
  (if $unprojNames == "" then "none" else $unprojNames end),
  (if $phrs == null then "-" else ($phrs | tostring) end),
  $verdict.reason
] | @tsv
JQ

pool_fetch() {
  local url=$1 out=''
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  out=$(curl --silent --show-error --max-time "${POOL_TIMEOUT}" "$url" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Any configured fixture path keeps the whole read off the network, so a test
# never reaches a live gateway and an unreadable fixture is reported rather than
# silently replaced by a live fetch.
pool_read() {
  local health='' accounts='' fixture=0
  if [ -n "${FM_FABLE_RUNWAY_POOL_HEALTH_JSON:-}" ]; then
    fixture=1
    if [ -f "$FM_FABLE_RUNWAY_POOL_HEALTH_JSON" ] && [ ! -L "$FM_FABLE_RUNWAY_POOL_HEALTH_JSON" ]; then
      health=$(cat -- "$FM_FABLE_RUNWAY_POOL_HEALTH_JSON" 2>/dev/null) || health=''
    fi
  fi
  if [ -n "${FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON:-}" ]; then
    fixture=1
    if [ -f "$FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON" ] && [ ! -L "$FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON" ]; then
      accounts=$(cat -- "$FM_FABLE_RUNWAY_POOL_ACCOUNTS_JSON" 2>/dev/null) || accounts=''
    fi
  fi
  if [ "$fixture" -eq 0 ]; then
    health=$(pool_fetch "$POOL_URL/health") || health=''
    accounts=$(pool_fetch "$POOL_URL/api/accounts") || accounts=''
  fi
  if [ -z "$health" ] || [ -z "$accounts" ]; then
    printf 'UNKNOWN\t-\t-\t-\tnone\tnone\tnone\t-\tpool_unavailable\n'
    return 0
  fi
  if ! printf '%s' "$health" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || ! printf '%s' "$accounts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'UNKNOWN\t-\t-\t-\tnone\tnone\tnone\t-\tpool_response_not_recognized\n'
    return 0
  fi
  printf '%s' "$accounts" \
    | jq -r --argjson now "$NOW" --argjson health "$health" "$POOL_JQ" 2>/dev/null \
    || printf 'UNKNOWN\t-\t-\t-\tnone\tnone\tnone\t-\tpool_response_not_readable\n'
}

# --- main -------------------------------------------------------------------

case "${1-}" in
  '') ;; # default action is the report
  -h|--help|help) usage ;;
  *) usage ;;
esac

POOL_URL=${FM_FABLE_RUNWAY_POOL_URL:-http://127.0.0.1:8080}

# The watcher runs this check as a direct child, so FM_CHECK_TIMEOUT is read
# here too and an operator who raised it is seen on both sides. One cap's worth
# of that bound is reserved as margin, and what remains is split four ways, one
# share per external call this makes.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
CALL_CAP=5
CALL_MAX=$(( (CHECK_TIMEOUT - CALL_CAP) / 4 ))
[ "$CALL_MAX" -le "$CALL_CAP" ] || CALL_MAX=$CALL_CAP
[ "$CALL_MAX" -ge 1 ] || CALL_MAX=1

QUOTA_TIMEOUT=$CALL_CAP
[ "$QUOTA_TIMEOUT" -le "$CALL_MAX" ] || QUOTA_TIMEOUT=$CALL_MAX
POOL_TIMEOUT=4
[ "$POOL_TIMEOUT" -le "$CALL_MAX" ] || POOL_TIMEOUT=$CALL_MAX
NOW=$(now_epoch)
case "$NOW" in
  ''|*[!0-9]*) NOW=$(date +%s) ;;
esac

IFS=$'\t' read -r FABLE_STATE FABLE_REM FABLE_BURN FABLE_EXH FABLE_HRS FABLE_REASON <<EOF
$(fable_read)
EOF

IFS=$'\t' read -r POOL_STATE POOL_ROUTABLE POOL_CONFIGURED POOL_EXHAUSTED POOL_CAPABLE POOL_TRACKED POOL_UNPROJ POOL_HRS POOL_REASON <<EOF
$(pool_read)
EOF

state_valid "$FABLE_STATE" || FABLE_STATE=RED
state_valid "$POOL_STATE" || POOL_STATE=UNKNOWN
OVERALL=$(worst_state "$FABLE_STATE" "$POOL_STATE")

fmt_hours() {
  case "${1-}" in
    ''|'-'|unknown) printf 'unknown\n' ;;
    *) printf '%.1fh\n' "$1" 2>/dev/null || printf 'unknown\n' ;;
  esac
}

EXH_PHRASE=${FABLE_EXH:--}
[ "$EXH_PHRASE" = "-" ] && EXH_PHRASE=unknown
[ "$FABLE_REM" = "-" ] && FABLE_REM=unknown
[ "$FABLE_BURN" = "-" ] && FABLE_BURN=unknown
[ "$POOL_ROUTABLE" = "-" ] && POOL_ROUTABLE=unknown
[ "$POOL_CONFIGURED" = "-" ] && POOL_CONFIGURED=unknown
[ "$POOL_EXHAUSTED" = "-" ] && POOL_EXHAUSTED=unknown

printf 'fable-runway: overall=%s fable_state=%s pool_state=%s fable_remaining=%s%% fable_burn=%sx fable_exhaustion=%s(%s) pool_routable=%s/%s pool_exhausted=%s pool_capable=%s pool_tracked=%s pool_unprojected=%s pool_exhaustion=%s fable_reason=%s pool_reason=%s\n' \
  "$OVERALL" "$FABLE_STATE" "$POOL_STATE" "$FABLE_REM" "$FABLE_BURN" \
  "$EXH_PHRASE" "$(fmt_hours "${FABLE_HRS:-}")" \
  "$POOL_ROUTABLE" "$POOL_CONFIGURED" "$POOL_EXHAUSTED" "$POOL_CAPABLE" \
  "${POOL_TRACKED:-none}" "${POOL_UNPROJ:-none}" \
  "$(fmt_hours "${POOL_HRS:-}")" \
  "${FABLE_REASON:-unknown}" "${POOL_REASON:-unknown}"

[ "$OVERALL" != RED ] || exit 2
exit 0

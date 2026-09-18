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
#     pool_routable=<r>/<c> pool_exhausted=<n>
#     pool_capable=<names|none|unobserved>
#     pool_tracked=<names|none|unobserved>
#     pool_unprojected=<names|none|unobserved>
#     pool_needs_auth=<names|none> pool_exhaustion=<n>h
#     fable_reason=<token> pool_reason=<token>
#
# Two independent runways are reported, because the supervisor reads its own
# credential while the fleet draws from the account pool, and they do not fail
# together:
#
#   fable_state  the supervisor's own credential, from quota-axi's
#                `model:fable` window: percentRemaining, pace.burnMultiple, and
#                the runway's projectedExhaustedAt.
#   pool_state   the account pool the fleet actually draws from. Two proxies
#                serve the same Claude logins and they do not agree, so both
#                are read: CLIProxyAPI's local auth inventory
#                (FM_FABLE_RUNWAY_AUTH_DIR, default ~/.cli-proxy-api) is the
#                authority for how many accounts hold a live grant, because it
#                is the proxy ANTHROPIC_BASE_URL points at; better-ccflare at
#                FM_FABLE_RUNWAY_POOL_URL (GET /health and GET /api/accounts)
#                supplies the per-account Fable windows that refine it.
#
# Reading better-ccflare alone would be wrong, and not in a subtle way: the two
# proxies share the same OAuth logins, so whichever refreshes a token last
# leaves the other holding a dead refresh_token. On a home where CLIProxyAPI
# refreshed them, better-ccflare reports every account tokenStatus=expired and
# routable=0 while the fleet is being served normally. So the auth inventory
# decides the counts whenever it can be read, and better-ccflare is a
# supplementary source rather than the authority. With no inventory present -
# a home that does not run CLIProxyAPI - better-ccflare decides alone, exactly
# as before.
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
# a home running neither proxy is a normal firstmate home, so a pool is UNKNOWN
# and leaves the overall state to the supervisor's own runway. It takes both
# sources failing to get there - an unreadable better-ccflare while the auth
# inventory still answers is a pool that can be counted but not projected, not
# a pool that cannot be read.
#
# The pool's routable counts decide the verdict on their own, so a pool whose
# accounts expose no Fable-scoped window at all is still judged by them: the
# missing window suppresses the projection fields, never the verdict.
#
# Suppressed is not empty, and the three membership fields say which they are.
# With no account exposing a Fable window there is nothing to have observed, so
# pool_capable, pool_tracked and pool_unprojected read `unobserved` rather than
# `none` - and so does an unreadable pool. That distinction is load-bearing
# rather than cosmetic: `none` is what opens a failover episode, and an
# unreadable better-ccflare beside a readable inventory produces exactly this
# shape on a pool whose every grant is live.
#
# Fable-capable means usable, with readable windows, none of them spent, and a
# Fable-scoped window among them. Usable means a live grant on the proxy the
# fleet actually routes through - the ANTHROPIC_BASE_URL the environment or the
# local Claude settings name - because a grant on the other proxy is real but
# unreachable. When that URL is the better-ccflare pool, or there is no
# inventory at all, better-ccflare's own records decide; otherwise the inventory
# does, and an account whose inventory grant died is spent as far as the fleet
# is concerned however healthy better-ccflare still believes it to be. An account with no Fable window may well be
# routable, but nothing about it says the fleet can draw Fable from it, so it is
# neither named in pool_capable nor counted against the no-capable-account RED.
#
# Needing a login is a cross-proxy fact: an account is named in pool_needs_auth
# when NO proxy holds a live grant for it - neither a current, enabled entry in
# the auth inventory nor a better-ccflare record without an authentication
# complaint (requiresReauth, a tokenStatus outside the usable ones, or a
# pauseReason naming authentication). An account one proxy can still serve is
# not a login the captain has to go and perform. A named account is not usable,
# so it is neither Fable-capable nor part of the projection. It is a different
# failure from a spent window and it has a different remedy, so it is reported
# on its own rather than folded into the counts; the check turns an account
# newly entering that state into a wake and a desktop notification, because
# re-authenticating is something the captain can do long before the runway
# matters.
#
# Per-account pool exhaustion is projected from each account's weekly windows:
# assuming a week runs seven days up to its resets_at, the average burn since
# the window opened is extrapolated to 100 percent, with the elapsed portion
# floored at six hours so a burst in a freshly opened week is not read as
# imminent exhaustion.
#
# A window's own resets_at is the ceiling on that projection. A week projected
# to run out at or after the moment it resets does not run out at all: it is
# refilled first, so its runway is the time left to that reset and it counts
# past both thresholds the way a zero-burn window does. Without that ceiling an
# account sitting at 99 percent projects exhaustion in 1.7h however close its
# reset is, so a pool with aligned weeks goes RED in the last hours before every
# one of them refills. The reported pool_exhaustion is bounded the same way, so
# it never claims more runway than the week it was measured over has left.
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
# prints a credential or an account email. It reads quota-axi, the local pool's
# HTTP API, and the auth inventory. Only two fields of each auth file are ever
# read - `disabled` and `expired` - and the account is labelled from its own
# file name, so neither the tokens nor the email address in that file is
# carried into the line or into any child process. Each file is parsed on its
# own, so one torn file - a proxy caught mid-rewrite, a hand-edit - costs that
# one account rather than the whole inventory, and the inventory counts as
# unreadable only when no file parses at all.
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
#   FM_FABLE_RUNWAY_AUTH_DIR               CLIProxyAPI auth directory holding
#                                          claude-<label>.json (default
#                                          ~/.cli-proxy-api); a path that does
#                                          not exist means no inventory
#   FM_FABLE_RUNWAY_SETTINGS_JSON          Claude settings file read for
#                                          .env.ANTHROPIC_BASE_URL when the
#                                          environment does not set it
#                                          (default ~/.claude/settings.json)
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
# reporting no burn at all is readable and maximally healthy, so its runway is
# simply the time left to its own reset - the same ceiling every other window
# gets - rather than dropping out of the counts the verdict is taken from.
# There is no burn rate left to measure, so where the week started does not
# matter and that case is settled before the window is placed at all. An
# untouched account is the pool's steady state.
IFS= read -r -d '' POOL_JQ <<'JQ' || true
. as $accts |
($auth // []) as $inv |
($auth != null) as $haveInv |
($haveInv and ($routes_ccflare | not)) as $useInv |
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
def lower($v): (if ($v | type) == "string" then ($v | ascii_downcase) else "" end);
def account_name($a):
  if ($a.name | type) == "string" and $a.name != ""
  then ($a.name | gsub("[ ,\t]"; "_")) else "unnamed" end;
# A better-ccflare record holds a grant unless it complains about authentication.
# Being paused is not such a complaint - a rate-limited account still has a
# credential - so the grant test and the routable test are separate.
def cc_grant($a):
  (($a.requiresReauth // false) != true)
  and (lower($a.tokenStatus) | (. == "" or . == "valid"))
  and ((lower($a.pauseReason) | test("auth|login|credential")) | not);
def cc_live($a):
  (($a.paused // false) | not) and (lower($a.tokenStatus) == "valid") and cc_grant($a);
def inv_live($n): any($inv[]; .label == $n and .live);
def cc_grant_name($n): any($accts[]; account_name(.) == $n and cc_grant(.));
def needs_auth_name($n): (inv_live($n) | not) and (cc_grant_name($n) | not);
# Usable means a live grant on the proxy the fleet actually routes through. A
# grant on the other proxy is real but unreachable, so it is not capacity: with
# ANTHROPIC_BASE_URL pointing at CLIProxyAPI, an account whose inventory grant
# died is spent as far as the fleet is concerned however healthy better-ccflare
# still believes it to be. The other proxy's grant still counts for
# needs_auth_name, because a login one proxy can still perform is not one the
# captain has to.
def usable($a):
  if $useInv then inv_live(account_name($a)) else cc_live($a) end;
def windows_known($a):
  (limits($a) | length) > 0
  and all(limits($a)[]; ((.percent | type) == "number"));
def capable($a):
  usable($a) and windows_known($a) and (fable_limit($a) != null)
  and all(limits($a)[]; (.percent < 100));
# A window's runway as {h, wall}: h is the hours it has left, and wall says
# whether that runway ends in exhaustion or in the window's own reset. A week
# that refills before its burn can spend it is not a wall at any distance.
def window_runway($lim):
  if $lim == null or (($lim.resets_at | type) != "string") then null
  else ($lim.resets_at | to_epoch) as $r |
    ($lim.percent // null) as $pct |
    if $r == null or ($pct | type) != "number" then null
    else (if $r <= $now then 0 else (($r - $now) / 3600) end) as $ttr |
      ($r - 604800) as $start |
      (($now - $start) / 3600) as $raw |
      if $pct <= 0 then {h: $ttr, wall: false}
      elif $raw <= 0 then null
      else (if $raw < 6 then 6 else $raw end) as $elapsed |
        ((100 - $pct) * $elapsed / $pct) as $proj |
        if $proj >= $ttr then {h: $ttr, wall: false}
        else {h: $proj, wall: true} end
      end
    end
  end;
# The account's runway is the sooner wall among its weeks; with no wall at all
# it is the sooner reset, which is a refill rather than a limit.
def account_runway($a):
  ([window_runway(fable_limit($a)), window_runway(weekly_all_limit($a))]
   | map(select(. != null))) as $w |
  if ($w | length) == 0 then null
  else ($w | map(select(.wall))) as $walls |
    if ($walls | length) > 0 then {h: ($walls | map(.h) | min), wall: true}
    else {h: ($w | map(.h) | min), wall: false} end
  end;
def named($list): [$list[] | account_name(.)] | join(",");
($accts | map(select(fable_limit(.) != null))) as $trackedAccts |
($trackedAccts | length) as $tracked |
($accts | map(select(capable(.)))) as $cap |
((($inv | map(.label)) + ($accts | map(account_name(.)))) | unique) as $allNames |
($allNames | map(select(needs_auth_name(.)))) as $authNamesList |
($cap | map({acct: ., rw: account_runway(.)})) as $capRw |
($capRw | map(select(.rw != null)) | map(.rw)) as $hrs |
($capRw | map(select(.rw == null)) | map(.acct)) as $unproj |
(if ($hrs | length) == 0 then null else ($hrs | map(.h) | max) end) as $phrs |
($hrs | map(select((.wall | not) or .h >= 2)) | length) as $past2 |
($hrs | map(select((.wall | not) or .h >= 6)) | length) as $past6 |
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
($authNamesList | join(",")) as $authNames |
# The auth inventory is the authority on capacity whenever it can be read: it
# is the proxy the fleet's base URL points at, and better-ccflare's own counts
# go stale the moment the other proxy refreshes a shared login.
(if $useInv then ($inv | map(select(.live)) | length)
 else ($health.pool.routable // null) end) as $routable |
(if $useInv then ($inv | length)
 else ($health.pool.configured // null) end) as $configured |
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
# No account exposing a Fable-scoped window is not an observation that the pool
# has no capacity - it is the absence of one, and it is also what an unread
# better-ccflare looks like beside a readable inventory. Reporting `none` there
# would be a claim the pool is empty, which is what opens a failover episode, so
# the three membership fields say `unobserved` instead and nothing downstream
# can read them as a count of zero.
($tracked == 0) as $suppressed |
[ $verdict.state,
  (if ($routable | type) == "number" then ($routable | tostring) else "-" end),
  (if ($configured | type) == "number" then ($configured | tostring) else "-" end),
  (if ($exhausted | type) == "number" then ($exhausted | tostring) else "-" end),
  (if $suppressed then "unobserved" elif $names == "" then "none" else $names end),
  (if $suppressed then "unobserved" elif $trackedNames == "" then "none" else $trackedNames end),
  (if $suppressed then "unobserved" elif $unprojNames == "" then "none" else $unprojNames end),
  (if $authNames == "" then "none" else $authNames end),
  (if $phrs == null then "-" else ($phrs | tostring) end),
  $verdict.reason
] | @tsv
JQ

# The auth inventory is the local record CLIProxyAPI keeps per login. Only
# `disabled` and `expired` are read out of it, and the account is labelled from
# its own file name - claude-<label>.json - which is also the name
# better-ccflare reports, so the two sources join without either the tokens or
# the email address in that file ever being read.
#
# `expired` carries a real UTC offset, so it is parsed as one. That is
# deliberately not the resets_at rule: a gateway window stamp the monitor
# cannot place in a seven-day week is unprojectable by decision, while an auth
# stamp is an instant and an instant with an offset is still an instant.
IFS= read -r -d '' AUTH_JQ <<'JQ' || true
def iso_epoch:
  if type != "string" then null
  else (sub("\\.[0-9]+"; "")) as $s
    | (try ($s | capture("^(?<body>[0-9T:-]+)(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")) catch null) as $m
    | if $m == null then null
      else (try (($m.body + "Z") | fromdateiso8601) catch null) as $e
        | if $e == null then null
          elif $m.tz == "Z" then $e
          else ($m.tz | gsub(":"; "")) as $t
            | ((($t[1:3] | tonumber) * 3600) + (($t[3:5] | tonumber) * 60)) as $off
            | (if ($t[0:1] == "-") then ($e + $off) else ($e - $off) end)
          end
      end
  end;
(.expired | iso_epoch) as $exp
| { label: ($label | gsub("[ ,\t]"; "_")),
    live: (((.disabled // false) != true) and $exp != null and ($exp > $now)) }
JQ

# The proxy the fleet actually routes through, from ANTHROPIC_BASE_URL - the
# environment first, then the local Claude settings. A grant on the other proxy
# is real but unreachable, so this is what decides whose grants are capacity.
# With nothing configured the inventory stays the authority.
fleet_base_url() {
  local settings=${FM_FABLE_RUNWAY_SETTINGS_JSON:-$HOME/.claude/settings.json}
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    printf '%s' "$ANTHROPIC_BASE_URL"
    return 0
  fi
  [ -f "$settings" ] && [ ! -L "$settings" ] || return 0
  jq -r '.env.ANTHROPIC_BASE_URL // empty' "$settings" 2>/dev/null
}

# Print the inventory as a compact array, or fail when there is none to read. A
# directory that is absent is a home that does not run CLIProxyAPI, which is a
# normal home, not an error.
auth_read() {
  local dir=${FM_FABLE_RUNWAY_AUTH_DIR:-$HOME/.cli-proxy-api} f label entry
  local -a entries=()
  [ -n "$dir" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for f in "$dir"/claude-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    label=${f##*/}
    label=${label#claude-}
    label=${label%.json}
    entry=$(jq -c --argjson now "$NOW" --arg label "$label" "$AUTH_JQ" "$f" 2>/dev/null) \
      || continue
    [ -n "$entry" ] || continue
    entries+=("$entry")
  done
  [ "${#entries[@]}" -gt 0 ] || return 1
  printf '[%s]' "$(IFS=,; printf '%s' "${entries[*]}")"
}

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
  local health='' accounts='' fixture=0 auth='' ccflare=1
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
  auth=$(auth_read) || auth=''
  # Only both sources failing is an unreadable pool. An unreadable
  # better-ccflare still leaves the inventory's capacity counts, which is the
  # verdict this monitor exists to give; the per-account windows are what is
  # lost, and they only ever refined it.
  if [ -z "$health" ] || [ -z "$accounts" ]; then
    ccflare=0
    if [ -z "$auth" ]; then
      printf 'UNKNOWN\t-\t-\t-\tunobserved\tunobserved\tunobserved\tnone\t-\tpool_unavailable\n'
      return 0
    fi
  elif ! printf '%s' "$health" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || ! printf '%s' "$accounts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    ccflare=0
    if [ -z "$auth" ]; then
      printf 'UNKNOWN\t-\t-\t-\tunobserved\tunobserved\tunobserved\tnone\t-\tpool_response_not_recognized\n'
      return 0
    fi
  fi
  if [ "$ccflare" -eq 0 ]; then
    health=null
    accounts='[]'
  fi
  [ -n "$auth" ] || auth=null
  printf '%s' "$accounts" \
    | jq -r --argjson now "$NOW" --argjson health "$health" --argjson auth "$auth" \
      --argjson routes_ccflare "$ROUTES_CCFLARE" "$POOL_JQ" 2>/dev/null \
    || printf 'UNKNOWN\t-\t-\t-\tunobserved\tunobserved\tunobserved\tnone\t-\tpool_response_not_readable\n'
}

# --- main -------------------------------------------------------------------

case "${1-}" in
  '') ;; # default action is the report
  -h|--help|help) usage ;;
  *) usage ;;
esac

POOL_URL=${FM_FABLE_RUNWAY_POOL_URL:-http://127.0.0.1:8080}
BASE_URL=$(fleet_base_url)
ROUTES_CCFLARE=false
[ "${BASE_URL%/}" != "${POOL_URL%/}" ] || ROUTES_CCFLARE=true

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

IFS=$'\t' read -r POOL_STATE POOL_ROUTABLE POOL_CONFIGURED POOL_EXHAUSTED POOL_CAPABLE POOL_TRACKED POOL_UNPROJ POOL_AUTH POOL_HRS POOL_REASON <<EOF
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

printf 'fable-runway: overall=%s fable_state=%s pool_state=%s fable_remaining=%s%% fable_burn=%sx fable_exhaustion=%s(%s) pool_routable=%s/%s pool_exhausted=%s pool_capable=%s pool_tracked=%s pool_unprojected=%s pool_needs_auth=%s pool_exhaustion=%s fable_reason=%s pool_reason=%s\n' \
  "$OVERALL" "$FABLE_STATE" "$POOL_STATE" "$FABLE_REM" "$FABLE_BURN" \
  "$EXH_PHRASE" "$(fmt_hours "${FABLE_HRS:-}")" \
  "$POOL_ROUTABLE" "$POOL_CONFIGURED" "$POOL_EXHAUSTED" "$POOL_CAPABLE" \
  "${POOL_TRACKED:-none}" "${POOL_UNPROJ:-none}" "${POOL_AUTH:-none}" \
  "$(fmt_hours "${POOL_HRS:-}")" \
  "${FABLE_REASON:-unknown}" "${POOL_REASON:-unknown}"

[ "$OVERALL" != RED ] || exit 2
exit 0

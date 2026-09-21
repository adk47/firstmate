#!/usr/bin/env bash
# fm-chair-runway.sh - read-only sensor for the three tanks the firstmate chair
# can run on: the 8317 CLIProxyAPI token pool, the 8080 better-ccflare pool, and
# SuperGrok.
#
# Usage:
#   fm-chair-runway.sh
#
# Prints exactly one machine-readable line and always exits 0. This is a
# sensor: it measures and reports, it never flips anything.
#
# Three sources, each reported as green|red|unknown with its measured figure:
#
#   pool8317   the token pool at FM_CHAIR_8317_URL. The deciding signal is a
#              LIVE PROBE: one minimal claude-fable-5-1 completion
#              (max_tokens 1, 20s timeout) through the pool's Anthropic
#              /v1/messages endpoint. HTTP 200 is green, 401/403/404 is red, and
#              a timeout or 5xx is unknown - never green, never red. A live
#              successful Fable completion is the only proof the pool can
#              actually serve Fable, which a token-freshness read cannot give.
#   ccflare    better-ccflare at FM_CHAIR_CCFLARE_URL, read from GET /health and
#              GET /api/accounts. Report needs_reauth=<n> and the account names
#              separately from capacity, because those are the accounts a human
#              must log in and the captain wants them named. green when
#              pool.routable > 0, red when it is 0, unknown when the pool
#              cannot be read at all.
#   grok       SuperGrok's remaining percent from quota-axi, green above the 10%
#              safety floor, red at or below it.
#   fablepct   the bound Claude account's remaining Fable percent AND the hours
#              until that window resets, from quota-axi --provider claude. A low
#              percent is only a pre-alarm when the refill is far away: 8% with
#              43h to reset means the tank empties first, 8% with 20 minutes to
#              reset means it is about to refill. Reported as ok|thin|dry.
#
# fable is the OR of the two Fable sources: green if EITHER 8317 or 8080 is
# green, red only when both are red, and unknown otherwise. Reading only the 8080
# pool is the exact bug this repository shipped: 8317 was serving Fable the whole
# time while the monitor declared both tanks empty.
#
# Read-only: this never writes fleet state, never mutates a pool, and never
# prints a secret. It reads local config and issues one bounded probe.
#
# Test seams (all optional; production reads the live sources):
#   FM_CHAIR_8317_URL            pool base URL (default http://127.0.0.1:8317)
#   FM_CHAIR_8317_KEY_FILE       file holding the pool API key
#   FM_CHAIR_8317_PROBE_MODEL    model probed (default claude-fable-5-1)
#   FM_CHAIR_8317_PROBE_TIMEOUT  probe timeout seconds (default 20)
#   FM_CHAIR_CCFLARE_URL         better-ccflare base URL (default http://127.0.0.1:8080)
#   FM_CHAIR_CCFLARE_FIXTURE     1 = do not contact better-ccflare; read the two files below
#   FM_CHAIR_CCFLARE_HEALTH_JSON   file holding a GET /health body
#   FM_CHAIR_CCFLARE_ACCOUNTS_JSON file holding a GET /api/accounts body
#   FM_CHAIR_GROK_JSON           file holding a quota-axi --provider grok JSON snapshot
#   FM_CHAIR_GROK_FLOOR_PCT      Grok safety floor percent (default 10)
#   FM_CHAIR_CLAUDE_JSON         file holding a quota-axi --provider claude JSON snapshot
#   FM_CHAIR_CLAUDE_FLOOR_PCT    Fable "thin" threshold percent (default 15)
#   FM_CHAIR_CLAUDE_DRY_HOURS    how distant a reset must be to count as thin (default 12)
#   FM_CHAIR_PROBE_CMD           override the probe: called as <url> <model> <timeout>,
#                                prints the HTTP status code (the key is never passed)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

[ $# -eq 0 ] || usage

POOL8317_URL=${FM_CHAIR_8317_URL:-http://127.0.0.1:8317}
POOL8317_KEY_FILE=${FM_CHAIR_8317_KEY_FILE:-${HOME:-}/.config/cliproxyapi/api_key}
POOL8317_MODEL=${FM_CHAIR_8317_PROBE_MODEL:-claude-fable-5-1}
POOL8317_TIMEOUT=${FM_CHAIR_8317_PROBE_TIMEOUT:-20}
CCFLARE_URL=${FM_CHAIR_CCFLARE_URL:-http://127.0.0.1:8080}
GROK_FLOOR_PCT=${FM_CHAIR_GROK_FLOOR_PCT:-10}
CLAUDE_FLOOR_PCT=${FM_CHAIR_CLAUDE_FLOOR_PCT:-15}
CLAUDE_DRY_HOURS=${FM_CHAIR_CLAUDE_DRY_HOURS:-12}

valid_state() {
  case "$1" in green|red|unknown) return 0 ;; *) return 1 ;; esac
}

# --- 8317 token pool --------------------------------------------------------

probe_8317() {
  local key code body
  [ -r "$POOL8317_KEY_FILE" ] || { printf 'unknown\tno_key\n'; return; }
  key=$(cat -- "$POOL8317_KEY_FILE" 2>/dev/null) || key=''
  [ -n "$key" ] || { printf 'unknown\tempty_key\n'; return; }
  if [ -n "${FM_CHAIR_PROBE_CMD:-}" ]; then
    # shellcheck disable=SC2086
    code=$("$FM_CHAIR_PROBE_CMD" "$POOL8317_URL" "$POOL8317_MODEL" "$POOL8317_TIMEOUT" 2>/dev/null) || code=000
  else
    body=$(mktemp "${TMPDIR:-/tmp}/.fm-chair-probe.XXXXXX") || { printf 'unknown\tprobe_tmp_failed\n'; return; }
    code=$(curl --silent --output "$body" --write-out '%{http_code}' --max-time "$POOL8317_TIMEOUT" \
      -X POST "$POOL8317_URL/v1/messages" \
      -H "Authorization: Bearer $key" \
      -H 'content-type: application/json' \
      -H 'anthropic-version: 2023-06-01' \
      --data-binary "{\"model\":\"$POOL8317_MODEL\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
      2>/dev/null) || code=000
    rm -f "$body" 2>/dev/null || true
  fi
  case "$code" in
    200) printf 'green\tHTTP:%s\n' "$code" ;;
    401|403|404) printf 'red\tHTTP:%s\n' "$code" ;;
    000|'') printf 'unknown\tprobe_no_response\n' ;;
    5*) printf 'unknown\tHTTP:%s\n' "$code" ;;
    *) printf 'red\tHTTP:%s\n' "$code" ;;
  esac
}

# --- 8080 better-ccflare ----------------------------------------------------

read_ccflare() {
  # echoes: <state> <routable> <configured> <needs_reauth_count> <names>
  local health accounts routable configured reauth names
  [ -n "${FM_CHAIR_CCFLARE_HEALTH_JSON:-}" ] && health=$(cat -- "$FM_CHAIR_CCFLARE_HEALTH_JSON" 2>/dev/null)
  [ -n "${FM_CHAIR_CCFLARE_ACCOUNTS_JSON:-}" ] && accounts=$(cat -- "$FM_CHAIR_CCFLARE_ACCOUNTS_JSON" 2>/dev/null)
  if [ "${FM_CHAIR_CCFLARE_FIXTURE:-0}" != 1 ]; then
    health=$(curl --silent --max-time 5 "$CCFLARE_URL/health" 2>/dev/null) || health=''
    accounts=$(curl --silent --max-time 5 "$CCFLARE_URL/api/accounts" 2>/dev/null) || accounts=''
  fi
  if [ -z "${health:-}" ]; then
    printf 'unknown\t-\t-\t-\tnone\n'; return
  fi
  if ! printf '%s' "$health" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'unknown\t-\t-\t-\tnone\n'; return
  fi
  routable=$(printf '%s' "$health" | jq -r '.pool.routable // "-"' 2>/dev/null) || routable=-
  configured=$(printf '%s' "$health" | jq -r '.pool.configured // "-"' 2>/dev/null) || configured=-
  reauth=0
  names=none
  if [ -n "${accounts:-}" ] && printf '%s' "$accounts" | jq -e 'type == "array"' >/dev/null 2>&1; then
    reauth=$(printf '%s' "$accounts" | jq -r '[.[] | select(.requiresReauth == true)] | length' 2>/dev/null) || reauth=0
    names=$(printf '%s' "$accounts" | jq -r '[.[] | select(.requiresReauth == true) | (.name // "unnamed")] | if length == 0 then "none" else join(",") end' 2>/dev/null) || names=none
  fi
  case "$routable" in
    ''|'-'|*[!0-9]*) printf 'unknown\t%s\t%s\t%s\t%s\n' "$routable" "$configured" "$reauth" "$names" ;;
    *)
      if [ "$routable" -gt 0 ]; then
        printf 'green\t%s\t%s\t%s\t%s\n' "$routable" "$configured" "$reauth" "$names"
      else
        printf 'red\t%s\t%s\t%s\t%s\n' "$routable" "$configured" "$reauth" "$names"
      fi
      ;;
  esac
}

# --- SuperGrok --------------------------------------------------------------

read_grok() {
  # echoes: <state> <pct>
  local json pct
  if [ -n "${FM_CHAIR_GROK_JSON:-}" ]; then
    json=$(cat -- "$FM_CHAIR_GROK_JSON" 2>/dev/null) || json=''
  else
    json=$(quota-axi --provider grok --json --no-credential-refresh 2>/dev/null </dev/null) || json=''
  fi
  [ -n "$json" ] || { printf 'unknown\t-\n'; return; }
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || { printf 'unknown\t-\n'; return; }
  pct=$(printf '%s' "$json" | jq -r '([.providers[]? | select(.provider=="grok")][0].quotaSemantics.effectiveAvailability // [] | map(select(.scope=="all_products")) | first).effectivePercentRemaining // empty' 2>/dev/null)
  case "$pct" in
    ''|*[!0-9.]*) printf 'unknown\t-\n' ;;
    *)
      if awk -v p="$pct" -v f="$GROK_FLOOR_PCT" 'BEGIN { exit !(p+0 > f) }'; then
        printf 'green\t%s\n' "$pct"
      else
        printf 'red\t%s\n' "$pct"
      fi
      ;;
  esac
}

# --- Fable runway (the bound Claude account) --------------------------------

read_fable_runway() {
  # echoes: <ok|thin|dry|unknown> <pct> <hours_to_reset>
  #
  # `percentRemaining` alone cannot tell a tank that is about to refill from one
  # that is about to run out - the reset deadline is what separates them. `thin`
  # is therefore a PAIR: at or below the floor AND a reset further away than the
  # dry-hours horizon, i.e. the tank empties before the refill arrives. `dry` is
  # zero percent. An unreadable reset degrades to ok for a non-zero percent
  # rather than claiming a distance that was never measured.
  local json pct reset hrs
  if [ -n "${FM_CHAIR_CLAUDE_JSON:-}" ]; then
    json=$(cat -- "$FM_CHAIR_CLAUDE_JSON" 2>/dev/null) || json=''
  else
    json=$(quota-axi --provider claude --json --no-credential-refresh 2>/dev/null </dev/null) || json=''
  fi
  [ -n "$json" ] || { printf 'unknown\t-\t-\n'; return; }
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || { printf 'unknown\t-\t-\n'; return; }
  pct=$(printf '%s' "$json" | jq -r '([.providers[]? | select(.provider=="claude")][0].windows // [] | map(select(.id=="model:fable")) | first).percentRemaining // empty' 2>/dev/null)
  reset=$(printf '%s' "$json" | jq -r '([.providers[]? | select(.provider=="claude")][0].windows // [] | map(select(.id=="model:fable")) | first).resetsAt // empty' 2>/dev/null)
  hrs=-
  case "$reset" in
    ''|null) : ;;
    *)
      hrs=$(python3 -c '
import sys, datetime
try:
    t = datetime.datetime.fromisoformat(sys.argv[1])
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    print("%.1f" % ((t - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 3600.0))
except Exception:
    print("-")
' "$reset" 2>/dev/null) || hrs=-
      ;;
  esac
  case "$pct" in
    ''|*[!0-9.]*) printf 'unknown\t-\t%s\n' "$hrs" ;;
    *)
      if awk -v p="$pct" 'BEGIN { exit !(p+0 <= 0) }'; then
        printf 'dry\t%s\t%s\n' "$pct" "$hrs"
      elif awk -v p="$pct" -v f="$CLAUDE_FLOOR_PCT" 'BEGIN { exit !(p+0 <= f) }' \
        && awk -v h="$hrs" -v d="$CLAUDE_DRY_HOURS" 'BEGIN { exit !(h+0 > d) }'; then
        printf 'thin\t%s\t%s\n' "$pct" "$hrs"
      else
        printf 'ok\t%s\t%s\n' "$pct" "$hrs"
      fi
      ;;
  esac
}

# --- combine ----------------------------------------------------------------

IFS=$'\t' read -r P8317 P8317_NOTE <<EOF
$(probe_8317)
EOF
IFS=$'\t' read -r CCF CCF_ROUTABLE CCF_CONFIGURED CCF_REAUTH CCF_NAMES <<EOF
$(read_ccflare)
EOF
IFS=$'\t' read -r GROK GROK_PCT <<EOF
$(read_grok)
EOF
IFS=$'\t' read -r FABLE_RUNWAY FABLE_PCT FABLE_RESET_H <<EOF
$(read_fable_runway)
EOF

valid_state "$P8317" || P8317=unknown
valid_state "$CCF" || CCF=unknown
valid_state "$GROK" || GROK=unknown
case "$FABLE_RUNWAY" in ok|thin|dry|unknown) ;; *) FABLE_RUNWAY=unknown ;; esac

FABLE=unknown
if [ "$P8317" = green ] || [ "$CCF" = green ]; then
  FABLE=green
elif [ "$P8317" = red ] && [ "$CCF" = red ]; then
  FABLE=red
fi

if [ "$FABLE" = green ]; then
  REASON=fable_available
elif [ "$FABLE" = red ]; then
  REASON=no_fable_source
else
  REASON=fable_unmeasured
fi

printf 'chair-runway: fable=%s pool8317=%s probe=%s ccflare=%s routable=%s/%s needs_reauth=%s names=%s grok=%s grok_pct=%s fable_runway=%s fable_pct=%s fable_reset_h=%s reason=%s\n' \
  "$FABLE" "$P8317" "$P8317_NOTE" "$CCF" "$CCF_ROUTABLE" "$CCF_CONFIGURED" \
  "$CCF_REAUTH" "$CCF_NAMES" "$GROK" "$GROK_PCT" \
  "$FABLE_RUNWAY" "$FABLE_PCT" "$FABLE_RESET_H" "$REASON"
exit 0
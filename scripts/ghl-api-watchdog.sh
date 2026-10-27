#!/bin/bash
# ──────────────────────────────────────────────────────────────
# GHL API Watchdog
#
# Daily canary through scripts/ghl.sh against the two GoHighLevel accounts the
# CMO outreach engine uses (b2b = McLaren's pipeline, winback). Pages
# #clio_devops on any non-zero verdict, one post per account per cooldown.
#
# Born from MUS-20329 (Oct 2026): Cloudflare started answering the CMO's
# hand-rolled urllib calls with HTTP 403 "error code: 1010" (client-signature
# ban), the second GHL outage in a week (19 Oct, 26 Oct), and nothing noticed
# until McLaren's batches were already blocked. ghl.sh sets the UA that avoids
# the ban; this canary notices when that, the key, or the account breaks again.
#
# Deliberately a system-cron bash watchdog, not an openclaw cron: it must fire
# when the gateway is down, and a boolean health question needs no LLM turn
# (same reasoning as scripts/mercury-token-watchdog.sh).
#
# Runs daily via /etc/cron.d/ghl-api-watchdog ON NODE-8 (installed idempotently
# by scripts/install-aux-units.sh), ahead of the CMO day.
#
# Keys: GHL_API_KEY and GHL_WINBACK_API_KEY are read from /etc/openclaw/main.env
# LAST-wins and WITHOUT sourcing the file (it holds every secret on the box, and
# shell/systemd consumers are last-wins; a `head -1` reader would probe a dead
# duplicate forever). Only those two are exported, and a key never appears in
# the log or a page.
#
# NOT maintenance-flag guarded: external vendor health, not fleet health. Listed
# in scripts/tests/fixtures/maintenance-guard-exempt.txt.
#
# Flags:
#   --dry-run   probe and log, do NOT post and do NOT touch any cooldown stamp.
#
# Env knobs (mainly for tests):
#   GHL_CLIENT           client path (default ./ghl.sh)
#   GHL_ENV_FILE         key source (default /etc/openclaw/main.env)
#   GHL_STATE_DIR        cooldown stamps ghl-api-<account>-last-alert
#                        (default /var/lib/hydra)
#   GHL_ALERT_INTERVAL   seconds between pages per account (default 20h)
#   GHL_CHANNEL          Slack channel (default C0ADV2W76G4 #clio_devops)
#   GHL_SKIP_HOST_GUARD  1 = skip the ovh-node-8 guard (tests)
#
# set -uo pipefail (NOT -e): the probes exit non-zero by design.
# ──────────────────────────────────────────────────────────────
set -uo pipefail
set +x   # never trace the keys

_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GHL_CLIENT="${GHL_CLIENT:-$_WD_DIR/ghl.sh}"
GHL_ENV_FILE="${GHL_ENV_FILE:-/etc/openclaw/main.env}"
STATE_DIR="${GHL_STATE_DIR:-/var/lib/hydra}"
# 20h, not 24h, so a daily tick is never suppressed by landing on the cadence.
ALERT_INTERVAL="${GHL_ALERT_INTERVAL:-72000}"
SKIP_HOST_GUARD="${GHL_SKIP_HOST_GUARD:-0}"

# slack-notify.sh reads this; export before sourcing so its `:=` default
# doesn't override us.
export SLACK_CHANNEL="${GHL_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

LOGPREFIX="[ghl-api-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
log() { echo "$LOGPREFIX $*"; }

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "$LOGPREFIX unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Before any probe: a dev box that merely has the repo checked out must not make
# live authenticated calls.
if [ "$SKIP_HOST_GUARD" != "1" ] && [ "$(hostname)" != "ovh-node-8" ]; then
  log "not on ovh-node-8 — refusing to run (set GHL_SKIP_HOST_GUARD=1 to override)"
  exit 0
fi

# read_env_var <VAR> — last assignment wins; CR, `export`, a trailing ` # comment`
# and one layer of quotes are stripped, as `set -a; . file` would. Prints nothing
# if the file is unreadable or the var absent/empty.
read_env_var() {
  [ -r "$GHL_ENV_FILE" ] || return 0
  tr -d '\r' < "$GHL_ENV_FILE" \
    | sed -nE "s/[[:space:]]+(#.*)?\$//; s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" \
    | tail -n 1 \
    | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

GHL_API_KEY="$(read_env_var GHL_API_KEY)"
GHL_WINBACK_API_KEY="$(read_env_var GHL_WINBACK_API_KEY)"
export GHL_API_KEY GHL_WINBACK_API_KEY

# shellcheck source=lib/slack-notify.sh
source "$_WD_DIR/lib/slack-notify.sh"

# page_once <account> <slack-text> — rate limited per account; the stamp
# advances ONLY on a confirmed delivery, so a failed post retries next tick.
page_once() {
  local account="$1" text="$2" stamp now last payload
  stamp="$STATE_DIR/ghl-api-${account}-last-alert"
  now="$(date -u +%s)"
  last="$( { tr -dc '0-9' < "$stamp"; } 2>/dev/null || echo 0)"
  [ -n "$last" ] || last=0
  # A future-dated stamp (clock stepped back) is invalid, not "recent": it must not mute alerts.
  if [ "$last" -le "$now" ] && [ $((now - last)) -lt "$ALERT_INTERVAL" ]; then
    log "page suppressed for ${account} (last delivered $((now - last))s ago, interval ${ALERT_INTERVAL}s)"
    return 0
  fi
  payload="$(mktemp)"
  jq -n --arg c "$SLACK_CHANNEL" --arg t "$text" '{channel:$c, text:$t}' > "$payload"
  # No RETURN trap: it would outlive this function and fire (with $payload
  # unset, fatal under -u) on the next function return in this shell.
  if slack_notify_payload_file_status "$payload"; then
    rm -f "$payload"
    log "paged ${SLACK_CHANNEL} for ${account}"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
  else
    rm -f "$payload"
    log "WARNING: Slack post FAILED for ${account} — cooldown NOT advanced, will retry next tick"
  fi
}

# probe <account> <VAR> <ghl.sh args...>
# Sets VERDICT_<account> ("ok" or "exit N"). Pages on any non-zero.
# (No associative arrays: macOS /bin/bash 3.2 runs the bats suite.)
probe() {
  local account="$1" var="$2" key out rc line
  shift 2
  key="${!var}"
  if [ -z "$key" ]; then
    rc=3
    out="ghl: ${var} is missing or empty in ${GHL_ENV_FILE}: add it there (DevOps), then re-run /opt/hydra/scripts/ghl-api-watchdog.sh --dry-run"
  elif [ ! -x "$GHL_CLIENT" ]; then
    rc=2
    out="ghl: client missing or not executable: ${GHL_CLIENT}"
  else
    out="$("$GHL_CLIENT" "$@" 2>&1 >/dev/null)"; rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf -v "VERDICT_${account}" %s ok
    [ "$DRY_RUN" -eq 1 ] || rm -f "$STATE_DIR/ghl-api-${account}-last-alert" 2>/dev/null || true
    return 0
  fi
  printf -v "VERDICT_${account}" %s "exit ${rc}"
  # Last stderr line only, one line, key redacted (ghl.sh never prints it; belt and braces).
  line="$(printf '%s' "$out" | tail -n 1 | tr '\r\n' '  ')"
  [ -z "$key" ] || line="${line//"$key"/[redacted]}"
  [ -n "$line" ] || line="ghl.sh exited ${rc} with no message"
  log "VIOLATION: ${account} (${var}) exit ${rc}: ${line}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would page ${SLACK_CHANNEL} for ${account} (cooldown untouched)"
    return 0
  fi
  page_once "$account" "GHL canary: ${account} (${var}) → ${line}"
}

VERDICT_b2b="unprobed"; VERDICT_winback="unprobed"
probe b2b GHL_API_KEY GET /opportunities/search \
  location_id=S5w31kRRgsBjjiVATWlP pipeline_id=GeSt85TueSvJ0SNFZXfQ limit=1
probe winback GHL_WINBACK_API_KEY --account winback GET /opportunities/search \
  location_id=fmK5Vl9sJv49WTYA0QyP limit=1

if [ "${VERDICT_b2b}" = ok ] && [ "${VERDICT_winback}" = ok ]; then
  log "clean: b2b ok, winback ok"
else
  log "degraded: b2b ${VERDICT_b2b}, winback ${VERDICT_winback}"
fi
exit 0

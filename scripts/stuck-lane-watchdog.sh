#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Stuck-Lane Watchdog  (Caroline / edge support)
#
# Alerts #clio_devops when the EDGE gateway's stuck-session recovery
# force-aborts a wedged agent run WITHOUT freeing the lane — the moment a
# customer's generated reply is silently discarded.
#
# Root cause (upstream, no released fix): openclaw #97538 / #92270. Rapid-fire
# inbound Intercom messages spawn overlapping embedded_run dispatches on one
# conversation lane; one run leaks the lane owner lock; later dispatches wedge at
# embedded_run:started; the stuck-session watchdog aborts them but logs
# `released=0` (lane never freed) and the runtime DISCARDS the already-generated
# reply. The customer sees nothing and — because the plugin's dispatch await
# never settles — the in-plugin silent_dispatch alarm can't fire either.
#
# TWO layers guard this (see docs / PR): the intercom plugin now bounds the
# dispatch await and pages #cs-escalations (dispatch_timed_out) for CUSTOMER
# pickup. THIS watchdog is the out-of-process OPS backstop: it fires from
# journald even if the plugin path itself is broken or mid-deploy, and it keys
# off the definitive `released=0` lane-leak marker the plugin cannot observe.
#
# Detection signal (ground-truthed in journald, openclaw-gateway-edge):
#   [diagnostic] stuck session recovery outcome: status=aborted
#     action=abort_embedded_run sessionId=<uuid>
#     sessionKey=agent:support:intercom:direct:<convId> … released=0
# The `action=abort_embedded_run` + `released=0` pair is the reply-killing event.
# We deliberately do NOT alert on mere `stalled_agent_run` warnings (transient,
# often self-resolve) — only on an abort that failed to release the lane.
#
# Dedupe: one page per wedged CONVERSATION per cooldown window
# (STUCK_LANE_COOLDOWN_SECONDS, default 6h) — collapses the ~3 aborts a single
# wedge emits into one page, while a genuine re-wedge after the window pages
# again. First-ever run seeds silently (no backlog page-storm on install).
#
# Runs every ~2 min via /etc/cron.d/stuck-lane-watchdog ON NODE-8 (installed
# idempotently by scripts/install-aux-units.sh). Must run as root — reads
# journald and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT post to Slack.
#               State IS still advanced (faithful dedupe rehearsal); point
#               STUCK_LANE_STATE_FILE at a throwaway path to rehearse without
#               consuming watermarks.
#
# Env knobs (mainly for tests — defaults target the live edge gateway):
#   STUCK_LANE_JOURNAL_FILE        pre-captured journal text (tests). Default:
#                                  live `journalctl` of openclaw-gateway-edge.
#   STUCK_LANE_LOOKBACK            journalctl --since window (default "15 min ago")
#   STUCK_LANE_STATE_FILE          per-conv last-alert store
#   STUCK_LANE_COOLDOWN_SECONDS    per-conv re-alert cooldown (default 21600 = 6h)
#   STUCK_LANE_SLACK_CHANNEL       target channel (default #clio_devops)
#   STUCK_LANE_INTERCOM_WORKSPACE  Intercom workspace id for deep-links. Default:
#                                  read from EDGE_CONFIG via jq; empty → no link.
#   STUCK_LANE_EDGE_CONFIG         edge openclaw.json (default /root/.openclaw-edge/openclaw.json)
#   STUCK_LANE_LOCKFILE            single-run lock
#   STUCK_LANE_SKIP_HOST_GUARD     1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[stuck-lane-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
JOURNAL_FILE="${STUCK_LANE_JOURNAL_FILE:-}"
LOOKBACK="${STUCK_LANE_LOOKBACK:-15 min ago}"
STATE_FILE="${STUCK_LANE_STATE_FILE:-/var/lib/stuck-lane-watchdog/seen.json}"
COOLDOWN="${STUCK_LANE_COOLDOWN_SECONDS:-21600}"
LOCKFILE="${STUCK_LANE_LOCKFILE:-/var/run/stuck-lane-watchdog.lock}"
EDGE_CONFIG="${STUCK_LANE_EDGE_CONFIG:-/root/.openclaw-edge/openclaw.json}"
SKIP_HOST_GUARD="${STUCK_LANE_SKIP_HOST_GUARD:-0}"
GATEWAY_UNIT="openclaw-gateway-edge"
DRY_RUN=0

# slack-notify.sh reads this (target channel).
export SLACK_CHANNEL="${STUCK_LANE_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# a fleet stopped on purpose would otherwise page this alarm for the whole window.
# Fail-safe: an absent/expired/malformed flag reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# Resolve the Intercom workspace id for deep-links: explicit env wins, else best-
# effort from the edge config (jq). Empty is fine — the alert then omits the link.
WORKSPACE="${STUCK_LANE_INTERCOM_WORKSPACE:-}"
if [ -z "$WORKSPACE" ] && command -v jq >/dev/null 2>&1 && [ -f "$EDGE_CONFIG" ]; then
  WORKSPACE="$(jq -r '.channels.intercom.accounts.default.workspaceId // empty' "$EDGE_CONFIG" 2>/dev/null || true)"
fi

# ──────────────────────────────────────────────────────────────
# scan_stuck_lanes — pure detection core.
#   $1 journal_file  $2 state_file  $3 payload_out  $4 persist(0|1)
# Reads journal text from $1, alerts on each wedged conversation whose lane
# recovery aborted with released=0 and whose last alert (in $2) is older than
# COOLDOWN (or never), advances that conv's watermark (when persist=1), writes a
# Slack payload to $3 (only when there are alerts), and prints the human-readable
# block to stdout. First-ever run (state file absent) seeds WITHOUT alerting.
# ──────────────────────────────────────────────────────────────
scan_stuck_lanes() {
  JOURNAL_FILE="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" PERSIST="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" COOLDOWN="$COOLDOWN" WORKSPACE="$WORKSPACE" python3 - <<'PYEOF'
import json, os, re
from datetime import datetime

journal_file = os.environ["JOURNAL_FILE"]
state_file   = os.environ["STATE_FILE"]
payload_out  = os.environ["PAYLOAD_OUT"]
persist      = os.environ.get("PERSIST", "1") == "1"
channel      = os.environ["SLACK_CHANNEL"]
cooldown     = int(os.environ.get("COOLDOWN", "21600"))
workspace    = os.environ.get("WORKSPACE", "").strip()

# The reply-killing event: an abort that failed to release the lane.
# One line per abort; sessionKey carries the Intercom conversation id.
SESSION_RE = re.compile(r"(?:^|\s)sessionId=(?P<sessionId>\S+)")
CONV_RE    = re.compile(r"sessionKey=agent:[a-z0-9_-]+:intercom:direct:(?P<convId>\d+)")
TS_RE      = re.compile(r"(\d{4}-\d{2}-\d{2}T[\d:.]+(?:[+-]\d{2}:?\d{2}|Z))")

def parse_epoch(ts):
    if not ts:
        return None
    t = ts.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(t).timestamp()
    except ValueError:
        return None

# state: convId -> {"ts": iso, "epoch": float}
seeded = os.path.exists(state_file)
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)
# convId -> {"count": n, "ts": latest_iso, "epoch": latest_epoch}
pending = {}

try:
    with open(journal_file) as f:
        lines = f.readlines()
except Exception:
    lines = []

for line in lines:
    # Gate on the definitive lane-leak marker: an abort that did NOT free the
    # lane. released>0 means recovery succeeded — never alert on that.
    if "stuck session recovery outcome:" not in line:
        continue
    if "action=abort_embedded_run" not in line:
        continue
    if "released=0" not in line:
        continue
    conv_m = CONV_RE.search(line)
    if not conv_m:
        continue  # not an intercom support lane we can route
    conv_id = conv_m.group("convId")
    ts_m = TS_RE.search(line)
    ts = ts_m.group(1) if ts_m else ""
    epoch = parse_epoch(ts) or 0.0
    cur = pending.get(conv_id)
    if cur is None or epoch >= cur["epoch"]:
        pending[conv_id] = {
            "count": (cur["count"] + 1) if cur else 1,
            "ts": ts or (cur["ts"] if cur else ""),
            "epoch": epoch,
        }
    else:
        pending[conv_id]["count"] += 1

alerts = []  # (conv_id, count, ts)
for conv_id, info in pending.items():
    prev = state.get(conv_id)
    prev_epoch = prev.get("epoch", 0.0) if isinstance(prev, dict) else 0.0
    # Alert unless we paged this conv within the cooldown window.
    within_cooldown = prev is not None and info["epoch"] and prev_epoch and (info["epoch"] - prev_epoch) < cooldown
    new_state[conv_id] = {"ts": info["ts"], "epoch": info["epoch"]}
    if not seeded:
        continue  # first-ever run: seed silently, no backlog page-storm
    if within_cooldown:
        continue
    alerts.append((conv_id, info["count"], info["ts"]))

# Prune the conv set so it can't grow unbounded (keep most recent 2000 by epoch).
if len(new_state) > 2000:
    new_state = dict(
        sorted(new_state.items(),
               key=lambda kv: (kv[1].get("epoch", 0.0) if isinstance(kv[1], dict) else 0.0))[-2000:]
    )

if persist:
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: a[2])

def conv_ref(conv_id):
    if workspace:
        url = f"https://app.intercom.com/a/inbox/{workspace}/inbox/conversation/{conv_id}"
        return f"<{url}|#{conv_id}>"
    return f"#{conv_id}"

lines_out = [
    f":rotating_light: *Stuck support lane(s) — reply discarded ({len(alerts)})*",
    "The edge gateway force-aborted a wedged agent run WITHOUT releasing the lane "
    "(`action=abort_embedded_run … released=0`), so Caroline's generated reply was "
    "discarded (upstream openclaw #97538). The customer got no bot reply — please "
    "check #cs-escalations / pick these up.",
]
for conv_id, count, ts in alerts:
    lines_out.append(f"• conv {conv_ref(conv_id)} — {count} abort(s) at {ts or '?'}")
text = "\n".join(lines_out)

with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (~30ms). Guards the failure that
# would make THIS watchdog itself rot silently: a detector that no longer
# detects, or one that fires on a lane that WAS released. Throwaway temp paths.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out bullets
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  # Pre-seeded state (so the conv is "new", not seed-suppressed). One abort that
  # did NOT release the lane (released=0 → must FIRE) and one that DID
  # (released=1 → must be SUPPRESSED), proving the released=0 gate.
  cat > "$td/journal.txt" <<'JNL'
2026-06-30T18:25:52.812+00:00 ovh-node-8 node[1]: 2026-06-30T18:25:52.812+00:00 [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-wedged sessionKey=agent:support:intercom:direct:215474906522805 activeSessionId=x activeWorkKind=embedded_run lane=session:agent:support:intercom:direct:215474906522805 aborted=true drained=true forceCleared=false released=0
2026-06-30T18:26:52.000+00:00 ovh-node-8 node[1]: 2026-06-30T18:26:52.000+00:00 [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-freed sessionKey=agent:support:intercom:direct:999999999999999 activeSessionId=y activeWorkKind=embedded_run lane=session:agent:support:intercom:direct:999999999999999 aborted=true drained=true forceCleared=true released=1
JNL
  printf '%s\n' '{"seed":{"ts":"2026-01-01T00:00:00Z","epoch":1}}' > "$td/state.json"
  out="$(COOLDOWN=21600 WORKSPACE="" scan_stuck_lanes "$td/journal.txt" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "215474906522805"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the released=0 abort" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -q "999999999999999"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector flagged a released=1 (lane-freed) abort" >&2
    return 1
  fi
  bullets="$(printf '%s\n' "$out" | grep -c '^• ' || true)"
  if [ "$bullets" != "1" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: expected 1 alert bullet, got $bullets" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed — refusing to run with a broken detector"
  exit 3
fi

# ──────────────────────────────────────────────────────────────
# Host guard: wrong node → no-op. Skippable for tests.
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another stuck-lane-watchdog run holds $LOCKFILE"; exit 0; }
fi

# Capture the journal window (unless a fixture was supplied for tests).
CLEANUP_JOURNAL=0
if [ -z "$JOURNAL_FILE" ]; then
  JOURNAL_FILE="$(mktemp)"
  CLEANUP_JOURNAL=1
  journalctl -u "$GATEWAY_UNIT" --since "$LOOKBACK" --no-pager -o short-iso 2>/dev/null > "$JOURNAL_FILE" || true
fi

PAYLOAD_FILE="$(mktemp)"
trap '[ "$CLEANUP_JOURNAL" -eq 1 ] && rm -f "$JOURNAL_FILE"; rm -f "$PAYLOAD_FILE"' EXIT

# Detect WITHOUT persisting (PERSIST=0): the watermark may only advance once
# the alert is actually delivered, else a token/channel/CLI outage marks the
# wedge "seen" and the only out-of-process page is never retried. The commit
# re-runs the scan over the SAME captured journal with PERSIST=1 (deterministic:
# identical input + unchanged state ⇒ identical detection, now written).
alert_block="$(scan_stuck_lanes "$JOURNAL_FILE" "$STATE_FILE" "$PAYLOAD_FILE" 0 || true)"
commit_watermark() {
  scan_stuck_lanes "$JOURNAL_FILE" "$STATE_FILE" /dev/null 1 >/dev/null || true
}

if [ -z "$alert_block" ]; then
  # Nothing to deliver — safe to commit (this is also the first-run seeding
  # path, which MUST persist or every run stays "first run" and never alerts).
  commit_watermark
  log "OK: no new stuck/discarded lanes."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  # Documented dry-run contract: state IS still advanced (faithful dedupe
  # rehearsal; use a throwaway STUCK_LANE_STATE_FILE to rehearse for free).
  commit_watermark
  exit 0
fi

log "Posting stuck-lane alert to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
if slack_notify_payload_file_status "$PAYLOAD_FILE"; then
  commit_watermark
else
  log "ALERT-DELIVERY-FAILED: Slack post not confirmed — watermark NOT advanced; the next cron tick will re-detect and retry."
  exit 1
fi

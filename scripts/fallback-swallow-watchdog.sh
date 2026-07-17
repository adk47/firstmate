#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Fallback-Swallow Watchdog
#
# Alerts #clio_devops when an agent turn ends in an EMPTY completion
# that gets "surfaced as an error to the user" — the symptom of
# openclaw's empty-completion-swallows-fallback flaw (2026-06-08
# @CMO incident, PR #450). openclaw only treats a 0-token completion
# as a failure-that-cascades for GPT-5-family models (the
# isGpt5ModelId gate in result-fallback-classifier); any non-GPT-5
# model that returns empty is scored candidate_succeeded and the
# chain STOPS instead of advancing to the stronger model behind it.
#
# fix/fallback-empty-cascade reshapes every fallback chain so non-GPT-5
# models sit last-only (enforced by validate-config-matrix.sh check #6),
# which neutralises the common case. This watchdog is the defense layer
# for the RESIDUALS the chain-reshape can't reach:
#   - a non-GPT-5 PRIMARY that empties (e.g. cmo on opus-4.7 by choice),
#   - the LAST model in a chain emptying (nothing left to cascade to),
#   - a future chain that somehow slips past the CI gate.
#
# Detection signal (ground-truthed in journald, ungated, all agents —
# interactive AND cron, both gateways):
#   [agent/embedded] incomplete turn detected: runId=… sessionId=…
#     stopReason=stop payloads=0 — surfacing error to user
# The `payloads=0` is the empty completion; `surfacing error to user`
# is the swallow symptom. We alert on each NEW runId (deduped via a
# state file), best-effort resolving the agent name from sessionId.
#
# Runs every ~5 min via /etc/cron.d/fallback-swallow-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh). Must run as
# root — reads journald and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT post
#               to Slack. State IS still advanced (faithful dedupe
#               rehearsal); point FALLBACK_SWALLOW_STATE_FILE at a
#               throwaway path to rehearse without consuming watermarks.
#
# Env knobs (mainly for tests — defaults target the live gateways):
#   FALLBACK_SWALLOW_JOURNAL_FILE   pre-captured journal text (tests).
#                                   Default: live `journalctl` of both
#                                   gateway units over the lookback window.
#   FALLBACK_SWALLOW_LOOKBACK       journalctl --since window (default "15 min ago")
#   FALLBACK_SWALLOW_STATE_FILE     alerted-runId store
#   FALLBACK_SWALLOW_AGENT_ROOTS    space-sep agent dirs for sessionId→agent
#   FALLBACK_SWALLOW_SLACK_CHANNEL  target channel (default #clio_devops)
#   FALLBACK_SWALLOW_LOCKFILE       single-run lock
#   FALLBACK_SWALLOW_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[fallback-swallow-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
JOURNAL_FILE="${FALLBACK_SWALLOW_JOURNAL_FILE:-}"
LOOKBACK="${FALLBACK_SWALLOW_LOOKBACK:-15 min ago}"
STATE_FILE="${FALLBACK_SWALLOW_STATE_FILE:-/var/lib/fallback-swallow-watchdog/seen.json}"
LOCKFILE="${FALLBACK_SWALLOW_LOCKFILE:-/var/run/fallback-swallow-watchdog.lock}"
AGENT_ROOTS="${FALLBACK_SWALLOW_AGENT_ROOTS:-/root/.openclaw-main/agents /root/.openclaw-edge/agents}"
SKIP_HOST_GUARD="${FALLBACK_SWALLOW_SKIP_HOST_GUARD:-0}"
GATEWAY_UNITS=(openclaw-gateway-main openclaw-gateway-edge)
DRY_RUN=0

# slack-notify.sh reads this (target channel).
export SLACK_CHANNEL="${FALLBACK_SWALLOW_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

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
# gateway restarts during a window churn fallbacks that would page this alarm.
# Fail-safe: an absent/expired/malformed flag reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# ──────────────────────────────────────────────────────────────
# scan_swallows — pure detection core.
#   $1 journal_file  $2 state_file  $3 payload_out  $4 persist(0|1)
# Reads journal text from $1, alerts on each NEW empty-completion swallow
# (runId not seen before), advances the runId watermark set in $2 (when
# persist=1), writes a Slack payload to $3 (only when there are alerts),
# and prints the human-readable block to stdout. First-ever run (state
# file absent) seeds WITHOUT alerting, so install never pages the backlog.
# ──────────────────────────────────────────────────────────────
scan_swallows() {
  JOURNAL_FILE="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" PERSIST="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" AGENT_ROOTS="$AGENT_ROOTS" python3 - <<'PYEOF'
import json, os, re, glob
from datetime import datetime, timezone

journal_file = os.environ["JOURNAL_FILE"]
state_file   = os.environ["STATE_FILE"]
payload_out  = os.environ["PAYLOAD_OUT"]
persist      = os.environ.get("PERSIST", "1") == "1"
channel      = os.environ["SLACK_CHANNEL"]
agent_roots  = os.environ.get("AGENT_ROOTS", "").split()

# The swallow fingerprint: an empty completion (payloads=0) surfaced to the user.
LINE_RE = re.compile(
    r"incomplete turn detected:\s*runId=(?P<runId>\S+)\s+sessionId=(?P<sessionId>\S+)"
    r"\s+stopReason=(?P<stop>\S+)\s+payloads=(?P<payloads>\d+)"
)
TS_RE = re.compile(r"(\d{4}-\d{2}-\d{2}T[\d:.]+(?:[+-]\d{2}:?\d{2}|Z))")

def resolve_agent(session_id):
    for root in agent_roots:
        for hit in glob.glob(os.path.join(root, "*", "sessions", session_id + "*")):
            # …/agents/<agent>/sessions/<sessionId>…  → take the <agent> segment
            parts = hit.split(os.sep)
            try:
                return parts[parts.index("sessions") - 1]
            except (ValueError, IndexError):
                pass
    return None

# previously-alerted runIds (dict runId -> iso ts)
seeded = os.path.exists(state_file)
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)
alerts = []  # (agent_or_session, runId, ts)

try:
    with open(journal_file) as f:
        lines = f.readlines()
except Exception:
    lines = []

for line in lines:
    if "incomplete turn detected" not in line or "surfacing error to user" not in line:
        continue
    m = LINE_RE.search(line)
    if not m or m.group("payloads") != "0":
        continue  # only empty completions (payloads=0) are the swallow signal
    run_id = m.group("runId")
    session_id = m.group("sessionId")
    ts_m = TS_RE.search(line)
    ts = ts_m.group(1) if ts_m else ""
    if run_id in state:
        continue  # already handled
    new_state[run_id] = ts or "seen"
    if not seeded:
        continue  # first-ever run: seed silently, no backlog page-storm
    who = resolve_agent(session_id) or ("session " + session_id[:12])
    alerts.append((who, run_id, ts))

# Prune the runId set so it can't grow unbounded (keep most recent 2000).
if len(new_state) > 2000:
    new_state = dict(sorted(new_state.items(), key=lambda kv: kv[1])[-2000:])

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
lines_out = [f":warning: *Empty-completion fallback swallow(s) — {len(alerts)}*",
             "An agent turn ended with an empty completion (payloads=0) surfaced as an error — "
             "the fallback chain may have been swallowed (openclaw isGpt5ModelId gate). "
             "Check the agent's model chain + the session for a 0-token final turn."]
for who, run_id, ts in alerts:
    lines_out.append(f"• *{who}* at {ts or '?'} (runId={run_id})")
text = "\n".join(lines_out)

with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (~30ms). Guards the
# failure that would make THIS watchdog itself rot silently: a
# detector that no longer detects. Uses throwaway temp paths.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out bullets
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  # Pre-seeded state (so runIds are "new", not seed-suppressed). One empty turn
  # (payloads=0 → must FIRE) and one non-empty incomplete turn (payloads=3 →
  # must be SUPPRESSED), proving the payloads==0 gate.
  cat > "$td/journal.txt" <<'JNL'
2026-06-08T11:46:48.365+00:00 [agent/embedded] incomplete turn detected: runId=RUN-empty sessionId=sess-empty stopReason=stop payloads=0 — surfacing error to user
2026-06-08T12:00:00.000+00:00 [agent/embedded] incomplete turn detected: runId=RUN-nonempty sessionId=sess-x stopReason=stop payloads=3 — surfacing error to user
JNL
  printf '%s\n' '{"RUN-old":"2026-06-01T00:00:00Z"}' > "$td/state.json"
  out="$(scan_swallows "$td/journal.txt" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "RUN-empty"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the empty (payloads=0) turn" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -q "RUN-nonempty"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector flagged a non-empty (payloads>0) turn" >&2
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
  flock -n 9 || { log "SKIP: another fallback-swallow-watchdog run holds $LOCKFILE"; exit 0; }
fi

# Capture the journal window (unless a fixture was supplied for tests).
CLEANUP_JOURNAL=0
if [ -z "$JOURNAL_FILE" ]; then
  JOURNAL_FILE="$(mktemp)"
  CLEANUP_JOURNAL=1
  units=()
  for u in "${GATEWAY_UNITS[@]}"; do units+=(-u "$u"); done
  journalctl "${units[@]}" --since "$LOOKBACK" --no-pager -o short-iso 2>/dev/null > "$JOURNAL_FILE" || true
fi

PAYLOAD_FILE="$(mktemp)"
trap '[ "$CLEANUP_JOURNAL" -eq 1 ] && rm -f "$JOURNAL_FILE"; rm -f "$PAYLOAD_FILE"' EXIT

alert_block="$(scan_swallows "$JOURNAL_FILE" "$STATE_FILE" "$PAYLOAD_FILE" 1 || true)"

if [ -z "$alert_block" ]; then
  log "OK: no new empty-completion fallback swallows."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  exit 0
fi

log "Posting fallback-swallow alert to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
slack_notify_payload_file "$PAYLOAD_FILE"

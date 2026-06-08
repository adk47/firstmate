#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Cron Health Watchdog
#
# Notifies #clio_devops the moment ANY openclaw cron run errors,
# so broken jobs stop rotting silently in cron/runs/*.jsonl. This
# is the missing piece behind the 2026-06 incident where the CMO
# b2b-reply-scanner stacked 17 straight preflight failures over
# ~3 days before anyone noticed (the model-allowlist drift fixed
# in the same PR). OpenClaw records every run outcome to JSONL but
# has no native failure alerting — this watchdog is that layer.
#
# Detection model: scan every cron/runs/<jobId>.jsonl, look at the
# "finished" records (status == ok|error). Alert on EVERY errored
# run we have not alerted on before (per-job high-water mark in a
# state file). One consolidated Slack post per invocation lists all
# new failures. First time a job is ever seen we seed its watermark
# WITHOUT alerting, so installing this never pages for the entire
# historical backlog.
#
# Runs every ~5 min via /etc/cron.d/cron-health-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh). Must run
# as root — reads /root/.openclaw-main/cron/ and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT
#               post to Slack. State IS still advanced, so a dry-run
#               is a faithful rehearsal of the dedupe behaviour; point
#               CRON_HEALTH_STATE_FILE at a throwaway path to rehearse
#               without consuming real watermarks.
#
# Env knobs (mainly for tests — defaults target the live main profile):
#   CRON_HEALTH_RUNS_DIR        cron run JSONL dir
#   CRON_HEALTH_JOBS_FILE       cron jobs.json (id -> name/agent map)
#   CRON_HEALTH_STATE_FILE      per-job watermark store
#   CRON_HEALTH_SLACK_CONFIG    openclaw config holding the devops token
#   CRON_HEALTH_SLACK_CHANNEL   target channel (default #clio_devops)
#   CRON_HEALTH_LOCKFILE        single-run lock
#   CRON_HEALTH_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[cron-health-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
CRON_RUNS_DIR="${CRON_HEALTH_RUNS_DIR:-/root/.openclaw-main/cron/runs}"
CRON_JOBS_FILE="${CRON_HEALTH_JOBS_FILE:-/root/.openclaw-main/cron/jobs.json}"
STATE_FILE="${CRON_HEALTH_STATE_FILE:-/var/lib/cron-health-watchdog/seen.json}"
LOCKFILE="${CRON_HEALTH_LOCKFILE:-/var/run/cron-health-watchdog.lock}"
SKIP_HOST_GUARD="${CRON_HEALTH_SKIP_HOST_GUARD:-0}"
ERROR_PREVIEW_CHARS=300
# Only page once a job has this many CONSECUTIVE error runs with no intervening
# healthy run. A single error bracketed by ok runs is a recovered/transient blip
# (the openclaw outcome resolver flags a whole run "error" on any recovered tool
# error — e.g. a cron agent that guessed a bad flag, self-corrected, and finished
# fine). The incident this watchdog exists for was a SUSTAINED failure (17 straight
# runs over ~3 days), so a streak threshold catches real breakage while killing the
# recovered-blip false alarms. Set to 1 to restore alert-on-every-error.
MIN_STREAK="${CRON_HEALTH_MIN_STREAK:-2}"
DRY_RUN=0

# slack-notify.sh reads these (channel + which config holds the token).
# Export before sourcing so its `:=` defaults don't override us.
export SLACK_CHANNEL="${CRON_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops
export SLACK_NOTIFY_CONFIG="${CRON_HEALTH_SLACK_CONFIG:-/root/.openclaw-main/openclaw.json}"

log() { echo "$LOGPREFIX $1"; }

# ──────────────────────────────────────────────────────────────
# Parse flags
# ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Locate the sibling Slack helper relative to THIS script so the
# watchdog works from /opt/hydra, a worktree, or a deploy mirror.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# ──────────────────────────────────────────────────────────────
# scan_failures — the pure detection core.
#   $1 runs_dir  $2 jobs_file  $3 state_file  $4 payload_out  $5 persist(0|1)
# Writes a Slack-ready JSON payload to $payload_out (only if there are
# new failures), advances the per-job watermarks in $state_file (when
# persist=1), and prints the human-readable alert block to stdout.
# Exit 0 always (best-effort); stdout empty == nothing new to report.
# ──────────────────────────────────────────────────────────────
scan_failures() {
  RUNS_DIR="$1" JOBS_FILE="$2" STATE_FILE="$3" PAYLOAD_OUT="$4" PERSIST="$5" \
  SLACK_CHANNEL="$SLACK_CHANNEL" PREVIEW="$ERROR_PREVIEW_CHARS" \
  MIN_STREAK="$MIN_STREAK" python3 - <<'PYEOF'
import json, os, glob
from datetime import datetime, timezone

runs_dir   = os.environ["RUNS_DIR"]
jobs_file  = os.environ["JOBS_FILE"]
state_file = os.environ["STATE_FILE"]
payload_out= os.environ["PAYLOAD_OUT"]
persist    = os.environ.get("PERSIST", "1") == "1"
channel    = os.environ["SLACK_CHANNEL"]
preview    = int(os.environ.get("PREVIEW", "300"))
min_streak = max(1, int(os.environ.get("MIN_STREAK", "2")))

def is_failure(rec):
    """A run is a hard failure only if it errored AND did not deliver its output.
    A run that errored but still delivered (delivered:true / deliveryStatus
    'delivered') shipped its result and is treated as healthy — it never alerts
    and it breaks a consecutive-error streak."""
    if rec.get("status") != "error":
        return False
    if rec.get("delivered") is True or rec.get("deliveryStatus") == "delivered":
        return False
    return True

# job id -> (name, agent)
names = {}
try:
    with open(jobs_file) as f:
        for j in json.load(f).get("jobs", []):
            names[j.get("id")] = (j.get("name", "<unknown>"), j.get("agentId", "<unknown>"))
except Exception:
    pass

# previous per-job high-water marks
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)
alerts = []  # (name, agent, ts_ms, err)

for path in sorted(glob.glob(os.path.join(runs_dir, "*.jsonl"))):
    job_id = os.path.basename(path)[:-len(".jsonl")]
    finished = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue  # skip a half-written/garbled line, don't abort the job
                if rec.get("status") in ("ok", "error") and isinstance(rec.get("ts"), (int, float)):
                    finished.append(rec)
    except Exception:
        continue
    if not finished:
        continue
    finished.sort(key=lambda r: r["ts"])  # streak detection needs chronological order
    max_ts = max(r["ts"] for r in finished)
    prev = state.get(job_id)
    if prev is None:
        # First time we've ever seen this job: seed the watermark and do
        # NOT alert on the historical backlog (avoids a page-storm on install).
        new_state[job_id] = max_ts
        continue
    name, agent = names.get(job_id, (job_id, "<unknown>"))
    # Walk runs chronologically tracking the consecutive-failure streak. A healthy
    # run (ok, or errored-but-delivered) resets it to 0. Only alert on a failure
    # run that is BOTH newer than the watermark AND the Nth-or-later consecutive
    # failure — this suppresses lone recovered blips but still pages every run of a
    # sustained outage.
    streak = 0
    for r in finished:
        if is_failure(r):
            streak += 1
            if r["ts"] > prev and streak >= min_streak:
                err = r.get("error") or r.get("summary") or "unknown error"
                err = " ".join(str(err).split())  # collapse newlines/runs of space to one line
                if len(err) > preview:
                    err = err[:preview] + "…"
                alerts.append((name, agent, r["ts"], err))
        else:
            streak = 0
    new_state[job_id] = max(prev, max_ts)

# Persist watermarks (best-effort, atomic).
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
lines = [f":rotating_light: *Cron failure(s) detected — {len(alerts)}*"]
for name, agent, ts_ms, err in alerts:
    ts_iso = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines.append(f"• *{name}* ({agent}) at {ts_iso}: {err}")
text = "\n".join(lines)

# Build the exact Slack payload in Python — error strings contain quotes,
# backticks and backslashes (e.g. failed `trino-query.sh \"SELECT ...\"`)
# that would shatter a naive bash JSON interpolation. slack-notify.sh's
# slack_notify_payload_file posts this verbatim.
with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (cost ~30ms).
# Guards the failure that would make THIS watchdog itself rot
# silently: a detector that no longer detects. Mirrors the
# openclaw-watchdog self-test discipline (a regex that silently
# stopped matching went unnoticed for months). Uses throwaway temp
# paths — never touches real state or Slack.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  mkdir -p "$td/runs"
  # One job, pre-seeded watermark at ts=100: ok@150, then a two-error streak
  # (error@190, error@200). This fixture exercises BOTH new behaviours at the
  # default streak threshold of 2: error@190 is a lone failure (preceded by the
  # ok@150) so it must be SUPPRESSED, while error@200 completes a 2-run streak so
  # it must FIRE. (Pre-streak-rule this file injected a single error and expected
  # 1 bullet; a lone error now yields 0, so the fixture grew a second error.)
  printf '%s\n' '{"status":"ok","ts":150}' '{"status":"error","ts":190,"error":"first"}' '{"status":"error","ts":200,"error":"boom `q` \"x\""}' \
    > "$td/runs/selftest-job.jsonl"
  printf '%s\n' '{"jobs":[{"id":"selftest-job","name":"selftest","agentId":"qa"}]}' > "$td/jobs.json"
  printf '%s\n' '{"selftest-job":100}' > "$td/state.json"
  # Pin the threshold at 2 for the self-test so it is deterministic regardless of
  # the operator's CRON_HEALTH_MIN_STREAK — the self-test verifies detector
  # HEALTH (fires on a streak, suppresses a lone error), not the live threshold.
  out="$(MIN_STREAK=2 scan_failures "$td/runs" "$td/jobs.json" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "selftest"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the injected error streak" >&2
    return 1
  fi
  # Exactly ONE bullet must fire: error@200 (the run completing the 2-error
  # streak). The ok@150 (healthy) and error@190 (lone, streak length 1) must both
  # be filtered out — a count of 2 would mean either ok runs are mis-reported or
  # the streak gate is not suppressing recovered blips.
  local bullets
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
# Host guard: wrong node → no-op (prevents an orphaned cron from
# firing after a host migration). Skippable for tests.
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

if [ ! -d "$CRON_RUNS_DIR" ]; then
  log "SKIP: cron runs dir not found: $CRON_RUNS_DIR"
  exit 0
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another cron-health-watchdog run holds $LOCKFILE"; exit 0; }
fi

PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

alert_block="$(scan_failures "$CRON_RUNS_DIR" "$CRON_JOBS_FILE" "$STATE_FILE" "$PAYLOAD_FILE" 1 || true)"

if [ -z "$alert_block" ]; then
  log "OK: no new cron failures."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  exit 0
fi

log "Posting cron-failure alert to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
slack_notify_payload_file "$PAYLOAD_FILE"

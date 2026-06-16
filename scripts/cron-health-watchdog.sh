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
#   CRON_HEALTH_SLACK_CHANNEL   target channel (default #clio_devops)
#   CRON_HEALTH_LOCKFILE        single-run lock
#   CRON_HEALTH_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[cron-health-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
CRON_RUNS_DIR="${CRON_HEALTH_RUNS_DIR:-/root/.openclaw-main/cron/runs}"
CRON_JOBS_FILE="${CRON_HEALTH_JOBS_FILE:-/root/.openclaw-main/cron/jobs.json}"
# openclaw 2026.6.x moved cron run logs OUT of cron/runs/<job>.jsonl and into the
# SQLite `cron_run_logs` table (its `entry_json` column is the same per-run
# record the JSONL lines held). The on-disk runs dir is FROZEN on 6.x, so
# reading it = blind to every failure. Production reads the DB below; the legacy
# JSONL dir stays as the test-injection + pre-6.x fallback, used only when no DB
# is configured. NOTE: `-` (not `:-`) so tests can force the JSONL path with
# CRON_HEALTH_RUNS_DB="" — an explicitly-empty value must win over this default.
CRON_RUNS_DB="${CRON_HEALTH_RUNS_DB-/root/.openclaw-main/state/openclaw.sqlite}"
CRON_STORE_KEY="${CRON_HEALTH_STORE_KEY:-/root/.openclaw-main/cron/jobs.json}"
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

# slack-notify.sh reads this (target channel).
# Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${CRON_HEALTH_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

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
  RUNS_DB="${RUNS_DB-$CRON_RUNS_DB}" STORE_KEY="${STORE_KEY-$CRON_STORE_KEY}" \
  SLACK_CHANNEL="$SLACK_CHANNEL" PREVIEW="$ERROR_PREVIEW_CHARS" \
  MIN_STREAK="$MIN_STREAK" python3 - <<'PYEOF'
import json, os, glob, sqlite3
from datetime import datetime, timezone

runs_dir   = os.environ["RUNS_DIR"]
jobs_file  = os.environ["JOBS_FILE"]
state_file = os.environ["STATE_FILE"]
payload_out= os.environ["PAYLOAD_OUT"]
persist    = os.environ.get("PERSIST", "1") == "1"
channel    = os.environ["SLACK_CHANNEL"]
preview    = int(os.environ.get("PREVIEW", "300"))
min_streak = max(1, int(os.environ.get("MIN_STREAK", "2")))
runs_db    = os.environ.get("RUNS_DB", "").strip()
store_key  = os.environ.get("STORE_KEY", "").strip()

def is_failure(rec):
    """A run is a hard failure only if it errored AND never reached its target.
    A run that errored but still delivered is treated as healthy — it never
    alerts and it breaks a consecutive-error streak. There are TWO delivery
    paths, either of which means the agent got its output out:

      1. openclaw's auto-delivery announced the turn output
         (delivered:true / deliveryStatus 'delivered').
      2. the agent posted to Slack itself via the `message` tool. openclaw
         does NOT credit that as the cron delivery, so the record keeps
         delivered:false / deliveryStatus:'not-delivered'; and under the codex
         runtime a trailing-or-earlier non-fatal tool error (a failed
         `stripe`/`git`/`jq` step) overwrites error/summary and flips the run
         to status:error even though the report was already posted. The tell
         is a non-empty delivery.messageToolSentTo — openclaw records a target
         there ONLY after a successful message-tool send (collectToolTelemetry
         bails on `if (params.isError) return` before populating it), so a
         non-empty array proves a message reached the channel with a receipt.

    Without path 2 every codex cron that self-posts its report
    (e.g. daily-dispute-handler) false-pages: verified 2026-06-08 — the dispute
    report reached #finance_muso (Slack ts 1780934615.350849) while the run
    record read status:error / delivered:false (error string was the earlier
    failed `stripe subscriptions list` step)."""
    if rec.get("status") != "error":
        return False
    if rec.get("delivered") is True or rec.get("deliveryStatus") == "delivered":
        return False
    sent = (rec.get("delivery") or {}).get("messageToolSentTo")
    if isinstance(sent, list) and sent:
        return False
    return True

def load_runs():
    """Return ({job_id: [record, ...]}, source_error_or_None).

    openclaw 2026.6.x persists cron run logs in the SQLite `cron_run_logs`
    table; its `entry_json` column is the SAME per-run record the legacy
    cron/runs/<job>.jsonl lines held, so the detector below is unchanged.
    Production reads the DB. The on-disk JSONL dir is the pre-6.x / unit-test
    fallback, used only when no DB is configured (RUNS_DB empty) or the DB file
    is absent. A DB that exists but has LOST the cron_run_logs table returns a
    source_error so we page (blind) instead of silently reporting OK on a
    frozen/relocated store — the exact silent-rot this watchdog guards against.
    """
    if runs_db and os.path.exists(runs_db):
        try:
            con = sqlite3.connect("file:%s?mode=ro" % runs_db, uri=True)
            try:
                cur = con.cursor()
                if cur.execute("SELECT name FROM sqlite_master "
                               "WHERE type='table' AND name='cron_run_logs'").fetchone() is None:
                    return {}, ("cron_run_logs table missing in %s — openclaw cron-store "
                                "schema changed; this watchdog can no longer read run logs" % runs_db)
                if store_key:
                    rows = cur.execute("SELECT job_id, entry_json FROM cron_run_logs "
                                       "WHERE store_key = ?", (store_key,))
                else:
                    rows = cur.execute("SELECT job_id, entry_json FROM cron_run_logs")
                by_job = {}
                for job_id, entry in rows:
                    if not entry:
                        continue
                    try:
                        rec = json.loads(entry)
                    except Exception:
                        continue  # skip a garbled row, don't abort the scan
                    by_job.setdefault(job_id, []).append(rec)
                return by_job, None
            finally:
                con.close()
        except Exception as e:
            return {}, "cron_run_logs read failed (%s): %s" % (runs_db, e)
    # Legacy / test fallback: per-job JSONL files.
    by_job = {}
    for path in sorted(glob.glob(os.path.join(runs_dir, "*.jsonl"))):
        job_id = os.path.basename(path)[:-len(".jsonl")]
        recs = []
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        recs.append(json.loads(line))
                    except Exception:
                        continue  # skip a half-written/garbled line
        except Exception:
            continue
        if recs:
            by_job[job_id] = recs
    return by_job, None

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

def _persist():
    if not persist:
        return
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

def _emit(text):
    # Build the exact Slack payload in Python — error strings contain quotes,
    # backticks and backslashes (e.g. failed `trino-query.sh \"SELECT ...\"`)
    # that would shatter a naive bash JSON interpolation. slack-notify.sh's
    # slack_notify_payload_file posts this verbatim.
    with open(payload_out, "w") as f:
        json.dump({"channel": channel, "text": text}, f)
    print(text)

runs_by_job, source_error = load_runs()

# Blind guard: the production run-log source (SQLite cron_run_logs) is
# unreadable. A monitor that reports OK forever while blind is the precise
# silent-rot this watchdog exists to prevent — so PAGE, once per episode
# (sentinel in the state file), not every tick.
if source_error:
    already = state.get("__source_error__")
    new_state["__source_error__"] = source_error
    _persist()
    if already != source_error:
        _emit(":rotating_light: *cron-health-watchdog is BLIND* — it cannot read cron "
              "run logs, so cron failures will go UNDETECTED until this is fixed.\n• " + source_error)
    raise SystemExit(0)

# Source healthy — clear any stale blind sentinel so a future episode re-pages.
new_state.pop("__source_error__", None)

alerts = []  # (name, agent, ts_ms, err)
for job_id, recs in sorted(runs_by_job.items()):
    finished = [r for r in recs
                if r.get("status") in ("ok", "error") and isinstance(r.get("ts"), (int, float))]
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

_persist()

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: a[2])
lines = [f":rotating_light: *Cron failure(s) detected — {len(alerts)}*"]
for name, agent, ts_ms, err in alerts:
    ts_iso = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines.append(f"• *{name}* ({agent}) at {ts_iso}: {err}")
_emit("\n".join(lines))
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
  # Two jobs, both pre-seeded watermark at ts=100.
  #
  # selftest-job: ok@150, then a two-error streak (error@190, error@200).
  # Exercises the streak threshold of 2: error@190 is a lone failure (preceded
  # by the ok@150) so it must be SUPPRESSED, while error@200 completes a 2-run
  # streak so it must FIRE.
  #
  # delivered-job: two errors (error@190, error@200), each carrying a non-empty
  # delivery.messageToolSentTo — the agent posted to Slack via the message tool
  # but the run still records status:error / delivered:false (the codex
  # self-post false-fail). is_failure() must treat BOTH as healthy, so this job
  # contributes 0 bullets and its name must NOT appear in the output. If the
  # message-tool branch ever regresses these two stack a 2-streak and fire,
  # tripping the bullet-count assertion below.
  printf '%s\n' '{"status":"ok","ts":150}' '{"status":"error","ts":190,"error":"first"}' '{"status":"error","ts":200,"error":"boom `q` \"x\""}' \
    > "$td/runs/selftest-job.jsonl"
  printf '%s\n' \
    '{"status":"error","ts":190,"error":"⚠️ 🛠️ `git status` failed","delivery":{"messageToolSentTo":[{"channel":"message"}]}}' \
    '{"status":"error","ts":200,"error":"⚠️ 🛠️ `stripe ...` failed","delivery":{"messageToolSentTo":[{"channel":"message"}]}}' \
    > "$td/runs/delivered-job.jsonl"
  printf '%s\n' '{"jobs":[{"id":"selftest-job","name":"selftest","agentId":"qa"},{"id":"delivered-job","name":"deliveredpost","agentId":"qa"}]}' > "$td/jobs.json"
  printf '%s\n' '{"selftest-job":100,"delivered-job":100}' > "$td/state.json"
  # Pin the threshold at 2 for the self-test so it is deterministic regardless of
  # the operator's CRON_HEALTH_MIN_STREAK — the self-test verifies detector
  # HEALTH (fires on a streak, suppresses a lone error), not the live threshold.
  out="$(RUNS_DB="" MIN_STREAK=2 scan_failures "$td/runs" "$td/jobs.json" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
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
  # The message-tool-delivered job must be suppressed entirely — its name must
  # never reach the alert block (guards the delivery.messageToolSentTo branch).
  if printf '%s' "$out" | grep -q "deliveredpost"; then
    echo "$LOGPREFIX SELF-TEST FAIL: message-tool-delivered run was flagged as a failure" >&2
    return 1
  fi

  # ── 6.x SQLite source path ──────────────────────────────────────────────
  # The cases above exercise the JSONL fallback (RUNS_DB=""). This one guards the
  # PRODUCTION reader: build a throwaway cron_run_logs table and verify a 2-error
  # streak surfaces THROUGH it. A future cron-store relocation that silently froze
  # this watchdog would fail HERE instead of rotting unnoticed.
  local db sout
  db="$td/runs.sqlite"
  python3 - "$db" <<'PYDB'
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE cron_run_logs (store_key TEXT, job_id TEXT, seq INTEGER, entry_json TEXT)")
sk = "/selftest/jobs.json"
for jid, seq, rec in [
    ("selftest-job", 1, {"status": "error", "ts": 190, "error": "first"}),
    ("selftest-job", 2, {"status": "error", "ts": 200, "error": "boom"}),
]:
    con.execute("INSERT INTO cron_run_logs (store_key, job_id, seq, entry_json) VALUES (?,?,?,?)",
                (sk, jid, seq, json.dumps(rec)))
con.commit(); con.close()
PYDB
  sout="$(RUNS_DB="$db" STORE_KEY="/selftest/jobs.json" MIN_STREAK=2 \
    scan_failures "$td/runs" "$td/jobs.json" "$td/state.json" "$td/payload-sql.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$sout" | grep -q "selftest"; then
    echo "$LOGPREFIX SELF-TEST FAIL: SQLite cron_run_logs reader did not surface the injected streak" >&2
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

# Run-log source presence. On 6.x the source is the SQLite cron_run_logs table
# (CRON_RUNS_DB); the legacy cron/runs/*.jsonl dir is the pre-6.x/test fallback.
# Skip only when the ACTIVE source is entirely absent — a present-but-broken DB
# (table relocated/missing) is handled as a loud BLIND alert in scan_failures,
# NOT a silent skip.
if [ -n "$CRON_RUNS_DB" ]; then
  if [ ! -f "$CRON_RUNS_DB" ] && [ ! -d "$CRON_RUNS_DIR" ]; then
    log "SKIP: no cron run-log source (DB $CRON_RUNS_DB and runs dir $CRON_RUNS_DIR both absent)"
    exit 0
  fi
elif [ ! -d "$CRON_RUNS_DIR" ]; then
  log "SKIP: cron runs dir not found: $CRON_RUNS_DIR (no DB configured)"
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

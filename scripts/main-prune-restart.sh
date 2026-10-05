#!/usr/bin/env bash
# scripts/main-prune-restart.sh -- offline session prune + restart of openclaw-gateway-main.
# Installed/scheduled by install-aux-units.sh (hydra-main-prune-restart.{service,timer}, 02:30 UTC).
# Replaces the hand-placed /usr/local/sbin/hydra-main-{prune-restart,nightly-reset}.sh bridge (MUS-1295).
#
# Why: main's cold start re-parses every session_nodes row on each session lookup
# (listSqliteSessionEntriesFromDatabase, MUS-2652), so the cost scales with row count. At 14d retention
# main carried ~7k rows and a restart froze /health for 22-60 min. Lab on a copy of live state (5 Oct):
# unpruned never stable in 15+ min; pruned of sessions idle >24h (7045 -> 2737 rows) stable from 6.3 min.
# What: maintenance flag -> online backup -> stop main -> `openclaw sessions cleanup --enforce` offline with
#       pruneAfter=$PRUNE on a TEMP config (live openclaw.json is not edited; agent :main sessions are
#       always kept) -> start main -> wait for STABLE health (200 for STABLE_SECS).
# FAIL-OPEN: if the prune fails, main is started anyway. Never retried, never restarts twice. A failed
#       BACKUP aborts before anything is stopped (main is untouched). A failed STOP skips the prune.
#       Exit non-zero (so OnFailure= pages) if the prune, stop or start failed or health never stabilised
#       (main is still started first: paging never costs availability).
# Rollback of data: $BACKUP_ROOT/<ts>/ (stop main, copy the .sqlite files back, start).
# Only one run at a time (flock on $LOCK_FILE); a second invocation skips.
# Usage: main-prune-restart.sh [reason]
#   HYDRA_MAIN_MIN_UPTIME_H=N  skip when main has been up < N hours (the nightly timer sets 4).
# The remaining env knobs exist so the bats suite can run the real script against stubs.
set -uo pipefail

PRUNE="${HYDRA_MAIN_PRUNE_AFTER:-24h}"
SVC="${SVC:-openclaw-gateway-main}"
SD="${SD:-/root/.openclaw-main}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/hydra-main-sessions}"
LOG_DIR="${LOG_DIR:-/var/log}"
MAINT_SH="${MAINT_SH:-/opt/hydra/scripts/hydra-maintenance.sh}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:18789/health}"
STABLE_SECS="${STABLE_SECS:-180}"
MAX_WAIT_SECS="${MAX_WAIT_SECS:-2700}"
POLL_SECS="${POLL_SECS:-5}"
MIN_UPTIME_H="${HYDRA_MAIN_MIN_UPTIME_H:-0}"
PRUNE_PATH="${HYDRA_PRUNE_PATH:-/usr/bin:/bin}"
LOCK_FILE="${LOCK_FILE:-/run/lock/hydra-main-prune-restart.lock}"
REASON="${1:-manual}"
TS=$(date -u +%Y%m%dT%H%M%SZ); BK="$BACKUP_ROOT/$TS"

log() { echo "[main-prune-restart $(date -u +%H:%M:%SZ)] $*"; }
rss_mb() { echo $(( $(ps -o rss= -p "$(systemctl show -p MainPID --value "$SVC")" 2>/dev/null || echo 0) / 1024 )); }
rows() { python3 - "$SD" <<'PY'
import sqlite3, glob, sys
t = 0
for db in glob.glob(f"{sys.argv[1]}/agents/*/agent/openclaw-agent.sqlite"):
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30); t += c.execute("select count(*) from session_nodes").fetchone()[0]; c.close()
print(t)
PY
}
main_uptime_h() {
  local start now
  start=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$SVC")
  now=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
  echo $(( (now - start) / 3600000000 ))
}

# Serialise the nightly unit and any manual run BEFORE the active check: two runs would both see main active,
# both stop it, and both run cleanup against the same SQLite stores while racing to start main. The lock dies
# with the process (fd 9), so a killed run can never wedge the next one. Unable to take the lock = abort with
# main untouched (and page); a held lock = another run is already doing this, skip.
exec 9>"$LOCK_FILE" || { log "ERROR cannot open lock $LOCK_FILE - aborting before any change"; exit 1; }
flock -n 9 || { log "another main-prune-restart run holds $LOCK_FILE - skip"; exit 0; }
if pgrep -f "scripts/(deploy|rollback).sh" >/dev/null; then log "deploy/rollback running - skip"; exit 0; fi
systemctl is-active --quiet "$SVC" || { log "main not active - skip (systemd/watchdog own that)"; exit 0; }
if [ "$MIN_UPTIME_H" -gt 0 ]; then
  up_h="${HYDRA_MAIN_UPTIME_H:-$(main_uptime_h)}"
  if [ "$up_h" -lt "$MIN_UPTIME_H" ]; then log "main up only ${up_h}h (< ${MIN_UPTIME_H}h) - already fresh, skip"; exit 0; fi
fi
log "start reason='$REASON' prune=$PRUNE rows_before=$(rows) rss=$(rss_mb)MB"
"$MAINT_SH" start "main session prune ($PRUNE) + restart: $REASON (MUS-1295)" --ttl 60m --operator hydra-main-prune-restart || log "WARN maintenance flag not set"

# 1. online backup (WAL-safe) while main still serves; keep the 2 newest. Failure aborts before any change.
mkdir -p "$BK" 2>/dev/null
python3 - "$SD" "$BK" <<'PY' || { log "backup FAILED - aborting before any change"; "$MAINT_SH" stop >/dev/null 2>&1; exit 1; }
import sqlite3, glob, os, sys
src, dst = sys.argv[1], sys.argv[2]
for db in glob.glob(f"{src}/agents/*/agent/openclaw-agent.sqlite") + [f"{src}/state/openclaw.sqlite"]:
    out = os.path.join(dst, os.path.relpath(db, src)); os.makedirs(os.path.dirname(out), exist_ok=True)
    s = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=60); d = sqlite3.connect(out); s.backup(d, pages=4096, sleep=0.002); d.close(); s.close()
PY
log "backup ok $BK ($(du -sh "$BK" | cut -f1))"
ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf

# 2. temp config = live config with only pruneAfter changed (live openclaw.json is NOT edited)
TC=$(mktemp -d "${TMPDIR:-/root}/.main-prune-cfg.XXXX"); cp "$SD/openclaw.json" "$TC/openclaw.json"
python3 - "$TC/openclaw.json" "$PRUNE" <<'PY'
import json, sys
p, v = sys.argv[1], sys.argv[2]; j = json.load(open(p)); j["session"]["maintenance"]["pruneAfter"] = v; json.dump(j, open(p, "w"))
PY

# 3. stop -> prune offline -> start. The prune's exit status is LOGGED and fails the unit afterwards, but never stops the start: fail-open.
# A stop that failed (or left main active) must NOT be pruned: cleanup would race the live gateway's
# writes on the same SQLite files. Skip the prune, leave main running, and fail the unit so it pages.
FAILED=0; prune_rc=0
s=$(date +%s); stop_rc=0; systemctl stop "$SVC" || stop_rc=$?
if [ "$stop_rc" -ne 0 ] || systemctl is-active --quiet "$SVC"; then
  log "ERROR stop failed (rc=$stop_rc, active=$(systemctl is-active "$SVC")) - NOT pruning a live store; main left as is"
  FAILED=1; prune_rc=skipped
else
  log "stopped in $(( $(date +%s)-s ))s"
fi
s=$(date +%s)
[ "$prune_rc" = skipped ] || env -i HOME=/root PATH="$PRUNE_PATH" OPENCLAW_STATE_DIR="$SD" OPENCLAW_CONFIG_PATH="$TC/openclaw.json" \
  timeout 1200 openclaw sessions cleanup --all-agents --enforce --json \
  > "$LOG_DIR/hydra-main-prune-$TS.json" 2> "$LOG_DIR/hydra-main-prune-$TS.err" || prune_rc=$?
rm -rf "$TC"
log "cleanup rc=$prune_rc secs=$(( $(date +%s)-s )) rows_after=$(rows)"
if [ "$prune_rc" != skipped ] && [ "$prune_rc" -ne 0 ]; then
  # Fail-open (main still starts below) but fail the unit once main is up, so OnFailure= pages: a prune that
  # fails every night lets rows climb back to the ~7k restart freeze with nothing else to say so.
  log "WARN prune failed (rc=$prune_rc, see $LOG_DIR/hydra-main-prune-$TS.err) - starting main anyway"
  FAILED=1
fi
start_rc=0; systemctl start "$SVC" || start_rc=$?
log "start issued rc=$start_rc (active=$(systemctl is-active "$SVC"))"
[ "$start_rc" -eq 0 ] || { log "ERROR systemctl start failed (rc=$start_rc) - not retrying"; FAILED=1; }

# 4. wait for STABLE health (200 continuously for STABLE_SECS), max MAX_WAIT_SECS. Never restarts again.
T0=$(date +%s); streak=""; stable=""; c=""
while [ $(( $(date +%s)-T0 )) -lt "$MAX_WAIT_SECS" ]; do
  c=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "$HEALTH_URL")
  t=$(( $(date +%s)-T0 ))
  if [ "$c" = 200 ]; then [ -z "$streak" ] && streak=$t; [ $((t-streak)) -ge "$STABLE_SECS" ] && { stable=$streak; break; }; else streak=""; fi
  sleep "$POLL_SECS"
done
if [ -n "$stable" ]; then log "RESULT OK stable 200 from ${stable}s after start; rss=$(rss_mb)MB"
else log "RESULT NOT STABLE after $((MAX_WAIT_SECS/60)) min (last=$c) - leaving it running, no further restart"; FAILED=1; fi
"$MAINT_SH" stop >/dev/null 2>&1 || true
# Exit non-zero when the prune, stop or start failed or health never stabilised, so the oneshot fails and
# OnFailure= pages; main has already been started first, so paging never costs availability.
exit "$FAILED"

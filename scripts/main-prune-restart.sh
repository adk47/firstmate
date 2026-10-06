#!/usr/bin/env bash
# scripts/main-prune-restart.sh -- offline session prune + restart of openclaw-gateway-main (MUS-1295).
# Scheduled by install-aux-units.sh (hydra-main-prune-restart.{service,timer}, 02:30 UTC); replaces the
# hand-placed /usr/local/sbin/hydra-main-{prune-restart,nightly-reset}.sh bridge.
# Why: main's cold start re-parses every session_nodes row per session lookup (MUS-2652), so cost scales with
# row count. At 14d retention (~7k rows) a restart froze /health 22-60 min; pruned to 24h (2737 rows) it was
# stable from 6.3 min (lab, 5 Oct).
# What: maintenance flag -> online backup -> stop main -> `openclaw sessions cleanup --enforce` offline with
# pruneAfter=$PRUNE on a TEMP config (live openclaw.json untouched) -> start main -> wait for STABLE health.
# FAIL-OPEN: a failed prune still starts main, once, never retried. A failed backup aborts before anything is
# stopped; a failed stop skips the prune. Exit non-zero (so OnFailure= pages) if the prune, stop or start
# failed or health never stabilised; main is started first, so paging never costs availability.
# Data rollback: $BACKUP_ROOT/<ts>/ (stop main, copy the .sqlite files back, start).
# One run at a time: flock on $LOCK_FILE, the SAME lock deploy.sh/rollback.sh take (lib/main-prune-lock.sh).
# Held from before the pgrep check through `systemctl start`, then released; a second run skips.
# Usage: main-prune-restart.sh [reason]; HYDRA_MAIN_MIN_UPTIME_H=N skips when main is younger (timer sets 4).
# The other env knobs exist so the bats suite can run the real script against stubs.
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
# TERM at 1200s, KILL 30s later: a cleanup that ignores TERM must not hold main stopped until systemd's 90 min.
CLEANUP_TIMEOUT_S="${CLEANUP_TIMEOUT_S:-1200}"; CLEANUP_KILL_AFTER_S="${CLEANUP_KILL_AFTER_S:-30}"
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

# One run at a time, BEFORE the active check. Lock dies with the process (fd 9). Cannot open = abort (pages); held = skip.
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

# 3. stop -> prune offline -> start. A prune failure is logged and fails the unit afterwards but never stops
# the start (fail-open). A stop that failed (or left main active) must NOT be pruned: skip it, fail the unit.
FAILED=0; prune_rc=0; RECOVER=0
# Armed from a successful stop until the normal start: a SIGTERM mid-cleanup must not leave main stopped unpaged.
recover_main() {
  [ "$RECOVER" -eq 1 ] || return 0
  RECOVER=0; log "interrupted after stopping main - starting it"; rm -rf "$TC"
  systemctl start "$SVC" || log "ERROR recovery start failed"
  "$MAINT_SH" stop >/dev/null 2>&1 || true
}
s=$(date +%s); stop_rc=0; systemctl stop "$SVC" || stop_rc=$?
if [ "$stop_rc" -ne 0 ] || systemctl is-active --quiet "$SVC"; then
  log "ERROR stop failed (rc=$stop_rc, active=$(systemctl is-active "$SVC")) - NOT pruning a live store; main left as is"
  FAILED=1; prune_rc=skipped
else
  log "stopped in $(( $(date +%s)-s ))s"
  RECOVER=1; trap recover_main EXIT   # bash runs the EXIT trap on SIGTERM/INT/HUP too
fi
s=$(date +%s)
[ "$prune_rc" = skipped ] || env -i HOME=/root PATH="$PRUNE_PATH" OPENCLAW_STATE_DIR="$SD" OPENCLAW_CONFIG_PATH="$TC/openclaw.json" \
  timeout --kill-after="$CLEANUP_KILL_AFTER_S" "$CLEANUP_TIMEOUT_S" openclaw sessions cleanup --all-agents --enforce --json \
  > "$LOG_DIR/hydra-main-prune-$TS.json" 2> "$LOG_DIR/hydra-main-prune-$TS.err" || prune_rc=$?
rm -rf "$TC"
log "cleanup rc=$prune_rc secs=$(( $(date +%s)-s )) rows_after=$(rows)"
if [ "$prune_rc" != skipped ] && [ "$prune_rc" -ne 0 ]; then
  # Fail-open (main still starts below), but fail the unit so OnFailure= pages (else rows climb back unnoticed).
  log "WARN prune failed (rc=$prune_rc, see $LOG_DIR/hydra-main-prune-$TS.err) - starting main anyway"
  FAILED=1
fi
start_rc=0; systemctl start "$SVC" || start_rc=$?; RECOVER=0
log "start issued rc=$start_rc (active=$(systemctl is-active "$SVC"))"
# The cleanup-vs-live-gateway race ends at start: release so a deploy is not held through the health wait.
exec 9>&-
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
# Non-zero when the prune, stop or start failed or health never stabilised: the oneshot fails, OnFailure= pages.
exit "$FAILED"

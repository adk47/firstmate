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
#   Backups mirror agents/<id>/agent/openclaw-agent.sqlite and state/openclaw.sqlite under $SD; the 2 NEWEST are kept,
#   rotated AFTER the new one is written, so peak disk is 3 snapshots (~7 GB each on 5 Oct). Restore, whole sequence
#   (cp while main runs corrupts the store):
#     B=/var/backups/hydra-main-sessions/<UTC-ts>; SD=/root/.openclaw-main
#     /opt/hydra/scripts/hydra-maintenance.sh start "restore main sessions" --ttl 60m --operator <you>
#     systemctl stop openclaw-gateway-main
#     (cd "$B" && find . -name '*.sqlite' | while read -r f; do rm -f "$SD/$f-wal" "$SD/$f-shm"; cp -p "$f" "$SD/$f"; done)
#     systemctl start openclaw-gateway-main
#     until [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:18789/health)" = 200 ]; do sleep 5; done
#     /opt/hydra/scripts/hydra-maintenance.sh stop
# Disarm without a revert: `systemctl disable --now hydra-main-prune-restart.timer`. The NEXT DEPLOY RE-ARMS IT
# (install-aux-units.sh enables + starts it and fails closed), so the only durable rollback is reverting the PR.
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
DEPLOY_PATH="${DEPLOY_PATH:-/opt/hydra}"   # same default as scripts/deploy.sh:21; the ssh-mode rsync target and the mutation marker live here
MARKER_MAX_AGE_MIN="${HYDRA_DEPLOY_MARKER_MAX_AGE_MIN:-120}"
REASON_MUT=""
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

# Someone other than us is mutating node-8 (MUS-8545 round 9 / MUS-8735 residual).
# The pgrep below only sees a LOCAL deploy; an ssh-mode deploy driven from a laptop leaves no deploy.sh process
# here, and TERMing that local ssh does not stop the command already running on node-8, so its remote tail can
# outlive the ssh that held our prune lock. Three signals: (1) and (2) are live and have no upper time bound;
# (3) covers the whole claim->clear window but its mtime is never refreshed (claim writes it once), so it goes
# blind past MARKER_MAX_AGE_MIN on purpose (a stranded marker must not disable the nightly prune forever; the
# timer fires once a night, so a stranded one costs at most one night). Past the bound only (1) and (2) remain.
# A deploy with a non-default DEPLOY_PATH would need this unit's environment updated too.
# No pipelines: `set -o pipefail` is on, so `pgrep ... | grep -q` would silently never fire.
deploy_mutating_node8() {
  local jobs rs marker
  jobs=$(systemctl list-jobs --no-legend 2>/dev/null || true)
  case "$jobs" in *openclaw-gateway-*)
    REASON_MUT="a systemd job is already operating a gateway: $(printf '%s' "$jobs" | tr '\n' ';')"; return 0 ;;
  esac
  rs=$(pgrep -af 'rsync --server' 2>/dev/null || true)
  case "$rs" in *"$DEPLOY_PATH/"*)
    REASON_MUT="a live rsync --server is writing $DEPLOY_PATH/ ($rs)"; return 0 ;;
  esac
  marker=$(find "$DEPLOY_PATH/.deploy-mutating" -mmin "-$MARKER_MAX_AGE_MIN" 2>/dev/null || true)
  if [ -n "$marker" ]; then
    REASON_MUT="$DEPLOY_PATH/.deploy-mutating is younger than ${MARKER_MAX_AGE_MIN}m (owner: $(head -n 1 "$DEPLOY_PATH/.deploy-mutating" 2>/dev/null | tr -d '[:space:]' || echo unreadable))"
    return 0
  fi
  return 1
}

# One run at a time, BEFORE the active check. Lock dies with the process (fd 9). Cannot open = abort (pages); held = skip.
exec 9>"$LOCK_FILE" || { log "ERROR cannot open lock $LOCK_FILE - aborting before any change"; exit 1; }
flock -n 9 || { log "another main-prune-restart run holds $LOCK_FILE - skip"; exit 0; }
if pgrep -f "scripts/(deploy|rollback).sh" >/dev/null; then log "deploy/rollback running - skip"; exit 0; fi
if deploy_mutating_node8; then log "WARN SKIP deploy-mutation-in-flight: $REASON_MUT - skip (nothing was changed)"; exit 0; fi
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
# Any prep failure aborts BEFORE main is stopped: a stopped main with no usable temp config restarts unpruned.
abort_prep() { log "temp config prep FAILED - aborting before main is stopped"; [ -z "${TC:-}" ] || rm -rf "$TC"; "$MAINT_SH" stop >/dev/null 2>&1; exit 1; }
TC=$(mktemp -d "${TMPDIR:-/root}/.main-prune-cfg.XXXX") || abort_prep
cp "$SD/openclaw.json" "$TC/openclaw.json" || abort_prep
python3 - "$TC/openclaw.json" "$PRUNE" <<'PY' || abort_prep
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
# Re-check: the online backup above is the longest pre-stop segment. The backup dir stays (the 2 newest are kept).
if deploy_mutating_node8; then
  log "WARN SKIP deploy-mutation-in-flight before stop: $REASON_MUT - main NOT stopped"
  rm -rf "$TC"; "$MAINT_SH" stop >/dev/null 2>&1 || true
  exit 0
fi
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

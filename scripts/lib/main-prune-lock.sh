#!/usr/bin/env bash
# scripts/lib/main-prune-lock.sh -- host-wide lock keeping deploy.sh / rollback.sh and main-prune-restart.sh
# from mutating node-8 at the same time (MUS-3742, CEO ruling on MUS-3814).
# A pgrep snapshot cannot be atomic: a deploy starting after the prune's check restarts main (deploy.sh Step 6,
# rollback.sh Step 2) while `openclaw sessions cleanup` is still writing the same SQLite stores. So both sides
# flock ONE file. The prune takes it non-blocking (skips while a deploy/rollback holds it); deploy/rollback take
# it blocking, ONCE, before their first mutation and hold it until they exit (not per restart: rollback.sh uses
# raw systemctl and deploy.sh restarts at several sites).
# Wait bound 1500s = the prune's hold (backup + stop + cleanup `timeout 1200` + start) plus margin. Its
# stable-health wait (<=45 min) is outside the lock, so a deploy never blocks ~67 min.
# fd hygiene: the lock is fd 213 of the deploy/rollback process. Nothing in deploy.sh, rollback.sh,
# lib/gateway-restart.sh or lib/deploy-mutation-marker.sh backgrounds a long-lived child (pinned by
# deploy-main-prune-lock.bats), so no child can keep the lock after exit; a new spawn there must close `213>&-`.
# Only meaningful on node-8 (HYDRA_LOCAL=true); in ssh mode callers log that the lock was not taken.

MAIN_PRUNE_LOCK_FILE="${MAIN_PRUNE_LOCK_FILE:-/run/lock/hydra-main-prune-restart.lock}"
MAIN_PRUNE_LOCK_WAIT_SECS="${MAIN_PRUNE_LOCK_WAIT_SECS:-1500}"

# rc 0 held; 1 timed out (a prune is still running); 2 lock file cannot be opened.
acquire_main_prune_lock() {
  { exec 213>"$MAIN_PRUNE_LOCK_FILE"; } 2>/dev/null || return 2
  flock -w "$MAIN_PRUNE_LOCK_WAIT_SECS" 213 || return 1
}

#!/usr/bin/env bash
# deploy-lock.sh — SOURCED, never executed. Per-host mutual-exclusion lock for
# deploy.sh, with stale-PID recovery. Portable mkdir-based locking: mkdir is
# atomic on every POSIX FS and, unlike flock, works on macOS without extra
# packages.
#
# Extracted from deploy.sh's inline block (incident 2026-07-01). The inline
# version did `mkdir_err=$(mkdir "$LOCK_DIR" 2>&1); mkdir_rc=$?` — but under
# `set -euo pipefail` the assignment's non-zero status (EEXIST when a lock dir
# already exists) tripped `set -e` and EXITED the script BEFORE the stale-PID
# recovery below could run. So the recovery was dead code, and a single
# orphaned lock (from a SIGKILL'd/cancelled deploy) wedged EVERY subsequent
# deploy until an operator manually removed it. Here the same `mkdir` result is
# captured with `|| mkdir_rc=$?`, which is a compound-list context `set -e`
# ignores — so recovery is reachable. Unit-tested: scripts/tests/deploy-lock.bats.
#
# Contract (self-contained: no dependency on deploy.sh's log/fail):
#   acquire_deploy_lock <dir>  -> 0 = acquired (this PID written to <dir>/pid);
#                                 non-zero + a message on stderr = refused.
#       return 1: lock dir could not be created for a non-EEXIST reason
#                 (permission denied, ENOSPC, EROFS, …).
#       return 2: a LIVE deploy already holds the lock (holder PID is alive).
#       return 3: cleared a stale lock but could not re-acquire it.
#       return 4: lock dir exists but has no pid file (another deploy is
#                 mid-acquisition, or one was killed between mkdir and writing
#                 pid) — refuse rather than guess.
#   release_deploy_lock <dir>  -> remove the lock dir (idempotent).

acquire_deploy_lock() {
  local dir="$1"
  local mkdir_rc=0 mkdir_err
  # The fix: `|| mkdir_rc=$?` keeps the failing assignment out of `set -e`'s
  # reach so the recovery block below actually runs on EEXIST.
  mkdir_err=$(mkdir "$dir" 2>&1) || mkdir_rc=$?
  if (( mkdir_rc != 0 )); then
    # Distinguish "lock dir already exists" (EEXIST → check for stale) from
    # other failures (permission denied, ENOSPC, EROFS, …). Without this,
    # all of those would fall into the stale-recovery path with a misleading
    # error.
    if [[ ! -d "$dir" ]]; then
      echo "deploy-lock: could not create lock dir at $dir: $mkdir_err" >&2
      return 1
    fi
    # Lock dir exists. Try stale-PID recovery.
    if [[ -f "$dir/pid" ]]; then
      local holder_pid
      holder_pid=$(cat "$dir/pid" 2>/dev/null || true)
      # Validate the pid is a positive integer before passing to kill -0, so a
      # corrupted/empty pid file doesn't get misinterpreted as a live holder.
      if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
        echo "deploy-lock: another deploy is already running (lock: $dir, holder PID: $holder_pid)" >&2
        return 2
      fi
      echo "deploy-lock: stale deploy lock found (holder PID '$holder_pid' is dead or invalid) — clearing" >&2
      rm -rf "$dir"
      if ! mkdir "$dir" 2>/dev/null; then
        echo "deploy-lock: failed to re-acquire deploy lock after clearing stale: $dir" >&2
        return 3
      fi
    else
      # Lock dir exists but pid file does not: another deploy mid-acquisition
      # (microsecond race between mkdir and writing pid) or one SIGKILL'd in
      # that window. Refuse rather than guess — manual cleanup is the fix.
      echo "deploy-lock: lock at $dir exists but has no pid file (another deploy mid-acquisition, or a prior deploy was killed before writing pid). If you're sure no deploy is running, remove it manually: rm -rf $dir" >&2
      return 4
    fi
  fi
  echo $$ > "$dir/pid"
  return 0
}

release_deploy_lock() {
  local dir="$1"
  rm -rf "$dir"
}

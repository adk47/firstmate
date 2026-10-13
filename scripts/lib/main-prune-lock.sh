#!/usr/bin/env bash
# scripts/lib/main-prune-lock.sh -- host-wide lock keeping deploy.sh / rollback.sh and main-prune-restart.sh
# from mutating node-8 at the same time (MUS-3742, CEO ruling on MUS-3814).
# A pgrep snapshot cannot be atomic: a deploy starting after the prune's check restarts main (deploy.sh Step 6,
# rollback.sh Step 2) while `openclaw sessions cleanup` is still writing the same SQLite stores. So both sides
# flock ONE file. The prune takes it non-blocking (skips while a deploy/rollback holds it); deploy/rollback take
# it blocking, ONCE, before their first mutation and hold it until they exit (not per restart: rollback.sh uses
# raw systemctl and deploy.sh restarts at several sites).
# Wait bound 1500s = the prune's hold (backup + stop + cleanup 1200s TERM + 30s KILL + start) + margin; its health wait
# (<=45 min) is outside the lock. fd hygiene: the lock is fd 213 of the deploy/rollback process; nothing in
# deploy.sh, rollback.sh, lib/gateway-restart.sh or lib/deploy-mutation-marker.sh backgrounds a long-lived child
# (pinned by main-prune-restart.bats), so none can keep it after exit; a new spawn there must close `213>&-`.
# On node-8 (HYDRA_LOCAL=true) callers use acquire_main_prune_lock; in ssh mode, acquire_main_prune_lock_remote (below).

MAIN_PRUNE_LOCK_FILE="${MAIN_PRUNE_LOCK_FILE:-/run/lock/hydra-main-prune-restart.lock}"
MAIN_PRUNE_LOCK_WAIT_SECS="${MAIN_PRUNE_LOCK_WAIT_SECS:-1500}"

# rc 0 held; 1 timed out (a prune is still running); 2 lock file cannot be opened.
acquire_main_prune_lock() {
  { exec 213>"$MAIN_PRUNE_LOCK_FILE"; } 2>/dev/null || return 2
  flock -w "$MAIN_PRUNE_LOCK_WAIT_SECS" 213 || return 1
}

# ssh mode (laptop deploy/rollback): the lock has to be held ON node-8, or the prune there cannot see us. Start a
# background ssh that takes the same flock remotely and then blocks reading stdin; stdin is a FIFO this shell keeps
# open on fd 214, so the remote lock lives exactly as long as this process (exit, kill or lost link close the FIFO,
# `cat` gets EOF/SIGHUP, the lock drops). Plain FIFO + polling, no coproc: macOS ships bash 3.2.
# Args: the ssh command and its options up to and including user@host. rc 0 held; 1 timed out or the ssh failed
# (a prune may still run; the remote flock itself exits 1 on timeout); 2 local setup failed.
acquire_main_prune_lock_remote() {
  local tmp wait_secs="$MAIN_PRUNE_LOCK_WAIT_SECS" i=0 parent=$$
  tmp="$(mktemp -d 2>/dev/null)" || return 2
  mkfifo "$tmp/in" || { rm -rf "$tmp"; return 2; }
  "$@" "exec 9>'$MAIN_PRUNE_LOCK_FILE' && flock -w $wait_secs 9 && echo LOCKED && exec cat >/dev/null" \
    <"$tmp/in" >"$tmp/out" 2>"$tmp/err" &
  MAIN_PRUNE_LOCK_REMOTE_PID=$!
  exec 214>"$tmp/in"
  while ! grep -q '^LOCKED$' "$tmp/out" 2>/dev/null; do
    if ! kill -0 "$MAIN_PRUNE_LOCK_REMOTE_PID" 2>/dev/null; then
      cat "$tmp/err" >&2 2>/dev/null
      exec 214>&-; rm -rf "$tmp"; return 1
    fi
    i=$((i + 1)); [ "$i" -gt $((wait_secs * 5 + 300)) ] && { kill "$MAIN_PRUNE_LOCK_REMOTE_PID" 2>/dev/null; exec 214>&-; rm -rf "$tmp"; return 1; }
    sleep 0.2
  done
  # The lock is only as live as that ssh. Once it dies (link drop, node-8 reboot) the prune may take the lock while we
  # keep mutating, so a watcher couples the two: ssh gone -> flag file + SIGTERM to this process (fail closed). It exits
  # when this process does. fd 214 is closed in it so it never keeps the remote lock alive past our exit.
  MAIN_PRUNE_LOCK_LOST_FILE="$tmp/lost"
  rm -f "$tmp/in" "$tmp/out" "$tmp/err"
  (
    exec 214>&- </dev/null >/dev/null
    self=$(sh -c 'echo $PPID')  # this subshell (bash 3.2 has no BASHPID); it is a child of $parent and must not signal itself
    while kill -0 "$MAIN_PRUNE_LOCK_REMOTE_PID" 2>/dev/null; do
      kill -0 "$parent" 2>/dev/null || { rm -rf "$tmp"; exit 0; }
      sleep "${MAIN_PRUNE_LOCK_WATCH_SECS:-1}"
    done
    kill -0 "$parent" 2>/dev/null || { rm -rf "$tmp"; exit 0; }
    : >"$tmp/lost"
    echo "FATAL: the ssh holding the main prune lock on node-8 died; aborting so we do not mutate without the lock" >&2
    # A foreground child (rsync, ssh, systemctl) outlives a TERMed parent -- bash defers the signal until the child ends --
    # and keeps mutating node-8 while the prune takes the freed lock. Stop the parent's descendant tree first (pids walked
    # with pgrep -P only, never a process group: deploy/rollback share the caller's pgid), TERM then KILL stragglers, and
    # only then TERM the parent. The flag above stays first: killing the child makes the parent's EXIT path run at once.
    # The parent is frozen (STOP) while its children die: under an errexit-suppressed step (`cmd || handler`, `if`) it
    # would otherwise start the NEXT foreground child in the gap before our TERM lands, and nothing would stop that one.
    kill -STOP "$parent" 2>/dev/null
    kids=$(_main_prune_lock_descendants "$parent" "$self")
    # shellcheck disable=SC2086  # pids, word-split on purpose
    if [ -n "$kids" ]; then
      kill -TERM $kids 2>/dev/null
      i=0
      while [ "$i" -lt "${MAIN_PRUNE_LOCK_KILL_WAIT_TICKS:-30}" ]; do
        alive=
        for k in $kids; do kill -0 "$k" 2>/dev/null && alive=1; done
        [ -z "$alive" ] && break
        i=$((i + 1)); sleep 0.1
      done
      kill -KILL $kids 2>/dev/null
    fi
    kill -TERM "$parent" 2>/dev/null
    kill -CONT "$parent" 2>/dev/null  # the pending TERM is delivered on resume
  ) &
}

# Print the pids of every descendant of $1, skipping $2 (the watcher) and whatever hangs under it.
_main_prune_lock_descendants() {
  local kid
  for kid in $(pgrep -P "$1" 2>/dev/null); do
    [ "$kid" = "$2" ] && continue
    echo "$kid"
    _main_prune_lock_descendants "$kid" "$2"
  done
}

# True once the remote lock watcher has fired (callers' EXIT backstops must not start main unlocked after that).
main_prune_lock_lost() { [ -n "${MAIN_PRUNE_LOCK_LOST_FILE:-}" ] && [ -e "$MAIN_PRUNE_LOCK_LOST_FILE" ]; }

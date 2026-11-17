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
# Fable [key=signed-on-sha] (QA #1604): when DEPLOY_APPLY_LOCK_FILE is set (deploy.sh sets it; rollback does not), the
# same holder ALSO takes the credit-message apply lock EXCLUSIVELY, held with the prune lock for the whole deploy: an
# apply in flight (it holds the lock shared) is WAITED for, up to DEPLOY_APPLY_LOCK_WAIT_SECS, and only then refuses the
# deploy (rc 3, nothing changed); no apply can start while the deploy mutates node-8 (an apply's shared non-blocking take
# fails and it sends nothing).
#
# Contract: prune, then tick, then apply, each a bounded `flock -w` wait (never a non-blocking refusal on first sight).
# rc 0 all held; 1 the prune lock timed out; 2 a lock file could not be opened (MAIN_PRUNE_LOCK_OPEN_FAILED names it);
# 3 the apply lock timed out; 4 the tick lock timed out.
DEPLOY_APPLY_LOCK_FILE="${DEPLOY_APPLY_LOCK_FILE:-}"
# firstmate 073 (2026-11-16): deploy 6 (run 43807967494) was dispatched at 05:05:23Z with apply.lock free and refused at
# 05:11:00Z because an apply had started in the six minutes between - a whole deploy window lost to one sighting. Waiting
# (bounded) instead of refusing on first sight means a tick that starts between dispatch and deploy only delays it.
# The prune lock is already held during this wait, so nothing else mutates node-8 meanwhile.
DEPLOY_APPLY_LOCK_WAIT_SECS="${DEPLOY_APPLY_LOCK_WAIT_SECS:-600}"
# firstmate 074 (2026-11-16): the deploy used to SLEEP to the next tick boundary with no lock held, then look again -
# which walked every dispatch into that tick's first apply (run 43807967494: slept 329s 05:05:31->05:11:00, met the
# 05:0x apply, refused). Now the deploy takes the outbound tick's own flock (credit-verify-outbound.sh fd 9) EXCLUSIVELY,
# waiting for an in-flight tick up to DEPLOY_TICK_LOCK_WAIT_SECS, BEFORE the apply lock, and holds both until it exits:
# a tick that fires mid-deploy finds the lock held and exits (its own "another tick holds" path), the next fire runs.
# Order prune -> tick -> apply; the tick never WAITS on the apply lock (it takes it shared non-blocking), so no cycle.
# When DEPLOY_TICK_LOCK_FILE is unset (rollback.sh) nothing changes. rc 4 = a tick still held it after the wait.
DEPLOY_TICK_LOCK_FILE="${DEPLOY_TICK_LOCK_FILE:-}"
DEPLOY_TICK_LOCK_WAIT_SECS="${DEPLOY_TICK_LOCK_WAIT_SECS:-600}"
# set by the acquire functions: seconds spent waiting for each lock ('' = not taken)
DEPLOY_TICK_LOCK_WAITED=""
DEPLOY_APPLY_LOCK_WAITED=""
# set on rc 2: the lock file that could not be opened
MAIN_PRUNE_LOCK_OPEN_FAILED=""

# rc 0 held; 1 timed out (a prune is still running); 2 lock file cannot be opened; 3 a credit-message apply was still in
# flight after DEPLOY_APPLY_LOCK_WAIT_SECS; 4 an outbound tick was still in flight after DEPLOY_TICK_LOCK_WAIT_SECS.
acquire_main_prune_lock() {
  local t0
  { exec 213>"$MAIN_PRUNE_LOCK_FILE"; } 2>/dev/null || { MAIN_PRUNE_LOCK_OPEN_FAILED="$MAIN_PRUNE_LOCK_FILE"; return 2; }
  flock -w "$MAIN_PRUNE_LOCK_WAIT_SECS" 213 || return 1
  if [ -n "$DEPLOY_TICK_LOCK_FILE" ]; then
    mkdir -p "$(dirname "$DEPLOY_TICK_LOCK_FILE")" 2>/dev/null
    { exec 216>>"$DEPLOY_TICK_LOCK_FILE"; } 2>/dev/null || { MAIN_PRUNE_LOCK_OPEN_FAILED="$DEPLOY_TICK_LOCK_FILE"; return 2; }
    t0=$(date +%s)
    flock -w "$DEPLOY_TICK_LOCK_WAIT_SECS" -x 216 || { DEPLOY_TICK_LOCK_WAITED=$(( $(date +%s) - t0 )); return 4; }
    DEPLOY_TICK_LOCK_WAITED=$(( $(date +%s) - t0 ))
    # the tick reads this file to say who holds its lock; name the deploy, not the last tick
    printf 'deploy:%s %s\n' "$$" "$(date +%s)" > "$(dirname "$DEPLOY_TICK_LOCK_FILE")/tick.holder" 2>/dev/null || true
  fi
  if [ -n "$DEPLOY_APPLY_LOCK_FILE" ]; then
    mkdir -p "$(dirname "$DEPLOY_APPLY_LOCK_FILE")" 2>/dev/null
    { exec 215>>"$DEPLOY_APPLY_LOCK_FILE"; } 2>/dev/null || { MAIN_PRUNE_LOCK_OPEN_FAILED="$DEPLOY_APPLY_LOCK_FILE"; return 2; }
    t0=$(date +%s)
    flock -w "$DEPLOY_APPLY_LOCK_WAIT_SECS" -x 215 || { DEPLOY_APPLY_LOCK_WAITED=$(( $(date +%s) - t0 )); return 3; }
    DEPLOY_APPLY_LOCK_WAITED=$(( $(date +%s) - t0 ))
  fi
  return 0
}

# ssh mode (laptop deploy/rollback): the lock has to be held ON node-8, or the prune there cannot see us. Start a
# background ssh that takes the same flock remotely and then blocks reading stdin; stdin is a FIFO this shell keeps
# open on fd 214, so the remote lock lives exactly as long as this process (exit, kill or lost link close the FIFO,
# `cat` gets EOF/SIGHUP, the lock drops). Plain FIFO + polling, no coproc: macOS ships bash 3.2.
# Args: the ssh command and its options up to and including user@host. rc 0 held; 1 timed out or the ssh failed
# (a prune may still run; the remote flock itself exits 1 on timeout); 2 local setup failed.
acquire_main_prune_lock_remote() {
  local tmp wait_secs="$MAIN_PRUNE_LOCK_WAIT_SECS" apply_wait=0 tick_wait=0 i=0 parent=$$
  [ -z "$DEPLOY_APPLY_LOCK_FILE" ] || apply_wait="$DEPLOY_APPLY_LOCK_WAIT_SECS"
  [ -z "$DEPLOY_TICK_LOCK_FILE" ] || tick_wait="$DEPLOY_TICK_LOCK_WAIT_SECS"
  # mktemp-ok: every failure return rm -rf's it; on success the watcher subshell removes it when this process exits (no trap: it would clobber the caller's)
  tmp="$(mktemp -d 2>/dev/null)" || return 2
  mkfifo "$tmp/in" || { rm -rf "$tmp"; return 2; }
  local apply_take="" tick_take="" tick_dir prune_take
  # each take prints "<NAME>_WAITED <seconds>" (or <NAME>_BUSY and exits) so the caller can log what it waited for;
  # an unopenable lock file prints "OPEN_FAILED <path>" and exits 2 so the caller names the right file
  prune_take="( : >>'$MAIN_PRUNE_LOCK_FILE' ) 2>/dev/null || { echo OPEN_FAILED '$MAIN_PRUNE_LOCK_FILE'; exit 2; }; exec 9>'$MAIN_PRUNE_LOCK_FILE' && "
  [ -z "$DEPLOY_APPLY_LOCK_FILE" ] || apply_take="mkdir -p '$(dirname "$DEPLOY_APPLY_LOCK_FILE")' 2>/dev/null || { echo OPEN_FAILED '$DEPLOY_APPLY_LOCK_FILE'; exit 2; }; { ( : >>'$DEPLOY_APPLY_LOCK_FILE' ) 2>/dev/null || { echo OPEN_FAILED '$DEPLOY_APPLY_LOCK_FILE'; exit 2; }; } && exec 8>>'$DEPLOY_APPLY_LOCK_FILE' && t0=\$(date +%s) && { flock -w $apply_wait -x 8 || { echo APPLY_WAITED \$(( \$(date +%s) - t0 )); echo APPLY_BUSY; exit 3; }; } && echo APPLY_WAITED \$(( \$(date +%s) - t0 )) && "
  if [ -n "$DEPLOY_TICK_LOCK_FILE" ]; then
    tick_dir="$(dirname "$DEPLOY_TICK_LOCK_FILE")"
    tick_take="mkdir -p '$tick_dir' 2>/dev/null || { echo OPEN_FAILED '$DEPLOY_TICK_LOCK_FILE'; exit 2; }; { ( : >>'$DEPLOY_TICK_LOCK_FILE' ) 2>/dev/null || { echo OPEN_FAILED '$DEPLOY_TICK_LOCK_FILE'; exit 2; }; } && exec 7>>'$DEPLOY_TICK_LOCK_FILE' && t0=\$(date +%s) && { flock -w $tick_wait -x 7 || { echo TICK_WAITED \$(( \$(date +%s) - t0 )); echo TICK_BUSY; exit 4; }; } && echo TICK_WAITED \$(( \$(date +%s) - t0 )) && { printf 'deploy:%s %s\\n' \$\$ \$(date +%s) > '$tick_dir/tick.holder' 2>/dev/null || true; } && "
  fi
  "$@" "${prune_take}flock -w $wait_secs 9 && ${tick_take}${apply_take}echo LOCKED && exec cat >/dev/null" \
    <"$tmp/in" >"$tmp/out" 2>"$tmp/err" &
  MAIN_PRUNE_LOCK_REMOTE_PID=$!
  exec 214>"$tmp/in"
  while ! grep -q '^LOCKED$' "$tmp/out" 2>/dev/null; do
    if ! kill -0 "$MAIN_PRUNE_LOCK_REMOTE_PID" 2>/dev/null; then
      cat "$tmp/err" >&2 2>/dev/null
      _main_prune_lock_read_waits "$tmp/out"
      if grep -q '^OPEN_FAILED ' "$tmp/out" 2>/dev/null; then
        # shellcheck disable=SC2034  # read by deploy.sh, which sources this file
        MAIN_PRUNE_LOCK_OPEN_FAILED=$(sed -n 's/^OPEN_FAILED //p' "$tmp/out" | tail -1)
        exec 214>&-; rm -rf "$tmp"; return 2
      fi
      if grep -q '^TICK_BUSY$' "$tmp/out" 2>/dev/null; then exec 214>&-; rm -rf "$tmp"; return 4; fi
      if grep -q '^APPLY_BUSY$' "$tmp/out" 2>/dev/null; then exec 214>&-; rm -rf "$tmp"; return 3; fi
      exec 214>&-; rm -rf "$tmp"; return 1
    fi
    i=$((i + 1)); [ "$i" -gt $(((wait_secs + tick_wait + apply_wait) * 5 + 300)) ] && { kill "$MAIN_PRUNE_LOCK_REMOTE_PID" 2>/dev/null; exec 214>&-; rm -rf "$tmp"; return 1; }
    sleep 0.2
  done
  # The lock is only as live as that ssh. Once it dies (link drop, node-8 reboot) the prune may take the lock while we
  # keep mutating, so a watcher couples the two: ssh gone -> flag file + SIGTERM to this process (fail closed). It exits
  # when this process does. fd 214 is closed in it so it never keeps the remote lock alive past our exit.
  MAIN_PRUNE_LOCK_LOST_FILE="$tmp/lost"
  _main_prune_lock_read_waits "$tmp/out"
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

# Read the remote take's "<NAME>_WAITED <s>" lines into DEPLOY_TICK_LOCK_WAITED / DEPLOY_APPLY_LOCK_WAITED.
# shellcheck disable=SC2034  # the WAITED vars are read by deploy.sh, which sources this file
_main_prune_lock_read_waits() {
  local v
  v=$(sed -n 's/^TICK_WAITED \([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | tail -1); [ -z "$v" ] || DEPLOY_TICK_LOCK_WAITED="$v"
  v=$(sed -n 's/^APPLY_WAITED \([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | tail -1); [ -z "$v" ] || DEPLOY_APPLY_LOCK_WAITED="$v"
  return 0
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

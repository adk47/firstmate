#!/usr/bin/env bash
# Evidence harness: drive the real watcher (bin/fm-watch.sh) over two idle
# worker fixtures and print what an end user sees in the wake output.
#   A) a worker whose status line declares a future wake time -> quiet on first
#      sight, then re-surfaced as a pause recheck that prints the wait's own
#      deadline and remaining minutes, never "possible wedge".
#   B) a worker gone quiet with no declared wait -> alarms with "possible wedge".
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7VTDJKZPGSMAM91445J364A
cd "$ROOT" || exit 1
umask 022
# tests/lib.sh and tests/wake-helpers.sh are the same fixtures the suite uses.
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-label-evidence)

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *) stat -c '%s:%Y' "$1" 2>/dev/null ;;
  esac
}
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_poll_cycle() {
  local state=$1 pid=$2 limit=${3:-300} beat first now changes=0 i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      changes=$((changes + 1))
      first=$now
      [ "$changes" -ge 2 ] && return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
ack_stopped_cycle() {
  local state=$1 err sequence generation
  err="$state/.evidence-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation"
}

deadline=$(date -u -d '+90 minutes' +%Y-%m-%dT%H:%M 2>/dev/null || date -u -v+90M +%Y-%m-%dT%H:%M)
echo "=== Scenario A: worker whose status declares a future wait (until ${deadline}Z) ==="
dir=$(make_case evidence-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
window="test:fm-held"
printf 'idle, holding for upstream' > "$capture_file"
printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
printf 'paused: holding for the upstream tool release until %sZ\n' "$deadline" > "$statusf"
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(hash_text "idle, holding for upstream")
printf '%s' "$pane_hash" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
pid=$!
wait_poll_cycle "$state" "$pid" || { reap "$pid"; echo "FAIL: watcher did not complete a poll cycle"; exit 1; }
reap "$pid"
echo "--- first sight of the declared wait (should print nothing: absorbed) ---"
if [ -s "$out" ]; then cat "$out"; else echo "(no wake output)"; fi
ack_stopped_cycle "$state" || { echo "FAIL: could not acknowledge cycle"; exit 1; }

back=$(( $(date +%s) - 500 ))
touch -m -d "@$back" "$statusf" 2>/dev/null || touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
: > "$out"
printf 'idle, holding for upstream (token 2)' > "$capture_file"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
pid=$!
wait_for_exit "$pid" 100 || { echo "FAIL: watcher did not re-surface the aged declared wait"; cat "$out"; exit 1; }
echo "--- pause recheck after the re-surface threshold (should name the deadline, not a wedge) ---"
cat "$out"
echo

echo "=== Scenario B: worker gone quiet with NO declared wait ==="
dir=$(make_case evidence-undeclared-quiet); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; capture_file="$dir/pane.txt"
window="test:fm-stopped"
printf 'idle prompt, finished' > "$capture_file"
printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
printf 'working: implementing\n' > "$state/stopped.status"
sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(hash_text "idle prompt, finished")
printf '%s' "$pane_hash" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
pid=$!
wait_for_exit "$pid" 100 || { echo "FAIL: watcher did not surface the undeclared quiet worker"; cat "$out"; exit 1; }
cat "$out"

echo
echo "=== Scenario C (contrast): provably-working quiet worker with NO declared wait, past the wedge timer ==="
dir=$(make_case evidence-quiet-wedge); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; capture_file="$dir/pane.txt"
window="test:fm-quiet"
printf 'idle building output' > "$capture_file"
printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
printf 'working: still compiling\n' > "$state/quiet.status"
sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
key=$(printf '%s' "$window" | tr ':/.' '___')
pane_hash=$(hash_text "idle building output")
printf '%s' "$pane_hash" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
# Phase A: first sighting is absorbed (provably working, below the threshold).
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
pid=$!
wait_poll_cycle "$state" "$pid" || { echo "FAIL: phase A did not complete"; reap "$pid"; exit 1; }
reap "$pid"
ack_stopped_cycle "$state" || { echo "FAIL: could not acknowledge phase A"; exit 1; }
# Phase B: the wedge timer has elapsed, so the undeclared quiet worker escalates.
echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
: > "$out"
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
pid=$!
wait_for_exit "$pid" 100 || { echo "FAIL: watcher did not wedge-escalate the undeclared quiet worker"; cat "$out"; exit 1; }
cat "$out"

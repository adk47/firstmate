#!/usr/bin/env bash
# tests/fm-watch-secondmate-wake-stall.test.sh - the secondmate wake-loop stall
# rung (bin/fm-watch.sh secondmate_wake_stall_tick) must not be satisfiable by
# the ordinary behaviour it detects.
#
# A mate drains its own wake queue at TURN START only, so any single turn longer
# than SECONDMATE_WAKE_STALL_SECS (a build, a test sweep, a review, a merge)
# leaves an aged foreign row behind while the mate is provably mid-turn. The
# rung therefore suppresses itself ONLY on a positive busy read through the same
# semantic busy contract stale detection uses, and reports in every other case:
# an idle-or-unknown pane, and a pane that cannot be captured at all.
#
# Each case is wired through exactly one gate so a regression in that gate alone
# fails it:
#   busy-contract-busy  -> silent, and no marker/receipt side effect that would
#                          suppress a later real stall
#   busy-contract-idle  -> reports with the unchanged reason text
#   capture failure     -> reports (a mate that cannot be read is never exempt)
#
# Fixtures are driven through bin/fm-watch-checkpoint.sh, the same foreground
# checkpoint harness its neighbours (fm-wake-queue.test.sh) use, with a fake
# tmux that owns the pane bytes. Nothing here is timing-sensitive beyond a
# generous checkpoint window: the age threshold is 1s and the seeded row is 10s
# old, so the rung's own age gate is never the thing under test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-secondmate-wake-stall)

# make_stall_case <name> <pane-file> <capture-fails 0|1>
# Builds one secondmate fixture: a recorded foreign mate with one aged wake row
# in its own home, a parent meta naming its endpoint, and a fake tmux that
# serves <pane-file> as the captured pane (or exits non-zero when the capture is
# meant to fail). Echoes the case dir.
make_stall_case() {  # <name> <pane-file> <capture-fails>
  local name=$1 pane=$2 fails=$3 dir state sub fakebin
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$sub/state" "$fakebin"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  # One aged, structurally valid foreign row: this is exactly what a mate's
  # queue looks like while it is mid-turn on that row.
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" \
    > "$sub/state/.wake-queue"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane)
    [ "$fails" = 1 ] && exit 1
    cat "$pane"
    ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# run_stall_checkpoint <dir> <seconds> <out-file>: one bounded watcher cycle.
run_stall_checkpoint() {  # <dir> <seconds> <out>
  local dir=$1 seconds=$2 out=$3
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_SECONDMATE_WAKE_STALL_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds "$seconds" > "$out" 2> "$dir/watch.err" || true
}

# A mate provably mid-turn on an aged row: the rung stays silent, publishes
# nothing durable, and leaves no marker or receipt that would later hide a real
# stall on the same mate.
test_busy_mate_on_aged_row_stays_silent() {
  local dir state pane out
  pane="$TMP_ROOT/busy-pane.txt"
  mkdir -p "$TMP_ROOT"
  printf 'Working... (279k context)\n' > "$pane"
  dir=$(make_stall_case busy-mate "$pane" 0)
  state="$dir/state"
  out="$dir/watch.out"
  # The ONE gate this case turns on: a valid, gen-matching, source-trusted busy
  # record for the mate's recorded harness (claude). The pane bytes themselves
  # are irrelevant to a converted adapter's verdict.
  printf 'g-busy.1.1\n' > "$state/mate.busy-gen"
  printf 'v1 gen=g-busy.1.1 seq=1 state=busy source=claude-hook event=turn ts=%s\n' \
    "$(date +%s)" > "$state/mate.busy-state"

  run_stall_checkpoint "$dir" 6 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "a provably busy mate reported a wake-loop stall: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a provably busy mate still published a durable parent notification"
  [ ! -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "a suppressed busy row still wrote the marker that hides a later real stall"
  [ ! -e "$state/.secondmate-wake-stall-receipts/mate" ] \
    || fail "a suppressed busy row still wrote a stall receipt"
  pass "an aged foreign row on a provably busy mate stays silent with no side effect"
}

# An idle mate on an aged row is a genuine stall and keeps the exact reason text,
# marker, receipt, and durable publication it has today.
test_idle_mate_on_aged_row_reports() {
  local dir state out
  dir=$(make_stall_case idle-mate "$TMP_ROOT/idle-pane.txt" 0)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'Idle\n' > "$TMP_ROOT/idle-pane.txt"
  printf 'g-idle.1.1\n' > "$state/mate.busy-gen"
  printf 'v1 gen=g-idle.1.1 seq=1 state=idle source=claude-hook event=stop ts=%s\n' \
    "$(date +%s)" > "$state/mate.busy-state"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "an idle mate's aged row did not report: $(cat "$out"); err=$(cat "$dir/watch.err")"
  grep -E 'check: secondmate wake-loop stalled: mate=mate row=7 age=[0-9]+s$' "$out" >/dev/null \
    || fail "the reported reason text changed shape: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "the idle mate's stall was not published durably"
  [ -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "the idle mate's stall wrote no marker, so it would repeat every poll"
  pass "an idle mate's aged row reports with the unchanged reason, marker, and publication"
}

# A mate whose pane cannot be read is never exempt: an unprovable busy read falls
# through to the ordinary report.
test_unreadable_mate_on_aged_row_reports() {
  local dir state out
  dir=$(make_stall_case capture-failure "$TMP_ROOT/unreadable-pane.txt" 1)
  state="$dir/state"
  out="$dir/watch.out"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "a mate whose pane could not be captured was silently exempted: $(cat "$out"); err=$(cat "$dir/watch.err")"
  [ -s "$state/.wake-queue" ] \
    || fail "an uncapturable mate's stall was not published durably"
  pass "a failed pane capture still reports the stall"
}

test_busy_mate_on_aged_row_stays_silent
test_idle_mate_on_aged_row_reports
test_unreadable_mate_on_aged_row_reports

echo "# all fm-watch-secondmate-wake-stall tests passed"

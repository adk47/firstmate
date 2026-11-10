#!/usr/bin/env bash
# tests/fm-watch-secondmate-wake-stall.test.sh - the secondmate wake-loop stall
# rung (bin/fm-watch.sh secondmate_wake_stall_tick) must not be satisfiable by
# the ordinary behaviour it detects.
#
# A mate drains its own wake queue at TURN START only, so any single turn longer
# than SECONDMATE_WAKE_STALL_SECS (a build, a test sweep, a review, a merge)
# leaves an aged foreign row behind while the mate is provably mid-turn. Mate
# launches do not currently arm the semantic busy contract, so the rung reports
# ONLY on an idle verdict from a semantic source that proves the mate is not
# working; a busy verdict is ordinary mid-turn work, and every unprovable read
# (unknown, missing, dead, empty, or failed capture) stays silent. Rendered-text
# fallback verdicts (grok-regex, rovo-regex) are not proof and stay silent too.
#
# Each case is wired through exactly one gate so a regression in that gate alone
# fails it:
#   unarmed production layout -> silent (the reported false-stall defect)
#   busy-contract-idle        -> reports with the unchanged reason text
#   busy-contract-busy        -> silent, and no marker/receipt side effect
#   capture failure           -> semantic idle still reports (capture is not proof)
#   grok rendered fallback    -> silent (a rendered-text idle is not proof)
#
# Busy records are produced through the REAL writer, bin/fm-busy-event.sh arm
# and apply, the same calls fm-spawn makes for a crew window. No test
# hand-writes a busy record into any state directory.
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
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-secondmate-wake-stall)

# make_stall_case <name> <pane-file> <capture-fails> [harness]
# Builds one secondmate fixture: a recorded foreign mate with one aged wake row
# in its own home, a parent meta naming its endpoint, and a fake tmux that
# serves <pane-file> as the captured pane (or exits non-zero when the capture is
# meant to fail). Echoes the case dir.
make_stall_case() {  # <name> <pane-file> <capture-fails> [harness]
  local name=$1 pane=$2 fails=$3 harness=${4:-claude} dir state sub fakebin
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$sub/state" "$fakebin"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=%s\nbackend=tmux\nhome=%s\n' \
    "$harness" "$sub" > "$state/mate.meta"
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

# The reported production layout: a recorded local secondmate whose launch never
# armed the semantic busy contract, with one aged foreign row. No busy gen and
# no busy record exist anywhere, so the rung cannot prove the mate is idle and
# must stand down rather than fire a false stall for an ordinary long turn.
test_unarmed_mate_on_aged_row_stays_silent() {
  local dir state out
  dir=$(make_stall_case unarmed-mate "$TMP_ROOT/unarmed-pane.txt" 0)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'Working... (279k context)\n' > "$TMP_ROOT/unarmed-pane.txt"

  run_stall_checkpoint "$dir" 6 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "an unarmed mate's aged row reported a false wake-loop stall: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an unarmed mate still published a durable parent notification"
  [ ! -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "an unarmed mate still wrote the stall marker"
  [ ! -e "$state/.secondmate-wake-stall-receipts/mate" ] \
    || fail "an unarmed mate still wrote a stall receipt"
  pass "an unarmed mate's aged row stays silent with no side effect"
}

# An idle mate on an aged row is a genuine stall and keeps the exact reason text,
# marker, receipt, and durable publication it has today. The idle record is
# produced through the real writer, not hand-written.
test_idle_mate_on_aged_row_reports() {
  local dir state out gen
  dir=$(make_stall_case idle-mate "$TMP_ROOT/idle-pane.txt" 0)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'Idle\n' > "$TMP_ROOT/idle-pane.txt"
  gen=$("$BUSY_EVENT" arm "$state" mate) || fail "arming the idle mate's busy contract failed"
  "$BUSY_EVENT" apply "$state" mate idle --gen "$gen" --source claude-hook --event stop \
    || fail "applying the idle verdict failed"

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

# A mate provably mid-turn on an aged row: the rung stays silent, publishes
# nothing durable, and leaves no marker or receipt that would later hide a real
# stall on the same mate. The busy record comes from the real writer.
test_busy_mate_on_aged_row_stays_silent() {
  local dir state out
  dir=$(make_stall_case busy-mate "$TMP_ROOT/busy-pane.txt" 0)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'Working... (279k context)\n' > "$TMP_ROOT/busy-pane.txt"
  "$BUSY_EVENT" arm "$state" mate >/dev/null || fail "arming the busy mate's busy contract failed"

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

# A semantic idle record proves the mate is not working even when the pane
# cannot be captured, so a transient capture failure must not suppress the
# stall. Capture is only an input to the rendered-text fallbacks.
test_semantic_idle_survives_capture_failure() {
  local dir state out gen
  dir=$(make_stall_case capture-failure "$TMP_ROOT/unreadable-pane.txt" 1)
  state="$dir/state"
  out="$dir/watch.out"
  gen=$("$BUSY_EVENT" arm "$state" mate) || fail "arming the capture-failure mate failed"
  "$BUSY_EVENT" apply "$state" mate idle --gen "$gen" --source claude-hook --event stop \
    || fail "applying the idle verdict failed"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "a semantic idle verdict was suppressed by a failed pane capture: $(cat "$out")"
  [ -s "$state/.wake-queue" ] \
    || fail "a semantic idle verdict published no durable notification"
  pass "a semantic idle verdict reports despite a failed pane capture"
}

# A grok mate has no semantic busy record, so the busy lib falls back to its
# rendered tail. A tail without the busy signature yields `idle grok-regex`,
# which is not proof the mate is not working: a long turn can scroll the busy
# footer out of the captured tail. The rung must stay silent.
test_grok_rendered_idle_on_aged_row_stays_silent() {
  local dir state out
  dir=$(make_stall_case grok-rendered-idle "$TMP_ROOT/grok-pane.txt" 0 grok)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'Working... (279k context)\n' > "$TMP_ROOT/grok-pane.txt"

  run_stall_checkpoint "$dir" 6 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "a grok rendered-text idle verdict reported a false wake-loop stall: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a grok rendered-text idle verdict still published a durable notification"
  [ ! -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "a grok rendered-text idle verdict still wrote the stall marker"
  [ ! -e "$state/.secondmate-wake-stall-receipts/mate" ] \
    || fail "a grok rendered-text idle verdict still wrote a stall receipt"
  pass "a grok rendered-text idle verdict stays silent with no side effect"
}

test_unarmed_mate_on_aged_row_stays_silent
test_idle_mate_on_aged_row_reports
test_grok_rendered_idle_on_aged_row_stays_silent
test_busy_mate_on_aged_row_stays_silent
test_semantic_idle_survives_capture_failure

echo "# all fm-watch-secondmate-wake-stall tests passed"

#!/usr/bin/env bash
# tests/fm-chair-flip.test.sh - dry-run and refusal tests for
# bin/fm-chair-flip.sh. Dry run prints every command and writes the handoff
# file, so the file contract is exercised without touching a terminal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chair-flip-tests)
SCRIPT="$ROOT/bin/fm-chair-flip.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

SENSOR="$TMP_ROOT/sensor.sh"
STATUS="$TMP_ROOT/status.sh"
cat > "$SENSOR" <<'SH'
#!/usr/bin/env bash
printf 'chair-runway: fable=%s pool8317=x ccflare=x routable=0/11 needs_reauth=0 names=none grok=%s grok_pct=%s reason=x\n' \
  "${FM_TEST_FABLE:-green}" "${FM_TEST_GROK:-green}" "${FM_TEST_GROK_PCT:-50}"
SH
cat > "$STATUS" <<'SH'
#!/usr/bin/env bash
printf 'chair-status: chair=%s terminal=%s pid=%s tty=%s reason=x\n' \
  "${FM_TEST_CHAIR:-grok}" "${FM_TEST_TERMINAL:-term_x}" 123 ttys000
SH
chmod +x "$SENSOR" "$STATUS"

run_flip() {  # <to> [env assignments already exported]
  FM_CHAIR_FLIP_DRY_RUN=1 \
  FM_CHAIR_FLIP_HOME="$HOME_DIR" \
  FM_CHAIR_FLIP_SENSOR_CMD="$SENSOR" \
  FM_CHAIR_FLIP_STATUS_CMD="$STATUS" \
  FM_CHAIR_FLIP_SLEEP_CMD=true \
  bash "$SCRIPT" "$@"
}

# --- dry run writes the handoff and prints commands -------------------------

rm -f "$HOME_DIR/state/.chair-flip-at"
printf 'done: something\n' > "$HOME_DIR/state/task-a.status"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok run_flip to-pi-fable)
assert_contains "$out" "DRY-RUN" "dry run prints commands"
assert_contains "$out" "terminal create" "dry run prints the launch"
assert_contains "$out" "handoff written" "dry run reports the handoff"
assert_present "$HOME_DIR/data/handoff-grok-to-pi-fable.md" "handoff file written"
handoff=$(cat "$HOME_DIR/data/handoff-grok-to-pi-fable.md")
assert_contains "$handoff" "data/MEMORY-INDEX.md" "handoff points at the memory index"
assert_contains "$handoff" "data/captain.md" "handoff points at captain.md"
assert_contains "$handoff" "data/learnings.md" "handoff points at learnings.md"
assert_contains "$handoff" "task-a.status" "handoff lists the in-flight status log"
assert_contains "$handoff" "done: something" "handoff carries the status tail"
assert_absent "$HOME_DIR/state/.chair-flip-at" "dry run does not stamp hysteresis"
pass "dry run prints commands and writes the handoff file"

# --- refusals ---------------------------------------------------------------

out=$(FM_TEST_FABLE=unknown FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 1 "$code" "unknown target refuses"
assert_contains "$out" "unknown" "refusal names the unknown source"
pass "refuses to flip toward an unknown source"

out=$(FM_TEST_FABLE=red FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 1 "$code" "red target refuses"
pass "refuses to flip toward a red source"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=pi-fable run_flip to-pi-fable); code=$?
expect_code 0 "$code" "already-there is a no-op"
assert_contains "$out" "no-op" "no-op reported"
pass "no-op when the chair is already at the target"

# --- hysteresis -------------------------------------------------------------

printf '%s\n' "$(date +%s)" > "$HOME_DIR/state/.chair-flip-at"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok FM_CHAIR_HYSTERESIS_SECS=1800 run_flip to-pi-fable); code=$?
expect_code 1 "$code" "hysteresis refuses"
assert_contains "$out" "hysteresis" "hysteresis refusal reported"
pass "refuses within the hysteresis window"

printf 'fm-chair-flip tests passed\n'
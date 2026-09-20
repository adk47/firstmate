#!/usr/bin/env bash
# tests/fm-chair-sentinel.test.sh - decision-table tests for
# bin/fm-chair-sentinel.sh with stubbed sensor, status, and actuator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chair-sentinel-tests)
SCRIPT="$ROOT/bin/fm-chair-sentinel.sh"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

SENSOR="$TMP_ROOT/sensor.sh"
STATUS="$TMP_ROOT/status.sh"
FLIP="$TMP_ROOT/flip.sh"
FLIP_LOG="$TMP_ROOT/flip.log"

cat > "$SENSOR" <<'SH'
#!/usr/bin/env bash
printf 'chair-runway: fable=%s pool8317=%s ccflare=%s routable=0/11 needs_reauth=%s names=%s grok=%s grok_pct=%s reason=x\n' \
  "${FM_TEST_FABLE:-green}" x x "${FM_TEST_REAUTH:-11}" "${FM_TEST_NAMES:-acctA,acctB}" "${FM_TEST_GROK:-red}" "${FM_TEST_GROK_PCT:-1}"
SH
cat > "$STATUS" <<'SH'
#!/usr/bin/env bash
printf 'chair-status: chair=%s terminal=%s pid=%s tty=%s reason=x\n' \
  "${FM_TEST_CHAIR:-pi-fable}" term_test 123 ttys000
SH
cat > "$FLIP" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_TEST_FLIP_LOG"
SH
chmod +x "$SENSOR" "$STATUS" "$FLIP"

run_tick() {
  : > "$FLIP_LOG"
  FM_CHAIR_SENTINEL_SENSOR_CMD="$SENSOR" \
  FM_CHAIR_SENTINEL_STATUS_CMD="$STATUS" \
  FM_CHAIR_SENTINEL_FLIP_CMD="$FLIP" \
  FM_CHAIR_SENTINEL_HOME="$HOME_DIR" \
  FM_TEST_FLIP_LOG="$FLIP_LOG" \
  FM_CHAIR_SENTINEL_NOW=1700000000 \
  bash "$SCRIPT"
}

# --- table ------------------------------------------------------------------

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "decision=fable_green_chair_ok" "green + pi chair is ok"
[ ! -s "$FLIP_LOG" ] || fail "no flip when the chair is already right"
pass "Fable green + pi-fable chair -> nothing"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok run_tick)
assert_contains "$out" "action=to-pi-fable" "green + grok chair flips to pi"
assert_grep "to-pi-fable" "$FLIP_LOG" "flip invoked to-pi-fable"
pass "Fable green + grok chair -> flip to-pi-fable"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=none run_tick)
assert_contains "$out" "action=to-pi-fable" "green + no chair flips to pi"
pass "Fable green + no chair -> flip to-pi-fable"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=green FM_TEST_CHAIR=grok run_tick)
assert_contains "$out" "decision=grok_red_chair_ok" "red + grok chair is ok"
[ ! -s "$FLIP_LOG" ] || fail "no flip away from a healthy grok chair"
pass "Fable red + Grok above floor + grok chair -> nothing"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=green FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "action=to-grok" "red + pi chair flips to grok"
assert_grep "to-grok" "$FLIP_LOG" "flip invoked to-grok"
pass "Fable red + Grok above floor + pi chair -> flip to-grok"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=red FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "decision=no_tank" "both red is no_tank"
[ ! -s "$FLIP_LOG" ] || fail "no flip when no tank exists"
assert_contains "$out" "Captain, firstmate has no tank" "captain line printed"
assert_contains "$out" "acctA,acctB" "captain line names accounts"
assert_present "$HOME_DIR/state/.chair-alarm" "alarm file written"
pass "both red -> no flip, alarm, captain line"

# --- logging ----------------------------------------------------------------

[ -f "$HOME_DIR/data/chair-sentinel/log.jsonl" ] || fail "log file written"
lines=$(wc -l < "$HOME_DIR/data/chair-sentinel/log.jsonl")
[ "$lines" -ge 6 ] || fail "one log line per tick (got $lines)"
tail -n 1 "$HOME_DIR/data/chair-sentinel/log.jsonl" | jq -e '.decision and .action' >/dev/null \
  || fail "log line carries decision and action"
pass "every tick appends one jsonl line"

printf 'fm-chair-sentinel tests passed\n'
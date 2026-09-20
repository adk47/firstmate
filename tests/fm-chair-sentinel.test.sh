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
printf 'chair-status: chair=%s terminal=%s pid=%s reason=x\n' \
  "${FM_TEST_CHAIR:-pi-fable}" term_test 123
SH
cat > "$FLIP" <<'SH'
#!/usr/bin/env bash
# Records the direction and the dry-run flag it was handed; answers like the
# real actuator (a source= line) and exits with FM_TEST_FLIP_EXIT.
printf '%s dry_run=%s\n' "$1" "${FM_CHAIR_FLIP_DRY_RUN:-unset}" >> "$FM_TEST_FLIP_LOG"
printf 'chair-flip: flipped grok -> %s source=%s\n' "$1" "${FM_TEST_FLIP_SOURCE:-8317}"
exit "${FM_TEST_FLIP_EXIT:-0}"
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
  bash "$SCRIPT" "$@"
}

last_log() { tail -n 1 "$HOME_DIR/data/chair-sentinel/log.jsonl"; }

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

# --- a foreign chair (claude) is replaced like none, never alarmed on -------

out=$(FM_TEST_FABLE=green FM_TEST_GROK=green FM_TEST_CHAIR=claude run_tick)
assert_contains "$out" "action=to-pi-fable" "green + claude chair flips to pi"
assert_not_contains "$out" "no tank" "a claude chair with both tanks full is not an alarm"
assert_absent "$HOME_DIR/state/.chair-alarm" "alarm cleared for a claude chair"
pass "Fable green + claude chair -> flip to-pi-fable, no alarm"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=green FM_TEST_CHAIR=claude run_tick)
assert_contains "$out" "action=to-grok" "red + grok green + claude chair flips to grok"
assert_grep "to-grok" "$FLIP_LOG" "flip invoked to-grok"
pass "Fable red + Grok above floor + claude chair -> flip to-grok"

# --- dry run is forwarded to the actuator -----------------------------------

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok run_tick)
assert_grep "to-pi-fable dry_run=0" "$FLIP_LOG" "live tick hands the actuator dry_run=0"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok FM_CHAIR_SENTINEL_DRY_RUN=1 run_tick)
assert_grep "to-pi-fable dry_run=1" "$FLIP_LOG" "dry-run tick hands the actuator dry_run=1"
pass "FM_CHAIR_SENTINEL_DRY_RUN reaches the actuator"

# --- logging ----------------------------------------------------------------

[ -f "$HOME_DIR/data/chair-sentinel/log.jsonl" ] || fail "log file written"
lines=$(wc -l < "$HOME_DIR/data/chair-sentinel/log.jsonl")
[ "$lines" -ge 10 ] || fail "one log line per tick (got $lines)"
last_log | jq -e '.decision and .action' >/dev/null || fail "log line carries decision and action"
pass "every tick appends one jsonl line"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok FM_TEST_FLIP_SOURCE=8080 run_tick)
last_log | jq -e '.flip_exit == 0 and .source == "8080"' >/dev/null || fail "successful flip logs exit 0 and its source ($(last_log))"
assert_contains "$out" "source=8080 flip_exit=0" "tick line reports the flip result and source"
pass "log records a verified flip with its source"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok FM_TEST_FLIP_EXIT=1 run_tick)
last_log | jq -e '.flip_exit == 1' >/dev/null || fail "failed flip logs its nonzero exit ($(last_log))"
assert_contains "$out" "flip_exit=1" "tick line reports the failed flip"
pass "log distinguishes a failed flip"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=pi-fable run_tick)
last_log | jq -e '.flip_exit == null and .source == "none"' >/dev/null || fail "no-action tick logs no flip result ($(last_log))"
pass "no-action tick logs flip_exit null"

# --- the armed LaunchAgent carries the tool PATH ----------------------------

if command -v python3 >/dev/null 2>&1; then
  LA_DIR="$TMP_ROOT/LaunchAgents"
  out=$(FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_CHAIR_SENTINEL_LA_DIR="$LA_DIR" FM_CHAIR_SENTINEL_LAUNCHCTL=true bash "$SCRIPT" arm); code=$?
  expect_code 0 "$code" "arm succeeds"
  PLIST="$LA_DIR/ai.muso.chair-sentinel.plist"
  assert_present "$PLIST" "plist written"
  env_json=$(python3 -c 'import plistlib, json, sys; print(json.dumps(plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]))' "$PLIST")
  la_path=$(printf '%s' "$env_json" | jq -r '.PATH // ""')
  for dir in "$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.grok/bin" /opt/homebrew/bin /usr/bin; do
    case ":$la_path:" in
      *":$dir:"*) : ;;
      *) fail "launchd PATH lacks $dir (got: $la_path)" ;;
    esac
  done
  printf '%s' "$env_json" | jq -e --arg home "$(cd "$HOME_DIR" && pwd -P)" '.FM_HOME == $home' >/dev/null || fail "plist FM_HOME"
  pass "armed LaunchAgent PATH covers the orca, pi, quota-axi and grok dirs"
else
  printf 'skip: python3 not found (plist parse)\n'
fi

printf 'fm-chair-sentinel tests passed\n'
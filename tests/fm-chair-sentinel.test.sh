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
  "${FM_TEST_FABLE:-green}" "${FM_TEST_POOL8317:-x}" "${FM_TEST_CCFLARE:-x}" "${FM_TEST_REAUTH:-11}" "${FM_TEST_NAMES:-acctA,acctB}" "${FM_TEST_GROK:-red}" "${FM_TEST_GROK_PCT:-1}"
SH
cat > "$STATUS" <<'SH'
#!/usr/bin/env bash
printf 'chair-status: chair=%s harness=x source=%s terminal=%s pid=%s reason=x\n' \
  "${FM_TEST_CHAIR:-pi-fable}" "${FM_TEST_SOURCE:-none}" term_test "${FM_TEST_PID:-123}"
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
  bash "$SCRIPT"
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

# --- a pi chair on a red source is re-seated on the green one ---------------

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=red FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8317 run_tick)
assert_contains "$out" "decision=chair_source_red_reseat" "8317-bound chair with 8317 red and 8080 green is re-seated"
assert_contains "$out" "action=to-pi-fable" "re-seat goes through to-pi-fable"
assert_grep "to-pi-fable" "$FLIP_LOG" "flip invoked"
assert_absent "$HOME_DIR/state/.chair-alarm" "not an alarm"
pass "pi on 8317, 8317 red, 8080 green -> re-seat to-pi-fable"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=red FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8080 run_tick)
assert_contains "$out" "decision=chair_source_red_reseat" "8080-bound chair with 8080 red and 8317 green is re-seated"
assert_contains "$out" "action=to-pi-fable" "re-seat goes through to-pi-fable"
pass "pi on 8080, 8080 red, 8317 green -> re-seat to-pi-fable"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=red FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8317 run_tick)
assert_contains "$out" "decision=fable_green_chair_ok" "a chair on its own green source is fine"
[ ! -s "$FLIP_LOG" ] || fail "no flip for a chair on a green source"
pass "pi on 8317, 8317 green -> nothing"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=unknown FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8317 run_tick)
assert_contains "$out" "decision=fable_green_chair_ok" "an unmeasured bound source is held, not re-seated"
[ ! -s "$FLIP_LOG" ] || fail "no flip on an unknown bound source"
pass "pi on 8317, 8317 unknown, 8080 green -> nothing"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=red FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=none run_tick)
assert_contains "$out" "decision=fable_green_chair_ok" "a chair with no bound source (non-Pi record) is not re-seated"
pass "pi with source=none -> nothing"

# --- an unknown bound source never re-seats a chair on its own --------------

SOURCE_FILE="$HOME_DIR/state/.chair-source"
rm -f "$SOURCE_FILE"
for n in 1 2 3 4 5 6; do
  out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=unknown run_tick)
  assert_contains "$out" "decision=fable_green_chair_ok" "a quiet chair with an unknown source is left alone (tick $n)"
  assert_contains "$out" "action=none" "no action on tick $n"
  [ ! -s "$FLIP_LOG" ] || fail "an unknown source must never trigger a flip (tick $n)"
  assert_absent "$HOME_DIR/state/.chair-alarm" "no alarm"
done
assert_contains "$(cat "$SOURCE_FILE")" "pid=123 source=unknown " "an unknown source is cached for the pid too"
pass "quiet chair, unknown source, fable green for 30 minutes -> no action"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=red FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=unknown run_tick)
assert_contains "$out" "decision=fable_green_chair_ok" "an unknown source cannot fire the source-red row"
[ ! -s "$FLIP_LOG" ] || fail "no flip on unknown source even with a red pool"
pass "unknown source + one pool red -> still nothing"

# --- a named source is cached per lock pid so later ticks never re-derive ---

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=red FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8317 run_tick)
assert_present "$SOURCE_FILE" "a named source is cached"
record=$(cat "$SOURCE_FILE")
assert_contains "$record" "pid=123 " "cached under the lock pid"
assert_contains "$record" "source=8317" "a cached unknown is replaced once the tank is named"
assert_contains "$record" "launched_at=1700000000" "stamped with the tick time"
pass "sentinel caches a named chair source keyed by pid"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=unknown run_tick)
assert_contains "$(cat "$SOURCE_FILE")" "source=8317" "an unknown reading never overwrites a cached source for the same pid"
out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=green FM_TEST_CCFLARE=green FM_TEST_CHAIR=pi-fable FM_TEST_SOURCE=8080 run_tick)
assert_contains "$(cat "$SOURCE_FILE")" "source=8317" "the same pid is not re-derived once cached"
pass "cached source is stable for the pid that holds the lock"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=green FM_TEST_CHAIR=grok FM_TEST_SOURCE=grok FM_TEST_PID=456 run_tick)
record=$(cat "$SOURCE_FILE")
assert_contains "$record" "pid=456 " "a new lock pid replaces the cached record"
assert_contains "$record" "source=grok" "a grok chair's source is cached too"
pass "new lock pid -> record replaced; grok chair source cached"
rm -f "$SOURCE_FILE"

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

# --- Fable unknown: never an alarm on its own, never a flip toward Fable ----

UNKNOWN_TICKS="$HOME_DIR/state/.chair-fable-unknown-ticks"
rm -f "$UNKNOWN_TICKS"

out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=grok run_tick)
assert_contains "$out" "decision=grok_chair_ok_fable_unmeasured" "grok chair on a green tank is fine while Fable is unmeasured"
assert_contains "$out" "action=none" "no flip"
assert_not_contains "$out" "no tank" "no alarm line"
assert_absent "$HOME_DIR/state/.chair-alarm" "no alarm file"
[ ! -s "$FLIP_LOG" ] || fail "no flip for a grok chair while Fable is unknown"
pass "Fable unknown + Grok green + grok chair -> nothing, no alarm"

out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=none run_tick)
assert_contains "$out" "action=to-grok" "no chair + green Grok seats Grok"
assert_grep "to-grok" "$FLIP_LOG" "flip invoked to-grok"
assert_absent "$HOME_DIR/state/.chair-alarm" "no alarm"
pass "Fable unknown + Grok green + no chair -> flip to-grok"

out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=claude run_tick)
assert_contains "$out" "action=to-grok" "foreign chair + green Grok seats Grok"
pass "Fable unknown + Grok green + claude chair -> flip to-grok"

rm -f "$UNKNOWN_TICKS"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=pi-fable run_tick)
for n in 1 2; do
  out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=pi-fable run_tick)
  assert_contains "$out" "decision=fable_unmeasured_hold" "pi chair is held on unknown tick $n"
  assert_contains "$out" "action=none" "no flip on unknown tick $n"
  assert_contains "$out" "fable_unknown_ticks=$n" "tick $n counted"
  [ ! -s "$FLIP_LOG" ] || fail "no flip while holding (tick $n)"
  assert_absent "$HOME_DIR/state/.chair-alarm" "no alarm while holding"
done
out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "decision=fable_unmeasured_expired" "third consecutive unknown tick expires the hold"
assert_contains "$out" "action=to-grok" "expired hold flips to Grok"
assert_grep "to-grok" "$FLIP_LOG" "flip invoked to-grok"
pass "Fable unknown + Grok green + pi chair -> held 2 ticks, flipped on the 3rd"

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "fable_unknown_ticks=0" "a measured tick resets the count"
assert_absent "$UNKNOWN_TICKS" "counter file cleared"
out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=green FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "decision=fable_unmeasured_hold" "the hold starts over after a measured tick"
assert_contains "$out" "fable_unknown_ticks=1" "count restarted"
pass "a measured Fable tick resets the unknown hold"

rm -f "$UNKNOWN_TICKS"
out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=red FM_TEST_CHAIR=pi-fable run_tick)
assert_contains "$out" "decision=no_tank" "unknown Fable with red Grok is no tank"
assert_contains "$out" "Captain, firstmate has no tank" "captain line printed"
assert_contains "$out" "acctA,acctB" "captain line names the 8080 accounts"
assert_present "$HOME_DIR/state/.chair-alarm" "alarm file written"
[ ! -s "$FLIP_LOG" ] || fail "no flip with no green tank"
pass "Fable unknown + Grok red -> no_tank alarm naming accounts"

out=$(FM_TEST_FABLE=unknown FM_TEST_GROK=unknown FM_TEST_CHAIR=grok run_tick)
assert_contains "$out" "decision=no_tank" "both unmeasured is no tank"
pass "Fable unknown + Grok unknown -> no_tank"

# --- dry run is forwarded to the actuator -----------------------------------

out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok run_tick)
assert_grep "to-pi-fable dry_run=0" "$FLIP_LOG" "live tick hands the actuator dry_run=0"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok FM_CHAIR_SENTINEL_DRY_RUN=1 run_tick)
assert_grep "to-pi-fable dry_run=1" "$FLIP_LOG" "dry-run tick hands the actuator dry_run=1"
pass "FM_CHAIR_SENTINEL_DRY_RUN reaches the actuator"

# --- logging ----------------------------------------------------------------

[ -f "$HOME_DIR/data/chair-sentinel/log.jsonl" ] || fail "log file written"
lines=$(wc -l < "$HOME_DIR/data/chair-sentinel/log.jsonl")
[ "$lines" -ge 21 ] || fail "one log line per tick (got $lines)"
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

LAUNCHCTL_STUB="$TMP_ROOT/launchctl.sh"
LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log"
cat > "$LAUNCHCTL_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LAUNCHCTL_LOG"
[ "$1" = list ] && printf '%s\n' "${FM_TEST_LAUNCHCTL_LOADED:-}"
exit 0
SH
chmod +x "$LAUNCHCTL_STUB"
LA_DIR="$TMP_ROOT/LaunchAgents"
LEGACY_PLIST="$LA_DIR/ai.muso.lane-tick-chair-flipper.plist"
mkdir -p "$LA_DIR"
printf '<plist/>\n' > "$LEGACY_PLIST"
: > "$LAUNCHCTL_LOG"
out=$(FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_CHAIR_SENTINEL_LA_DIR="$LA_DIR" FM_CHAIR_SENTINEL_LAUNCHCTL="$LAUNCHCTL_STUB" \
  FM_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" FM_TEST_LAUNCHCTL_LOADED="-	0	ai.muso.lane-tick-chair-flipper" bash "$SCRIPT" arm); code=$?
expect_code 0 "$code" "arm succeeds"
PLIST="$LA_DIR/ai.muso.chair-sentinel.plist"
assert_present "$PLIST" "plist written"
assert_absent "$LEGACY_PLIST" "the legacy lane-tick flipper plist is removed"
assert_grep "bootout gui/$(id -u)/ai.muso.lane-tick-chair-flipper" "$LAUNCHCTL_LOG" "the legacy tick is booted out"
[ "$(grep -n 'bootout' "$LAUNCHCTL_LOG" | cut -d: -f1 | head -1)" -lt "$(grep -n "load $PLIST" "$LAUNCHCTL_LOG" | cut -d: -f1 | head -1)" ] \
  || fail "legacy tick must be retired before the sentinel is loaded"
assert_contains "$out" "retired legacy tick ai.muso.lane-tick-chair-flipper" "arm reports the retirement"
pass "arm retires the legacy lane-tick chair flipper before loading the sentinel"

: > "$LAUNCHCTL_LOG"
out=$(FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_CHAIR_SENTINEL_LA_DIR="$LA_DIR" FM_CHAIR_SENTINEL_LAUNCHCTL="$LAUNCHCTL_STUB" \
  FM_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" bash "$SCRIPT" arm); code=$?
expect_code 0 "$code" "re-arm succeeds"
assert_not_contains "$out" "retired legacy" "nothing to retire the second time"
assert_no_grep "bootout" "$LAUNCHCTL_LOG" "no bootout when the legacy tick is already gone"
pass "re-arm is quiet once the legacy tick is gone"

out=$(FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_CHAIR_SENTINEL_LA_DIR="$LA_DIR" FM_CHAIR_SENTINEL_LAUNCHCTL="$LAUNCHCTL_STUB" \
  FM_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" bash "$SCRIPT" disarm); code=$?
expect_code 0 "$code" "disarm succeeds"
assert_absent "$PLIST" "sentinel plist removed"
assert_absent "$LEGACY_PLIST" "disarm does not restore the legacy tick"
pass "disarm leaves the legacy tick retired"

if command -v python3 >/dev/null 2>&1; then
  : > "$LAUNCHCTL_LOG"
  out=$(FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_CHAIR_SENTINEL_LA_DIR="$LA_DIR" FM_CHAIR_SENTINEL_LAUNCHCTL="$LAUNCHCTL_STUB" \
    FM_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" bash "$SCRIPT" arm); code=$?
  expect_code 0 "$code" "arm succeeds"
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
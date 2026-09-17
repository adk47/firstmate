#!/usr/bin/env bash
# tests/fm-lane-model-switch.test.sh - the composer-safe one-lane model switch
# (bin/fm-lane-model-switch.sh) against fake Orca screens.
#
# The contract under test is the refusal boundary, because that is the whole
# reason this script exists rather than a plain send: a lane whose composer is
# not proven empty must never receive `/model`, an unreadable screen must send
# nothing at all, and a switch that does land must be verified on screen and
# recorded before the lane is kicked back to work. The tick report is the other
# half: a model switch can skip the next scheduled tick, so the script prints
# the next expected one from the home's own tick source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWITCH="$ROOT/bin/fm-lane-model-switch.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-model-switch-tests)

# A fake Orca CLI: `terminal read` serves the next queued screen file, and
# every send is recorded so a test can prove what did and did not reach the
# lane. Screens are queued as <n>.json so a case controls the exact sequence
# the script sees (pre-switch capture, composer verdict, verify, kick).
make_orca_fakebin() {  # <dir> -> echoes the fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
: "${FM_ORCA_LOG:?}"
: "${FM_ORCA_SCREENS:?}"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$FM_ORCA_LOG"
case "${1:-}${2:-}" in
  status*) printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  terminalread)
    count_file="$FM_ORCA_SCREENS/.count"
    n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$count_file"
    file="$FM_ORCA_SCREENS/$n.json"
    if [ ! -f "$file" ]; then
      printf '{"ok":false,"error":{"message":"no queued screen %s"}}\n' "$n"
      exit 2
    fi
    cat "$file"
    ;;
  terminalsend) printf '{"ok":true,"result":{"sent":true}}\n' ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

screen_json() {  # <file> <line>...
  local file=$1
  shift
  python3 - "$file" "$@" <<'PY'
import json, sys
path, lines = sys.argv[1], sys.argv[2:]
with open(path, "w") as handle:
    json.dump({"ok": True, "result": {"terminal": {"tail": list(lines)}}}, handle)
PY
}

case_dir() {  # <name> -> sets CASE FB LOG SCREENS HOME STATE DATA
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/screens"
  LOG="$CASE/log"
  SCREENS="$CASE/screens"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE")
  HOME_DIR="$CASE/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
}

write_lane_meta() {  # <id> [model]
  local id=$1 model=${2:-opus[1m]}
  fm_write_meta "$STATE/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "harness=claude" \
    "kind=ship" \
    "model=$model" \
    "backend=orca" \
    "terminal=term-$id"
}

run_switch() {  # <args...>; sets OUT RC. SWITCH_GATEWAY_PORT picks the gateway port.
  local rc=0
  OUT=$(PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_ORCA_LOG="$LOG" FM_ORCA_SCREENS="$SCREENS" FM_LANE_SWITCH_PAUSE=0.2 \
    FM_LANE_SWITCH_SETTLE=0.1 FM_LANE_SWITCH_SLEEP=0.1 \
    FM_DEEPSEEK_GATEWAY_PORT="${SWITCH_GATEWAY_PORT:-8799}" \
    bash "$SWITCH" "$@" 2>&1) || rc=$?
  RC=$rc
}

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# --- refusal paths ----------------------------------------------------------

test_dirty_composer_is_refused() {
  case_dir dirty-composer
  write_lane_meta lane-a
  # A composer holding unsubmitted text. Orca's capture carries no styling, so
  # trailing text after the prompt glyph is never a positive empty proof: the
  # verdict is unknown, and the script must refuse rather than append to it.
  screen_json "$SCREENS/1.json" 'some earlier output' '❯ rm -rf /important'
  screen_json "$SCREENS/2.json" 'some earlier output' '❯ rm -rf /important'
  screen_json "$SCREENS/3.json" 'some earlier output' '❯ rm -rf /important'
  run_switch lane-a 'opus[1m]'
  expect_code 2 "$RC" "a dirty composer must be refused"
  assert_contains "$OUT" "does not verify empty" "the refusal must name the composer"
  assert_contains "$OUT" "pending composer saved:" "the refusal must save what the composer held"
  assert_no_grep '/model' "$LOG" "nothing may be typed when the composer is dirty"
  assert_grep '--interrupt' "$LOG" "the composer is cleared before the re-verification"
  # The saved capture is the operator's copy of what was typed.
  assert_present "$DATA/lane-model-switch/pending-composer" "the pending composer directory must exist"
  grep -rl 'rm -rf /important' "$DATA/lane-model-switch/pending-composer" >/dev/null \
    || fail "the saved capture must contain the text the composer held"
  assert_no_grep 'model_switch_to=' "$STATE/lane-a.meta" "a refused switch must not be recorded as done"
  pass "fm-lane-model-switch: a composer that will not verify empty is refused and nothing is typed"
}

test_unreadable_screen_sends_nothing() {
  case_dir unreadable-screen
  write_lane_meta lane-b
  # No queued screen at all: the capture itself fails, which is the
  # fail-closed direction - an unreadable lane is never a clean lane.
  run_switch lane-b 'opus[1m]'
  expect_code 2 "$RC" "an unreadable screen must be refused"
  assert_contains "$OUT" "unreadable" "the refusal must say the screen could not be read"
  assert_no_grep 'terminal send' "$LOG" "an unreadable screen must not send anything to the lane"
  pass "fm-lane-model-switch: an unreadable screen refuses before any backend call"
}

test_non_claude_lane_is_refused() {
  case_dir non-claude
  fm_write_meta "$STATE/lane-c.meta" \
    "harness=codex" "kind=ship" "model=gpt-5" "backend=orca" "terminal=term-lane-c"
  run_switch lane-c 'opus[1m]'
  expect_code 2 "$RC" "a non-Claude lane must be refused"
  assert_contains "$OUT" "only a Claude Code lane" "the refusal must name the harness boundary"
  pass "fm-lane-model-switch: a non-Claude lane is refused"
}

test_gate_agent_is_refused_before_any_backend_call() {
  case_dir gate-agent
  write_lane_meta lane-gate
  screen_json "$SCREENS/1.json" '❯'
  # A no-mistakes gate agent must never drive a live lane. The helper's own
  # semantics are covered by tests/fm-gate-refuse.test.sh; this pins that THIS
  # entrypoint sources and calls it before it resolves or touches anything.
  # The suite's own bypass is dropped here on purpose: tests/lib.sh exports
  # FM_GATE_REFUSE_BYPASS=1 so the real suite can run from a gate worktree.
  local rc=0
  OUT=$(env -u FM_GATE_REFUSE_BYPASS PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_ORCA_LOG="$LOG" FM_ORCA_SCREENS="$SCREENS" NO_MISTAKES_GATE=1 \
    bash "$SWITCH" lane-gate 'opus[1m]' 2>&1) || rc=$?
  expect_code 3 "$rc" "a no-mistakes gate agent must be refused"
  [ ! -s "$LOG" ] || fail "a refused gate agent must not reach the lane, got: $(cat "$LOG")"
  pass "fm-lane-model-switch: a no-mistakes gate agent is refused before any backend call"
}

test_remote_lane_is_refused() {
  case_dir remote-lane
  fm_write_meta "$STATE/lane-d.meta" \
    "harness=claude" "kind=secondmate" "model=opus[1m]" "backend=orca" "terminal=term-lane-d" "remote_host=other.example"
  run_switch lane-d 'opus[1m]'
  expect_code 2 "$RC" "a remote lane must be refused"
  assert_contains "$OUT" "remote secondmate" "the refusal must name the remote boundary"
  pass "fm-lane-model-switch: a remote lane is refused"
}

test_unhealthy_gateway_is_refused_before_the_lane() {
  case_dir gateway-unhealthy
  write_lane_meta lane-e
  screen_json "$SCREENS/1.json" '❯'
  # --gateway with no gateway listening on that port: refuse before touching
  # the lane, so a failed repoint never costs a switch.
  SWITCH_GATEWAY_PORT=$(free_port)
  run_switch lane-e 'gateway' --gateway
  expect_code 1 "$RC" "an unhealthy gateway must stop the switch"
  assert_contains "$OUT" "not healthy" "the failure must name the gateway health gate"
  [ ! -s "$LOG" ] || fail "an unhealthy gateway must be detected before any backend call"
  unset SWITCH_GATEWAY_PORT
  pass "fm-lane-model-switch: --gateway refuses an unhealthy gateway before touching the lane"
}

test_gateway_value_form_is_refused() {
  case_dir gateway-value
  write_lane_meta lane-n
  screen_json "$SCREENS/1.json" '❯'
  # The second gateway is loopback-only, so there is no host to point at. A
  # value form used to be accepted and silently probed 127.0.0.1 anyway, which
  # recorded one endpoint while binding another; it is now an explicit refusal.
  run_switch lane-n 'gateway' --gateway=http://host.example:8799
  expect_code 2 "$RC" "a --gateway value must be refused"
  assert_contains "$OUT" "takes no value" "the refusal must say only the bare flag is supported"
  assert_contains "$OUT" "FM_DEEPSEEK_GATEWAY_PORT" "the refusal must name how a port is chosen instead"
  [ ! -s "$LOG" ] || fail "a refused flag must not reach the lane"
  pass "fm-lane-model-switch: --gateway=<value> is refused rather than half-honoured"
}

# --- the switch itself ------------------------------------------------------

test_clean_switch_verifies_records_and_kicks() {
  case_dir clean-switch
  write_lane_meta lane-f 'opus'
  mkdir -p "$DATA/lane-f"
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'Opus 5 · 1M context' '❯'
  printf '7,37 * * * *\n' > "$DATA/lane-f/crons"
  run_switch lane-f 'opus[1m]' --now 2026-09-17T19:05:00Z
  expect_code 0 "$RC" "a clean lane must switch"
  assert_contains "$OUT" "switched: lane-f opus -> opus[1m]" "the switch must be reported with before and after"
  assert_contains "$OUT" "kicked:" "the lane must be kicked back to work"
  assert_contains "$OUT" "next-tick: 7,37 * * * *" "the next expected tick must be printed"
  assert_contains "$OUT" "2026-09-17T19:07:00Z" "the next tick must be computed from the cron expression"
  assert_grep '--text' "$LOG" "the model spec must reach the lane"
  assert_grep '/model opus[1m]' "$LOG" "the /model command must be typed verbatim"
  assert_grep 'model_switch_to=opus[1m]' "$STATE/lane-f.meta" "the switch must be recorded in metadata"
  assert_grep 'model_switch_from=opus' "$STATE/lane-f.meta" "the previous model must be recorded"
  assert_grep 'model=opus[1m]' "$STATE/lane-f.meta" "the metadata model must follow the switch"
  pass "fm-lane-model-switch: a clean lane switches, verifies, records, and reports its next tick"
}

# --- the gateway repoint ----------------------------------------------------

GATEWAY_SH="$ROOT/bin/fm-deepseek-gateway.sh"
GATEWAY_HOMES=()

stop_test_gateways() {
  local home
  for home in "${GATEWAY_HOMES[@]:-}"; do
    [ -n "$home" ] || continue
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash "$GATEWAY_SH" stop --force >/dev/null 2>&1 || true
  done
}
trap 'stop_test_gateways; fm_test_cleanup' EXIT
trap 'stop_test_gateways; fm_test_cleanup; exit 130' INT
trap 'stop_test_gateways; fm_test_cleanup; exit 143' TERM

# A real second gateway on a scratch port: --gateway probes its health and asks
# it for both the advertised model id and the exports, so a fixture that only
# pretended to be one would not exercise the repoint at all.
start_test_gateway() {  # sets SWITCH_GATEWAY_PORT
  cat > "$CASE/pick.py" <<'PY'
import json, sys
json.dump({
    "kind": "deepseek",
    "slot": "offpeak",
    "provider": "openrouter-named",
    "model": "deepseek/deepseek-v4.1-flash",
    "base_url": "http://127.0.0.1:1/api/v1",
    "api_key_cmd": "printf sk-fixture-key",
    "list_in": 0.15,
    "list_out": 0.60,
}, sys.stdout)
PY
  SWITCH_GATEWAY_PORT=$(free_port)
  GATEWAY_HOMES+=("$HOME_DIR")
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$GATEWAY_SH" \
    start --port "$SWITCH_GATEWAY_PORT" --pick "$CASE/pick.py" > "$CASE/gateway.log" 2>&1 \
    || fail "the gateway fixture must start: $(cat "$CASE/gateway.log")"
}

reset_screens() {
  rm -f "$SCREENS/.count" "$SCREENS"/*.json
}

test_plain_switch_leaves_the_gateway_repoint_untouched() {
  case_dir gateway-then-plain
  write_lane_meta lane-m 'opus'
  start_test_gateway
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  run_switch lane-m gateway --gateway
  expect_code 0 "$RC" "the gateway repoint must switch the lane: $OUT"
  assert_contains "$OUT" "switched: lane-m opus -> deepseek-v4.1-flash" "the advertised model id must be resolved from the gateway"
  assert_present "$STATE/lane-m.gateway.env" "the repoint must be written for the lane's next launch"
  assert_grep "ANTHROPIC_BASE_URL=http://127.0.0.1:$SWITCH_GATEWAY_PORT" "$STATE/lane-m.gateway.env" \
    "the exports must point at the gateway that was probed"
  local mode
  mode=$(stat -c '%a' "$STATE/lane-m.gateway.env" 2>/dev/null || stat -f '%Lp' "$STATE/lane-m.gateway.env")
  [ "$mode" = "600" ] || fail "the lane's gateway exports carry a token and must be mode 0600, got $mode"
  cp "$STATE/lane-m.gateway.env" "$CASE/gateway.env.before"

  # A later model switch with no --gateway is exactly the documented "model
  # switch only, same gateway" step. It must not disturb the repoint.
  reset_screens
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'Opus 5 · 1M context' '❯'
  run_switch lane-m 'opus[1m]'
  expect_code 0 "$RC" "the plain switch must succeed: $OUT"
  cmp -s "$CASE/gateway.env.before" "$STATE/lane-m.gateway.env" \
    || fail "a plain model switch must leave the lane's gateway exports byte-identical"
  assert_contains "$OUT" "left $STATE/lane-m.gateway.env untouched" \
    "the report must say the endpoint record was left alone"
  assert_grep 'model_switch_to=opus[1m]' "$STATE/lane-m.meta" "the plain switch must still be recorded"
  assert_grep 'model_switch_gateway=-' "$STATE/lane-m.meta" "the plain switch must record that it bound no gateway"
  pass "fm-lane-model-switch: a plain model switch leaves a prior gateway repoint byte-identical"
}

test_unconfirmed_switch_does_not_kick() {
  case_dir unconfirmed
  write_lane_meta lane-g 'opus'
  screen_json "$SCREENS/1.json" '❯'
  screen_json "$SCREENS/2.json" '❯'
  screen_json "$SCREENS/3.json" '❯'
  # The verify read still shows the old model: the submit landed but the switch
  # did not take, so the lane must not be told to resume work.
  screen_json "$SCREENS/4.json" 'Opus 5 · 200k context' '❯'
  run_switch lane-g 'opus[1m]'
  expect_code 1 "$RC" "an unverified switch must fail"
  assert_contains "$OUT" "does not confirm it" "the failure must name the verification gate"
  assert_no_grep 'MODEL SWITCH:' "$LOG" "the lane must not be kicked when the switch is unconfirmed"
  assert_no_grep 'model_switch_to=' "$STATE/lane-g.meta" "an unconfirmed switch must not be recorded"
  pass "fm-lane-model-switch: an unconfirmed switch fails without kicking the lane"
}

test_echoed_command_alone_does_not_confirm() {
  case_dir echoed-command
  write_lane_meta lane-l 'opus'
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  # Claude Code renders the submitted command back into its transcript before
  # it decides anything, so this screen is what a REJECTED switch looks like:
  # the model name is on it only because this script typed it. The script's own
  # input must never satisfy the script's own proof.
  screen_json "$SCREENS/4.json" 'previous output' '> /model opus[1m]' '❯'
  run_switch lane-l 'opus[1m]'
  expect_code 1 "$RC" "an echo-only screen must not count as a confirmed switch"
  assert_contains "$OUT" "does not confirm it" "the failure must name the verification gate"
  assert_no_grep 'MODEL SWITCH:' "$LOG" "a lane must not be kicked on an echo-only confirmation"
  assert_no_grep 'model_switch_to=' "$STATE/lane-l.meta" "an echo-only confirmation must not be recorded"
  assert_grep 'model=opus' "$STATE/lane-l.meta" "the recorded model must still be the one before the attempt"
  pass "fm-lane-model-switch: the echoed /model command alone does not confirm a switch"
}

test_dry_run_sends_nothing() {
  case_dir dry-run
  write_lane_meta lane-h
  screen_json "$SCREENS/1.json" '❯'
  screen_json "$SCREENS/2.json" '❯'
  run_switch lane-h 'opus[1m]' --dry-run
  expect_code 0 "$RC" "a dry run over a clean lane must succeed"
  assert_contains "$OUT" "dry-run:" "the dry run must say what it would do"
  assert_no_grep 'terminal send' "$LOG" "a dry run must not send anything to the lane"
  assert_no_grep 'model_switch_to=' "$STATE/lane-h.meta" "a dry run must not record anything"
  pass "fm-lane-model-switch: a dry run performs the checks and sends nothing"
}

# --- ticks ------------------------------------------------------------------

test_unparsable_tick_source_is_reported_not_fatal() {
  case_dir bad-cron
  write_lane_meta lane-i 'opus'
  screen_json "$SCREENS/1.json" '❯'
  screen_json "$SCREENS/2.json" '❯'
  screen_json "$SCREENS/3.json" '❯'
  screen_json "$SCREENS/4.json" 'Opus 5 · 1M' '❯'
  screen_json "$SCREENS/5.json" 'Opus 5 · 1M' '❯'
  mkdir -p "$DATA/lane-i"
  printf 'not a cron expression\n' > "$DATA/lane-i/crons"
  run_switch lane-i 'opus[1m]'
  expect_code 0 "$RC" "an unparsable tick source must not fail the switch"
  assert_contains "$OUT" "unparsable cron expression" "the tick report must say what it could not read"
  pass "fm-lane-model-switch: an unparsable tick source is reported without failing the switch"
}

test_no_tick_source_says_so() {
  case_dir no-ticks
  write_lane_meta lane-j 'opus'
  screen_json "$SCREENS/1.json" '❯'
  screen_json "$SCREENS/2.json" '❯'
  screen_json "$SCREENS/3.json" '❯'
  screen_json "$SCREENS/4.json" 'Opus 5 · 1M' '❯'
  screen_json "$SCREENS/5.json" 'Opus 5 · 1M' '❯'
  run_switch lane-j 'opus[1m]'
  expect_code 0 "$RC" "a lane with no recorded tick must still switch"
  assert_contains "$OUT" "no tick source recorded" "the tick report must admit it has no source"
  assert_contains "$OUT" "verify the lane actually fires" "the operator must be told what to verify by hand"
  pass "fm-lane-model-switch: a lane with no recorded tick source is told to verify by hand"
}

test_meta_cron_line_is_a_tick_source() {
  case_dir meta-cron
  write_lane_meta lane-k 'opus'
  printf 'cron=13 14 * * *\n' >> "$STATE/lane-k.meta"
  screen_json "$SCREENS/1.json" '❯'
  screen_json "$SCREENS/2.json" '❯'
  screen_json "$SCREENS/3.json" '❯'
  screen_json "$SCREENS/4.json" 'Opus 5 · 1M' '❯'
  screen_json "$SCREENS/5.json" 'Opus 5 · 1M' '❯'
  run_switch lane-k 'opus[1m]' --now 2026-09-17T19:05:00Z
  expect_code 0 "$RC" "a metadata cron line must be honoured"
  assert_contains "$OUT" "next-tick: 13 14 * * *" "the metadata tick source must be reported"
  assert_contains "$OUT" "2026-09-18T14:13:00Z" "the next fire time must be the next day's 14:13"
  pass "fm-lane-model-switch: a cron= metadata line is used as a tick source"
}

test_dirty_composer_is_refused
test_unreadable_screen_sends_nothing
test_non_claude_lane_is_refused
test_remote_lane_is_refused
test_gate_agent_is_refused_before_any_backend_call
test_unhealthy_gateway_is_refused_before_the_lane
test_gateway_value_form_is_refused
test_clean_switch_verifies_records_and_kicks
test_plain_switch_leaves_the_gateway_repoint_untouched
test_unconfirmed_switch_does_not_kick
test_echoed_command_alone_does_not_confirm
test_dry_run_sends_nothing
test_unparsable_tick_source_is_reported_not_fatal
test_no_tick_source_says_so
test_meta_cron_line_is_a_tick_source

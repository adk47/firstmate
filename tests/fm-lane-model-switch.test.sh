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

# The fake Orca CLI below records its argv joined by US (0x1f), so this is the
# substring a real `orca terminal send` leaves in the log.
LANE_SEND=$'terminal\x1fsend'
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

# A NON-Orca lane: window= and no terminal=, which is what cmux, herdr, tmux
# and zellij lanes actually record. The tick guard must reach these too.
write_tmux_lane_meta() {  # <id> [model]
  local id=$1 model=${2:-opus[1m]}
  fm_write_meta "$STATE/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "harness=claude" \
    "kind=ship" \
    "model=$model" \
    "backend=tmux"
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
  local saved mode
  saved=$(grep -rl 'rm -rf /important' "$DATA/lane-model-switch/pending-composer") \
    || fail "the saved capture must contain the text the composer held"
  # That capture holds whatever the composer was holding - here a destructive
  # command, and equally a pasted credential - so it carries the same mode as
  # every other artifact this tool writes.
  mode=$(stat -c '%a' "$saved" 2>/dev/null || stat -f '%Lp' "$saved")
  [ "$mode" = "600" ] || fail "the saved composer capture must be mode 0600, got $mode"
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
  assert_no_grep "$LANE_SEND" "$LOG" "an unreadable screen must not send anything to the lane"
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
  run_switch lane-f 'opus[1m]'
  expect_code 0 "$RC" "a clean lane must switch"
  assert_contains "$OUT" "switched: lane-f opus -> opus[1m]" "the switch must be reported with before and after"
  assert_contains "$OUT" "kicked:" "the lane must be kicked back to work"
  assert_contains "$OUT" "ticks:   7,37 * * * *" "the lane's recorded cron expression must be printed verbatim"
  # Positive control for the "nothing was typed into the lane" assertions
  # elsewhere in this suite: on the one path that really does type into a lane,
  # the same pattern those assertions forbid must be present.
  assert_grep "$LANE_SEND" "$LOG" "a lane that switches must be typed into"
  assert_grep '--text' "$LOG" "the model spec must reach the lane"
  assert_grep '/model opus[1m]' "$LOG" "the /model command must be typed verbatim"
  assert_grep 'model_switch_to=opus[1m]' "$STATE/lane-f.meta" "the switch must be recorded in metadata"
  assert_grep 'model_switch_from=opus' "$STATE/lane-f.meta" "the previous model must be recorded"
  assert_grep 'model=opus[1m]' "$STATE/lane-f.meta" "the metadata model must follow the switch"
  pass "fm-lane-model-switch: a clean lane switches, verifies, records, and reports its recorded ticks"
}

test_retry_after_a_slow_redraw_is_recorded() {
  case_dir retry-after-redraw
  write_lane_meta lane-p 'opus'
  # The lane applied an earlier attempt after that attempt had already given
  # up, so the target model is ALREADY on the pre-submit screen. The retry's
  # own confirmation is byte-identical to it, and a bottom-anchored pane
  # renders it above the composer rather than after it; the fresh line must
  # still count, so the retry records the switch.
  screen_json "$SCREENS/1.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/2.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/3.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'Opus 5 · 1M context' \
    '> /model opus[1m]' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'Opus 5 · 1M context' \
    '> /model opus[1m]' 'Opus 5 · 1M context' '❯'
  run_switch lane-p 'opus[1m]'
  expect_code 0 "$RC" "a retry whose confirmation repeats an existing line must still be recorded: $OUT"
  assert_contains "$OUT" "switched: lane-p opus -> opus[1m]" "the retry must report the switch"
  assert_grep 'model=opus[1m]' "$STATE/lane-p.meta" "the retry must record the model the lane is actually on"
  pass "fm-lane-model-switch: a retry confirmed by a repeated line is still recorded"
}

# scrolled_screen_lines: a full 200-line pane whose transcript already carries
# this script's OWN earlier kick text, which names the target model. That line
# is the stale evidence a scroll-blind rule would accept.
scrolled_screen_lines() {
  local i
  for i in $(seq 1 4); do printf 'transcript line %03d\n' "$i"; done
  printf 'MODEL SWITCH: this lane is now on deepseek-v4.1-flash. Resume your standing goal.\n'
  for i in $(seq 6 199); do printf 'transcript line %03d\n' "$i"; done
  printf '❯\n'
}

# scroll_case: queue a full pane, then the same pane scrolled up by three lines
# with <extra> rendered above the composer. The stale model mention survives
# the scroll inside the carried-over transcript either way.
scroll_case() {  # <name> <lane> [extra-line]
  local name=$1 lane=$2 extra=${3:-} line
  case_dir "$name"
  write_lane_meta "$lane" 'opus'
  BASE_LINES=()
  while IFS= read -r line; do BASE_LINES+=("$line"); done < <(scrolled_screen_lines)
  [ "${#BASE_LINES[@]}" = 200 ] || fail "the scrolled fixture must be a full 200-line pane"
  local carried=("${BASE_LINES[@]:3:196}")
  local after=("${carried[@]}" '> /model deepseek-v4.1-flash')
  [ -z "$extra" ] || after+=("$extra")
  after+=('❯')
  screen_json "$SCREENS/1.json" "${BASE_LINES[@]}"
  screen_json "$SCREENS/2.json" "${BASE_LINES[@]}"
  screen_json "$SCREENS/3.json" "${BASE_LINES[@]}"
  screen_json "$SCREENS/4.json" "${after[@]}"
  screen_json "$SCREENS/5.json" "${after[@]}"
}

test_scrolled_pane_does_not_confirm_from_stale_transcript() {
  # The pane scrolled and the client rendered no confirmation of its own: the
  # only occurrence of the model name is the stale kick line carried over from
  # before the submit, so nothing may be recorded and the lane must not be
  # kicked.
  scroll_case scrolled-stale lane-s
  run_switch lane-s 'deepseek-v4.1-flash'
  expect_code 1 "$RC" "a stale transcript mention must not confirm a switch"
  assert_contains "$OUT" "does not confirm it" "the failure must name the verification gate"
  assert_no_grep 'MODEL SWITCH:' "$LOG" "the lane must not be kicked on stale evidence"
  assert_no_grep 'model_switch_to=' "$STATE/lane-s.meta" "a switch confirmed only by stale text must not be recorded"
  assert_grep 'model=opus' "$STATE/lane-s.meta" "the recorded model must still be the one before the attempt"

  # The same scrolled pane, but the client really did render the switch below
  # the carried-over transcript: that one must verify.
  scroll_case scrolled-confirmed lane-t 'model set to deepseek-v4.1-flash (routed)'
  run_switch lane-t 'deepseek-v4.1-flash'
  expect_code 0 "$RC" "a genuine confirmation on a scrolled pane must verify: $OUT"
  assert_contains "$OUT" "switched: lane-t opus -> deepseek-v4.1-flash" "the switch must be reported"
  assert_grep 'model_switch_to=deepseek-v4.1-flash' "$STATE/lane-t.meta" "the switch must be recorded"
  # The other half of the assertion above: the real kick text DOES reach a lane
  # whose switch confirmed, so the stale-evidence case can actually fail.
  assert_grep 'MODEL SWITCH:' "$LOG" "a confirmed switch must kick the lane back to work"
  pass "fm-lane-model-switch: a scrolled pane confirms only on genuinely new output"
}

test_client_model_rejection_is_not_a_confirmation() {
  case_dir model-rejection
  write_lane_meta lane-q 'opus'
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  # Claude Code's own refusal QUOTES the model id, so it satisfies any check
  # that merely looks for the name. This is the client saying no.
  screen_json "$SCREENS/4.json" 'previous output' '> /model deepseek-v4.1-flash' \
    "There's an issue with the selected model (deepseek-v4.1-flash). It may not exist or you may not have access to it." '❯'
  run_switch lane-q 'deepseek-v4.1-flash'
  expect_code 1 "$RC" "a rendered model rejection must not count as a switch"
  assert_contains "$OUT" "does not confirm it" "the failure must name the verification gate"
  assert_no_grep 'MODEL SWITCH:' "$LOG" "a rejected lane must not be kicked"
  assert_no_grep 'model_switch_to=' "$STATE/lane-q.meta" "a rejected switch must not be recorded"
  assert_grep 'model=opus' "$STATE/lane-q.meta" "the recorded model must still be the one before the attempt"
  pass "fm-lane-model-switch: the client's own model rejection is not read as a confirmation"
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

# repoint_pool_lane: the first --gateway run against a lane that has never been
# repointed. Asserts the record-first contract and leaves the env in place for
# the caller.
repoint_pool_lane() {  # <lane-id>
  local id=$1
  run_switch "$id" gateway --gateway
  expect_code 0 "$RC" "recording a repoint must succeed without an in-place switch: $OUT"
  assert_present "$STATE/$id.gateway.env" "the repoint must be written for the lane's next launch"
  assert_grep "ANTHROPIC_BASE_URL=http://127.0.0.1:$SWITCH_GATEWAY_PORT" "$STATE/$id.gateway.env" \
    "the exports must point at the gateway that was probed"
  local mode
  mode=$(stat -c '%a' "$STATE/$id.gateway.env" 2>/dev/null || stat -f '%Lp' "$STATE/$id.gateway.env")
  [ "$mode" = "600" ] || fail "the lane's gateway exports carry a token and must be mode 0600, got $mode"
}

test_repoint_is_recorded_for_a_lane_that_must_relaunch() {
  case_dir gateway-repoint
  write_lane_meta lane-r 'opus'
  start_test_gateway
  # A lane still on the shared account pool: its running session cannot accept
  # the gateway's model id, so the repoint must be recorded for the next launch
  # and nothing may be typed into the lane.
  repoint_pool_lane lane-r
  assert_contains "$OUT" "no /model is sent to it" "the report must say why nothing was typed"
  assert_contains "$OUT" "set -a; . $STATE/lane-r.gateway.env" "the report must print the exact relaunch step"
  assert_contains "$OUT" "/model deepseek-v4.1-flash" "the report must name the model to select after the relaunch"
  assert_no_grep "$LANE_SEND" "$LOG" "a lane that must relaunch must not be typed into"
  assert_no_grep 'model_switch_to=' "$STATE/lane-r.meta" "no model switch happened, so none may be recorded"
  assert_grep 'model=opus' "$STATE/lane-r.meta" "the recorded model must still be the lane's running one"

  # Now that a repoint is on record, the same command does attempt the in-place
  # switch: the env file is the evidence the session may already be on it.
  reset_screens
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  run_switch lane-r gateway --gateway
  expect_code 0 "$RC" "an already-repointed lane must take the in-place switch: $OUT"
  assert_contains "$OUT" "switched: lane-r opus -> deepseek-v4.1-flash" "the advertised model id must be resolved from the gateway"
  assert_grep '/model deepseek-v4.1-flash' "$LOG" "the /model command must reach an already-repointed lane"
  assert_grep 'model_switch_to=deepseek-v4.1-flash' "$STATE/lane-r.meta" "the in-place switch must be recorded"
  pass "fm-lane-model-switch: --gateway records the repoint first and only switches an already-repointed lane"
}

test_tick_owning_lane_is_refused_a_gateway_repoint() {
  case_dir gateway-tick-owner
  write_lane_meta lane-w 'opus'
  write_lane_meta lane-x 'opus'
  start_test_gateway
  # The home's loop registry: lane-w's terminal owns two /loop wakeups, and its
  # terminal is recorded under the pre-reboot name. lane-x is in the same
  # registry with no expected wakeups at all.
  mkdir -p "$DATA/cmux-takeover"
  cat > "$DATA/cmux-takeover/expected-loops.json" <<'JSON'
[
  {"term": "term-other", "term_prior_reboot": "term-lane-w", "expected": ["30m drift sweep", "6h digest"]},
  {"term": "term-lane-x", "expected": []}
]
JSON
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  run_switch lane-w gateway --gateway
  expect_code 2 "$RC" "a lane that owns /loop wakeups must be refused a repoint"
  assert_contains "$OUT" "lane-w owns 2 /loop wakeup" "the refusal must name the lane and what it owns"
  assert_contains "$OUT" "stays on the shared account pool" "the refusal must say where the lane stays"
  assert_absent "$STATE/lane-w.gateway.env" "a refused lane must have no repoint recorded"
  assert_no_grep "$LANE_SEND" "$LOG" "a refused lane must not be typed into"

  # Same registry, an entry with no expected wakeups and no recorded crons:
  # this lane is in scope and takes the repoint.
  run_switch lane-x gateway --gateway
  expect_code 0 "$RC" "a lane the registry records no wakeups for must be allowed: $OUT"
  assert_present "$STATE/lane-x.gateway.env" "an in-scope lane must have its repoint recorded"

  # lane-x is now ON the gateway, and its agent has since armed two /loop
  # wakeups - the ordinary behaviour of these lanes. A later model change for
  # it is sent in place, with no relaunch, so there is no schedule for the
  # switch to cost and the tick refusal must not fire.
  cat > "$DATA/cmux-takeover/expected-loops.json" <<'JSON'
[
  {"term": "term-other", "term_prior_reboot": "term-lane-w", "expected": ["30m drift sweep", "6h digest"]},
  {"term": "term-lane-x", "expected": ["15m watch", "daily report"]}
]
JSON
  reset_screens
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'model set to deepseek-v4.1-flash (routed)' '❯'
  run_switch lane-x gateway --gateway
  expect_code 0 "$RC" "a lane already on the gateway must switch in place however many loops it owns: $OUT"
  assert_contains "$OUT" "switched: lane-x" "the already-repointed lane must take the in-place switch"
  assert_grep 'model_switch_to=deepseek-v4.1-flash' "$STATE/lane-x.meta" "the in-place switch must be recorded"
  pass "fm-lane-model-switch: a first repoint is refused for a tick owner, an already-repointed lane is not"
}

test_non_orca_lane_that_owns_loops_is_refused() {
  case_dir gateway-tmux-tick-owner
  write_tmux_lane_meta lane-z 'opus'
  write_tmux_lane_meta lane-ab 'opus'
  write_tmux_lane_meta lane-ac 'opus'
  start_test_gateway
  # A tmux lane carries no terminal= at all, so a guard that read that field
  # could never fire for it - the lane would be repointed and relaunched, and
  # the wakeups the intent calls unrecoverable would be gone. lane-z is named
  # by its endpoint, lane-ab by the backend-independent firstmate_task key.
  mkdir -p "$DATA/cmux-takeover"
  cat > "$DATA/cmux-takeover/expected-loops.json" <<'JSON'
[
  {"term": "fm-lane-z", "expected": ["10m sweep", "hourly digest"]},
  {"firstmate_task": "lane-ab", "expected": ["nightly report"]},
  {"term": "fm-lane-ac", "expected": []}
]
JSON
  run_switch lane-z gateway --gateway
  expect_code 2 "$RC" "a non-Orca lane that owns /loop wakeups must be refused a first repoint"
  assert_contains "$OUT" "lane-z owns 2 /loop wakeup" "the refusal must name the lane and what it owns"
  assert_contains "$OUT" "fm-lane-z" "the refusal must name the endpoint it matched on"
  assert_absent "$STATE/lane-z.gateway.env" "a refused lane must have no repoint recorded"
  assert_no_grep "$LANE_SEND" "$LOG" "a refused lane must not be typed into"

  run_switch lane-ab gateway --gateway
  expect_code 2 "$RC" "an entry naming the lane by firstmate_task must refuse it too"
  assert_contains "$OUT" "lane-ab owns 1 /loop wakeup" "the firstmate_task join must be honoured"
  assert_absent "$STATE/lane-ab.gateway.env" "a refused lane must have no repoint recorded"

  # Same registry, an entry with no expected wakeups: in scope, takes the repoint.
  run_switch lane-ac gateway --gateway
  expect_code 0 "$RC" "a non-Orca lane the registry records no wakeups for must be allowed: $OUT"
  assert_present "$STATE/lane-ac.gateway.env" "an in-scope lane must have its repoint recorded"
  pass "fm-lane-model-switch: the tick guard reaches a non-Orca lane by its resolved endpoint"
}

test_cron_owning_lane_is_refused_a_gateway_repoint() {
  case_dir gateway-cron-owner
  write_lane_meta lane-y 'opus'
  # No gateway is started: the refusal lands before the health probe, which is
  # itself the point - a tick-owning lane is out of scope whether or not the
  # gateway is up. The port below has nothing behind it.
  SWITCH_GATEWAY_PORT=$(free_port)
  # No loop registry at all; this lane owns ticks under this script's own
  # convention, which is the same unrotatable state.
  mkdir -p "$DATA/lane-y"
  printf '7,37 * * * *\n' > "$DATA/lane-y/crons"
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  run_switch lane-y gateway --gateway
  expect_code 2 "$RC" "a lane that owns recorded crons must be refused a repoint"
  assert_contains "$OUT" "lane-y owns recorded cron ticks" "the refusal must name the lane and the tick source"
  assert_absent "$STATE/lane-y.gateway.env" "a refused lane must have no repoint recorded"
  assert_no_grep "$LANE_SEND" "$LOG" "a refused lane must not be typed into"
  # The same lane still takes a plain model switch: only the repoint is scoped.
  reset_screens
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  screen_json "$SCREENS/3.json" 'previous output' '❯'
  screen_json "$SCREENS/4.json" 'previous output' 'Opus 5 · 1M context' '❯'
  screen_json "$SCREENS/5.json" 'previous output' 'Opus 5 · 1M context' '❯'
  run_switch lane-y 'opus[1m]'
  expect_code 0 "$RC" "a tick-owning lane must still take an in-place model switch: $OUT"
  assert_grep 'model_switch_to=opus[1m]' "$STATE/lane-y.meta" "the in-place switch must still be recorded"
  unset SWITCH_GATEWAY_PORT
  pass "fm-lane-model-switch: a lane with recorded crons is refused a repoint but still switches in place"
}

test_dry_run_gateway_describes_the_run_it_would_make() {
  case_dir gateway-dry-run
  write_lane_meta lane-u 'opus'
  start_test_gateway
  # A dry run over a pool lane must predict the record-only path the real run
  # takes, not a switch the real run would never make - and must write nothing.
  run_switch lane-u gateway --gateway --dry-run
  expect_code 0 "$RC" "a dry run over a pool lane must succeed: $OUT"
  assert_contains "$OUT" "would record the gateway binding" "the dry run must say it would record the repoint"
  assert_contains "$OUT" "no /model is sent to it" "the dry run must predict the record-only path"
  assert_contains "$OUT" "set -a; . $STATE/lane-u.gateway.env" "the dry run must print the same relaunch step"
  assert_absent "$STATE/lane-u.gateway.env" "a dry run must not write the repoint"
  assert_no_grep "$LANE_SEND" "$LOG" "a dry run must not send anything to the lane"
  assert_no_grep 'model_switch_to=' "$STATE/lane-u.meta" "a dry run must not record anything"

  # Once a repoint is on record the real run would switch in place, so the dry
  # run must describe that instead.
  repoint_pool_lane lane-u
  reset_screens
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  screen_json "$SCREENS/2.json" 'previous output' '❯'
  run_switch lane-u gateway --gateway --dry-run
  expect_code 0 "$RC" "a dry run over a repointed lane must succeed: $OUT"
  assert_contains "$OUT" "would switch opus -> deepseek-v4.1-flash" "the dry run must predict the in-place switch"
  assert_no_grep "$LANE_SEND" "$LOG" "a dry run must still send nothing"
  pass "fm-lane-model-switch: a --gateway dry run predicts the branch the real run takes"
}

test_truncated_repoint_is_not_read_as_already_pointed() {
  case_dir gateway-truncated-env
  write_lane_meta lane-v 'opus'
  start_test_gateway
  # A repoint that failed half way leaves nothing usable. An empty file must
  # not be mistaken for durable evidence that the lane is on the gateway, or
  # the next run types the gateway's model into a lane still on the pool.
  : > "$STATE/lane-v.gateway.env"
  screen_json "$SCREENS/1.json" 'previous output' '❯'
  run_switch lane-v gateway --gateway
  expect_code 0 "$RC" "a lane with a truncated repoint must be re-recorded, not switched: $OUT"
  assert_contains "$OUT" "no /model is sent to it" "an empty env file must not count as a recorded repoint"
  assert_no_grep "$LANE_SEND" "$LOG" "a lane with a truncated repoint must not be typed into"
  [ -s "$STATE/lane-v.gateway.env" ] || fail "the run must replace the truncated repoint with real exports"
  assert_grep "ANTHROPIC_BASE_URL=http://127.0.0.1:$SWITCH_GATEWAY_PORT" "$STATE/lane-v.gateway.env" \
    "the rewritten exports must point at the gateway"
  pass "fm-lane-model-switch: a truncated repoint file is not read as an already-pointed lane"
}

test_plain_switch_leaves_the_gateway_repoint_untouched() {
  case_dir gateway-then-plain
  write_lane_meta lane-m 'opus'
  start_test_gateway
  repoint_pool_lane lane-m
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
  assert_no_grep "$LANE_SEND" "$LOG" "a dry run must not send anything to the lane"
  assert_no_grep 'model_switch_to=' "$STATE/lane-h.meta" "a dry run must not record anything"
  pass "fm-lane-model-switch: a dry run performs the checks and sends nothing"
}

# --- ticks ------------------------------------------------------------------

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
  run_switch lane-k 'opus[1m]'
  expect_code 0 "$RC" "a metadata cron line must be honoured"
  assert_contains "$OUT" "ticks:   13 14 * * *" "the metadata tick source must be reported verbatim"
  assert_contains "$OUT" "watch the next one actually fire" "the operator must be told to watch the real fire"
  pass "fm-lane-model-switch: a cron= metadata line is reported as a tick source"
}

test_dirty_composer_is_refused
test_unreadable_screen_sends_nothing
test_non_claude_lane_is_refused
test_remote_lane_is_refused
test_gate_agent_is_refused_before_any_backend_call
test_unhealthy_gateway_is_refused_before_the_lane
test_gateway_value_form_is_refused
test_clean_switch_verifies_records_and_kicks
test_retry_after_a_slow_redraw_is_recorded
test_scrolled_pane_does_not_confirm_from_stale_transcript
test_repoint_is_recorded_for_a_lane_that_must_relaunch
test_tick_owning_lane_is_refused_a_gateway_repoint
test_non_orca_lane_that_owns_loops_is_refused
test_cron_owning_lane_is_refused_a_gateway_repoint
test_dry_run_gateway_describes_the_run_it_would_make
test_truncated_repoint_is_not_read_as_already_pointed
test_plain_switch_leaves_the_gateway_repoint_untouched
test_unconfirmed_switch_does_not_kick
test_echoed_command_alone_does_not_confirm
test_client_model_rejection_is_not_a_confirmation
test_dry_run_sends_nothing
test_no_tick_source_says_so
test_meta_cron_line_is_a_tick_source

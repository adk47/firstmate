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
ORCA="$TMP_ROOT/orca.sh"
ORCA_LOG="$TMP_ROOT/orca.log"
cat > "$SENSOR" <<'SH'
#!/usr/bin/env bash
# fable is the OR of the two pools, exactly as bin/fm-chair-runway.sh reports it.
p=${FM_TEST_POOL8317:-green}; c=${FM_TEST_CCFLARE:-red}
if [ -n "${FM_TEST_FABLE:-}" ]; then f=$FM_TEST_FABLE
elif [ "$p" = green ] || [ "$c" = green ]; then f=green
elif [ "$p" = red ] && [ "$c" = red ]; then f=red
else f=unknown; fi
printf 'chair-runway: fable=%s pool8317=%s probe=x ccflare=%s routable=0/11 needs_reauth=0 names=none grok=%s grok_pct=%s reason=x\n' \
  "$f" "$p" "$c" "${FM_TEST_GROK:-green}" "${FM_TEST_GROK_PCT:-50}"
SH
cat > "$STATUS" <<'SH'
#!/usr/bin/env bash
c=${FM_TEST_CHAIR:-grok}
case "$c" in pi-fable) h=pi ;; none) h=${FM_TEST_HARNESS:-none} ;; *) h=$c ;; esac
printf 'chair-status: chair=%s harness=%s terminal=%s pid=%s reason=x\n' \
  "$c" "$h" "${FM_TEST_TERMINAL:-term_x}" "${FM_TEST_PID:-none}"
SH
cat > "$ORCA" <<'SH'
#!/usr/bin/env bash
# Records every invocation; `terminal create` answers with a handle.
printf '%s\n' "$*" >> "$FM_TEST_ORCA_LOG"
case "$1 $2" in
  "terminal create") printf '{"result":{"terminal":{"handle":"term_new"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
chmod +x "$SENSOR" "$STATUS" "$ORCA"

run_flip() {  # <to> [env assignments already exported]
  FM_CHAIR_FLIP_DRY_RUN=1 \
  FM_CHAIR_FLIP_HOME="$HOME_DIR" \
  FM_CHAIR_FLIP_SENSOR_CMD="$SENSOR" \
  FM_CHAIR_FLIP_STATUS_CMD="$STATUS" \
  FM_CHAIR_FLIP_SLEEP_CMD=true \
  bash "$SCRIPT" "$@"
}

run_flip_live() {  # <to>: no dry run, Orca replaced by the recording stub
  : > "$ORCA_LOG"
  FM_CHAIR_FLIP_DRY_RUN=0 \
  FM_CHAIR_FLIP_HOME="$HOME_DIR" \
  FM_CHAIR_FLIP_SENSOR_CMD="$SENSOR" \
  FM_CHAIR_FLIP_STATUS_CMD="$STATUS" \
  FM_CHAIR_FLIP_SLEEP_CMD=true \
  FM_CHAIR_FLIP_ORCA_CMD="${FM_TEST_ORCA_CMD:-$ORCA}" \
  FM_TEST_ORCA_LOG="$ORCA_LOG" \
  FM_CHAIR_VERIFY_SECS=0 \
  bash "$SCRIPT" "$@"
}

# --- dry run writes the handoff and prints commands -------------------------

rm -f "$HOME_DIR/state/.chair-flip-at"
printf 'done: something\n' > "$HOME_DIR/state/task-a.status"
out=$(FM_TEST_FABLE=green FM_TEST_CHAIR=grok run_flip to-pi-fable)
assert_contains "$out" "DRY-RUN" "dry run prints commands"
assert_contains "$out" "terminal create" "dry run prints the launch"
assert_contains "$out" "DRY-RUN: orca terminal send --terminal term_x --text /exit --enter --json" "dry run shows the graceful exit it would send"
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

# --- the successor is launched on the source that is actually green ---------

out=$(FM_TEST_POOL8317=green FM_TEST_CCFLARE=red FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 0 "$code" "8317 green flips"
assert_contains "$out" "token-pool/claude-fable-5-1" "8317 green launches Pi on the token-pool provider"
assert_not_contains "$out" "ANTHROPIC_BASE_URL" "8317 green does not point Pi at 8080"
assert_contains "$out" "source=8317" "output records the 8317 source"
handoff=$(cat "$HOME_DIR/data/handoff-grok-to-pi-fable.md")
assert_contains "$handoff" "source=8317" "handoff records the 8317 source"
pass "8317 green -> pi on token-pool, source=8317"

out=$(FM_TEST_POOL8317=red FM_TEST_CCFLARE=green FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 0 "$code" "8080 alone green flips"
assert_contains "$out" "ANTHROPIC_BASE_URL=http://127.0.0.1:8080" "only 8080 green launches Pi against the 8080 gateway"
assert_contains "$out" "anthropic/claude-fable-5-1" "8080 uses the anthropic provider"
assert_not_contains "$out" "token-pool/" "8080 alone never launches toward the dead 8317"
assert_contains "$out" "source=8080" "output records the 8080 source"
handoff=$(cat "$HOME_DIR/data/handoff-grok-to-pi-fable.md")
assert_contains "$handoff" "source=8080" "handoff records the 8080 source"
pass "only 8080 green -> pi on the 8080 gateway, source=8080"

out=$(FM_TEST_POOL8317=unknown FM_TEST_CCFLARE=green FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 0 "$code" "8317 unknown + 8080 green flips"
assert_contains "$out" "source=8080" "8317 unknown is not a launch target"
assert_not_contains "$out" "token-pool/" "8317 unknown never receives the chair"
pass "8317 unknown + 8080 green -> 8080"

out=$(FM_TEST_POOL8317=green FM_TEST_CCFLARE=green FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 0 "$code" "both green flips"
assert_contains "$out" "source=8317" "both green prefers 8317"
pass "both green -> 8317"

out=$(FM_TEST_FABLE=red FM_TEST_GROK=green FM_TEST_CHAIR=pi-fable run_flip to-grok); code=$?
expect_code 0 "$code" "to-grok flips"
assert_contains "$out" "source=supergrok" "to-grok records the SuperGrok source"
assert_contains "$out" "DRY-RUN: orca terminal send --terminal term_x --text /quit --enter --json" "a pi incumbent is asked to /quit, Pi's own exit command"
assert_contains "$out" "--command 'grok --always-approve '" "grok is launched in the verified unattended form"
assert_not_contains "$out" "permission-mode" "no unverified permission flag"
pass "to-grok -> source=supergrok, pi asked to /quit, grok --always-approve"

# --- refusals ---------------------------------------------------------------

out=$(FM_TEST_FABLE=unknown FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 1 "$code" "unknown target refuses"
assert_contains "$out" "unknown" "refusal names the unknown source"
pass "refuses to flip toward an unknown source"

out=$(FM_TEST_FABLE=red FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 1 "$code" "red target refuses"
pass "refuses to flip toward a red source"

out=$(FM_TEST_FABLE=green FM_TEST_POOL8317=unknown FM_TEST_CCFLARE=unknown FM_TEST_CHAIR=grok run_flip to-pi-fable); code=$?
expect_code 1 "$code" "fable green with no green pool refuses"
assert_contains "$out" "no green Fable source" "refusal names the missing source"
pass "refuses when no concrete Fable source is green"

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

# --- never end the incumbent when Orca cannot launch the successor ----------

rm -f "$HOME_DIR/state/.chair-flip-at" "$HOME_DIR/data/handoff-grok-to-pi-fable.md"
out=$(FM_TEST_ORCA_CMD="$TMP_ROOT/no-such-orca" FM_TEST_CHAIR=grok run_flip_live to-pi-fable); code=$?
expect_code 1 "$code" "missing orca refuses"
assert_contains "$out" "not found" "refusal names the missing Orca CLI"
assert_absent "$HOME_DIR/state/.chair-flip-at" "nothing acted, so no hysteresis stamp"
assert_absent "$HOME_DIR/data/handoff-grok-to-pi-fable.md" "refused before the handoff"
[ ! -s "$ORCA_LOG" ] || fail "no terminal was touched"
pass "orca missing -> refuse before any side effect"

# --- a flip that acted is stamped even when verification fails -------------

rm -f "$HOME_DIR/state/.chair-flip-at" "$HOME_DIR/state/.lock"
out=$(FM_TEST_CHAIR=grok run_flip_live to-pi-fable); code=$?
expect_code 1 "$code" "verification fails with no successor lock"
assert_contains "$out" "verification failed" "failure reported"
assert_present "$HOME_DIR/state/.chair-flip-at" "hysteresis stamp written once the flip acted"
assert_grep "terminal send --terminal term_x --text /exit --enter --json" "$ORCA_LOG" "/exit is submitted with Enter"
assert_grep "terminal create --worktree path:" "$ORCA_LOG" "successor terminal created"
pass "acted-then-failed flip is bounded by the hysteresis window"

# --- the first prompt rides the launch command, never a post-create send ----

create_line=$(grep -F "terminal create" "$ORCA_LOG")
assert_contains "$create_line" "pi --model token-pool/claude-fable-5-1 --thinking high 'Take the helm: run bin/fm-session-start.sh, then read $HOME_DIR/data/handoff-grok-to-pi-fable.md" \
  "the prompt is the harness's positional argument in --command"
assert_no_grep "terminal send --terminal term_new" "$ORCA_LOG" "nothing is typed into the successor's shell"
pass "first prompt passed as a launch argument"

out=$(FM_TEST_CHAIR=grok run_flip_live to-pi-fable); code=$?
expect_code 1 "$code" "immediate retry refuses"
assert_contains "$out" "hysteresis" "retry lands in the hysteresis window"
[ ! -s "$ORCA_LOG" ] || fail "retry within the window touches no terminal"
pass "no unbounded relaunch loop after a failed verification"

# --- only the harness pid status identified is ever signalled ---------------

assert_dies() {  # <pid> <msg>: the pid exits within 5s (zombies count as exited)
  local i stat
  for i in $(seq 1 50); do
    stat=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
    case "$stat" in ''|Z*) wait "$1" 2>/dev/null; return 0 ;; esac
    sleep 0.1
  done
  fail "$2"
}

sleep 300 & INCUMBENT=$!
sleep 300 & BYSTANDER=$!
trap 'kill "$INCUMBENT" "$BYSTANDER" 2>/dev/null; fm_test_cleanup' EXIT
rm -f "$HOME_DIR/state/.chair-flip-at"
printf '%s\n' "$BYSTANDER" > "$HOME_DIR/state/.lock"
out=$(FM_TEST_CHAIR=grok FM_TEST_PID="$INCUMBENT" FM_CHAIR_EXIT_WAIT_SECS=4 run_flip_live to-pi-fable); code=$?
assert_contains "$out" "incumbent pid $INCUMBENT still alive" "the status pid is the one waited on and signalled"
assert_dies "$INCUMBENT" "the incumbent harness pid was not ended"
kill -0 "$BYSTANDER" 2>/dev/null || fail "the unrelated pid in state/.lock was signalled"
pass "SIGTERM targets the status pid, never the raw lock pid"

rm -f "$HOME_DIR/state/.chair-flip-at"
printf '%s\n' "$BYSTANDER" > "$HOME_DIR/state/.lock"
out=$(FM_TEST_CHAIR=none FM_TEST_TERMINAL=none FM_CHAIR_EXIT_WAIT_SECS=4 run_flip_live to-pi-fable); code=$?
assert_not_contains "$out" "SIGTERM" "a stale lock with a recycled pid signals nothing"
kill -0 "$BYSTANDER" 2>/dev/null || fail "the recycled lock pid was signalled"
assert_grep "terminal create" "$ORCA_LOG" "the successor is still launched"
pass "chair=none pid=none -> nothing signalled, successor launched"

# --- a context-full Pi with a known terminal still gets /exit ---------------

sleep 300 & FULL_PI=$!
trap 'kill "$INCUMBENT" "$BYSTANDER" "$FULL_PI" 2>/dev/null; fm_test_cleanup' EXIT
rm -f "$HOME_DIR/state/.chair-flip-at"
out=$(FM_TEST_CHAIR=none FM_TEST_HARNESS=pi FM_TEST_TERMINAL=term_full FM_TEST_PID="$FULL_PI" FM_CHAIR_EXIT_WAIT_SECS=4 run_flip_live to-pi-fable); code=$?
assert_grep "terminal send --terminal term_full --text /quit --enter --json" "$ORCA_LOG" "/quit (Pi's exit command) reaches the context-full Pi's terminal"
assert_no_grep "text /exit" "$ORCA_LOG" "Pi is never sent /exit, which it would submit as a chat message"
assert_dies "$FULL_PI" "the context-full Pi was not ended"
pass "chair=none pi with a terminal -> graceful /quit first, then SIGTERM"

# --- no terminal known: the log says so before the wait + SIGTERM ------------

sleep 300 & BLIND=$!
trap 'kill "$INCUMBENT" "$BYSTANDER" "$FULL_PI" "$BLIND" 2>/dev/null; fm_test_cleanup' EXIT
rm -f "$HOME_DIR/state/.chair-flip-at"
out=$(FM_TEST_CHAIR=claude FM_TEST_TERMINAL=none FM_TEST_PID="$BLIND" FM_CHAIR_EXIT_WAIT_SECS=4 run_flip_live to-pi-fable); code=$?
assert_contains "$out" "no terminal or exit command known for incumbent claude pid $BLIND" "log line names the missing terminal"
assert_no_grep "terminal send" "$ORCA_LOG" "no exit command without a terminal"
assert_dies "$BLIND" "the terminal-less incumbent was not ended"
pass "no terminal -> logged, then wait + SIGTERM"

printf 'fm-chair-flip tests passed\n'
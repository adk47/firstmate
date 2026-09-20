#!/usr/bin/env bash
# tests/fm-chair-status.test.sh - classifier tests for bin/fm-chair-status.sh.
#
# The lock pid is a real live process (this test shell), so liveness is
# exercised for real; the command line and Orca inventory are fed through the
# script's documented seams.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-chair-status-tests)
SCRIPT="$ROOT/bin/fm-chair-status.sh"
LOCK="$TMP_ROOT/lock"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"

PS_CMD="$TMP_ROOT/ps.sh"
ORCA_CMD="$TMP_ROOT/orca.sh"
cat > "$PS_CMD" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_CMDLINE:-}"
SH
cat > "$ORCA_CMD" <<'SH'
#!/usr/bin/env bash
# Stands in for the Orca CLI: `terminal list` answers with the inventory
# fixture, `terminal read --screen` with the rendered-screen fixture (the only
# surface that carries Pi's footer), and records the read it was asked for.
case "$1 $2" in
  "terminal list")
    if [ -n "${FM_TEST_ORCA_JSON:-}" ]; then printf '%s\n' "$FM_TEST_ORCA_JSON"; else printf '%s\n' '{"result":{"terminals":[]}}'; fi
    ;;
  "terminal read")
    printf '%s\n' "$*" >> "$FM_TEST_ORCA_READ_LOG"
    printf '%s' "${FM_TEST_ORCA_SCREEN:-}" | jq -Rs '{result:{terminal:{tail:(split("\n") | map(select(length > 0)))}}}'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$PS_CMD" "$ORCA_CMD"
READ_LOG="$TMP_ROOT/orca-read.log"

run_status() {
  : > "$READ_LOG"
  FM_CHAIR_STATUS_LOCK="$LOCK" \
  FM_CHAIR_STATUS_PS_CMD="$PS_CMD" \
  FM_CHAIR_STATUS_ORCA_CMD="$ORCA_CMD" \
  FM_CHAIR_HOME_DIR="$HOME_DIR" \
  FM_TEST_ORCA_JSON="${FM_TEST_ORCA_JSON:-}" \
  FM_TEST_ORCA_SCREEN="${FM_TEST_ORCA_SCREEN:-}" \
  FM_TEST_ORCA_READ_LOG="$READ_LOG" \
  bash "$SCRIPT" "$@"
}

orca_json() {  # <agentIdentity> <title> [connected] [preview]
  printf '{"result":{"terminals":[{"handle":"term_x","worktreePath":"%s","agentIdentity":"%s","title":"%s","connected":%s,"preview":"%s"}]}}' \
    "$HOME_DIR" "$1" "$2" "${3:-true}" "${4:-}"
}

orca_json_two() {  # <agentIdentity> <title1> <title2>
  printf '{"result":{"terminals":[{"handle":"term_x","worktreePath":"%s","agentIdentity":"%s","title":"%s","connected":true},{"handle":"term_y","worktreePath":"%s","agentIdentity":"%s","title":"%s","connected":true}]}}' \
    "$HOME_DIR" "$1" "$2" "$HOME_DIR" "$1" "$3"
}

# --- no lock / dead pid -----------------------------------------------------

rm -f "$LOCK"
out=$(run_status)
assert_contains "$out" "chair=none" "absent lock is no chair"
assert_contains "$out" "reason=no_lock" "absent lock reason"
pass "absent lock -> none"

printf '999999\n' > "$LOCK"
out=$(run_status)
assert_contains "$out" "chair=none" "dead pid is no chair"
assert_contains "$out" "reason=stale_lock" "dead pid reason"
pass "dead lock pid -> none"

# --- live harnesses ---------------------------------------------------------

printf '%s\n' "$$" > "$LOCK"
export FM_TEST_ORCA_JSON
FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate")
out=$(FM_TEST_CMDLINE='grok --permission-mode bypassPermissions' run_status)
assert_contains "$out" "chair=grok" "grok command line classifies as grok"
assert_contains "$out" "terminal=term_x" "chair terminal matched by title"
pass "live grok harness -> chair=grok with its terminal"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
out=$(FM_TEST_CMDLINE='pi --model token-pool/claude-fable-5-1' run_status)
assert_contains "$out" "chair=pi-fable" "pi command line classifies as pi-fable"
pass "live pi harness -> chair=pi-fable"

FM_TEST_ORCA_JSON=$(orca_json claude "claude - firstmate")
out=$(FM_TEST_CMDLINE='claude --dangerously-skip-permissions' run_status)
assert_contains "$out" "chair=claude" "claude command line classifies as claude"
pass "live claude harness -> chair=claude"

out=$(FM_TEST_CMDLINE='/bin/zsh -l' run_status)
assert_contains "$out" "chair=none" "a bare shell is not a chair"
pass "non-harness holder -> none"

# --- terminal matching is conservative --------------------------------------

FM_TEST_ORCA_JSON=$(orca_json pi "Pi ready")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "harness still classified"
assert_contains "$out" "terminal=none" "a terminal without the chair title is not matched"
pass "title convention gates terminal matching"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "terminal=term_x" "matching terminal accepted"
pass "matching title and harness selects the terminal"

FM_TEST_ORCA_JSON=$(orca_json grok "Fleet triage - grok")
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "terminal=none" "a grok chair we launched must still carry the firstmate title"
pass "title convention stays for the chairs we launch"

# --- a foreign chair is matched without the title convention ----------------

FM_TEST_ORCA_JSON=$(orca_json claude "Firstmate setup and alternatives")
out=$(FM_TEST_CMDLINE='claude --dangerously-skip-permissions' run_status)
assert_contains "$out" "chair=claude" "claude classified"
assert_contains "$out" "terminal=term_x" "a claude terminal is matched on worktree + connected + identity alone"
pass "foreign claude chair -> its terminal without a firstmate title"

FM_TEST_ORCA_JSON=$(orca_json claude "Firstmate setup and alternatives" false)
out=$(FM_TEST_CMDLINE='claude' run_status)
assert_contains "$out" "terminal=none" "a disconnected claude terminal is not matched"
pass "foreign chair still requires a connected terminal"

FM_TEST_ORCA_JSON=$(orca_json_two claude "Session A" "Session B")
out=$(FM_TEST_CMDLINE='claude' run_status)
assert_contains "$out" "chair=claude" "claude classified"
assert_contains "$out" "terminal=none" "two candidate claude terminals fail closed"
assert_contains "$out" "reason=ambiguous_terminal" "ambiguity named"
pass "two foreign candidates -> none (fail closed)"

# --- context-full pi counts as no chair, read from the rendered screen ------

export FM_TEST_ORCA_SCREEN
FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "99.2%/1.0M")
FM_TEST_ORCA_SCREEN=''
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "the list preview is not the footer surface"
assert_grep "terminal read --terminal term_x --screen --json" "$READ_LOG" "the rendered screen of the matched terminal is read"
pass "footer is read from terminal read --screen, never from the list preview"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
FM_TEST_ORCA_SCREEN=$'> \n\nclaude-fable-5-1  ↑1.2M ↓40.1k  99.2%/1.0M'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=none" "a 99.2%-context pi chair is no chair"
assert_contains "$out" "reason=context_full" "context-full reason"
assert_contains "$out" "terminal=term_x" "its terminal is still reported so /exit can reach it"
assert_contains "$out" "pid=$$" "its pid is still reported"
pass "screen footer 99.2%/1.0M -> none, terminal and pid kept"

FM_TEST_ORCA_SCREEN=$'claude-fable-5-1  ↑1.2M ↓40.1k  100.0%/1.0M'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=none" "a 100.0%-context pi chair is no chair"
pass "screen footer 100.0%/1.0M -> none"

FM_TEST_ORCA_SCREEN=$'claude-fable-5-1  ↑1.2M ↓40.1k  42.0%/1.0M'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "a 42%-context pi chair is still the chair"
assert_contains "$out" "terminal=term_x" "its terminal is still reported"
pass "screen footer 42.0%/1.0M -> pi-fable"

FM_TEST_ORCA_SCREEN=$'I noticed the context was at 100% so I ran /compact.\ncontext: 100% used before, fine now\nclaude-fable-5-1  12.0%/1.0M'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "prose mentioning 100% context is not a full footer"
assert_contains "$out" "reason=live_harness" "no context_full reason from prose"
pass "chatty screen mentioning 100% context -> still pi-fable"

FM_TEST_ORCA_SCREEN=$'99.9%/1.0M (before compact)\nclaude-fable-5-1  8.5%/1.0M'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "the last footer token wins"
pass "last footer token on the screen is the one consulted"

FM_TEST_ORCA_SCREEN=$'starting up...'
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "a screen with no footer token is not full"
pass "no footer token -> not full"

FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate")
FM_TEST_ORCA_SCREEN=$'99.9%/1.0M'
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "chair=grok" "the footer rule is Pi-only"
[ ! -s "$READ_LOG" ] || fail "a grok chair's screen is never read"
pass "context rule does not apply to a grok chair"

printf 'fm-chair-status tests passed\n'
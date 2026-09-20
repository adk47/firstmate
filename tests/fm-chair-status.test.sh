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
if [ -n "${FM_TEST_ORCA_JSON:-}" ]; then
  printf '%s\n' "$FM_TEST_ORCA_JSON"
else
  printf '%s\n' '{"result":{"terminals":[]}}'
fi
SH
chmod +x "$PS_CMD" "$ORCA_CMD"

run_status() {
  FM_CHAIR_STATUS_LOCK="$LOCK" \
  FM_CHAIR_STATUS_PS_CMD="$PS_CMD" \
  FM_CHAIR_STATUS_ORCA_CMD="$ORCA_CMD" \
  FM_CHAIR_HOME_DIR="$HOME_DIR" \
  FM_TEST_ORCA_JSON="${FM_TEST_ORCA_JSON:-}" \
  bash "$SCRIPT" "$@"
}

orca_json() {  # <agentIdentity> <title> [connected] [preview]
  printf '{"result":{"terminals":[{"handle":"term_x","worktreePath":"%s","agentIdentity":"%s","title":"%s","connected":%s,"preview":"%s"}]}}' \
    "$HOME_DIR" "$1" "$2" "${3:-true}" "${4:-}"
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

# --- context-full pi counts as no chair, read from the footer token only ----

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "claude-fable-5-1  ↑1.2M ↓40.1k  99.2%/1.0M")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=none" "a 99.2%-context pi chair is no chair"
assert_contains "$out" "reason=context_full" "context-full reason"
pass "footer 99.2%/1.0M -> none"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "claude-fable-5-1  ↑1.2M ↓40.1k  100.0%/1.0M")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=none" "a 100.0%-context pi chair is no chair"
pass "footer 100.0%/1.0M -> none"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "claude-fable-5-1  ↑1.2M ↓40.1k  42.0%/1.0M")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "a 42%-context pi chair is still the chair"
assert_contains "$out" "terminal=term_x" "its terminal is still reported"
pass "footer 42.0%/1.0M -> pi-fable"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "I noticed the context was at 100% so I ran /compact; context: 100% used before, fine now  claude-fable-5-1  12.0%/1.0M")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "prose mentioning 100% context is not a full footer"
assert_contains "$out" "reason=live_harness" "no context_full reason from prose"
pass "chatty pane mentioning 100% context -> still pi-fable"

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate" true "99.9%/1.0M (before compact)  claude-fable-5-1  8.5%/1.0M")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "the last footer token wins"
pass "last footer token in the pane is the one consulted"

FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate" true "99.9%/1.0M")
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "chair=grok" "the footer rule is Pi-only"
pass "context rule does not apply to a grok chair"

printf 'fm-chair-status tests passed\n'
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
  bash "$SCRIPT"
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
assert_contains "$out" "harness=grok" "harness named"
assert_contains "$out" "source=none" "a grok chair has no Fable source"
pass "live grok harness -> chair=grok with its terminal"

# Pi rewrites its process title, so a live Pi reports just `pi` with no model.
FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "chair=pi-fable" "pi command line classifies as pi-fable"
assert_contains "$out" "harness=pi" "the harness itself is pi"
assert_contains "$out" "source=unknown" "with no flip record and no session file the tank is unknown"
pass "live pi harness, no evidence -> chair=pi-fable source=unknown"

out=$(FM_TEST_CMDLINE='/Users/x/.npm-global/bin/pi-signed --model token-pool/claude-fable-5-1' run_status)
assert_contains "$out" "chair=pi-fable" "pi-signed is a pi chair"
assert_contains "$out" "harness=pi-signed" "harness named"
pass "live pi-signed harness -> chair=pi-fable"

FM_TEST_ORCA_JSON=$(orca_json claude "claude - firstmate")
out=$(FM_TEST_CMDLINE='claude --dangerously-skip-permissions' run_status)
assert_contains "$out" "chair=claude" "claude command line classifies as claude"
assert_contains "$out" "harness=claude" "harness named"
pass "live claude harness -> chair=claude"

out=$(FM_TEST_CMDLINE='/Users/x/.local/share/claude/versions/2.1.220 --dangerously-skip-permissions' run_status)
assert_contains "$out" "chair=claude" "a version-named Claude binary is still claude (install path evidence)"
pass "version-named claude binary -> chair=claude"

for h in codex opencode kimi; do
  FM_TEST_ORCA_JSON=$(orca_json "$h" "Some session")
  out=$(FM_TEST_CMDLINE="$h --yolo" run_status)
  assert_contains "$out" "chair=$h" "a verified $h harness is a chair, not holder_not_harness"
  assert_contains "$out" "harness=$h" "harness named"
  assert_contains "$out" "pid=$$" "its pid is reported so the actuator can end it"
  assert_contains "$out" "terminal=term_x" "its terminal is matched without the firstmate title"
done
pass "every harness bin/fm-lock.sh honours is recognised (codex, opencode, kimi)"

FM_TEST_ORCA_JSON=$(printf '{"result":{"terminals":[{"handle":"term_null","worktreePath":"%s","agentIdentity":null,"title":"grok","connected":true}]}}' "$HOME_DIR")
out=$(FM_TEST_CMDLINE='cursor-agent --trust --yolo --workspace /Users/x/firstmate' run_status)
assert_contains "$out" "chair=cursor" "a Cursor primary is a cursor chair, never an empty label"
assert_contains "$out" "harness=cursor" "harness named cursor"
assert_contains "$out" "pid=$$" "its pid is reported"
assert_contains "$out" "terminal=none" "an identity-less tab is not claimed as the cursor chair's terminal"
pass "live cursor-agent harness -> chair=cursor, no identity-less tab match"

out=$(FM_TEST_CMDLINE='/Users/x/.local/share/cursor-agent/versions/2026.09.1/index.js --trust --yolo' run_status)
assert_contains "$out" "chair=cursor" "the versioned Cursor install form is cursor"
pass "versioned cursor-agent install -> chair=cursor"

out=$(FM_TEST_CMDLINE='cursor-agent --trust --yolo --workspace /Users/x/Projects/api-service' run_status)
assert_contains "$out" "chair=cursor" "a workspace path containing 'pi' does not turn Cursor into a Pi chair"
assert_contains "$out" "harness=cursor" "harness stays cursor"
pass "cursor-agent with an incidental 'pi' substring -> chair=cursor"

out=$(FM_TEST_CMDLINE='cursor-agent --trust --yolo "fix the grok pipeline and the kimi codex import"' run_status)
assert_contains "$out" "chair=cursor" "harness names in a positional prompt do not rename a Cursor chair"
pass "cursor-agent with harness names in its prompt -> chair=cursor"

FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate")
out=$(FM_TEST_CMDLINE='node /Users/x/.npm-global/lib/node_modules/@grok/cli/dist/index.js --always-approve' run_status)
assert_contains "$out" "chair=grok" "an interpreter-launched harness is still named from its script path"
pass "node-launched grok -> chair=grok"

out=$(FM_TEST_CMDLINE='/bin/zsh -l' run_status)
assert_contains "$out" "chair=none" "a bare shell is not a chair"
assert_contains "$out" "harness=none" "no harness"
assert_contains "$out" "pid=none" "no pid"
assert_contains "$out" "reason=holder_not_harness" "reason"
pass "non-harness holder -> none"

# --- chair source: the flip's record wins while its pid holds the lock ------

SOURCE_FILE="$HOME_DIR/state/.chair-source"
printf 'pid=%s source=8080 launched_at=1700000000\n' "$$" > "$SOURCE_FILE"
FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "source=8080" "the recorded source is reported for the lock pid"
pass "state/.chair-source with the lock pid -> its source"

printf 'pid=%s source=8080 launched_at=1700000000\n' "$$" > "$SOURCE_FILE"
FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate")
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "source=8080" "the record applies to whichever harness holds the pid"
printf 'pid=%s source=grok launched_at=1700000000\n' "$$" > "$SOURCE_FILE"
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "source=grok" "a grok record reads back as grok"
pass "state/.chair-source names a grok chair's tank"

printf 'pid=999999 source=8080 launched_at=1700000000\n' > "$SOURCE_FILE"
FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
out=$(FM_TEST_CMDLINE='pi' run_status)
assert_contains "$out" "source=unknown" "a record for another pid is stale and ignored"
pass "state/.chair-source for a different pid -> ignored"

FM_TEST_ORCA_JSON=$(orca_json grok "grok - firstmate")
out=$(FM_TEST_CMDLINE='grok' run_status)
assert_contains "$out" "source=none" "a non-Pi chair with no record has no tank to name"
pass "grok chair without a record -> source=none"
rm -f "$SOURCE_FILE"

# --- chair source: this Pi's own session file, by identity not recency -----

SESSIONS="$TMP_ROOT/sessions"
CWD_RESOLVED=$(cd "$HOME_DIR" && pwd -P)
SESSION_DIR="$SESSIONS/--$(printf '%s' "${CWD_RESOLVED#/}" | tr '/' '-')--"
mkdir -p "$SESSION_DIR"
proc_start() {  # <pid> -> epoch the process started
  local l; l=$(ps -o lstart= -p "$1" | sed 's/^ *//; s/ *$//')
  date -j -f '%a %b %d %T %Y' "$l" +%s 2>/dev/null || date -d "$l" +%s
}
iso_at() {  # <epoch> -> Pi's session timestamp form
  date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z
}
session_file() {  # <name> <cwd> <epoch> <provider...>: a Pi session jsonl with one model_change per provider
  local f="$SESSION_DIR/$1.jsonl" cwd=$2 at=$3 prov; shift 3
  printf '{"type":"session","version":3,"id":"%s","timestamp":"%s","cwd":"%s"}\n' "$1" "$(iso_at "$at")" "$cwd" > "$f"
  for prov in "$@"; do
    printf '{"type":"model_change","id":"x","parentId":null,"timestamp":"%s","provider":"%s","modelId":"claude-fable-5-1"}\n' "$(iso_at "$at")" "$prov" >> "$f"
  done
  printf '%s\n' "$f"
}
run_status_sessions() { FM_CHAIR_STATUS_PI_SESSIONS_DIR="$SESSIONS" run_status; }
START=$(proc_start "$$")

FM_TEST_ORCA_JSON=$(orca_json pi "π - firstmate")
mine=$(session_file 2026-09-20T14-00-00-000Z_mine "$CWD_RESOLVED" $((START + 3)) token-pool anthropic)
touch -t 202001010000 "$mine"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=8080" "the session created as this pid started names the tank from its LAST model_change"
pass "quiet chair (session untouched for years) -> still its own source"

other=$(session_file 2026-09-20T15-00-00-000Z_other "$CWD_RESOLVED" $((START + 3600)) token-pool)
touch "$other"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=8080" "a second Pi opened later in the same home is never the chair, however recent"
pass "second Pi opened in the home -> the chair keeps its own source"

earlier=$(session_file 2026-09-20T13-00-00-000Z_earlier "$CWD_RESOLVED" $((START - 3600)) token-pool)
touch "$earlier"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=8080" "a session from before this pid started is not its own"
pass "older session in the home -> ignored for a pid that started later"

rm -f "$mine"
touch "$earlier"; sleep 1; touch "$other"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=unknown" "with no session created as this pid started, no other session is taken for the chair"
pass "no identity match (e.g. a resumed session) -> unknown, never another Pi's file"

printf 'pid=%s source=unknown launched_at=1700000000\n' "$$" > "$SOURCE_FILE"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=unknown" "a recorded unknown with no match stays unknown"
mine=$(session_file 2026-09-20T14-00-00-000Z_mine "$CWD_RESOLVED" $((START + 3)) anthropic)
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=8080" "a recorded unknown is re-derived and named once the chair's session appears"
rm -f "$SOURCE_FILE" "$mine"
pass "recorded unknown is re-derived every read"

rm -f "$other" "$earlier"
elsewhere=$(session_file 2026-09-20T14-00-01-000Z_elsewhere /somewhere/else $((START + 2)) anthropic)
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=unknown" "a session whose cwd is not this home is ignored even at the right time"
pass "session for another cwd -> unknown"
rm -f "$elsewhere"

mine=$(session_file 2026-09-20T14-00-00-000Z_mine "$CWD_RESOLVED" $((START + 3)) anthropic)
printf 'pid=%s source=8317 launched_at=1700000000\n' "$$" > "$SOURCE_FILE"
out=$(FM_TEST_CMDLINE='pi' run_status_sessions)
assert_contains "$out" "source=8317" "the flip's record outranks the session file"
rm -f "$SOURCE_FILE"
FM_TEST_ORCA_JSON=$(orca_json claude "claude - firstmate")
out=$(FM_TEST_CMDLINE='claude' run_status_sessions)
assert_contains "$out" "source=none" "a Pi session file says nothing about a claude chair"
pass "record outranks session; session only applies to a Pi chair"
rm -f "$mine"

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
assert_contains "$out" "terminal=term_x" "its terminal is still reported so the exit command can reach it"
assert_contains "$out" "harness=pi" "the harness is still named so the actuator sends Pi's exit command"
assert_contains "$out" "pid=$$" "its pid is still reported"
pass "screen footer 99.2%/1.0M -> none, harness, terminal and pid kept"

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
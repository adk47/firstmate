#!/usr/bin/env bash
# Behavior tests for the transient inference-gateway keep-alive: the event gate
# (the agent's own recorded turn end, plus the bounded tail window and the deny
# list that beats it) and the twice-bounded retry ladder.
#
# The turn-end records are written by the contract's only writer,
# bin/fm-busy-event.sh, exactly as the harness's own hooks write them, so these
# fixtures cannot drift from what production records.
# The classifier's text inputs are quoted from the real transcripts this fleet
# produced, so a wording change that would blind it in production fails here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-gateway-retry-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-gateway-keepalive)

# shellcheck source=bin/fm-gateway-retry-lib.sh
. "$LIB"

# The exact rendered text Claude Code emits for the gateway failures this fleet
# actually hits. The em dash is deliberate: the harness renders one, and a
# classifier written against a hyphen would silently never match.
E503_ACCOUNTS='API Error: 503 All accounts are temporarily unavailable. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:8080).'
E503_SERVICE='API Error: 503 Service temporarily unavailable. Please try again later. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:8080).'
E529='API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:8080).'
E500='API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:8080).'
E_COMPACT_503='Prompt is too long · automatic compaction failed: API Error: 503 All accounts are temporarily unavailable. This is a server-side issue, usually temporary — try again in a moment.'
E_LIMIT="You've hit your limit · resets 5:50am (America/Chicago)"
E_LOGIN='Login expired · Please run /login'
E_LONG='Prompt is too long'
# shellcheck disable=SC2016 # Verbatim harness text; the backticks are literal.
E_400='API Error: 400 messages.25.content.3: `thinking` or `redacted_thinking` blocks in the latest assistant message cannot be modified.'
E_REFUSED='API Error: Unable to connect to API (ConnectionRefused)'

# The idle Claude screen below a turn-ending error: the error, a blank row, the
# bordered empty composer, and the shortcut footer. This is the shape a pane
# reader actually sees, so the bounded tail window is exercised against it.
IDLE_FOOTER=$(printf '\n╭──────────────────────────────╮\n│ >                            │\n╰──────────────────────────────╯\n  ? for shortcuts')

# <n> non-blank lines of ordinary agent output.
ordinary_lines() {  # <count>
  local i=1
  while [ "$i" -le "$1" ]; do
    printf '⏺ step %s of the task finished cleanly\n' "$i"
    i=$(( i + 1 ))
  done
}

# Record one turn end on <task> through the contract's ONLY writer, arming a
# fresh incarnation first: bin/fm-spawn.sh wires Claude's Stop hook to
# `--event stop` and its StopFailure hook to `--event stop-failure`, both of
# them this same command, so a fixture written here is the record production
# has.
record_turn_end() {  # <state-dir> <task> <event> [source]
  local st=$1 task=$2 event=$3 source=${4:-claude-hook} gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$st" "$task") || return 1
  "$ROOT/bin/fm-busy-event.sh" apply "$st" "$task" idle --gen "$gen" \
    --source "$source" --event "$event" >/dev/null
}

new_state() {  # <name>
  local d="$TMP_ROOT/$1/state"
  rm -rf "${TMP_ROOT:?}/${1:?}"
  mkdir -p "$d"
  printf '%s' "$d"
}

test_text_classifier_accepts_the_real_transient_errors() {
  local t
  for t in "$E503_ACCOUNTS" "$E503_SERVICE" "$E529" "$E500"; do
    fm_gateway_text_is_transient "$t" \
      || fail "the text classifier missed a real transient gateway error: ${t:0:40}"
    fm_gateway_text_is_transient "$(printf '%s\n%s' "$t" "$IDLE_FOOTER")" \
      || fail "the classifier missed a real transient error rendered above the idle composer and footer: ${t:0:40}"
  done
  pass "text classifier accepts every transient gateway error this fleet has produced, bare and above the idle footer"
}

test_deny_list_beats_a_transient_code_inside_a_permanent_failure() {
  # The one that matters most: this string CONTAINS "API Error: 503", and
  # re-ringing it would burn the whole budget with no chance of progress
  # because the context, not the gateway, is what failed.
  fm_gateway_text_is_transient "$E_COMPACT_503" \
    && fail "a compaction failure carrying a 503 must never be treated as retryable"
  local t
  for t in "$E_LIMIT" "$E_LOGIN" "$E_LONG" "$E_400" ""; do
    fm_gateway_text_is_transient "$t" \
      && fail "a non-retryable failure was classified transient: ${t:0:40}"
  done
  pass "the deny list beats a transient code inside a permanent failure"
}

test_deny_list_matches_anywhere_while_the_transient_match_is_bounded() {
  # A deny hit must never be narrowed away: a permanent failure far up the
  # capture still vetoes a transient error rendered right above the footer.
  local pane
  pane=$(printf '%s\n%s\n%s\n%s' "$E_LIMIT" "$(ordinary_lines 20)" "$E503_ACCOUNTS" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "a deny-list hit above the bounded tail window was narrowed away"
  pass "the deny list matches anywhere in the capture while the transient match reads only the tail"
}

test_a_recovered_agent_with_the_old_error_in_scrollback_is_not_stalled() {
  # The bug this pins: a crew that hit a 503, was re-rung, carried on, and went
  # idle again still has the old error in its 40-line scrollback. Only the few
  # lines immediately above the prompt say what the LAST turn did.
  local st pane
  st=$(new_state recovered-scrollback)
  pane=$(printf '%s\n%s\n%s' "$E503_ACCOUNTS" "$(ordinary_lines 12)" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "an error that scrolled above the last turn's output was still classified as a live stall"
  # The recorded turn end is left as an API error on purpose: the tail window,
  # not the gate, is what has to keep this crew out of the ladder.
  record_turn_end "$st" task-r stop-failure || fail "could not record an API-error turn end"
  fm_gateway_note_stall "$st" task-r || fail "could not open a stall record"
  fm_gateway_record_attempt "$st" task-r || fail "could not charge an attempt"
  fm_gateway_stalled_now "$st" task-r "$pane" \
    && fail "a recovered crew with the old error in scrollback was kept in the ladder"
  fm_gateway_stall_open "$st" task-r \
    && fail "leaving the ladder must drop the record so a later stall starts fresh"
  pass "a recovered agent whose scrollback still holds the old error is not re-rung"
}

test_repository_text_naming_the_errors_is_not_a_stall() {
  # A crewmate that greps or cats this repository's own sources prints the
  # gateway's sentences and the word overloaded at its prompt. None of that is
  # the harness's rendered "API Error: <5xx>" shape. The stronger case - a
  # crewmate printing that shape itself - is not this match's job and is pinned
  # on the gate, in test_the_recorded_turn_end_gates_the_ladder below.
  # Built as printf arguments, not a heredoc inside a nested substitution:
  # stock macOS Bash 3.2 cannot parse that shape and fails the whole file.
  local pane
  pane=$(printf '%s\n' \
    'bin/fm-gateway-retry-lib.sh:34:# word such as "overloaded".' \
    "docs/gateway-keepalive.md:12: the gateway's own out-of-capacity sentences" \
    'tests/fm-gateway-keepalive.test.sh:22: All accounts are temporarily unavailable' \
    'tests/fm-gateway-keepalive.test.sh:23: Service temporarily unavailable' \
    'Overloaded' \
    "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "repository text mentioning overloaded and the gateway sentences was classified as a stall"
  pass "repository text naming the errors without the rendered API Error shape is not a stall"
}

test_a_gateway_that_is_simply_down_is_not_retried() {
  # ConnectionRefused is the genuine outage the captain wants surfaced, not
  # something to keep re-ringing an agent about.
  fm_gateway_text_is_transient "$E_REFUSED" \
    && fail "an unreachable gateway must surface as an outage, not enter the re-ring ladder"
  pass "an unreachable gateway is left to surface as an outage"
}

test_ladder_is_bounded_by_attempts() {
  local st
  st=$(new_state attempts-bound)
  fm_gateway_note_stall "$st" task-a || fail "could not open a stall record"
  FM_GATEWAY_RETRY_MAX=3 FM_GATEWAY_RETRY_HORIZON=99999
  export FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  fm_gateway_budget_spent "$st" task-a && fail "a fresh stall must not start with a spent budget"
  local i
  for i in 1 2 3; do
    fm_gateway_record_attempt "$st" task-a || fail "could not charge attempt $i"
  done
  [ "$(fm_gateway_attempts "$st" task-a)" = 3 ] || fail "attempts were not counted"
  fm_gateway_budget_spent "$st" task-a || fail "the attempt bound did not stop the ladder"
  unset FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  pass "the ladder stops at its attempt bound"
}

test_ladder_is_bounded_by_wall_clock_independently() {
  # The second bound exists for the slow case the attempt count cannot catch:
  # few attempts, spread across a genuine outage.
  local st rec now
  st=$(new_state horizon-bound)
  now=$(date +%s)
  rec="$st/task-b.gateway-stall"
  printf 'v1 first=%s attempts=1 last=%s notified=0 kind=pane\n' \
    "$(( now - 4000 ))" "$(( now - 4000 ))" > "$rec"
  FM_GATEWAY_RETRY_MAX=99 FM_GATEWAY_RETRY_HORIZON=2700
  export FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  fm_gateway_budget_spent "$st" task-b \
    || fail "the wall-clock horizon did not stop a long stall with attempts to spare"
  unset FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  pass "the ladder stops at its wall-clock horizon independently of the attempt count"
}

# The busy-duration exit has to outlast the harness's OWN internal retry of a
# 503 - about 240 seconds per docs/verification/gateway-keepalive.md, during
# which UserPromptSubmit has already marked the pane busy. The exit is applied
# by counting busy polls, so a bound expressed in polls silently shrinks when a
# home polls faster than the 15-second default: at a 5-second interval the old
# 40-poll value covered only 200 seconds, back under that retry, and the record
# was dropped mid-ladder so a genuine outage could never be declared. The bound
# is therefore wall clock, converted to each caller's cadence.
test_busy_clear_window_is_wall_clock_at_every_poll_cadence() {
  # Each cadence is paired with its own length in milliseconds, so the window a
  # count really covers can be asserted in integer arithmetic. The sub-second
  # ones are not hypothetical: FM_POLL has no floor and this repository's own
  # suites drive the real watcher at 0.2 and 0.02 seconds, where rounding the
  # cadence up to a whole second derives a fifth or a fiftieth of the window.
  local pair interval ms polls window retry=240
  for pair in 15:15000 5:5000 1:1000 1.5:1500 0.5:500 0.2:200 0.02:20; do
    interval=${pair%%:*}
    ms=${pair#*:}
    polls=$(fm_gateway_busy_clear_polls "$interval")
    window=$(( polls * ms / 1000 ))
    [ "$window" -ge 600 ] \
      || fail "a ${interval}s poll interval derived only ${window}s of busy ($polls polls), shrinking the window below the bound"
    [ "$window" -gt "$retry" ] \
      || fail "a ${interval}s poll interval derived ${window}s of busy, inside the harness's own ~${retry}s internal retry; the record would be dropped mid-ladder and no outage could ever be declared"
  done

  # A cadence that is not a number, and one that is zero because the caller does
  # not sleep at all, have no wall clock to divide: both fall back to the longest
  # window this function can name rather than a short one.
  [ "$(fm_gateway_busy_clear_polls abc)" = 600 ] \
    || fail "an unreadable poll interval did not fall back to the bound's own seconds"
  [ "$(fm_gateway_busy_clear_polls 0)" = 600 ] \
    || fail "a zero poll interval did not fall back to the bound's own seconds"

  # Rounded UP to whole polls, and never to zero: an interval longer than the
  # whole window must still take one busy poll to end a record, not none.
  [ "$(fm_gateway_busy_clear_polls 7)" = 86 ] \
    || fail "the derived poll count was not rounded up to cover the whole window"
  [ "$(fm_gateway_busy_clear_polls 3600)" = 1 ] \
    || fail "an interval longer than the window derived fewer than one poll, which would end a record on sight"

  # The bound itself is the tunable; the derivation follows it at any cadence.
  [ "$( (FM_GATEWAY_BUSY_CLEAR_SECS=60; fm_gateway_busy_clear_polls 5) )" = 12 ] \
    || fail "the derivation ignored a configured busy-clear window"
  pass "the busy-clear window stays wall clock at every poll cadence, past the harness's own retry"
}

test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach() {
  # The bug this pins: if every sighting advanced the backoff anchor, a stall
  # polled more often than its backoff would be absorbed forever and never
  # re-rung, and the horizon would never be reached either.
  local st first_open
  st=$(new_state anchor-stability)
  record_turn_end "$st" task-c stop-failure || fail "could not record an API-error turn end"
  FM_GATEWAY_RETRY_BACKOFF=1
  export FM_GATEWAY_RETRY_BACKOFF
  fm_gateway_stalled_now "$st" task-c "$E503_ACCOUNTS" || fail "a stalled pane must open the record"
  first_open=$(fm_gateway_first_seen "$st" task-c)
  sleep 2
  fm_gateway_stalled_now "$st" task-c "$E503_ACCOUNTS" || fail "re-sighting must keep the record"
  [ "$(fm_gateway_first_seen "$st" task-c)" = "$first_open" ] \
    || fail "re-noting an open stall moved its wall-clock anchor"
  fm_gateway_attempt_due "$st" task-c \
    || fail "re-noting an open stall pushed the next attempt out of reach"
  unset FM_GATEWAY_RETRY_BACKOFF
  pass "re-sighting an open stall moves neither the horizon anchor nor the backoff anchor"
}

test_first_attempt_waits_out_its_backoff() {
  local st
  st=$(new_state first-backoff)
  FM_GATEWAY_RETRY_BACKOFF=3600
  export FM_GATEWAY_RETRY_BACKOFF
  fm_gateway_note_stall "$st" task-d || fail "could not open a stall record"
  fm_gateway_attempt_due "$st" task-d \
    && fail "a stall must not be re-rung the instant it is first seen"
  unset FM_GATEWAY_RETRY_BACKOFF
  pass "the first attempt waits out its own backoff rather than firing on sight"
}

test_backoff_ladder_repeats_its_last_step() {
  FM_GATEWAY_RETRY_BACKOFF='30 60 120 300'
  export FM_GATEWAY_RETRY_BACKOFF
  [ "$(fm_gateway_backoff_secs 1)" = 30 ] || fail "attempt 1 backoff wrong"
  [ "$(fm_gateway_backoff_secs 4)" = 300 ] || fail "attempt 4 backoff wrong"
  [ "$(fm_gateway_backoff_secs 9)" = 300 ] || fail "the ladder's last step must repeat past its length"
  unset FM_GATEWAY_RETRY_BACKOFF
  pass "the backoff ladder repeats its last step past its own length"
}

test_the_recorded_turn_end_gates_the_ladder() {
  # The agent's OWN record of how its last turn ended is the first condition,
  # and the pane text is the second. Case 2 is why: its screen is
  # indistinguishable from case 1 by text alone - this repository's docs and
  # tests put that exact string on a crewmate's screen - and no amount of
  # reading ROWS tells a finished crew from a stalled one. The recorded event
  # does.
  local st stalled quoting
  st=$(new_state event-gate)
  stalled=$(printf '%s\n%s' "$E503_ACCOUNTS" "$IDLE_FOOTER")
  quoting=$(printf '%s\n%s' "⏺ The census row quotes it as \"$E503_ACCOUNTS\"" "$IDLE_FOOTER")

  # 1. An API-error turn end, and the pane naming a transient one: the stall
  # this keep-alive exists for.
  record_turn_end "$st" task-sf stop-failure || fail "could not record an API-error turn end"
  fm_gateway_stalled_now "$st" task-sf "$stalled" \
    || fail "a recorded API-error turn end showing the transient error did not enter the ladder"
  fm_gateway_stall_open "$st" task-sf || fail "entering the ladder must open the durable record"

  # 2. A NORMAL turn end quoting the same error in its report: never the ladder's
  # business, whatever is on the screen.
  record_turn_end "$st" task-stop stop || fail "could not record a normal turn end"
  fm_gateway_stalled_now "$st" task-stop "$quoting" \
    && fail "a crew that finished its turn normally was pulled into the ladder by text on its screen"
  fm_gateway_stall_open "$st" task-stop && fail "a normal turn end must open no record"

  # 3. An API-error turn end with no transient error on the pane: the event says
  # THAT an API error ended the turn, never WHICH one, so the text still has to
  # agree.
  record_turn_end "$st" task-quiet stop-failure || fail "could not record an API-error turn end"
  fm_gateway_stalled_now "$st" task-quiet "$(printf '%s\n%s' "$(ordinary_lines 3)" "$IDLE_FOOTER")" \
    && fail "an API-error turn end with no transient error on the pane entered the ladder"
  fm_gateway_stall_open "$st" task-quiet && fail "a pane with no transient error must open no record"

  # And the exit is the same signal as the entry: the crew takes the continue,
  # its next turn ends normally, and the record is dropped on the next idle poll
  # without waiting for the old error to scroll off the screen.
  fm_gateway_record_attempt "$st" task-sf || fail "could not charge an attempt"
  record_turn_end "$st" task-sf stop || fail "could not record the recovering turn end"
  fm_gateway_stalled_now "$st" task-sf "$stalled" \
    && fail "a crew whose turn ended normally is still read as stalled while its old error is on screen"
  fm_gateway_stall_open "$st" task-sf \
    && fail "leaving the ladder must drop the record so a later stall starts fresh"
  pass "the recorded turn end gates the ladder: an API-error end with the error enters it, a normal end never does, and a normal end ends it"
}

# The rendered error as a PANE actually holds it. The screen is ~80 columns and
# the error is 191 characters, so it always arrives split across rows: word
# wrapped, the way an Ink TUI breaks its own text, and hard wrapped mid-word, the
# way a terminal breaks a line that overruns the margin. Both are quoted from the
# shapes this classifier was measured against.
WRAPPED_503_WORD=$(printf '%s\n%s\n%s' \
'⏺ API Error: 503 All accounts are temporarily unavailable. This is a' \
' server-side issue, usually temporary — try again in a moment. If it persists,' \
' check your inference gateway (127.0.0.1:8080).')
WRAPPED_503_HARD=$(printf '%s\n%s\n%s' \
'API Error: 503 All accounts are temporarily unavailable. This is a server-side i' \
'ssue, usually temporary — try again in a moment. If it persists, check your infe' \
'rence gateway (127.0.0.1:8080).')

test_a_wrapped_rendered_error_still_enters_the_ladder() {
  # The regression that four position-based classifiers each produced in their
  # own way: the row carrying the shape is never the last row of a wrap, so a
  # classifier that anchors anywhere on the SCREEN misses the very error the
  # captain is waiting on and nothing is ever re-rung. The text condition is
  # bounded to the tail window and otherwise unanchored, so every wrap shape
  # reads the same.
  local st pane shape
  st=$(new_state wrapped-stall)
  for shape in word-wrapped hard-wrapped; do
    case "$shape" in
      word-wrapped) pane=$WRAPPED_503_WORD ;;
      *) pane=$WRAPPED_503_HARD ;;
    esac
    rm -f "$st/task-w.gateway-stall"
    record_turn_end "$st" task-w stop-failure || fail "could not record an API-error turn end"
    fm_gateway_stalled_now "$st" task-w "$(printf '%s\n%s' "$pane" "$IDLE_FOOTER")" \
      || fail "a pane holding the rendered error as a screen wraps it ($shape) did not enter the ladder"
    fm_gateway_stall_open "$st" task-w \
      || fail "no stall record was opened for the wrapped error ($shape)"
  done
  pass "the rendered error still opens the ladder when the pane wraps it, word wrapped and hard wrapped"
}

test_an_unreadable_turn_end_keeps_a_task_out_of_the_ladder() {
  # The documented limit of this keep-alive. `stop-failure` is written in
  # exactly one place, the claude arm of bin/fm-spawn.sh's busy wiring, so a
  # task with no record, with an event no claude hook writes, or with a record
  # whose incarnation can no longer be read is deliberately NOT re-rung on the
  # strength of pane text alone - it is left to ordinary triage.
  local st pane
  st=$(new_state unreadable-event)
  pane=$(printf '%s\n%s' "$E503_ACCOUNTS" "$IDLE_FOOTER")

  fm_gateway_stalled_now "$st" task-none "$pane" \
    && fail "a task with no turn-lifecycle record at all entered the ladder"
  fm_gateway_stall_open "$st" task-none && fail "a task with no record must open no record"

  record_turn_end "$st" task-other after-agent gemini-hook \
    || fail "could not record another adapter's turn end"
  fm_gateway_stalled_now "$st" task-other "$pane" \
    && fail "a turn end no claude hook writes entered the ladder"
  fm_gateway_stall_open "$st" task-other && fail "an unknown turn-end event must open no record"

  record_turn_end "$st" task-orphan stop-failure || fail "could not record an API-error turn end"
  rm -f "$st/task-orphan.busy-gen"
  fm_gateway_stalled_now "$st" task-orphan "$pane" \
    && fail "a record whose incarnation cannot be read entered the ladder"
  fm_gateway_stall_open "$st" task-orphan && fail "an unreadable record must open no record"
  pass "no record, an event no claude hook writes, and an unreadable record all stay out of the ladder"
}

test_spent_budget_declares_an_external_wait_not_a_wedge() {
  local st line
  st=$(new_state paused-line)
  fm_gateway_note_stall "$st" task-g || fail "could not open a stall record"
  fm_gateway_record_attempt "$st" task-g || fail "could not charge an attempt"
  line=$(fm_gateway_paused_status_line "$st" task-g)
  case "$line" in
    'paused [key=gateway-503]: '*) : ;;
    *) fail "a spent budget must declare a keyed external wait, got: $line" ;;
  esac
  pass "a spent budget declares a keyed external wait rather than a wedge"
}

# What the real consumer of a status log says is still open on it, so these
# assertions are the fleet snapshot's own verdict rather than a grep.
open_activity_keys() {  # <status-file>
  bash -c '. "$1"; status_open_activities "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$1"
}

test_a_recovered_agent_closes_its_declared_gateway_wait() {
  local st status open
  st=$(new_state resolved-line)
  status="$st/task-r.status"
  printf 'working: implementing the fix\n' > "$status"
  record_turn_end "$st" task-r stop-failure || fail "could not record an API-error turn end"
  fm_gateway_note_stall "$st" task-r || fail "could not open a stall record"
  fm_gateway_record_attempt "$st" task-r || fail "could not charge an attempt"
  printf '%s\n' "$(fm_gateway_paused_status_line "$st" task-r)" >> "$status"
  fm_gateway_mark_notified "$st" task-r || fail "could not mark the declaration made"
  open=$(open_activity_keys "$status")
  case "$open" in
    *gateway-503*) : ;;
    *) fail "the declared wait did not open a keyed phase to begin with, got: $open" ;;
  esac

  # The gateway recovers: the crew's next turn ends normally, so the record is
  # dropped - and the phase that record declared must go with it, or a finished
  # crew is reported as still waiting on the gateway for the life of the log.
  record_turn_end "$st" task-r stop || fail "could not record the recovering turn end"
  fm_gateway_stalled_now "$st" task-r "$(ordinary_lines 3)" \
    && fail "a recovered crew still reads as stalled"
  printf 'done: shipped\n' >> "$status"
  open=$(open_activity_keys "$status")
  case "$open" in
    *gateway-503*) fail "a recovered crew is still declared as waiting on the gateway: $open" ;;
  esac

  pass "a recovered agent's declared gateway wait is closed, leaving no open gateway-503 phase"
}


test_text_classifier_accepts_the_real_transient_errors
test_deny_list_beats_a_transient_code_inside_a_permanent_failure
test_deny_list_matches_anywhere_while_the_transient_match_is_bounded
test_a_recovered_agent_with_the_old_error_in_scrollback_is_not_stalled
test_repository_text_naming_the_errors_is_not_a_stall
test_the_recorded_turn_end_gates_the_ladder
test_a_wrapped_rendered_error_still_enters_the_ladder
test_an_unreadable_turn_end_keeps_a_task_out_of_the_ladder
test_a_gateway_that_is_simply_down_is_not_retried
test_ladder_is_bounded_by_attempts
test_ladder_is_bounded_by_wall_clock_independently
test_busy_clear_window_is_wall_clock_at_every_poll_cadence
test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach
test_first_attempt_waits_out_its_backoff
test_backoff_ladder_repeats_its_last_step
test_spent_budget_declares_an_external_wait_not_a_wedge
test_a_recovered_agent_closes_its_declared_gateway_wait

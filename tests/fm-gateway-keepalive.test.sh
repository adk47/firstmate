#!/usr/bin/env bash
# Behavior tests for the transient inference-gateway keep-alive:
# the rendered-pane classifier (the bounded tail window and the deny list that
# beats it) and the twice-bounded retry ladder.
#
# The classifier's inputs are quoted from the real transcripts this fleet
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

# <text> as a pane holds it at <cols> columns: screen ROWS, hard-wrapped at the
# margin exactly as tmux wraps a line too long for the pane and as
# `tmux capture-pane -p` then hands it back - one row per wrap, no separator, no
# word breaking. tmux is not a dependency of this suite, so the split is
# reproduced here; the fixtures below assert it really did split, because the
# regression this pins shipped precisely because every fixture wrote the ~190
# character error as one unwrapped line no pane could ever show.
pane_rows() {  # <text> <cols>
  local s=$1 w=$2
  while [ "${#s}" -gt "$w" ]; do
    printf '%s\n' "${s:0:$w}"
    s=${s:$w}
  done
  printf '%s\n' "$s"
}

row_count() {  # <rows>
  printf '%s\n' "$1" | grep -c ''
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
  # gateway's sentences, the word overloaded, AND the rendered
  # "API Error: <5xx>" shape itself - docs/verification/gateway-keepalive.md's
  # census table and this file's own fixtures carry it verbatim - and then says
  # so in its own words. Every one of those is a citation: quoted, and the
  # harness never quotes its own error.
  local pane
  pane=$(printf '%s\n%s' "$(cat <<'TXT'
bin/fm-gateway-retry-lib.sh:34:# word such as "overloaded".
docs/verification/gateway-keepalive.md:39:| 2427 | `API Error: 503 Service temporarily unavailable. …` | transient |
tests/fm-gateway-keepalive.test.sh:22:E503_ACCOUNTS='API Error: 503 All accounts are temporarily unavailable. …'
Overloaded
⏺ Those are all citations — the harness renders "API Error: 503 All accounts are temporarily unavailable." itself, unquoted, on the line it ends the turn with.
TXT
)" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "a crewmate quoting this repository's own rendered error text was classified as a stall"
  pass "repository text quoting the rendered API Error shape is a citation, not a stall"
}

test_only_the_live_output_line_decides_a_stall() {
  # (1) A turn that named the error and then carried on ends on its OWN output.
  # The error is history there, not the live line, and re-ringing that crew
  # would send it a continue nobody asked for and spend the whole budget.
  local pane
  pane=$(printf '%s\n%s\n%s' \
    "⏺ the census row in docs/verification/gateway-keepalive.md reads $E503_SERVICE" \
    "$(ordinary_lines 3)" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "an agent that named the error mid-turn and then carried on was classified as stalled"

  # (2) The same window ENDING on the harness's own rendered error, above the
  # idle composer and footer, is exactly the stall this keep-alive exists for.
  # The composer and footer are not output lines; anchoring to the raw last
  # non-blank line would find the footer and blind the detector completely.
  pane=$(printf '%s\n%s\n%s' "$(ordinary_lines 3)" "$E503_ACCOUNTS" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    || fail "a pane whose last output line is the rendered error was not classified as a stall"
  pass "only the live output line decides a stall: an error named mid-turn is not one, an error ending the turn is"
}

test_a_wrapped_rendered_error_is_still_a_stall() {
  # The error the captain is waiting on is 191 characters. No pane shows that on
  # one row: a crew window is opened detached at tmux's 80-column default and
  # captured as physical rows, so the shape arrives on the FIRST row of a wrap
  # and the pane's last row is a fragment carrying none of it. A classifier that
  # reads a screen row instead of the line the harness wrote is inert at every
  # width a crew runs at - no record, no continue, nothing retried.
  local cols rows pane st
  for cols in 160 100 80; do
    rows=$(pane_rows "$E503_ACCOUNTS" "$cols")
    [ "$(row_count "$rows")" -gt 1 ] \
      || fail "the ${cols}-column fixture did not wrap, so it cannot pin this regression"
    pane=$(printf '%s%s' "$rows" "$IDLE_FOOTER")
    fm_gateway_text_is_transient "$pane" \
      || fail "the rendered error wrapped at $cols columns, as a real pane holds it, was not classified as a stall"
  done

  # And the ladder actually engages on it: the durable record opens, which is
  # what buys the crew its continue instruction.
  st=$(new_state wrapped-stall)
  fm_gateway_stalled_now "$st" task-w "$(printf '%s%s' "$(pane_rows "$E503_ACCOUNTS" 80)" "$IDLE_FOOTER")" \
    || fail "a pane holding the wrapped error did not enter the re-ring ladder"
  fm_gateway_stall_open "$st" task-w || fail "no stall record was opened for the wrapped error"
  pass "the rendered error still opens the ladder when the pane wraps it, at 160, 100 and 80 columns"
}

test_a_citation_split_across_a_wrap_is_still_quoted() {
  # The quote and the shape land on DIFFERENT rows: at 80 columns this citation's
  # opening `"` ends one row and `API Error: 503` sits inside the next. Judging
  # that next row alone would find the shape with nothing ahead of it and re-ring
  # a crew that was only reading the docs, so the quote test has to run on the
  # reconstructed line, not on the row.
  local citation rows pane
  citation="⏺ The verification record's census table quotes the pooled gateway failure as \"the rendered $E503_ACCOUNTS\" and classes it transient."
  rows=$(pane_rows "$citation" 80)
  [ "$(row_count "$rows")" -gt 1 ] \
    || fail "the citation fixture did not wrap, so it cannot pin this regression"
  printf '%s\n' "$rows" | sed -n 2p | grep -q 'API Error: 503' \
    || fail "the citation fixture no longer splits with the shape on a continuation row"
  pane=$(printf '%s%s' "$rows" "$IDLE_FOOTER")
  fm_gateway_text_is_transient "$pane" \
    && fail "a citation whose quote opened on an earlier screen row was classified as a stall"
  pass "a citation split across a wrap is still read as quoted, not as the harness's own error"
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
  local interval polls window retry=240
  for interval in 15 5 1; do
    polls=$(fm_gateway_busy_clear_polls "$interval")
    window=$(( polls * interval ))
    [ "$window" -ge 600 ] \
      || fail "a ${interval}s poll interval derived only ${window}s of busy ($polls polls), shrinking the window below the bound"
    [ "$window" -gt "$retry" ] \
      || fail "a ${interval}s poll interval derived ${window}s of busy, inside the harness's own ~${retry}s internal retry; the record would be dropped mid-ladder and no outage could ever be declared"
  done

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

test_pane_is_the_single_detector() {
  # A record only ever exists because a pane showed the error, and a pane that
  # no longer shows it ends the stall whatever the record says: there is no
  # second detector whose word can hold the ladder open against the pane.
  local st
  st=$(new_state pane-authority)
  fm_gateway_stalled_now "$st" task-e 'ordinary pane output' \
    && fail "an ordinary pane must not enter the ladder"
  fm_gateway_stall_open "$st" task-e && fail "an ordinary pane must open no record"
  fm_gateway_stalled_now "$st" task-e "$E503_ACCOUNTS" || fail "a stalled pane must enter the ladder"
  fm_gateway_stall_open "$st" task-e || fail "a stalled pane must open the record"
  fm_gateway_stalled_now "$st" task-e 'ordinary pane output' \
    && fail "a pane that moved on before any attempt must still leave the ladder"
  fm_gateway_stall_open "$st" task-e \
    && fail "leaving the ladder must drop the record so a later stall starts fresh"
  pass "the rendered pane is the single detector: it alone opens, keeps, and ends a stall"
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
  fm_gateway_note_stall "$st" task-r || fail "could not open a stall record"
  fm_gateway_record_attempt "$st" task-r || fail "could not charge an attempt"
  printf '%s\n' "$(fm_gateway_paused_status_line "$st" task-r)" >> "$status"
  fm_gateway_mark_notified "$st" task-r || fail "could not mark the declaration made"
  open=$(open_activity_keys "$status")
  case "$open" in
    *gateway-503*) : ;;
    *) fail "the declared wait did not open a keyed phase to begin with, got: $open" ;;
  esac

  # The gateway recovers: the pane no longer shows the error, so the record is
  # dropped - and the phase that record declared must go with it, or a finished
  # crew is reported as still waiting on the gateway for the life of the log.
  fm_gateway_stalled_now "$st" task-r "$(ordinary_lines 3)" \
    && fail "a recovered pane still reads as stalled"
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
test_only_the_live_output_line_decides_a_stall
test_a_wrapped_rendered_error_is_still_a_stall
test_a_citation_split_across_a_wrap_is_still_quoted
test_a_gateway_that_is_simply_down_is_not_retried
test_ladder_is_bounded_by_attempts
test_ladder_is_bounded_by_wall_clock_independently
test_busy_clear_window_is_wall_clock_at_every_poll_cadence
test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach
test_first_attempt_waits_out_its_backoff
test_backoff_ladder_repeats_its_last_step
test_pane_is_the_single_detector
test_spent_budget_declares_an_external_wait_not_a_wedge
test_a_recovered_agent_closes_its_declared_gateway_wait

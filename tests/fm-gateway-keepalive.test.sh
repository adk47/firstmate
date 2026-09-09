#!/usr/bin/env bash
# Behavior tests for the transient inference-gateway keep-alive:
# the classifier (both signals plus the deny list that beats them), the twice-bounded
# retry ladder, the StopFailure detector hook, and the watcher's re-ring backstop.
#
# The classifier's inputs are quoted from the real transcripts this fleet
# produced, so a wording change that would blind it in production fails here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-gateway-retry-lib.sh"
HOOK="$ROOT/bin/fm-gateway-stall-hook.sh"
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
  done
  pass "text classifier accepts every transient gateway error this fleet has produced"
}

test_deny_list_beats_a_transient_code_inside_a_permanent_failure() {
  # The one that matters most: this string CONTAINS "API Error: 503", and
  # re-ringing it would burn the whole budget with no chance of progress
  # because the context, not the gateway, is what failed.
  fm_gateway_text_is_transient "$E_COMPACT_503" \
    && fail "a compaction failure carrying a 503 must never be treated as retryable"
  fm_gateway_is_transient server_error "$E_COMPACT_503" \
    && fail "permanent text must beat even a transient TYPED kind"
  local t
  for t in "$E_LIMIT" "$E_LOGIN" "$E_LONG" "$E_400" ""; do
    fm_gateway_text_is_transient "$t" \
      && fail "a non-retryable failure was classified transient: ${t:0:40}"
  done
  pass "the deny list beats a transient code inside a permanent failure, and beats a transient typed kind"
}

test_a_gateway_that_is_simply_down_is_not_retried() {
  # ConnectionRefused is the genuine outage the captain wants surfaced, not
  # something to keep re-ringing an agent about.
  fm_gateway_text_is_transient "$E_REFUSED" \
    && fail "an unreachable gateway must surface as an outage, not enter the re-ring ladder"
  pass "an unreachable gateway is left to surface as an outage"
}

test_typed_kind_and_text_are_independent_positives() {
  # Either signal alone must carry a verdict, because each is the ONLY signal
  # available to one of the two detectors.
  fm_gateway_is_transient server_error '' || fail "the typed kind alone must carry a positive verdict"
  fm_gateway_is_transient overloaded '' || fail "the typed kind alone must carry a positive verdict"
  fm_gateway_is_transient '' "$E503_ACCOUNTS" || fail "the text alone must carry a positive verdict"
  fm_gateway_is_transient unknown "$E503_ACCOUNTS" || fail "an unrecognised kind must not veto matching text"
  # ...and losing one must not turn a real stall into a miss.
  fm_gateway_is_transient unknown '' && fail "an unknown kind with no text must not be retried"
  fm_gateway_is_transient rate_limit "$E503_ACCOUNTS" \
    && fail "a permanent TYPED kind must beat matching transient text"
  pass "typed kind and text are independent positives, and either permanent signal vetoes"
}

test_ladder_is_bounded_by_attempts() {
  local st
  st=$(new_state attempts-bound)
  fm_gateway_note_stall "$st" task-a server_error || fail "could not open a stall record"
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
  printf 'v1 first=%s attempts=1 last=%s notified=0 kind=server_error\n' \
    "$(( now - 4000 ))" "$(( now - 4000 ))" > "$rec"
  FM_GATEWAY_RETRY_MAX=99 FM_GATEWAY_RETRY_HORIZON=2700
  export FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  fm_gateway_budget_spent "$st" task-b \
    || fail "the wall-clock horizon did not stop a long stall with attempts to spare"
  unset FM_GATEWAY_RETRY_MAX FM_GATEWAY_RETRY_HORIZON
  pass "the ladder stops at its wall-clock horizon independently of the attempt count"
}

test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach() {
  # The bug this pins: if every sighting advanced the backoff anchor, a stall
  # polled more often than its backoff would be absorbed forever and never
  # re-rung, and the horizon would never be reached either.
  local st first_open
  st=$(new_state anchor-stability)
  FM_GATEWAY_RETRY_BACKOFF=1
  export FM_GATEWAY_RETRY_BACKOFF
  fm_gateway_note_stall "$st" task-c server_error || fail "could not open a stall record"
  first_open=$(fm_gateway_first_seen "$st" task-c)
  sleep 2
  fm_gateway_note_stall "$st" task-c server_error || fail "re-noting must succeed"
  [ "$(fm_gateway_first_seen "$st" task-c)" = "$first_open" ] \
    || fail "re-noting an open stall moved its wall-clock anchor"
  fm_gateway_attempt_due "$st" task-c \
    || fail "re-noting an open stall pushed the next attempt out of reach"
  unset FM_GATEWAY_RETRY_BACKOFF
  pass "re-noting an open stall moves neither the horizon anchor nor the backoff anchor"
}

test_first_attempt_waits_out_its_backoff() {
  local st
  st=$(new_state first-backoff)
  FM_GATEWAY_RETRY_BACKOFF=3600
  export FM_GATEWAY_RETRY_BACKOFF
  fm_gateway_note_stall "$st" task-d server_error || fail "could not open a stall record"
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

test_pane_is_authoritative_after_the_first_attempt() {
  # The hook's record bridges the gap between the harness failing the turn and
  # the next poll rendering it, and nothing more. Once an attempt is charged, an
  # agent whose pane has moved on is working again and must leave the ladder,
  # or the keep-alive would keep interrupting a recovered agent.
  local st
  st=$(new_state pane-authority)
  fm_gateway_note_stall "$st" task-e server_error || fail "could not open a stall record"
  fm_gateway_stalled_now "$st" task-e 'ordinary pane output' \
    || fail "a hook-opened record with no attempts yet must hold the ladder open"
  fm_gateway_record_attempt "$st" task-e || fail "could not charge an attempt"
  fm_gateway_stalled_now "$st" task-e 'ordinary pane output' \
    && fail "after an attempt, a pane that moved on must leave the ladder"
  fm_gateway_stall_open "$st" task-e \
    && fail "leaving the ladder must drop the record so a later stall starts fresh"
  pass "the rendered pane is authoritative once an attempt has been charged"
}

test_stale_hook_record_expires_without_a_pane_match() {
  local st rec now
  st=$(new_state stale-record)
  now=$(date +%s)
  rec="$st/task-f.gateway-stall"
  printf 'v1 first=%s attempts=0 last=%s notified=0 kind=server_error\n' \
    "$(( now - 900 ))" "$(( now - 900 ))" > "$rec"
  touch -t "$(date -r "$(( now - 900 ))" +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$rec" 2>/dev/null || true
  FM_GATEWAY_STALL_FRESH=300
  export FM_GATEWAY_STALL_FRESH
  fm_gateway_stalled_now "$st" task-f 'ordinary pane output' \
    && fail "a hook record older than its freshness window must not hold the ladder open alone"
  unset FM_GATEWAY_STALL_FRESH
  pass "a stale hook record expires instead of holding the ladder open forever"
}

test_spent_budget_declares_an_external_wait_not_a_wedge() {
  local st line
  st=$(new_state paused-line)
  fm_gateway_note_stall "$st" task-g server_error || fail "could not open a stall record"
  fm_gateway_record_attempt "$st" task-g || fail "could not charge an attempt"
  line=$(fm_gateway_paused_status_line "$st" task-g)
  case "$line" in
    'paused [key=gateway-503]: '*) : ;;
    *) fail "a spent budget must declare a keyed external wait, got: $line" ;;
  esac
  pass "a spent budget declares a keyed external wait rather than a wedge"
}

# --- the StopFailure detector hook ------------------------------------------

run_hook() {  # <state-dir> <task> <payload-json>
  printf '%s' "$3" | env -u GROK_AGENT -u GROK_HOOK_EVENT \
    "$HOOK" --task "$2" --state "$1"
}

test_hook_records_a_transient_stop_failure() {
  local st
  command -v jq >/dev/null 2>&1 || { pass "hook payload tests skipped: no jq on this host"; return; }
  st=$(new_state hook-transient)
  run_hook "$st" task-h "$(jq -nc --arg m "$E503_ACCOUNTS" \
    '{hook_event_name:"StopFailure",error:"server_error",last_assistant_message:$m}')" \
    || fail "the hook must always exit 0"
  fm_gateway_stall_open "$st" task-h || fail "a transient StopFailure was not recorded"
  pass "the StopFailure hook records a transient gateway stall"
}

test_hook_clears_the_record_on_any_other_failure() {
  local st
  command -v jq >/dev/null 2>&1 || { pass "hook payload tests skipped: no jq on this host"; return; }
  st=$(new_state hook-clears)
  fm_gateway_note_stall "$st" task-i server_error || fail "could not seed a stall record"
  run_hook "$st" task-i "$(jq -nc --arg m "$E_LIMIT" \
    '{hook_event_name:"StopFailure",error:"rate_limit",last_assistant_message:$m}')" \
    || fail "the hook must always exit 0"
  fm_gateway_stall_open "$st" task-i \
    && fail "a different failure proves the earlier stall is over and must drop its budget"
  pass "the StopFailure hook drops a stale stall record on any other failure"
}

test_hook_is_inert_on_a_foreign_or_unreadable_payload() {
  local st
  st=$(new_state hook-inert)
  run_hook "$st" task-j '' || fail "empty input must exit 0"
  fm_gateway_stall_open "$st" task-j && fail "empty input must record nothing"
  run_hook "$st" task-j 'not json at all' || fail "malformed input must exit 0"
  fm_gateway_stall_open "$st" task-j && fail "malformed input must record nothing"
  if command -v jq >/dev/null 2>&1; then
    run_hook "$st" task-j "$(jq -nc '{hook_event_name:"Stop",stop_hook_active:false}')" \
      || fail "a non-StopFailure event must exit 0"
    fm_gateway_stall_open "$st" task-j && fail "a Stop payload must record nothing"
    printf '%s' "$(jq -nc --arg m "$E503_ACCOUNTS" \
      '{hook_event_name:"StopFailure",error:"server_error",last_assistant_message:$m}')" \
      | GROK_HOOK_EVENT=stop "$HOOK" --task task-k --state "$st" \
      || fail "a foreign host payload must exit 0"
    fm_gateway_stall_open "$st" task-k \
      && fail "the hook must stand down on a foreign harness host"
  fi
  pass "the StopFailure hook is inert on empty, malformed, wrong-event, and foreign-host input"
}

test_hook_never_exits_two() {
  # StopFailure is executed outside Claude's REPL loop, so exit 2 buys nothing
  # and only risks being read as a hook failure. Pinned so nobody "upgrades"
  # this detector into a blocker that cannot work.
  local st rc=0
  command -v jq >/dev/null 2>&1 || { pass "hook payload tests skipped: no jq on this host"; return; }
  st=$(new_state hook-exit)
  printf '%s' "$(jq -nc --arg m "$E503_ACCOUNTS" \
    '{hook_event_name:"StopFailure",error:"server_error",last_assistant_message:$m}')" \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT "$HOOK" --task task-l --state "$st" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "the detector hook exited $rc; it must always exit 0"
  pass "the StopFailure detector never exits 2"
}

# --- the out-of-session primary keep-alive agent ------------------------------
#
# Driven over a real fake backend rather than asserted on its source, because
# everything that matters here is what it SENDS and what it refuses to send.

AGENT="$ROOT/bin/fm-keepalive-agent.sh"
ENDPOINT="$ROOT/bin/fm-keepalive-endpoint.sh"

make_primary_home() {  # <name>; echoes the home dir
  local name=$1 home
  home="$TMP_ROOT/$name"
  rm -rf "${home:?}"
  mkdir -p "$home/state" "$home/fakebin"
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  capture-pane) cat "${FM_FAKE_PANE:-/dev/null}"; exit 0 ;;
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_SENDLOG:-/dev/null}"; exit 0 ;;
  display-message) printf '\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$home/fakebin/tmux"
  : > "$home/send.log"
  printf 'window=x:y\nkind=ship\n' > "$home/state/t1.meta"
  TMUX_PANE='%9' "$ENDPOINT" record --state "$home/state" >/dev/null \
    || fail "could not record a primary endpoint for $name"
  printf '%s' "$E503_ACCOUNTS" > "$home/pane.txt"
  printf '%s\n' 'ordinary output, nothing wrong' > "$home/recovered.txt"
  printf '%s\n' "$home"
}

# Runs one agent pass with a live session lock and echoes how many keystroke
# batches reached the pane.
agent_pass() {  # <home> <pane-file> [extra env...]
  local home=$1 pane=$2
  shift 2
  : > "$home/send.log"
  PATH="$home/fakebin:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_SENDLOG="$home/send.log" \
    "$@" "$AGENT" --home "$home" >/dev/null 2>&1
  wc -l < "$home/send.log" | tr -d ' '
}

with_live_lock() {  # <home> <command...>
  local home=$1 pid rc
  shift
  sleep 30 &
  pid=$!
  printf 'pid=%s\n' "$pid" > "$home/state/.lock"
  "$@"
  rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return $rc
}

test_primary_agent_re_rings_a_stalled_primary() {
  local home sent
  home=$(make_primary_home primary-rering)
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/pane.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0)
  [ "$sent" -ge 1 ] || fail "the keep-alive did not send the stalled primary a continue line"
  grep -qi 'continue exactly where you left off' "$home/send.log" \
    || fail "what reached the pane is not the keep-alive continue line"
  [ -f "$home/state/.primary.gateway-stall" ] || fail "the pass recorded no stall"
  pass "the primary keep-alive re-rings a primary stalled on a gateway error"
}

test_primary_agent_refuses_a_pane_with_no_live_session() {
  # The dangerous case: the pane may no longer be firstmate at all, and typing
  # a paragraph at a plain shell prompt is worse than doing nothing.
  local home sent
  home=$(make_primary_home primary-dead-session)
  printf 'pid=999999\n' > "$home/state/.lock"
  sent=$(agent_pass "$home" "$home/pane.txt" env FM_GATEWAY_RETRY_BACKOFF=0)
  [ "$sent" -eq 0 ] || fail "the keep-alive typed into a pane whose session lock names no live owner"
  grep -q 'no live owner' "$home/state/.keepalive-agent.log" \
    || fail "the refusal was not reported"
  pass "the primary keep-alive refuses to type into a pane with no live session"
}

test_primary_agent_stops_at_the_budget_and_reports_the_outage() {
  local home sent now
  home=$(make_primary_home primary-outage)
  now=$(date +%s)
  printf 'v1 first=%s attempts=8 last=%s notified=0 kind=pane\n' \
    "$(( now - 100 ))" "$(( now - 100 ))" > "$home/state/.primary.gateway-stall"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/pane.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0 FM_GATEWAY_RETRY_MAX=8)
  [ "$sent" -eq 0 ] || fail "a spent budget must stop the re-ring"
  grep -q 'OUTAGE' "$home/state/.keepalive-agent.log" \
    || fail "a spent budget must report the outage the captain asked to be told about"
  pass "the primary keep-alive stops at its budget and reports a real outage"
}

test_primary_agent_repairs_lapsed_supervision_once_per_episode() {
  local home first second
  home=$(make_primary_home primary-supervision)
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  first=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt")
  [ "$first" -ge 1 ] || fail "lapsed supervision with work in flight was not repaired"
  grep -qi 'supervision has been down' "$home/send.log" \
    || fail "what reached the pane is not a supervision repair line"
  second=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt")
  [ "$second" -eq 0 ] || fail "the supervision nag must be bounded, not sent every pass"
  pass "the primary keep-alive repairs lapsed supervision once per episode"
}

test_primary_agent_stands_down_in_away_mode_and_when_idle() {
  local home sent
  home=$(make_primary_home primary-standdown)
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  : > "$home/state/.afk"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt")
  [ "$sent" -eq 0 ] || fail "away mode owns supervision; the keep-alive must stand down"
  rm -f "$home/state/.afk" "$home/state/t1.meta"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt")
  [ "$sent" -eq 0 ] || fail "a home with nothing to supervise must not be nagged"
  pass "the primary keep-alive stands down in away mode and on an idle home"
}

test_primary_agent_is_inert_without_a_recorded_endpoint() {
  local home sent
  home=$(make_primary_home primary-no-endpoint)
  rm -f "$home/state/.primary-endpoint"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/pane.txt")
  [ "$sent" -eq 0 ] || fail "the keep-alive acted without a proved endpoint"
  grep -q 'no recorded primary endpoint' "$home/state/.keepalive-agent.log" \
    || fail "the inert pass did not say why it did nothing"
  pass "the primary keep-alive is inert, and says so, without a proved endpoint"
}


test_text_classifier_accepts_the_real_transient_errors
test_deny_list_beats_a_transient_code_inside_a_permanent_failure
test_a_gateway_that_is_simply_down_is_not_retried
test_typed_kind_and_text_are_independent_positives
test_ladder_is_bounded_by_attempts
test_ladder_is_bounded_by_wall_clock_independently
test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach
test_first_attempt_waits_out_its_backoff
test_backoff_ladder_repeats_its_last_step
test_pane_is_authoritative_after_the_first_attempt
test_stale_hook_record_expires_without_a_pane_match
test_spent_budget_declares_an_external_wait_not_a_wedge
test_hook_records_a_transient_stop_failure
test_hook_clears_the_record_on_any_other_failure
test_hook_is_inert_on_a_foreign_or_unreadable_payload
test_hook_never_exits_two
test_primary_agent_re_rings_a_stalled_primary
test_primary_agent_refuses_a_pane_with_no_live_session
test_primary_agent_stops_at_the_budget_and_reports_the_outage
test_primary_agent_repairs_lapsed_supervision_once_per_episode
test_primary_agent_stands_down_in_away_mode_and_when_idle
test_primary_agent_is_inert_without_a_recorded_endpoint

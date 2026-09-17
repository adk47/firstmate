#!/usr/bin/env bash
# Behavior tests for the transient inference-gateway keep-alive:
# the rendered-pane classifier (the bounded tail window and the deny list that
# beats it), the twice-bounded retry ladder, the out-of-session primary
# keep-alive agent, and the main home's session-start install sweep.
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
  # gateway's sentences and the word overloaded at its prompt. None of that is
  # the harness's rendered "API Error: <5xx>" shape.
  local pane
  pane=$(printf '%s\n%s' "$(cat <<'TXT'
bin/fm-gateway-retry-lib.sh:34:# word such as "overloaded".
docs/gateway-keepalive.md:12: the gateway's own out-of-capacity sentences
tests/fm-gateway-keepalive.test.sh:22: All accounts are temporarily unavailable
tests/fm-gateway-keepalive.test.sh:23: Service temporarily unavailable
Overloaded
TXT
)" "$IDLE_FOOTER")
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

  # The primary has no status log of its own, and none is invented for it.
  fm_gateway_note_stall "$st" "$FM_GATEWAY_PRIMARY_SCOPE" || fail "could not open the primary's record"
  fm_gateway_mark_notified "$st" "$FM_GATEWAY_PRIMARY_SCOPE" || fail "could not mark the primary notified"
  fm_gateway_stalled_now "$st" "$FM_GATEWAY_PRIMARY_SCOPE" "$(ordinary_lines 3)" \
    && fail "a recovered primary pane still reads as stalled"
  [ ! -e "$st/$FM_GATEWAY_PRIMARY_SCOPE.status" ] \
    || fail "the clear path invented a status log for a scope that has none"
  pass "a recovered agent's declared gateway wait is closed, leaving no open gateway-503 phase"
}

test_a_busy_turn_clears_a_stall_record_whatever_its_length() {
  local st status open
  st=$(new_state busy-progress)
  status="$st/task-b.status"
  printf 'working: started\n' > "$status"

  # A stall opens, is re-rung once, and spends its budget, so the wait is
  # declared as the external wait it is.
  fm_gateway_stalled_now "$st" task-b "$E503_ACCOUNTS" || fail "a stalled pane must open the record"
  fm_gateway_record_attempt "$st" task-b || fail "could not charge an attempt"
  fm_gateway_mark_notified "$st" task-b || fail "could not mark the wait declared"
  printf '%s\n' "$(fm_gateway_paused_status_line "$st" task-b)" >> "$status"
  open=$(open_activity_keys "$status")
  case "$open" in
    *gateway-503*) : ;;
    *) fail "the declared wait did not open a keyed phase to begin with, got: $open" ;;
  esac

  # The crew recovers and runs one long continuous turn. Its pane reads busy for
  # the whole of it, so the idle clear path is never reached and the record would
  # otherwise outlive the stall it records.
  fm_gateway_note_progress "$st" task-b
  fm_gateway_stall_open "$st" task-b && fail "a busy turn left the stall record open"
  open=$(open_activity_keys "$status")
  case "$open" in
    *gateway-503*) fail "a recovered crew is still declared as waiting on the gateway: $open" ;;
  esac

  # So a genuinely new transient error begins a fresh ladder, instead of being
  # judged against the stale anchor and declared spent with no retry at all.
  fm_gateway_stalled_now "$st" task-b "$E503_ACCOUNTS" \
    || fail "a new transient error did not open a fresh stall"
  [ "$(fm_gateway_attempts "$st" task-b)" = 0 ] \
    || fail "the new stall inherited the spent ladder's attempts"
  fm_gateway_budget_spent "$st" task-b \
    && fail "a genuinely new stall was declared spent on sight"

  # A no-op for a scope with no record, so every poll may call it unconditionally.
  fm_gateway_note_progress "$st" task-none \
    || fail "progress for a scope with no record must be a silent no-op"
  pass "a stall record does not outlive a successful turn, whatever its length"
}

test_a_notice_never_buries_an_unresolved_notice_of_another_kind() {
  local st
  st=$(new_state notice-kinds)
  fm_keepalive_notice_write "$st" outage "the gateway kept this primary stalled; check 127.0.0.1:8080" \
    || fail "could not record an outage notice"
  # The install notice's condition is real, but so is the outage's, and only
  # the outage's own writer may retire it.
  fm_keepalive_notice_write "$st" install "the installer refused" \
    && fail "an install notice displaced an unresolved outage notice"
  [ "$(fm_keepalive_notice_kind "$st")" = outage ] \
    || fail "the unresolved outage notice did not survive a competing write"
  # The same kind is the same condition, so its newest reason still wins.
  fm_keepalive_notice_write "$st" outage "the gateway is still down" \
    || fail "a same-kind update was refused"
  [ "$(fm_keepalive_notice_read "$st")" = 'the gateway is still down' ] \
    || fail "a same-kind update did not replace the recorded reason"
  # Once its own writer resolves it, the slot is free for the other condition.
  fm_keepalive_notice_clear "$st" outage
  fm_keepalive_notice_write "$st" install "the installer refused" \
    || fail "a resolved slot refused the other writer's condition"
  [ "$(fm_keepalive_notice_kind "$st")" = install ] \
    || fail "the install notice was not recorded once the outage cleared"
  pass "an unresolved notice is never buried by the other writer's condition"
}

# --- the out-of-session primary keep-alive agent ------------------------------
#
# Driven over a real fake backend rather than asserted on its source, because
# everything that matters here is what it SENDS and what it refuses to send.

AGENT="$ROOT/bin/fm-keepalive-agent.sh"
ENDPOINT="$ROOT/bin/fm-keepalive-endpoint.sh"

# A fake process table: the pid named by FM_FAKE_LOCK_PID is a live claude
# harness, every other pid is a plain shell. This is what makes state/.lock
# mean "a live firstmate session" the way bin/fm-lock.sh and its readers mean
# it, rather than "some process is alive".
write_fake_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
harness=${FM_FAKE_LOCK_PID:-}
case "$field" in
  comm=) if [ "$pid" = "$harness" ]; then printf '/usr/local/bin/claude\n'; else printf '/bin/bash\n'; fi ;;
  args=) if [ "$pid" = "$harness" ]; then printf 'claude --resume\n'; else printf 'bash\n'; fi ;;
  ppid=) if [ "$pid" = "$harness" ]; then printf '1\n'; else printf '%s\n' "${harness:-1}"; fi ;;
  *) printf '\n' ;;
esac
exit 0
SH
  chmod +x "$1/ps"
}

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
  write_fake_ps "$home/fakebin"
  : > "$home/send.log"
  printf 'window=x:y\nkind=ship\n' > "$home/state/t1.meta"
  TMUX_PANE='%9' "$ENDPOINT" record --state "$home/state" >/dev/null \
    || fail "could not record a primary endpoint for $name"
  printf '%s\n%s' "$E503_ACCOUNTS" "$IDLE_FOOTER" > "$home/pane.txt"
  printf '%s\n%s' 'ordinary output, nothing wrong' "$IDLE_FOOTER" > "$home/recovered.txt"
  printf '%s\n%s\n%s' "$E503_ACCOUNTS" '⏺ carrying on with the interrupted step' \
    '✻ Thinking… (esc to interrupt)' > "$home/busy.txt"
  printf '%s\n' "$home"
}

# Runs one agent pass and echoes how many keystroke batches reached the pane.
agent_pass() {  # <home> <pane-file> [extra env...]
  local home=$1 pane=$2
  shift 2
  : > "$home/send.log"
  PATH="$home/fakebin:$PATH" FM_FAKE_PANE="$pane" FM_FAKE_SENDLOG="$home/send.log" \
    "$@" "$AGENT" --home "$home" >/dev/null 2>&1
  wc -l < "$home/send.log" | tr -d ' '
}

# Seeds state/.lock exactly as bin/fm-lock.sh writes it - a BARE pid - naming a
# live process the fake process table reports as a claude harness.
with_live_lock() {  # <home> <command...>
  local home=$1 pid rc
  shift
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.lock"
  FM_FAKE_LOCK_PID=$pid "$@"
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

test_primary_agent_never_types_into_a_busy_primary() {
  # The captain, or an earlier pass, already nudged the primary and it is
  # mid-turn with the old error still on screen. Typing now would land a second
  # continue line in a running turn.
  local home sent
  home=$(make_primary_home primary-busy)
  touch "$home/state/.last-watcher-beat"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/busy.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0)
  [ "$sent" -eq 0 ] || fail "the keep-alive typed into a primary that is mid-turn"
  [ ! -f "$home/state/.primary.gateway-stall" ] \
    || fail "a busy primary must not be charged a gateway stall"
  pass "the primary keep-alive stands down while the primary's pane is busy"
}

test_primary_agent_drops_the_record_once_the_primary_recovered() {
  local home sent now
  home=$(make_primary_home primary-recovered)
  touch "$home/state/.last-watcher-beat"
  now=$(date +%s)
  printf 'v1 first=%s attempts=1 last=%s notified=0 kind=pane\n' \
    "$(( now - 100 ))" "$(( now - 100 ))" > "$home/state/.primary.gateway-stall"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0)
  [ "$sent" -eq 0 ] || fail "a recovered primary was re-rung"
  [ ! -f "$home/state/.primary.gateway-stall" ] \
    || fail "a recovered primary's stall record was kept, so a later stall would start with a spent budget"
  pass "the primary keep-alive drops the stall record once the primary's pane has moved on"
}

test_primary_agent_refuses_a_pane_with_no_live_session() {
  # The dangerous case: the pane may no longer be firstmate at all, and typing
  # a paragraph at a plain shell prompt is worse than doing nothing.
  local home sent
  home=$(make_primary_home primary-dead-session)
  printf '999999\n' > "$home/state/.lock"
  sent=$(agent_pass "$home" "$home/pane.txt" env FM_GATEWAY_RETRY_BACKOFF=0)
  [ "$sent" -eq 0 ] || fail "the keep-alive typed into a pane whose session lock names no live owner"
  grep -q 'no live owner' "$home/state/.keepalive-agent.log" \
    || fail "the refusal was not reported"
  pass "the primary keep-alive refuses to type into a pane with no live session"
}

test_primary_agent_requires_the_lock_owner_to_be_a_harness() {
  # A bare pid that is alive but is not a harness process is a reused pid, not
  # firstmate. The same liveness predicate the lock's own readers use decides.
  local home sent pid
  home=$(make_primary_home primary-reused-pid)
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.lock"
  sent=$(FM_FAKE_LOCK_PID=0 agent_pass "$home" "$home/pane.txt" env FM_GATEWAY_RETRY_BACKOFF=0)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$sent" -eq 0 ] || fail "a live non-harness pid in state/.lock was treated as a running firstmate session"
  pass "the primary keep-alive treats a live non-harness lock pid as no session"
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

  # The log has no reader during an outage, so the outage must also reach the
  # notice the next session start reports.
  [ "$(fm_keepalive_notice_kind "$home/state")" = outage ] \
    || fail "a spent budget on the primary left no keep-alive notice for session start to report"
  case "$(fm_keepalive_notice_read "$home/state")" in
    *127.0.0.1:8080*) : ;;
    *) fail "the recorded outage does not name what the captain has to check" ;;
  esac

  with_live_lock "$home" agent_pass "$home" "$home/pane.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0 FM_GATEWAY_RETRY_MAX=8 >/dev/null
  [ "$(fm_keepalive_notice_kind "$home/state")" = outage ] \
    || fail "a continuing outage must not be re-recorded away by the next pass"

  with_live_lock "$home" agent_pass "$home" "$home/recovered.txt" >/dev/null
  fm_keepalive_notice_read "$home/state" >/dev/null 2>&1 \
    && fail "a primary that recovered is still reported as a live outage"
  pass "the primary keep-alive stops at its budget, records the outage for session start, and clears it on recovery"
}

test_primary_outage_notice_survives_a_busy_pane() {
  # A busy pane is never classified, so it carries no evidence the outage ended.
  # The captain typing a nudge into a still-503ing primary is exactly that.
  local home now
  home=$(make_primary_home primary-outage-busy)
  now=$(date +%s)
  printf 'v1 first=%s attempts=8 last=%s notified=0 kind=pane\n' \
    "$(( now - 100 ))" "$(( now - 100 ))" > "$home/state/.primary.gateway-stall"
  with_live_lock "$home" agent_pass "$home" "$home/pane.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0 FM_GATEWAY_RETRY_MAX=8 >/dev/null
  [ "$(fm_keepalive_notice_kind "$home/state")" = outage ] \
    || fail "the spent budget recorded no outage notice to begin with"

  with_live_lock "$home" agent_pass "$home" "$home/busy.txt" \
    env FM_GATEWAY_RETRY_BACKOFF=0 FM_GATEWAY_RETRY_MAX=8 >/dev/null
  [ "$(fm_keepalive_notice_kind "$home/state")" = outage ] \
    || fail "a busy pane erased an outage notice nothing had resolved"
  pass "a busy primary pane leaves an unresolved outage notice exactly as it is"
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

test_primary_agent_repairs_supervision_for_a_procevent_only_home() {
  # A registered process-to-event source is a wait on an external process, not
  # a task: it has no state/<id>.meta, and it still needs a running watcher.
  local home sent
  home=$(make_primary_home primary-procevent)
  rm -f "$home/state/t1.meta"
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" register lavish keepalive-src -- \
    /bin/sh -c 'exit 0' >/dev/null \
    || fail "could not register a process-event source"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  sent=$(with_live_lock "$home" agent_pass "$home" "$home/recovered.txt")
  [ "$sent" -ge 1 ] || fail "a home whose only supervision need is a registered event source was left unsupervised"
  grep -qi 'supervision has been down' "$home/send.log" \
    || fail "what reached the pane is not a supervision repair line"
  pass "the primary keep-alive repairs supervision for a home whose only wait is an event source"
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

# Endpoint detection driven over the real `record`/`read` interface, in an
# environment stripped of every marker the caller is not testing, so each case
# proves what the session could actually observe about its own pane.
endpoint_record() {  # <state-dir> <env assignments...>; echoes "<backend> <target>"
  local dir=$1
  shift
  env -u TMUX_PANE -u TMUX -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID \
    -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u ORCA_TERMINAL_ID \
    "$@" "$ENDPOINT" record --state "$dir"
}

test_endpoint_detects_a_cmux_primary_in_the_shape_the_backend_parses() {
  local sdir out
  sdir="$TMP_ROOT/endpoint-cmux/state"
  rm -rf "$TMP_ROOT/endpoint-cmux"
  mkdir -p "$sdir"

  out=$(endpoint_record "$sdir" CMUX_WORKSPACE_ID=ws-1 CMUX_SURFACE_ID=sf-1) \
    || fail "a cmux primary's own identifiers proved no endpoint"
  [ "$out" = 'cmux ws-1:sf-1' ] || fail "expected 'cmux ws-1:sf-1', got '$out'"
  [ "$("$ENDPOINT" read --state "$sdir" --field backend)" = cmux ] \
    || fail "the record did not name cmux as the backend"
  # The recorded target must be what the cmux adapter actually parses, not a
  # shape only this script agrees with.
  (
    . "$ROOT/bin/backends/cmux.sh"
    t=$("$ENDPOINT" read --state "$sdir" --field target)
    fm_backend_cmux_parse_target "$t" || exit 1
    [ "$FM_BACKEND_CMUX_WORKSPACE" = ws-1 ] && [ "$FM_BACKEND_CMUX_SURFACE" = sf-1 ]
  ) || fail "the recorded cmux target is not the <workspace>:<surface> the adapter parses"

  # cmux injects its modern and legacy identifiers together and marks all five
  # non-overridable, so the legacy pair on its own is not a cmux surface and
  # proves nothing (bin/fm-backend.sh records that contract).
  rm -f "$sdir/.primary-endpoint"
  endpoint_record "$sdir" CMUX_TAB_ID=ws-2 CMUX_PANEL_ID=sf-2 >/dev/null 2>&1 \
    && fail "cmux's legacy identifier spellings alone proved an endpoint"
  [ ! -e "$sdir/.primary-endpoint" ] || fail "a failed detection still wrote a record"

  # Half a pair is not a pane: nothing to prove, so nothing is recorded.
  endpoint_record "$sdir" CMUX_WORKSPACE_ID=ws-3 >/dev/null 2>&1 \
    && fail "a workspace with no surface must not prove an endpoint"
  [ ! -e "$sdir/.primary-endpoint" ] || fail "a failed detection still wrote a record"
  pass "endpoint detection resolves a cmux primary into the target the cmux adapter parses"
}

test_endpoint_refuses_a_runtime_it_cannot_read() {
  local state
  state="$TMP_ROOT/endpoint-unproved/state"
  rm -rf "$TMP_ROOT/endpoint-unproved"
  mkdir -p "$state"

  # orca ids come from the orca CLI at spawn time, never from the environment;
  # an inherited ORCA_TERMINAL_ID proves nothing and must not be believed.
  endpoint_record "$state" ORCA_TERMINAL_ID=orca-1 >/dev/null 2>&1 \
    && fail "an environment variable orca never exports proved an endpoint"
  [ ! -e "$state/.primary-endpoint" ] || fail "an unproved runtime still wrote a record"

  # The explicit override is the documented way in for such a runtime.
  env -u TMUX_PANE -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET \
    -u FM_SUPERVISOR_BACKEND -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
    "$ENDPOINT" record --state "$state" --backend orca --target orca-1 >/dev/null \
    || fail "the explicit --backend/--target override was refused"
  [ "$("$ENDPOINT" read --state "$state" --field target)" = orca-1 ] \
    || fail "the override did not reach the record"
  pass "a runtime whose identifiers cannot be read needs the explicit override, and gets it"
}

test_endpoint_record_carries_only_the_fields_it_documents() {
  local state line
  state="$TMP_ROOT/endpoint-fields/state"
  rm -rf "$TMP_ROOT/endpoint-fields"
  mkdir -p "$state"
  endpoint_record "$state" TMUX_PANE='%7' >/dev/null || fail "a tmux primary proved no endpoint"
  line=$("$ENDPOINT" read --state "$state")
  case "$line" in
    'v1 backend=tmux target=%7 harness='*' ts='*) : ;;
    *) fail "unexpected record line '$line'" ;;
  esac
  "$ENDPOINT" read --state "$state" --field pid >/dev/null 2>&1 \
    && fail "the record still carries the dropped pid field"
  pass "the endpoint record is exactly the documented v1 line"
}

test_installer_plist_has_no_dead_flag() {
  # The plist is the generated artifact launchd consumes; the agent takes no
  # --once, so the job must not pass one.
  local home fakebin out plist
  home="$TMP_ROOT/plist-shape"
  rm -rf "${home:?}"
  mkdir -p "$home/state" "$home/fakehome"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" launchctl
  printf '#!/usr/bin/env bash\nprintf Darwin\\\\n\n' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  out=$(HOME="$home/fakehome" PATH="$fakebin:$PATH" TMUX_PANE='%3' \
    "$ROOT/bin/fm-keepalive-install.sh" install --home "$home" 2>&1) \
    || fail "install refused: $out"
  plist=$(find "$home/fakehome/Library/LaunchAgents" -name 'ai.firstmate.keepalive.*.plist' | head -1)
  [ -n "$plist" ] || fail "install wrote no plist"
  grep -q "$ROOT/bin/fm-keepalive-agent.sh" "$plist" || fail "the job does not run this home's agent"
  grep -q -- '--once' "$plist" && fail "the job passes a --once the agent does not take"
  pass "the launchd job runs the agent with --home only"
}

test_installer_keeps_a_pre_existing_plist_a_failed_reload_did_not_write() {
  # A reachable domain whose load verbs refuse is not evidence the job is gone,
  # so a failed reload must never take away an installation someone else made.
  local home fakebin out plist before
  home="$TMP_ROOT/plist-failed-reload"
  rm -rf "${home:?}"
  mkdir -p "$home/state" "$home/fakehome"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" launchctl
  printf '#!/usr/bin/env bash\nprintf Darwin\\\\n\n' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  out=$(HOME="$home/fakehome" PATH="$fakebin:$PATH" TMUX_PANE='%3' \
    "$ROOT/bin/fm-keepalive-install.sh" install --home "$home" 2>&1) \
    || fail "install refused: $out"
  plist=$(find "$home/fakehome/Library/LaunchAgents" -name 'ai.firstmate.keepalive.*.plist' | head -1)
  [ -n "$plist" ] || fail "install wrote no plist"
  before=$(shasum < "$plist")

  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = print ] && exit 0
exit 1
SH
  chmod +x "$fakebin/launchctl"
  out=$(HOME="$home/fakehome" PATH="$fakebin:$PATH" TMUX_PANE='%3' \
    "$ROOT/bin/fm-keepalive-install.sh" install --home "$home" 2>&1) \
    && fail "a launchctl that refused every load verb was reported as success"
  [ -f "$plist" ] || fail "a failed reload deleted a plist this invocation did not create"
  [ "$(shasum < "$plist")" = "$before" ] || fail "the surviving plist is not the one that was installed"
  case "$out" in
    *"left in place"*) : ;;
    *) fail "the failed reload did not report that the installed job was left alone: $out" ;;
  esac

  rm -f "$plist"
  out=$(HOME="$home/fakehome" PATH="$fakebin:$PATH" TMUX_PANE='%3' \
    "$ROOT/bin/fm-keepalive-install.sh" install --home "$home" 2>&1) \
    && fail "a launchctl that refused every verb was reported as success"
  [ ! -f "$plist" ] || fail "a first install that could not load left a plist claiming it had"
  pass "a failed reload keeps a plist it did not write, and a failed first install leaves none"
}

test_installer_plist_survives_xml_significant_paths() {
  # launchd parses the plist as XML, so a home or PATH entry carrying & or < is
  # the difference between a job that loads and one that silently never runs.
  command -v python3 >/dev/null 2>&1 || { pass "skipped: python3 not found"; return 0; }
  local home fakebin out plist
  home="$TMP_ROOT/plist-r&d<x>"
  rm -rf "${home:?}"
  mkdir -p "$home/state" "$home/fakehome"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" launchctl
  printf '#!/usr/bin/env bash\nprintf Darwin\\\\n\n' > "$fakebin/uname"
  chmod +x "$fakebin/uname"
  out=$(HOME="$home/fakehome" PATH="$fakebin:$home/r&d/bin:$PATH" TMUX_PANE='%3' \
    "$ROOT/bin/fm-keepalive-install.sh" install --home "$home" 2>&1) \
    || fail "install refused: $out"
  plist=$(find "$home/fakehome/Library/LaunchAgents" -name 'ai.firstmate.keepalive.*.plist' | head -1)
  [ -n "$plist" ] || fail "install wrote no plist"
  python3 - "$plist" "$home" <<'PY' || fail "the plist launchd would parse does not carry the paths it was given"
import plistlib, sys
job = plistlib.load(open(sys.argv[1], 'rb'))
home = sys.argv[2]
assert job['ProgramArguments'][1:] == ['--home', home], job['ProgramArguments']
assert job['EnvironmentVariables']['FM_HOME'] == home, job['EnvironmentVariables']
assert job['StandardOutPath'] == home + '/state/.keepalive-agent.out', job['StandardOutPath']
assert home + '/r&d/bin' in job['EnvironmentVariables']['PATH'].split(':'), job['EnvironmentVariables']['PATH']
PY
  pass "the generated plist stays well-formed for a home and PATH carrying XML-significant characters"
}

# --- the main home's session-start install sweep ------------------------------
#
# Driven through the real bin/fm-bootstrap.sh over a genuine primary checkout:
# a plain git repository carrying AGENTS.md, its own bin/, a state dir, and a
# session lock owned by this process tree (through the fake process table). The
# launchd side is a fake launchctl and a HOME under the fixture, so nothing
# leaves the fixture.

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"

make_locked_primary_checkout() {  # <name>; echoes the home dir
  local name=$1 home fakebin
  home="$TMP_ROOT/boot-$name"
  rm -rf "${home:?}"
  mkdir -p "$home/state" "$home/config" "$home/fakehome"
  git init -q "$home"
  cp -R "$ROOT/bin" "$home/bin"
  : > "$home/AGENTS.md"
  printf '700\n' > "$home/state/.lock"
  fakebin=$(fm_fakebin "$home")
  write_fake_ps "$fakebin"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LAUNCHCTL_LOG:-/dev/null}"
[ "${1:-}" != print ] && exit 0
# gui/<uid>/<label> asks about the job; gui/<uid> asks about the domain itself.
case "${2:-}" in
  */*/*) exit "${FM_FAKE_LAUNCHCTL_PRINT_RC:-0}" ;;
  *) exit "${FM_FAKE_LAUNCHCTL_GUI_RC:-0}" ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_UNAME:-Darwin}"
SH
  chmod +x "$fakebin/uname"
  printf '%s\n' "$home"
}

# One session-start bootstrap over <home>; prints its stdout.
run_sweep() {  # <home> [env...]
  local home=$1
  shift
  HOME="$home/fakehome" PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_FAKE_LOCK_PID=700 FM_FAKE_LAUNCHCTL_LOG="$home/launchctl.log" \
    FM_BOOTSTRAP_NETWORK=skip TMUX_PANE='%9' "$@" "$BOOTSTRAP" 2>/dev/null
}

keepalive_lines() {  # <output>
  printf '%s\n' "$1" | grep -c '^BOOTSTRAP_INFO: primary keep-alive ' || true
}

installed_plist() {  # <home>
  find "$1/fakehome/Library/LaunchAgents" -name 'ai.firstmate.keepalive.*.plist' 2>/dev/null | head -1
}

# Only the verbs that (re)load the job count as a load; a liveness probe is not
# one.
load_ops() {  # <home>
  grep -c '^\(bootstrap\|load\) ' "$1/launchctl.log" 2>/dev/null || true
}

test_session_start_installs_the_primary_keepalive_once_and_refreshes_its_endpoint() {
  local home out plist sum1 sum2 loads
  home=$(make_locked_primary_checkout install)
  out=$(run_sweep "$home")
  [ "$(keepalive_lines "$out")" = 1 ] || fail "expected exactly one primary keep-alive fact on first session start, got: $out"
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive installed' \
    || fail "the first session start did not report the install: $out"
  plist=$(installed_plist "$home")
  [ -n "$plist" ] || fail "session start installed no launchd job"
  grep -q "$home/bin/fm-keepalive-agent.sh" "$plist" || fail "the job does not run this home's own agent"
  grep -q 'bootstrap' "$home/launchctl.log" || fail "the job was written but never loaded"
  [ "$("$ENDPOINT" read --state "$home/state" --field target)" = '%9' ] \
    || fail "session start did not record the primary's own pane"

  sum1=$(shasum < "$plist")
  loads=$(load_ops "$home")
  out=$(run_sweep "$home")
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a session start with the job already installed must be quiet, got: $out"
  sum2=$(shasum < "$plist")
  [ "$sum1" = "$sum2" ] || fail "an already-installed job was rewritten"
  [ "$(load_ops "$home")" = "$loads" ] || fail "an already-installed job was reloaded"

  out=$(run_sweep "$home" env TMUX_PANE='%10')
  [ "$(keepalive_lines "$out")" = 1 ] || fail "a relaunch into a new pane must report one refresh, got: $out"
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive refreshed' \
    || fail "the relaunch was not reported as a refresh: $out"
  [ "$("$ENDPOINT" read --state "$home/state" --field target)" = '%10' ] \
    || fail "the relaunched primary's pane was not re-recorded"
  [ "$(load_ops "$home")" = "$loads" ] || fail "a refresh must not reload the job"

  # A plist on disk proves only that a file exists: launchd may have booted the
  # job out, or never loaded it at all.
  out=$(run_sweep "$home" env TMUX_PANE='%10' FM_FAKE_LAUNCHCTL_PRINT_RC=1)
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive installed' \
    || fail "a plist whose job is not loaded was reported as healthy: $out"
  [ "$(load_ops "$home")" -gt "$loads" ] || fail "the job launchd is not running was never re-bootstrapped"
  pass "the main home's session start installs the keep-alive once, stays quiet after, re-points it on relaunch, and re-bootstraps a job launchd is not running"
}

test_session_start_stays_quiet_for_a_job_installed_with_an_explicit_endpoint() {
  # The home that followed the KEEPALIVE line's own remediation: installed by
  # hand with --backend/--target because its terminal proves nothing. Later
  # session starts still prove nothing, and its job is running fine.
  local home out rc=0
  home=$(make_locked_primary_checkout keepalive-override)
  HOME="$home/fakehome" PATH="$home/fakebin:$PATH" \
    FM_FAKE_LAUNCHCTL_LOG="$home/launchctl.log" \
    "$home/bin/fm-keepalive-install.sh" install --home "$home" \
    --backend tmux --target '%77' >/dev/null \
    || fail "the documented --backend/--target install refused"
  [ -n "$(installed_plist "$home")" ] || fail "the override install wrote no plist"

  out=$(run_sweep "$home" env -u TMUX_PANE -u TMUX -u HERDR_ENV -u HERDR_SESSION \
    -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u ORCA_TERMINAL_ID) || rc=$?
  [ "$rc" -eq 0 ] || fail "a healthy keep-alive must not fail session start"
  printf '%s\n' "$out" | grep -q '^KEEPALIVE: ' \
    && fail "a job that is installed and loaded was reported as broken: $out"
  fm_keepalive_notice_read "$home/state" >/dev/null 2>&1 \
    && fail "a healthy keep-alive recorded a failure notice"
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a healthy keep-alive must be quiet: $out"
  [ "$("$ENDPOINT" read --state "$home/state" --field target)" = '%77' ] \
    || fail "the session that could prove no endpoint overwrote the recorded one"
  pass "session start leaves a loaded job installed with an explicit endpoint alone, and says nothing"
}

test_session_start_reloads_an_unloaded_job_from_the_recorded_endpoint() {
  # Everything needed to reload the job is on disk, including the pane the
  # override install recorded, so a session start that can prove no endpoint of
  # its own must re-bootstrap rather than declare the home uninstallable.
  local home out loads rc=0
  home=$(make_locked_primary_checkout keepalive-unloaded)
  HOME="$home/fakehome" PATH="$home/fakebin:$PATH" \
    FM_FAKE_LAUNCHCTL_LOG="$home/launchctl.log" \
    "$home/bin/fm-keepalive-install.sh" install --home "$home" \
    --backend tmux --target '%77' >/dev/null \
    || fail "the documented --backend/--target install refused"
  loads=$(load_ops "$home")

  out=$(run_sweep "$home" env -u TMUX_PANE -u TMUX -u HERDR_ENV -u HERDR_SESSION \
    -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u ORCA_TERMINAL_ID FM_FAKE_LAUNCHCTL_PRINT_RC=1) || rc=$?
  [ "$rc" -eq 0 ] || fail "reloading the job must not fail session start"
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive installed' \
    || fail "an unloaded job with a recorded pane was not reloaded: $out"
  [ "$(load_ops "$home")" -gt "$loads" ] || fail "the unloaded job was never bootstrapped again"
  printf '%s\n' "$out" | grep -q '^KEEPALIVE: ' \
    && fail "a home that could be reloaded was reported as having no keep-alive: $out"
  fm_keepalive_notice_read "$home/state" >/dev/null 2>&1 \
    && fail "a reloadable home recorded a keep-alive failure notice"
  [ "$("$ENDPOINT" read --state "$home/state" --field target)" = '%77' ] \
    || fail "the reload lost the recorded primary pane"
  pass "session start reloads an unloaded job from the endpoint this home already recorded"
}

test_session_start_changes_nothing_when_the_launchd_domain_is_unreachable() {
  # An ssh session or a login-session transition cannot reach the per-user GUI
  # domain. Every launchctl query fails there, which is evidence about the
  # domain and none at all about the job.
  local home out loads rc=0
  home=$(make_locked_primary_checkout keepalive-nogui)
  out=$(run_sweep "$home")
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive installed' \
    || fail "the fixture did not install a healthy job to begin with: $out"
  loads=$(load_ops "$home")
  fm_keepalive_notice_write "$home/state" outage "the gateway kept this primary stalled" \
    || fail "could not stage an unresolved outage notice"

  out=$(run_sweep "$home" env FM_FAKE_LAUNCHCTL_GUI_RC=1 FM_FAKE_LAUNCHCTL_PRINT_RC=1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unreachable launchd domain must not fail session start"
  printf '%s\n' "$out" | grep -qF 'no working keep-alive' \
    && fail "a job the session could not observe was reported as missing: $out"
  [ "$(load_ops "$home")" = "$loads" ] \
    || fail "an unreachable domain must not tear down or reload the job"
  [ "$(fm_keepalive_notice_kind "$home/state")" = outage ] \
    || fail "the unresolved outage notice was overwritten by a session that could see nothing"
  printf '%s\n' "$out" | grep -q '^KEEPALIVE: the gateway kept this primary stalled' \
    || fail "the outage still waiting on the captain stopped being reported: $out"
  pass "a session that cannot reach the launchd domain reports nothing new and changes nothing"
}

test_session_start_reports_a_primary_that_could_not_be_kept_alive() {
  # A primary whose terminal proves no endpoint gets no job at all, which is the
  # captain's ask going unmet; the sweep must say so and still finish.
  local home out rc=0
  home=$(make_locked_primary_checkout keepalive-unprovable)
  out=$(run_sweep "$home" env -u TMUX_PANE -u TMUX -u HERDR_ENV -u HERDR_SESSION \
    -u HERDR_PANE_ID -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u ORCA_TERMINAL_ID) || rc=$?
  [ "$rc" -eq 0 ] || fail "a keep-alive that could not be installed must not fail session start"
  [ -z "$(installed_plist "$home")" ] || fail "the job was installed for a pane nobody proved"
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a failure must not be reported as a completed fact: $out"
  printf '%s\n' "$out" | grep -q '^KEEPALIVE: ' \
    || fail "a primary with no keep-alive was left silent: $out"
  printf '%s\n' "$out" | grep -q 'fm-keepalive-install.sh install' \
    || fail "the actionable line does not name the remediation: $out"
  [ "$(fm_keepalive_notice_kind "$home/state")" = install ] \
    || fail "the sweep reported the failure without recording it for the next session start"

  # Started from a pane it can read, the same home installs and stops reporting.
  out=$(run_sweep "$home")
  printf '%s\n' "$out" | grep -q '^BOOTSTRAP_INFO: primary keep-alive installed' \
    || fail "the retry from a readable pane did not install the job: $out"
  printf '%s\n' "$out" | grep -q '^KEEPALIVE: ' \
    && fail "a resolved keep-alive failure is still being reported: $out"
  fm_keepalive_notice_read "$home/state" >/dev/null 2>&1 \
    && fail "a successful install left the failure notice behind"
  pass "session start reports and then clears a primary that could not be kept alive"
}

test_session_start_keepalive_honours_the_opt_out_and_its_scope() {
  local home out
  home=$(make_locked_primary_checkout opt-out)
  : > "$home/config/keepalive-off"
  out=$(run_sweep "$home")
  [ "$(keepalive_lines "$out")" = 0 ] || fail "config/keepalive-off must silence the sweep, got: $out"
  [ -z "$(installed_plist "$home")" ] || fail "config/keepalive-off must install nothing"

  home=$(make_locked_primary_checkout linux)
  out=$(run_sweep "$home" env FM_FAKE_UNAME=Linux)
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a non-macOS host must print nothing, got: $out"
  [ -z "$(installed_plist "$home")" ] || fail "a non-macOS host must install nothing"

  home=$(make_locked_primary_checkout secondmate)
  printf 'mate-1\n' > "$home/.fm-secondmate-home"
  out=$(run_sweep "$home")
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a secondmate home stays opt-in, got: $out"
  [ -z "$(installed_plist "$home")" ] || fail "a secondmate home must not be auto-installed"

  home=$(make_locked_primary_checkout unowned)
  printf '999999\n' > "$home/state/.lock"
  out=$(run_sweep "$home")
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a session that does not own the fleet lock must not record its pane, got: $out"
  [ -z "$(installed_plist "$home")" ] || fail "a session that does not own the fleet lock must install nothing"
  [ ! -e "$home/state/.primary-endpoint" ] || fail "a session that does not own the fleet lock recorded its pane as the primary"

  home=$(make_locked_primary_checkout detect-only)
  out=$(run_sweep "$home" env FM_BOOTSTRAP_DETECT_ONLY=1)
  [ "$(keepalive_lines "$out")" = 0 ] || fail "a detect-only session start must not install, got: $out"
  [ -z "$(installed_plist "$home")" ] || fail "a detect-only session start installed the job"
  pass "the session-start keep-alive sweep honours config/keepalive-off, macOS only, main home only, lock ownership, and detect-only"
}


test_text_classifier_accepts_the_real_transient_errors
test_deny_list_beats_a_transient_code_inside_a_permanent_failure
test_deny_list_matches_anywhere_while_the_transient_match_is_bounded
test_a_recovered_agent_with_the_old_error_in_scrollback_is_not_stalled
test_repository_text_naming_the_errors_is_not_a_stall
test_a_gateway_that_is_simply_down_is_not_retried
test_ladder_is_bounded_by_attempts
test_ladder_is_bounded_by_wall_clock_independently
test_re_noting_a_stall_cannot_push_the_next_attempt_out_of_reach
test_first_attempt_waits_out_its_backoff
test_backoff_ladder_repeats_its_last_step
test_pane_is_the_single_detector
test_spent_budget_declares_an_external_wait_not_a_wedge
test_a_recovered_agent_closes_its_declared_gateway_wait
test_a_busy_turn_clears_a_stall_record_whatever_its_length
test_a_notice_never_buries_an_unresolved_notice_of_another_kind
test_primary_agent_re_rings_a_stalled_primary
test_primary_agent_never_types_into_a_busy_primary
test_primary_agent_drops_the_record_once_the_primary_recovered
test_primary_agent_refuses_a_pane_with_no_live_session
test_primary_agent_requires_the_lock_owner_to_be_a_harness
test_primary_agent_stops_at_the_budget_and_reports_the_outage
test_primary_outage_notice_survives_a_busy_pane
test_primary_agent_repairs_lapsed_supervision_once_per_episode
test_primary_agent_repairs_supervision_for_a_procevent_only_home
test_primary_agent_stands_down_in_away_mode_and_when_idle
test_primary_agent_is_inert_without_a_recorded_endpoint
test_endpoint_detects_a_cmux_primary_in_the_shape_the_backend_parses
test_endpoint_refuses_a_runtime_it_cannot_read
test_endpoint_record_carries_only_the_fields_it_documents
test_installer_plist_has_no_dead_flag
test_installer_keeps_a_pre_existing_plist_a_failed_reload_did_not_write
test_installer_plist_survives_xml_significant_paths
test_session_start_installs_the_primary_keepalive_once_and_refreshes_its_endpoint
test_session_start_stays_quiet_for_a_job_installed_with_an_explicit_endpoint
test_session_start_reloads_an_unloaded_job_from_the_recorded_endpoint
test_session_start_changes_nothing_when_the_launchd_domain_is_unreachable
test_session_start_reports_a_primary_that_could_not_be_kept_alive
test_session_start_keepalive_honours_the_opt_out_and_its_scope

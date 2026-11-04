#!/usr/bin/env bash
# tests/fm-ticket-intake.test.sh - the captain ask intake bound.
#
# The contract this pins: one captain input is a Trigger, a Trigger becomes one
# ticket carrying an owner and a first-proof due time, an ask with no owner after
# ten minutes and an owner with no first proof after an hour are both paged, and
# the ledger is the generated view of every ask rather than a hand-kept list.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-ticket-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-intake)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# run <home> <now> <args...>: one command against an isolated home with the
# clock pinned, so a bound is measured without waiting for it.
run() {
  local home=$1 now=$2
  shift 2
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TICKET_INTAKE_NOW="$now" "$INTAKE" "$@" 2>&1
}

trigger() {  # <home> <now> <text>
  run "$1" "$2" trigger --source chat "$3"
}

test_an_unowned_ask_pages_at_ten_minutes_then_reminds() {
  local home tr out
  home=$(make_home unowned)
  tr=$(trigger "$home" 1000 "fix the credits page copy")
  case "$tr" in
    tr-1000-*) : ;;
    *) fail "trigger did not print a usable id: $tr" ;;
  esac
  out=$(run "$home" 1500 check)
  [ -z "$out" ] || fail "an eight-minute-old ask was already paged: $out"
  out=$(run "$home" 1601 check)
  assert_contains "$out" "unowned ask" "a ten-minute-old ask was not paged"
  assert_contains "$out" "fix the credits page copy" "the page did not carry the ask's own words"
  assert_contains "$out" "no ticket or owner" "the page did not name the condition"
  out=$(run "$home" 1610 check)
  [ -z "$out" ] || fail "the same open finding was paged again on the next poll: $out"
  out=$(run "$home" 1601 check)
  assert_not_contains "$out" "unowned ask" "a re-poll inside the reminder window paged again"
  out=$(run "$home" 3500 check)
  assert_contains "$out" "unowned ask still open after" "the finding was not reminded after the remind interval"
  pass "an ask with no ticket pages at ten minutes, stays quiet, then reminds"
}

test_the_owner_clock_pages_at_one_hour_and_first_proof_recovers() {
  local home tr out
  home=$(make_home owned)
  tr=$(trigger "$home" 1000 "ship the credits page copy fix")
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    out=$(run "$home" 1000 new "$tr" --title "Credits page copy" --owner alpha)
    case "$out" in
      ask-*) : ;;
      *) fail "new did not print the created row id: $out" ;;
    esac
  else
    out=$(run "$home" 1000 attach credits-1 --trigger "$tr" --owner alpha)
    case "$out" in
      credits-1) : ;;
      *) fail "attach did not record the ticket: $out" ;;
    esac
  fi
  out=$(run "$home" 1000 status)
  assert_contains "$out" "1 open ticket(s), 0 ask(s) without an owner, 0 past first-proof due" \
    "status did not count the owned ticket"
  out=$(run "$home" 4599 check)
  [ -z "$out" ] || fail "a ticket inside its first hour was already paged: $out"
  out=$(run "$home" 4601 check)
  assert_contains "$out" "no first proof" "an owner with no first proof after an hour was not paged"
  assert_contains "$out" "owner alpha" "the page did not name the owner"
  printf 'working: started the credits page copy fix\n' > "$home/state/alpha.status"
  out=$(run "$home" 4700 check)
  assert_contains "$out" "recovered" "the owner's first status event did not clear the finding"
  out=$(run "$home" 4700 ledger)
  assert_contains "$out" "(status)" "the ledger did not record the first proof and its evidence"
  out=$(run "$home" 9000 check)
  assert_not_contains "$out" "no first proof" "a proved ticket kept paging"
  pass "an owner with no first proof after an hour pages, and its first status event clears it"
}

test_an_unowned_ticket_pages_from_when_the_captain_asked() {
  local home tr out
  [ "$HAVE_TASKS_AXI" = 1 ] || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home late-ticket)
  tr=$(trigger "$home" 1000 "the credits page copy is wrong")
  run "$home" 1000 new "$tr" --title "Credits page copy" >/dev/null 2>&1 \
    || fail "new could not record the ticket"
  out=$(run "$home" 1400 check)
  [ -z "$out" ] || fail "a ticket younger than the unowned bound was paged: $out"
  out=$(run "$home" 1601 check)
  assert_contains "$out" "unowned ticket" "a ticket with no owner was not paged"
  assert_contains "$out" "has had no owner for 10m" "the unowned bound did not measure from the ask's arrival"
  pass "a ticket with no owner pages on the ten-minute bound measured from arrival"
}

test_a_closed_ask_and_a_done_row_are_never_paged() {
  local home tr out task
  home=$(make_home closed)
  tr=$(trigger "$home" 1000 "quick question, no work needed")
  out=$(run "$home" 1000 close "$tr" --reason "answered in chat")
  assert_contains "$out" "closed:" "close did not report the answered ask"
  out=$(run "$home" 9000 check)
  [ -z "$out" ] || fail "an ask recorded as answered was paged: $out"
  out=$(run "$home" 9000 ledger --open)
  assert_not_contains "$out" "quick question" "--open kept an answered ask in the open view"
  [ "$HAVE_TASKS_AXI" = 1 ] || { echo "skip: tasks-axi not found"; return 0; }
  tr=$(trigger "$home" 9100 "another ask that ships")
  task=$(run "$home" 9100 new "$tr" --title "Another ask" --owner beta)
  (cd "$home" && tasks-axi "done" "$task" --file data/backlog.md >/dev/null 2>&1) \
    || fail "could not close the row"
  out=$(run "$home" 20000 check)
  [ -z "$out" ] || fail "a ticket whose row is done was paged: $out"
  pass "an answered ask and a done row are both outside the bound"
}

test_inbox_notes_become_asks_but_automated_notes_do_not() {
  local home out
  home=$(make_home inbox)
  mkdir -p "$home/state/inbox"
  cat > "$home/state/inbox/1790611238-O1gIxh.note" <<'EOF'
id=1790611238-O1gIxh
at=1970-01-12T13:46:40Z
source=voice
--
the credits page copy needs a fix
EOF
  cat > "$home/state/inbox/1790611299-AaBbCc.note" <<'EOF'
id=1790611299-AaBbCc
at=1970-01-12T13:48:19Z
source=procevent
--
procevent: sentry-watch fired (automated, not the captain)
EOF
  run "$home" 1000700 check >/dev/null 2>&1
  out=$(run "$home" 1000700 ledger)
  assert_contains "$out" "the credits page copy needs a fix" "a pending captain note did not become an ask"
  assert_not_contains "$out" "sentry-watch fired" "an automated note became a captain ask"
  assert_contains "$out" "voice" "the ask did not keep the note's source"
  assert_contains "$out" "inbox:1790611238-O1gIxh" "the ask did not keep the note's thread"
  out=$(run "$home" 1000700 ledger)
  assert_contains "$out" "coverage: 1 captain ask(s)" "one note should be exactly one ask, not one per poll"
  pass "pending captain notes become asks with their thread, and automated notes are skipped"
}

test_the_ledger_is_the_generated_view_of_every_ask() {
  local home tr out
  home=$(make_home ledger)
  tr=$(trigger "$home" 1000 "make the ledger the record")
  out=$(run "$home" 1000 ledger)
  assert_contains "$out" "# Captain asks - generated from the intake records and tasks-axi" \
    "the ledger did not say what it is generated from"
  assert_contains "$out" "| Ask | Arrived | Source | Thread |" "the ledger lost its columns"
  assert_contains "$out" "make the ledger the record" "the ledger did not show the ask"
  assert_contains "$out" "no ticket" "the ledger did not report the ask's row state"
  assert_contains "$out" "coverage: 1 captain ask(s), 0 owned, 1 without an owning ticket" \
    "the ledger did not report its coverage"
  run "$home" 1000 close "$tr" --reason "shipped as a direct fix" >/dev/null 2>&1
  out=$(run "$home" 1000 ledger)
  assert_contains "$out" "answered: shipped as a direct fix" "the ledger did not record the answer"
  pass "the ledger is generated from the records and reports coverage and answers"
}

test_arm_status_and_disarm_own_the_watchdog() {
  local home out
  home=$(make_home arming)
  trigger "$home" 1000 "an ask that arms the bound" >/dev/null
  out=$(run "$home" 1000 status)
  assert_contains "$out" "check    armed" "recording an ask did not arm the bound"
  assert_present "$home/state/ticket-intake.check.sh" "the armed shim was not written"
  assert_present "$home/state/ticket-intake.check-trust" "arm bound no trust record"
  out=$(run "$home" 1000 status)
  assert_contains "$out" "0 open ticket(s)" "status did not report the coverage counts"
  out=$(run "$home" 1000 disarm)
  assert_absent "$home/state/ticket-intake.check.sh" "disarm left the shim"
  assert_absent "$home/state/.ticket-intake" "disarm left the findings record"
  out=$(run "$home" 1000 status)
  assert_contains "$out" "not armed" "status still reported the check as armed after disarm"
  pass "recording an ask arms the bound, and status and disarm own it"
}

test_a_multi_line_ask_stays_one_record_and_bad_ids_are_refused() {
  local home tr out
  home=$(make_home sanitize)
  tr=$(printf 'fix it\tplease\nand keep it one line\n' | run "$home" 1000 trigger --source chat --text-file -)
  case "$tr" in
    tr-1000-*) : ;;
    *) fail "a piped trigger was refused: $tr" ;;
  esac
  out=$(run "$home" 1000 ledger)
  assert_contains "$out" "fix it please and keep it one line" "the ask's text was not collapsed onto one line"
  out=$(run "$home" 1000 trigger --source 'not/a/source' "hello")
  assert_contains "$out" "invalid source" "an invalid source was accepted"
  out=$(run "$home" 1000 new "../escape")
  assert_contains "$out" "invalid trigger id" "a path-traversal trigger id was accepted"
  pass "a multi-line ask becomes one record line and unsafe ids are refused"
}

test_an_unreadable_backlog_is_its_own_page() {
  local home out
  home=$(make_home blind)
  mkdir -p "$home/state/intake/tickets"
  printf 'task=orphan-1\ntitle=orphan\nintake_at=1970-01-01T00:00:00Z\nintake_epoch=1000\n' \
    > "$home/state/intake/tickets/orphan-1.ticket"
  out=$(PATH=/usr/bin:/bin run "$home" 2000 check)
  assert_contains "$out" "cannot read row state" "a blind backlog reader was not paged"
  assert_contains "$out" "unavailable" "the page did not name why the bound is blind"
  pass "a backlog state this home cannot read pages instead of silently dropping the bound"
}

test_an_unowned_ask_pages_at_ten_minutes_then_reminds
test_the_owner_clock_pages_at_one_hour_and_first_proof_recovers
test_an_unowned_ticket_pages_from_when_the_captain_asked
test_a_closed_ask_and_a_done_row_are_never_paged
test_inbox_notes_become_asks_but_automated_notes_do_not
test_the_ledger_is_the_generated_view_of_every_ask
test_arm_status_and_disarm_own_the_watchdog
test_a_multi_line_ask_stays_one_record_and_bad_ids_are_refused
test_an_unreadable_backlog_is_its_own_page

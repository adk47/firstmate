#!/usr/bin/env bash
# tests/fm-verif-scale-report.test.sh - the verification scale report must
# refuse rather than default. A source it could not read prints UNMEASURED with
# the reason and the run exits nonzero; it never prints 0 for a source it did
# not read, never counts a reminder or a status note as a proof ask, and never
# counts a hold as a decision. The incident this pins: three wrong ask rates in
# one night, each from counting every sent message, and a goal check that read
# an unread source as 0.
#
# The report's ssh is replaced by a shim that runs the remote command on this
# machine, so the real statements run through the real sqlite3 against a
# fixture ledger; nothing here reaches a network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found"

REPORT="$ROOT/bin/fm-verif-scale-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-verif-scale)

# The shim: ssh's last argument is the remote command. FAKE_SSH_MODE picks what
# the "host" does with it.
FAKE_SSH="$TMP_ROOT/ssh"
cat > "$FAKE_SSH" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SSH_LOG:-/dev/null}"
cmd=${*: -1}
case "${FAKE_SSH_MODE:-run}" in
  run) exec bash -c "$cmd" ;;
  unreachable)
    printf 'ssh: connect to host ledger.invalid port 22: Connection timed out\n' >&2
    exit 255
    ;;
  hang) sleep 30 ;;
esac
SH
chmod +x "$FAKE_SSH"

# A core wrapper that answers the way the real one does: a warning on stderr
# and one quoted CSV row on stdout. FAKE_TRINO_ROW replaces the row.
FAKE_TRINO="$TMP_ROOT/trino-query.sh"
cat > "$FAKE_TRINO" <<'SH'
#!/usr/bin/env bash
printf 'WARNING: Unable to create a system terminal, creating a dumb terminal\n' >&2
printf '%s\n' "${FAKE_TRINO_ROW-\"120\",\"100\",\"2026-11-20 10:00:00\"}"
SH
chmod +x "$FAKE_TRINO"

# make_ledger <path>: the two tables the report reads, in the live column
# shapes, with no rows.
make_ledger() {
  sqlite3 "$1" "
    CREATE TABLE verify_messages (id INTEGER PRIMARY KEY, campaign TEXT, status TEXT, created_at TEXT, sent_at TEXT, proof_tagged_at TEXT, proof_attachments INTEGER);
    CREATE TABLE decisions (id INTEGER PRIMARY KEY, request_id TEXT, decision TEXT, mode TEXT, decided_at TEXT);
  "
}

# msg <ledger> <campaign> <status> <sqlite age modifier> <shape T|space|unsent> [tagged] [attachments]
# 'unsent' leaves sent_at empty, which the live table does on 1,407 sent rows.
msg() {
  local db=$1 campaign=$2 status=$3 age=$4 shape=$5 tagged=${6:-0} attachments=${7:-0} fmt sent tag=NULL
  case "$shape" in
    T) fmt='%Y-%m-%dT%H:%M:%SZ'; sent="strftime('$fmt', 'now', '$age')" ;;
    space) fmt='%Y-%m-%d %H:%M:%S'; sent="strftime('$fmt', 'now', '$age')" ;;
    unsent) fmt='%Y-%m-%dT%H:%M:%SZ'; sent=NULL ;;
  esac
  [ "$tagged" = 0 ] || tag="strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
  sqlite3 "$db" "INSERT INTO verify_messages (campaign, status, created_at, sent_at, proof_tagged_at, proof_attachments) VALUES ('$campaign', '$status', strftime('$fmt', 'now', '$age'), $sent, $tag, $attachments);"
}

# dec <ledger> <request> <decision> <mode> <sqlite age modifier>
dec() {
  sqlite3 "$1" "INSERT INTO decisions (request_id, decision, mode, decided_at) VALUES ('$2', '$3', '$4', strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '$5'));"
}

# A ledger with a known answer for every line of the report. Built once and
# copied, since every row is its own sqlite3 call.
TEMPLATE="$TMP_ROOT/template.sqlite3"
populated_ledger() {  # <path>
  [ -f "$TEMPLATE" ] || build_template "$TEMPLATE"
  cp "$TEMPLATE" "$1"
}

build_template() {  # <path>
  local db=$1
  make_ledger "$db"
  # Proof asks in the last hour: 2 + 1 + 1 = 4, across both timestamp shapes
  # and one row with no sent_at.
  msg "$db" proof-need-ask sent '-10 minutes' T 1
  msg "$db" proof-need-ask sent '-20 minutes' space
  msg "$db" claim-proof-ask sent '-30 minutes' unsent 0 2
  msg "$db" uvn-new-rows sent '-40 minutes' T
  # Older asks: 3 more inside 24 hours, 2 more inside 7 days, 1 outside.
  msg "$db" proof-need-ask sent '-5 hours' T
  msg "$db" proof-need-ask sent '-6 hours' space 1
  msg "$db" uvn-new-rows sent '-7 hours' unsent
  msg "$db" proof-need-ask sent '-3 days' T
  msg "$db" claim-proof-ask sent '-4 days' T
  msg "$db" proof-need-ask sent '-9 days' T 1
  # An ask that was never sent is not an ask sent.
  msg "$db" proof-need-ask deferred '-5 minutes' T
  msg "$db" proof-need-ask rejected '-5 minutes' T
  # Not asks: reminders and status notes, 3 + 2 + 1 = 6 in the last hour.
  msg "$db" uvn-reminder-14 sent '-5 minutes' T
  msg "$db" uvn-reminder-14 sent '-6 minutes' T
  msg "$db" uvn-reminder-30 sent '-7 minutes' space
  msg "$db" uvn-status sent '-8 minutes' T 1
  msg "$db" uvn-status sent '-9 minutes' T
  msg "$db" claim-status sent '-11 minutes' T
  # Neither: listed by name, counted nowhere.
  msg "$db" backlog-reply sent '-12 minutes' T
  msg "$db" backlog-reply sent '-13 minutes' T
  msg "$db" proof-refusal sent '-14 minutes' T
  # Decisions written in the last hour: approve r1, approve_partial r2 twice,
  # support r3 = 4 rows on 3 requests. One more approve inside 24 hours.
  dec "$db" r1 approve apply '-10 minutes'
  dec "$db" r2 approve_partial apply '-11 minutes'
  dec "$db" r2 approve_partial apply '-12 minutes'
  dec "$db" r3 support apply '-13 minutes'
  dec "$db" r4 approve apply '-5 hours'
  # Rows that wrote nothing: 5 holds on one request, a defer, a close, and
  # judge and shadow rows whatever their decision.
  dec "$db" r5 hold apply '-1 minutes'
  dec "$db" r5 hold apply '-2 minutes'
  dec "$db" r5 hold apply '-3 minutes'
  dec "$db" r5 hold apply '-4 minutes'
  dec "$db" r5 hold apply '-5 minutes'
  dec "$db" r6 defer apply '-6 minutes'
  dec "$db" r7 close apply '-7 minutes'
  dec "$db" r8 support judge '-8 minutes'
  dec "$db" r8 approve judge '-9 minutes'
  dec "$db" r9 approve shadow '-10 minutes'
}

# report <ledger> [VAR=value...]: runs the report against the shim with an
# empty config directory. Sets OUT (stdout and stderr together) and RC.
report() {
  local db=$1
  shift
  OUT=$(env -u FM_VERIF_SCALE_JUMP \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    FM_VERIF_SCALE_SSH="$FAKE_SSH" \
    FM_VERIF_SCALE_HOST=ledger.invalid \
    FM_VERIF_SCALE_LEDGER="$db" \
    FM_VERIF_SCALE_TRINO="$FAKE_TRINO" \
    "$@" "$REPORT" 2>&1)
  RC=$?
}

line() {  # <fixed text>: the one output line carrying it
  printf '%s\n' "$OUT" | grep -F -- "$1"
}

# No line may state a count of zero for a source that was not read.
assert_no_number_for() {  # <text naming the source's lines> <label>
  if printf '%s\n' "$OUT" | grep -v '^UNMEASURED: ' | grep -F -- "$1" >/dev/null; then
    fail "$2: a number line was printed for an unread source"$'\n'"$OUT"
  fi
}

test_every_number_is_read_and_carries_its_window_source_and_query() {
  local db="$TMP_ROOT/full.sqlite3" l
  populated_ledger "$db"
  report "$db"
  expect_code 0 "$RC" "a full read"
  assert_not_contains "$OUT" UNMEASURED "a full read prints no UNMEASURED line"
  assert_not_contains "$OUT" INCOMPLETE "a full read is not incomplete"

  l=$(line 'proof asks sent, window last 60 min')
  assert_contains "$l" '= 4 per hour (proof-need-ask=2 claim-proof-ask=1 uvn-new-rows=1;' "asks in the last hour are the three named campaigns only"
  l=$(line 'proof asks sent, window last 24 h')
  assert_contains "$l" '= 7, 0.3 per hour on average (proof-need-ask=4 claim-proof-ask=1 uvn-new-rows=2;' "asks in the last 24 hours"

  l=$(line 'EXCLUDED from the ask line, window last 60 min')
  assert_contains "$l" '= 6 sent (reminders uvn-reminder-*=3, status notes uvn-status=2 claim-status=1)' "reminders and status notes are named as excluded"
  l=$(line 'other campaigns sent')
  assert_contains "$l" '= backlog-reply=2 proof-refusal=1' "every other campaign is listed by name"

  l=$(line 'ask to proof return rate')
  assert_contains "$l" '= 33.33% (3 of 9 proof asks sent in the window carry proof;' "the return rate counts a tag or an attachment, over 7 days of asks"
  assert_contains "$(line 'ask to proof return by send day')" '(newest days still filling)' "the per-day read says its newest days are still filling"

  l=$(line 'decisions written, window last 60 min')
  assert_contains "$l" '= 4 per hour on 3 distinct requests (approve=1 approve_partial=2 support=1;' "decisions are apply-mode approve, approve_partial, and support only"
  l=$(line 'decisions written, window last 24 h')
  assert_contains "$l" '= 5, 0.2 per hour on average on 4 distinct requests (approve=2 approve_partial=2 support=1;' "decisions in the last 24 hours"
  l=$(line 'EXCLUDED from the decision line, window last 60 min')
  assert_contains "$l" '= 10 rows (close=1 defer=1 hold=5 mode-judge=2 mode-shadow=1)' "holds, defers, closes, and other modes are named as excluded"

  l=$(line 'queue depth GROSS')
  assert_contains "$l" 'INCLUDING soft-deleted rows, as of 2026-11-20 10:00:00Z = 120 ' "gross queue depth says it includes soft-deleted rows"
  l=$(line 'queue depth NET')
  assert_contains "$l" 'soft-deleted rows left out, as of 2026-11-20 10:00:00Z = 100 (20 soft-deleted)' "net queue depth says it leaves them out"

  # Every line is a window or a total and names its source and its query.
  while IFS= read -r l; do
    case "$l" in
      'window: '*' | source: '*' | query: SELECT '*) ;;
      'total: '*' | source: '*' | query: SELECT '*) ;;
      *) fail "a line without its window, source, and query: $l" ;;
    esac
  done <<EOF
$OUT
EOF
  [ "$(printf '%s\n' "$OUT" | grep -c '^total: ')" -eq 2 ] || fail "only the two queue lines are totals"$'\n'"$OUT"
  pass "a full read prints every number with its window, source, and query, counting asks and decisions by name"
}

test_an_unreachable_host_is_unmeasured_and_exits_nonzero() {
  local db="$TMP_ROOT/unreachable.sqlite3"
  populated_ledger "$db"
  report "$db" FAKE_SSH_MODE=unreachable
  expect_code 1 "$RC" "an unreachable host"
  assert_contains "$OUT" "UNMEASURED: verify_messages in ledger.invalid:$db - proof asks and return rate (ssh to ledger.invalid failed: ssh: connect to host ledger.invalid port 22: Connection timed out)" "the message ledger is UNMEASURED with the reason"
  assert_contains "$OUT" "UNMEASURED: decisions (the decide ledger) in ledger.invalid:$db - decisions (ssh to ledger.invalid failed:" "the decide ledger is UNMEASURED with the reason"
  assert_contains "$OUT" "UNMEASURED: core credit_requests through ledger.invalid:$FAKE_TRINO - queue depth (ssh to ledger.invalid failed:" "the queue is UNMEASURED with the reason"
  assert_contains "$OUT" 'INCOMPLETE: at least one source is UNMEASURED' "the run says it is incomplete"
  assert_not_contains "$OUT" 'window: ' "no window number is printed for an unread host"
  assert_not_contains "$OUT" 'total: ' "no total is printed for an unread host"
  pass "an unreachable host prints UNMEASURED with the reason for every source and exits nonzero"
}

test_a_missing_table_costs_only_its_own_lines() {
  local db="$TMP_ROOT/no-messages.sqlite3"
  populated_ledger "$db"
  sqlite3 "$db" "DROP TABLE verify_messages;"
  report "$db"
  expect_code 1 "$RC" "a missing table"
  assert_contains "$OUT" "UNMEASURED: verify_messages in ledger.invalid:$db - proof asks and return rate (exit 1: " "the missing table is UNMEASURED"
  assert_contains "$OUT" 'no such table: verify_messages' "the reason is the source's own error"
  assert_no_number_for 'proof asks' "a missing message table"
  assert_no_number_for 'return rate' "a missing message table"
  assert_contains "$(line 'decisions written, window last 60 min')" '= 4 per hour on 3 distinct requests' "the decide ledger is still read"
  assert_contains "$(line 'queue depth NET')" '= 100 ' "the queue is still read"
  assert_contains "$OUT" 'INCOMPLETE: ' "the run says it is incomplete"

  db="$TMP_ROOT/no-decisions.sqlite3"
  populated_ledger "$db"
  sqlite3 "$db" "DROP TABLE decisions;"
  report "$db"
  expect_code 1 "$RC" "a missing decide ledger"
  assert_contains "$OUT" 'no such table: decisions' "the missing decide ledger is UNMEASURED with its error"
  assert_no_number_for 'decisions written' "a missing decide ledger"
  assert_contains "$(line 'proof asks sent, window last 60 min')" '= 4 per hour' "the message ledger is still read"
  pass "a missing table is UNMEASURED with the source's own error, and the other sources are still read"
}

test_a_missing_ledger_file_is_unmeasured() {
  report "$TMP_ROOT/no-such-ledger.sqlite3"
  expect_code 1 "$RC" "a missing ledger file"
  assert_contains "$OUT" 'UNMEASURED: verify_messages in ' "a missing ledger file is UNMEASURED"
  assert_no_number_for 'proof asks' "a missing ledger file"
  assert_no_number_for 'decisions written' "a missing ledger file"
  [ ! -e "$TMP_ROOT/no-such-ledger.sqlite3" ] || fail "the read-only report created a ledger file"
  pass "a missing ledger file is UNMEASURED and the read creates nothing"
}

test_a_source_that_does_not_answer_in_time_is_unmeasured() {
  local db="$TMP_ROOT/hang.sqlite3"
  populated_ledger "$db"
  report "$db" FAKE_SSH_MODE=hang FM_VERIF_SCALE_LEDGER_SECS=1 FM_VERIF_SCALE_CORE_SECS=1
  expect_code 1 "$RC" "a source that does not answer"
  assert_contains "$OUT" '- proof asks and return rate (no answer within 1s)' "a slow message ledger is UNMEASURED"
  assert_contains "$OUT" '- queue depth (no answer within 1s)' "a slow core read is UNMEASURED"
  assert_not_contains "$OUT" 'window: ' "no number is printed for a source that did not answer"
  pass "a source that does not answer inside its bound is UNMEASURED, not waited on forever"
}

test_an_unreadable_core_answer_is_unmeasured() {
  local db="$TMP_ROOT/core.sqlite3" row
  populated_ledger "$db"
  for row in '' 'Query failed: Catalog postgresql_core does not exist' '"120","100"' '"100","120","2026-11-20 10:00:00"' '"","100","2026-11-20 10:00:00"'; do
    report "$db" FAKE_TRINO_ROW="$row"
    expect_code 1 "$RC" "core answering '$row'"
    assert_contains "$OUT" "UNMEASURED: core credit_requests through ledger.invalid:$FAKE_TRINO - queue depth (" "core answering '$row' is UNMEASURED"
    assert_no_number_for 'queue depth' "core answering '$row'"
    assert_contains "$(line 'proof asks sent, window last 60 min')" '= 4 per hour' "the ledger lines still print when core answers '$row'"
  done

  report "$db" FM_VERIF_SCALE_TRINO="$TMP_ROOT/no-such-wrapper.sh"
  expect_code 1 "$RC" "a missing core wrapper"
  assert_contains "$OUT" '- queue depth (exit 127: ' "a missing core wrapper is UNMEASURED with its exit status"
  pass "a core read that fails, is empty, is short, or puts net above gross is UNMEASURED"
}

test_a_rate_over_zero_asks_is_unmeasured_not_zero_percent() {
  local db="$TMP_ROOT/no-asks.sqlite3"
  make_ledger "$db"
  msg "$db" uvn-status sent '-5 minutes' T 1
  msg "$db" proof-need-ask sent '-9 days' T 1
  dec "$db" r1 hold apply '-5 minutes'
  report "$db"
  expect_code 1 "$RC" "a week with no asks"
  # The counts were read, and they are zero: that is a measurement.
  assert_contains "$(line 'proof asks sent, window last 60 min')" '= 0 per hour (proof-need-ask=0 claim-proof-ask=0 uvn-new-rows=0;' "a read count of zero asks is printed as read"
  assert_contains "$(line 'decisions written, window last 60 min')" '= 0 per hour on 0 distinct requests' "a read count of zero decisions is printed as read"
  assert_contains "$(line 'EXCLUDED from the decision line, window last 60 min')" '= 1 rows (hold=1)' "the hold is named, not counted"
  # The rate has no denominator, so it is not a number.
  assert_contains "$OUT" '- return rate (no proof ask was sent in the 7 days to ' "a rate over zero asks is UNMEASURED"
  assert_no_number_for 'return rate' "a week with no asks"
  pass "a return rate with no asks behind it is UNMEASURED, while a count that was read as zero is printed"
}

test_a_timestamp_in_an_unknown_shape_is_unmeasured() {
  local db="$TMP_ROOT/shape.sqlite3"
  populated_ledger "$db"
  sqlite3 "$db" "INSERT INTO verify_messages (campaign, status, created_at, sent_at) VALUES ('proof-need-ask', 'sent', '1795170000', '1795170000');"
  report "$db"
  expect_code 1 "$RC" "a sent row in an unknown timestamp shape"
  assert_contains "$OUT" '- proof asks and return rate (1 sent rows carry a timestamp in neither known shape' "an unplaceable sent row makes the source UNMEASURED"
  assert_no_number_for 'proof asks' "an unplaceable sent row"

  db="$TMP_ROOT/dec-shape.sqlite3"
  populated_ledger "$db"
  sqlite3 "$db" "INSERT INTO decisions (request_id, decision, mode, decided_at) VALUES ('r1', 'approve', 'apply', strftime('%Y-%m-%d %H:%M:%S', 'now'));"
  report "$db"
  expect_code 1 "$RC" "a decision in an unknown timestamp shape"
  assert_contains "$OUT" '- decisions (1 recent rows carry a decided_at this report cannot place in a window)' "an unplaceable decision makes the source UNMEASURED"
  assert_no_number_for 'decisions written' "an unplaceable decision"
  pass "a row whose time cannot be placed in a window makes its source UNMEASURED rather than silently missed"
}

test_no_host_is_unmeasured_never_a_built_in_guess() {
  : > "$TMP_ROOT/nohost.calls"
  OUT=$(env -u FM_VERIF_SCALE_HOST -u FM_VERIF_SCALE_JUMP FM_CONFIG_OVERRIDE="$TMP_ROOT/no-config" \
    FM_VERIF_SCALE_SSH="$FAKE_SSH" FAKE_SSH_LOG="$TMP_ROOT/nohost.calls" "$REPORT" 2>&1)
  RC=$?
  expect_code 1 "$RC" "no host configured"
  assert_contains "$OUT" 'UNMEASURED: ledger host (no host configured: set FM_VERIF_SCALE_HOST' "no host is UNMEASURED and says what to set"
  [ ! -s "$TMP_ROOT/nohost.calls" ] || fail "the report reached for a host nobody configured"
  pass "with no host configured the report is UNMEASURED and reaches nowhere"
}

test_the_config_file_supplies_the_host_and_the_environment_wins() {
  local db="$TMP_ROOT/config.sqlite3" cfg="$TMP_ROOT/config"
  populated_ledger "$db"
  mkdir -p "$cfg"
  {
    printf '# the ledger host\n'
    printf 'FM_VERIF_SCALE_HOST=from-file.invalid  \n'
    printf 'FM_VERIF_SCALE_JUMP=jump.invalid\n'
    printf 'FM_VERIF_SCALE_LEDGER=%s\n' "$db"
    printf 'FM_VERIF_SCALE_TRINO=%s\n' "$FAKE_TRINO"
  } > "$cfg/verif-scale.env"
  : > "$TMP_ROOT/config.calls"
  OUT=$(env -u FM_VERIF_SCALE_HOST -u FM_VERIF_SCALE_JUMP -u FM_VERIF_SCALE_LEDGER -u FM_VERIF_SCALE_TRINO \
    FM_CONFIG_OVERRIDE="$cfg" FM_VERIF_SCALE_SSH="$FAKE_SSH" FAKE_SSH_LOG="$TMP_ROOT/config.calls" "$REPORT" 2>&1)
  RC=$?
  expect_code 0 "$RC" "a host from the config file"
  assert_contains "$OUT" "source: verify_messages in from-file.invalid:$db" "the file's host and ledger are the ones read"
  assert_grep '-J jump.invalid from-file.invalid ' "$TMP_ROOT/config.calls" "the file's jump host is used"
  assert_grep '-o BatchMode=yes' "$TMP_ROOT/config.calls" "the read never waits on a password prompt"

  OUT=$(env -u FM_VERIF_SCALE_JUMP -u FM_VERIF_SCALE_LEDGER -u FM_VERIF_SCALE_TRINO \
    FM_VERIF_SCALE_HOST=from-env.invalid \
    FM_CONFIG_OVERRIDE="$cfg" FM_VERIF_SCALE_SSH="$FAKE_SSH" "$REPORT" 2>&1)
  RC=$?
  expect_code 0 "$RC" "a host from the environment"
  assert_contains "$OUT" "source: verify_messages in from-env.invalid:$db" "a set environment variable wins over the file"
  pass "the config file supplies the host, the jump host, and the paths, and the environment wins over it"
}

test_help_and_usage_errors() {
  OUT=$("$REPORT" --help 2>&1)
  RC=$?
  expect_code 0 "$RC" "--help"
  assert_contains "$OUT" 'UNMEASURED: <source> (<reason>)' "--help states the refusal contract"
  assert_contains "$OUT" 'FM_VERIF_SCALE_HOST' "--help names the host setting"
  OUT=$("$REPORT" --bogus 2>&1)
  RC=$?
  expect_code 2 "$RC" "an unknown argument"
  assert_contains "$OUT" 'unknown argument: --bogus' "an unknown argument is named"
  pass "--help prints the contract and an unknown argument is a usage error"
}

test_every_number_is_read_and_carries_its_window_source_and_query
test_an_unreachable_host_is_unmeasured_and_exits_nonzero
test_a_missing_table_costs_only_its_own_lines
test_a_missing_ledger_file_is_unmeasured
test_a_source_that_does_not_answer_in_time_is_unmeasured
test_an_unreadable_core_answer_is_unmeasured
test_a_rate_over_zero_asks_is_unmeasured_not_zero_percent
test_a_timestamp_in_an_unknown_shape_is_unmeasured
test_no_host_is_unmeasured_never_a_built_in_guess
test_the_config_file_supplies_the_host_and_the_environment_wins
test_help_and_usage_errors

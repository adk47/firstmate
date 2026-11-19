#!/usr/bin/env bash
# tests/fm-inbox-wake-ack.test.sh - the note/wake acknowledgement join.
#
# The 2026-11 measurement behind this suite: bin/fm-wake-drain.sh never touched
# state/inbox/*.note, and --ack-through only advanced the queue cursor, so a wake
# could be acknowledged while its note was never acked. Three captain notes sat
# 23h+ - a Fable recovery plan, an orchestration review, a proof-only request -
# while fresh notes were handled in the same minute. These cases pin the join
# that ends it, in both directions:
#   1. `fm-inbox.sh drain --ack <id>` retires the note AND the `check: inbox:<id>`
#      wake that announced it, so one command clears both records of the one
#      obligation.
#   2. `fm-wake-drain.sh --ack-through` refuses (exit 3, naming the note id) while
#      a captain note at or below its cutoff is still unacknowledged, and writes
#      nothing - no row consumed, no receipt recorded.
#   3. After the note is acked, the same acknowledgement succeeds.
#   4. There is no override: an extra acknowledgement argument is rejected, because
#      an override on a fail-safe is a fail-open.
#   5. state/inbox-auto is NOT coupled: it is a bounded log of machine records the
#      captain never wrote, so refusing there would block routine acknowledgement.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

INBOX="$ROOT/bin/fm-inbox.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-wake-ack)

HOME_DIR=
STATE=
ERR=

setup() {  # <case-name>
  HOME_DIR=$(make_case "$1")
  STATE="$HOME_DIR/state"
  ERR="$HOME_DIR/drain.err"
}

inbox() {  # <args...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$INBOX" "$@"
}

drain() {  # <args...>
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$DRAIN" "$@"
}

# Present the queue and hand back the acknowledgement the drain printed, exactly
# as firstmate would run it.
requirement() {  # -> "sequence generation"
  local sequence generation
  : > "$ERR"
  drain > /dev/null 2> "$ERR" || fail "the presenting drain failed: $(cat "$ERR")"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$ERR" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$ERR" | tail -1)
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the drain printed no acknowledgement requirement: $(cat "$ERR")"
  printf '%s %s\n' "$sequence" "$generation"
}

note_ids() {  # <dir> -> the staged record ids, one per line
  local f
  for f in "$1"/*.note; do
    [ -e "$f" ] || break
    basename "$f" .note
  done
}

pending_rows() {  # -> the queued row count
  if [ -s "$STATE/.wake-queue" ]; then awk 'END { print NR }' "$STATE/.wake-queue"; else printf '0\n'; fi
}

# --- 1. acking a note retires its wake -------------------------------------

setup one-command-clears-both
inbox note "read the recovery plan before the lease work" > /dev/null \
  || fail "the captain note should queue"
id=$(note_ids "$STATE/inbox")
[ -n "$id" ] || fail "the captain note was not staged"
assert_grep "check: captain inbox note $id" "$STATE/.wake-queue" \
  "the note should announce itself with its own id in the payload"

read -r seq gen <<EOF
$(requirement)
EOF

out=$(inbox drain --ack "$id") || fail "acking the note failed: $out"
assert_contains "$out" "acked $id" "acking should report the note it retired"
assert_contains "$out" "retired 1 wake(s) for $id" \
  "acking a note should retire the wake that announced it"
assert_present "$STATE/inbox/handled/$id.note" \
  "the acknowledged note belongs in handled/"
assert_absent "$STATE/inbox/$id.note" "the acknowledged note should leave the queue"
[ "$(pending_rows)" = 0 ] \
  || fail "acking the note should leave no wake behind: $(cat "$STATE/.wake-queue")"

set +e
drain --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 0 ] || fail "the acknowledgement should succeed once the note is acked: $(cat "$ERR")"
[ "$(pending_rows)" = 0 ] || fail "the acknowledgement should find nothing left to consume"
pass "drain --ack retires the note and the wake that announced it, so one command clears both"

# --- 1b. a note whose wake is already gone is reported, not silent --------

setup wake-already-gone
inbox note "its wake was acknowledged before the note" > /dev/null \
  || fail "the captain note should queue"
id=$(note_ids "$STATE/inbox")
# The wake went away first (an older acknowledgement, or an operator clearing the
# queue by hand). The note is then the only surviving record, which is exactly the
# state that hid for 23h, so acking it says so instead of printing a zero count.
awk -F '\t' 'NF < 5 || $4 != "inbox:'"$id"'" { print }' "$STATE/.wake-queue" > "$STATE/.wake-queue.trim" \
  && mv "$STATE/.wake-queue.trim" "$STATE/.wake-queue"
[ "$(pending_rows)" = 0 ] || fail "the fixture should start with no queued wake"
out=$(inbox drain --ack "$id") || fail "acking the note failed: $out"
assert_contains "$out" "acked $id" "acking should still report the note it retired"
assert_not_contains "$out" "retired 0 wake(s)" \
  "acking a note whose wake is already gone must not report a zero retirement"
assert_contains "$out" "no wake was still queued" \
  "acking an orphaned note should say its wake was already gone, so the state is visible"
pass "acking a note whose wake is already gone reports the surviving note instead of a zero count"

# --- 2. an unacked note blocks the acknowledgement, and writes nothing -----

setup refusal
inbox note "three notes sat 23h+ for want of this join" > /dev/null \
  || fail "the captain note should queue"
id=$(note_ids "$STATE/inbox")
# This is the exact shape Aaron named: a source=text captain note whose wake is
# bare-acknowledged. The guard must refuse it, and reverting the guard turns this
# case red.
assert_grep 'source=text' "$STATE/inbox/$id.note" \
  "the fixture must be a source=text captain note, filed in state/inbox/"
append_wake "$STATE" signal unrelated-task 'signal: unrelated-task status changed' \
  || fail "the unrelated wake should queue"
[ "$(pending_rows)" = 2 ] || fail "the fixture should hold the note wake and one other row"

read -r seq gen <<EOF
$(requirement)
EOF
[ "$(pending_rows)" = 2 ] || fail "presenting the queue must not consume a row"

set +e
drain --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 3 ] || fail "an acknowledgement over an unacked captain note should refuse, got exit $code: $(cat "$ERR")"
assert_contains "$(cat "$ERR")" "NOT acknowledged through $seq" \
  "the refusal should say nothing was acknowledged"
assert_contains "$(cat "$ERR")" "$id" "the refusal should name the note it is waiting on"
assert_contains "$(cat "$ERR")" "bin/fm-inbox.sh drain --ack" \
  "the refusal should name the one command that clears both"

[ "$(pending_rows)" = 2 ] \
  || fail "a refused acknowledgement must consume no row: $(cat "$STATE/.wake-queue")"
assert_grep "check: captain inbox note $id" "$STATE/.wake-queue" \
  "a refused acknowledgement must leave the note wake queued"
assert_present "$STATE/inbox/$id.note" \
  "a refused acknowledgement must leave the note waiting"
pass "a bare acknowledgement is refused while a source=text captain note is unacked"

# --- 3. the same acknowledgement succeeds once the note is acked ----------

inbox drain --ack "$id" > /dev/null || fail "acking the note failed"
set +e
drain --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 0 ] || fail "the acknowledgement should succeed after the note is acked: $(cat "$ERR")"
[ "$(pending_rows)" = 0 ] \
  || fail "the acknowledgement should consume every row through $seq: $(cat "$STATE/.wake-queue")"
pass "acknowledging the note unblocks the wake acknowledgement that named it"

# --- 4. the refusal has no override: an override is a fail-open -----------

setup no-override
inbox note "there is no way round this on purpose" > /dev/null || fail "the captain note should queue"
id=$(note_ids "$STATE/inbox")
read -r seq gen <<EOF
$(requirement)
EOF

set +e
drain --ack-through "$seq" --recovery-generation "$gen" --allow-unacked-notes \
  > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 2 ] \
  || fail "an override argument must be refused outright, got exit $code: $(cat "$ERR")"
assert_contains "$(cat "$ERR")" "unexpected acknowledgement arguments" \
  "the refusal should name the rejected argument path"
[ "$(pending_rows)" = 1 ] || fail "a rejected argument must consume nothing"
assert_present "$STATE/inbox/$id.note" "a rejected argument must leave the note waiting"

set +e
drain --ack-through 0 --recovery-generation "$gen" --allow-bogus > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 2 ] || fail "an unknown acknowledgement argument should refuse, got exit $code"
pass "the refusal has no override: an extra acknowledgement argument is rejected, not honoured"

# --- 5. the automated queue is a log, not the captain's queue --------------

setup automated
inbox note --source ci "ci poll 4 failed" > /dev/null || fail "the automated note should queue"
auto_id=$(note_ids "$STATE/inbox-auto")
[ -n "$auto_id" ] || fail "the automated note was not staged"
read -r seq gen <<EOF
$(requirement)
EOF

set +e
drain --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2> "$ERR"
code=$?
set -e
[ "$code" -eq 0 ] \
  || fail "an automated record must never block a routine acknowledgement: $(cat "$ERR")"
[ "$(pending_rows)" = 0 ] || fail "the automated wake row should be consumed"
assert_present "$STATE/inbox-auto/$auto_id.note" \
  "acknowledging the wake is not acknowledging the automated record"
pass "state/inbox-auto records never block an acknowledgement"

printf 'all fm-inbox wake-ack cases passed\n'

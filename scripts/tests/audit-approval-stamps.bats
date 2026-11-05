#!/usr/bin/env bats
# Tests for scripts/audit-approval-stamps.sh: the watchdog that answers "was every customer note we
# sent authorized by an approval we can name?" from the verify ledger alone.
#
# Captain, 2026-11-03: "users aren't in the dark ... no human reviews is the goal". The gate accepts a
# Fable ruling id for template classes a ruling pre-approved, and stamps every claim with
# approver_kind + approval_id + the template identity hash. This suite pins the watchdog that makes the
# stamp load-bearing:
#   - a clean ledger exits 0 and says so;
#   - a send with no usable stamp pages, ONCE per ledger row (a standing finding keeps the exit code red
#     but stops re-paging: re-paging immutable evidence trains people to mute the channel);
#   - "I could not check" is never reported as clean (unreadable registry / unreadable ledger exit 2 and
#     page);
#   - rows from before the stamp shipped are history, not findings.
#
# Hermetic: a throwaway sqlite ledger built with the real helper's schema, the repo registry, a temp state
# file, and muso stubs (the tests that must PAGE use the logging ok stub; the preview tests use --dry-run).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
AUDIT="$HYDRA_REPO/scripts/audit-approval-stamps.sh"
HELPER="$HYDRA_REPO/scripts/credit_review/verify_ledger.py"
REGISTRY="$HYDRA_REPO/policies/fable-rulings.json"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  # the ok stub LOGS its argv: a live page's text goes to Slack, not stdout, so the test greps the call itself
  printf '#!/bin/sh\necho "$@" >> "%s"\nexit 0\n' "$TEST_TMPDIR/muso-ok.log" > "$TEST_TMPDIR/muso-ok"; chmod +x "$TEST_TMPDIR/muso-ok"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/muso-fail"; chmod +x "$TEST_TMPDIR/muso-fail"
  export APPROVAL_AUDIT_LEDGER="$TEST_TMPDIR/ledger.sqlite3"
  export APPROVAL_AUDIT_HELPER="$HELPER"
  export APPROVAL_AUDIT_REGISTRY="$REGISTRY"
  export APPROVAL_AUDIT_STATE_FILE="$TEST_TMPDIR/seen.json"
  python3 -I "$HELPER" --db "$APPROVAL_AUDIT_LEDGER" migrate >/dev/null
}

row() { # row <status> <day> <approver_kind|-> <approval_id|-> <template|-> <copy_ref> <approved_by>
  python3 - "$APPROVAL_AUDIT_LEDGER" "$@" <<'PY'
import json, sqlite3, sys
path, status, day, kind, aid, sha, copy_ref, approved_by = sys.argv[1:9]
db = sqlite3.connect(path)
db.execute(
    "INSERT INTO verify_messages (campaign, kind, user_key, day, status, message_type, request_ids_json, n_credits,"
    " approved_by, approval_ref, copy_ref, approver_kind, approval_id, template_sha256, created_at, updated_at)"
    " VALUES ('reply-ref','initial','fan@example.com',? ,?,'comment',?,1,?,'ref',?,?,?,?,'2026-11-04T10:00:00Z',"
    " '2026-11-04T10:00:00Z')",
    (day, status, json.dumps(["req-1"]), approved_by, copy_ref,
     None if kind == "-" else kind, None if aid == "-" else aid, None if sha == "-" else sha))
db.commit()
PY
}

# The stamp's template hash is RECOMPUTED by the auditor (QA 2026-11-04 finding 2), so the fixtures carry the real
# identity digest for reply-ref/initial/refv rather than a placeholder.
TEMPLATE_SHA="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); from credit_review.verify_ledger import template_identity_sha256 as t; print(t(campaign="reply-ref", kind="initial", copy_ref="refv"))' "$HYDRA_REPO/scripts")"
CAPTAIN_ROW() { row sent 2026-11-04 captain-slack U7RP6HKUZ "$TEMPLATE_SHA" refv U7RP6HKUZ; }
RULED_ROW()   { row sent 2026-11-04 fable-ruling fable-ruling-1103-103 "$TEMPLATE_SHA" refv fable-ruling-1103-103; }

audit() { run "$AUDIT" --since 2026-11-04 --dry-run; }

@test "a clean ledger exits 0 and says what it checked" {
  CAPTAIN_ROW; RULED_ROW
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: 2 send(s) since 2026-11-04 carry a valid approval stamp"* ]]
}

@test "a send with no usable stamp pages once, naming the row and the reason, and keeps the exit code red" {
  CAPTAIN_ROW
  row sent 2026-11-04 - - - refv caroline-ref-picker     # an agent identity, unstamped
  # a LIVE run with a working Slack stub: the page lands, so the watermark records it (a dry run must not, see below)
  MUSO_BIN="$TEST_TMPDIR/muso-ok" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token run "$AUDIT" --since 2026-11-04
  [ "$status" -eq 1 ]
  [[ "$output" == *"paged 1 new finding(s); 1 total"* ]]
  # the page that was actually handed to Slack names the row and the reason
  grep -q 'customer note(s) without a valid approval stamp' "$TEST_TMPDIR/muso-ok.log"
  grep -q 'no approver stamp' "$TEST_TMPDIR/muso-ok.log"
  grep -q 'ledger #2' "$TEST_TMPDIR/muso-ok.log"
  # the watermark now holds that row, so the next tick is a standing problem, not a fresh page
  grep -q '"2"' "$APPROVAL_AUDIT_STATE_FILE"
  MUSO_BIN="$TEST_TMPDIR/muso-ok" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token run "$AUDIT" --since 2026-11-04
  [ "$status" -eq 1 ]
  [[ "$output" == *"standing: 1 finding(s) already paged"* ]]
  [[ "$output" != *"customer note(s) without a valid approval stamp"* ]]
}

@test "a --dry-run preview does not consume the watermark, so the live timer still pages it (QA 2026-11-04 round 4 finding 3)" {
  row sent 2026-11-04 - - - refv caroline-ref-picker
  # the preview: prints the page instead of posting it
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"customer note(s) without a valid approval stamp"* ]]
  [[ "$output" == *"dry run: would page 1 new finding(s) (watermark NOT advanced)"* ]]
  # nothing was recorded - an operator looking before a deploy must not silence the alert he was looking at
  [ ! -s "$APPROVAL_AUDIT_STATE_FILE" ]
  # the live run then pages the same row and only then records it
  MUSO_BIN="$TEST_TMPDIR/muso-ok" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token run "$AUDIT" --since 2026-11-04
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 new finding(s)"* ]]
  grep -q '"1"' "$APPROVAL_AUDIT_STATE_FILE"
}

@test "a page that does not reach Slack is NOT recorded as paged, and the next run retries the row (QA finding 3)" {
  row sent 2026-11-04 - - - refv caroline-ref-picker
  # A page that silently failed used to advance the watermark: the unauthorized note would then never be reported again.
  MUSO_BIN="$TEST_TMPDIR/muso-fail" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token run "$AUDIT" --since 2026-11-04
  [ "$status" -eq 2 ]
  [[ "$output" == *"did NOT reach Slack"* ]]
  [ ! -s "$APPROVAL_AUDIT_STATE_FILE" ] || ! grep -q '"1"' "$APPROVAL_AUDIT_STATE_FILE"
  # a working Slack on the next run pages the same row, and only then is it recorded
  MUSO_BIN="$TEST_TMPDIR/muso-ok" MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token run "$AUDIT" --since 2026-11-04
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 new finding(s)"* ]]
  grep -q '"1"' "$APPROVAL_AUDIT_STATE_FILE"
}

@test "a ruling id whose class does not cover this copy is a finding, not a send under a real ruling" {
  row sent 2026-11-04 fable-ruling fable-ruling-1103-103 "$(printf 'c%.0s' {1..64})" docrecvn fable-ruling-1103-103
  audit
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not pre-approve copy 'docrecvn'"* ]]
}

@test "rows from before the stamp shipped are history, not findings" {
  row sent 2026-11-02 - - - refv U7RP6HKUZ
  audit
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: 0 send(s)"* ]]
}

@test "an unreadable registry is reported as CANNOT CHECK (exit 2), never as clean" {
  RULED_ROW
  export APPROVAL_AUDIT_REGISTRY="$TEST_TMPDIR/absent.json"
  audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot run"* ]]
  [[ "$output" == *"not readable"* ]]
}

@test "an unreadable ledger is reported as CANNOT CHECK (exit 2), never as clean" {
  printf 'not a database\n' > "$APPROVAL_AUDIT_LEDGER"
  audit
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not run"* ]]
}

@test "a bad flag or a malformed --since is a usage error, not an audit result" {
  run "$AUDIT" --since 2026-13
  [ "$status" -eq 2 ]
  run "$AUDIT" --nope
  [ "$status" -eq 2 ]
}

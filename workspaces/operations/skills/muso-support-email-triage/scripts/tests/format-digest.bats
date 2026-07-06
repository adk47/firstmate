#!/usr/bin/env bats
# format-digest.sh — the deterministic Phase 3 join/count/emit step of the
# muso-support-email-triage skill. Hermetic: it only needs python3 + a $WORKDIR
# holding emails.json (fetch, authoritative) and verdicts.json (LLM-authored).
# No openclaw/muso/network, so no PATH stubbing is required.
#
# The contract under test:
#   - 0 threads              -> prints exactly NO_REPLY (cron stays silent).
#   - verdict ∈ {caroline, human, spam}; anything else fails loud.
#   - spam/no-action NEVER counts toward Caroline-can-handle (Nick's complaint:
#     a fuel-card promo must not inflate her win count).
#   - the spam segment is shown in the header only when n_spam > 0.
#   - reconciliation is fail-loud (Rule 13): a bad/missing/unreconcilable verdict
#     exits non-zero rather than shipping a fabricated digest.

SCRIPT="${BATS_TEST_DIRNAME}/../format-digest.sh"

setup() {
  WORKDIR="$(mktemp -d)"
  export WORKDIR
}
teardown() {
  # format-digest.sh scrubs $WORKDIR on the success path; clean up the rest.
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
}

emails() { printf '%s' "$1" > "$WORKDIR/emails.json"; }
verdicts() { printf '%s' "$1" > "$WORKDIR/verdicts.json"; }

@test "empty inbox prints exactly NO_REPLY and exits 0" {
  emails '[]'
  verdicts '[]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "NO_REPLY" ]
}

@test "three-verdict digest: header counts each bucket and spam is separated out" {
  emails '[
    {"threadId":"t1","subject":"verify my credits","url":"https://mail/t1"},
    {"threadId":"t2","subject":"Save 10p per litre on fuel with POWK","url":"https://mail/t2"},
    {"threadId":"t3","subject":"chain of title","url":"https://mail/t3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"credits pending","reason":"customer-credit-verification"},
    {"threadId":"t2","verdict":"spam","description":"fuel-card promo","reason":"promotional / not a customer"},
    {"threadId":"t3","verdict":"human","description":"legal inquiry","reason":"legal / rights"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  first_line="${lines[0]}"
  [[ "$first_line" == *"3 new"* ]]
  [[ "$first_line" == *"1 Caroline-can-handle"* ]]
  [[ "$first_line" == *"1 need a human"* ]]
  [[ "$first_line" == *"1 spam/no-action"* ]]
}

@test "spam is NOT counted as Caroline-can-handle (the fuel-card regression)" {
  # Two spam threads, one real Caroline thread. Caroline count MUST be 1, not 3.
  emails '[
    {"threadId":"t1","subject":"real question","url":"u1"},
    {"threadId":"t2","subject":"promo A","url":"u2"},
    {"threadId":"t3","subject":"promo B","url":"u3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"how do I claim","reason":"KB: faq"},
    {"threadId":"t2","verdict":"spam","description":"promo","reason":"marketing"},
    {"threadId":"t3","verdict":"spam","description":"promo","reason":"marketing"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"1 Caroline-can-handle"* ]]
  [[ "${lines[0]}" == *"2 spam/no-action"* ]]
  # And the spam bullets carry the spam tag, not the Caroline tag.
  [[ "$output" == *":wastebasket: spam/no-action"* ]]
}

@test "no spam segment in the header when nothing is spam" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"KB: faq"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"spam/no-action"* ]]
  [[ "${lines[0]}" == *"1 Caroline-can-handle"* ]]
  [[ "${lines[0]}" == *"0 need a human"* ]]
}

@test "each verdict renders its own tag" {
  emails '[
    {"threadId":"t1","subject":"a","url":"u1"},
    {"threadId":"t2","subject":"b","url":"u2"},
    {"threadId":"t3","subject":"c","url":"u3"}
  ]'
  verdicts '[
    {"threadId":"t1","verdict":"caroline","description":"d","reason":"r"},
    {"threadId":"t2","verdict":"human","description":"d","reason":"r"},
    {"threadId":"t3","verdict":"spam","description":"d","reason":"r"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *":white_check_mark: Caroline-can-handle"* ]]
  [[ "$output" == *":raising_hand: needs a human"* ]]
  [[ "$output" == *":wastebasket: spam/no-action"* ]]
}

@test "an invalid verdict fails loud (does not ship a partial digest)" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"junk","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid verdict"* ]]
  [[ "$output" == *"caroline|human|spam"* ]]
}

@test "a verdict for an unknown threadId fails loud (no fabricated rows)" {
  emails '[{"threadId":"t1","subject":"s","url":"u1"}]'
  verdicts '[{"threadId":"t9","verdict":"caroline","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in emails.json"* ]]
}

@test "a thread with no verdict fails loud" {
  emails '[
    {"threadId":"t1","subject":"a","url":"u1"},
    {"threadId":"t2","subject":"b","url":"u2"}
  ]'
  verdicts '[{"threadId":"t1","verdict":"caroline","description":"d","reason":"r"}]'
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no verdict"* ]]
}

@test "em-dashes in description/reason are normalized to hyphens" {
  emails '[{"threadId":"t1","subject":"sub—ject","url":"u1"}]'
  verdicts '[{"threadId":"t1","verdict":"spam","description":"promo — ignore","reason":"marketing — cold"}]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"—"* ]]
  [[ "$output" != *"–"* ]]
}

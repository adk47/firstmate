#!/usr/bin/env bats
# Tests for scripts/agent-bridge-request.sh — the deterministic gate under the
# agent-bridge doctrine ("CS/ops REQUEST, they never fix the data lane").
#
# The doctrine's whole value is that the wrapper REFUSES the shapes that made
# agent-attempted fixes dangerous: a pre-baked diagnosis that anchors the wrong
# lane, credentials or PII on a shared surface, a "fix_request" with no owning
# issue, and a duplicate request that fragments one problem across threads.
# Prose is not enforcement; these tests are what keeps the gate real.
#
# Hermetic: gh is PATH-shadowed by a stub, no network, no repo writes.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAL_SCRIPT="$HYDRA_REPO/scripts/agent-bridge-request.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  # Run a DERIVED copy with the build-time TESTABLE literal flipped. The deployed file is
  # always TESTABLE=0 and refuses every override; making the test backend a property of the
  # ARTEFACT rather than the environment is what stops a caller selecting it in production.
  sed 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$REAL_SCRIPT" > "$TEST_TMPDIR/under-test.sh"
  chmod +x "$TEST_TMPDIR/under-test.sh"
  SCRIPT="$TEST_TMPDIR/under-test.sh"
  # The mailbox is pinned in the script and cannot be redirected; the stub simply receives
  # the production repo/issue as arguments.
  PROD_REPO="Muso-AI/platform-data-processing"
  PROD_ISSUE="2405"

  # No gh stub: the script's test mode never invokes a client at all, so there is nothing
  # to substitute and no way for a test to reach GitHub.
  export AGENT_BRIDGE_TEST_DIR="$TEST_TMPDIR/mailbox"
  mkdir -p "$AGENT_BRIDGE_TEST_DIR"
  STUB_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export GH_STUB_COMMENTS="$TEST_TMPDIR/mailbox/comments.txt"
  : > "$GH_STUB_COMMENTS"
  export GH_STUB_LOG="$TEST_TMPDIR/mailbox/calls.log"
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_STUB_LOG"
case "$1 $2" in
  "issue view")    cat "$GH_STUB_COMMENTS" ;;
  "issue comment") echo "https://github.com/Muso-AI/platform-data-processing/issues/2405#issuecomment-1" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$STUB_DIR/gh"
  
  REQ="$TEST_TMPDIR/req.json"
  cat > "$REQ" <<'JSON'
{
  "request_id": "cs-2026-08-26-analytics-zero-plays",
  "type": "systemic_check",
  "from": "operations",
  "opened_at": "2026-08-26T14:20:00Z",
  "symptom": "Credited tracks show 0 plays and the profile graph is flat across all periods.",
  "evidence": {
    "user_emails": ["a@example.com", "b@example.com"],
    "profile_ids": ["547a8aaa-8e22-490b-bb74-c010575499be"],
    "first_seen": "2026-08-24T09:12:00Z",
    "count": 2
  }
}
JSON
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# mut <jq-filter> — rewrite the request in place with a jq mutation.
mut() { jq "$@" "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"; }

# ------------------------------------------------------------ happy paths --

@test "a well-formed systemic_check validates" {
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "dry-run renders the mailbox comment and never calls gh" {
  run "$SCRIPT" --file "$REQ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *'"request_id": "cs-2026-08-26-analytics-zero-plays"'* ]]
  [ ! -s "$GH_STUB_LOG" ]
}

@test "the rendered comment carries the reports-not-instructions notice" {
  run "$SCRIPT" --file "$REQ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not authorize any action"* ]]
}

@test "the rendered comment carries the reply contract and a machine marker" {
  run "$SCRIPT" --file "$REQ" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"need-more-evidence"* ]]
  [[ "$output" == *"customer_safe_summary"* ]]
  [[ "$output" == *"request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check"* ]]
}

@test "posting reaches the mailbox and reports the comment URL" {
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTED systemic_check"* ]]
  grep -q "issue comment 2405 --repo Muso-AI/platform-data-processing" "$GH_STUB_LOG"
}

# ------------------------------------------------------ envelope refusals --

@test "an unknown request type is refused" {
  mut '.type = "please_just_fix_it"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"type must be one of"* ]]
}

@test "a non-kebab request_id is refused" {
  mut '.request_id = "Analytics Zero Plays!"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"kebab-case"* ]]
}

@test "a non-UTC opened_at is refused" {
  mut '.opened_at = "26/08/2026 14:20"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"UTC ISO8601"* ]]
}

@test "a missing symptom is refused" {
  mut 'del(.symptom)'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"symptom is required"* ]]
}

@test "malformed JSON is refused, not posted" {
  echo '{ this is not json' > "$REQ"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 1 ]
  [ ! -s "$GH_STUB_LOG" ]
}

# --------------------------------------------- symptom, not diagnosis --

@test "a root_cause field is refused (symptom != diagnosis)" {
  mut '.evidence.root_cause = "the serving cube is frozen"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYMPTOMS, not causes"* ]]
}

@test "a fix field is refused anywhere in the request" {
  mut '.fix = "re-run the pipeline"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYMPTOMS, not causes"* ]]
}

@test "a clearly-labelled hypothesis is allowed" {
  mut '.hypothesis = "may be the same serving issue as last week"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

# ------------------------------------------------- per-type requirements --

@test "systemic_check without user_emails is refused" {
  mut 'del(.evidence.user_emails)'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"user_emails"* ]]
}

@test "systemic_check with ONE user is refused (one customer is not a class)" {
  mut '.evidence.user_emails = ["a@example.com"] | .evidence.count = 1'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"DISTINCT"* ]]
}

@test "systemic_check with the same user twice is refused (distinct, not length)" {
  mut '.evidence.user_emails = ["a@example.com", "A@Example.com "]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 1"* ]]
}

@test "systemic_check with a non-array user_emails is refused" {
  mut '.evidence.user_emails = "a@example.com"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ARRAY"* ]]
}

@test "a count lower than the distinct user tally is refused as self-inconsistent" {
  mut '.evidence.count = 1'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"lower than the number of distinct users"* ]]
}

@test "systemic_check without first_seen is refused" {
  mut 'del(.evidence.first_seen)'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"first_seen"* ]]
}

@test "data_verification requires a claim and an entity id" {
  mut '.type = "data_verification" | .evidence = {"observed_at": "2026-08-26T13:55:00Z", "profile_ids": ["x"]}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"claim"* ]]
}

@test "data_verification with no profile or track id is refused" {
  mut '.type = "data_verification" | .evidence = {"claim": "streams frozen at 12,480", "observed_at": "2026-08-26T13:55:00Z"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile_id or track_id"* ]]
}

@test "fix_request without an owning issue is refused (that is a systemic_check)" {
  mut '.type = "fix_request" | .evidence = {"customer_impact": "2 paying customers"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"known_issue"* ]]
}

@test "fix_request with an owning issue and typed impact validates" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/platform-data-processing-v4#222","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":2,"paying":true}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "escalation without a trend signal is refused" {
  mut '.type = "escalation" | .evidence = {"count": 7, "why_escalating": "count_climbing"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"rate or evidence.first_seen"* ]]
}

@test "escalation with a trend signal validates" {
  mut '.type = "escalation" | .evidence = {"count": 7, "rate": "1/day -> 6/day", "why_escalating": "count_climbing"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------- security --

@test "a GitHub token in any field is refused" {
  mut '.evidence.claim = "used token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO credentials"* ]]
}

@test "a private key is refused" {
  mut '.evidence.claim = "-----BEGIN RSA PRIVATE KEY-----"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO credentials"* ]]
}

@test "a credential-shaped field name is refused" {
  mut '.evidence.db_password = "hunter2"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO credentials"* ]]
}

@test "identity-document PII is refused" {
  mut '.evidence.claim = "customer sent passport number for identity check"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"PII ceiling"* ]]
}

@test "a long opaque blob is refused" {
  mut '.evidence.claim = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"opaque blob"* ]]
}

@test "a token smuggled inside a URL query string is still refused" {
  # Regression: URLs were stripped before the credential scan, so a token in a query
  # parameter fell out of the scan surface and was posted verbatim.
  mut '.evidence.conversation_links = ["https://example.test/cb?access_token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO credentials"* ]]
}

@test "a JSON-escaped credential key is refused (raw-byte grep alone is bypassable)" {
  # "api_key" is invisible to a grep over the file bytes, but jq -S decodes it to
  # api_key in the very comment this script posts. The scan must see what jq sees.
  printf '%s' '{
    "request_id": "cs-2026-08-26-escaped-key",
    "type": "systemic_check",
    "from": "operations",
    "opened_at": "2026-08-26T14:20:00Z",
    "symptom": "Credited tracks show 0 plays.",
    "evidence": {
      "user_emails": ["a@example.com", "b@example.com"],
      "first_seen": "2026-08-24T09:12:00Z",
      "count": 2,
      "note": "api_key=abcdefghijklmnop"
    }
  }' > "$REQ"
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO credentials"* ]]
}

@test "a phone number is refused" {
  mut '.evidence.claim = "customer callback 415 555 2671"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"PII ceiling"* ]]
}

@test "SHORT ordinary sentences are not street addresses — the bound was never enough" {
  # Round two of this finding, and the one that changed the mechanism. Bounding the words
  # between the number and the suffix does nothing for sentences that are already short:
  # "6 customers have no way to access analytics" is three words from the digit to the
  # suffix. There is no bound at which "a digit, some words, then `way`" stops being prose,
  # because `way`/`place`/`drive`/`court`/`circle`/`lane` are ordinary English words. The
  # vocabulary changed, not the bound. Note `data lane` in particular: it is the term this
  # protocol uses about itself on nearly every page.
  for phrase in \
    "6 customers have no way to access analytics" \
    "13 profiles in the data lane are frozen" \
    "4 accounts drive most of the volume" \
    "2 customers circle back weekly about this" \
    "9 users have no place to report the problem"
  do
    mut --arg p "$phrase" '.evidence.claim = $p'
    run "$SCRIPT" --file "$REQ" --validate
    [ "$status" -eq 0 ] || { echo "refused ordinary prose: $phrase"; false; }
  done
}

@test "unambiguous street addresses are still refused after the vocabulary narrowed" {
  # The other half of the trade: dropping the ambiguous suffixes must not drop the control.
  for addr in \
    "billing address is 1600 Amphitheatre Parkway" \
    "they gave 221B Baker Street as the billing address" \
    "billing address is 742 North Evergreen Terrace" \
    "55 Ocean Ave. is on file for this account" \
    "9 Sunset Blvd. is the billing address" \
    "12 Mulholland Dr. on the invoice" \
    "88 Airport Highway on the account"
  do
    mut --arg a "$addr" '.evidence.claim = $a'
    run "$SCRIPT" --file "$REQ" --validate
    [ "$status" -eq 1 ] || { echo "accepted an address: $addr"; false; }
    [[ "$output" == *"street-address-shaped"* ]]
  done
}

@test "a real sentence containing a digit and the word 'way' is NOT a street address" {
  # The suffix list is made of ordinary English words. With an unbounded word run between
  # the number and the suffix, ANY sentence with a date and a later "way"/"place"/"drive"
  # matches. This is not hypothetical: it refused the first real request filed over this
  # bridge. The bound (at most three intervening words) is what makes the pattern mean
  # "street address" rather than "prose".
  mut '.evidence.claim = "The 2026-08-27 export reports 1,027,335,401 lifetime streams and operations has no independent way to confirm it"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a street address with a unit-lettered number is still refused" {
  mut '.evidence.claim = "they gave 221B Baker Street as the billing address on 2026-08-01"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"street-address-shaped"* ]]
}

@test "a multi-word street address inside the bound is still refused" {
  mut '.evidence.claim = "billing address is 742 North Evergreen Terrace as of 2026-08-01"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"street-address-shaped"* ]]
}

@test "a street address is refused" {
  mut '.evidence.claim = "billing address is 1600 Amphitheatre Parkway"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"PII ceiling"* ]]
}

@test "an off-protocol evidence field is refused by allowlist, by name" {
  mut '.evidence.customer_phone = "n/a"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"customer_phone"* ]]
  [[ "$output" == *"not part of this protocol"* ]]
}

@test "an off-protocol top-level field is refused" {
  mut '.customer_record = {}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown top-level field"* ]]
}

@test "customer-stated stream counts are not mistaken for phone numbers" {
  mut '.evidence.customer_stated_numbers = ["65,397,687", "12,480"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "conversation deeplinks are NOT mistaken for secrets" {
  mut '.evidence.conversation_links = ["https://app.intercom.com/a/apps/abcdefghijklmnopqrstuvwxyz0123456789/conversations/215474812001295"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "emails and UUID profile ids pass the PII ceiling" {
  mut '.evidence.user_emails = ["reyko@example.com", "second@example.com"] | .evidence.profile_ids = ["32fa65b0-b738-4dde-894c-2fdada8a85b2"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------- de-dupe --

@test "a duplicate request_id is refused rather than fragmenting the thread" {
  echo "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 3 ]
  [[ "$output" == *"DUPLICATE"* ]]
  ! grep -q "issue comment" "$GH_STUB_LOG"
}

@test "a duplicate near the top of a mailbox larger than the pipe buffer is still refused" {
  # Regression: the check was `printf '%s' "$EXISTING" | grep -qE <marker>`. Under
  # `set -o pipefail`, grep -q exits on the first match, and when the mailbox is larger
  # than the pipe buffer printf is still writing, takes SIGPIPE (141), and the pipeline
  # reports FAILURE for a real match -- so the wrapper posted a duplicate instead of
  # refusing it. The one-line mailboxes above cannot reproduce that: the marker must be
  # followed by more data than a pipe can hold (64 KiB on Linux), so that grep closing
  # early is observable. 1 MiB of filler is comfortably past it on every platform.
  {
    echo "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->"
    head -c 1048576 /dev/zero | tr '\0' 'x'
    echo
  } > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 3 ]
  [[ "$output" == *"DUPLICATE"* ]]
  ! grep -q "issue comment" "$GH_STUB_LOG"
  [ ! -d "$AGENT_BRIDGE_TEST_DIR/posts" ]
}

@test "--follow-up posts onto the same request_id, marked as a follow-up" {
  echo "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 0 ]
  grep -q "issue comment" "$GH_STUB_LOG"
}

@test "a failed mailbox read refuses the post instead of failing open" {
  # Regression: `|| true` turned a 403/timeout into an empty comment list, so the
  # script posted as if no duplicate existed -- fragmenting an incident exactly when
  # the mailbox was degraded. An empty list is an answer; a failed read is not.
  # An unreadable mailbox: the comments file is removed, so the read fails rather than
  # returning empty. (Test mode reads a file instead of calling a client, so this is the
  # same distinction the production path draws by exit status.)
  rm -f "$AGENT_BRIDGE_TEST_DIR/comments.txt"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not read"* ]]
  [ ! -d "$AGENT_BRIDGE_TEST_DIR/posts" ]
}

@test "a different request_id is not treated as a duplicate" {
  echo "<!-- agent-bridge request_id=cs-2026-08-25-something-else type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 0 ]
  grep -q "issue comment" "$GH_STUB_LOG"
}

# --------------------------------------------------------------- usage --

@test "missing --file is a usage error, not a refusal" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "a nonexistent file is a usage error" {
  run "$SCRIPT" --file "$TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]
}

@test "--help prints the usage block, and survives header edits (marker-extracted)" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"Exit codes:"* ]]
  # Guards the line-range regression: a numbered range prints the wrong block the
  # first time anyone edits the header, and nothing else would notice.
  [[ "$output" != *"Mailbox:"* ]]
}

@test "screenshot_described is REMOVED — an optional prose field nobody needed" {
  mut '.evidence.screenshot_described = "the header reads the same total for every period"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not part of this protocol"* ]]
}

# ---------------------------------------------- entropy exemption is narrow --

@test "an opaque token in a URL QUERY STRING is refused (the exemption stops at ?)" {
  # The URL exemption exists for opaque PATH segments in deeplinks. Stripping the whole
  # URL threw the query string away with it, and that is exactly where a credential
  # rides — this one has no recognisable prefix, so only the entropy check can catch it.
  mut '.evidence.conversation_links = ["https://example.test/cb?token=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"opaque blob"* ]]
}

@test "an opaque token in a URL FRAGMENT is refused too" {
  mut '.evidence.conversation_links = ["https://example.test/cb#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "a long deeplink PATH is still not mistaken for a secret" {
  # The regression guard for the fix above: narrowing the exemption must not re-break
  # the false positive it was introduced to prevent.
  mut '.evidence.conversation_links = ["https://app.intercom.com/a/apps/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOP/conversations/215474812001295"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

# ------------------------------------------------- allowlist binds at depth --

@test "nested PII under an ALLOWED evidence key is refused" {
  # `note` is allowlisted, so a name check alone never looked inside it.
  mut '.evidence.claim = {"customer_phone":"2125550123"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"nested"* ]]
}

@test "an array of objects under an allowed key is refused" {
  mut '.evidence.customer_stated_numbers = [{"street_address":"221 Baker Street"}]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"nested"* ]]
}

@test "flat lists of scalars are still fine" {
  mut '.evidence.customer_stated_numbers = ["0","12,480"] | .evidence.count = 3'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------ value SHAPE checks --

@test "a first_seen that is not a timestamp is refused" {
  mut '.evidence.first_seen = "not-a-time"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ISO8601"* ]]
}

@test "a non-numeric count is refused" {
  mut '.evidence.count = "many"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  # Refused by the non-negative-integer gate, which now runs first and is stricter than
  # the type check behind it.
  [[ "$output" == *"INTEGER"* || "$output" == *"NUMBER"* ]]
}

@test "user_emails that are not emails are refused" {
  # Two distinct placeholders satisfy the >=2-distinct rule and still identify nobody.
  mut '.evidence.user_emails = ["x","y"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not email addresses"* ]]
}

@test "the whole malformed-shape combination is refused, not silently accepted" {
  mut '.evidence.user_emails = ["x","y"] | .evidence.first_seen = "not-a-time" | .evidence.count = "many"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "an observed_at that is not a timestamp is refused on data_verification" {
  mut '.type = "data_verification" | .evidence.claim = "frozen at 12,480 since 2026-08-04" | .evidence.observed_at = "yesterday"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ISO8601"* ]]
}

# ------------------------------------------------------ dedupe is atomic --

@test "an empty-array claim is refused (jq renders [] as non-empty text)" {
  mut '.type = "data_verification" | .evidence.claim = [] | .evidence.observed_at = "2026-08-26T13:55:00Z"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "an object-valued known_issue is refused" {
  mut '.type = "fix_request" | .evidence.known_issue = {"n":222} | .evidence.customer_impact = {"surface":"analytics","metric":"plays","direction":"missing","affected_count":2,"paying":true}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "a customer_impact with affected_count 0 is refused" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":0}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *">= 1"* ]]
}

@test "a numeric why_escalating is refused" {
  mut '.type = "escalation" | .evidence = {"count":7,"rate":"1/day -> 6/day","why_escalating":7}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "a negative count is refused (a tally of reports cannot be below zero)" {
  mut '.evidence.count = -1'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative INTEGER"* ]]
}

@test "a fractional count is refused" {
  mut '.evidence.count = 2.5'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative INTEGER"* ]]
}

@test "a negative count is refused on escalation too" {
  mut '.type = "escalation" | .evidence.why_escalating = "count_climbing" | .evidence.rate = "1/day -> 6/day" | .evidence.count = -3'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  # escalation is stricter than the other types: it needs >= 1, not merely non-negative.
  [[ "$output" == *">= 1"* ]]
}

@test "a bare digit-only phone number is refused in a request too" {
  mut '.evidence.claim = "customer called from 2125550123"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"phone number"* ]]
}

@test "a customer-quoted stream count with separators still passes" {
  mut '.evidence.customer_stated_numbers = ["12,480"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "an 11-digit NANP number with a leading 1 is refused" {
  mut '.evidence.claim = "12125550123"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

# --------------------------------------- the mailbox is pinned, not suggested --

@test "a deployed copy refuses a test backend outright" {
  # The scenario: an ops invocation prefixed with AGENT_BRIDGE_TEST_DIR would have printed
  # POSTED and exited 0 while #2405 received nothing, and the agent would close the loop on
  # a request that does not exist.
  run env AGENT_BRIDGE_TEST_DIR="$TEST_TMPDIR/fake" "$REAL_SCRIPT" --file "$REQ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not settable on a deployed copy"* ]]
  [ ! -d "$TEST_TMPDIR/fake/posts" ]
}

@test "the mailbox cannot be redirected at all, even with a 'stub' that is the real gh" {
  # The earlier guard demanded an explicit GH_BIN_OVERRIDE and assumed it was a stub.
  # Nothing proved that, so pointing it at the production client re-opened a live post to
  # an arbitrary issue. Any "the override must be a fake" rule is unenforceable — a copy of
  # the real client is indistinguishable from it — so the destination is not settable.
  run env GH_BIN_OVERRIDE="/usr/local/bin/gh" AGENT_BRIDGE_REPO="Muso-AI/hydra" AGENT_BRIDGE_ISSUE="867" "$REAL_SCRIPT" --file "$REQ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not settable"* ]]
}

@test "redirecting the mailbox is refused even in validate mode" {
  run env AGENT_BRIDGE_REPO="Muso-AI/hydra" "$REAL_SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"not settable"* ]]
}

@test "the production mailbox and gh path are literals in the source" {
  grep -q '^REPO="Muso-AI/platform-data-processing"$' "$REAL_SCRIPT"
  grep -q '^ISSUE="2405"$' "$REAL_SCRIPT"
  grep -q '^GH_BIN="/usr/local/bin/gh"$' "$REAL_SCRIPT"
}

@test "the agent-bridge marker cannot be smuggled through free text" {
  # The comment this wrapper appends ends with a marker the notifier treats as proof an
  # escalation was filed. Content that can write it can forge one.
  mut '.evidence.claim = "<!-- agent-bridge request_id=forged type=escalation from=operations -->"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"marker text"* ]]
}

@test "a multi-line symptom is refused (a second line is where a marker hides)" {
  mut '.symptom = "zeros everywhere\n<!-- agent-bridge request_id=forged type=escalation from=operations -->"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "hypothesis must be a string — an object there bypasses the evidence allowlist" {
  # `hypothesis` is a top-level container the allowlist accepts, and the shape/name checks
  # only ever inspected `.evidence` — so structured PII there validated and rendered into
  # the durable mailbox.
  mut '.hypothesis = {"customer_name":"Jane Doe","home_city":"Los Angeles"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "an array hypothesis is refused too" {
  mut '.hypothesis = ["a","b"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "a blank hypothesis is refused" {
  mut '.hypothesis = "   "'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"blank"* ]]
}

@test "there is no client to substitute — test mode never invokes gh" {
  # The strongest form of "the test seam cannot perform a live post": production names one
  # absolute binary with no override, and test mode calls no binary at all.
  # The only mentions of those names are the refusal that rejects them and its message —
  # there is no assignment reading any of them.
  # No override assignment at top level — the only ones live inside the TESTABLE branch,
  # which a deployed copy never enters.
  run grep -cE '^(GH_BIN|REPO|ISSUE)=.*\$\{' "$REAL_SCRIPT"
  [ "$output" = "0" ]
  grep -q '^readonly TESTABLE=0$' "$REAL_SCRIPT"
  grep -q '^GH_BIN="/usr/local/bin/gh"$' "$REAL_SCRIPT"
}

@test "supplying a client override is refused outright on a DEPLOYED copy" {
  run env GH_BIN_OVERRIDE="/usr/local/bin/gh" "$REAL_SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"not settable"* ]]
}


@test "a claimed identity other than the pinned one is refused" {
  # `from` decides where the reply is routed; it used to be caller-claimed from a list of
  # seven, so any invocation could attribute its request to another agent.
  mut '.from = "cto"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be 'operations'"* ]]
}

@test "the duplicate refusal names the follow-up path the doctrine tells you to use" {
  printf '%s\n' "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$AGENT_BRIDGE_TEST_DIR/comments.txt"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 3 ]
  [[ "$output" == *"--follow-up"* ]]
}

@test "a follow-up renders as a follow-up, not as a fresh request" {
  printf '%s\n' "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$AGENT_BRIDGE_TEST_DIR/comments.txt"
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 0 ]
  grep -q "FOLLOW-UP" "$AGENT_BRIDGE_TEST_DIR/posts/cs-2026-08-26-analytics-zero-plays.md"
}

@test "a bare payment card number is refused even with no 'card' keyword nearby" {
  # The old check needed a nearby word, so a naked PAN reached the durable mailbox.
  mut '.evidence.claim = "the number they gave was 4539578763621486"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Luhn"* ]]
}

@test "a large non-Luhn number is NOT mistaken for a card" {
  # Length cannot be the discriminator: customers quote big counts. The checksum can.
  mut '.evidence.customer_stated_numbers = ["6539578763621483"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "--follow-up on a request_id that does not exist is refused" {
  : > "$AGENT_BRIDGE_TEST_DIR/comments.txt"
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs something to follow"* ]]
  [ ! -d "$AGENT_BRIDGE_TEST_DIR/posts" ]
}

@test "a GROUPED payment card number is refused (the way cards are actually written)" {
  mut '.evidence.claim = "they read out 4111 1111 1111 1111 on the call"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Luhn"* ]]
}

@test "a HYPHEN-grouped payment card number is refused" {
  mut '.evidence.claim = "card 4111-1111-1111-1111"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "normalising does not glue unrelated numbers into a false card" {
  mut '.evidence.customer_stated_numbers = ["12,480","5,000"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a hostile PATH cannot own the process or rewrite the payload" {
  # Two routes the wrapper used to lose: an `env bash` shebang (a `bash` shim owns the
  # process before any pinning) and PATH-resolved helpers (a `jq` shim rewrites the payload
  # AFTER validation, so pinned downstream binaries carry an attacker-built body).
  hostile="$TEST_TMPDIR/hostile"
  mkdir -p "$hostile"
  for c in bash jq grep awk sed timeout; do
    printf '#!/bin/sh\necho "PWNED via %s" >&2\nexit 0\n' "$c" > "$hostile/$c"
    chmod +x "$hostile/$c"
  done
  run env PATH="$hostile:$PATH" "$SCRIPT" --file "$REQ"
  [[ "$output" != *"PWNED"* ]]
  [ "$status" -eq 0 ]
  [ -f "$AGENT_BRIDGE_TEST_DIR/posts/cs-2026-08-26-analytics-zero-plays.md" ]
}

@test "the entrypoint is an absolute interpreter and replaces PATH" {
  head -1 "$REAL_SCRIPT" | grep -q '^#!/bin/bash -p$'
  grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$' "$REAL_SCRIPT"
}

@test "BASH_ENV cannot run caller code before the gates" {
  # Bash sources $BASH_ENV before line 1, so without privileged mode a caller could print
  # the production success contract and exit 0 without a mailbox write ever happening.
  printf 'echo "PWNED-BASH_ENV"\n' > "$TEST_TMPDIR/inj.sh"
  run env BASH_ENV="$TEST_TMPDIR/inj.sh" "$SCRIPT" --file "$REQ" --validate
  [[ "$output" != *"PWNED-BASH_ENV"* ]]
  [ "$status" -eq 0 ]
}

@test "an exported shell function cannot shadow a helper" {
  # Exported functions are imported before line 1 too, and a hostile `jq` rewrites the
  # payload after validation while the pinned binaries carry it.
  run env BASH_FUNC_jq%%='() { echo PWNED-FN; }' "$SCRIPT" --file "$REQ" --validate
  [[ "$output" != *"PWNED-FN"* ]]
  [ "$status" -eq 0 ]
}

@test "the entrypoint runs bash in privileged mode" {
  head -1 "$REAL_SCRIPT" | grep -q '^#!/bin/bash -p$'
}

@test "a transcript pasted into note is refused (it matches no scanner, so shape is the gate)" {
  long="$(printf 'Customer Jane Doe said: %s' "$(printf 'x%.0s' $(seq 1 320))")"
  mut --arg v "$long" '.evidence.claim = $v'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"transcript"* || "$output" == *"note"* ]]
}

@test "a multi-line prose field is refused and points at conversation_links" {
  # No name in the fixture: the quoted-speech guard now fires first on a "Name:" opener, and
  # this test is about the LINE bound, so it must exercise that rule and not the other one.
  mut '.evidence.claim = "both on Business\nboth noticed after 2026-08-24\nboth followed up"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"SINGLE line"* ]]
}

@test "a short single-line note still passes" {
  mut '.evidence.claim = "both are Business plan, both noticed after 2026-08-24"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "the removed generic fields are refused by name" {
  # note / detail / what_they_see were the general-purpose prose channel. Prose is the one
  # thing this gate cannot police, so the FIELDS are gone rather than guarded.
  for f in note detail what_they_see; do
    cp "$REQ" "$REQ.orig"
    jq --arg k "$f" '.evidence[$k] = "anything at all"' "$REQ.orig" > "$REQ"
    run "$SCRIPT" --file "$REQ" --validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"not part of this protocol"* ]]
    mv "$REQ.orig" "$REQ"
  done
}

@test "a zero-report escalation is refused" {
  mut '.type = "escalation" | .evidence.count = 0 | .evidence.rate = "0/day -> 0/day" | .evidence.why_escalating = "count_climbing"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *">= 1"* ]]
}


# ------------------------------------------------- the input is read ONCE --

@test "swapping the file after validation cannot change what gets posted" {
  # TOCTOU: every check re-opened the caller's path and the render re-opened it again, so a
  # swap between the last check and the render posted content that was never validated.
  # Here the "attacker" replaces the file with a credential-bearing request the moment
  # validation has passed; the snapshot means the posted body is still the validated one.
  cat > "$TEST_TMPDIR/swap.sh" <<SWAP
#!/bin/bash
sleep 0.2
jq '.symptom = "SWAPPED ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"' "$REQ" > "$REQ.tmp" && mv "$REQ.tmp" "$REQ"
SWAP
  chmod +x "$TEST_TMPDIR/swap.sh"
  "$TEST_TMPDIR/swap.sh" &
  run "$SCRIPT" --file "$REQ"
  wait
  [ "$status" -eq 0 ]
  posted="$AGENT_BRIDGE_TEST_DIR/posts/cs-2026-08-26-analytics-zero-plays.md"
  [ -f "$posted" ]
  run grep -c "SWAPPED" "$posted"
  [ "$output" = "0" ]
  run grep -c "ghp_" "$posted"
  [ "$output" = "0" ]
}

@test "the posted body is internally consistent under a hammering swapper" {
  # The real invariant is "posted == VALIDATED", not "posted == original": if the snapshot
  # happens to catch a rewritten version, posting that version is correct — it is the one
  # that was checked. What must never happen is the body being assembled from TWO different
  # reads, which is what eighteen re-opens allowed. The rendered comment contains the symptom
  # twice (the blockquote and the JSON block); if those came from different reads they differ.
  # Deterministic: true no matter where the swaps land.
  ( for i in $(seq 1 60); do
      jq --arg n "ATTACKER-$i" '.symptom = $n' "$REQ" > "$REQ.att" 2>/dev/null && mv "$REQ.att" "$REQ" 2>/dev/null
    done ) &
  swapper=$!
  run "$SCRIPT" --file "$REQ"
  wait $swapper 2>/dev/null || true
  [ "$status" -eq 0 ]
  posted="$AGENT_BRIDGE_TEST_DIR/posts/cs-2026-08-26-analytics-zero-plays.md"
  [ -f "$posted" ]
  quoted="$(grep -m1 '^> ' "$posted" | sed 's/^> //')"
  injson="$(sed -n '/^```json$/,/^```$/p' "$posted" | sed '1d;$d' | jq -r '.symptom')"
  [ -n "$quoted" ]
  [ "$quoted" = "$injson" ]
}

@test "the snapshot directory is cleaned up" {
  # This test WAS false-green: it ran `wc -l` and asserted only the exit status, and `wc`
  # exits 0 whether it counts zero files or fifty. QA verified it still reported ok with
  # every `rm -rf "$SNAP_DIR"` deleted from the wrapper — so CI was certifying cleanup while
  # snapshots containing customer emails and internal IDs accumulated under /tmp.
  # Now it pins TMPDIR to a directory this test owns, so the count is exact and attributable.
  snaproot="$TEST_TMPDIR/snaproot"
  mkdir -p "$snaproot"
  run env TMPDIR="$snaproot" "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
  run bash -c "find '$snaproot' -name request.json | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  # And nothing else is left behind either.
  run bash -c "find '$snaproot' -mindepth 1 | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "the snapshot is cleaned up on the POST path too, not just validate" {
  snaproot="$TEST_TMPDIR/snaproot2"
  mkdir -p "$snaproot"
  run env TMPDIR="$snaproot" "$SCRIPT" --file "$REQ"
  [ "$status" -eq 0 ]
  run bash -c "find '$snaproot' -name request.json | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "the snapshot is cleaned up even when the request is REFUSED" {
  # The refusal path exits early; if it skipped the trap, a rejected request carrying the
  # very PII that got it rejected would be the thing left on disk.
  snaproot="$TEST_TMPDIR/snaproot3"
  mkdir -p "$snaproot"
  mut '.evidence.user_emails = ["only-one@example.com"]'
  run env TMPDIR="$snaproot" "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  run bash -c "find '$snaproot' -name request.json | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "an evidence key containing a space cannot masquerade as two allowed keys" {
  # `for k in $(jq ...)` word-split before comparing, so "claim observed_at" was seen as two
  # allowed keys and the real off-protocol key passed with whatever prose it carried.
  mut '.evidence["claim observed_at"] = "Jane Doe: my plays are gone"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not part of this protocol"* ]]
}

@test "a top-level key containing a space is refused too" {
  mut '.["symptom hypothesis"] = "Jane Doe said so"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown top-level field"* ]]
}

@test "a glob metacharacter in a key cannot match by pathname expansion" {
  mut '.evidence["*"] = "anything"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not part of this protocol"* ]]
}

@test "a tab-bearing key is refused" {
  mut '.evidence["claim\tobserved_at"] = "x"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "the refusal names the offending key, not a fragment of it" {
  mut '.evidence["claim observed_at"] = "x"'
  run "$SCRIPT" --file "$REQ" --validate
  [[ "$output" == *"claim observed_at"* ]]
}


@test "a missing timeout binary is an environment error, not an unbounded call" {
  # The deadline used to fall back to running unbounded when `timeout` was absent — so it
  # disappeared exactly when the host was degraded, which is when it matters.
  cp "$SCRIPT" "$TEST_TMPDIR/notimeout.sh"
  # Force BOTH resolution branches at a path that does not exist, so the fail-closed guard
  # is what runs rather than the dev-box fallback.
  sed -i.bak 's|command -v timeout .*|echo /nonexistent/timeout)"|; s|^  TIMEOUT_BIN="/usr/bin/timeout"$|  TIMEOUT_BIN="/nonexistent/timeout"|' "$TEST_TMPDIR/notimeout.sh"
  chmod +x "$TEST_TMPDIR/notimeout.sh"
  run "$TEST_TMPDIR/notimeout.sh" --file "$REQ"
  [ "$status" -eq 2 ]
  [[ "$output" == *"required dependency"* ]]
  [ ! -d "$AGENT_BRIDGE_TEST_DIR/posts" ]
}

@test "an email address buried in claim is refused" {
  mut '.type = "data_verification" | .evidence = {"claim":"jane@example.com says 12,480 is wrong","observed_at":"2026-08-26T13:55:00Z","profile_ids":["547a8aaa-8e22-490b-bb74-c010575499be"]}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"email address"* ]]
}

@test "an @handle in claim is refused" {
  mut '.type = "data_verification" | .evidence = {"claim":"@janedoe says 12,480 is wrong","observed_at":"2026-08-26T13:55:00Z","profile_ids":["547a8aaa-8e22-490b-bb74-c010575499be"]}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"@handle"* ]]
}

@test "a prose field that answers its own question still passes" {
  mut '.type = "fix_request" | .evidence.known_issue = "Muso-AI/hydra#1" | .evidence.customer_impact = {"surface":"analytics","metric":"plays","direction":"missing","affected_count":2,"paying":true}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}


@test "a non-string entry in user_emails is REFUSED, not a crash outside the exit contract" {
  # ascii_downcase on a number made jq throw and the wrapper exited 5 — outside the
  # documented 0-4 range, so a caller could neither classify the failure nor be told what to
  # fix. An undocumented exit code is a broken interface, not a rough edge.
  mut '.evidence.user_emails = [123, "a@example.com"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-string"* ]]
}

@test "a non-array profile_ids is refused rather than concatenated blindly" {
  mut '.type = "data_verification" | .evidence.claim = "frozen at 12,480 since 2026-08-04" | .evidence.observed_at = "2026-08-26T13:55:00Z" | .evidence.profile_ids = "not-an-array"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ARRAY"* ]]
}

@test "an off-schema customer_impact string is refused — the Jane Doe case, closed by typing" {
  # This is the case four rounds of pattern-matching could not close. It is closed now not by
  # recognising the name but by the field being unable to hold a sentence at all.
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":"Jane Doe says her credits vanished"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"OBJECT"* ]]
}

@test "a name cannot hide in the metric token either" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":{"surface":"analytics","metric":"Jane Doe says her credits vanished","direction":"missing","affected_count":2}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"snake_case token"* ]]
}

@test "off-schema keys inside customer_impact are refused" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":2,"note":"Jane Doe said so"}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"off-schema"* ]]
}

@test "quoted speech in claim is still refused (claim is the one prose field left)" {
  mut '.type = "data_verification" | .evidence = {"claim":"Jane Doe: 12,480 is wrong","observed_at":"2026-08-26T13:55:00Z","profile_ids":["547a8aaa-8e22-490b-bb74-c010575499be"]}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"quoted speech"* ]]
}

@test "an unmeasurable claim is refused — a claim must be checkable" {
  mut '.type = "data_verification" | .evidence.observed_at = "2026-08-26T13:55:00Z" | .evidence.claim = "Jane Doe says it is broken"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "why_escalating must be one of exactly three enum values" {
  mut '.type = "escalation" | .evidence = {"count":6,"rate":"1/day -> 6/day","why_escalating":"it is bad"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one of"* ]]
}

@test "a prose description of a real ground is still refused — it is an enum, not a sentence" {
  mut '.type = "escalation" | .evidence = {"count":6,"rate":"1/day -> 6/day","why_escalating":"the count is climbing and Jane Doe is furious"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "a legitimate escalation ground still passes" {
  mut '.type = "escalation" | .evidence.count = 6 | .evidence.rate = "1/day -> 6/day" | .evidence.why_escalating = "count_climbing"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "an email address in hypothesis is refused" {
  # hypothesis is TOP-LEVEL, so it sat outside the prose-field loop entirely while the doc
  # told producers to write a sentence there.
  mut '.hypothesis = "jane@example.com may have been merged into another profile"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"email address"* ]]
}

@test "quoted speech in hypothesis is refused" {
  mut '.hypothesis = "Jane Doe: I was merged into another profile"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"quoted speech"* ]]
}

@test "a multi-line hypothesis is refused" {
  mut '.hypothesis = "maybe the cube froze\nor maybe capture stopped"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"SINGLE line"* ]]
}

@test "a clearly-labelled one-line hypothesis still passes" {
  mut '.hypothesis = "the served cube generation may be frozen at an older run id"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a bare NAME in hypothesis still passes — the documented residual, asserted so it stays documented" {
  # Not a bug report: this is the acknowledged gap, and pinning it means a future change that
  # silently closes OR widens it shows up as a test change rather than as a surprise.
  mut '.hypothesis = "the profile may have been merged into another one"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a numeric request_id is refused, not coerced to a string" {
  # `jq -r` renders 12345 as "12345", so the envelope accepted values whose type it never
  # agreed to. Same defect the array members had, one level up.
  mut '.request_id = 12345'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "a numeric symptom is refused" {
  mut '.symptom = 12345'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "an object-valued type is refused" {
  mut '.type = {"n":1}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "a request_id quoted inside another comment is not mistaken for an existing thread" {
  # Unanchored substring matching meant any occurrence counted as proof — including one
  # rendered inside another request's JSON block — so de-dup could refuse a genuinely new
  # request and --follow-up could believe a thread existed that never did.
  cat > "$AGENT_BRIDGE_TEST_DIR/comments.txt" <<EOF
**agent-bridge request — systemic check** (from \`operations\`)
\`\`\`json
{ "evidence": { "claim": "see request_id=cs-2026-08-26-analytics-zero-plays for context" } }
\`\`\`
<!-- agent-bridge request_id=some-other-thing type=systemic_check from=operations -->
EOF
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTED"* ]]
}

@test "--follow-up is not fooled by a quoted request_id either" {
  printf '%s\n' 'a comment mentioning request_id=cs-2026-08-26-analytics-zero-plays in passing' > "$AGENT_BRIDGE_TEST_DIR/comments.txt"
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs something to follow"* ]]
}


# ------------------------------------------- the rest of the schema is typed too --

@test "prose in conversation_links is refused - that field carries links" {
  mut '.evidence.conversation_links = ["she said her plays vanished last Tuesday"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"not URLs"* ]]
}

@test "real deeplinks in conversation_links still pass" {
  mut '.evidence.conversation_links = ["https://app.intercom.com/a/apps/x/conversations/215474812001295"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a sentence in customer_stated_numbers is refused - give the figures" {
  mut '.evidence.customer_stated_numbers = ["she said it was 12,480 last week"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"numeric values"* ]]
}

@test "actual figures in customer_stated_numbers pass, string or number" {
  mut '.evidence.customer_stated_numbers = ["12,480", 0, "65.5%"]'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a description instead of an issue reference is refused" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"the cube freeze one Jane reported","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":2}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"issue REFERENCE"* ]]
}

@test "a full GitHub issue URL is an acceptable known_issue" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"https://github.com/Muso-AI/platform-data-processing-v4/issues/222","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":2}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "an opinion instead of a rate is refused" {
  mut '.type = "escalation" | .evidence = {"count":6,"why_escalating":"count_climbing","rate":"getting much worse"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"N/period"* ]]
}

@test "a parseable rate passes" {
  mut '.type = "escalation" | .evidence = {"count":6,"why_escalating":"count_climbing","rate":"1/day -> 6/day"}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a sentence cannot hide in any remaining evidence field" {
  # The sweep asserted as one test: every evidence field except the three documented prose
  # residuals now rejects a sentence.
  for f in conversation_links customer_stated_numbers; do
    cp "$REQ" "$REQ.orig"
    jq --arg k "$f" '.evidence[$k] = ["Jane Doe says her credits vanished"]' "$REQ.orig" > "$REQ"
    run "$SCRIPT" --file "$REQ" --validate
    [ "$status" -eq 1 ]
    mv "$REQ.orig" "$REQ"
  done
}

@test "an email address in the symptom is refused" {
  # symptom is top-level and was outside the prose loop while every document said it was
  # scanned — a documented residual quietly became an undocumented one.
  mut '.symptom = "jane@example.com reports 0 plays on all credited tracks"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"email address"* ]]
}

@test "an @handle in the symptom is refused" {
  mut '.symptom = "@janedoe reports 0 plays on all credited tracks"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"@handle"* ]]
}

@test "quoted speech in the symptom is refused" {
  mut '.symptom = "Jane Doe: my plays are gone"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"quoted speech"* ]]
}

@test "a normal symptom still passes, and keeps its own 400-char bound" {
  mut '.symptom = "Credited tracks show 0 plays and the profile graph is flat across all periods."'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a flag with no value is a usage error, not a silent set -e death" {
  # `shift 2` with nothing to shift made `set -e` kill the script: exit 1, no output — a
  # usage error wearing the validation-refusal code, telling the caller nothing.
  run "$SCRIPT" --file
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "a re-pointed mailbox is caught at RUNTIME regardless of spelling" {
  for form in 'REPO="Muso-AI/somewhere-else"' 'export REPO="Muso-AI/somewhere-else"' 'declare -x REPO="Muso-AI/somewhere-else"'; do
    cp "$REAL_SCRIPT" "$TEST_TMPDIR/mut.sh"
    # Insert BEFORE the freeze: after it the name is readonly and bash errors instead, which
    # is a different (also correct) protection. The runtime assertion is what covers the
    # window between resolution and freeze.
    awk -v ins="$form" '
      /^readonly REPO ISSUE GH_BIN TEST_DIR$/ { print ins }
      { print }
    ' "$TEST_TMPDIR/mut.sh" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mut.sh"
    chmod +x "$TEST_TMPDIR/mut.sh"
    run env -u AGENT_BRIDGE_TEST_DIR -u AGENT_BRIDGE_REPO \
        -u AGENT_BRIDGE_ISSUE -u GH_BIN_OVERRIDE \
        -u AGENT_BRIDGE_GH_TIMEOUT_SECS -u AGENT_BRIDGE_TEST_READ_DELAY \
        "$TEST_TMPDIR/mut.sh" --file "$REQ" --validate
    [ "$status" -eq 2 ]
    [[ "$output" == *"REPO was altered"* ]]
  done
}

@test "an impossible calendar date is refused, not just a malformed one" {
  # 2026-13-45T99:99:99Z is well-formed and impossible. A lane correlating events on it would
  # place the report outside every window it looked in.
  mut '.evidence.first_seen = "2026-13-45T99:99:99Z"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ISO8601"* ]]
}

@test "an impossible opened_at is refused" {
  mut '.opened_at = "2026-02-30T00:00:00Z"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
}

@test "a real leap day is accepted" {
  # The calendar check must not reject valid instants — 2028 is a leap year.
  mut '.opened_at = "2028-02-29T12:00:00Z"'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 0 ]
}

@test "a numeric customer_impact.surface is refused before the enum check coerces it" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":{"surface":5,"metric":"plays","direction":"missing","affected_count":2}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"STRING"* ]]
}

@test "a string affected_count is refused" {
  mut '.type = "fix_request" | .evidence = {"known_issue":"Muso-AI/hydra#1","customer_impact":{"surface":"analytics","metric":"plays","direction":"missing","affected_count":"2"}}'
  run "$SCRIPT" --file "$REQ" --validate
  [ "$status" -eq 1 ]
  [[ "$output" == *"NUMBER"* ]]
}

@test "a neutered die cannot disable the runtime pins — the exit is inlined" {
  # `die() { :; }` used to turn every pin into a no-op while the gate still matched the
  # comparison. The refusal now carries its own exit.
  cp "$REAL_SCRIPT" "$TEST_TMPDIR/mut.sh"
  sed -i.bak 's|^die().*|die() { :; }|' "$TEST_TMPDIR/mut.sh"
  awk '/^readonly REPO ISSUE GH_BIN TEST_DIR$/ { print "REPO=\"Muso-AI/somewhere-else\"" } { print }' \
    "$TEST_TMPDIR/mut.sh" > "$TEST_TMPDIR/m2" && mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mut.sh"
  chmod +x "$TEST_TMPDIR/mut.sh"
  run env -u AGENT_BRIDGE_TEST_DIR -u AGENT_BRIDGE_REPO \
      -u AGENT_BRIDGE_ISSUE -u GH_BIN_OVERRIDE \
      -u AGENT_BRIDGE_GH_TIMEOUT_SECS -u AGENT_BRIDGE_TEST_READ_DELAY \
      "$TEST_TMPDIR/mut.sh" --file "$REQ" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"REPO was altered"* ]]
}

# ------------------------------------------------- at-least-once semantics --

@test "concurrent callers on one request_id: every outcome is a DEFINED one, never a hang" {
  # THE ASSERTION IS THE INVARIANT, NOT THE INTERLEAVING. There is no mutex, so which
  # caller reads before the other posts is genuinely undetermined — and a test that
  # asserted a particular interleaving would be asserting something the contract
  # deliberately does not promise. (It did, briefly, and CI caught it: the second caller
  # happened to read AFTER the first had posted, saw the duplicate, and correctly refused
  # with 3 — on a machine where the two processes had not overlapped. A flaky test would
  # have been the wrong lesson from a correct run.)
  #
  # What at-least-once DOES promise, and what this pins:
  #   - the request lands AT LEAST once,
  #   - no caller is left hanging, crashing, or blocked on a lock that no longer exists,
  #   - every outcome is either "posted" (0) or "already there, use --follow-up" (3),
  #   - and if both post, that is ACCEPTED — two comments, one request_id, which the
  #     consumer collapses at triage.
  : > "$GH_STUB_COMMENTS"
  export AGENT_BRIDGE_TEST_READ_DELAY=1
  "$SCRIPT" --file "$REQ" & p1=$!
  "$SCRIPT" --file "$REQ" & p2=$!
  s1=0; wait "$p1" || s1=$?
  s2=0; wait "$p2" || s2=$?

  # Diagnostic BEFORE the assertions, because this case has failed in CI twice
  # and both times the log carried only `not ok` with no values — unactionable.
  # bats surfaces a test's output only when it fails, so this costs nothing on a
  # green run and names the actual outcome on a red one.
  #
  # ROOT-CAUSED 2026-09-22, from exactly the evidence this instrumentation was
  # added to capture. The next occurrence arrived carrying:
  #   cp: cannot create regular file '.../posts/<id>.md': File exists
  #   concurrency outcome: s1=0 s2=1 posts=1
  # s2=1 is not one of the contract's outcomes. The archive step used `cp`,
  # and GNU cp opens a destination it believes is new with O_CREAT|O_EXCL, so
  # the losing racer got EEXIST and `set -e` propagated cp's exit 1.
  #
  # Why 32 earlier runs missed it: the window is between cp's stat and its
  # open, and it only exists when the destination starts ABSENT. Measured on
  # node-8 (GNU coreutils 9.4): 0/300 with two racers on a pre-existing file,
  # 67/400 with a fresh destination and four. The fix is a shell redirect
  # (O_CREAT|O_TRUNC, cannot fail on an existing file): 0/400.
  #
  # The diagnostic below stays. It cost nothing on green runs and is what made
  # the cause readable in one shot when it finally fired.
  posts="$(grep -c "issue comment" "$GH_STUB_LOG" || true)"
  echo "concurrency outcome: s1=$s1 s2=$s2 posts=$posts (expect s in {0,3}, at least one 0, posts in 1..2)" >&2
  if [ -s "$GH_STUB_LOG" ]; then
    echo "--- gh stub log ---" >&2
    sed 's/^/  /' "$GH_STUB_LOG" >&2
  fi

  # 0 = posted, 3 = duplicate. 2 would mean a usage/environment refusal — which is what a
  # lock timeout used to look like, so this is the assertion that says the lock is gone.
  [ "$s1" -eq 0 ] || [ "$s1" -eq 3 ]
  [ "$s2" -eq 0 ] || [ "$s2" -eq 3 ]

  # AT LEAST once: they cannot BOTH decline. Losing the request is the failure that matters.
  [ "$s1" -eq 0 ] || [ "$s2" -eq 0 ]

  [ "$posts" -ge 1 ]
  [ "$posts" -le 2 ]

  # Whatever landed carries the id the consumer dedupes on — the entire basis for calling a
  # duplicate harmless rather than merely rare.
  grep -q "cs-2026-08-26-analytics-zero-plays" \
    "$AGENT_BRIDGE_TEST_DIR/posts/cs-2026-08-26-analytics-zero-plays.md"
}

@test "the archive write cannot fail on a destination another caller just created" {
  # The behavioural guard is the concurrency test above — it is what actually
  # went red. But its red is PROBABILISTIC (the window sits between cp's stat
  # and its open, and exists only while the destination is absent), so it
  # cannot be relied on to catch a reintroduction: the same `cp` survived 32
  # deliberate runs on node-8 before CI caught it.
  #
  # So this one is deterministic and deliberately shape-based: whatever writes
  # the archive destination must be a command that cannot fail when the file
  # already exists. `cp` and `cp -f` both can (measured 67/400 and 58/400 with
  # four racers on GNU coreutils 9.4); a redirect and `mv` of a unique temp
  # cannot (0/400 each).
  local archive_cmd
  archive_cmd="$(grep -vE '^[[:space:]]*#' "$SCRIPT" \
    | grep -F 'TEST_DIR/posts/' \
    | grep -vF 'mkdir' \
    | head -1 \
    | sed -E 's/^[[:space:]]+//' \
    | awk '{ print $1 }')"

  # Vacuity guard: an empty match would satisfy the assertion below trivially,
  # which is how a shape-based test quietly stops testing anything.
  [ -n "$archive_cmd" ]

  if [ "$archive_cmd" = "cp" ]; then
    echo "archive write uses cp, which exits 1 with EEXIST when a concurrent" >&2
    echo "caller creates the destination first — see the concurrency test above." >&2
    return 1
  fi
}

@test "a second post on a live request_id is ACCEPTED, not blocked — no mutex survives" {
  # The deterministic half of the pair above. Under --follow-up the wrapper posts onto an
  # existing thread, which is the same read-then-write window the lock used to serialise.
  # Two of them back to back both succeed: nothing is holding, reaping, or waiting.
  printf '%s\n' "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 0 ]
  run "$SCRIPT" --file "$REQ" --follow-up
  [ "$status" -eq 0 ]
  [ "$(grep -c "issue comment" "$GH_STUB_LOG")" -eq 2 ]
}

@test "the ordinary NON-racing duplicate is still caught and pointed at --follow-up" {
  # Best effort, not a gate: it catches the case that actually happens (someone
  # re-filing an existing request minutes later) without pretending to catch the race.
  echo "<!-- agent-bridge request_id=cs-2026-08-26-analytics-zero-plays type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -eq 3 ]
  [[ "$output" == *"DUPLICATE"* ]]
}

@test "an unreadable mailbox still FAILS CLOSED — at-least-once is not at-least-blind" {
  # "I could not check" and "there was nothing there" stay distinguishable. Relaxing
  # duplicate HANDLING must not relax the duplicate READ, which is a different contract.
  rm -f "$GH_STUB_COMMENTS"
  run "$SCRIPT" --file "$REQ"
  [ "$status" -ne 0 ]
  ! grep -q "issue comment" "$GH_STUB_LOG"
}

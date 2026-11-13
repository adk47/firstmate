#!/usr/bin/env bats
# Tests for scripts/intercom-ops-write.sh: the ONLY path the operations agent uses to write
# into an Intercom conversation.
#
# Why the wrapper exists (2026-09-01): the ops agent resolved an escalated conversation by
# composing a raw `curl POST /conversations/<id>/reply` from memory. That day it chose
# message_type "note" (internal, correct). On 2026-08-31 the SAME raw-curl path chose
# "comment" under a human's admin id and customers saw "Nicholas Sollazzo" mid-thread. The
# difference between an internal note and a customer-facing reply was one word in a payload
# the agent typed itself, guarded by prose. These tests are what keeps the gate real:
# internal note by default, a customer-facing reply only with an allowlisted human's
# explicit approval, Caroline's identity pinned, the api-log written BEFORE the POST, and
# the response part_type verified so "POSTED note" can never describe a comment.
#
# Hermetic: curl is a stub handed in through the test seam, no network, no repo writes.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAL_SCRIPT="$HYDRA_REPO/scripts/intercom-ops-write.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  # Derived copy with the build-time TESTABLE literal flipped (see agent-bridge-request.bats):
  # the deployed file is always TESTABLE=0 and refuses every override.
  sed 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$REAL_SCRIPT" > "$TEST_TMPDIR/under-test.sh"
  chmod +x "$TEST_TMPDIR/under-test.sh"
  SCRIPT="$TEST_TMPDIR/under-test.sh"

  export MUSOAI_INTERCOM_TOKEN="test-token"
  export INTERCOM_OPS_TEST_LOG_DIR="$TEST_TMPDIR/api-logs"
  # The per-conversation write lock lives in the test's own dir, and a held lock is given up on after 1 s
  # (the deployed copy waits 20 s under /run/lock and refuses both overrides).
  export INTERCOM_OPS_TEST_LOCK_DIR="$TEST_TMPDIR/locks"
  export INTERCOM_OPS_TEST_LOCK_WAIT_S=1
  mkdir -p "$INTERCOM_OPS_TEST_LOG_DIR"

  # curl stub: records the URL and the JSON payload, answers like Intercom really does: the
  # FULL conversation (top-level id = conversation id) whose LAST conversation_part is the
  # one just created, part_type following the requested message_type (the shape
  # plugins/intercom/tests/outbound.test.ts pins). A stub that answered a bare part would
  # certify a wrapper that fails on every real write. INTERCOM_STUB_RESPONSE overrides it.
  STUB_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export CURL_STUB_LOG="$TEST_TMPDIR/curl-calls.log"
  export CURL_STUB_PAYLOAD="$TEST_TMPDIR/curl-payload.json"
  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
payload=""
url=""
# The body last POSTed, the way Intercom stores text: & < > escaped, each line a <p>, and a line that starts
# "N. " a list item with its number dropped.
stored_as_intercom() {
  jq -r '.body | split("\n") | map(select(length > 0)
      | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
      | if test("^[0-9]+\\. ") then "<li>" + sub("^[0-9]+\\. "; "") + "</li>" else "<p>" + . + "</p>" end)
      | join("")' "$CURL_STUB_PAYLOAD"
}
while [ $# -gt 0 ]; do
  case "$1" in
    --data|-d) if [ "$2" = "@-" ]; then payload="$(cat)"; else payload="$2"; fi; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -z "$payload" ]; then
  # A GET. Reads are recorded apart from the POSTs, so a test counting writes never counts a read.
  #   1st GET = the PRE-READ the wrapper makes before it logs, claims or posts: the parts already on file.
  #             Default: the customer's own older part and nothing of ours. INTERCOM_STUB_PREREAD overrides it
  #             (a JSON body), and INTERCOM_STUB_PREREAD_RC makes the read itself fail.
  #   later   = the re-read after a POST whose response carried no qualifying part (INTERCOM_STUB_REFETCH, a
  #             JSON body; or INTERCOM_STUB_REFETCH_STORED=1, the conversation as it reads once the POST landed).
  # "1st" is per wrapper invocation, not per test: a test may run the wrapper twice, or two at once. So the count
  # is keyed by the wrapper's pid: the topmost of the stub's ancestors that is still the copy under test (a `$( ... || true)`
  # runs in a forked copy of it, so the direct grandparent is not always the wrapper itself).
  echo "$url" >> "$CURL_STUB_LOG.get"
  wrapper_pid=""; up="$PPID"
  while [ -n "$up" ] && [ "$up" -gt 1 ]; do
    case "$(ps -o args= -p "$up" 2>/dev/null)" in
      *under-test.sh*) wrapper_pid="$up" ;;
      *) [ -z "$wrapper_pid" ] || break ;;
    esac
    up="$(ps -o ppid= -p "$up" 2>/dev/null | tr -d ' ')"
  done
  wrapper_pid="${wrapper_pid:-$PPID}"
  echo "$url" >> "$CURL_STUB_LOG.get.$wrapper_pid"
  conv="${url##*/conversations/}"; conv="${conv%%[/?]*}"
  if [ "$(wc -l < "$CURL_STUB_LOG.get.$wrapper_pid")" -eq 1 ]; then
    [ -z "${INTERCOM_STUB_PREREAD_RC:-}" ] || exit "$INTERCOM_STUB_PREREAD_RC"
    if [ -n "${INTERCOM_STUB_PREREAD:-}" ]; then printf '%s' "$INTERCOM_STUB_PREREAD"; exit 0; fi
    printf '{"type":"conversation","id":"%s","conversation_parts":{"type":"conversation_part.list","conversation_parts":[{"type":"conversation_part","id":"52987726001","part_type":"comment","body":"<p>hello</p>","created_at":%s,"author":{"type":"user","id":"6001"}}],"total_count":1}}' "$conv" "$(( $(date +%s) - 3600 ))"
    exit 0
  fi
  if [ -n "${INTERCOM_STUB_REFETCH_STORED:-}" ]; then
    # The conversation now holds what this call POSTed, stored the way Intercom stores text: & < > escaped,
    # each line a <p>, and a line that starts "N. " a list item with its number dropped. The part is ours
    # (id 777), created now. INTERCOM_STUB_REFETCH_EXTRA adds more parts (raw JSON, comma-led).
    now="$(date +%s)"
    stored="$(stored_as_intercom)"
    mt="$(jq -r '.message_type' "$CURL_STUB_PAYLOAD")"
    if [ "$mt" = "note" ]; then pt="note"; else pt="${INTERCOM_STUB_REFETCH_STORED_TYPE:-comment}"; fi
    jq -cn --arg conv "$conv" --arg pt "$pt" --arg body "$stored" --argjson now "$now" \
      --argjson extra "[${INTERCOM_STUB_REFETCH_EXTRA#,}]" \
      '{type: "conversation", id: $conv, conversation_parts: {type: "conversation_part.list", conversation_parts:
         ([{type: "conversation_part", id: "777", part_type: $pt, body: $body, created_at: $now,
            author: {type: "admin", id: "5763097"}}] + $extra)}}'
    exit 0
  fi
  if [ -n "${INTERCOM_STUB_REFETCH:-}" ]; then printf '%s' "$INTERCOM_STUB_REFETCH"; else printf '{}'; fi
  exit 0
fi
echo "$url" >> "$CURL_STUB_LOG"
printf '%s' "$payload" > "$CURL_STUB_PAYLOAD"
# INTERCOM_STUB_POST_SLEEP holds the POST open (seconds), so a test can start a second call while this one is in flight.
[ -z "${INTERCOM_STUB_POST_SLEEP:-}" ] || sleep "$INTERCOM_STUB_POST_SLEEP"
if [ -n "${INTERCOM_STUB_RESPONSE:-}" ]; then
  printf '%s' "$INTERCOM_STUB_RESPONSE"
  exit 0
fi
mt="$(printf '%s' "$payload" | jq -r '.message_type')"
if [ "$mt" = "note" ]; then pt="note"; else pt="comment"; fi
conv="${url##*/conversations/}"; conv="${conv%%/*}"
# The part just created is OURS (author = the pinned bot admin), created now, with a body: the delivery read-back
# accepts nothing less. The part before it is the customer's own, older, so it can never stand in for the send.
now="$(date +%s)"
# The body is what this call POSTed, stored the way Intercom stores text (stored_as_intercom): the read-back holds
# the POST's own response to the text too, so a fixed placeholder body would verify nothing.
stored_as_intercom | jq -Rsc --arg conv "$conv" --arg pt "$pt" --argjson now "$now" \
  '{type: "conversation", id: $conv, conversation_parts: {type: "conversation_part.list", total_count: 2, conversation_parts: [
     {type: "conversation_part", id: "52987726001", part_type: "comment", body: "<p>hello</p>", created_at: ($now - 3600),
      author: {type: "user", id: "6001"}},
     {type: "conversation_part", id: "52987726093", part_type: $pt, body: (. | rtrimstr("\n")), created_at: $now,
      author: {type: "admin", id: "5763097"}}]}}'
STUB
  chmod +x "$STUB_DIR/curl"
  # The wrapper replaces PATH on line 1, so the stub is handed over through the explicit
  # test seam rather than PATH-shadowing.
  export INTERCOM_OPS_TEST_CURL_BIN="$STUB_DIR/curl"
  INTERCOM_OPS_TEST_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)"
  export INTERCOM_OPS_TEST_TIMEOUT_BIN

  # The erasure register the gdpr-erasure purpose must find its conversation in. A real sqlite
  # file with the real table shape, because the ownership check is a real query: a stub would
  # certify a writer that cannot read the register it is supposed to be bounded by.
  export INTERCOM_OPS_TEST_GDPR_REGISTER="$TEST_TMPDIR/erasure.sqlite"
  sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
    'CREATE TABLE erasure_requests (id INTEGER PRIMARY KEY, conversation_id TEXT, status TEXT);' \
    'CREATE TABLE erasure_sends (id INTEGER PRIMARY KEY, request_id INTEGER, kind TEXT, channel TEXT, target TEXT, body_sha TEXT, state TEXT, consumed_at TEXT DEFAULT "");' \
    "INSERT INTO erasure_requests (id, conversation_id, status) VALUES (1, '215476650395415', 'open');" \
    "INSERT INTO erasure_requests (id, conversation_id, status) VALUES (2, '215476650395416', 'closed');"
}

# The pipeline claims a letter BEFORE it invokes the writer: a `sending` row carrying the
# conversation as its target and the sha256 of the exact approved bytes. A purpose write must
# match one, so every purpose test that expects a POST has to seed the claim it is posting.
claim_letter() {  # $1 conversation, $2 body, $3 request id (default 1), $4 state (default sending)
  local sha
  sha="$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
  sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
    "INSERT INTO erasure_sends (request_id, kind, channel, target, body_sha, state) VALUES (${3:-1}, 'ask', 'intercom', '$1', '$sha', '${4:-sending}');"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

payload() { cat "$CURL_STUB_PAYLOAD"; }
get_calls() { if [ -f "$CURL_STUB_LOG.get" ]; then wc -l < "$CURL_STUB_LOG.get" | tr -d ' '; else echo 0; fi; }
log_count() { find "$INTERCOM_OPS_TEST_LOG_DIR" -type f -name '*.json' | wc -l | tr -d ' '; }
curl_calls() { if [ -f "$CURL_STUB_LOG" ]; then wc -l < "$CURL_STUB_LOG" | tr -d ' '; else echo 0; fi; }

# --- the deployed artefact ---------------------------------------------------------

@test "the committed script is not in test mode" {
  grep -q '^readonly TESTABLE=0$' "$REAL_SCRIPT"
  [ "$(grep -cE '^[[:space:]]*(readonly[[:space:]]+)?TESTABLE=' "$REAL_SCRIPT")" -eq 1 ]
}

@test "a deployed copy refuses the test overrides" {
  run "$REAL_SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"INTERCOM_OPS_TEST_"* ]]
  unset INTERCOM_OPS_TEST_CURL_BIN INTERCOM_OPS_TEST_TIMEOUT_BIN
  run "$REAL_SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"INTERCOM_OPS_TEST_LOG_DIR"* ]]
}

# --- internal note: the default, and the header Nick asked for ---------------------

@test "a note posts message_type note as Caroline with the audience header" {
  run "$SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience Jan \
    --body "Profile is verified; data verification is open. Keep the conversation open."
  [ "$status" -eq 0 ]
  [[ "$output" == "POSTED note conversation=215475719661301 part=52987726093" ]]
  [ "$(payload | jq -r .message_type)" = "note" ]
  [ "$(payload | jq -r .type)" = "admin" ]
  [ "$(payload | jq -r .admin_id)" = "5763097" ]
  body="$(payload | jq -r .body)"
  [[ "$body" == "Note to Jan (internal Ops note, not visible to the customer). Requested in Slack by Jan."* ]]
  [[ "$body" == *"Keep the conversation open." ]]
  grep -q '^https://api.intercom.io/conversations/215475719661301/reply$' "$CURL_STUB_LOG"
}

@test "audience team and self render their own headers" {
  run "$SCRIPT" note --conversation 1 --requested-by U0AL36NADEY --audience team --body "x"
  [ "$status" -eq 0 ]
  [[ "$(payload | jq -r .body)" == "Note to team (internal Ops note"* ]]
  [[ "$(payload | jq -r .body)" == *"Requested in Slack by Nick."* ]]
  run "$SCRIPT" note --conversation 1 --requested-by U7RP6HKUZ --audience self --body "x"
  [ "$status" -eq 0 ]
  [[ "$(payload | jq -r .body)" == "Note to self (internal Ops note"* ]]
  [[ "$(payload | jq -r .body)" == *"Requested in Slack by Aaron."* ]]
}

@test "a note without an audience is refused" {
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--audience"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "the posting identity is Caroline even when INTERCOM_ADMIN_ID names a human" {
  export INTERCOM_ADMIN_ID="10206197"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [ "$(payload | jq -r .admin_id)" = "5763097" ]
}

@test "the body can come from a file" {
  printf 'line one\nline two\n' > "$TEST_TMPDIR/body.txt"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body-file "$TEST_TMPDIR/body.txt"
  [ "$status" -eq 0 ]
  [[ "$(payload | jq -r .body)" == *"line one"*"line two"* ]]
}

# --- write access: only the three allowlisted humans can request a write ----------

# --- the purpose class: a machine authorization, never a fourth human -----------------

@test "a purpose reply posts as a comment and logs the machine authorization, not a human" {
  claim_letter 215476650395415 "We have removed your profile from Muso."
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [[ "$output" == "POSTED comment conversation=215476650395415 part=52987726093" ]]
  [ "$(payload | jq -r .message_type)" = "comment" ]
  [ "$(payload | jq -r .admin_id)" = "5763097" ]
  log="$(find "$INTERCOM_OPS_TEST_LOG_DIR" -type f -name '*.json' | head -1)"
  [ "$(jq -r .approved_by "$log")" = "system:gdpr-pipeline" ]
  [ "$(jq -r .requester "$log")" = "system:gdpr-pipeline" ]
  [ "$(jq -r .purpose "$log")" = "gdpr-erasure" ]
  [[ "$(jq -r .authorization "$log")" == *"no human asked for this letter"* ]]
  # The whole point: the trail must not claim a human approved it.
  ! grep -qE 'U7RP6HKUZ|U038BM16T7W|U0AL36NADEY|explicitly approved' "$log"
}

@test "a purpose reply is refused when the bytes are not a letter the pipeline claimed" {
  # The hole QA found on the second review of #1820: ownership alone made this writer a
  # general-purpose customer-facing poster for anyone who can run it. The body must match a
  # `sending` row the pipeline wrote BEFORE invoking the writer.
  claim_letter 215476650395415 "the approved letter"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "arbitrary text nobody approved"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no letter the erasure pipeline has claimed matches these exact bytes"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "a purpose reply CONSUMES the claim, so a sequential replay cannot post the same letter twice" {
  # The finding this pins: a read-only "is there a sending row" check is not a claim. If the POST lands but the
  # pipeline has not yet recorded `sent`, a second invocation with the same conversation and bytes passed the same
  # check and posted a duplicate statutory letter. The check now consumes the claim in one conditional UPDATE.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  # The claim is now spent, and the ledger still says `sending` - the pipeline has not recorded `sent` yet, which is
  # exactly the window the replay used to slip through.
  [ "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT state FROM erasure_sends WHERE target='215476650395415'")" = "sending" ]
  [ -n "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 1 ]
  [[ "$output" == *"no letter the erasure pipeline has claimed matches these exact bytes"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a purpose reply is refused when the claim was already consumed, even if the state is still sending" {
  claim_letter 215476650395415 "We have removed your profile from Muso."
  sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
    "UPDATE erasure_sends SET consumed_at='2026-11-06T20:00:00Z' WHERE target='215476650395415';"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 1 ]
  [ "$(curl_calls)" -eq 0 ]
}

@test "two concurrent purpose replies post the letter exactly once" {
  # SQLite serialises writers, so of two overlapping invocations exactly one sees changes()=1. Without the atomic
  # consume both read the same `sending` row and both POST.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso." >"$TEST_TMPDIR/a.out" 2>&1 &
  local pa=$! sa=0 sb=0
  "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso." >"$TEST_TMPDIR/b.out" 2>&1 &
  local pb=$!
  # `local` resets $?, so capture each status in the same statement that waits.
  wait "$pa" || sa=$?
  wait "$pb" || sb=$?
  # Exactly one succeeded and exactly one POST happened.
  [ "$(( (sa == 0) + (sb == 0) ))" -eq 1 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "--validate and --dry-run do NOT consume the claim, so the real send still works" {
  # The finding this pins: the consume used to run inside the ownership check, which is called BEFORE the
  # no-write exits. A --validate on a valid claim therefore burned it, the real reply was then refused, and an
  # owed statutory letter silently never went out. The consume now runs after every no-write exit.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso." --validate
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 0 ]
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso." --dry-run
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 0 ]
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  # The claim survived both no-write modes, so the real letter still goes out exactly once.
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a preflight refusal does NOT consume the claim, so a corrected retry still works" {
  # A refusal is not a send. If the leak scan or a flag check refuses, the claim must survive so the pipeline's
  # next attempt (with corrected copy) is not blocked by a claim nobody spent.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --body "We have removed your profile from Muso."
  [ "$status" -eq 1 ]
  [[ "$output" == *"--customer-facing"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a purpose reply is refused when the claim is already sent, not sending" {
  claim_letter 215476650395415 "the approved letter" 1 sent
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "the approved letter"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no letter the erasure pipeline has claimed"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose reply is refused when the claim belongs to a closed request" {
  claim_letter 215476650395416 "the approved letter" 2
  run "$SCRIPT" reply --conversation 215476650395416 --purpose gdpr-erasure --customer-facing \
    --body "the approved letter"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an OPEN request in the erasure register"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose reply accepts --body-file, because the body is read before it is matched" {
  claim_letter 215476650395415 "a letter from a file"
  printf '%s' "a letter from a file" > "$TEST_TMPDIR/letter.txt"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body-file "$TEST_TMPDIR/letter.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == "POSTED comment conversation=215476650395415 part=52987726093" ]]
  [ "$(payload | jq -r .body)" = "a letter from a file" ]
}

@test "every purpose in the table has an ownership arm, so the table alone cannot widen the blast radius" {
  table="$(sed -n 's/^readonly PURPOSE_TABLE="\(.*\)"$/\1/p' "$REAL_SCRIPT")"
  [ -n "$table" ]
  arms="$(sed -n '/^purpose_owns_conversation()/,/^}/p' "$REAL_SCRIPT" | sed -n 's/^    \([a-z0-9-]*\))$/\1/p')"
  for p in $table; do
    [[ " $arms " == *" $p "* ]] || { echo "purpose '$p' has no ownership arm"; return 1; }
  done
}

@test "a purpose reply is refused for a conversation the register does not own" {
  run "$SCRIPT" reply --conversation 999999999 --purpose gdpr-erasure --customer-facing --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an OPEN request in the erasure register"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "a purpose reply is refused for a CLOSED request, so a finished thread cannot be written to" {
  # The register owns this conversation, but the request is finished. Counting it would let a caller with the
  # writer token post arbitrary customer-facing text to a closed request with no human approval and no live
  # statutory send - the hole QA found on PR #1820.
  run "$SCRIPT" reply --conversation 215476650395416 --purpose gdpr-erasure --customer-facing --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not an OPEN request in the erasure register"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "a purpose reply is refused when the register cannot be read" {
  export INTERCOM_OPS_TEST_GDPR_REGISTER="$TEST_TMPDIR/absent.sqlite"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not readable"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose reply is refused when the register has no erasure_requests table" {
  sqlite3 "$TEST_TMPDIR/empty.sqlite" 'CREATE TABLE unrelated (x);'
  export INTERCOM_OPS_TEST_GDPR_REGISTER="$TEST_TMPDIR/empty.sqlite"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not answer the ownership query"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose may not be combined with a human approver or requester" {
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --approved-by U7RP6HKUZ --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --requested-by U7RP6HKUZ --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "an unknown purpose is refused" {
  run "$SCRIPT" reply --conversation 215476650395415 --purpose refunds --customer-facing --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a purpose this writer knows"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose does not apply to an internal note" {
  run "$SCRIPT" note --conversation 215476650395415 --purpose gdpr-erasure --audience team --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"applies to 'reply' only"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a purpose reply still needs --customer-facing and still passes the leak scan" {
  # The claim is seeded so the ownership gate passes and these later gates are actually reached.
  claim_letter 215476650395415 "x"
  claim_letter 215476650395415 "see https://github.com/Muso-AI/hydra/issues/1"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--customer-facing"* ]]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "see https://github.com/Muso-AI/hydra/issues/1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"internal surfaces"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a requester outside the write allowlist is refused" {
  run "$SCRIPT" note --conversation 1 --requested-by U0ANK0VS75F --audience team --body "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"write allowlist"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "a requester that is not a Slack user id is refused" {
  run "$SCRIPT" note --conversation 1 --requested-by "Jan" --audience team --body "x"
  [ "$status" -eq 1 ]
  [ "$(curl_calls)" -eq 0 ]
}

# --- customer-facing reply: explicit, approved, and clean ---------------------------

@test "a reply without --customer-facing is refused" {
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --approved-by U038BM16T7W --body "Hi Johannes, thanks for your patience."
  [ "$status" -eq 1 ]
  [[ "$output" == *"--customer-facing"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a reply without --approved-by is refused" {
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --body "Hi Johannes, thanks for your patience."
  [ "$status" -eq 1 ]
  [[ "$output" == *"--approved-by"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a reply approved by god_mode or self is refused" {
  for a in god_mode god_mode_self_approve self operations; do
    run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by "$a" --body "Hi Johannes."
    [ "$status" -eq 1 ]
    [[ "$output" == *"human"* ]]
  done
  [ "$(curl_calls)" -eq 0 ]
}

@test "a reply approved by a non-allowlisted user id is refused" {
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0ANK0VS75F --body "Hi Johannes."
  [ "$status" -eq 1 ]
  [ "$(curl_calls)" -eq 0 ]
}

@test "an approved reply posts message_type comment as Caroline with no header" {
  run "$SCRIPT" reply --conversation 215475719661301 --requested-by U038BM16T7W --customer-facing --approved-by U038BM16T7W \
    --body "Hi Johannes, thanks for your patience. Our team is reviewing the missing milestones and will follow up within 2 business days."
  [ "$status" -eq 0 ]
  [[ "$output" == "POSTED comment conversation=215475719661301 part=52987726093" ]]
  [ "$(payload | jq -r .message_type)" = "comment" ]
  [ "$(payload | jq -r .admin_id)" = "5763097" ]
  [[ "$(payload | jq -r .body)" == "Hi Johannes,"* ]]
  [[ "$(payload | jq -r .body)" != *"Note to"* ]]
}

@test "a customer-facing body that leaks internals is refused" {
  for bad in \
    "See https://github.com/Muso-AI/platform-data-processing/issues/2405 for status." \
    "Ops resolution: profile verified." \
    "I filed a ticket with the team." \
    "Our tool failed on the first try, sorry." \
    "I ran profile_status for you." \
    "Tracked on #2405." \
    "Your verification is open on issue 2405." \
    "Both are tracked under issues 2405 and 2406." \
    "Ask <@U038BM16T7W> for details." \
    "The admin id on this thread is fine."; do
    run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U038BM16T7W --body "$bad"
    [ "$status" -eq 1 ]
    [[ "$output" == *"internal"* ]]
  done
  [ "$(curl_calls)" -eq 0 ]
}

@test "words the sanitizer does not redact are not refused in a customer reply" {
  # Caroline's SOUL bans "error"/"system" by prose and says "API" is fine; the sanitizer
  # (plugins/intercom/src/sanitize-tool-leak.ts) redacts none of them. Refusing them here
  # blocked an approved reply for saying "error" while the wrapper claimed to mirror the code.
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U038BM16T7W \
    --body "Sorry for the error on our side; our system has re-synced your profile and the API now shows it."
  [ "$status" -eq 0 ]
}

@test "the same wording is fine in an internal note" {
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience Jan \
    --body "Ops resolution: see https://github.com/Muso-AI/platform-data-processing/issues/2405#issuecomment-5498235228, ticket open."
  [ "$status" -eq 0 ]
}

# --- the write is logged before it happens, and verified after ----------------------

@test "the api-log is written before the POST and names the requester" {
  run "$SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  f="$(find "$INTERCOM_OPS_TEST_LOG_DIR" -type f -name 'intercom-note-215475719661301-*.json')"
  [ -n "$f" ]
  [ "$(jq -r .agent "$f")" = "operations" ]
  [ "$(jq -r .action "$f")" = "intercom_internal_note" ]
  [ "$(jq -r .target "$f")" = "conversation:215475719661301" ]
  [ "$(jq -r .requester "$f")" = "U038BM16T7W" ]
  [ "$(jq -r .audience "$f")" = "team" ]
  # Written BEFORE the POST: the log's mtime must not be after the curl stub's payload file.
  [ ! "$f" -nt "$CURL_STUB_PAYLOAD" ]
}

@test "a customer reply is logged with its approver" {
  run "$SCRIPT" reply --conversation 7 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "Hi there."
  [ "$status" -eq 0 ]
  f="$(find "$INTERCOM_OPS_TEST_LOG_DIR" -type f -name 'intercom-reply-7-*.json')"
  [ -n "$f" ]
  [ "$(jq -r .action "$f")" = "intercom_customer_reply" ]
  [ "$(jq -r .approved_by "$f")" = "U0AL36NADEY" ]
}

@test "a response whose last part_type does not match the intent exits 4" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[{"type":"conversation_part","id":"9","part_type":"comment"}]}}'
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" == *"part_type"* ]]
  [[ "$output" != *"POSTED"* ]]
}

@test "a bare conversation_part response (a shape the API never sends) is not accepted as verified" {
  # Guards the stub-fidelity trap: the first draft read a top-level part_type and its stub
  # answered one, so CI was green while every real write would have exited 4.
  export INTERCOM_STUB_RESPONSE='{"type":"conversation_part","id":"1","part_type":"note"}'
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "the printed part id is the created part, not the conversation id" {
  run "$SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=52987726093" ]]
  [[ "$output" != *"part=215475719661301"* ]]
}

# --- the delivery read-back: what counts as "this POST landed" -------------------------
# node-8 ran this predicate by hand from 2026-11-09 (a reply to a CLOSED conversation comes back as a part of
# type "open" carrying our body, and the old last-part check recorded that delivered letter as rc 4).

# <part_type> <author id> <created_at offset in s> <body> [more parts as raw JSON, comma-led]
# A note with --body "x" asked for by Jan (U038BM16T7W), the way Intercom stores it: the wrapper's own header line,
# then the body, a <p> each. The read-back holds every part to the text this call sent, so a test about the part's
# type, author, age or id must hand it THIS text - with a placeholder body it would pass on the text alone.
NOTE_X='<p>Note to team (internal Ops note, not visible to the customer). Requested in Slack by Jan.</p><p>x</p>'

_conv_with_part() {
  local now; now="$(date +%s)"
  printf '{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[{"type":"conversation_part","id":"777","part_type":"%s","body":"%s","created_at":%s,"author":{"type":"admin","id":"%s"}}%s]}}' \
    "$1" "$4" "$((now + $3))" "$2" "${5:-}"
}

@test "a reply to a CLOSED conversation is verified by our reopen part that carries the body" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part open 5763097 0 '<p>your letter</p>')"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"POSTED comment conversation=1 part=777" ]]
}

@test "a reopen part never verifies a NOTE" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part open 5763097 0 "$NOTE_X")"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "a bare reopen with an empty body is not a delivery" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part open 5763097 0 '<p> </p>')"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
}

@test "a part written by anyone but the pinned bot admin never verifies a send" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 10206197 0 "$NOTE_X")"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "a part created before the POST is an earlier attempt's, not evidence of this one" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 5763097 -600 "$NOTE_X")"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "two qualifying parts is a duplicate a person must see, never a pick of one" {
  local now; now="$(date +%s)"
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 5763097 0 "$NOTE_X" ",{\"type\":\"conversation_part\",\"id\":\"778\",\"part_type\":\"note\",\"body\":\"$NOTE_X\",\"created_at\":$now,\"author\":{\"type\":\"admin\",\"id\":\"5763097\"}}")"
  export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" == *"2 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
}

@test "a 2xx whose body shows no qualifying part is settled by ONE re-read under the same rule" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  export INTERCOM_STUB_REFETCH_STORED=1
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
  # two reads: the pre-read before the write, and exactly one re-read after it
  [ "$(get_calls)" -eq 2 ]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a verified write makes one pre-read and no re-read" {
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [ "$(get_calls)" -eq 1 ]
  [ "$(curl_calls)" -eq 1 ]
}

# --- the pre-read: a part already on file can never verify this write (QA review of #1929) ---------------
# The read-back's window opens 10 s before the POST (clock difference with Intercom). Caroline answers live
# under the same admin id, so a part of hers written seconds earlier sat inside that window with a body, and
# the re-read after a POST that created nothing picked it up and printed POSTED.
# In each case below the earlier part carries the SAME words this call sends (a canned letter sent twice is the
# same bytes), so its text matches and only the pre-read keeps it from verifying the write.

@test "a bot part written 2 s earlier does not verify a POST that returned an error (QA #1929 finding 1)" {
  INTERCOM_STUB_PREREAD="$(_conv_with_part comment 5763097 -2 '<p>your letter</p>')"; export INTERCOM_STUB_PREREAD
  export INTERCOM_STUB_RESPONSE='{"type":"error.list","errors":[{"code":"server_error","message":"Server Error"}]}'
  export INTERCOM_STUB_REFETCH="$INTERCOM_STUB_PREREAD"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a bot part written 2 s earlier does not verify a part-less 2xx either" {
  INTERCOM_STUB_PREREAD="$(_conv_with_part note 5763097 -2 "$NOTE_X")"; export INTERCOM_STUB_PREREAD
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  export INTERCOM_STUB_REFETCH="$INTERCOM_STUB_PREREAD"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "a part on file before the write is excluded even when the POST response repeats it" {
  INTERCOM_STUB_PREREAD="$(_conv_with_part note 5763097 -2 "$NOTE_X")"; export INTERCOM_STUB_PREREAD
  export INTERCOM_STUB_RESPONSE="$INTERCOM_STUB_PREREAD"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "with an earlier bot part on file, the part this write created is the one reported" {
  local now; now="$(date +%s)"
  INTERCOM_STUB_PREREAD="$(_conv_with_part note 5763097 -2 "$NOTE_X")"; export INTERCOM_STUB_PREREAD
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 5763097 -2 "$NOTE_X" ",{\"type\":\"conversation_part\",\"id\":\"778\",\"part_type\":\"note\",\"body\":\"$NOTE_X\",\"created_at\":$now,\"author\":{\"type\":\"admin\",\"id\":\"5763097\"}}")"
  export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=778" ]]
}

@test "a conversation that cannot be read before the write stops BEFORE the log, the claim and the POST" {
  claim_letter 215476650395415 "We have removed your profile from Muso."
  export INTERCOM_STUB_PREREAD_RC=28
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  # exit 2 + ERROR: is what send.WRITER_PREFLIGHT_RC reads as provably pre-send (retryable), never `unknown`
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: conversation 215476650395415 could not be read before the write"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
}

@test "a pre-read that answers anything but a conversation (an error body) stops the write the same way" {
  export INTERCOM_STUB_PREREAD='{"type":"error.list","errors":[{"code":"not_found","message":"Resource Not Found"}]}'
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not be read before the write"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "the pre-read is ordered BEFORE the audit record, so a failed read logs and spends nothing" {
  pre_line="$(grep -n '^PRE_READ=' "$SCRIPT" | head -1 | cut -d: -f1)"
  log_dir_line="$(grep -n 'mkdir -p "$LOG_DIR"' "$SCRIPT" | head -1 | cut -d: -f1)"
  consume_line="$(grep -n 'purpose_consume_claim "$PURPOSE" "$CONVERSATION"' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$pre_line" ] && [ -n "$log_dir_line" ] && [ -n "$consume_line" ]
  [ "$pre_line" -lt "$log_dir_line" ]
  [ "$pre_line" -lt "$consume_line" ]
}

@test "the re-read is held to the same lower bound: an older part of ours does not verify" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 -600 '<p>x</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
  # the same part, created now, does verify: the time was the only thing wrong with it
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>x</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

# --- the re-read is tied to the text this call sent (QA review of #1929, second round) -------------------
# The re-read shows whatever the conversation holds. Caroline and every other caller of this script write under
# the same admin id, so a part one of them adds AFTER the pre-read is new, ours by author and inside the window.
# Without a tie to this request it verified a POST that created nothing.

@test "another writer's part added after the pre-read does not verify a POST that returned an error (QA #1929 round 2)" {
  export INTERCOM_STUB_RESPONSE='{"type":"error.list","errors":[{"code":"server_error","message":"Server Error"}]}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>Caroline, answering the customer live</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "another writer's part added after the pre-read does not verify a part-less 2xx either" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part note 5763097 0 '<p>a different note, by another caller</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
}

@test "a re-read that holds another writer's part AND ours reports ours" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  export INTERCOM_STUB_REFETCH_STORED=1
  export INTERCOM_STUB_REFETCH_EXTRA=",{\"type\":\"conversation_part\",\"id\":\"778\",\"part_type\":\"comment\",\"body\":\"<p>Caroline, answering live</p>\",\"created_at\":$(date +%s),\"author\":{\"type\":\"admin\",\"id\":\"5763097\"}}"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "a re-read part whose text is not the text sent does not verify, however close" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>your letter, with one more line</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

# --- word boundaries are part of the text (QA review of #1929, third round) -------------------------------
# With ALL white space removed, "now here" and another writer's "no where" were one text ("nowhere"), so that
# other part verified a POST that created nothing. A run of white space is one space; it is never nothing.

@test "another writer's part that differs only in where the words break does not verify an error POST (QA #1929 round 3)" {
  export INTERCOM_STUB_RESPONSE='{"type":"error.list","errors":[{"code":"server_error","message":"Server Error"}]}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>no where</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "now here"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "another writer's part that differs only in where the words break does not verify a part-less 2xx" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>no where</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "now here"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
  # the same re-read with the words where this call put them does verify: the break was the only difference
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>now here</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "now here"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "two lines are not one run of letters: a part that joins them does not verify" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>thank youall done</p>')"; export INTERCOM_STUB_REFETCH
  body="$(printf 'thank you\nall done')"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "$body"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
  # stored the way Intercom stores two lines (a block per line), it is this call's text
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>thank you</p><p>all   done</p>')"; export INTERCOM_STUB_REFETCH
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "a tag inside a line (a link Intercom makes of an address) adds no space; a tag that ends a block does" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  INTERCOM_STUB_REFETCH="$(_conv_with_part comment 5763097 0 '<p>Open <a href=\"https://muso.ai/x\" target=\"_blank\">https://muso.ai/x</a>.<br>Then <b>reply</b>.</p>')"; export INTERCOM_STUB_REFETCH
  body="$(printf 'Open https://muso.ai/x.\nThen reply.')"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "the re-read matches a letter the way Intercom stores it: tags, escaped & < >, a numbered list" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  export INTERCOM_STUB_REFETCH_STORED=1
  body="$(printf 'Hi,\n\nTwo ways to finish:\n1. Sign in & open your page\n2. Reply here with <the title>\n\nMuso Support')"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "a reply to a CLOSED conversation is verified on the re-read by the reopen part that carries the text" {
  export INTERCOM_STUB_RESPONSE='{"type":"conversation","id":"1","conversation_parts":{"conversation_parts":[]}}'
  export INTERCOM_STUB_REFETCH_STORED=1 INTERCOM_STUB_REFETCH_STORED_TYPE=open
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

# --- one write per conversation at a time (QA review of #1929, fourth round) ------------------------------
# Text ties a part to a call, and text cannot tell two calls apart when both send the same words (a canned
# letter is the same bytes every time). Every caller of this script takes a per-conversation lock before it
# reads, logs, claims or posts, so a second call cannot start until the first has finished its read-back - and
# by then the first call's part is on file at the second's pre-read (the cases above).

_wait_locked() {  # $1 lock file: returns once somebody holds it (5 s at most)
  local _
  for _ in $(seq 1 100); do
    if [ -e "$1" ] && ! flock -n "$1" true 2>/dev/null; then return 0; fi
    sleep 0.05
  done
  return 1
}

@test "two calls with the same words in flight: the second reads, logs, claims and posts nothing (exit 2)" {
  local lock="$INTERCOM_OPS_TEST_LOCK_DIR/conversation-1.lock"
  # the first call's POST stays open for 8 s; it holds the lock from before its pre-read to its exit
  INTERCOM_STUB_POST_SLEEP=8 "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing \
    --approved-by U0AL36NADEY --body "your letter" > "$TEST_TMPDIR/first.out" 2>&1 3>&- &
  local first=$!
  _wait_locked "$lock"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: another write to conversation 1 is in flight"* ]]
  [[ "$output" != *"POSTED"* ]]
  wait "$first"
  grep -q '^POSTED comment conversation=1 part=52987726093$' "$TEST_TMPDIR/first.out"
  # one POST, one audit record, one read (the first call's pre-read): the second call did none of the three
  [ "$(curl_calls)" -eq 1 ]
  [ "$(log_count)" -eq 1 ]
  [ "$(get_calls)" -eq 1 ]
  # the lock went with the first call: the same write now runs
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
}

@test "a held lock stops a purpose write BEFORE its claim is spent, and only for that conversation" {
  local lock="$INTERCOM_OPS_TEST_LOCK_DIR/conversation-215476650395415.lock"
  mkdir -p "$INTERCOM_OPS_TEST_LOCK_DIR"
  flock "$lock" sleep 6 3>&- &
  local holder=$!
  _wait_locked "$lock"
  claim_letter 215476650395415 "We have removed your profile from Muso."
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  # exit 2 + ERROR: is what send.WRITER_PREFLIGHT_RC reads as provably pre-send (retryable), never `unknown`
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: another write to conversation 215476650395415 is in flight"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(get_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  # another conversation is not held up by it
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  kill "$holder" 2>/dev/null || true
}

@test "a lock directory that cannot be used stops the write before anything is read or posted" {
  export INTERCOM_OPS_TEST_LOCK_DIR="$TEST_TMPDIR/not-a-dir"
  : > "$INTERCOM_OPS_TEST_LOCK_DIR"   # a FILE where the dir should be
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: the write lock"* ]]
  [ "$(get_calls)" -eq 0 ]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
  # a symlink is refused too: the lock must be the directory every other caller uses, not where a link points
  rm -f "$INTERCOM_OPS_TEST_LOCK_DIR"
  mkdir -p "$TEST_TMPDIR/elsewhere"
  ln -s "$TEST_TMPDIR/elsewhere" "$INTERCOM_OPS_TEST_LOCK_DIR"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: the write lock directory"* ]]
  [ "$(curl_calls)" -eq 0 ]
}

@test "the lock is taken BEFORE the pre-read, and a deployed copy takes it under /run/lock for 20 s, no override" {
  lock_line="$(grep -n '"\$FLOCK_BIN" -w "\$LOCK_WAIT_S" 9' "$SCRIPT" | head -1 | cut -d: -f1)"
  pre_line="$(grep -n '^PRE_READ=' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$lock_line" ] && [ -n "$pre_line" ]
  [ "$lock_line" -lt "$pre_line" ]
  grep -q '^readonly PROD_LOCK_DIR="/run/lock/hydra-intercom-ops-write"$' "$REAL_SCRIPT"
  grep -q '^readonly PROD_LOCK_WAIT_S=20$' "$REAL_SCRIPT"
  unset INTERCOM_OPS_TEST_LOG_DIR INTERCOM_OPS_TEST_CURL_BIN INTERCOM_OPS_TEST_TIMEOUT_BIN INTERCOM_OPS_TEST_LOCK_WAIT_S
  run "$REAL_SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"INTERCOM_OPS_TEST_LOCK_DIR is not settable"* ]]
  unset INTERCOM_OPS_TEST_LOCK_DIR
  export INTERCOM_OPS_TEST_LOCK_WAIT_S=0
  run "$REAL_SCRIPT" note --conversation 215475719661301 --requested-by U038BM16T7W --audience team --body "x" --validate
  [ "$status" -eq 2 ]
  [[ "$output" == *"INTERCOM_OPS_TEST_LOCK_WAIT_S is not settable"* ]]
}

# --- the POST's own response is held to the text too (QA review of #1929, fourth round) -------------------
# Intercom answers a reply with the FULL conversation, not with the part it made. A 2xx that created nothing
# for this call, while another writer added a part under the same admin id after the pre-read, shows that
# part alone - and a response read without the text verified it.

@test "a 2xx response that holds only another writer's part does not verify this call (QA #1929 round 4)" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part comment 5763097 0 '<p>Caroline, answering the customer live</p>')"; export INTERCOM_STUB_RESPONSE
  export INTERCOM_STUB_REFETCH="$INTERCOM_STUB_RESPONSE"
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 qualifying part(s)"* ]]
  [[ "$output" != *"POSTED"* ]]
  [ "$(curl_calls)" -eq 1 ]
  # the same response with this call's words in that part does verify: the text was the only difference
  INTERCOM_STUB_RESPONSE="$(_conv_with_part comment 5763097 0 '<p>your letter</p>')"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "a 2xx response that holds another writer's NOTE alone does not verify a note" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 5763097 0 '<p>a different note, by another caller</p>')"; export INTERCOM_STUB_RESPONSE
  export INTERCOM_STUB_REFETCH="$INTERCOM_STUB_RESPONSE"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" != *"POSTED"* ]]
}

@test "a response that holds this call's part AND another writer's reports this call's, not a duplicate" {
  local now; now="$(date +%s)"
  INTERCOM_STUB_RESPONSE="$(_conv_with_part comment 5763097 0 '<p>Caroline, answering live</p>' ",{\"type\":\"conversation_part\",\"id\":\"778\",\"part_type\":\"comment\",\"body\":\"<p>your letter</p>\",\"created_at\":$now,\"author\":{\"type\":\"admin\",\"id\":\"5763097\"}}")"
  export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U0AL36NADEY --body "your letter"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=778" ]]
  [ "$(get_calls)" -eq 1 ]
}

@test "a note part of ours, created now, that carries the note as stored verifies (control for the cases above)" {
  INTERCOM_STUB_RESPONSE="$(_conv_with_part note 5763097 0 "$NOTE_X")"; export INTERCOM_STUB_RESPONSE
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part=777" ]]
}

@test "an Intercom error response exits 4 and never prints POSTED" {
  export INTERCOM_STUB_RESPONSE='{"type":"error.list","errors":[{"code":"unauthorized","message":"Access Token Invalid"}]}'
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 4 ]
  [[ "$output" == *"Access Token Invalid"* ]]
  [[ "$output" != *"POSTED"* ]]
}

# --- validate / dry-run never touch the network or the log --------------------------

@test "--dry-run renders the payload and posts nothing" {
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience Jan --body "x" --dry-run
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "DRY-RUN note conversation=1" ]]
  rendered="$(printf '%s\n' "${lines[@]:1}")"
  [ "$(printf '%s' "$rendered" | jq -r .message_type)" = "note" ]
  [[ "$(printf '%s' "$rendered" | jq -r .body)" == "Note to Jan"* ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

@test "--validate checks and posts nothing" {
  run "$SCRIPT" reply --conversation 1 --requested-by U038BM16T7W --customer-facing --approved-by U038BM16T7W --body "Hi." --validate
  [ "$status" -eq 0 ]
  [[ "$output" == "VALID comment conversation=1" ]]
  [ "$(curl_calls)" -eq 0 ]
  [ "$(log_count)" -eq 0 ]
}

# --- shape --------------------------------------------------------------------------

@test "a flag with no value is a usage error with a message, not a silent exit 1" {
  # A bare `shift 2` past the end of argv exits 1 under set -e with NO output, which the
  # agent would read as a refusal (exit 1 is the refusal code).
  for flag in --conversation --requested-by --audience --approved-by --body --body-file; do
    run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body x "$flag"
    [ "$status" -eq 2 ]
    [[ "$output" == *"$flag needs a value"* ]]
  done
  [ "$(curl_calls)" -eq 0 ]
}

@test "a missing log dir is created, not a refusal; an uncreatable one is a usage error" {
  rm -rf "$INTERCOM_OPS_TEST_LOG_DIR"
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 0 ]
  [ "$(log_count)" -eq 1 ]
  rm -rf "$INTERCOM_OPS_TEST_LOG_DIR"
  : > "$INTERCOM_OPS_TEST_LOG_DIR"   # a FILE where the dir should be: mkdir -p must fail
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to write unlogged"* ]]
  [ "$(curl_calls)" -eq 1 ]
}

@test "a large multi-line body is not refused as empty" {
  # ~216KB, above Linux's 128KB single-argv cap (MAX_ARG_STRLEN): the body must reach jq and
  # curl through stdin, or this passes on a Mac and fails on node-8.
  { printf 'line\n'; for _ in $(seq 1 8000); do printf 'lorem ipsum dolor sit amet\n'; done; } > "$TEST_TMPDIR/big.txt"
  [ "$(wc -c < "$TEST_TMPDIR/big.txt")" -gt 131072 ]
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body-file "$TEST_TMPDIR/big.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == POSTED* ]]
  [ "$(payload | jq -r '.body | length')" -gt 131072 ]
}

@test "a missing token is a usage error, not a refusal" {
  unset MUSOAI_INTERCOM_TOKEN
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"MUSOAI_INTERCOM_TOKEN"* ]]
}

@test "a non-numeric conversation id, an empty body and an unknown subcommand are refused" {
  run "$SCRIPT" note --conversation abc --requested-by U038BM16T7W --audience team --body "x"
  [ "$status" -eq 1 ]
  run "$SCRIPT" note --conversation 1 --requested-by U038BM16T7W --audience team --body "   "
  [ "$status" -eq 1 ]
  run "$SCRIPT" close --conversation 1 --requested-by U038BM16T7W
  [ "$status" -eq 2 ]
  [ "$(curl_calls)" -eq 0 ]
}

@test "a FAILED audit-record write leaves the claim intact, so the letter is retryable (QA #1820)" {
  # The finding this pins: the purpose path used to consume the claim BEFORE building/writing its audit
  # record. Every way that block fails - an unwritable dir, a jq that cannot build the JSON, a full disk -
  # exits 1 through `set -e` ABOVE the POST. `_intercom_send` cannot tell a bare 1 from a dropped
  # connection, so it reads Ambiguous, `deliver` records `unknown`, and `unknown` is the never-retried
  # state: a statutory letter nobody received is stranded forever.
  #
  # A read-only log dir reproduces it exactly - mkdir -p succeeds on an existing dir, and the `>` onto
  # "$LOG_FILE" fails with a bare 1, which is the disk-full shape QA named.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  chmod 500 "$INTERCOM_OPS_TEST_LOG_DIR"
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  chmod 700 "$INTERCOM_OPS_TEST_LOG_DIR"
  # EXIT 2 WITH AN `ERROR:` PREFIX, not a bare 1. `send.WRITER_PREFLIGHT_RC` maps 2 to `ERROR:`, which is what makes
  # `deliver` record `failed` (retryable) instead of `unknown` (never retried). A bare 1 is indistinguishable from a
  # dropped connection after a POST, so the letter would still be stranded even with its claim intact (QA #1820).
  [ "$status" -eq 2 ]
  # `ERROR:` must be on its own line: bash prints the redirection diagnostic first, so the line that matters is the
  # writer's, and `send._intercom_send` matches the prefix per line for exactly that reason.
  [[ "$output" == *"ERROR: cannot write the audit record"* ]]
  [[ "$output" == *"refusing to write unlogged"* ]]
  [ "$(curl_calls)" -eq 0 ]
  # THE ASSERTION THAT MATTERS: nothing was posted AND the claim was not burned.
  [ -z "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
  [ "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT state FROM erasure_sends WHERE target='215476650395415'")" = "sending" ]
  # And the retry works, which is the whole point of leaving the claim intact.
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [[ "$output" == POSTED* ]]
  [ "$(curl_calls)" -eq 1 ]
  [ -n "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" "SELECT consumed_at FROM erasure_sends WHERE target='215476650395415'")" ]
}

@test "one POST consumes exactly ONE claim, so two requests on one conversation both keep a letter" {
  # QA #1820: the consume matched conversation + body hash, not a row, and accepted any positive changes(). Two
  # open requests sharing a conversation with identical copy therefore had BOTH claims consumed by one invocation
  # while only one reply was posted - the second letter was left `sending` with its claim spent and could never go
  # out. Exactly one claim per POST is the invariant.
  claim_letter 215476650395415 "We have removed your profile from Muso."
  # A SECOND open request for the same conversation, carrying a claim for the SAME approved bytes.
  sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
    "INSERT INTO erasure_requests (id, conversation_id, status) VALUES (3, '215476650395415', 'open');"
  claim_letter 215476650395415 "We have removed your profile from Muso." 3
  [ "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
      "SELECT count(*) FROM erasure_sends WHERE target='215476650395415' AND consumed_at=''")" -eq 2 ]
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 1 ]
  # EXACTLY ONE consumed. Not two: the second request still owns an unspent claim and can still be sent.
  [ "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
      "SELECT count(*) FROM erasure_sends WHERE target='215476650395415' AND consumed_at=''")" -eq 1 ]
  # And the second letter can go out, which is the point of not spending its claim.
  run "$SCRIPT" reply --conversation 215476650395415 --purpose gdpr-erasure --customer-facing \
    --body "We have removed your profile from Muso."
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" -eq 2 ]
  [ "$(sqlite3 "$INTERCOM_OPS_TEST_GDPR_REGISTER" \
      "SELECT count(*) FROM erasure_sends WHERE target='215476650395415' AND consumed_at=''")" -eq 0 ]
}

@test "the consume is ordered AFTER the audit record and immediately BEFORE the POST" {
  # A structural guard, because the bug above is an ORDERING bug and an ordering bug is invisible to a
  # test that only exercises the happy path. This fails if anyone moves the consume back above the log
  # write (stranding letters on a failed record) or below the POST (allowing a replayed letter).
  log_dir_line="$(grep -n 'mkdir -p "$LOG_DIR"' "$SCRIPT" | head -1 | cut -d: -f1)"
  log_file_line="$(grep -n '> "$LOG_FILE"' "$SCRIPT" | head -1 | cut -d: -f1)"
  consume_line="$(grep -n 'purpose_consume_claim "$PURPOSE" "$CONVERSATION"' "$SCRIPT" | head -1 | cut -d: -f1)"
  post_line="$(grep -n -- '--data @-' "$SCRIPT" | head -1 | cut -d: -f1)"
  [ -n "$log_dir_line" ] && [ -n "$log_file_line" ] && [ -n "$consume_line" ] && [ -n "$post_line" ]
  [ "$log_dir_line" -lt "$log_file_line" ]
  [ "$log_file_line" -lt "$consume_line" ]
  [ "$consume_line" -lt "$post_line" ]
}

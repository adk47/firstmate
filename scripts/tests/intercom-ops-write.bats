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
while [ $# -gt 0 ]; do
  case "$1" in
    --data|-d) if [ "$2" = "@-" ]; then payload="$(cat)"; else payload="$2"; fi; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "$CURL_STUB_LOG"
printf '%s' "$payload" > "$CURL_STUB_PAYLOAD"
if [ -n "${INTERCOM_STUB_RESPONSE:-}" ]; then
  printf '%s' "$INTERCOM_STUB_RESPONSE"
  exit 0
fi
mt="$(printf '%s' "$payload" | jq -r '.message_type')"
if [ "$mt" = "note" ]; then pt="note"; else pt="comment"; fi
conv="${url##*/conversations/}"; conv="${conv%%/*}"
printf '{"type":"conversation","id":"%s","conversation_parts":{"type":"conversation_part.list","conversation_parts":[{"type":"conversation_part","id":"52987726001","part_type":"comment"},{"type":"conversation_part","id":"52987726093","part_type":"%s"}],"total_count":2}}' "$conv" "$pt"
STUB
  chmod +x "$STUB_DIR/curl"
  # The wrapper replaces PATH on line 1, so the stub is handed over through the explicit
  # test seam rather than PATH-shadowing.
  export INTERCOM_OPS_TEST_CURL_BIN="$STUB_DIR/curl"
  INTERCOM_OPS_TEST_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout)"
  export INTERCOM_OPS_TEST_TIMEOUT_BIN
}

teardown() { rm -rf "$TEST_TMPDIR"; }

payload() { cat "$CURL_STUB_PAYLOAD"; }
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

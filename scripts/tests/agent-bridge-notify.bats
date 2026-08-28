#!/usr/bin/env bats
# Tests for scripts/agent-bridge-notify.sh — the gate on the REAL-TIME bridge lane.
#
# This wrapper exists because the alternative was a documented `curl`: read a
# cluster-wide Centrifugo publish key into the agent's shell and let it compose the body.
# That key can write to ANY channel — including `ticker:*`, the live customer nowcast bus
# — and can forge any `from` value, so a single wrong field is a production incident under
# a forged sender. These tests are what make the wrapper a gate rather than a convenience:
# the channel cannot be chosen, the mailbox must already carry the escalation, and
# customer data cannot ride the lane.
#
# Hermetic: kubectl and curl are PATH-shadowed by stubs, gh is stubbed, no network.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
REAL_SCRIPT="$HYDRA_REPO/scripts/agent-bridge-notify.sh"

RID="cs-2026-08-26-escalate-credits-vanishing"
SUM="6 customers today vs 1 yesterday report credits vanishing from claimed profiles"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  # Run a DERIVED copy with the build-time TESTABLE literal flipped. The deployed file is
  # always TESTABLE=0 and refuses every override; making the test backend a property of the
  # ARTEFACT rather than the environment is what stops a caller selecting it in production.
  sed 's/^readonly TESTABLE=0$/readonly TESTABLE=1/' "$REAL_SCRIPT" > "$TEST_TMPDIR/under-test.sh"
  chmod +x "$TEST_TMPDIR/under-test.sh"
  SCRIPT="$TEST_TMPDIR/under-test.sh"
  export AGENT_BRIDGE_REPO="Muso-AI/test-repo"
  export AGENT_BRIDGE_ISSUE="9999"

  STUB_DIR="$TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"

  export GH_STUB_COMMENTS="$TEST_TMPDIR/comments.txt"
  # By default the mailbox already carries the escalation.
  echo "<!-- agent-bridge request_id=$RID type=escalation from=operations -->" > "$GH_STUB_COMMENTS"
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view") cat "$GH_STUB_COMMENTS" ;;
  *) exit 1 ;;
esac
STUB

  cat > "$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
# get svc <name> -o jsonpath=... | get secret <name> -o jsonpath=...
for a in "$@"; do
  case "$a" in
    svc|service) echo "10.43.0.99"; exit 0 ;;
    secret)      printf 'c3R1Yi1hcGkta2V5'; exit 0 ;;   # base64 "stub-api-key"
  esac
done
exit 1
STUB

  export CURL_STUB_LOG="$TEST_TMPDIR/curl.log"
  export CURL_STUB_BODY='{"result":{}}'
  export CURL_STUB_STDIN="$TEST_TMPDIR/curl.stdin"
  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_STUB_LOG"
cat >> "$CURL_STUB_STDIN" 2>/dev/null || true
printf '%s' "$CURL_STUB_BODY"
STUB

  chmod +x "$STUB_DIR"/*
  export GH_BIN="$STUB_DIR/gh"
  export KUBECTL_BIN="$STUB_DIR/kubectl"
  export CURL_BIN="$STUB_DIR/curl"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# ------------------------------------------------------------- happy path --

@test "an escalation already on the mailbox publishes" {
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLISHED"* ]]
}

@test "the published payload is built here, on the hard-coded channel" {
  run "$SCRIPT" --request-id "$RID" --summary "$SUM" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"channel": "agent:pdp"'* ]]
  [[ "$output" == *'"kind": "escalation"'* ]]
  [[ "$output" == *"$RID"* ]]
}

@test "dry-run never reaches the publish API" {
  run "$SCRIPT" --request-id "$RID" --summary "$SUM" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

# ------------------------------------------------- the channel is not a knob --

@test "there is no way to choose a channel" {
  # The whole point: `ticker:*` must be unreachable from this path, and it is unreachable
  # because the argument does not exist rather than because a check rejects the value.
  run "$SCRIPT" --request-id "$RID" --summary "$SUM" --channel "ticker:abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "ticker never appears in the published payload" {
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  run grep -c "ticker" "$CURL_STUB_LOG"
  [ "$output" = "0" ]
}

# --------------------------------------------------------- mailbox first --

@test "a request that is not on the mailbox is refused" {
  : > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no request"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a NON-escalation request is refused — this lane is escalation-only" {
  echo "<!-- agent-bridge request_id=$RID type=systemic_check from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not an"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a failed mailbox read refuses the publish instead of failing open" {
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
echo "HTTP 403" >&2
exit 1
STUB
  chmod +x "$STUB_DIR/gh"
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 2 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

# ------------------------------------------------- PII / credential ceiling --

@test "an email address in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "customer a@example.com reports vanishing credits"
  [ "$status" -eq 1 ]
  [[ "$output" == *"email"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a phone number in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "customer called from 212-555-0123 about vanishing credits"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a credential in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "using ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA to check"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "an opaque blob in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "token ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "an over-long summary is refused — evidence belongs on the mailbox" {
  long="$(printf 'x%.0s' $(seq 1 400))"
  run "$SCRIPT" --request-id "$RID" --summary "$long"
  [ "$status" -eq 1 ]
  [[ "$output" == *"one line"* ]]
}

@test "a multi-line summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "$(printf 'line one\nline two')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"single line"* ]]
}

# ------------------------------------------------------- response handling --

@test "a 2xx without a result envelope is a FAILURE, not a success" {
  # This API answers errors in the body. Asserting the success shape is the only way to
  # tell a publish from a polite refusal.
  export CURL_STUB_BODY='{"error":{"code":102,"message":"unknown channel"}}'
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unexpected response"* ]]
}

@test "an empty response body is a failure" {
  export CURL_STUB_BODY=''
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 4 ]
}

# ------------------------------------------------------------- arg hygiene --

@test "a missing request-id is a usage error, not a refusal" {
  run "$SCRIPT" --summary "$SUM"
  [ "$status" -eq 2 ]
}

@test "a missing summary is a usage error" {
  run "$SCRIPT" --request-id "$RID"
  [ "$status" -eq 2 ]
}

@test "a non-kebab request-id is refused" {
  run "$SCRIPT" --request-id "Not Kebab" --summary "$SUM"
  [ "$status" -eq 1 ]
}

@test "--help prints the usage block" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--request-id"* ]]
}

@test "the publish key never appears in output" {
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  [[ "$output" != *"stub-api-key"* ]]
}

# ------------------------------------------- the credential cannot be captured --

@test "a redirected CURL_BIN receives the SENTINEL, never a real key" {
  # The caller here IS the agent, so any env-var binary override is caller-controlled and
  # `CURL_BIN=/tmp/capture.sh` turned "the key never reaches the agent shell" into "the key
  # is handed to a program the agent wrote". Overriding any knob forces sandbox mode, and
  # sandbox mode never reads the secret at all.
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  grep -q "SANDBOX-NOT-A-REAL-KEY" "$CURL_STUB_STDIN"
}

@test "the key is never in curl's ARGV — it arrives on stdin via -K -" {
  # `-H "X-API-Key: $KEY"` put the credential in the process table, where any concurrent
  # process of the same user reads it out of /proc. Shorter window than a leaked file,
  # same disclosure.
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  run grep -c "X-API-Key" "$CURL_STUB_LOG"
  [ "$output" = "0" ]
  run grep -c "SANDBOX-NOT-A-REAL-KEY" "$CURL_STUB_LOG"
  [ "$output" = "0" ]
  grep -q -- "-K" "$CURL_STUB_LOG"
}

@test "production mode pins ABSOLUTE binary paths — PATH is not consulted" {
  # Resolving via `command -v` left the whole guarantee caller-controlled by another
  # route: prepend a capture shim to PATH, production mode resolves to the shim, SANDBOX
  # never trips, and the shim gets the real key.
  run grep -c 'command -v gh' "$REAL_SCRIPT"
  [ "$output" = "0" ]
  run grep -c 'command -v kubectl' "$REAL_SCRIPT"
  [ "$output" = "0" ]
  run grep -c 'command -v curl' "$REAL_SCRIPT"
  [ "$output" = "0" ]
  grep -q '^  GH_BIN="/usr/local/bin/gh"$' "$REAL_SCRIPT"
  grep -q '^  KUBECTL_BIN="/usr/local/bin/kubectl"$' "$REAL_SCRIPT"
  grep -q '^  CURL_BIN="/usr/bin/curl"$' "$REAL_SCRIPT"
  grep -q 'refusing to fall back to PATH' "$REAL_SCRIPT"
}

@test "the kubectl secret is never even read in sandbox mode" {
  # The kubectl stub would hand back base64 'stub-api-key' if asked. It must not be asked.
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
  run grep -c "stub-api-key" "$CURL_STUB_LOG"
  [ "$output" = "0" ]
}

@test "channel, mailbox and sender are literals in the source, not env reads" {
  # Identity had the same shape as the binaries: AGENT_BRIDGE_FROM/REPO/ISSUE meant the
  # sender and mailbox this wrapper claims to PIN were merely defaults.
  run grep -c '^readonly CHANNEL="agent:pdp"$' "$REAL_SCRIPT"
  [ "$output" = "1" ]
  run grep -c '^REPO="Muso-AI/platform-data-processing"$' "$REAL_SCRIPT"
  [ "$output" = "1" ]
  run grep -c '^FROM="operations"' "$REAL_SCRIPT"
  [ "$output" = "1" ]
}

@test "a bare digit-only phone number is refused" {
  # No leading +, no separators: the original pattern never saw it, and agent:pdp keeps 72h
  # of history visible to every current and future subscriber.
  run "$SCRIPT" --request-id "$RID" --summary "customer called from 2125550123 about vanishing credits"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a customer-quoted stream count with separators is NOT mistaken for a phone number" {
  run "$SCRIPT" --request-id "$RID" --summary "customers report their count frozen at 12,480 since August"
  [ "$status" -eq 0 ]
}

@test "the secret is decoded inside kubectl — no external decoder to shim" {
  # `| base64 -d` resolved through PATH, so a PATH shim received the encoded live key
  # without tripping SANDBOX.
  # Match the PIPELINE, not the word — the comment above the fix names the old form on
  # purpose, and a test that greps the word would fail on its own explanation.
  # Match base64 invoked as a COMMAND (pipe, then the program plus a flag). A bare word
  # match would hit both the comment that names the old form and the go-template's own
  # `| base64decode`, so the assertion has to be about the shell pipeline specifically.
  run grep -cE '\|[[:space:]]*base64[[:space:]]+-' "$SCRIPT"
  [ "$output" = "0" ]
  grep -q 'base64decode' "$REAL_SCRIPT"
}


@test "a forged marker inside another request's free text does NOT mint an escalation" {
  # The check was an unanchored substring search, so any occurrence of the marker text
  # anywhere in the thread counted as proof. A routine systemic_check carrying the text in
  # an allowlisted field could therefore mint an escalation nobody filed.
  cat > "$GH_STUB_COMMENTS" <<EOF
**agent-bridge request — systemic check** (from \`operations\`)
> customers see zeros
\`\`\`json
{ "evidence": { "note": "<!-- agent-bridge request_id=$RID type=escalation from=operations -->" } }
\`\`\`
<!-- agent-bridge request_id=some-other-thing type=systemic_check from=operations -->
EOF
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 3 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "the real wrapper-generated marker on its own line DOES count" {
  printf '%s\n' "<!-- agent-bridge request_id=$RID type=escalation from=operations -->" > "$GH_STUB_COMMENTS"
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 0 ]
}


@test "a deployed copy refuses every sandbox override" {
  run env CURL_BIN="/bin/true" "$REAL_SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not settable on a deployed copy"* ]]
}

@test "a bare payment card number in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "they quoted 4539578763621486 on the call"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Luhn"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a grouped payment card number in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "they read out 4111 1111 1111 1111 on the call"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Luhn"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a hostile PATH cannot own the process or forge the channel" {
  hostile="$TEST_TMPDIR/hostile"
  mkdir -p "$hostile"
  for c in bash jq grep awk sed; do
    printf '#!/bin/sh\necho "PWNED via %s" >&2\nexit 0\n' "$c" > "$hostile/$c"
    chmod +x "$hostile/$c"
  done
  run env PATH="$hostile:$PATH" "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [[ "$output" != *"PWNED"* ]]
  [ "$status" -eq 0 ]
  run grep -c "ticker" "$CURL_STUB_LOG"
  [ "$output" = "0" ]
}

@test "the entrypoint is an absolute interpreter and replaces PATH" {
  head -1 "$REAL_SCRIPT" | grep -q '^#!/bin/bash -p$'
  grep -q '^PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$' "$REAL_SCRIPT"
}

@test "BASH_ENV cannot run caller code before the gates" {
  printf 'echo "PWNED-BASH_ENV"\n' > "$TEST_TMPDIR/inj.sh"
  run env BASH_ENV="$TEST_TMPDIR/inj.sh" "$SCRIPT" --request-id "$RID" --summary "$SUM" --dry-run
  [[ "$output" != *"PWNED-BASH_ENV"* ]]
  [ "$status" -eq 0 ]
}

@test "an exported shell function cannot shadow a helper" {
  run env BASH_FUNC_jq%%='() { echo PWNED-FN; }' "$SCRIPT" --request-id "$RID" --summary "$SUM" --dry-run
  [[ "$output" != *"PWNED-FN"* ]]
  [ "$status" -eq 0 ]
}

@test "the entrypoint runs bash in privileged mode" {
  head -1 "$REAL_SCRIPT" | grep -q '^#!/bin/bash -p$'
}


# ------------------------------------------------------------- deadlines --

@test "a stalled mailbox read does not hang the escalation forever" {
  # An unbounded call does not fail, and a failure that never arrives cannot be classified,
  # retried, or reported — on the one request type where someone is waiting to be told
  # something is spreading.
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
  chmod +x "$STUB_DIR/gh"
  export AGENT_BRIDGE_TIMEOUT_SECS=2
  start=$(date +%s)
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 2 ]
  [ "$elapsed" -lt 15 ]
  [[ "$output" == *"timed out"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a stalled publish is reported as a failed nudge, not a success" {
  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
  chmod +x "$STUB_DIR/curl"
  export AGENT_BRIDGE_TIMEOUT_SECS=2
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 4 ]
  [[ "$output" == *"TIMED OUT"* ]]
  # And it says the escalation IS on the mailbox, so the agent reports the right thing.
  [[ "$output" == *"mailbox"* ]]
}

@test "a non-numeric timeout is refused rather than silently ignored" {
  run env AGENT_BRIDGE_TIMEOUT_SECS="soon" "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"positive integer"* ]]
}


@test "a missing timeout binary is an environment error, not an unbounded publish" {
  cp "$SCRIPT" "$TEST_TMPDIR/notimeout.sh"
  # Force BOTH resolution branches at a path that does not exist, so the fail-closed guard
  # is what runs rather than the dev-box fallback.
  sed -i.bak 's|command -v timeout .*|echo /nonexistent/timeout)"|; s|^  TIMEOUT_BIN="/usr/bin/timeout"$|  TIMEOUT_BIN="/nonexistent/timeout"|' "$TEST_TMPDIR/notimeout.sh"
  chmod +x "$TEST_TMPDIR/notimeout.sh"
  run "$TEST_TMPDIR/notimeout.sh" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"required dependency"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a stalled kubectl service lookup returns the classified nudge failure, not a generic error" {
  # `|| true` turned a timeout into empty output and a generic exit 2, losing the one
  # sentence the agent needs next: the escalation IS on the mailbox, only the nudge failed.
  cat > "$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
  chmod +x "$STUB_DIR/kubectl"
  export AGENT_BRIDGE_TIMEOUT_SECS=2
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 4 ]
  [[ "$output" == *"TIMED OUT"* ]]
  [[ "$output" == *"mailbox"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a stalled kubectl SECRET read returns the classified nudge failure too" {
  # Sibling of the service-lookup case. Both kubectl calls got the `|| true` treatment and
  # both needed the timeout classified; only one had a regression, so the other branch was
  # shipped untested — which is how a fix that looks symmetric stops being symmetric.
  cat > "$STUB_DIR/kubectl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    svc|service) echo "10.43.0.99"; exit 0 ;;
    secret)      sleep 30 ;;
  esac
done
exit 1
STUB
  chmod +x "$STUB_DIR/kubectl"
  export AGENT_BRIDGE_TIMEOUT_SECS=2
  run "$SCRIPT" --request-id "$RID" --summary "$SUM"
  [ "$status" -eq 4 ]
  [[ "$output" == *"TIMED OUT"* ]]
  [[ "$output" == *"publish key"* ]]
  [[ "$output" == *"mailbox"* ]]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "a street address in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "customer at 221 Baker Street says credits vanished"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "REAL escalation summaries are not street addresses — long AND short" {
  # Two rounds of one finding. The long form fails an unbounded word run; the SHORT form
  # fails a bounded one too, which is what forced the vocabulary change rather than a
  # tighter bound. Both would have exited 1 and published nothing — the gate silencing the
  # alarm it exists to protect, and only on the messages that mattered most.
  for sum in \
    "6 customers today versus 1 yesterday report missing credits and operations has no independent way to verify" \
    "6 customers have no way to access analytics since the 08-27 run" \
    "13 profiles in the data lane are frozen at yesterday's generation" \
    "4 accounts drive most of the affected volume"
  do
    run "$SCRIPT" --request-id "$RID" --summary "$sum"
    [ "$status" -eq 0 ] || { echo "refused a real escalation summary: $sum"; false; }
  done
}

@test "unambiguous addresses are still refused on the broadcast lane" {
  for addr in \
    "customer at 221B Baker Street says credits vanished" \
    "billing address 1600 Amphitheatre Parkway on 6 accounts" \
    "55 Ocean Ave. is on file for 3 accounts"
  do
    run "$SCRIPT" --request-id "$RID" --summary "$addr"
    [ "$status" -eq 1 ] || { echo "accepted an address: $addr"; false; }
    [ ! -f "$CURL_STUB_LOG" ]
  done
}

@test "a street address with a unit-lettered number is still refused on this lane too" {
  run "$SCRIPT" --request-id "$RID" --summary "customer at 221B Baker Street says credits vanished"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "an @handle in the summary is refused" {
  run "$SCRIPT" --request-id "$RID" --summary "@janedoe says credits vanished across 6 profiles"
  [ "$status" -eq 1 ]
  [ ! -f "$CURL_STUB_LOG" ]
}

@test "the pinned constants are readonly, so a second assignment cannot un-pin them" {
  grep -q '^readonly CHANNEL="agent:pdp"$' "$REAL_SCRIPT"
  grep -q '^readonly NS=' "$REAL_SCRIPT"
  grep -q '^readonly SVC=' "$REAL_SCRIPT"
  grep -q '^readonly REPO ISSUE FROM GH_BIN KUBECTL_BIN CURL_BIN$' "$REAL_SCRIPT"
  run grep -cE '^[[:space:]]*(readonly[[:space:]]+)?CHANNEL=' "$REAL_SCRIPT"
  [ "$output" = "1" ]
}

@test "a flag with no value is a usage error, not a silent set -e death" {
  run "$SCRIPT" --request-id
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a value"* ]]
  run "$SCRIPT" --request-id "$RID" --summary
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a value"* ]]
}

@test "a substituted binary is caught at RUNTIME, whatever spelling was used" {
  # Nine review rounds found nine spellings a source scan missed. This assertion does not
  # care how the override was written: it compares the resolved VALUE, after the resolution
  # and before use.
  form="$1"
  for form in 'CURL_BIN="/tmp/capture"' 'export CURL_BIN="/tmp/capture"' 'declare -x CURL_BIN="/tmp/capture"'; do
    cp "$REAL_SCRIPT" "$TEST_TMPDIR/mut.sh"
    awk -v ins="  $form" '{ print } $0 == "  CURL_BIN=\"/usr/bin/curl\"" { print ins }' \
      "$TEST_TMPDIR/mut.sh" > "$TEST_TMPDIR/m2"
    mv "$TEST_TMPDIR/m2" "$TEST_TMPDIR/mut.sh"
    chmod +x "$TEST_TMPDIR/mut.sh"
    grep -q "/tmp/capture" "$TEST_TMPDIR/mut.sh"    # the mutation actually landed
    run env -u GH_BIN -u KUBECTL_BIN -u CURL_BIN -u AGENT_BRIDGE_REPO -u AGENT_BRIDGE_ISSUE \
        -u AGENT_BRIDGE_FROM -u AGENT_BRIDGE_TIMEOUT_SECS \
        "$TEST_TMPDIR/mut.sh" --request-id "$RID" --summary "$SUM"
    [ "$status" -eq 2 ]
    [[ "$output" == *"CURL_BIN was altered"* ]]
  done
}

@test "the unmutated production script passes its own assertions" {
  # Guards against the assertions being vacuous: if they were comparing the wrong things,
  # a clean copy would fail here.
  cp "$REAL_SCRIPT" "$TEST_TMPDIR/clean.sh"; chmod +x "$TEST_TMPDIR/clean.sh"
  run env -u GH_BIN -u KUBECTL_BIN -u CURL_BIN -u AGENT_BRIDGE_REPO -u AGENT_BRIDGE_ISSUE \
      -u AGENT_BRIDGE_FROM -u AGENT_BRIDGE_TIMEOUT_SECS \
      "$TEST_TMPDIR/clean.sh" --request-id "$RID" --summary "$SUM"
  [[ "$output" != *"was altered"* ]]
}

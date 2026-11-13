#!/usr/bin/env bats
# A global flag placed AFTER the request body is refused by name, in both wrapper copies.
#
# The dispatcher parses global flags (--requester, --evidence-excerpt, ...) only BEFORE
# the command and stops at `call`. A flag left after the json body was therefore never
# read, and the call ran as if it had not been passed. For an approve the gate then
# answered
#
#     credit_approve_gate: --evidence-excerpt is required for autonomous approves.
#
# to a caller that HAD passed --evidence-excerpt. 62 rows of exactly that text are in
# the credit-review ledger (`decision_outcomes`, action approve), each one reading as
# "the caller sent no evidence" when the caller sent it in a slot nothing parses.
#
# These cases run the wrapper as a FILE (`bash <wrapper> ...`), not a sourced function:
# the bug lives in the dispatcher, which a sourced test never executes. Only `curl` is
# replaced, and no case here may reach it.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CANONICAL="$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
  WORKSPACE="$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
  for f in "$CANONICAL" "$WORKSPACE"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; return 1; }
  done

  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/runlogs"
  CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$CURL_LOG"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
printf '{"data":{"updatedIds":[]}}\n200'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  echo 'codex_health_gate() { return 0; }' > "$BATS_TEST_TMPDIR/codex-health.sh"
  printf '%s\ndummy-token\n' "$(date +%s)" > "$BATS_TEST_TMPDIR/token-cache"

  export CURL_LOG
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_RUNLOG_DIR="$BATS_TEST_TMPDIR/runlogs"
  export CV_RESULTS_PATH="$BATS_TEST_TMPDIR/results.jsonl"
  export ADMIN_TOKEN_CACHE_PATH="$BATS_TEST_TMPDIR/token-cache"
  export CODEX_HEALTH_LIB="$BATS_TEST_TMPDIR/codex-health.sh"
  export MUSO_API_URL="https://example.invalid"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  export OPS_DRY_RUN=0
  unset REQUESTER_EMAIL CV_APPROVE_GATE_DISABLED EVIDENCE_EXCERPT SCALE_DRAIN \
        SCALE_DRAIN_TOKEN SCALE_DRAIN_TOKEN_FILE MUSO_ADMIN_IDENTITY

  CR_ID="00000001-0000-4000-8000-000000000000"
  APPROVE_BODY="{\"requestIds\":[\"$CR_ID\"],\"status\":\"approved\"}"
  EXCERPT="drain-signal:precedent;precedent_match;v1;00000009-0000-4000-8000-000000000000;-"
}

# Run "$@" against both wrapper copies; every case must hold for both.
both() {
  local check="$1" f
  shift
  for f in "$CANONICAL" "$WORKSPACE"; do
    run bash "$f" "$@"
    "$check" "$f"
  done
}

refused_by_name() {
  [ "$status" -eq 2 ] || { echo "$1: rc=$status, want 2: $output" >&2; return 1; }
  [[ "$output" == *"comes after the request body and was NOT read"* ]] \
    || { echo "$1: refused for the wrong reason: $output" >&2; return 1; }
  [[ "$output" == *"Global flags go BEFORE the command"* ]] \
    || { echo "$1: no correction offered: $output" >&2; return 1; }
  [[ ! -s "$CURL_LOG" ]] || { echo "$1: reached the network: $(cat "$CURL_LOG")" >&2; return 1; }
}

@test "an approve that passed --evidence-excerpt after the body is not told it passed none" {
  # The reproduction. Before the guard both wrappers exited 1 with
  # "--evidence-excerpt is required" - a statement about the caller that was false.
  check() {
    refused_by_name "$1"
    [[ "$output" == *"'--evidence-excerpt' comes after"* ]] \
      || { echo "$1: the flag is not named: $output" >&2; return 1; }
    [[ "$output" != *"--evidence-excerpt is required"* ]] \
      || { echo "$1: still claims the caller sent no evidence: $output" >&2; return 1; }
  }
  both check --requester scale-drain@hydra-ops \
    call PUT /admin/credit-requests "$APPROVE_BODY" --evidence-excerpt "$EXCERPT"
}

@test "any global flag after the body is refused, not only the evidence flag" {
  local flag
  for flag in --requester --confirmed-by --approval-msg-id --profile-audit-id; do
    check() {
      refused_by_name "$1"
      [[ "$output" == *"'$flag' comes after"* ]] \
        || { echo "$1: $flag is not named: $output" >&2; return 1; }
    }
    both check call PUT /admin/credit-requests '{"requestIds":[],"status":"rejected"}' "$flag" value
  done
}

@test "a read with a trailing flag is refused too: the flag was not read there either" {
  check() { refused_by_name "$1"; }
  both check call GET "/admin/credit-requests?profilesIds=p1&limit=1" "" --requester jan@muso.ai
}

@test "the same flag BEFORE the command is read: the gate moves past 'is required'" {
  # The control. With the flag where the dispatcher parses it, the gate has the excerpt
  # and refuses (if it refuses) for some OTHER reason - never for a missing excerpt, and
  # never with the trailing-flag text.
  check() {
    [[ "$output" != *"--evidence-excerpt is required"* ]] \
      || { echo "$1: a leading flag was not read: $output" >&2; return 1; }
    [[ "$output" != *"comes after the request body"* ]] \
      || { echo "$1: a leading flag was refused as trailing: $output" >&2; return 1; }
  }
  both check --evidence-excerpt "some literal words from the page" --requester someone@hydra-ops \
    call PUT /admin/credit-requests "$APPROVE_BODY"
}

@test "a json body that merely contains '--' is not mistaken for a flag" {
  check() {
    [[ "$output" != *"comes after the request body"* ]] \
      || { echo "$1: a body was refused as a flag: $output" >&2; return 1; }
    [[ "$output" != *"looks like a misplaced flag"* ]] \
      || { echo "$1: a body was refused as a flag: $output" >&2; return 1; }
  }
  both check call POST /admin/notes '{"text":"--evidence-excerpt is a flag, this is a note"}'
}

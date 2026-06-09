#!/usr/bin/env bats
# Tests for muso-stripe-write.sh — the codex-health gate on Stripe writes.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WRAPPER="$REPO_ROOT/scripts/muso-stripe-write.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # Record what `stripe` was called with, so we can assert pass-through.
  cat >"$BIN/stripe" <<'SH'
#!/usr/bin/env bash
echo "STRIPE_CALLED $*"
SH
  chmod +x "$BIN/stripe"
  export STRIPE_BIN="$BIN/stripe"
  export OPENCLAW_GATEWAY_UNIT="test-unit"
}

# Helper: install a fake `journalctl` on PATH that emits $1 and exits $2.
fake_journalctl() {
  local out="$1" code="${2:-0}"
  cat >"$BIN/journalctl" <<SH
#!/usr/bin/env bash
printf '%s' "$out"
exit $code
SH
  chmod +x "$BIN/journalctl"
  export PATH="$BIN:$PATH"
}

@test "healthy journal -> executes the stripe write (pass-through)" {
  fake_journalctl "Jun 09 10:00:00 node-8 openclaw[1]: message processed: outcome=ok" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED refunds create -d charge=ch_X --confirm"* ]]
}

@test "degraded journal (refresh_token_reused) -> REFUSES, stripe not called" {
  fake_journalctl "Jun 09 10:00:01 node-8 openclaw[1]: OpenAI Codex token refresh failed (401): code=refresh_token_reused" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"DEGRADED"* ]]
  [[ "$output" != *"STRIPE_CALLED"* ]]
}

@test "degraded journal (reason=auth_permanent) -> REFUSES" {
  fake_journalctl "Jun 09 10:00:02 node-8 openclaw[1]: [model-fallback/decision] reason=auth_permanent next=openrouter/openai/gpt-5.4-mini" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" != *"STRIPE_CALLED"* ]]
}

@test "degraded journal (auth token invalidated) -> REFUSES" {
  fake_journalctl "Jun 09 10:00:03 node-8 openclaw[1]: authentication token has been invalidated" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
}

@test "journald unreadable (non-zero exit) -> FAIL-CLOSED refuse" {
  fake_journalctl "" 1
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"unverifiable"* ]]
  [[ "$output" != *"STRIPE_CALLED"* ]]
}

@test "empty-but-readable window -> treated as healthy-quiet, executes" {
  fake_journalctl "" 0
  run "$WRAPPER" refunds create -d "charge=ch_X" --confirm
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPE_CALLED"* ]]
}

@test "no args -> usage error (exit 2), nothing executed" {
  fake_journalctl "ok" 0
  run "$WRAPPER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "missing codex-health lib -> refuse" {
  fake_journalctl "ok" 0
  CODEX_HEALTH_LIB="/nonexistent/codex-health.sh" run "$WRAPPER" refunds create -d "charge=ch_X"
  [ "$status" -eq 3 ]
  [[ "$output" == *"codex-health lib"* ]]
}

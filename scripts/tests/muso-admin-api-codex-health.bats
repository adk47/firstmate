#!/usr/bin/env bats
# Tests for the codex model-health gate on admin-API WRITES (muso-admin-api.sh).
#
# Mirrors scripts/tests/muso-stripe-write.bats: a degraded/unverifiable codex must
# refuse state-changing writes (the agent can't perceive its own fallback, so the
# refusal is the only honest signal), while READS pass through. Incident 2026-06-08.
#
# The refuse paths return BEFORE cmd_call reaches the network (check_env validates
# dummy env, then the gate refuses), so CLI-level tests need no curl stub. The
# read-allowed / healthy / no-bypass cases are exercised at the function level by
# sourcing the script (its source-safe guard skips the CLI dispatcher when sourced).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # The operations agent runs the WORKSPACE copy (rank-1 skill shadow); other agents
  # get the canonical skills-all copy via tier-4 managed fallback. Both carry the gate,
  # so run this suite against each by overriding ADMIN_API_SCRIPT (default: canonical).
  SCRIPT="${ADMIN_API_SCRIPT:-$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh}"
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"

  export CODEX_HEALTH_LIB="$REPO_ROOT/scripts/lib/codex-health.sh"
  export OPENCLAW_GATEWAY_UNIT="test-unit"
  # check_env() runs before the gate in cmd_call; dummy values satisfy it without
  # any network — the refuse paths never reach get_token/curl.
  export MUSO_API_URL="http://127.0.0.1:0/none"
  export MUSO_ADMIN_EMAIL="test@example.com"
  export MUSO_ADMIN_PASSWORD="x"
  # Keep state/audit writes inside the test tmpdir.
  export MUSO_OPS_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export OPS_DRY_RUN_AUDIT_PATH="$BATS_TEST_TMPDIR/dry-run-audit.jsonl"

  DEGRADED="Jun 09 10:00:01 node-8 openclaw[1]: OpenAI Codex token refresh failed (401): code=refresh_token_reused"
  HEALTHY="Jun 09 10:00:00 node-8 openclaw[1]: message processed: outcome=ok"
}

# Install a fake `journalctl` on PATH that emits $1 and exits $2.
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

# ── CLI-level: refuse paths (exit before any network call) ───────────────────

@test "degraded codex -> POST write REFUSED, no API call" {
  fake_journalctl "$DEGRADED" 0
  run bash "$SCRIPT" call POST /admin/track/enrichByUrl '{"enrichmentUrl":"https://open.spotify.com/track/x"}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CODEX_DEGRADED"* ]]
  [[ "$output" == *"DEGRADED"* ]]
}

@test "unreadable journald -> POST write FAIL-CLOSED refuse" {
  fake_journalctl "" 1
  run bash "$SCRIPT" call POST "/admin/track/capture/abc" ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CODEX_DEGRADED"* ]]
  [[ "$output" == *"unverifiable"* ]]
}

@test "missing codex-health lib -> POST write refused" {
  fake_journalctl "$HEALTHY" 0
  CODEX_HEALTH_LIB="/nonexistent/codex-health.sh" run bash "$SCRIPT" call POST /admin/track/enrichByUrl '{}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CODEX_HEALTH_LIB_MISSING"* ]]
}

@test "dry-run skips the gate even while degraded (write audited, not refused)" {
  fake_journalctl "$DEGRADED" 0
  OPS_DRY_RUN=1 run bash "$SCRIPT" call POST /admin/track/enrichByUrl '{"enrichmentUrl":"x"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dryRun":true'* ]]
  [[ "$output" != *"MUSO_CODEX_DEGRADED"* ]]
}

# ── Function-level: read-allowed / healthy / no-bypass ───────────────────────

@test "GET read is allowed even while codex degraded" {
  fake_journalctl "$DEGRADED" 0
  source "$SCRIPT"
  run enforce_codex_health_gate GET
  [ "$status" -eq 0 ]
}

@test "healthy codex -> POST write passes the gate" {
  fake_journalctl "$HEALTHY" 0
  source "$SCRIPT"
  run enforce_codex_health_gate POST
  [ "$status" -eq 0 ]
}

# Regression: the gate must have NO caller-settable bypass. The actor it restrains
# (a degraded model issuing admin writes) sets per-command env when it invokes the
# tool, so an env-var off-switch would make the guard optional for exactly that
# actor. A degraded codex stays refused even with CODEX_HEALTH_GATE_DISABLED=1.
@test "CODEX_HEALTH_GATE_DISABLED=1 does NOT bypass the gate (no caller escape hatch)" {
  fake_journalctl "$DEGRADED" 0
  source "$SCRIPT"
  CODEX_HEALTH_GATE_DISABLED=1 run enforce_codex_health_gate POST
  [ "$status" -ne 0 ]
  [[ "$output" == *"MUSO_CODEX_DEGRADED"* ]]
}

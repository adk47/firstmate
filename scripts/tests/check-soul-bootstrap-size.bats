#!/usr/bin/env bats
# Tests for check-soul-bootstrap-size.sh: the gate that keeps Caroline's
# injected workspace bootstrap files under openclaw's per-file and total caps.
#
# Why this suite exists: openclaw keeps a 75% HEAD and a 25% TAIL of an
# over-cap bootstrap file and drops the MIDDLE (trimBootstrapContent,
# BOOTSTRAP_HEAD_RATIO/BOOTSTRAP_TAIL_RATIO, verified on 2026.7.1). TOOLS.md
# sat at 46,104 chars against a 40,000 cap and logged 310 truncation warnings
# in 24h, silently removing the profile_credits_status / profile_claim_status /
# cancel_subscription sections from every turn. The gate is the mechanical
# backstop; these tests keep the gate honest.
#
# Hermetic: every case builds a synthetic repo in $TEST_TMPDIR and runs the
# script from there (it resolves $CFG and workspaces/ relative to cwd).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-soul-bootstrap-size.sh"

# openclaw's CANONICAL workspace bootstrap set, verbatim from the Set literal in
# dist/workspace-DkQ7irPD.js. All eight, deliberately:
#   MEMORY is declared as DEFAULT_MEMORY_FILENAME = CANONICAL_ROOT_MEMORY_FILENAME
#   = "MEMORY.md", so grepping the dist for the literal string misses it — it IS
#   a bootstrap file. An earlier version of this list omitted MEMORY (caught in
#   review) and BOOTSTRAP, which meant the completeness assertion below would
#   have stayed green if either were dropped from the production guard.
INJECTED=(SOUL AGENTS TOOLS IDENTITY USER HEARTBEAT MEMORY BOOTSTRAP)

# BOOTSTRAP.md is canonical but NOT required — it is the un-onboarded-workspace
# marker (isWorkspaceBootstrapPending), so its absence is the healthy state and
# the guard must not demand it. Everything else must exist.
REQUIRED=(SOUL AGENTS TOOLS IDENTITY USER HEARTBEAT MEMORY)

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/workspaces/support"
  for f in "${REQUIRED[@]}"; do
    echo "x" > "$TEST_TMPDIR/workspaces/support/$f.md"
  done
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_cfg <defaults-cap> [support-override-cap]
write_cfg() {
  local defaults="$1" override="${2:-}" entry='{"id":"support"}'
  [ -n "$override" ] && entry="{\"id\":\"support\",\"bootstrapMaxChars\":$override}"
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<JSON
{"agents":{"defaults":{"bootstrapMaxChars":$defaults,"bootstrapTotalMaxChars":120000},
 "list":[$entry]}}
JSON
}

@test "the guard lists every file in openclaw's canonical bootstrap set" {
  # Regression cover for two omissions caught in review: HEARTBEAT.md was
  # missing from the guard, and MEMORY/BOOTSTRAP were missing from THIS list —
  # so the assertion itself would have stayed green while the guard undercounted.
  # Checks the union of required + optional, since BOOTSTRAP.md lives in the
  # optional array.
  for f in "${INJECTED[@]}"; do
    grep -q "workspaces/support/$f\.md" "$SCRIPT" \
      || { echo "guard is missing $f.md — it is in openclaw's canonical set"; return 1; }
  done
}

@test "BOOTSTRAP.md is optional: absent is healthy, present is sized" {
  write_cfg 50000
  # absent (the steady state) must not fail
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BOOTSTRAP.md is listed"* ]]
  # present and over-cap must fail
  head -c 400 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/BOOTSTRAP.md"
  write_cfg 100
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BOOTSTRAP.md"* ]]
}

@test "resolves the PER-AGENT cap when the support entry overrides defaults" {
  # openclaw: resolveAgentConfig(cfg,agentId)?.bootstrapMaxChars ?? defaults.
  # A position-based `grep | head -1` returns the defaults here and is wrong.
  write_cfg 40000 50000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap 50000"* ]]
  [[ "$output" != *"cap 40000"* ]]
}

@test "falls back to agents.defaults when the agent has no override" {
  write_cfg 40000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap 40000"* ]]
}

@test "fails when a file exceeds the per-file cap" {
  write_cfg 100
  head -c 500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/TOOLS.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TOOLS.md"* ]]
  # must steer at the per-agent key, not the shared default that scales
  # memory-health-check.sh's warn threshold for every other agent
  [[ "$output" == *"agents.list[id=support].bootstrapMaxChars"* ]]
}

@test "fails when the aggregate exceeds the total cap" {
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":50000,"bootstrapTotalMaxChars":10},"list":[{"id":"support"}]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bootstrap total"* ]]
}

@test "a missing listed file fails loud instead of being skipped" {
  # A silent `continue` would let a deleted TOOLS.md pass this gate forever.
  write_cfg 50000
  rm "$TEST_TMPDIR/workspaces/support/TOOLS.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TOOLS.md"* ]]
}

@test "a missing config aborts (exit 2) rather than silently using a default" {
  write_cfg 50000
  rm "$TEST_TMPDIR/openclaw-edge.json"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "a renamed cap key falls back to the default instead of dying silently" {
  # Under `set -euo pipefail` the old grep-pipeline reader exited non-zero and
  # killed the script BEFORE its `:-` default was ever consulted.
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<'JSON'
{"agents":{"defaults":{"RENAMED":1},"list":[{"id":"support"}]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap 40000"* ]]
}

#!/usr/bin/env bats
# Tests for check-dead-infra-refs.sh: the gate that keeps agent-facing content
# (skills-all/, workspaces/, cron-jobs.json) from pointing any agent at dead
# infrastructure — AWS (decommissioned 2026-05-31), Athena (retired 2026-04-25),
# and the frozen profile_v3_* tables. Born from the 2026-07-24 Finance
# escalation (daily-dispute-handler followed muso-stripe-disputes into an
# Athena AssumeRole → InvalidClientTokenId).
#
# Hermetic: most tests run against a synthetic mini-repo in $TEST_TMPDIR via
# the REPO_ROOT / DEAD_INFRA_ALLOWLIST env overrides; one test runs against
# the real repo tree.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-dead-infra-refs.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/skills-all/dummy" "$TEST_TMPDIR/workspaces/agentx"
  cat > "$TEST_TMPDIR/skills-all/dummy/SKILL.md" <<'EOF'
# Dummy skill
Query Trino via bash /opt/hydra/scripts/trino-query.sh — nothing dead here.
EOF
  cat > "$TEST_TMPDIR/workspaces/agentx/SOUL.md" <<'EOF'
# Agent X
All analytics on OVH Trino.
EOF
  : > "$TEST_TMPDIR/allowlist.txt"
  export REPO_ROOT="$TEST_TMPDIR"
  export DEAD_INFRA_ALLOWLIST="$TEST_TMPDIR/allowlist.txt"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "passes on the real repo tree with the real allowlist" {
  unset REPO_ROOT DEAD_INFRA_ALLOWLIST
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "passes on a clean synthetic tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails on the Athena workgroup/us-west-2 idiom in a SKILL.md (tier 1)" {
  echo 'Use the `clio-agent` workgroup, `us-west-2`, no --profile flag.' \
    >> "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/dummy/SKILL.md"* ]]
  [[ "$output" == *"[workgroup"* ]]
  [[ "$output" == *"[uswest2"* ]]
}

@test "fails on AssumeRole in a workspace SOUL.md (tier 1)" {
  echo 'Refresh creds via sts AssumeRole before querying.' \
    >> "$TEST_TMPDIR/workspaces/agentx/SOUL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[assumerole"* ]]
}

@test "fails on a real aws CLI invocation in a skill script (tier 1)" {
  echo 'aws s3 ls --profile muso-readonly' > "$TEST_TMPDIR/skills-all/dummy/run.sh"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[awscli"* ]]
  [[ "$output" == *"[awsprofile"* ]]
}

@test "tier 1 catches operational syntax even in non-doctrine files" {
  mkdir -p "$TEST_TMPDIR/workspaces/agentx/notes"
  echo 'boto3.client("athena")' > "$TEST_TMPDIR/workspaces/agentx/notes/scratch.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[boto3"* ]]
}

@test "fails on a bare frozen-v3 table name on a doctrine surface (tier 2)" {
  echo 'SELECT * FROM profile_v3_lifetime' >> "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[v3"* ]]
}

@test "bare athena word on a NON-doctrine surface passes (tier 2 scoping)" {
  mkdir -p "$TEST_TMPDIR/workspaces/agentx/reference"
  echo 'Back then we used Athena for this.' > "$TEST_TMPDIR/workspaces/agentx/reference/history.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "uppercase 'AWS Athena' prose outside doctrine surfaces passes (awscli is case-sensitive)" {
  mkdir -p "$TEST_TMPDIR/workspaces/agentx/strategy"
  echo 'Data verified across AWS Athena before the migration.' \
    > "$TEST_TMPDIR/workspaces/agentx/strategy/old-plan.md"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "an allowlist entry with the right key exempts the hit" {
  echo 'NEVER query profile_v3_lifetime — frozen.' >> "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'skills-all/dummy/SKILL.md -- v3 -- NEVER-warning is the doctrine' \
    > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "allowlist keys are scoped: aws entry does not exempt an athena hit" {
  echo 'Run it in Athena.' >> "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'There is no AWS account anymore.' >> "$TEST_TMPDIR/skills-all/dummy/SKILL.md"
  echo 'skills-all/dummy/SKILL.md -- aws -- decommission note' > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[athena"* ]]
  [[ "$output" != *"[aws/"* ]]
}

@test "a directory-prefix entry exempts nested files" {
  mkdir -p "$TEST_TMPDIR/skills-all/dummy/refs"
  echo 'legacy: aws athena list-named-queries' > "$TEST_TMPDIR/skills-all/dummy/refs/old.md"
  echo 'skills-all/dummy/ -- awscli -- legacy migration examples' > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a stale allowlist entry (no remaining matches) fails" {
  echo 'skills-all/dummy/SKILL.md -- athena -- nothing matches this anymore' \
    > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer matches anything"* ]]
}

@test "an allowlist entry pointing at a nonexistent path fails" {
  echo 'skills-all/ghost/SKILL.md -- athena -- gone' > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nonexistent path"* ]]
}

@test "a malformed allowlist line exits 2" {
  echo 'skills-all/dummy/SKILL.md -- athena' > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Malformed allowlist line"* ]]
}

@test "an unknown pattern key in the allowlist exits 2" {
  echo 'skills-all/dummy/SKILL.md -- redshift -- not a key' > "$TEST_TMPDIR/allowlist.txt"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown pattern key"* ]]
}

@test "missing skills-all/ or workspaces/ exits 2" {
  rm -rf "$TEST_TMPDIR/skills-all"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "cron-jobs.json is scanned (both tiers)" {
  echo '{"message": "query athena for disputes", "setup": "pip install boto3"}' \
    > "$TEST_TMPDIR/cron-jobs.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cron-jobs.json"* ]]
  [[ "$output" == *"[athena"* ]]
  [[ "$output" == *"[boto3"* ]]
}

#!/usr/bin/env bats
# Tests for scripts/lib/deploy-rollback-gate.sh: the "Rollback on failure"
# decision logic extracted out of .github/workflows/deploy.yml.
#
# Covers the incident class the gate prevents: deploy.sh Step 0 (drift
# check) and Step 4a (pre-flight) are READ-ONLY and halt with exit 1 BEFORE
# any rsync when the server has agent-edited files. On a daily schedule
# (rather than one deploy per merge) that halt is common, and running
# rollback.sh on every failure() would restart both gateways for nothing.

setup() {
  GATE="${BATS_TEST_DIRNAME}/../lib/deploy-rollback-gate.sh"
  DEPLOY_PATH="$BATS_TEST_TMPDIR/deploy"
  mkdir -p "$DEPLOY_PATH"
}

teardown() {
  rm -rf "$DEPLOY_PATH"
}

@test "marker owned by this run -> rollback=true" {
  printf '%s\n' gha-1-1 > "$DEPLOY_PATH/.deploy-mutating"
  run "$GATE" "$DEPLOY_PATH" gha-1-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback=true"* ]]
}

@test "marker owned by ANOTHER deploy -> rollback=false (concurrent holder, QA Critical on PR #948)" {
  printf '%s\n' manual-node8-4242 > "$DEPLOY_PATH/.deploy-mutating"
  run "$GATE" "$DEPLOY_PATH" gha-1-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback=false"* ]]
  [[ "$output" == *"another deploy"* ]]
}

@test "unreadable marker -> rollback=false, exit 0 (QA Important round 2 on PR #948)" {
  # CI runs bats as root, so chmod cannot make the file unreadable; stub the
  # reader on PATH instead so the read fails the way an I/O error would.
  printf '%s\n' gha-1-1 > "$DEPLOY_PATH/.deploy-mutating"
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  printf '#!/bin/sh\necho "head: cannot open: Input/output error" >&2\nexit 1\n' > "$stub/head"
  chmod +x "$stub/head"
  run env PATH="$stub:$PATH" "$GATE" "$DEPLOY_PATH" gha-1-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback=false"* ]]
  [[ "$output" == *"could not read"* ]]
}

@test "workflow still pages when the gate crashes (fallback decision)" {
  workflow="${BATS_TEST_DIRNAME}/../../.github/workflows/deploy.yml"
  grep -q 'DECISION="rollback=false"' "$workflow"
}

@test "marker absent -> rollback=false" {
  run "$GATE" "$DEPLOY_PATH" gha-1-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"rollback=false"* ]]
}

@test "missing token arg -> exit 2" {
  run "$GATE" "$DEPLOY_PATH"
  [ "$status" -eq 2 ]
}

@test "empty args -> exit 2" {
  run "$GATE" "" ""
  [ "$status" -eq 2 ]
}

@test "output is exactly one stdout line" {
  printf '%s\n' gha-1-1 > "$DEPLOY_PATH/.deploy-mutating"
  stdout_file="$BATS_TEST_TMPDIR/stdout"
  "$GATE" "$DEPLOY_PATH" gha-1-1 >"$stdout_file" 2>/dev/null
  [ "$(wc -l < "$stdout_file")" -eq 1 ]
}

@test "workflow exports the run token to deploy.sh, passes it to the gate, and carries no push trigger" {
  workflow="${BATS_TEST_DIRNAME}/../../.github/workflows/deploy.yml"
  grep -q 'HYDRA_DEPLOY_RUN_ID: gha-${{ github.run_id }}-${{ github.run_attempt }}' "$workflow"
  grep -q 'scripts/lib/deploy-rollback-gate.sh /opt/hydra "gha-${{ github.run_id }}-${{ github.run_attempt }}"' "$workflow"
  if grep -qE '^[[:space:]]*push:' "$workflow"; then false; fi
}

@test "deploy.sh writes the marker AFTER the muso CLI pin and BEFORE Step 4b (QA Important on PR #948)" {
  deploy="${BATS_TEST_DIRNAME}/../deploy.sh"
  pin=$(grep -n 'Step 4a.5/8: Pinning muso CLI' "$deploy" | head -1 | cut -d: -f1)
  marker=$(grep -n 'Claiming the mutation marker' "$deploy" | head -1 | cut -d: -f1)
  sync=$(grep -n 'Step 4b/8: Local sync' "$deploy" | head -1 | cut -d: -f1)
  [ -n "$pin" ] && [ -n "$marker" ] && [ -n "$sync" ]
  [ "$pin" -lt "$marker" ]
  [ "$marker" -lt "$sync" ]
}

@test "deploy.sh CLAIMS the marker atomically (no plain write) on both the local and the ssh path (QA Critical round 3 on PR #948)" {
  deploy="${BATS_TEST_DIRNAME}/../deploy.sh"
  grep -q 'claim_mutation_marker "$DEPLOY_PATH/.deploy-mutating" "$DEPLOY_RUN_TOKEN"' "$deploy"
  grep -q "bash -s -- claim '\$DEPLOY_PATH/.deploy-mutating' '\$DEPLOY_RUN_TOKEN'" "$deploy"
  # a bare redirect of the token into the marker is the overwrite bug
  if grep -qE 'printf .%s.n. "\$DEPLOY_RUN_TOKEN" *> *"\$DEPLOY_PATH/.deploy-mutating"' "$deploy"; then false; fi
}

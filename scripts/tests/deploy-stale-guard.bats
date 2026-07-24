#!/usr/bin/env bats
# Tests for scripts/lib/deploy-stale-guard.sh — the "Refuse stale deploys"
# decision logic extracted out of .github/workflows/deploy.yml.
#
# Covers the incident that motivated the guard (ancestor case, run
# 29992449557) and the QA finding on PR #731 that closed the diverged-history
# gap (default was proceed=true; now proceed=false unless
# HYDRA_ALLOW_STALE_DEPLOY=1). Builds a tiny throwaway git repo fixture per
# test; no network.

setup() {
  GUARD="${BATS_TEST_DIRNAME}/../lib/deploy-stale-guard.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
}

teardown() {
  rm -rf "$REPO"
}

# Two linear commits: OLD (first commit) then TIP (second commit). OLD is an
# ancestor of TIP.
seed_linear_history() {
  git -C "$REPO" commit --allow-empty -m "commit 1" --quiet
  OLD=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" commit --allow-empty -m "commit 2" --quiet
  TIP=$(git -C "$REPO" rev-parse HEAD)
}

# A diverged commit: an independent root commit sharing no ancestry with TIP
# (simulating a force-push / rewritten lineage).
seed_diverged_history() {
  seed_linear_history
  local start_branch
  start_branch=$(git -C "$REPO" symbolic-ref --short HEAD)
  git -C "$REPO" checkout --orphan diverged --quiet
  git -C "$REPO" commit --allow-empty -m "diverged root" --quiet
  DIVERGED=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" checkout "$start_branch" --quiet
}

# Run the guard with cwd inside the fixture repo (it does its own
# `git merge-base`, so it must execute where that history is checked out).
# HYDRA_ALLOW_STALE_DEPLOY is explicitly unset unless the caller passes one.
run_guard() {
  local cur="$1" tip="$2" override="${3:-}"
  ( cd "$REPO" && HYDRA_ALLOW_STALE_DEPLOY="$override" "$GUARD" "$cur" "$tip" )
}

@test "cur == tip -> proceed=true" {
  seed_linear_history
  run run_guard "$TIP" "$TIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceed=true"* ]]
}

@test "cur is an ancestor of tip -> proceed=false (superseded)" {
  seed_linear_history
  run run_guard "$OLD" "$TIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceed=false"* ]]
}

@test "diverged history -> proceed=false by default (QA finding, PR #731)" {
  seed_diverged_history
  run run_guard "$DIVERGED" "$TIP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceed=false"* ]]
}

@test "diverged history + HYDRA_ALLOW_STALE_DEPLOY=1 -> proceed=true (override)" {
  seed_diverged_history
  run run_guard "$DIVERGED" "$TIP" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceed=true"* ]]
}

@test "ancestor + HYDRA_ALLOW_STALE_DEPLOY=1 -> proceed=true (override)" {
  seed_linear_history
  run run_guard "$OLD" "$TIP" "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"proceed=true"* ]]
}

#!/usr/bin/env bats
# Tests for scripts/pr-skill-drift-gate.sh — the PR-time shift-left of the
# skill-drift check. It FAILS the PR on SERVER-AHEAD / CONFLICT (so the author
# captures/reconciles before merge) but lets REPO-AHEAD through (the #366 fix
# at PR time). Missing/unreachable baseline → warn + pass (the deploy backstop
# still catches it). It deliberately does NOT honor the hot-patch ack window —
# at PR time an announced server edit is exactly what a human should review.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GATE="$HYDRA_REPO/scripts/pr-skill-drift-gate.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  REPO="$TEST_TMPDIR/repo"; SERVER="$TEST_TMPDIR/server"
  mkdir -p "$REPO" "$SERVER"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.test
  git -C "$REPO" config user.name tester
}
teardown() { rm -rf "$TEST_TMPDIR"; }

commit_skill() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"; printf '%s' "$content" > "$REPO/$path"
  git -C "$REPO" add -- "$path"; git -C "$REPO" commit -q -m "set $path"
}
srv_write() {
  local path="$1" content="$2"
  mkdir -p "$SERVER/$(dirname "$path")"; printf '%s' "$content" > "$SERVER/$path"
}
set_baseline() { printf '%s\n' "$1" > "$SERVER/.deployed-sha"; }

gate() { run env REPO_ROOT="$REPO" SERVER_ROOT="$SERVER" "$GATE"; }

@test "SERVER-AHEAD fails the PR with a per-file capture command" {
  commit_skill skills-all/bar/SKILL.md "v0"
  set_baseline "$(git -C "$REPO" rev-parse HEAD)"
  srv_write skills-all/bar/SKILL.md "v1-server"

  gate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'skills-all/bar/SKILL.md'
  echo "$output" | grep -q -- '--only'
}

@test "CONFLICT fails the PR with reconcile guidance" {
  commit_skill skills-all/baz/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD); set_baseline "$base"
  commit_skill skills-all/baz/SKILL.md "v1-repo"
  srv_write skills-all/baz/SKILL.md "v2-server"

  gate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'skills-all/baz/SKILL.md'
  echo "$output" | grep -qiE 'conflict|reconcile'
}

@test "REPO-AHEAD only → passes (the #366 fix at PR time)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD); set_baseline "$base"
  commit_skill skills-all/foo/SKILL.md "v1-repo"
  srv_write skills-all/foo/SKILL.md "v0"

  gate
  [ "$status" -eq 0 ]
}

@test "clean (server == repo) → passes" {
  commit_skill skills-all/foo/SKILL.md "v0"
  set_baseline "$(git -C "$REPO" rev-parse HEAD)"
  srv_write skills-all/foo/SKILL.md "v0"

  gate
  [ "$status" -eq 0 ]
}

@test "no .deployed-sha baseline → warn + pass (deploy backstop still applies)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  srv_write skills-all/foo/SKILL.md "v1-server"   # would be SERVER-AHEAD, but no baseline

  gate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::'
}

@test "remediation command shell-quotes a path with spaces (copy-paste safe)" {
  commit_skill "skills-all/foo bar/SKILL.md" "v0"
  set_baseline "$(git -C "$REPO" rev-parse HEAD)"
  srv_write "skills-all/foo bar/SKILL.md" "v1-server"   # SERVER-AHEAD

  gate
  [ "$status" -eq 1 ]
  # The generated --only command must escape the space (printf %q → foo\ bar),
  # not emit a bare space that copy-paste would split into two args.
  echo "$output" | grep -qF 'skills-all/foo\ bar/SKILL.md'
  ! echo "$output" | grep -qF -- '--only skills-all/foo bar/SKILL.md'
}

@test "unreachable baseline → warn + pass" {
  commit_skill skills-all/foo/SKILL.md "v0"
  set_baseline "0000000000000000000000000000000000000000"
  srv_write skills-all/foo/SKILL.md "v1-server"

  gate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '::warning::'
}

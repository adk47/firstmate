#!/usr/bin/env bats
# Tests for the Step 0 drift report's skill-workshop attribution
# (MUS-4098). When deploy.sh Step 0 blocks on drift, each drifted
# SKILL.md is matched against the workshop's on-disk proposals
# (<proposals-root>/<skill>-<date>-<hash>/generations/<uuid>/PROPOSAL.md)
# by BODY (proposal-only frontmatter keys stripped), never by mtime, SSH
# login or auth.log. The attribution is diagnostics only: Step 0's exit
# status and drift set must be identical with and without it.
#
# Step 0 is a function inside deploy.sh (which cannot be sourced whole),
# so the suite extracts the two functions and runs them in HYDRA_LOCAL
# mode against a synthetic repo + fake server tree. ssh is PATH-shadowed.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$REPO_ROOT/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  REPO="$TEST_TMPDIR/repo"       # HYDRA_ROOT (git checkout)
  SERVER="$TEST_TMPDIR/server"   # DEPLOY_PATH (fake /opt/hydra)
  PROPS="$TEST_TMPDIR/openclaw-edge/skill-workshop/proposals"
  mkdir -p "$REPO" "$SERVER"

  mkdir -p "$TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho "test stub: ssh refused ($*)" >&2\nexit 99\n' > "$TEST_TMPDIR/bin/ssh"
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.test
  git -C "$REPO" config user.name tester
  mkdir -p "$REPO/skills-all/foo" "$REPO/skills-all/bar"
  printf -- '---\nname: foo\ndescription: d\n---\nbody v0\n' > "$REPO/skills-all/foo/SKILL.md"
  printf -- '---\nname: bar\ndescription: d\n---\nbar v0\n' > "$REPO/skills-all/bar/SKILL.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  git -C "$REPO" rev-parse HEAD > "$SERVER/.deployed-sha"
  cp -R "$REPO/skills-all" "$SERVER/skills-all"

  # Extract Step 0 + the attribution helper from the real deploy.sh.
  awk '/^drift_proposal_attribution\(\) \{/,/^}/' "$DEPLOY_SH" > "$TEST_TMPDIR/fns.sh"
  awk '/^drift_check_against_baseline\(\) \{/,/^}/' "$DEPLOY_SH" >> "$TEST_TMPDIR/fns.sh"
  cat > "$TEST_TMPDIR/harness.sh" <<HARNESS
set -euo pipefail
HYDRA_LOCAL=true
HYDRA_ROOT="$REPO"
DEPLOY_PATH="$SERVER"
RSYNC_EXCLUDES=()
export HYDRA_PROPOSALS_GLOB="$PROPS"
log() { echo "[t] \$*"; }
fail() { log "FATAL: \$*"; exit 1; }
source "$TEST_TMPDIR/fns.sh"
drift_check_against_baseline
HARNESS
}

teardown() {
  chmod -R u+rwx "$TEST_TMPDIR" 2>/dev/null || true
  rm -rf "$TEST_TMPDIR"
}

# Server-side hand edit of foo (the drift under test).
drift_foo() { printf -- '---\nname: foo\ndescription: d\n---\nbody v1-live\n' > "$SERVER/skills-all/foo/SKILL.md"; }

# Write a proposal for <skill> whose body is <body>; proposal-only keys added.
make_proposal() {
  local skill="$1" body="$2" date="${3:-2026-10-04T10:00:00Z}" dir
  dir="$PROPS/$skill-20261004-abc123/generations/11111111-2222-3333-4444-555555555555"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: d\nstatus: proposal\nversion: 3\ndate: %s\n---\n%s\n' \
    "$skill" "$date" "$body" > "$dir/PROPOSAL.md"
}

# The drift set exactly as Step 0 prints it (attribution sub-lines excluded).
drift_set() {
  printf '%s\n' "$output" | awk '/^DRIFTED FILES/{f=1;next} f&&/^$/{exit} f&&!/↳/{print}'
}

@test "matching proposal: path and date are printed beside the drifted file" {
  drift_foo
  make_proposal foo "body v1-live" "2026-10-04T10:00:00Z"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  skills-all/foo/SKILL.md"$'\n'"    ↳ skill-workshop proposal: $PROPS/foo-20261004-abc123/generations/11111111-2222-3333-4444-555555555555/PROPOSAL.md (date: 2026-10-04T10:00:00Z)"* ]]
}

@test "non-matching proposal body: no attribution line" {
  drift_foo
  make_proposal foo "some other body"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/foo/SKILL.md"* ]]
  [[ "$output" != *"skill-workshop proposal"* ]]
}

@test "proposal for a different skill is not attributed" {
  drift_foo
  make_proposal bar "body v1-live"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" != *"skill-workshop proposal"* ]]
}

@test "missing proposals dir: no attribution, same status" {
  drift_foo
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" != *"skill-workshop proposal"* ]]
}

@test "unreadable proposals dir: no attribution, same status" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores chmod"
  drift_foo
  make_proposal foo "body v1-live"
  chmod 000 "$PROPS"
  run bash "$TEST_TMPDIR/harness.sh"
  chmod 755 "$PROPS"
  [ "$status" -eq 1 ]
  [[ "$output" != *"skill-workshop proposal"* ]]
}

@test "verdict unchanged: status and drift set identical with and without a matching proposal" {
  drift_foo
  run bash "$TEST_TMPDIR/harness.sh"
  without_status=$status; without_set=$(drift_set)
  make_proposal foo "body v1-live"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq "$without_status" ]
  [ "$(drift_set)" = "$without_set" ]
  [ "$without_set" = "  skills-all/foo/SKILL.md" ]
}

@test "attribution is by body, not mtime: newer-mtime non-matching proposal is ignored" {
  drift_foo
  make_proposal foo "body v1-live"
  later="$PROPS/foo-20261005-def456/generations/22222222-2222-3333-4444-555555555555"
  mkdir -p "$later"
  printf -- '---\nname: foo\nstatus: proposal\nversion: 4\ndate: 2026-10-05T00:00:00Z\n---\nunrelated\n' > "$later/PROPOSAL.md"
  touch -d '+1 hour' "$later/PROPOSAL.md" 2>/dev/null || touch -t 203001010000 "$later/PROPOSAL.md"
  run bash "$TEST_TMPDIR/harness.sh"
  [[ "$output" == *"foo-20261004-abc123"* ]]
  [[ "$output" != *"foo-20261005-def456"* ]]
}

@test "no drift: clean exit 0 and no attribution even with a matching proposal present" {
  make_proposal foo "body v0"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Clean"* ]]
  [[ "$output" != *"skill-workshop proposal"* ]]
}

@test "no SSH-login / auth.log heuristic in the attribution helper" {
  body=$(awk '/^drift_proposal_attribution\(\) \{/,/^}/' "$DEPLOY_SH")
  [ -n "$body" ]
  [[ "$body" != *auth.log* ]]
  [[ "$body" != *journalctl* ]]
  [[ "$body" != *"last -"* ]]
}

@test "two drifted skills, each with a matching proposal: both get an attribution line" {
  drift_foo
  printf -- '---\nname: bar\ndescription: d\n---\nbar live\n' > "$SERVER/skills-all/bar/SKILL.md"
  make_proposal foo "body v1-live"
  make_proposal bar "bar live"
  run bash "$TEST_TMPDIR/harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  skills-all/bar/SKILL.md"$'\n'"    ↳ skill-workshop proposal: $PROPS/bar-20261004-abc123/"* ]]
  [[ "$output" == *"  skills-all/foo/SKILL.md"$'\n'"    ↳ skill-workshop proposal: $PROPS/foo-20261004-abc123/"* ]]
  [[ "$output" != *"newline in string"* ]]
}

@test "two proposals with the same body: newest date wins and the path is clean" {
  drift_foo
  make_proposal foo "body v1-live" "2026-10-04T10:00:00Z"
  newer="$PROPS/foo-20261005-def456/generations/22222222-2222-3333-4444-555555555555"
  mkdir -p "$newer"
  printf -- '---\nname: foo\ndescription: d\nstatus: proposal\nversion: 4\ndate: 2026-10-05T10:00:00Z\n---\nbody v1-live\n' > "$newer/PROPOSAL.md"
  run bash "$TEST_TMPDIR/harness.sh"
  [[ "$output" == *"    ↳ skill-workshop proposal: $newer/PROPOSAL.md (date: 2026-10-05T10:00:00Z)"* ]]
  [[ "$output" != *"foo-20261004-abc123"* ]]
}

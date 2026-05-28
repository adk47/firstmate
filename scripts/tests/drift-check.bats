#!/usr/bin/env bats
# Tests for scripts/lib/drift-check.sh — the 3-way (baseline / repo-HEAD /
# server) skill-drift classifier used by deploy.sh Step 4a and the
# pr-validate deploy-preflight gate. Comparison is by git blob identity
# (git rev-parse <sha>:<path> + git hash-object), never the working tree,
# so it is immune to runner working-tree staleness (the suspected #366
# root cause). PATH-shadows ssh so an accidental remote call fails loudly
# (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/drift-check.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  REPO="$TEST_TMPDIR/repo"        # sandbox git checkout = repo_root arg
  SERVER="$TEST_TMPDIR/server"    # fake /opt/hydra = server_root arg
  mkdir -p "$REPO" "$SERVER"

  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.test
  git -C "$REPO" config user.name  tester

  # PATH-shadow ssh: the lib is local-only (HYDRA_LOCAL semantics), but a
  # regression that shells out to ssh should fail the suite, not hit prod.
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  # shellcheck disable=SC1090
  source "$LIB"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Commit <path>=<content> into the sandbox repo (advances HEAD).
commit_skill() {
  local path="$1" content="$2"
  mkdir -p "$REPO/$(dirname "$path")"
  printf '%s' "$content" > "$REPO/$path"
  git -C "$REPO" add -- "$path"
  git -C "$REPO" commit -q -m "set $path"
}

# Write <path>=<content> into the fake server tree.
srv_write() {
  local path="$1" content="$2"
  mkdir -p "$SERVER/$(dirname "$path")"
  printf '%s' "$content" > "$SERVER/$path"
}

# ─── classification ────────────────────────────────────────────────

@test "REPO-AHEAD: repo edited, server still at baseline" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-repo"   # HEAD moves ahead
  srv_write skills-all/foo/SKILL.md "v0"           # server == baseline

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "REPO-AHEAD skills-all/foo/SKILL.md" ]
}

@test "SERVER-AHEAD: server edited, repo still at baseline" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)             # HEAD == baseline
  srv_write skills-all/foo/SKILL.md "v1-server"     # server moved

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "SERVER-AHEAD skills-all/foo/SKILL.md" ]
}

@test "CONFLICT: both repo and server diverged from baseline" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-repo"
  srv_write skills-all/foo/SKILL.md "v2-server"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "CONFLICT skills-all/foo/SKILL.md" ]
}

@test "CLEAN: repo and server made the identical edit → no output" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-same"
  srv_write skills-all/foo/SKILL.md "v1-same"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "both added since baseline, differ → CONFLICT" {
  # baseline commit has NO foo
  commit_skill skills-all/other/SKILL.md "seed"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "added-in-repo"
  srv_write skills-all/foo/SKILL.md "added-on-server"
  srv_write skills-all/other/SKILL.md "seed"        # other stays clean

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "CONFLICT skills-all/foo/SKILL.md" ]
}

@test "server-only-new SKILL.md is NOT classified (left to deletion rail)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  srv_write skills-all/foo/SKILL.md "v0"            # clean
  srv_write skills-all/serveronly/SKILL.md "new"    # present only on server

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "repo-only-new SKILL.md is NOT classified (deploy just pushes it)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/repoonly/SKILL.md "new"   # present only in repo
  srv_write skills-all/foo/SKILL.md "v0"            # clean

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mixed set: REPO-AHEAD + SERVER-AHEAD + CONFLICT" {
  commit_skill skills-all/foo/SKILL.md "v0"
  commit_skill skills-all/bar/SKILL.md "v0"
  commit_skill skills-all/baz/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-repo"    # foo: repo moved
  commit_skill skills-all/baz/SKILL.md "v1-repo"    # baz: repo moved
  srv_write skills-all/foo/SKILL.md "v0"            # foo: server baseline  → REPO-AHEAD
  srv_write skills-all/bar/SKILL.md "v1-server"     # bar: server moved      → SERVER-AHEAD
  srv_write skills-all/baz/SKILL.md "v2-server"     # baz: both moved        → CONFLICT

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "REPO-AHEAD skills-all/foo/SKILL.md"
  echo "$output" | grep -qx "SERVER-AHEAD skills-all/bar/SKILL.md"
  echo "$output" | grep -qx "CONFLICT skills-all/baz/SKILL.md"
  [ "$(echo "$output" | grep -c .)" -eq 3 ]
}

@test "path with spaces classified correctly" {
  commit_skill "skills-all/foo bar/SKILL.md" "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill "skills-all/foo bar/SKILL.md" "v1-repo"
  srv_write "skills-all/foo bar/SKILL.md" "v0"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "REPO-AHEAD skills-all/foo bar/SKILL.md" ]
}

# ─── fail-safe exit codes ──────────────────────────────────────────

@test "empty baseline → exit 5 (caller falls back to blunt)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  srv_write skills-all/foo/SKILL.md "v1"

  run classify_skill_drift "" "$REPO" "$SERVER"
  [ "$status" -eq 5 ]
}

@test "baseline commit unreachable → exit 6" {
  commit_skill skills-all/foo/SKILL.md "v0"
  srv_write skills-all/foo/SKILL.md "v1"
  bogus="0000000000000000000000000000000000000000"

  run classify_skill_drift "$bogus" "$REPO" "$SERVER"
  [ "$status" -eq 6 ]
}

@test "not a git repo → exit 4" {
  base="0000000000000000000000000000000000000000"
  run classify_skill_drift "$base" "$TEST_TMPDIR/notrepo" "$SERVER"
  [ "$status" -eq 4 ]
}

@test "missing server_root arg → exit 2" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  run classify_skill_drift "$base" "$REPO"
  [ "$status" -eq 2 ]
}

# ─── compute_skill_block_lines (deploy Step 4a decision) ───────────
# Smart path blocks SERVER-AHEAD + CONFLICT but lets REPO-AHEAD through
# (the #366 fix). No baseline / remote / classifier-skip → blunt fallback
# so the gate never silently weakens.

@test "block list: REPO-AHEAD alone does NOT block (the #366 fix)" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-repo"
  srv_write skills-all/foo/SKILL.md "v0"

  run compute_skill_block_lines "" "$base" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "block list: SERVER-AHEAD + CONFLICT block, REPO-AHEAD excluded" {
  commit_skill skills-all/foo/SKILL.md "v0"
  commit_skill skills-all/bar/SKILL.md "v0"
  commit_skill skills-all/baz/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill skills-all/foo/SKILL.md "v1-repo"   # REPO-AHEAD
  commit_skill skills-all/baz/SKILL.md "v1-repo"   # CONFLICT (server also moves)
  srv_write skills-all/foo/SKILL.md "v0"
  srv_write skills-all/bar/SKILL.md "v1-server"    # SERVER-AHEAD
  srv_write skills-all/baz/SKILL.md "v2-server"    # CONFLICT

  run compute_skill_block_lines "" "$base" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "SERVER-AHEAD skills-all/bar/SKILL.md"
  echo "$output" | grep -qx "CONFLICT skills-all/baz/SKILL.md"
  ! echo "$output" | grep -q "REPO-AHEAD"
  ! echo "$output" | grep -q "skills-all/foo/SKILL.md"
}

@test "block list: empty baseline → blunt fallback parses the rsync itemize" {
  itemize=$'>fcsT...... skills-all/muso-anrok/SKILL.md\n.f....t.... skills-all/unchanged/SKILL.md\ncd+++++++++ skills-all/somedir/'
  run compute_skill_block_lines "$itemize" "" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ">fcsT...... skills-all/muso-anrok/SKILL.md"
  # metadata-only (.f....t) and dir (cd++) lines are not content drift
  ! echo "$output" | grep -q "unchanged"
  ! echo "$output" | grep -q "somedir"
}

@test "block list: remote (hydra_local=false) → blunt fallback even with baseline" {
  commit_skill skills-all/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  itemize=$'>fcsT...... skills-all/foo/SKILL.md'
  run compute_skill_block_lines "$itemize" "$base" "$REPO" "$SERVER" false
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ">fcsT...... skills-all/foo/SKILL.md"
}

@test "block list: classifier hard error (not a git repo) → non-zero (fail closed)" {
  run compute_skill_block_lines "" "deadbeef" "$TEST_TMPDIR/notrepo" "$SERVER" true
  [ "$status" -ne 0 ]
  [ "$status" -ne 5 ]
  [ "$status" -ne 6 ]
}

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

# ─── workspaces/*/skills coverage (MUS-1792) ────────────────────────
# The candidate set used to be scoped to skills-all/ only, so a
# workspaces/<ws>/skills/**/SKILL.md divergence was never enumerated —
# the gate passed #1047 having examined 0 of its 5 files. These prove the
# widened pathspec covers that tree with the same classification rules.

@test "SERVER-AHEAD: workspaces/*/skills/**/SKILL.md node-8-ahead divergence" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)             # HEAD == baseline
  srv_write workspaces/operations/skills/foo/SKILL.md "v1-server"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "SERVER-AHEAD workspaces/operations/skills/foo/SKILL.md" ]
}

@test "CONFLICT: workspaces/*/skills/**/SKILL.md both-sides divergence" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill workspaces/operations/skills/foo/SKILL.md "v1-repo"
  srv_write workspaces/operations/skills/foo/SKILL.md "v2-server"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "CONFLICT workspaces/operations/skills/foo/SKILL.md" ]
}

@test "REPO-AHEAD: workspaces/*/skills/**/SKILL.md repo-ahead-only edit, real gate exits 0" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill workspaces/operations/skills/foo/SKILL.md "v1-repo"
  srv_write workspaces/operations/skills/foo/SKILL.md "v0"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ "$output" = "REPO-AHEAD workspaces/operations/skills/foo/SKILL.md" ]
}

@test "untracked server-only workspaces/*/skills/**/SKILL.md is NOT classified" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  srv_write workspaces/operations/skills/foo/SKILL.md "v0"              # clean
  srv_write workspaces/operations/skills/serveronly/SKILL.md "new"      # untracked at HEAD

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "workspaces/*/memory/**/SKILL.md is NOT classified (not under .../skills/)" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill workspaces/operations/memory/notes/SKILL.md "repo-note"
  srv_write workspaces/operations/skills/foo/SKILL.md "v0"              # clean
  srv_write workspaces/operations/memory/notes/SKILL.md "server-note"   # diverges, but out of scope

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "workspaces/*/tmp*/**/SKILL.md is NOT classified (not under .../skills/)" {
  commit_skill workspaces/operations/skills/foo/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  commit_skill workspaces/operations/tmpwork/skills/x/SKILL.md "repo-scratch"
  srv_write workspaces/operations/skills/foo/SKILL.md "v0"                    # clean
  srv_write workspaces/operations/tmpwork/skills/x/SKILL.md "server-scratch"  # diverges, but out of scope

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mixed skills-all/ + workspaces/ set classifies both trees in one pass" {
  commit_skill skills-all/foo/SKILL.md "v0"
  commit_skill workspaces/operations/skills/bar/SKILL.md "v0"
  base=$(git -C "$REPO" rev-parse HEAD)
  srv_write skills-all/foo/SKILL.md "v1-server"
  srv_write workspaces/operations/skills/bar/SKILL.md "v1-server"

  run classify_skill_drift "$base" "$REPO" "$SERVER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "SERVER-AHEAD skills-all/foo/SKILL.md"
  echo "$output" | grep -qx "SERVER-AHEAD workspaces/operations/skills/bar/SKILL.md"
  [ "$(echo "$output" | grep -c .)" -eq 2 ]
}

@test "block list: blunt fallback matches skills-all/ AND workspaces/ content drift" {
  itemize=$'>fcsT...... skills-all/muso-anrok/SKILL.md\n>fcsT...... workspaces/operations/skills/foo/SKILL.md\n.f....t.... skills-all/unchanged/SKILL.md'
  run compute_skill_block_lines "$itemize" "" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ">fcsT...... skills-all/muso-anrok/SKILL.md"
  echo "$output" | grep -qx ">fcsT...... workspaces/operations/skills/foo/SKILL.md"
  if echo "$output" | grep -q "unchanged"; then echo "a metadata-only (non-content) change was wrongly included in the block list" >&2; false; fi
}

@test "block list: blunt fallback does NOT block on a non-skill workspaces/ file (GitHub QA Bot NO-GO on hydra#1051)" {
  # The blunt fallback's grep 'skills-all/|workspaces/' matches ANY changed
  # file under workspaces/, not just workspace SKILL.md files — so a remote
  # deploy (HYDRA_LOCAL=false) or an unreachable baseline would classify a
  # drifted workspaces/qa/SOUL.md as "skill drift" and block the deploy for
  # a file that was never in scope. Scope it the same way the smart
  # classifier's candidate pathspec already does.
  itemize='>fcsT...... workspaces/qa/SOUL.md'
  run compute_skill_block_lines "$itemize" "" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "block list: blunt fallback STILL blocks on a non-SKILL.md skills-all/ file (internal QA round-4 NO-GO)" {
  # The round-4 fix above over-corrected: it also narrowed the skills-all/
  # arm from "any file under skills-all/" (the base behaviour) to
  # "SKILL.md only", silently dropping 443 of 520 tracked skills-all/
  # files -- including executable skill scripts like
  # skills-all/muso-abuse-block/scripts/abuse-block.py. Unlike the smart
  # classifier (which IS correctly SKILL.md-only -- Step 0 and the
  # deletion rail cover the rest there), the blunt fallback's documented
  # job is to degrade to the pre-change "any skills-all/ file" behaviour
  # when it runs, i.e. precisely when Step 0 is ALSO skipped (no/
  # unreachable baseline, HYDRA_SKIP_DRIFT_CHECK=1). Only the workspaces/
  # arm needed SKILL.md-only scoping -- base already matched it not at
  # all, so narrowing it to .../skills/.../SKILL.md is a pure widening,
  # not a narrowing, for that arm.
  itemize='>fcs..... skills-all/muso-abuse-block/scripts/abuse-block.py'
  run compute_skill_block_lines "$itemize" "" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'skills-all/muso-abuse-block/scripts/abuse-block.py'
}

# ─── remediation command target (MUS-1792 round 2 — QA finding 1) ──
# deploy.sh's DRIFT_BRIEFING has its own copy of "which sync-from-server.sh
# target accepts this path" — a second copy of the decision
# pr-skill-drift-gate.sh already makes. A shared function is the fix: the
# bug QA found was exactly this decision drifting out of sync between the
# two printers when workspaces/ coverage was added to one but not the other.

@test "sync_target_for_path: workspaces/ path picks the workspaces target" {
  run sync_target_for_path "workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" = "workspaces" ]
}

@test "sync_target_for_path: skills-all/ path picks the skills target" {
  run sync_target_for_path "skills-all/foo/SKILL.md"
  [ "$status" -eq 0 ]
  [ "$output" = "skills" ]
}

@test "format_skill_capture_commands: workspaces/ SERVER-AHEAD path gets the workspaces target, not skills" {
  run format_skill_capture_commands "SERVER-AHEAD workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'scripts/sync-from-server.sh workspaces --apply --only workspaces/operations/skills/foo/SKILL.md'
  echo "$output" | grep -qF 'git add workspaces/operations/skills/foo/SKILL.md && git commit'
  # `!` must be the LAST command in the test body, or bats won't fail on it
  # (SC2314) — the wrong-target string must never appear, checked last.
  if echo "$output" | grep -qF 'scripts/sync-from-server.sh skills --apply --only workspaces/operations/skills/foo/SKILL.md'; then
    echo "wrong target 'skills' leaked into the command for a workspaces/ path" >&2
    return 1
  fi
}

@test "format_skill_capture_commands: skills-all/ SERVER-AHEAD path still gets the skills target" {
  run format_skill_capture_commands "SERVER-AHEAD skills-all/foo/SKILL.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'scripts/sync-from-server.sh skills --apply --only skills-all/foo/SKILL.md'
}

@test "format_skill_capture_commands: CONFLICT lines are excluded (handled by format_skill_conflict_commands)" {
  run format_skill_capture_commands "CONFLICT workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "format_skill_capture_commands: blunt-fallback raw itemize line (11-char code, Linux rsync 3.x shape) is treated as SERVER-AHEAD, target picked from the parsed path" {
  run format_skill_capture_commands ">fcsT...... workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'scripts/sync-from-server.sh workspaces --apply --only workspaces/operations/skills/foo/SKILL.md'
}

@test "format_skill_capture_commands: blunt-fallback raw itemize line (9-char code, macOS openrsync shape) parses the path correctly, not off by a fixed offset" {
  # MUS-1792 round 3 (QA finding 1): the itemize code width is NOT fixed at
  # 11 chars across rsync implementations. /usr/bin/rsync on macOS is
  # openrsync (protocol 29, "rsync 2.6.9 compatible"), which emits a 9-char
  # code — confirmed by running the real local rsync --itemize-changes, not
  # assumed: `>f+++++++ SKILL.md` / `>f.s..... SKILL.md`. A fixed char-offset
  # extraction (the previous `${line:12}`) silently truncates the path's
  # first 2 characters on this shape ("workspaces/..." -> "rkspaces/..."),
  # which sync_target_for_path then can't recognize, falling through to its
  # 'skills' default and printing a dead-end command. This fixture is the
  # real openrsync output shape, not a hand-typed guess.
  run format_skill_capture_commands ">f+++++++ workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  # The full exact command string is the proof: a truncated path ("rkspaces/
  # ...") cannot produce this string character-for-character. (A substring
  # check for "rkspaces" alone is NOT a valid negative here — "workspaces"
  # itself contains "rkspaces" as a substring, so that check would be
  # vacuously true on correct output too.)
  echo "$output" | grep -qF 'scripts/sync-from-server.sh workspaces --apply --only workspaces/operations/skills/foo/SKILL.md'
  if echo "$output" | grep -qF -- '--only rkspaces'; then
    echo "path was truncated by a fixed char-offset assumption" >&2
    return 1
  fi
}

@test "format_skill_conflict_commands: CONFLICT path gets a git show baseline command" {
  run format_skill_conflict_commands "CONFLICT workspaces/operations/skills/bar/SKILL.md"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'git show "$(cat /opt/hydra/.deployed-sha)":workspaces/operations/skills/bar/SKILL.md'
}

@test "format_skill_conflict_commands: SERVER-AHEAD lines are excluded (handled by format_skill_capture_commands)" {
  run format_skill_conflict_commands "SERVER-AHEAD workspaces/operations/skills/foo/SKILL.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  if echo "$output" | grep -q "REPO-AHEAD"; then echo "a REPO-AHEAD-only skill was wrongly included in the block list" >&2; false; fi
  ! echo "$output" | grep -q "skills-all/foo/SKILL.md"
}

@test "block list: empty baseline → blunt fallback parses the rsync itemize" {
  itemize=$'>fcsT...... skills-all/muso-anrok/SKILL.md\n.f....t.... skills-all/unchanged/SKILL.md\ncd+++++++++ skills-all/somedir/'
  run compute_skill_block_lines "$itemize" "" "$REPO" "$SERVER" true
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx ">fcsT...... skills-all/muso-anrok/SKILL.md"
  # metadata-only (.f....t) and dir (cd++) lines are not content drift
  if echo "$output" | grep -q "unchanged"; then echo "a metadata-only (non-content) change was wrongly included in the block list" >&2; false; fi
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

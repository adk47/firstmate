#!/usr/bin/env bats
load helpers

setup() {
  setup_skill_tmp
  # PR auto-open is opt-in via OPS_CAROLINE_REVIEW_PR_OPEN=1. Every test in
  # this file exercises the happy path past the gate, so set it once here.
  # The gate itself is exercised in @test "skips when PR_OPEN unset".
  export OPS_CAROLINE_REVIEW_PR_OPEN=1
  # Build a fake repo
  export REPO_ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$REPO_ROOT/workspaces/support/reference" "$REPO_ROOT/.githooks"
  cd "$REPO_ROOT"
  git init -q
  git config user.email "t@t" && git config user.name "t"
  cat > workspaces/support/reference/common-issues.md <<EOF
# Common issues

## Audio file export

Existing prose.
EOF
  # Pass-through pre-commit hook
  cat > .githooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
  chmod +x .githooks/pre-commit
  git add -A && git commit -q -m "init"
  export BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  # Stand up a bare repo to act as origin so `git push -u origin <branch>`
  # actually has somewhere to push to. Required since Fix #4 (PR #287) made
  # push failures abort the script rather than silently `|| true`.
  git init --bare -q "$TEST_TMPDIR/origin.git"
  git remote add origin "$TEST_TMPDIR/origin.git"
  # Point the script at this checkout explicitly. Production clones a fresh copy
  # (it must not assume cwd is a checkout); the clone path is covered by its own
  # test below.
  export CAROLINE_KB_REPO_DIR="$REPO_ROOT"
  cat > "$WORKDIR/clusters.json" <<EOF
{
  "week_of": "2026-05-12",
  "clusters": [
    {
      "topic": "FLAC export",
      "unique_customers": 3,
      "conversation_ids": ["c1","c2","c3"],
      "target_path": "workspaces/support/reference/common-issues.md",
      "anchor": "## Audio file export",
      "insertion": "If you need FLAC, request it via the audio settings.",
      "response_pattern": "improvise"
    }
  ]
}
EOF
  cat > "$WORKDIR/conversations.jsonl" <<EOF
{"id":"c1","contact_id":"A"}
{"id":"c2","contact_id":"B"}
{"id":"c3","contact_id":"C"}
EOF
}
teardown() { teardown_skill_tmp; }

@test "creates ONE PR for multiple clusters in one branch" {
  jq '.clusters += [{
    "topic": "track delete",
    "unique_customers": 3,
    "conversation_ids": ["c1","c2","c3"],
    "target_path": "workspaces/support/reference/common-issues.md",
    "anchor": "## Audio file export",
    "insertion": "Track deletion is handled in Settings.",
    "response_pattern": "punt"
  }]' "$WORKDIR/clusters.json" > "$WORKDIR/clusters2.json"
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters2.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  # gh stub records args via printf '%q', so spaces become backslash-escaped.
  # "gh pr" always appears adjacent; count invocations of pr create.
  grep -c "gh pr" "$TEST_TMPDIR/gh.calls" >/dev/null
  [ "$(grep -c "gh pr" "$TEST_TMPDIR/gh.calls")" -eq 1 ]
  # Success path must restore worktree: back on base branch, local auto branch gone.
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]
  ! git show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
}

@test "skips with exit 0 when OPS_CAROLINE_REVIEW_PR_OPEN unset" {
  unset OPS_CAROLINE_REVIEW_PR_OPEN
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPS_CAROLINE_REVIEW_PR_OPEN"* ]]
  # No PR call should have been made
  [ ! -f "$TEST_TMPDIR/gh.calls" ] || ! grep -q "gh pr create" "$TEST_TMPDIR/gh.calls"
}

@test "aborts when worktree dirty" {
  cd "$REPO_ROOT"
  echo "dirt" >> workspaces/support/reference/common-issues.md
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty"* || "$output" == *"clean"* ]]
}

@test "safe-restore on pre-commit failure" {
  cd "$REPO_ROOT"
  cat > .githooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
  git add .githooks/pre-commit && git commit -q -m "fail hook"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  # Branch should be deleted
  ! git show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  # Should be back on base branch
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]
  # No untracked files
  [ -z "$(git ls-files --others --exclude-standard)" ]
}

@test "sets reviewer nsollazzo on PR" {
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  grep -q "reviewer" "$TEST_TMPDIR/gh.calls"
  grep -q "nsollazzo" "$TEST_TMPDIR/gh.calls"
}

@test "commit body lists all cluster topics" {
  cd "$REPO_ROOT"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  # Success-path restore deletes the LOCAL auto branch but the push to
  # origin survives. Read the commit body from origin's ref instead.
  run git log -1 --format=%B "origin/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  [[ "$output" == *"FLAC export"* ]]
}

@test "safe-restore on git commit failure (commit-msg hook rejects)" {
  cd "$REPO_ROOT"
  # Install a commit-msg hook that always fails so git commit exits non-zero,
  # simulating any failure mode (empty diff, policy reject, etc.).
  mkdir -p .git/hooks
  cat > .git/hooks/commit-msg <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
  chmod +x .git/hooks/commit-msg

  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  # Branch should be deleted by safe_restore via the EXIT trap
  ! git show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  # Should be back on base branch
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]
}

@test "works when the caller's cwd is NOT a git checkout (production shape)" {
  # The cron runs from the operations workspace, which is not a repo. With the
  # checkout supplied explicitly, the script must not depend on cwd being one.
  mkdir -p "$TEST_TMPDIR/not-a-repo"
  cd "$TEST_TMPDIR/not-a-repo"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  [ "$(grep -c "gh pr" "$TEST_TMPDIR/gh.calls")" -eq 1 ]
}

@test "clones Muso-AI/hydra when CAROLINE_KB_REPO_DIR is unset" {
  unset CAROLINE_KB_REPO_DIR
  # No global/system git identity: the clone must get a local identity from the
  # script, or `git commit` fails "Author identity unknown".
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  # Stub `gh repo clone` to populate the target dir from the fixture checkout.
  cat > "$TEST_TMPDIR/bin/gh" <<STUB
#!/usr/bin/env bash
printf 'gh %q\n' "\$*" >> "${TEST_TMPDIR}/gh.calls"
if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
  git clone -q "$REPO_ROOT" "\$4"
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "https://github.com/Muso-AI/hydra/pull/9999"; exit 0; fi
[ "\$1" = "auth" ] && exit 0
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  mkdir -p "$TEST_TMPDIR/not-a-repo"
  cd "$TEST_TMPDIR/not-a-repo"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -eq 0 ]
  # gh stub records args via printf %q, so the space is escaped (repo\ clone).
  grep -q "clone" "$TEST_TMPDIR/gh.calls"
  [ "$(grep -c "gh pr" "$TEST_TMPDIR/gh.calls")" -eq 1 ]
}

@test "safe-restore on gh pr create failure" {
  cd "$REPO_ROOT"
  # Override gh stub to fail on pr create
  cat > "$TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/gh.calls"
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "gh pr create: stubbed failure" >&2
  exit 1
fi
[ "$1" = "auth" ] && exit 0
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/gh"
  run "$SCRIPTS_DIR/open-kb-pr.sh" "$WORKDIR/clusters.json" "$WORKDIR/conversations.jsonl"
  [ "$status" -ne 0 ]
  # Branch should be deleted by safe_restore via the EXIT trap
  ! git show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
  # Back on base
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BASE_BRANCH" ]
  # The pushed remote branch must also be deleted so a same-day retry is clean.
  ! git --git-dir="$TEST_TMPDIR/origin.git" show-ref --verify --quiet "refs/heads/auto/caroline-kb-review-$(date -u +%Y-%m-%d)"
}

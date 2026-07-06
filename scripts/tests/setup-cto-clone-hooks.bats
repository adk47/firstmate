#!/usr/bin/env bats
# Tests for scripts/lib/setup-cto-clone-hooks.sh — the out-of-band installer that
# arms the CTO push-audit guard for ALL clones under the repos dir via a
# directory-scoped git hooksPath (includeIf gitdir -> core.hooksPath). Proves the
# wiring end-to-end with real pushes to a local bare remote: a clone UNDER the
# repos dir fires the guard; a clone OUTSIDE does not. The guard's own logic is
# covered separately in cto-push-audit-guard.bats.
#
# Hermetic: GIT_CONFIG_GLOBAL/SYSTEM are pinned to test files so the runner's real
# git config is never touched; no network (local bare remote).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SETUP="$HYDRA_REPO/scripts/lib/setup-cto-clone-hooks.sh"

NOW=1782648000   # 2026-06-25T12:00:00Z, matches the guard's CTO_PUSH_GUARD_NOW
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
ymd() { date -u -d "@$1" +%Y-%m-%d 2>/dev/null || date -u -r "$1" +%Y-%m-%d; }

setup() {
  # Resolve symlinks (macOS mktemp returns /var/... but git resolves gitdir to
  # /private/var/... when matching includeIf — the pattern must use the real path).
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  export CTO_REPOS_DIR="$TMP/repos"
  export CTO_HOOKS_DIR="$TMP/hooks"
  export CTO_GUARD_SRC="$HYDRA_REPO/scripts/lib/cto-push-audit-guard.sh"
  export CTO_GITCONFIG="$TMP/gitconfig"
  export CTO_HOOKS_GITCONFIG="$TMP/hooks.gitconfig"
  export CTO_AUDIT_DIR="$TMP/audit"
  mkdir -p "$CTO_REPOS_DIR" "$CTO_AUDIT_DIR"

  bash "$SETUP" >/dev/null   # arm it

  # Make every git command in the test use our isolated global config (which holds
  # the includeIf) and ignore the runner's system config.
  export GIT_CONFIG_GLOBAL="$CTO_GITCONFIG"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export CTO_PUSH_GUARD_NOW="$NOW"

  # Bare remote at a path the guard resolves to "Muso-AI/core-backend".
  REMOTE="$TMP/remotes/Muso-AI/core-backend.git"
  mkdir -p "$(dirname "$REMOTE")"
  git init --bare -q "$REMOTE"
}

teardown() { rm -rf "$TMP"; }

# Clone $REMOTE into $1, commit, and push HEAD to branch $2 (default cto/test).
# Sets `output`/`status`.
clone_commit_push() { # <clone-path> [branch=cto/test]
  local br="${2:-cto/test}"
  git clone -q "$REMOTE" "$1"
  git -C "$1" commit -q --allow-empty -m "change"
  run git -C "$1" push origin "HEAD:refs/heads/$br"
}

add_row() { # <repo-target>
  printf '{"ts":"%s","agent":"cto","action":"code-change","target":"%s"}\n' \
    "$(iso "$(( NOW - 600 ))")" "$1" >> "$CTO_AUDIT_DIR/$(ymd "$NOW").jsonl"
}

@test "installer is idempotent (second run adds no duplicate includeIf)" {
  bash "$SETUP" >/dev/null
  [ "$(grep -c "gitdir:$CTO_REPOS_DIR/" "$CTO_GITCONFIG")" -eq 1 ]
  [ -x "$CTO_HOOKS_DIR/pre-push" ]
}

@test "clone UNDER the repos dir: guard fires and BLOCKS a push with no audit row" {
  clone_commit_push "$CTO_REPOS_DIR/clone-a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cto-push-audit-guard"* ]]
}

@test "clone UNDER the repos dir: push SUCCEEDS once a fresh audit row exists" {
  add_row "Muso-AI/core-backend"
  clone_commit_push "$CTO_REPOS_DIR/clone-b"
  [ "$status" -eq 0 ]
}

@test "clone UNDER the repos dir: BLOCKS a non-cto/ branch push even with an audit row" {
  add_row "Muso-AI/core-backend"
  clone_commit_push "$CTO_REPOS_DIR/clone-c" "fix/login"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cto/<slug>"* ]]
}

@test "clone OUTSIDE the repos dir: guard does NOT fire (push succeeds, no audit row)" {
  clone_commit_push "$TMP/outside-clone"
  [ "$status" -eq 0 ]
}

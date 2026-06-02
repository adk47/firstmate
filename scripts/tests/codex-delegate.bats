#!/usr/bin/env bats
# Tests for scripts/codex-delegate.sh — the gated git/PR plumbing the CTO agent
# uses to ship a Codex-authored coding task as a branch + PR (never a merge).
#
# The production script reads NO environment for policy or paths (so an
# exec-capable agent has nothing to forge, and the self-hosted CI runner — which
# is ALSO root on node-8 — has no host/path signal it could be distinguished by).
# Tests therefore `source` the script (its main is guarded so it does not run on
# source) and override the plain shell vars (REPOS_ROOT / AUDIT_LOG /
# AUTH_CHECK_CMD) in their own shell, exercising the cmd_* functions against a
# throwaway sandbox. A real LOCAL bare git repo stands in for the GitHub remote;
# `gh`/auth-check/codex are PATH stubbed. So the suite NEVER touches real GitHub,
# real node-8 clones, or real codex auth (memory: bats must stub gh/openclaw).
#
# Load-bearing safety tests: (1) "never invokes codex" (a codex stub drops a
# sentinel; asserted never created) and (2) the script exposes NO env knob — both
# guard the mechanical boundary an exec agent must not be able to route around.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-delegate.sh"

NICK="U0AL36NADEY"   # allowlisted requester (slack-people.json)

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  # Local bare repo as the "GitHub remote", seeded with a main branch. The path
  # ends in Muso-AI/hydra.git so its normalized slug matches the resolved SLUG
  # (the origin-drift guard compares owner/repo, not the full URL).
  REMOTE="$TEST_TMPDIR/Muso-AI/hydra.git"
  mkdir -p "$(dirname "$REMOTE")"
  git init -q --bare "$REMOTE"
  local seed="$TEST_TMPDIR/seed"
  git init -q "$seed"
  git -C "$seed" config user.email t@t; git -C "$seed" config user.name t
  echo "# hydra" > "$seed/README.md"
  git -C "$seed" add -A; git -C "$seed" commit -q -m init
  git -C "$seed" branch -M main
  git -C "$seed" remote add origin "$REMOTE"; git -C "$seed" push -q origin main

  # `gh` stub: clone from the local bare remote; pr list empty; pr create echoes a URL.
  cat > "$STUBBIN/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then git clone -q "$REMOTE" "\$4"; exit \$?; fi
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "https://github.com/Muso-AI/hydra/pull/999"; exit 0; fi
exit 0
STUB
  chmod +x "$STUBBIN/gh"

  # auth-check stub (clean by default; tests flip to failing).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/authcheck"; chmod +x "$STUBBIN/authcheck"

  # `codex` stub: drops a sentinel if EVER invoked. It must never be.
  CODEX_SENTINEL="$TEST_TMPDIR/codex-was-called"; export CODEX_SENTINEL
  printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 0\n' "$CODEX_SENTINEL" > "$STUBBIN/codex"
  chmod +x "$STUBBIN/codex"
  export PATH="$STUBBIN:$PATH"

  # Source the script (main is guarded; it will not run) and OVERRIDE the plain
  # shell vars to point at the sandbox. This injection path exists only because
  # we source; production executes and reads none of this from the environment.
  # shellcheck disable=SC1090
  source "$SCRIPT"
  REPOS_ROOT="$TEST_TMPDIR/repos"
  AUDIT_LOG="$TEST_TMPDIR/audit.jsonl"
  AUTH_CHECK_CMD="$STUBBIN/authcheck"
  # Canonical remote base -> EXPECTED_REMOTE resolves to the local bare repo
  # "$TEST_TMPDIR/Muso-AI/hydra.git" (== $REMOTE), so origin/push target it.
  GITHUB_REMOTE_BASE="$TEST_TMPDIR"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

clone_dir() { echo "$REPOS_ROOT/hydra"; }
branch_of() { git -C "$(clone_dir)" rev-parse --abbrev-ref HEAD; }

prepare_ok() { # cut a branch; echoes BRANCH on success
  run cmd_prepare --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | sed -n 's/^BRANCH=//p'
}

# ── gates ────────────────────────────────────────────────────────────────────

@test "refuses a repo not on the allowlist" {
  run cmd_prepare --repo core-backend --requester "$NICK" --task "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the allowlist"* ]]
}

@test "refuses an unauthorized requester" {
  run cmd_prepare --repo hydra --requester UHACKER --task "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not authorized"* ]]
}

@test "refuses a missing requester" {
  run cmd_prepare --repo hydra --task "x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing --requester"* ]]
}

@test "refuses any codex-auth-shaped argument (never performs codex auth)" {
  run cmd_prepare --repo hydra --requester "$NICK" --task "codex login --device-auth"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must never perform codex auth"* ]]
}

# ── the mechanical-boundary invariant: no forgeable env knobs ─────────────────

@test "the deployed script exposes NO environment knob (nothing for an agent to forge)" {
  # Any reintroduced CODEX_DELEGATE_* / env-driven override of policy or paths
  # would defeat the boundary. Keep this at zero.
  run grep -nE 'CODEX_DELEGATE_|\$\{?[A-Z_]*OVERRIDE' "$SCRIPT"
  [ "$status" -ne 0 ]   # grep found nothing
}

@test "EXECUTED script ignores env policy overrides (copied-script / env bypass closed)" {
  # Execute the REAL script (not sourced) with env set as a hostile caller would.
  # A failing auth stub via env guarantees NO clone even if a regression made the
  # script read env, so this is safe on the node-8 CI runner.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/failauth"; chmod +x "$STUBBIN/failauth"
  CODEX_DELEGATE_REQUESTERS="UHACKER" \
  CODEX_DELEGATE_AUTH_CHECK="$STUBBIN/failauth" \
  CODEX_DELEGATE_REPOS_ROOT="$TEST_TMPDIR/evil" \
  CODEX_DELEGATE_AUDIT_LOG="$TEST_TMPDIR/evil.jsonl" \
    run "$SCRIPT" prepare --repo hydra --requester UHACKER --task "x"
  # Correct: UHACKER is not in the hardcoded allowlist -> refused (exit 1), before
  # auth/clone. (A regression that read env would instead pass the requester and
  # hit the failing auth stub -> exit 2; either way nothing is cloned.)
  [ "$status" -eq 1 ]
  [[ "$output" == *"not authorized"* ]]
  [ ! -e "$TEST_TMPDIR/evil" ]
}

@test "aborts (exit 2) when the codex auth health check fails" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/authcheck"
  run cmd_prepare --repo hydra --requester "$NICK" --task "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"auth health check failed"* ]]
}

# ── prepare / finalize lifecycle ──────────────────────────────────────────────

@test "prepare: idempotently clones, syncs to origin/main, cuts a codex/cto branch" {
  branch="$(prepare_ok)"
  [[ "$branch" == codex/cto/add-a-hello-comment-* ]]
  [ "$(branch_of)" = "$branch" ]
  [ -f "$(clone_dir)/.git/codex-delegate.json" ]
  grep -q '"event":"prepare"' "$AUDIT_LOG"
}

@test "prepare: recreates a clone whose origin DRIFTED to a different repo" {
  mkdir -p "$REPOS_ROOT"
  git clone -q "$REMOTE" "$(clone_dir)"
  git -C "$(clone_dir)" remote set-url origin "https://github.com/evil/other.git"
  branch="$(prepare_ok)"
  [ "$(git -C "$(clone_dir)" remote get-url origin)" = "$REMOTE" ]   # re-cloned to canonical
  [[ "$branch" == codex/cto/* ]]
}

@test "prepare: recreates a clone whose origin is the SAME SLUG on a WRONG HOST" {
  # The earlier slug-only check would have wrongly trusted this. The full-URL
  # canonical check must reject it and re-clone from the expected remote.
  mkdir -p "$REPOS_ROOT"
  git clone -q "$REMOTE" "$(clone_dir)"
  git -C "$(clone_dir)" remote set-url origin "git@evil.example:Muso-AI/hydra.git"
  prepare_ok >/dev/null
  [ "$(git -C "$(clone_dir)" remote get-url origin)" = "$REMOTE" ]
}

@test "finalize: pushes to the canonical remote, NOT a drifted origin" {
  branch="$(prepare_ok)"
  echo "// hello" >> "$(clone_dir)/README.md"
  # Tamper origin to a same-slug wrong host AFTER prepare; finalize must still
  # push only to the expected canonical remote (the bare repo), never to origin.
  git -C "$(clone_dir)" remote set-url origin "git@evil.example:Muso-AI/hydra.git"
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 0 ]
  git -C "$REMOTE" rev-parse --verify "refs/heads/$branch" >/dev/null   # landed on canonical
}

@test "finalize: resumable — retries push/PR after a transient failure (no false 'no changes')" {
  branch="$(prepare_ok)"
  echo "// hello" >> "$(clone_dir)/README.md"
  # Run 1: commit + push succeed (real git to the bare remote), then `gh pr create` fails.
  cat > "$STUBBIN/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "boom" >&2; exit 1; fi
exit 0
STUB
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 2 ]
  git -C "$REMOTE" rev-parse --verify "refs/heads/$branch" >/dev/null   # branch WAS pushed

  # Run 2 (clean tree, prepared commit present): must NOT report "no changes";
  # must resume to a successful PR creation.
  cat > "$STUBBIN/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then exit 0; fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then echo "https://github.com/Muso-AI/hydra/pull/777"; exit 0; fi
exit 0
STUB
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR_URL=https://github.com/Muso-AI/hydra/pull/777"* ]]
  [[ "$output" != *"no changes"* ]]
}

@test "finalize: refuses when the working tree has no changes" {
  prepare_ok >/dev/null
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no changes"* ]]
  grep -q '"event":"finalize-nochanges"' "$AUDIT_LOG"
}

@test "finalize: commits, pushes the branch, opens a PR (never the base)" {
  branch="$(prepare_ok)"
  echo "// hello" >> "$(clone_dir)/README.md"
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR_URL=https://github.com/Muso-AI/hydra/pull/999"* ]]
  # branch was pushed to the remote; main was NOT moved.
  git -C "$REMOTE" rev-parse --verify "$branch" >/dev/null
  [ "$(git -C "$REMOTE" rev-parse main)" = "$(git -C "$TEST_TMPDIR/seed" rev-parse main)" ]
  grep -q '"event":"finalize"' "$AUDIT_LOG"
}

@test "finalize: fail-closed — aborts before any remote write if the audit cannot be persisted" {
  branch="$(prepare_ok)"
  echo "// hello" >> "$(clone_dir)/README.md"
  # Make the audit path un-creatable (its parent is a regular file) so the
  # fail-closed audit_strict before `git push` cannot persist.
  touch "$TEST_TMPDIR/blocker"
  AUDIT_LOG="$TEST_TMPDIR/blocker/audit.jsonl"
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no audit trail"* ]]
  # the branch was NEVER pushed to the remote
  run git -C "$REMOTE" rev-parse --verify "refs/heads/$branch"
  [ "$status" -ne 0 ]
}

@test "finalize: refuses (exit 2) without a prepare marker" {
  run cmd_finalize --repo hydra --requester "$NICK" --task "x"
  [ "$status" -eq 2 ]
  [[ "$output" == *"run prepare first"* ]]
}

@test "abort: returns the clone to origin/main and removes the marker" {
  prepare_ok >/dev/null
  run cmd_abort --repo hydra
  [ "$status" -eq 0 ]
  [ "$(branch_of)" = "main" ]
  [ ! -f "$(clone_dir)/.git/codex-delegate.json" ]
}

# ── the core safety invariant ─────────────────────────────────────────────────

@test "NEVER invokes codex across a full prepare->edit->finalize cycle" {
  prepare_ok >/dev/null
  echo "// hello" >> "$(clone_dir)/README.md"
  run cmd_finalize --repo hydra --requester "$NICK" --task "Add a hello comment"
  [ "$status" -eq 0 ]
  [ ! -f "$CODEX_SENTINEL" ]   # the codex stub was never called
}

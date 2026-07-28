#!/usr/bin/env bats
# Tests for scripts/qa-review-status.sh — the `qa-review` commit status that
# becomes the merge gate on repos listed in .merge_gate_repos.
#
# The stakes are asymmetric and worth stating: GitHub NEVER times out a required
# status check that was never reported, so a bug that drops a status leaves the
# PR permanently unmergeable, while a bug that posts a spurious `success` opens
# the gate. Both directions are covered below.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/qa-review-status.sh"

SHA="0123456789abcdef0123456789abcdef01234567"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export QA_GH_LOG="$TEST_TMPDIR/qa-gh.log"; : > "$QA_GH_LOG"

  # Stub the identity shim, logging every call so a test can assert what was
  # posted. STUB_POST_FAIL=1 models GitHub rejecting the write.
  cat > "$TEST_TMPDIR/qa-gh.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QA_GH_LOG"
[ -n "${STUB_POST_FAIL:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
exit 0
STUB
  chmod +x "$TEST_TMPDIR/qa-gh.sh"
  export QA_GH="$TEST_TMPDIR/qa-gh.sh"
  # Default policy: neither gated nor on the App — the arming-order guard is a
  # no-op, so the posting tests below exercise only the posting path.
  printf '%s' '{"merge_gate_repos":[],"identity":{"app_repos":[]}}' > "$TEST_TMPDIR/policy.json"
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/policy.json"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# ---------------------------------------------------------------------------
# Posting
# ---------------------------------------------------------------------------

@test "posts a pending status with the qa-review context" {
  run "$SCRIPT" Muso-AI/hydra "$SHA" pending "QA review queued"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$QA_GH_LOG"
  grep -q 'state=pending' "$QA_GH_LOG"
  grep -q 'context=qa-review' "$QA_GH_LOG"
}

@test "posts success and failure states" {
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 0 ]
  grep -q 'state=success' "$QA_GH_LOG"
  : > "$QA_GH_LOG"
  run "$SCRIPT" Muso-AI/hydra "$SHA" failure "NO-GO"
  [ "$status" -eq 0 ]
  grep -q 'state=failure' "$QA_GH_LOG"
}

@test "routes through the identity shim with --repo, so the App can post it (app_id pinning)" {
  # A status posted by a user cannot be app-pinned; only an App-posted one can.
  run "$SCRIPT" Muso-AI/hydra "$SHA" pending "queued"
  [ "$status" -eq 0 ]
  grep -q -- '--repo Muso-AI/hydra' "$QA_GH_LOG"
}

@test "a >140 char description is truncated (GitHub's limit) with an ellipsis" {
  long="$(printf 'x%.0s' {1..200})"
  run "$SCRIPT" Muso-AI/hydra "$SHA" failure "$long"
  [ "$status" -eq 0 ]
  # the posted description must be exactly 140 chars, ending in ...
  posted="$(grep -o 'description=x*\.*' "$QA_GH_LOG" | head -1 | sed 's/^description=//')"
  [ "${#posted}" -eq 140 ]
  case "$posted" in *...) ;; *) false ;; esac
}

# ---------------------------------------------------------------------------
# Input validation — these values are spliced into an API path
# ---------------------------------------------------------------------------

@test "rejects a non-40-hex sha" {
  run "$SCRIPT" Muso-AI/hydra "not-a-sha" pending "queued"
  [ "$status" -eq 2 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "rejects a sha containing path traversal" {
  run "$SCRIPT" Muso-AI/hydra "../../etc/passwd" pending "queued"
  [ "$status" -eq 2 ]
}

@test "rejects an invalid state" {
  run "$SCRIPT" Muso-AI/hydra "$SHA" greenish "queued"
  [ "$status" -eq 2 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "rejects a repo that is not owner/name" {
  run "$SCRIPT" hydra "$SHA" pending "queued"
  [ "$status" -eq 2 ]
}

@test "missing arguments → exit 2" {
  run "$SCRIPT" Muso-AI/hydra "$SHA" pending
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Failure surfacing
# ---------------------------------------------------------------------------

@test "a failed POST exits 3 (so the caller can warn) rather than reporting success" {
  STUB_POST_FAIL=1 run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'could not post'
}

# ---------------------------------------------------------------------------
# Arming-order guard — the worst failure shape this change can produce
# ---------------------------------------------------------------------------

@test "gated repo NOT on the App identity → refuses, rather than posting a status the pin can never accept" {
  printf '%s' '{"merge_gate_repos":["Muso-AI/hydra"],"identity":{"app_repos":[]}}' > "$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'app_repos'
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "gated repo that IS on the App identity → posts normally" {
  printf '%s' '{"merge_gate_repos":["Muso-AI/hydra"],"identity":{"app_repos":["Muso-AI/hydra"]}}' > "$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "optional target_url is passed through (the Details link on a required check)" {
  run "$SCRIPT" Muso-AI/hydra "$SHA" failure "NO-GO" "https://github.com/Muso-AI/hydra/pull/1/files"
  [ "$status" -eq 0 ]
  grep -q 'target_url=https://github.com/Muso-AI/hydra/pull/1/files' "$QA_GH_LOG"
}

@test "rejects a multi-segment repo (strict owner/name, not just contains-slash)" {
  run "$SCRIPT" Muso-AI/hydra/../evil "$SHA" pending "queued"
  [ "$status" -eq 2 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "a POST failure surfaces the underlying reason, not a bare message" {
  STUB_POST_FAIL=1 run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'could not post'
}

@test "gated repo with the kill switch active → refuses (rollback must not silently wedge the gate)" {
  printf '%s' '{"merge_gate_repos":["Muso-AI/hydra"],"identity":{"app_repos":["Muso-AI/hydra"]}}' > "$TEST_TMPDIR/policy.json"
  touch "$TEST_TMPDIR/killswitch"
  QA_GH_HOST_FLAG="$TEST_TMPDIR/killswitch" run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'kill switch'
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "gated repo with QA_GH_IDENTITY=host → refuses" {
  printf '%s' '{"merge_gate_repos":["Muso-AI/hydra"],"identity":{"app_repos":["Muso-AI/hydra"]}}' > "$TEST_TMPDIR/policy.json"
  QA_GH_IDENTITY=host run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "UNgated repo with the kill switch active → posts normally (guard is gate-scoped)" {
  touch "$TEST_TMPDIR/killswitch"
  QA_GH_HOST_FLAG="$TEST_TMPDIR/killswitch" run "$SCRIPT" Muso-AI/core-backend "$SHA" success "GO"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "ungated repo does not abort under set -e (qa_policy_has returning 1 is normal)" {
  # Regression: calling qa_policy_has bare made `set -e` kill the script on the
  # perfectly ordinary "repo is not in the list" path — every post silently
  # exited 1 with no message.
  printf '%s' '{"merge_gate_repos":["Muso-AI/other"],"identity":{"app_repos":[]}}' > "$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" pending "queued"
  [ "$status" -eq 0 ]
  grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "unreadable policy → exit 3 (must not read as 'ungated, safe to post')" {
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/absent.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "malformed policy JSON → exit 3, never posts" {
  printf '%s' 'not json {{{' > "$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

@test "merge_gate_repos present but not an array → exit 3 (schema failure fails closed)" {
  printf '%s' '{"merge_gate_repos":"hydra","identity":{"app_repos":[]}}' > "$TEST_TMPDIR/policy.json"
  run "$SCRIPT" Muso-AI/hydra "$SHA" success "GO"
  [ "$status" -eq 3 ]
  ! grep -q -- '--method POST' "$QA_GH_LOG"
}

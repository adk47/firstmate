#!/usr/bin/env bats
# Tests for scripts/qa-gh.sh — the identity shim that decides whether a QA
# GitHub call runs as the muso-qa-bot App or the ambient host login.
#
# Every test PATH-shadows `gh` and stubs the token minter, so the suite NEVER
# touches real GitHub and never needs an App key (memory: bats must stub gh —
# an unstubbed test once fired 9 real Slack alerts).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SHIM="$HYDRA_REPO/scripts/qa-gh.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"

  # `gh` stub: prints the identity it was handed plus its own args, so a test can
  # assert BOTH which credential was injected and that the leading --repo was
  # consumed by the shim rather than leaking into the gh command line.
  cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH_TOKEN=${GH_TOKEN:-<unset>}"
echo "ARGS=$*"
STUB
  chmod +x "$STUBBIN/gh"
  export PATH="$STUBBIN:$PATH"

  # Token minter stub. QA_GH_TOKEN_FAIL=1 makes it fail like a dead App key.
  cat > "$TEST_TMPDIR/token.sh" <<'TOK'
#!/usr/bin/env bash
if [ -n "${QA_GH_TOKEN_FAIL:-}" ]; then
  echo "token-stub: mint failed" >&2
  exit 5
fi
echo "ghs_stubtoken_${2:-none}"
TOK
  chmod +x "$TEST_TMPDIR/token.sh"
  export QA_GH_TOKEN_SCRIPT="$TEST_TMPDIR/token.sh"

  # Default: nothing on the App yet — the state PR 1 ships in.
  policy '{"identity":{"app_repos":[]}}'
  export QA_GH_HOST_FLAG="$TEST_TMPDIR/host-flag"   # absent unless a test creates it
}
teardown() { rm -rf "$TEST_TMPDIR"; }

policy() { printf '%s' "$1" > "$TEST_TMPDIR/policy.json"; export QA_APPROVAL_POLICY="$TEST_TMPDIR/policy.json"; }

# ---------------------------------------------------------------------------
# The "merged dark" property — this is what makes PR 1 safe to deploy
# ---------------------------------------------------------------------------

@test "empty app_repos → host identity, no token injected (behaviour identical to pre-shim)" {
  run "$SHIM" --repo Muso-AI/core-backend pr view 12 --repo Muso-AI/core-backend --json state
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
  # the shim's own --repo must NOT reach gh; the command keeps its own
  echo "$output" | grep -q 'ARGS=pr view 12 --repo Muso-AI/core-backend --json state'
}

@test "no --repo at all → host identity, args passed through untouched" {
  run "$SHIM" api user --jq .login
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
  echo "$output" | grep -q 'ARGS=api user --jq .login'
}

# ---------------------------------------------------------------------------
# App identity
# ---------------------------------------------------------------------------

@test "repo listed in app_repos → App identity with a repo-scoped token" {
  policy '{"identity":{"app_repos":["Muso-AI/core-backend"]}}'
  run "$SHIM" --repo Muso-AI/core-backend pr view 12
  [ "$status" -eq 0 ]
  # token minted for THAT repo (the stub echoes back the --repo it was given)
  echo "$output" | grep -q 'GH_TOKEN=ghs_stubtoken_Muso-AI/core-backend'
}

@test "a repo NOT in a non-empty app_repos stays on the host identity (staged cutover)" {
  policy '{"identity":{"app_repos":["Muso-AI/core-backend"]}}'
  run "$SHIM" --repo Muso-AI/octave-ui pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
}

# ---------------------------------------------------------------------------
# Kill switch and overrides
# ---------------------------------------------------------------------------

@test "kill switch beats the policy: flag present → host even for an app_repos repo" {
  policy '{"identity":{"app_repos":["Muso-AI/core-backend"]}}'
  touch "$QA_GH_HOST_FLAG"
  run "$SHIM" --repo Muso-AI/core-backend pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
  # and it says so, so an operator sees why reviews reverted to the old identity
  echo "$output" | grep -q 'kill switch active'
}

@test "QA_GH_IDENTITY=app forces the App even when app_repos is empty" {
  QA_GH_IDENTITY=app run "$SHIM" --repo Muso-AI/octave-ui pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=ghs_stubtoken_Muso-AI/octave-ui'
}

@test "QA_GH_IDENTITY=host forces the host even when the repo is in app_repos" {
  policy '{"identity":{"app_repos":["Muso-AI/core-backend"]}}'
  QA_GH_IDENTITY=host run "$SHIM" --repo Muso-AI/core-backend pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
}

# ---------------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------------

@test "unreadable policy → host identity (fail-safe: degrade to the old behaviour, never half-state)" {
  export QA_APPROVAL_POLICY="$TEST_TMPDIR/absent.json"
  run "$SHIM" --repo Muso-AI/core-backend pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
}

@test "malformed policy JSON → host identity, does not crash" {
  policy 'this is not json {{{'
  run "$SHIM" --repo Muso-AI/core-backend pr view 12
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'GH_TOKEN=<unset>'
}

@test "token mint failure → exit 5 and gh is NEVER invoked (fails loud, not blind)" {
  policy '{"identity":{"app_repos":["Muso-AI/core-backend"]}}'
  QA_GH_TOKEN_FAIL=1 run "$SHIM" --repo Muso-AI/core-backend pr review 12 --approve
  [ "$status" -eq 5 ]
  # the whole point: a dead credential must not fall back to the host account and
  # silently approve as a human
  ! echo "$output" | grep -q 'ARGS='
}

@test "usage: no gh args → exit 2" {
  run "$SHIM" --repo Muso-AI/core-backend
  [ "$status" -eq 2 ]
}

@test "usage: --repo without a value → exit 2" {
  run "$SHIM" --repo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Empty review payloads are refused at the one write surface (2026-11-06:
# hydra#1820 @ 086158df carried bodiless COMMENTED reviews that read as "the
# bot reviewed this" while saying nothing). Exit 6, reason named, nothing sent.
# ---------------------------------------------------------------------------

review_payload() { printf '%s' "$1" > "$TEST_TMPDIR/payload.json"; echo "$TEST_TMPDIR/payload.json"; }

@test "empty review: no body and no comments → exit 6, gh never called, reason names the path" {
  p="$(review_payload '{"commit_id":"abc","event":"COMMENT","body":"","comments":[]}')"
  run "$SHIM" --repo Muso-AI/hydra api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input "$p"
  [ "$status" -eq 6 ]
  [[ "$output" != *"ARGS="* ]]
  [[ "$output" == *"EMPTY review"* ]]
  [[ "$output" == *"repos/Muso-AI/hydra/pulls/1820/reviews"* ]]
  [[ "$output" == *"no body and no inline comments"* ]]
}

@test "empty review: whitespace-only body with absent comments is still empty; -X POST form too" {
  p="$(review_payload '{"commit_id":"abc","event":"COMMENT","body":"  \n\t "}')"
  run "$SHIM" api repos/Muso-AI/hydra/pulls/1820/reviews -X POST --input "$p"
  [ "$status" -eq 6 ]
}

@test "empty review: --input - (stdin) is NOT inspected -- passed through, nothing spooled to disk" {
  run bash -c "printf '%s' '{\"body\":\"\",\"comments\":[]}' | \"$SHIM\" api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input -"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ARGS=api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input -'
}

@test "verdict body passes through untouched (the verdict is never reformatted)" {
  p="$(review_payload '{"commit_id":"abc","event":"COMMENT","body":"✅ **Verdict: GO** — 0 unresolved Critical","comments":[]}')"
  run "$SHIM" --repo Muso-AI/hydra api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input "$p"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ARGS=api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input $p"
}

@test "comment-only review (carry-forward thread reply) passes: body empty but comments non-empty" {
  p="$(review_payload '{"commit_id":"abc","event":"COMMENT","body":"","comments":[{"path":"a.py","line":1,"body":"Confirmed fixed"}]}')"
  run "$SHIM" api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input "$p"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ARGS=api'
}

@test "the guard is scoped: a GET on /reviews, a POST elsewhere, and non-api calls are untouched" {
  p="$(review_payload '{}')"
  run "$SHIM" api repos/Muso-AI/hydra/pulls/1820/reviews --input "$p"
  [ "$status" -eq 0 ]
  run "$SHIM" api repos/Muso-AI/hydra/issues/1820/comments --method POST --input "$p"
  [ "$status" -eq 0 ]
  run "$SHIM" pr comment 1820 --body ""
  [ "$status" -eq 0 ]
}

@test "unparseable payload is left to gh (it 400s loudly), not swallowed by the guard" {
  printf 'not json' > "$TEST_TMPDIR/bad.json"
  run "$SHIM" api repos/Muso-AI/hydra/pulls/1820/reviews --method POST --input "$TEST_TMPDIR/bad.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ARGS=api'
}

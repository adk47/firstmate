#!/usr/bin/env bats
# Tests for scripts/lib/codex-health.sh — the Codex (OpenAI agentRuntime)
# health detectors used by openclaw-watchdog.sh to fail loud when edge's
# Caroline silently degrades off codex (auth dead) or loses vision.
#
# Log fixtures below are REAL lines captured from the live edge journal
# (hydra, openclaw 2026.5.27) during the #356 window — see R5 research.
# PATH-shadows ssh so an accidental remote call fails loudly
# (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
LIB="$HYDRA_REPO/scripts/lib/codex-health.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

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

# ── codex_count_auth_invalidated ──────────────────────────────

@test "auth_invalidated: counts real codex-auth-dead lines (text + vision)" {
  run codex_count_auth_invalidated <<EOF
May 27 22:41:01 ovh-node-8 node[2436656]: [tools] image failed: All image models failed (2): openai/gpt-5.5: ... | openai-codex/gpt-5.5: Your authentication token has been invalidated. Please try signing in again.
May 27 18:04:07 ovh-node-8 node[399557]: openai-codex/gpt-5.5: Your authentication token has been invalidated. Please try signing in again.
May 27 21:03:43 ovh-node-8 node[399557]: [model-fallback/decision] candidate_succeeded requested=openrouter/google/gemini-3.5-flash candidate=openrouter/openai/gpt-5.5 reason=unknown next=none
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "auth_invalidated: returns 0 on a clean log (no false positive)" {
  run codex_count_auth_invalidated <<EOF
May 28 16:14:45 ovh-node-8 node[1221322]: run agent end isError=false
May 28 16:22:22 ovh-node-8 node[1221322]: reply sent
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── codex_count_refresh_reused ────────────────────────────────
# REAL lines from the 2026-06-08 openclaw-gateway-main journal (the outage that
# went unalerted for 3.5h because the auth_invalidated detector keys on a
# DIFFERENT string). These are the lines the alarm MUST match next time.

@test "refresh_reused: counts the real refresh-race lines (401 + auth_permanent fallback)" {
  run codex_count_refresh_reused <<'EOF'
Jun 08 20:31:44 ovh-node-8 node[3073539]: error="FailoverError: OAuth token refresh failed for openai-codex: OpenAI Codex token refresh failed (401): {
Jun 08 20:31:44 ovh-node-8 node[3073539]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth_permanent next=openrouter/openai/gpt-5.4-mini detail=... "code": "refresh_token_reused" ...
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "refresh_reused: a bare refresh_token_reused code line is matched" {
  run codex_count_refresh_reused <<'EOF'
Jun 08 17:31:24 ovh-node-8 node[3073539]:     "code": "refresh_token_reused"
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "refresh_reused: the successful-fallback (reason=unknown) line is NOT counted" {
  # The codex→openrouter serving line must not inflate the count, else the alert
  # would never clear while the fleet is merely running on the fallback.
  run codex_count_refresh_reused <<'EOF'
Jun 08 20:32:13 ovh-node-8 node[3073539]: [model-fallback/decision] model fallback decision: decision=candidate_succeeded requested=openai/gpt-5.5 candidate=openrouter/openai/gpt-5.4-mini reason=unknown next=none
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "refresh_reused: distinct from auth_invalidated (May-29 string is not this signature)" {
  run codex_count_refresh_reused <<'EOF'
May 27 18:04:07 ovh-node-8 node[399557]: openai-codex/gpt-5.5: Your authentication token has been invalidated. Please try signing in again.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── codex_count_apikey_route ──────────────────────────────────
# REAL lines from the 2026-06-19 outage AFTER codex was floated to 2026.6.1: the
# #90925 mis-route to the OpenAI api-key endpoint. These went unalerted because no
# detector keyed on them.

@test "apikey_route: counts the #90925 api-key-route 401 + invalid_api_key" {
  run codex_count_apikey_route <<'EOF'
Jun 19 06:57:55 ovh-node-8 node[2229866]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth next=openrouter/openai/gpt-5.4-mini detail=unexpected status 401 Unauthorized: Incorrect API key provided: sk-hydra******2026, url: https://api.openai.com/v1/responses
Jun 19 06:57:55 ovh-node-8 node[2229866]: error="FailoverError: unexpected status 401 ... code: invalid_api_key ..."
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "apikey_route: the successful gpt-5.4-mini fallback line is NOT counted (alert clears when codex recovers)" {
  run codex_count_apikey_route <<'EOF'
Jun 19 06:58:00 ovh-node-8 node[2229866]: [model-fallback/decision] model fallback decision: decision=candidate_succeeded requested=openai/gpt-5.5 candidate=openrouter/openai/gpt-5.4-mini reason=unknown next=none
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "apikey_route: distinct from the OAuth-route signatures (expired / invalidated not counted)" {
  run codex_count_apikey_route <<'EOF'
Jun 18 22:07:49 ovh-node-8 node[902795]: unexpected status 401 Unauthorized: Provided authentication token is expired. Please try signing in again.
May 27 18:04:07 ovh-node-8 node[399557]: openai-codex/gpt-5.5: Your authentication token has been invalidated. Please try signing in again.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── codex_count_token_expired ─────────────────────────────────
# REAL lines from the ORIGINAL 2026-06-19 trigger: the OAuth access token lapsed
# (chatgpt.com/backend-api/codex route) ~21:48 UTC and refresh stopped renewing it.

@test "token_expired: counts the OAuth access-token-lapsed 401" {
  run codex_count_token_expired <<'EOF'
Jun 18 22:07:49 ovh-node-8 node[902795]: unexpected status 401 Unauthorized: Provided authentication token is expired. Please try signing in again., url: https://chatgpt.com/backend-api/codex/responses
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "token_expired: does NOT double-count the 'has been invalidated' string (shares the sign-in-again tail)" {
  run codex_count_token_expired <<'EOF'
May 27 18:04:07 ovh-node-8 node[399557]: openai-codex/gpt-5.5: Your authentication token has been invalidated. Please try signing in again.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "token_expired: a clean log is 0 (no false positive)" {
  run codex_count_token_expired <<'EOF'
Jun 19 07:22:15 ovh-node-8 node[2410912]: run agent end isError=false
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── codex_count_vision_failures ───────────────────────────────

@test "vision_failures: counts image AND pdf 'All image models failed'" {
  run codex_count_vision_failures <<EOF
May 27 22:41:01 ovh-node-8 node[2436656]: [tools] image failed: All image models failed (2): openai/gpt-5.5: ...
May 27 22:42:10 ovh-node-8 node[2436656]: [tools] pdf failed: All image models failed (2): openai/gpt-5.5: ...
May 27 18:04:21 ovh-node-8 node[399557]: reply sent ok
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "vision_failures: 'Model does not support images' alone is NOT counted" {
  run codex_count_vision_failures <<EOF
May 27 22:41:11 ovh-node-8 node[2436656]: [tools] image failed: Model does not support images: openrouter/anthropic/claude-4.6-sonnet-20260217 (resolved input: text)
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ── codex_edge_auth_symlink_status ────────────────────────────

@test "symlink_status: ok for a symlink to an existing target (expiry irrelevant)" {
  local real="$TEST_TMPDIR/main-auth-profiles.json"
  local future_ms=$(( ($(date +%s) + 7*24*3600) * 1000 ))
  printf '{"version":1,"profiles":{"openai-codex:a@b":{"expires":%s}}}' "$future_ms" > "$real"
  ln -s "$real" "$TEST_TMPDIR/edge-auth-profiles.json"
  run codex_edge_auth_symlink_status "$TEST_TMPDIR/edge-auth-profiles.json"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "symlink_status: not-symlink for a regular file (deploy clobber)" {
  echo '{"version":1,"profiles":{}}' > "$TEST_TMPDIR/edge-auth-profiles.json"
  run codex_edge_auth_symlink_status "$TEST_TMPDIR/edge-auth-profiles.json"
  [ "$status" -eq 0 ]
  [ "$output" = "not-symlink" ]
}

@test "symlink_status: dangling for a symlink to a missing target" {
  ln -s "$TEST_TMPDIR/does-not-exist.json" "$TEST_TMPDIR/edge-auth-profiles.json"
  run codex_edge_auth_symlink_status "$TEST_TMPDIR/edge-auth-profiles.json"
  [ "$status" -eq 0 ]
  [ "$output" = "dangling" ]
}

# The codex access token is ~9h-lived + refresh-on-use, so a near/just-past
# `expires` is the normal steady state, NOT a "needs human re-auth" signal. The
# old 24h "stale" sub-check fired on essentially every cycle (false alarm). This
# test pins the fix: a symlink to a soon-/already-expired token is still `ok`.
# A genuinely dead token is detected by codex_count_auth_invalidated, not here.
@test "symlink_status: ok even when the token is near/just expired (no stale signal)" {
  local real="$TEST_TMPDIR/main-auth-profiles.json"
  local past_ms=$(( ($(date +%s) - 3600) * 1000 ))
  printf '{"version":1,"profiles":{"openai-codex:a@b":{"expires":%s}}}' "$past_ms" > "$real"
  ln -s "$real" "$TEST_TMPDIR/edge-auth-profiles.json"
  run codex_edge_auth_symlink_status "$TEST_TMPDIR/edge-auth-profiles.json"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "symlink_status: missing when nothing is at the path" {
  run codex_edge_auth_symlink_status "$TEST_TMPDIR/nope.json"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

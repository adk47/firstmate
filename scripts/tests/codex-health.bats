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

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
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm the watchdog during CI (it runs on the live node-8 host). Pin the
  # flag at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"

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

# ── codex_count_apikey_route: 2026-07-06 fail-OPEN regression ──
# On 2026-07-06 the whole fleet mis-routed to the api-key endpoint (#90925) while the
# write-health gate reported HEALTHY. openclaw circuit-broke gpt-5.5 for normal turns
# (they routed straight to mini, no api-key string), so the ONLY api-key records left
# were the periodic background-summarization retries — whose `detail=Summarization
# failed` an over-broad compaction filter then excluded, taking the fail-CLOSED write
# gate fail-OPEN. A genuine route-failure record MUST count regardless of the
# summarization/compaction wording in its detail; only raw transport probes and
# agent/chat text are excluded.

@test "apikey_route: a real route failure counts even when detail says 'Summarization failed' (2026-07-06 fail-open regression)" {
  run codex_count_apikey_route <<'EOF'
Jul 06 19:42:48 ovh-node-8 node[1211532]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth next=openrouter/openai/gpt-5.4-mini detail=Summarization failed: 401 Incorrect API key provided: sk-hydra******2026. You can find your API key at https://platform.openai.com/account/api-keys.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "apikey_route: a bare [openai-transport] compaction probe (no fallback decision) stays 0" {
  # Background compaction probing the Responses endpoint with the placeholder key
  # logs a raw transport 401 but never reaches a fallback decision — genuinely benign,
  # must not trip the gate on its own. This is #643's legitimate de-noising, kept.
  run codex_count_apikey_route <<'EOF'
Jul 06 19:13:34 ovh-node-8 node[1211532]: [agent/embedded] skipping codex app-server compaction for non-manual trigger
Jul 06 19:13:35 ovh-node-8 node[1211532]: [openai-transport] [responses] error provider=openai api=openai-responses model=gpt-5.5 name=Error status=401 code=invalid_api_key type=invalid_request_error message=401 Incorrect API key provided: sk-hydra******2026.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "apikey_route: agent/chat text repeating 'invalid_api_key' is not counted" {
  # A QA/agent session discussing the incident must not be read as degradation.
  run codex_count_apikey_route <<'EOF'
Jul 06 19:27:43 ovh-node-8 node[1211532]: [agent:nested] session=agent:qa:main channel=webchat a real #90925 invalid_api_key hit followed by a compaction marker must still count.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "apikey_route: real summarization route failure counts amid benign probe + compaction noise" {
  # The full 2026-07-06 shape: raw probe (ignored) + compaction-diag (ignored) + the
  # real reason=auth fallback record (counted). The gate must see the degradation.
  run codex_count_apikey_route <<'EOF'
Jul 06 19:13:35 ovh-node-8 node[1211532]: [openai-transport] [responses] error provider=openai api=openai-responses model=gpt-5.5 status=401 code=invalid_api_key message=401 Incorrect API key provided: sk-hydra******2026.
Jul 06 19:13:35 ovh-node-8 node[1211532]: [agent/embedded] [compaction-diag] end runId=99999d25 sessionKey=agent:qa:main trigger=cli_budget provider=openai/gpt-5.5 outcome=failed reason=provider_error_4xx
Jul 06 19:13:35 ovh-node-8 node[1211532]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth next=openrouter/openai/gpt-5.4-mini detail=Summarization failed: 401 Incorrect API key provided: sk-hydra******2026.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "apikey_route: a real route failure carrying channel= session context still counts (no whole-line agent-text exclusion)" {
  # The record is identified by its LEADING [model-fallback/decision] tag; a channel=
  # field further down the line must NOT drop it. Excluding on that substring would be a
  # second fail-open of the same class as the summarization one — this pins against it.
  run codex_count_apikey_route <<'EOF'
Jul 06 19:42:48 ovh-node-8 node[1211532]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth channel=slack next=openrouter/openai/gpt-5.4-mini detail=401 Incorrect API key provided: sk-hydra******2026.
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

# ── codex_apikey_route_verdict ────────────────────────────────
# Classifies a nonzero api-key-route 401 count by the ACTUAL pin state so the
# watchdog stops blaming EVERY such 401 on a version float. pin_exit mirrors
# ensure-codex-version-pinned.sh --check: 0 clean / 1 drift / 2 read-err.

@test "verdict: no 401s → none (regardless of pin state)" {
  run codex_apikey_route_verdict 0 0
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
  run codex_apikey_route_verdict 0 1
  [ "$output" = "none" ]
}

@test "verdict: 401s AND pin drifted (exit 1) → float (genuine #90925)" {
  run codex_apikey_route_verdict 5 1
  [ "$status" -eq 0 ]
  [ "$output" = "float" ]
}

@test "verdict: 401s but pin CLEAN (exit 0) → compaction (NOT a float)" {
  # The 2026-07-06 case: 2 invalid_api_key 401s, both agent:qa:main compaction,
  # pin clean. Must NOT be classified as a float (re-pin would be a no-op).
  run codex_apikey_route_verdict 2 0
  [ "$status" -eq 0 ]
  [ "$output" = "compaction" ]
}

@test "verdict: 401s but pin UNVERIFIABLE (exit 2) → unverifiable" {
  run codex_apikey_route_verdict 3 2
  [ "$status" -eq 0 ]
  [ "$output" = "unverifiable" ]
}

@test "verdict: defaults are safe (missing args → none / unverifiable, never float)" {
  run codex_apikey_route_verdict
  [ "$output" = "none" ]           # count defaults to 0
  run codex_apikey_route_verdict 1 # pin_exit defaults to 2 (unverifiable), not float
  [ "$output" = "unverifiable" ]
}

# ── codex_health_gate: api-key-401 pin discrimination ─────────
# The admin/Stripe write gate must NOT refuse a write on a compaction-only api-key 401
# (pin clean → fleet healthy for real turns, 2026-07-06 QA-lane case), but must stay
# fail-CLOSED on a genuine float or an unverifiable pin. journalctl and the pin --check
# are both stubbed (PATH + CODEX_PIN_CHECK_BIN), so no real openclaw is touched.

# Stub journalctl to emit ONE genuine api-key route-failure record (what #644 counts).
_gate_journal_apikey() {
  cat > "$TEST_TMPDIR/bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "Jul 06 19:42:48 ovh-node-8 node[1211532]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.5 candidate=openai/gpt-5.5 reason=auth next=openrouter/openai/gpt-5.4-mini detail=Summarization failed: 401 Incorrect API key provided: sk-hydra******2026."
SH
  chmod +x "$TEST_TMPDIR/bin/journalctl"
}

# Write a fake ensure-codex-version-pinned.sh that exits $1 on --check; echo its path.
_fake_pin() {
  local code="$1"
  cat > "$TEST_TMPDIR/bin/pin-$code.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = "--check" ] && exit $code
exit 0
SH
  chmod +x "$TEST_TMPDIR/bin/pin-$code.sh"
  echo "$TEST_TMPDIR/bin/pin-$code.sh"
}

@test "gate: api-key 401 with pin CLEAN → healthy (compaction, write ALLOWED)" {
  _gate_journal_apikey
  CODEX_PIN_CHECK_BIN="$(_fake_pin 0)" run codex_health_gate test-unit 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"compaction-only"* ]]
}

@test "gate: api-key 401 with pin DRIFTED → DEGRADED (real float, write REFUSED)" {
  _gate_journal_apikey
  CODEX_PIN_CHECK_BIN="$(_fake_pin 1)" run codex_health_gate test-unit 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEGRADED"* ]]
  [[ "$output" == *"float"* ]]
}

@test "gate: api-key 401 with pin UNVERIFIABLE → DEGRADED (fail-closed on a write gate)" {
  _gate_journal_apikey
  CODEX_PIN_CHECK_BIN="$(_fake_pin 2)" run codex_health_gate test-unit 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"DEGRADED"* ]]
}

@test "pin_check_exit: missing / non-executable bin → 2 (unverifiable)" {
  CODEX_PIN_CHECK_BIN="/nonexistent/pin.sh" run codex_pin_check_exit
  [ "$status" -eq 2 ]
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

# ── codex_count_websearch_reconnect ───────────────────────────
# 2026-07 incident: PR #695 set tools.web.search.provider:"codex" on main,
# which disabled native codex search on openclaw 7.1 and left the managed
# worker unable to authenticate — every web_search call spun Reconnecting
# before failing. Silent for ~15min post-restart; #701 reverted the config.

@test "websearch_reconnect: counts the Reconnecting signature" {
  run codex_count_websearch_reconnect <<'EOF'
Jul 15 09:12:03 ovh-node-8 node[123456]: [tools] web_search failed: Reconnecting... 2/5
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "websearch_reconnect: counts the provider reconnection failed signature" {
  run codex_count_websearch_reconnect <<'EOF'
Jul 15 09:12:04 ovh-node-8 node[123456]: [tools] web_search failed: provider reconnection failed
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "websearch_reconnect: sums both signatures across lines" {
  run codex_count_websearch_reconnect <<'EOF'
Jul 15 09:12:03 ovh-node-8 node[123456]: [tools] web_search failed: Reconnecting... 2/5
Jul 15 09:12:05 ovh-node-8 node[123456]: [tools] web_search failed: Reconnecting... 3/5
Jul 15 09:12:08 ovh-node-8 node[123456]: [tools] web_search failed: provider reconnection failed
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ]
}

@test "websearch_reconnect: a clean log is 0 (no false positive)" {
  run codex_count_websearch_reconnect <<'EOF'
Jul 15 09:12:03 ovh-node-8 node[123456]: [tools] web_search ok: found 5 results
Jul 15 09:12:04 ovh-node-8 node[123456]: run agent end isError=false
EOF
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "websearch_reconnect: an UNRELATED 'provider reconnection failed' does NOT match" {
  # A managed-provider/tool reconnect with no web_search context must not
  # false-page as web_search BROKEN (would send operators to the wrong fix).
  run codex_count_websearch_reconnect <<'EOF'
Jul 15 09:12:03 ovh-node-8 node[123456]: [tools] some_other_tool failed: provider reconnection failed
Jul 15 09:12:04 ovh-node-8 node[123456]: provider reconnection failed
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

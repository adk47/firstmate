#!/usr/bin/env bats
# Tests for scripts/codex-keepalive.sh — the PROACTIVE codex OAuth expiry
# safety-net pager (pages BEFORE the token lapses; the watchdog only fires AFTER
# the 401 storm; the twice-weekly codex-token-refresh timer does the actual refresh).
# Hermetic: reads a throwaway canonical auth store (openclaw 2026.7.x stripped
# all expiry data from `models status --json`, so the keepalive reads the store
# file we own directly), PATH-shadows `muso` (records would-be Slack pages) and
# `ssh` (see memory/feedback_bats_must_stub_openclaw.md).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-keepalive.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm this pager during CI (it runs on the live node-8 host). Pin the flag
  # at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/state"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"

  # Throwaway canonical store root: the keepalive reads
  # <root>/.openclaw-<profile>/agents/main/agent/auth-profiles.json.
  export CODEX_KEEPALIVE_STORE_ROOT="$TEST_TMPDIR/root"
  STORE_DIR="$TEST_TMPDIR/root/.openclaw-main/agents/main/agent"
  mkdir -p "$STORE_DIR"

  # muso stub: record `slack send` calls so tests can assert a page fired.
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"

  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE=/dev/null
  export KEEPALIVE_STATE_DIR="$TEST_TMPDIR/state"
  export CODEX_KEEPALIVE_COOLDOWN_MIN=60

  # Usage-cap detection seams — hermetic defaults: an EMPTY journal (no cap
  # signature; the real journalctl must never be consulted, this suite may run
  # on the live node-8 CI runner) and a RECORDING rotate stub (rc settable via
  # state/rotate-rc) so no test can ever drain-restart a real gateway.
  export ROTATE_LOG="$TEST_TMPDIR/rotate.log"
  export CODEX_KEEPALIVE_JOURNAL_BIN="$TEST_TMPDIR/bin/journalctl-stub"
  cat > "$TEST_TMPDIR/bin/journalctl-stub" <<STUB
#!/bin/bash
cat "$TEST_TMPDIR/state/journal-fixture" 2>/dev/null
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl-stub"
  export CODEX_KEEPALIVE_ROTATE_BIN="$TEST_TMPDIR/bin/rotate-stub"
  cat > "$TEST_TMPDIR/bin/rotate-stub" <<STUB
#!/bin/bash
echo "rotate \$*" >> "$ROTATE_LOG"
exit "\$(cat "$TEST_TMPDIR/state/rotate-rc" 2>/dev/null || echo 0)"
STUB
  chmod +x "$TEST_TMPDIR/bin/rotate-stub"
  export CODEX_ROTATE_STAMP="$TEST_TMPDIR/state/rotate-stamp"
  # Hermeticity for the proactive/quota paths: archives + rollout scans stay
  # inside the sandbox (this suite may run on the node-8 CI runner as root).
  export CODEX_USAGE_ARCHIVE_DIR="$TEST_TMPDIR/archive"
}

# Write a rollout snapshot under the sandbox store root.
# _set_active_snapshot <age_seconds> <window_minutes> <used_pct> <resets_in_seconds>
_set_active_snapshot() {
  local age="$1" wm="$2" pct="$3" rin="$4" now ts iso sess
  now="$(date +%s)"; ts="$(( now - age ))"
  iso="$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%S.000Z)"
  sess="$CODEX_KEEPALIVE_STORE_ROOT/.openclaw-main/agents/clio/agent/codex-home/sessions/2026/07/21"
  mkdir -p "$sess"
  cat > "$sess/rollout-snap.jsonl" <<JSON
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":$pct,"window_minutes":$wm,"resets_at":$(( now + rin ))},"secondary":null}}
JSON
}

# Write a journal fixture carrying N usage-cap fallback lines.
_set_cap_signature() {
  local n="${1:-1}" i
  : > "$TEST_TMPDIR/state/journal-fixture"
  for (( i = 0; i < n; i++ )); do
    echo 'node[1]: [auto-reply] dispatch notice="Model Fallback: openrouter/openai/gpt-5.6-luna (selected openai/gpt-5.6-sol; You'"'"'ve reached your Codex subscription usage limit. Next reset in 4 days)"' \
      >> "$TEST_TMPDIR/state/journal-fixture"
  done
}

# Real 2026-07-27 gateway wording for a server-side session revocation.
_set_revoked_signature() {
  local n="${1:-1}" i
  : > "$TEST_TMPDIR/state/journal-fixture"
  for (( i = 0; i < n; i++ )); do
    echo 'node[1]: [model-fallback/decision] model fallback decision: decision=candidate_failed requested=openai/gpt-5.6-sol candidate=openai/gpt-5.6-sol reason=auth_permanent next=openrouter/openai/gpt-5.6-luna detail=Your access token could not be refreshed. Please log out and sign in again.' \
      >> "$TEST_TMPDIR/state/journal-fixture"
  done
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Write a canonical store whose soonest codex expiry is N minutes from now.
_set_remaining_min() {
  local exp_a exp_b
  exp_a=$(( ( $(date +%s) + $1 * 60 ) * 1000 ))
  exp_b=$(( exp_a + 86400000 ))   # second profile expires later; min() must win
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","provider":"openai-codex","access":"A","refresh":"R","expires":$exp_a},
  "openai-codex:b@x.com":{"type":"oauth","provider":"openai-codex","access":"B","refresh":"R","expires":$exp_b}
}}
JSON
}

@test "healthy token (well above warn window) → no page, logs healthy" {
  _set_remaining_min 10080   # 7 days, default WARN_MIN=2880 (2 days)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "expiring token (< warn window) → pages #clio_devops pre-emptively" {
  _set_remaining_min 60
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "slack send" "$PAGE_LOG"
}

@test "steady-state trough (3 days, above the 2-day warn) → no false page" {
  # The whole point of WARN_MIN=2880: the twice-weekly refresh keeps the token at
  # ~6.5d, and even a single missed run only dips to ~3d — which must NOT page.
  _set_remaining_min 4320   # 3 days
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "page text points at the refresh helper, not the broken device-code login" {
  _set_remaining_min 60
  run "$SCRIPT"
  grep -q "codex-oauth-refresh.sh" "$PAGE_LOG"
  ! grep -q "auth login --provider openai-codex" "$PAGE_LOG"
}

@test "already-expired token → NO page (reactive watchdog owns it)" {
  _set_remaining_min -200   # expired 200 min ago
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALREADY EXPIRED"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "min() across profiles: the SOONEST expiry wins even when listed LAST" {
  # Both aaron accounts stay logged in, so the store carries >1 openai-codex
  # profile; the pager must key on the SOONEST-lapsing one. A regression from
  # min() to first()/.[0] would read the healthy first profile and never page
  # while the second account silently lapsed. Fixture deliberately lists the
  # HEALTHY profile first and the SOON one second so first-vs-min diverge.
  local exp_healthy exp_soon
  exp_healthy=$(( ( $(date +%s) + 10080 * 60 ) * 1000 ))   # 7 days (first)
  exp_soon=$(( ( $(date +%s) + 60 * 60 ) * 1000 ))         # 60 min (last, sooner)
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{
  "openai-codex:healthy@x.com":{"type":"oauth","provider":"openai-codex","access":"A","refresh":"R","expires":$exp_healthy},
  "openai-codex:soon@x.com":{"type":"oauth","provider":"openai-codex","access":"B","refresh":"R","expires":$exp_soon}
}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]   # min() → 60m → pages; first() → 7d → would log healthy
  [ -s "$PAGE_LOG" ]
}

@test "no openai-codex profile in the store → BLIND page (was a silent skip pre-2026.7.1)" {
  # Regression: after the 7.1 upgrade the keepalive logged "no openai-codex auth
  # profile found — skipping" every 15 min for hours while the fleet 401'd —
  # fail-open. Blindness on this box is always breakage and must page.
  printf %s '{"profiles":{"anthropic:tok":{"type":"oauth","expires":99}}}' \
    > "$STORE_DIR/auth-profiles.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLIND"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "BLIND" "$PAGE_LOG"
}

@test "canonical store missing/unreadable → BLIND page" {
  # No auth-profiles.json written at all.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BLIND"* ]]
  [ -s "$PAGE_LOG" ]
  grep -q "BLIND" "$PAGE_LOG"   # the page that fired is the BLIND page, not some other alert
}

@test "blind page respects its own cooldown (no 15-min page storm)" {
  date +%s > "$TEST_TMPDIR/state/codex-keepalive-main-blind-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within cooldown"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "cooldown: a second expiring run within cooldown does not re-page" {
  _set_remaining_min 60
  date +%s > "$TEST_TMPDIR/state/codex-keepalive-main-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"within cooldown"* ]]
  [ ! -s "$PAGE_LOG" ]
}

# ── usage-cap auto-rotation (2026-07-21 incident: active sub capped while a
#    fresh standby idled; fleet rode the PAID OpenRouter rung for hours) ──────

@test "cap signature in journal → invokes account rotate --auto" {
  _set_remaining_min 10080
  _set_cap_signature 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--auto" "$ROTATE_LOG"
}

@test "no cap signature → rotate never invoked" {
  _set_remaining_min 10080
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "cap signature but a rotation ran inside the window → no re-rotate (old lines still in journal)" {
  _set_remaining_min 10080
  _set_cap_signature 2
  date +%s > "$CODEX_ROTATE_STAMP"   # just rotated; signature lines predate it
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
  [[ "$output" == *"rotation ran"* ]]
}

@test "rotate refuses on cooldown (rc=3) → no-rotation-target page, cooldown-limited" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 3 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Wording is "no rotation target left", not "BOTH accounts": the fleet has
  # THREE linked codex accounts as of 2026-07-28, so rc=3/rc=7 mean "no viable
  # candidate remains", not "both are spent".
  grep -q "no rotation target left" "$PAGE_LOG"
  # second run inside the page cooldown must not re-page
  : > "$PAGE_LOG"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$PAGE_LOG" ]
}

@test "rotate reports no standby (rc=4) → honest no-standby page" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 4 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "NO viable standby" "$PAGE_LOG"
}

@test "cap detection failure-mode: expiry checks still run when journal stub is empty" {
  # The cap block must never break the original expiry safety net.
  _set_remaining_min 60
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]
  [ -s "$PAGE_LOG" ]
}

@test "rotate reports standby known-capped (rc=7) → no-rotation-target page with reset ETA" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 7 > "$TEST_TMPDIR/state/rotate-rc"
  # standby archive: weekly capped, resets in ~25h → page must carry the ETA
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '1\t-\t10080\t98\t%s\t-\t-\t-\n' "$(( $(date +%s) + 90000 ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_x.snapshot.tsv"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "no rotation target left" "$PAGE_LOG"
  grep -q "known-capped" "$PAGE_LOG"
  grep -q "Earliest known quota reset: in 1d" "$PAGE_LOG"
}

# ── proactive rotation (rotate BEFORE the cap error ever fires) ──────────────

@test "proactive: fresh snapshot >= threshold with far reset → rotate --auto with proactive reason" {
  _set_remaining_min 10080
  _set_active_snapshot 300 10080 96 200000   # 5min old, weekly 96%, resets ~2.3d
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--auto" "$ROTATE_LOG"
  grep -q "proactive: weekly at 96% used" "$ROTATE_LOG"
}

@test "proactive: below threshold → no rotate" {
  _set_remaining_min 10080
  _set_active_snapshot 300 10080 80 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: window resets soon (< MIN_RESET) → ride it out, no rotate" {
  _set_remaining_min 10080
  _set_active_snapshot 300 10080 99 1200   # resets in 20min < 60min floor
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: stale snapshot (> FRESH_MIN) → no rotate" {
  _set_remaining_min 10080
  _set_active_snapshot "$(( 3 * 3600 ))" 10080 99 200000   # 3h old vs 90min freshness
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: recent rotation stamp suppresses the check" {
  _set_remaining_min 10080
  _set_active_snapshot 300 10080 99 200000
  date +%s > "$CODEX_ROTATE_STAMP"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: rotate declines (rc=7 standby capped) → quiet log, NO page" {
  _set_remaining_min 10080
  _set_active_snapshot 300 10080 97 200000
  echo 7 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  [[ "$output" == *"rotate declined rc=7"* ]]
  [ ! -s "$PAGE_LOG" ]
}

@test "reactive cap signature wins the tick: proactive does not double-fire" {
  _set_remaining_min 10080
  _set_cap_signature 2
  _set_active_snapshot 300 10080 99 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--auto' "$ROTATE_LOG")" -eq 1 ]
  grep -q "usage cap (keepalive auto-rotate)" "$ROTATE_LOG"
}

# ── session revocation → auto-rotate (2026-07-27) ─────────────────────────────
# The 2h outage happened with two credentialed accounts idle: nothing connected
# "the active account is dead" to the rotation lever that already existed.
# Detection alone would not have shortened it — these lock in the reflex.

@test "session-revocation signature → invokes account rotate --auto" {
  _set_remaining_min 10080
  _set_revoked_signature 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--auto" "$ROTATE_LOG"
  grep -q "session revoked upstream" "$ROTATE_LOG"
}

@test "no revocation signature → rotate never invoked" {
  _set_remaining_min 10080
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "revocation signature but a rotation ran inside the window → no re-rotate" {
  # Right after a rotation the OLD revocation lines are still inside the journal
  # window; re-firing would burn the rotate cooldown and flap accounts.
  _set_remaining_min 10080
  _set_revoked_signature 2
  date +%s > "$CODEX_ROTATE_STAMP"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "revocation rotate is attempted ONCE per tick, not once per signature class" {
  # A cap and a revocation can both be live in one window (a capped account that
  # was also revoked). Two rotations in one tick would flap.
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 'node[1]: detail=Your access token could not be refreshed. Please log out and sign in again.' \
    >> "$TEST_TMPDIR/state/journal-fixture"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '--auto' "$ROTATE_LOG")" -eq 1 ]
}

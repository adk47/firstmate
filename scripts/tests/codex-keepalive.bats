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

  # ITEM F / HERMETICITY: pin the runtime this suite tests. codex-keepalive.sh
  # now branches on `openclaw --version` (>= 2026.8 projects the SQLite cell;
  # below that it reads the canonical JSON). Without a stub the branch is
  # decided by whatever node-8 happens to be running, which is exactly how
  # codex-oauth-refresh.bats silently went red across the 2026-09-10 cutover.
  # Default to a pre-8 runtime so the existing JSON-store tests keep asserting
  # the semantics they were written for; the cell tests below override this.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'OCSTUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "openclaw 2026.7.1"; exit 0; }
exit 0
OCSTUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

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
  # The measured-quota paths resolve the ACTIVE account via codex-active-account.sh,
  # whose precedence is env > state file > baked default. Without these two the
  # suite read the REAL /var/lib/hydra/codex-active-account on node-8 and fell
  # back to the baked aaron@muso.ai — so every measurement fixture was filed
  # under a key the script never looked up, and the guard under test was
  # unreachable. Pin both into the sandbox, same as codex-account-rotate.bats.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/state/active-account"
  export CODEX_ACTIVE_ACCOUNT_DEFAULT="openai-codex:a@x.com"
}

# Write a rollout snapshot under the sandbox store root.
# _set_active_snapshot <age_seconds> <window_minutes> <used_pct> <resets_in_seconds>
# _set_active_measurement <age_secs> <window_minutes> <used_pct> <reset_in_secs>
# Write a MEASURED quota row for the active account (the baked-default
# openai-codex:a@x.com, which caa_active_key resolves to with no state file).
# Same argument shape as _set_active_snapshot so the proactive tests read as a
# straight swap: the proactive path now decides on measured evidence instead of
# the account-blind fleet-wide rollout it used to read.
_set_active_measurement() {
  local age="$1" wm="$2" pct="$3" rin="$4" now
  now="$(date +%s)"
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t%s\t%s\t%s\t-\t-\t-\tprobe-live\tpro\n' \
    "$(( now - age ))" "$wm" "$pct" "$(( now + rin ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_a_x.com.measure.tsv"
}

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

@test "rotate refuses on cooldown (rc=3) → cooldown page that makes NO quota claim" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 3 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # rc 3 means "we rotated recently", which is a statement about OUR clock and
  # nothing else. It previously shared a headline with rc 7 ("every alternate
  # account is known-capped"), and that merge is how the false 2026-08-05 page
  # asserted three exhausted subscriptions while two sat at 4% and 0%.
  grep -q "rotation deferred" "$PAGE_LOG"
  grep -q "cooldown" "$PAGE_LOG"
  run grep -q "capped" "$PAGE_LOG"
  [ "$status" -ne 0 ]
  # second run inside the page cooldown must not re-page
  : > "$PAGE_LOG"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$PAGE_LOG" ]
}

@test "rotate reports no standby (rc=4) → structural page, not a quota claim" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 4 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "no standby account exists" "$PAGE_LOG"
  grep -q "STRUCTURAL" "$PAGE_LOG"
}

@test "rotate cannot measure any alternate (rc=8) → UNKNOWN page that denies a cap claim" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 8 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "cannot measure alternate account quota" "$PAGE_LOG"
  # The page must explicitly disown the claim the old merged headline made.
  grep -q "NOT a claim that those accounts are capped" "$PAGE_LOG"
}

# ── THE HEADLINE GUARD ───────────────────────────────────────────────────────
# The behaviour this whole change is named for: a cap signature in the journal
# is NOT evidence about the account WE run. openclaw's embedded path rotates
# its own auth.order profiles and retries a spent head profile every ~75s
# forever, so on 2026-08-05/06 aaron@muso.ai at 100% produced 143 cap lines in
# three hours while our active account sat at 0% — and this script rotated the
# state file (a different surface), burned the cooldown, and paged that every
# account was capped.
#
# These three tests pin the whole decision table. Until CODEX_KEEPALIVE_CANON
# derived from the sandbox store root, none of them could even reach the guard.

@test "guard: cap signature + FRESH measured-healthy active → no rotate, says it is not ours" {
  _set_remaining_min 10080
  _set_cap_signature 5
  _set_active_measurement 300 10080 10 200000    # 5min old, 10% used
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
  grep -q "NOT our active account" "$PAGE_LOG"
  grep -q "auth.order" "$PAGE_LOG"
}

@test "guard: a STALE healthy reading must NOT veto a real cap" {
  # The collector runs every 20min and an account at 85% can be at 100% inside
  # the hour, so vetoing on a 59-minute-old "healthy" row suppressed genuine
  # caps. Anything older than one collector cycle plus slack falls through to
  # the rotate actuator, which decides on its own measured gates.
  _set_remaining_min 10080
  _set_cap_signature 5
  _set_active_measurement 3000 10080 10 200000   # 50min old > 25min veto window
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--auto" "$ROTATE_LOG"
}

@test "guard: measured-CAPPED active rotates AND allows an unmeasured target" {
  # Our account is provably spent, so any reachable standby beats the paid
  # rung — refusing for want of a measurement would strand the fleet. The
  # rotate script still pages that the target was unverified.
  _set_remaining_min 10080
  _set_cap_signature 5
  _set_active_measurement 300 10080 100 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--allow-unmeasured" "$ROTATE_LOG"
}

@test "guard: session revocation always allows an unmeasured target" {
  # A revoked session means the active account is DEAD. rc 8 protects an
  # ELECTIVE choice and must never be able to fire here — that would recreate
  # the 2026-07-27 ~2h outage where the fleet rode openrouter while a healthy
  # standby idled.
  _set_remaining_min 10080
  _set_revoked_signature 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--allow-unmeasured" "$ROTATE_LOG"
}

@test "proactive: a FUTURE-dated measurement must not trigger a rotate" {
  _set_remaining_min 10080
  _set_active_measurement "-7200" 10080 99 200000   # dated 2h in the FUTURE
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "a FUTURE-dated rotate stamp must not suppress cap handling" {
  # _rotated_recently would report "we just rotated" forever on a rolled-back
  # clock, skipping BOTH cap and revocation handling.
  _set_remaining_min 10080
  _set_cap_signature 3
  _set_active_measurement 300 10080 100 200000
  echo "$(( $(date +%s) + 86400 ))" > "$CODEX_ROTATE_STAMP"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
}

@test "cap+revocation in one tick with UNKNOWN quota: revocation still gets its rotate" {
  # CAP_ACTED used to be set BEFORE the cap rotate, so a cap attempt that
  # changed nothing (rc 8, quota unknown) still blocked _check_session_revoked
  # — the one handler that passes --allow-unmeasured, because a revoked
  # account is provably dead. Every tick repeated it and the fleet stayed on
  # the paid rung while the reflex that could rescue it never ran.
  _set_remaining_min 10080
  # both signatures in one journal fixture, no measurement on disk => unknown
  _set_cap_signature 2
  _set_revoked_signature 2 >> /dev/null
  {
    echo 'node[1]: [auto-reply] dispatch notice="You'"'"'ve reached your Codex subscription usage limit."'
    echo 'node[1]: [model-fallback/decision] reason=auth_permanent detail=Your access token could not be refreshed. Please log out and sign in again.'
  } > "$TEST_TMPDIR/state/journal-fixture"
  echo 8 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # the revocation attempt must have happened, carrying --allow-unmeasured
  grep -q -- "--allow-unmeasured" "$ROTATE_LOG"
  grep -q "session revoked upstream" "$ROTATE_LOG"
}

@test "a FUTURE-dated cooldown stamp must not swallow a page" {
  # `now - last` goes negative on a rolled-back clock or a bad manual write, so
  # the >= comparison fails and the stamp reads as an eternally-active cooldown
  # — silently suppressing every page on it until wall time catches up. Paging
  # twice is recoverable; a page swallowed during an outage is not.
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 8 > "$TEST_TMPDIR/state/rotate-rc"
  echo "$(( $(date +%s) + 86400 ))" > "$KEEPALIVE_STATE_DIR/codex-keepalive-quotaunknown-cooldown"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "cannot measure alternate account quota" "$PAGE_LOG"
}

@test "rc 3, rc 7 and rc 8 each get their OWN cooldown stamp" {
  # Sharing one stamp would let whichever state fired first mask the others for
  # an hour — and they need different human responses.
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 3 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  grep -q "rotation deferred" "$PAGE_LOG"
  : > "$PAGE_LOG"
  # a DIFFERENT state must still page even though rc 3 just did
  echo 8 > "$TEST_TMPDIR/state/rotate-rc"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "cannot measure alternate account quota" "$PAGE_LOG"
}

@test "cap detection failure-mode: expiry checks still run when journal stub is empty" {
  # The cap block must never break the original expiry safety net.
  _set_remaining_min 60
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXPIRING"* ]]
  [ -s "$PAGE_LOG" ]
}

@test "rotate reports every alternate MEASURED capped (rc=7) → page with reset ETA" {
  _set_remaining_min 10080
  _set_cap_signature 1
  echo 7 > "$TEST_TMPDIR/state/rotate-rc"
  # The ETA must come from a MEASUREMENT, not the legacy .snapshot.tsv archive:
  # on 2026-08-06 every archive carried one account's reset epoch, so an
  # inference-derived number inside a page framed as measured evidence would
  # hand the operator a confident wrong recovery time.
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '%s\t-\t10080\t98\t%s\t-\t-\t-\tprobe-live\tpro\n' \
    "$(date +%s)" "$(( $(date +%s) + 90000 ))" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_a_x.com.measure.tsv"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "every alternate account is measured CAPPED" "$PAGE_LOG"
  grep -q "Earliest MEASURED quota reset: in 1d" "$PAGE_LOG"
}

# ── proactive rotation (rotate BEFORE the cap error ever fires) ──────────────
# These now drive _set_active_measurement, not _set_active_rollout: the
# proactive path reads the active account's own MEASUREMENT. It previously read
# the fleet-wide rollout snapshot, which carries no account identity — so it
# could rotate off an unattributed number in the same tick that the reactive
# path had just declined to rotate on measured evidence.

@test "proactive: fresh snapshot >= threshold with far reset → rotate --auto with proactive reason" {
  _set_remaining_min 10080
  _set_active_measurement 300 10080 96 200000   # 5min old, weekly 96%, resets ~2.3d
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -s "$ROTATE_LOG" ]
  grep -q -- "--auto" "$ROTATE_LOG"
  grep -q "proactive: weekly at 96% used" "$ROTATE_LOG"
}

@test "proactive: below threshold → no rotate" {
  _set_remaining_min 10080
  _set_active_measurement 300 10080 80 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: window resets soon (< MIN_RESET) → ride it out, no rotate" {
  _set_remaining_min 10080
  _set_active_measurement 300 10080 99 1200   # resets in 20min < 60min floor
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: stale snapshot (> FRESH_MIN) → no rotate" {
  _set_remaining_min 10080
  _set_active_measurement "$(( 3 * 3600 ))" 10080 99 200000   # 3h old vs 90min freshness
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: recent rotation stamp suppresses the check" {
  _set_remaining_min 10080
  _set_active_measurement 300 10080 99 200000
  date +%s > "$CODEX_ROTATE_STAMP"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
}

@test "proactive: rotate declines (rc=7 standby capped) → quiet log, NO page" {
  _set_remaining_min 10080
  _set_active_measurement 300 10080 97 200000
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


# ── 2026.8+ SQLite cell projection ───────────────────────────────────────────
#
# The 2026-09-10 cutover archived the canonical auth-profiles.json into
# <stateDir>/state/openclaw.sqlite (config_machine_state row 'authProfiles.store',
# column value_json). This script kept reading the JSON path, so it went BLIND on
# every tick and paged hourly while providing ZERO coverage. These tests pin the
# projection AND its two deliberate properties: redaction, and the
# openai: -> openai-codex: namespace translation.

_kal_stub_runtime() {
  cat > "$TEST_TMPDIR/bin/openclaw" <<OCSTUB
#!/bin/bash
[ "\$1" = "--version" ] && { echo "openclaw $1"; exit 0; }
exit 0
OCSTUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

# _kal_seed_cell <profile> <expires-ms> [extra-json-for-profile]
# Builds a REAL SQLite cell keyed the way 8.2 keys it (openai:<email>) and
# carrying token material, so the redaction assertion has something to catch.
_kal_seed_cell() {
  local profile="$1" expires="$2"
  local db="$TEST_TMPDIR/root/.openclaw-$profile/state/openclaw.sqlite"
  mkdir -p "$(dirname "$db")"
  KAL_DB="$db" KAL_EXP="$expires" node --experimental-sqlite --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(process.env.KAL_DB);
    db.exec("create table if not exists config_machine_state (state_key TEXT PRIMARY KEY, value_json TEXT, updated_at_ms INTEGER)");
    const store = { profiles: {
      "openai:a@x.com": { provider: "openai", access: "SUPERSECRET_ACCESS_A", refresh: "SUPERSECRET_REFRESH_A", idToken: "SUPERSECRET_ID_A", expires: Number(process.env.KAL_EXP) },
      "openai:b@x.com": { provider: "openai", access: "SUPERSECRET_ACCESS_B", refresh: "SUPERSECRET_REFRESH_B", expires: Number(process.env.KAL_EXP) + 7200000 }
    } };
    db.prepare("insert or replace into config_machine_state (state_key, value_json, updated_at_ms) values (?,?,?)")
      .run("authProfiles.store", JSON.stringify(store), Date.now());
  '
}

@test "cell: on 2026.8.2 the projection is used and expiries are read from it" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  # 90 minutes out: comfortably valid, so no expiring page and NOT blind.
  _kal_seed_cell main "$(( ($(date +%s) + 5400) * 1000 ))"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The BLIND page is the tell that the projection did not happen.
  ! grep -qi "keepalive BLIND" "$PAGE_LOG" 2>/dev/null
}

@test "cell: an EXPIRING cell token still pages (coverage is genuinely restored)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  # 20 minutes out — inside the pre-expiry warning band.
  _kal_seed_cell main "$(( ($(date +%s) + 1200) * 1000 ))"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qiE "expiring|BLIND" "$PAGE_LOG" 2>/dev/null
}

@test "cell: the projection REDACTS — no token material reaches disk" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  _kal_seed_cell main "$(( ($(date +%s) + 5400) * 1000 ))"
  # KAL_CANON_DIR is honoured and NOT cleaned up, so we can inspect exactly what
  # the script wrote. This script is a MONITOR: it never needs a token, so a
  # token in its temp file would be a brand-new secret-on-disk surface.
  export KAL_CANON_DIR="$TEST_TMPDIR/canon"
  mkdir -p "$KAL_CANON_DIR"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -r "$KAL_CANON_DIR/main-auth-profiles.json" ]
  proj="$(cat "$KAL_CANON_DIR/main-auth-profiles.json")"
  [[ "$proj" != *"SUPERSECRET_ACCESS"* ]]
  [[ "$proj" != *"SUPERSECRET_REFRESH"* ]]
  [[ "$proj" != *"SUPERSECRET_ID"* ]]
  # and it DID carry the one field it needs
  [[ "$proj" == *"expires"* ]]
}

@test "cell: ids are translated openai: -> openai-codex: in the PROJECTION" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  _kal_seed_cell main "$(( ($(date +%s) + 5400) * 1000 ))"
  export KAL_CANON_DIR="$TEST_TMPDIR/canon"
  mkdir -p "$KAL_CANON_DIR"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Assert on the PROJECTED file, not on the seeded cell (asserting the seed
  # would be tautological). Without this translation the
  # startswith("openai-codex:") selectors match NOTHING and the script reads
  # "no codex profiles" — a silent false clean.
  keys="$(jq -r '.profiles | keys | join(",")' "$KAL_CANON_DIR/main-auth-profiles.json")"
  [[ "$keys" == *"openai-codex:a@x.com"* ]]
  [[ "$keys" == *"openai-codex:b@x.com"* ]]
  [[ "$keys" != *"\"openai:a@x.com\""* ]]
}

@test "cell: a MISSING cell on 2026.8.2 falls back and still pages BLIND (fail-safe)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  # No cell seeded, and no canonical JSON either.
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG" 2>/dev/null
}

@test "cell: missing cell + readable HEALTHY legacy JSON still pages BLIND (no false healthy)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  # QA finding on #931. The first version of the resolver fell back to any
  # readable canonical JSON when the cell projection failed. On >= 2026.8 the
  # runtime does not use that file, so a readable STALE one with future
  # expiries made _codex_remaining_ms report healthy and SUPPRESSED the BLIND
  # page while the real auth cell was unusable — blind-and-QUIET, the exact
  # failure this change exists to remove. Not hypothetical: doctor archives
  # that file beside the live path and the window runbook renamed one to
  # auth-profiles.json.SPENT-DO-NOT-USE-* because such files linger.
  _kal_stub_runtime 2026.8.2
  # NO cell seeded. A perfectly healthy-looking legacy JSON, 90 minutes out.
  exp=$(( ($(date +%s) + 5400) * 1000 ))
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{"openai-codex:a@x.com":{"access":"stale","refresh":"stale","expires":$exp}}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # It must NOT read that file and call the fleet healthy.
  grep -qi "keepalive BLIND" "$PAGE_LOG"
}

@test "cell: a readable legacy JSON does not mask a CORRUPT cell either" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  # A cell that exists but is not a usable sqlite database.
  mkdir -p "$TEST_TMPDIR/root/.openclaw-main/state"
  printf 'this is not sqlite' > "$TEST_TMPDIR/root/.openclaw-main/state/openclaw.sqlite"
  exp=$(( ($(date +%s) + 5400) * 1000 ))
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{"openai-codex:a@x.com":{"access":"stale","refresh":"stale","expires":$exp}}}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
}

# QA finding on #931 (round 3): with the cell FAILED, CODEX_KEEPALIVE_CANON used
# to stay pointed at the legacy JSON and the direct quota consumers
# (_active_measured_row, _measured_account_lines, _measured_earliest_reset_note)
# read it without the resolver. A readable stale JSON plus a fresh HEALTHY
# measurement for the state-file key then let _check_usage_cap call a live cap
# "not our active account" and skip rotation — the fleet stayed on the paid rung
# with a usable standby idle, while the expiry loop was correctly paging BLIND.
@test "cell: FAILED cell + stale healthy JSON + cap signature + fresh healthy measurement → cap check REFUSES (no rotate, no 'not ours'), BLIND still pages" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  mkdir -p "$TEST_TMPDIR/root/.openclaw-main/state"
  printf 'this is not sqlite' > "$TEST_TMPDIR/root/.openclaw-main/state/openclaw.sqlite"
  _kal_healthy_legacy_json
  _set_cap_signature 5
  _set_active_measurement 300 10080 10 200000    # 5min old, 10% used: the false-veto bait
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
  [ ! -s "$ROTATE_LOG" ]
  run grep -c "NOT our active account" "$PAGE_LOG"
  [ "$output" = "0" ]
  run "$SCRIPT"
  [[ "$output" == *"canonical auth store could not be resolved (runtime state=cell)"* ]]
  [[ "$output" == *"refusing to classify it as noise or to rotate"* ]]
}

@test "cell: UNKNOWN runtime + stale healthy JSON + cap signature + fresh healthy measurement → cap check REFUSES too" {
  _kal_stub_runtime "banana"
  _kal_healthy_legacy_json
  _set_cap_signature 5
  _set_active_measurement 300 10080 10 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
  [ ! -s "$ROTATE_LOG" ]
  run grep -c "NOT our active account" "$PAGE_LOG"
  [ "$output" = "0" ]
  [[ "$output" != *"NOT our active account"* ]]
}

@test "cell: with a HEALTHY cell the cap guard still reaches its decision table (not over-tightened)" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  _kal_seed_cell main "$(( ($(date +%s) + 5400) * 1000 ))"
  _set_cap_signature 5
  _set_active_measurement 300 10080 10 200000
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$ROTATE_LOG" ]
  grep -q "NOT our active account" "$PAGE_LOG"
}

@test "cell: on a PRE-2026.8 runtime the cell is ignored even if present" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.7.1
  # Seed a healthy cell but NO json store: a 7.1 runtime must not read the cell,
  # so it must still go BLIND rather than silently picking up 8.2 state.
  _kal_seed_cell main "$(( ($(date +%s) + 5400) * 1000 ))"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG" 2>/dev/null
}


# ── the version gate, with the system PUT IN each state ─────────────────────
# Three states, and the legacy JSON is trusted in exactly ONE of them. Added
# after the bot found that "cannot determine the version" silently took the
# pre-2026.8 path and read an obsolete file as healthy.

_kal_healthy_legacy_json() {
  exp=$(( ($(date +%s) + 5400) * 1000 ))
  cat > "$STORE_DIR/auth-profiles.json" <<JSON
{"profiles":{"openai-codex:a@x.com":{"access":"stale","refresh":"stale","expires":$exp}}}
JSON
}

@test "version EMPTY + healthy stale JSON -> BLIND naming the unknown version" {
  # openclaw missing or its --version silent. On a real 8.2 host this used to
  # read the obsolete JSON and report healthy.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'OCSTUB'
#!/bin/bash
exit 0
OCSTUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  _kal_healthy_legacy_json
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
  [[ "$output" == *"runtime version unknown"* ]]
}

@test "version GARBAGE + healthy stale JSON -> BLIND (no lenient parse)" {
  _kal_stub_runtime "banana"
  _kal_healthy_legacy_json
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
  [[ "$output" == *"runtime version unknown"* ]]
}

@test "version TRUNCATED (2026) + healthy stale JSON -> BLIND" {
  # A shape that would satisfy a loose numeric check but is not a release.
  _kal_stub_runtime "2026"
  _kal_healthy_legacy_json
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qi "keepalive BLIND" "$PAGE_LOG"
}

@test "version POSITIVELY pre-2026.8 + JSON -> the JSON path still works (not over-tightened)" {
  # The other direction: the fix must not break the one state where the legacy
  # store IS the truth, or 7.x hosts lose their keepalive entirely.
  _kal_stub_runtime 2026.7.1
  _kal_healthy_legacy_json
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qi "keepalive BLIND" "$PAGE_LOG" 2>/dev/null
}


# ── the BLIND page must name the store the RESOLVER selected ────────────────
# One per version state. A fixed path sends the responder to the wrong file on
# exactly the new failure path (missing/corrupt cell on 2026.8+).

@test "page text: on 2026.8+ names the CELL and its row, not the JSON" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi
  _kal_stub_runtime 2026.8.2
  run "$SCRIPT"        # no cell seeded -> BLIND
  [ "$status" -eq 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"state/openclaw.sqlite"* ]]
  [[ "$page" == *"authProfiles.store"* ]]
  [[ "$page" == *"codex-auth-invariants.sh --check"* ]]
  # must NOT send them to the archived JSON
  [[ "$page" != *"agents/main/agent/auth-profiles.json"* ]]
}

@test "page text: on a pre-2026.8 runtime names the canonical JSON" {
  _kal_stub_runtime 2026.7.1
  # no JSON present -> BLIND on the legacy path
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"agents/main/agent/auth-profiles.json"* ]]
  [[ "$page" != *"state/openclaw.sqlite"* ]]
}

@test "page text: on an UNKNOWN runtime names neither store and points at --version" {
  _kal_stub_runtime "banana"
  _kal_healthy_legacy_json
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"could not be determined"* ]]
  [[ "$page" == *"openclaw --version"* ]]
  [[ "$page" != *"state/openclaw.sqlite"* ]]
}

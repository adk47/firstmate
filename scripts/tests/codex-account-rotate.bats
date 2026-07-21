#!/usr/bin/env bats
# Tests for scripts/lib/codex-account-rotate.sh (the account-failover actuator)
# and scripts/lib/codex-active-account.sh (the deploy-proof active-account
# resolver). Born from the 2026-07-21 usage-cap incident: the active codex
# subscription capped while a paid, fresh standby idled, because nothing could
# switch accounts — sol/luna are model variants on ONE subscription, so the
# model-level fallback chain can never express "try the other account".
# Hermetic: throwaway canonical store + state files, PATH-shadowed
# systemctl/openclaw/muso (see memory/feedback_bats_must_stub_openclaw.md),
# stubbed codex-auth-sync.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
ROTATE="$HYDRA_REPO/scripts/lib/codex-account-rotate.sh"
CAA_LIB="$HYDRA_REPO/scripts/lib/codex-active-account.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/state" "$TEST_TMPDIR/canon"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"
  export SYNC_LOG="$TEST_TMPDIR/sync.log"
  export RESTART_LOG="$TEST_TMPDIR/restart.log"

  # Two-account canonical store (the live shape: aaron active, kaufman standby).
  export CANON_DIR="$TEST_TMPDIR/canon"
  cat > "$CANON_DIR/auth-profiles.json" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","provider":"openai-codex","email":"a@x.com","access":"ACCESS-A","refresh":"R-A","accountId":"uuid-a","expires":9999999999999},
  "openai-codex:k@y.com":{"type":"oauth","provider":"openai-codex","email":"k@y.com","access":"ACCESS-K","refresh":"R-K","accountId":"uuid-k","expires":9999999999999}
}}
JSON

  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/state/active"
  export CODEX_ACTIVE_ACCOUNT_DEFAULT="openai-codex:a@x.com"
  export CODEX_ROTATE_STAMP="$TEST_TMPDIR/state/stamp"
  export CODEX_ROTATE_SERVICES="gw-main.service gw-edge.service"
  export CODEX_ROTATE_COOLDOWN_MIN=120
  # Hermeticity: the archive + rollout scan must never touch live node-8 state
  # (this suite may run on the node-8 CI runner as root).
  export CODEX_USAGE_ARCHIVE_DIR="$TEST_TMPDIR/archive"
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/authroot"
  mkdir -p "$CODEX_AUTH_ROOT"

  # codex-auth-sync stub: records the invocation (incl. the CODEX_AUTH_PRIMARY
  # env rotate must pin explicitly); rc from a settable file.
  export CODEX_ROTATE_SYNC_BIN="$TEST_TMPDIR/bin/sync-stub"
  cat > "$TEST_TMPDIR/bin/sync-stub" <<STUB
#!/bin/bash
echo "sync env CODEX_AUTH_PRIMARY=\${CODEX_AUTH_PRIMARY:-<unset>} \$*" >> "$SYNC_LOG"
exit "\$(cat "$TEST_TMPDIR/state/sync-rc" 2>/dev/null || echo 0)"
STUB
  chmod +x "$TEST_TMPDIR/bin/sync-stub"

  # systemctl stub: records restarts, answers the drain lib's probes.
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
case "\$*" in
  *"show -p MainPID"*) echo 123; exit 0 ;;
  *is-failed*)         exit 1 ;;
  *is-active*)         exit 0 ;;
  *restart*)           echo "\$*" >> "$RESTART_LOG"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"

  # openclaw stub: safe-restart request fails (rc=1) so the drain lib takes the
  # hard-restart fallback — drain semantics themselves are covered by
  # gateway-restart.bats (same approach as codex-token-refresh.bats).
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"

  # muso stub: records would-be Slack pages.
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"

  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  export MUSO_SLACK_BOT_TOKEN_DEVOPS="xoxb-test"
  export MUSO_SLACK_ENV_FILE=/dev/null
  export GATEWAY_HARD_POLL_TRIES=1 GATEWAY_HARD_POLL_SECS=0
  export GATEWAY_DRAIN_DEADLINE_SECS=1 GATEWAY_DRAIN_POLL_SECS=1
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_canon="$TEST_TMPDIR/canon/auth-profiles.json"   # overwritten in setup-time expansions; use helper
canon() { echo "$CANON_DIR/auth-profiles.json"; }

# ── resolver (codex-active-account.sh) ──────────────────────────────────────

@test "resolver: no state file → baked default" {
  run bash -c "source '$CAA_LIB'; caa_active_key '$(canon)'"
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:a@x.com" ]
}

@test "resolver: valid state file wins over the default" {
  echo "openai-codex:k@y.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run bash -c "source '$CAA_LIB'; caa_active_key '$(canon)'"
  [ "$status" -eq 0 ]
  [ "$output" = "openai-codex:k@y.com" ]
}

@test "resolver: state file naming an unknown profile → default + stderr warning" {
  echo "openai-codex:ghost@nowhere.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run bash -c "source '$CAA_LIB'; caa_active_key '$(canon)'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"openai-codex:a@x.com"* ]]
  [[ "$output" == *"WARNING"* ]]
}

@test "resolver: caa_write_active is atomic and 0600" {
  run bash -c "source '$CAA_LIB'; caa_write_active 'openai-codex:k@y.com'"
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
  [ "$(stat -c %a "$CODEX_ACTIVE_ACCOUNT_FILE" 2>/dev/null || stat -f %Lp "$CODEX_ACTIVE_ACCOUNT_FILE")" = "600" ]
}

# ── rotate actuator ──────────────────────────────────────────────────────────

@test "--to <email> rotates: state written, sync ran, both gateways restarted, page sent, stamp written" {
  run "$ROTATE" --to k@y.com --reason "test rotation"
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
  [ -s "$SYNC_LOG" ]
  grep -q "restart gw-main.service" "$RESTART_LOG"
  grep -q "restart gw-edge.service" "$RESTART_LOG"
  grep -q "rotated" "$PAGE_LOG"
  [[ "$(cat "$CODEX_ROTATE_STAMP")" =~ ^[0-9]+$ ]]
}

@test "--to the already-active account → no-op exit 0: no sync, no restart, no page" {
  run "$ROTATE" --to a@x.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
  [ ! -s "$SYNC_LOG" ]
  [ ! -s "$RESTART_LOG" ]
  [ ! -s "$PAGE_LOG" ]
}

@test "cooldown: fresh stamp → exit 3, nothing changed" {
  date +%s > "$CODEX_ROTATE_STAMP"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 3 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
  [ ! -s "$SYNC_LOG" ]
  [ ! -s "$RESTART_LOG" ]
}

@test "--force bypasses the cooldown" {
  date +%s > "$CODEX_ROTATE_STAMP"
  run "$ROTATE" --to k@y.com --force
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
}

@test "--auto picks the profile that is not currently active" {
  # no state file → current = default a@x.com → auto target must be k@y.com
  run "$ROTATE" --auto
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
}

@test "--auto again after a rotation flips back (2-account round-robin)" {
  echo "openai-codex:k@y.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  run "$ROTATE" --auto --force
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:a@x.com" ]
}

@test "--auto with a single-account canonical → exit 4" {
  cat > "$(canon)" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","email":"a@x.com","access":"ACCESS-A","refresh":"R-A"}
}}
JSON
  run "$ROTATE" --auto
  [ "$status" -eq 4 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
}

@test "sync failure → state file restored, exit 5, no restart, critical page" {
  echo "openai-codex:a@x.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  echo 1 > "$TEST_TMPDIR/state/sync-rc"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 5 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:a@x.com" ]
  [ ! -s "$RESTART_LOG" ]
  grep -q "FAILED at auth sync" "$PAGE_LOG"
}

@test "sync failure with no prior state file → state file removed again" {
  echo 1 > "$TEST_TMPDIR/state/sync-rc"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 5 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
}

@test "target with no access token in canonical → exit 2 before any mutation" {
  cat > "$(canon)" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","email":"a@x.com","access":"ACCESS-A","refresh":"R-A"},
  "openai-codex:k@y.com":{"type":"oauth","email":"k@y.com","refresh":"R-K"}
}}
JSON
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 2 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
  [ ! -s "$SYNC_LOG" ]
}

@test "unknown target → exit 2" {
  run "$ROTATE" --to ghost@nowhere.com
  [ "$status" -eq 2 ]
  [ ! -s "$SYNC_LOG" ]
}

@test "CODEX_ROTATE_RESTART=0 → syncs, stamps, pages, but never restarts" {
  CODEX_ROTATE_RESTART=0 run "$ROTATE" --to k@y.com
  [ "$status" -eq 0 ]
  [ -s "$SYNC_LOG" ]
  [ ! -s "$RESTART_LOG" ]
  grep -q "rotated" "$PAGE_LOG"
}

@test "no arguments → exit 2 usage error" {
  run "$ROTATE"
  [ "$status" -eq 2 ]
}

@test "env CODEX_AUTH_PRIMARY defines 'current' for the no-op check" {
  # env says kaufman is active → rotating to kaufman is a no-op even though
  # the state file is absent (env wins over file+default, matching sync).
  CODEX_AUTH_PRIMARY="openai-codex:k@y.com" run "$ROTATE" --to k@y.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "an inherited CODEX_AUTH_PRIMARY override cannot pin the sync to the OLD account" {
  # QA finding (#719): rotate used to invoke sync with the caller's env intact —
  # an exported CODEX_AUTH_PRIMARY would make sync re-pin the old account and
  # exit 0 while the success page claimed the target was active. The sync must
  # be invoked with an explicit CODEX_AUTH_PRIMARY=<target>.
  CODEX_AUTH_PRIMARY="openai-codex:a@x.com" run "$ROTATE" --to k@y.com
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
  grep -q "env CODEX_AUTH_PRIMARY=openai-codex:k@y.com" "$SYNC_LOG"
}

@test "--to a target whose token is EXPIRED → exit 2, no mutation" {
  # QA finding (#719): a standby whose refresh has been failing must not be
  # rotated onto — the fleet would restart into a token_expired storm while
  # the script reports success.
  local past=$(( ( $(date +%s) - 3600 ) * 1000 ))
  cat > "$(canon)" <<JSON
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","email":"a@x.com","access":"ACCESS-A","refresh":"R-A","expires":9999999999999},
  "openai-codex:k@y.com":{"type":"oauth","email":"k@y.com","access":"ACCESS-K","refresh":"R-K","expires":$past}
}}
JSON
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"expire"* ]]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
  [ ! -s "$SYNC_LOG" ]
}

@test "--auto skips an expired-token candidate → exit 4 (no viable alternate)" {
  local past=$(( ( $(date +%s) - 3600 ) * 1000 ))
  cat > "$(canon)" <<JSON
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","email":"a@x.com","access":"ACCESS-A","refresh":"R-A","expires":9999999999999},
  "openai-codex:k@y.com":{"type":"oauth","email":"k@y.com","access":"ACCESS-K","refresh":"R-K","expires":$past}
}}
JSON
  run "$ROTATE" --auto
  [ "$status" -eq 4 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
}

@test "--auto skips a missing-access-token candidate → exit 4, not exit 2" {
  cat > "$(canon)" <<'JSON'
{"version":1,"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","email":"a@x.com","access":"ACCESS-A","refresh":"R-A","expires":9999999999999},
  "openai-codex:k@y.com":{"type":"oauth","email":"k@y.com","refresh":"R-K","expires":9999999999999}
}}
JSON
  run "$ROTATE" --auto
  [ "$status" -eq 4 ]
}

@test "--auto refuses a target whose ARCHIVED snapshot is still capped → exit 7" {
  # aaron (current) hits its cap; kaufman's archive from its last active stint
  # says weekly 98% with a FUTURE reset → rotating would land on another
  # capped subscription. rc 7 tells the keepalive "both capped".
  local future=$(( $(date +%s) + 90000 ))
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '1\t-\t10080\t98\t%s\t-\t-\t-\n' "$future" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_k_y.com.snapshot.tsv"
  run "$ROTATE" --auto
  [ "$status" -eq 7 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]
  [ ! -s "$SYNC_LOG" ]
  [ ! -s "$RESTART_LOG" ]
}

@test "--auto proceeds when the archived cap's reset has PASSED" {
  local past=$(( $(date +%s) - 100 ))
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '1\t-\t10080\t98\t%s\t-\t-\t-\n' "$past" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_k_y.com.snapshot.tsv"
  run "$ROTATE" --auto
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
}

@test "explicit --to bypasses the archived-cap viability gate" {
  local future=$(( $(date +%s) + 90000 ))
  mkdir -p "$CODEX_USAGE_ARCHIVE_DIR"
  printf '1\t-\t10080\t98\t%s\t-\t-\t-\n' "$future" \
    > "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_k_y.com.snapshot.tsv"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 0 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:k@y.com" ]
}

@test "successful rotation archives the OUTGOING account's freshest snapshot" {
  # A rollout under CODEX_AUTH_ROOT carries the active (a@x.com) account's
  # snapshot; after rotating to kaufman it must be archived under a@x.com.
  local sess="$CODEX_AUTH_ROOT/.openclaw-main/agents/clio/agent/codex-home/sessions/2026/07/21"
  mkdir -p "$sess"
  local now iso; now="$(date +%s)"
  iso="$(date -u -d "@$(( now - 300 ))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$(( now - 300 ))" +%Y-%m-%dT%H:%M:%S.000Z)"
  cat > "$sess/rollout-x.jsonl" <<JSON
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":97,"window_minutes":10080,"resets_at":$(( now + 200000 ))},"secondary":null}}
JSON
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 0 ]
  local arch="$CODEX_USAGE_ARCHIVE_DIR/openai-codex_a_x.com.snapshot.tsv"
  [ -r "$arch" ]
  [ "$(cut -f4 "$arch")" = "97" ]
}

@test "archive boundary: a snapshot predating the current account's activation is NOT archived under it" {
  # QA finding (#719, round 5): after A→B then a quick B→A before B emits any
  # rollout, the freshest snapshot is still A's — archiving it under B would
  # make a later --auto wrongly refuse a fresh B with rc 7.
  local sess="$CODEX_AUTH_ROOT/.openclaw-main/agents/clio/agent/codex-home/sessions/2026/07/21"
  mkdir -p "$sess"
  local now; now="$(date +%s)"
  local iso; iso="$(date -u -d "@$(( now - 3600 ))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -r "$(( now - 3600 ))" +%Y-%m-%dT%H:%M:%S.000Z)"
  cat > "$sess/rollout-old.jsonl" <<JSON
{"type":"event_msg","ts":"$iso","rate_limits":{"limit_id":"codex","primary":{"used_percent":99,"window_minutes":10080,"resets_at":$(( now + 200000 ))},"secondary":null}}
JSON
  date +%s > "$CODEX_ROTATE_STAMP"   # CURRENT became active just now (stamp newer than snapshot)
  run "$ROTATE" --to k@y.com --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping archive"* ]]
  [ ! -e "$CODEX_USAGE_ARCHIVE_DIR/openai-codex_a_x.com.snapshot.tsv" ]
}

@test "sync + state-RESTORE failure (prev state present) → still pages, page admits the file may name the target" {
  # QA finding (#719, round 3): a swallowed restore failure left logs/page
  # claiming the old state was restored while the file still named $TARGET —
  # the next heal would flip the fleet again. Failure injection is root-proof:
  # the sync stub replaces the state file's PARENT DIR with a regular file, so
  # the restoring caa_write_active's mkdir -p fails even for root.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/state/sub/active"
  mkdir -p "$TEST_TMPDIR/state/sub"
  echo "openai-codex:a@x.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  cat > "$TEST_TMPDIR/bin/sync-stub" <<STUB
#!/bin/bash
echo "sync env CODEX_AUTH_PRIMARY=\${CODEX_AUTH_PRIMARY:-<unset>} \$*" >> "$SYNC_LOG"
if [ ! -e "$TEST_TMPDIR/state/sabotaged" ]; then
  touch "$TEST_TMPDIR/state/sabotaged"
  rm -rf "$TEST_TMPDIR/state/sub" && touch "$TEST_TMPDIR/state/sub"
  exit 1
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/sync-stub"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 5 ]
  [ "$(grep -c "^sync " "$SYNC_LOG")" -eq 2 ]              # compensating sync still ran
  grep -q "state file restore FAILED" "$PAGE_LOG"          # page admits the truth
  ! grep -q "state file restored to" "$PAGE_LOG"           # and never claims success
}

@test "sync failure + uncleanable ABSENT-state rollback (rm fails) → no set -e abort: compensating sync + page still run" {
  # Round 3, second shape: with no prior state file the rollback is `rm -f`,
  # whose failure used to abort under set -e BEFORE the compensating sync and
  # the critical page. Injection: the sync stub turns the state file into a
  # non-empty DIRECTORY — rm -f then fails even as root.
  cat > "$TEST_TMPDIR/bin/sync-stub" <<STUB
#!/bin/bash
echo "sync env CODEX_AUTH_PRIMARY=\${CODEX_AUTH_PRIMARY:-<unset>} \$*" >> "$SYNC_LOG"
if [ ! -e "$TEST_TMPDIR/state/sabotaged" ]; then
  touch "$TEST_TMPDIR/state/sabotaged"
  rm -f "$CODEX_ACTIVE_ACCOUNT_FILE"
  mkdir -p "$CODEX_ACTIVE_ACCOUNT_FILE/keep"
  exit 1
fi
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/sync-stub"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 5 ]
  [ "$(grep -c "^sync " "$SYNC_LOG")" -eq 2 ]
  grep -q "state file restore FAILED" "$PAGE_LOG"
}

@test "sync failure with an ENV-selected current account → compensation pins CURRENT, not the absent state file" {
  # QA finding (#719, round 2): with CODEX_AUTH_PRIMARY selecting the running
  # account and NO state file, a failed rotation must re-converge the stores
  # to that EFFECTIVE account — pinning the file's (absent/stale) content
  # would converge to the baked default instead.
  echo 1 > "$TEST_TMPDIR/state/sync-rc"
  cat > "$TEST_TMPDIR/bin/sync-stub" <<STUB
#!/bin/bash
echo "sync env CODEX_AUTH_PRIMARY=\${CODEX_AUTH_PRIMARY:-<unset>} \$*" >> "$SYNC_LOG"
rc="\$(cat "$TEST_TMPDIR/state/sync-rc" 2>/dev/null || echo 0)"
echo 0 > "$TEST_TMPDIR/state/sync-rc"
exit "\$rc"
STUB
  chmod +x "$TEST_TMPDIR/bin/sync-stub"
  CODEX_AUTH_PRIMARY="openai-codex:k@y.com" run "$ROTATE" --to a@x.com
  [ "$status" -eq 5 ]
  [ ! -e "$CODEX_ACTIVE_ACCOUNT_FILE" ]                                # restored to absent
  grep -q "env CODEX_AUTH_PRIMARY=openai-codex:a@x.com" "$SYNC_LOG"    # attempt → target
  grep -q "env CODEX_AUTH_PRIMARY=openai-codex:k@y.com" "$SYNC_LOG"    # compensation → effective current
}

@test "sync failure after partial writes → compensating sync runs pinned to the PREVIOUS account" {
  # QA finding (#719): codex-auth-sync is not transactional — a mid-run
  # failure leaves a MIX of old and new credentials across the runtime
  # stores. Restoring the state file alone is not enough; rotate must run a
  # compensating sync (pinned to the previous account) to re-converge them.
  echo "openai-codex:a@x.com" > "$CODEX_ACTIVE_ACCOUNT_FILE"
  echo 1 > "$TEST_TMPDIR/state/sync-rc"
  # stub: first call fails (rc from file), later calls succeed
  cat > "$TEST_TMPDIR/bin/sync-stub" <<STUB
#!/bin/bash
echo "sync env CODEX_AUTH_PRIMARY=\${CODEX_AUTH_PRIMARY:-<unset>} \$*" >> "$SYNC_LOG"
rc="\$(cat "$TEST_TMPDIR/state/sync-rc" 2>/dev/null || echo 0)"
echo 0 > "$TEST_TMPDIR/state/sync-rc"
exit "\$rc"
STUB
  chmod +x "$TEST_TMPDIR/bin/sync-stub"
  run "$ROTATE" --to k@y.com
  [ "$status" -eq 5 ]
  [ "$(cat "$CODEX_ACTIVE_ACCOUNT_FILE")" = "openai-codex:a@x.com" ]
  [ "$(grep -c "^sync " "$SYNC_LOG")" -eq 2 ]
  grep -q "env CODEX_AUTH_PRIMARY=openai-codex:k@y.com" "$SYNC_LOG"   # attempt
  grep -q "env CODEX_AUTH_PRIMARY=openai-codex:a@x.com" "$SYNC_LOG"   # compensation
  [ ! -s "$RESTART_LOG" ]
  grep -q "FAILED at auth sync" "$PAGE_LOG"
}

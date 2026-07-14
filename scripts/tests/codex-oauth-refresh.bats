#!/usr/bin/env bats
# Tests for scripts/lib/codex-oauth-refresh.sh — the out-of-band ChatGPT-OAuth
# refresh-grant helper. Hermetic: PATH-shadows `curl` (canned token response,
# success/invalid_grant switchable) and `ssh`; operates on a throwaway auth
# store. NEVER hits the real auth.openai.com (see feedback_bats_must_stub_openclaw).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/codex-oauth-refresh.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  # Throwaway auth store mirroring the real shape.
  export CODEX_AUTH_STORE="$TEST_TMPDIR/auth-profiles.json"
  cat > "$CODEX_AUTH_STORE" <<'JSON'
{"profiles":{
  "openai-codex:a@x.com":{"type":"oauth","provider":"openai-codex","email":"a@x.com","access":"OLD_ACCESS_A","refresh":"OLD_REFRESH_A","accountId":"acc-a","chatgptPlanType":"pro","expires":1000},
  "openai-codex:b@x.com":{"type":"oauth","provider":"openai-codex","email":"b@x.com","access":"OLD_ACCESS_B","refresh":"OLD_REFRESH_B","accountId":"acc-b","chatgptPlanType":"pro","expires":1000}
}}
JSON
  export CODEX_AUTH_BACKUP_DIR="$TEST_TMPDIR/backups"

  # curl stub: emits whatever is in $RESP_FILE (default = a valid rotated grant).
  export RESP_FILE="$TEST_TMPDIR/curl_response.json"
  cat > "$RESP_FILE" <<'JSON'
{"access_token":"NEW_ACCESS","refresh_token":"NEW_REFRESH","expires_in":864000,"token_type":"Bearer"}
JSON
  cat > "$TEST_TMPDIR/bin/curl" <<STUB
#!/bin/bash
cat "$RESP_FILE"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/curl"
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh refused ($*)" >&2; exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # No slack token → _page no-ops (lib may be absent anyway).
  export MUSO_SLACK_ENV_FILE=/dev/null
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "success: both profiles get rotated tokens + future expiry, exit 0" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].refresh' "$CODEX_AUTH_STORE")" = "NEW_REFRESH" ]
  [ "$(jq -r '.profiles["openai-codex:b@x.com"].refresh' "$CODEX_AUTH_STORE")" = "NEW_REFRESH" ]
  # expires advanced well beyond the original 1000ms
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].expires' "$CODEX_AUTH_STORE")" -gt 1000000000000 ]
  # untouched fields preserved
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].accountId' "$CODEX_AUTH_STORE")" = "acc-a" ]
}

@test "success: a pre-write backup of the store is created" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash -c "ls $CODEX_AUTH_BACKUP_DIR/auth-profiles-*.json | wc -l"
  [ "$output" -ge 1 ]
}

@test "invalid_grant: store left UNTOUCHED, exit 1" {
  printf %s '{"error":"invalid_grant","error_description":"token expired"}' > "$RESP_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].refresh' "$CODEX_AUTH_STORE")" = "OLD_REFRESH_A" ]
  [[ "$output" == *"refresh FAILED"* ]]
}

@test "invalid_grant: raw response is dumped for recovery" {
  printf %s '{"error":"invalid_grant"}' > "$RESP_FILE"
  run "$SCRIPT"
  run bash -c "cat $CODEX_AUTH_BACKUP_DIR/refresh-resp-*.json"
  [[ "$output" == *"invalid_grant"* ]]
}

@test "dry-run: no POST, store unchanged, exit 0" {
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "garbled response (missing refresh_token): profile untouched, exit 1" {
  printf %s '{"access_token":"X","expires_in":864000}' > "$RESP_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
}

@test "NON-JSON body (HTML 5xx page): does NOT set-e-abort; pages + exit 1, store untouched" {
  # Regression test: jq exits 5 on non-JSON; without `|| true` set -e aborted
  # BEFORE the fail-loud page (the bug the review caught).
  printf %s '<html><body>502 Bad Gateway</body></html>' > "$RESP_FILE"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refresh FAILED"* ]]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
  [ "$(jq -r '.profiles["openai-codex:b@x.com"].refresh' "$CODEX_AUTH_STORE")" = "OLD_REFRESH_B" ]
}

@test "old token-bearing backups >30d are pruned" {
  mkdir -p "$CODEX_AUTH_BACKUP_DIR"
  old="$CODEX_AUTH_BACKUP_DIR/auth-profiles-20200101T000000Z.json"
  printf '{}' > "$old"; touch -t 202001010000 "$old"   # portable backdate (BSD+GNU)
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$old" ]
}

@test "sync hook: failing codex-auth-sync after a successful refresh → exit 1 (timer must go red)" {
  cat > "$TEST_TMPDIR/bin/fake-sync" <<'SYNC'
#!/bin/bash
echo "fake sync: refusing" >&2; exit 1
SYNC
  chmod +x "$TEST_TMPDIR/bin/fake-sync"
  CODEX_AUTH_SYNC_BIN="$TEST_TMPDIR/bin/fake-sync" run "$SCRIPT"
  [ "$status" -eq 1 ]
  # The refresh itself still landed (canonical rotated)…
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
  # …and the failure is loud, not the plain success path.
  [[ "$output" == *"sync FAILED"* ]]
}

@test "sync hook: MISSING codex-auth-sync after a successful refresh → exit 1" {
  CODEX_AUTH_SYNC_BIN="$TEST_TMPDIR/does-not-exist" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing/not executable"* ]]
}

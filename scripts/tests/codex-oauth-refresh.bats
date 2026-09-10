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
  # Hermeticity: codex-auth-sync now resolves its primary from the account-
  # rotation state file (/var/lib/hydra/codex-active-account); pin it at an
  # absent sandbox path so live state on the node-8 CI runner can't leak in.
  export CODEX_ACTIVE_ACCOUNT_FILE="$TEST_TMPDIR/absent-active-account"
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
  # Sandbox the post-refresh codex-auth-sync fan-out: its derived-store targets
  # come from CODEX_AUTH_ROOT (default /root). Without this, a successful
  # refresh here fans the fixture NEW_ACCESS token into the LIVE stores when
  # the suite runs on node-8 (incident 2026-07-14: fleet 401 → openrouter).
  export CODEX_AUTH_ROOT="$TEST_TMPDIR"

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
  # openclaw stub: the script's >= 2026.8 break-glass gate shells out to
  # `openclaw --version`, so WITHOUT this the suite reads the RUNTIME INSTALLED
  # ON THE HOST. That is not hypothetical: node-8 ran 2026.7.1 (gate no-op, all
  # green) until the 2026-09-10 8.2 cutover installed 2026.8.2, at which point
  # the gate began REFUSING and all 13 non-gate tests here went red on every PR
  # — a suite failing on host state it never set. Default to a pre-8 runtime so
  # these tests exercise refresh mechanics deterministically; every test that is
  # ABOUT the gate overwrites this stub in its own body (see
  # _stub_openclaw_version and the unparseable-runtime cases below), so none of
  # them is weakened by this default.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "openclaw 2026.7.1"; exit 0; }
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  # Record every attempted `muso` invocation. This suite never intentionally
  # sends Slack notifications, so teardown fails if a credential inherited
  # from the parent environment activates the notifier.
  export MUSO_CALL_LOG="$TEST_TMPDIR/muso-calls.log"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$MUSO_CALL_LOG"
exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  # The node-8 runner can inherit a bot selection plus real tokens for several
  # bots. Strip the selection and every token so no parent credential can
  # activate an alert path.
  unset SLACK_NOTIFY_BOT
  while IFS='=' read -r name _; do
    case "$name" in
      MUSO_SLACK_BOT_TOKEN_*) unset "$name" ;;
    esac
  done < <(env)
  export MUSO_SLACK_ENV_FILE=/dev/null
}
teardown() {
  local status=0
  if [ -s "$MUSO_CALL_LOG" ]; then
    echo "unexpected muso invocation during hermetic test" >&2
    status=1
  fi
  rm -rf "$TEST_TMPDIR"
  return "$status"
}

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

@test "sync hook: fan-out targets CODEX_AUTH_ROOT, not /root (2026-07-14 clobber regression)" {
  # openclaw stub reporting a 7.x runtime so the real codex-auth-sync.sh runs
  # its live semantics (on a box without openclaw its version gate would no-op
  # and this test would prove nothing).
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "openclaw 2026.7.1"; exit 0; }
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  # A derived store inside the sandbox root, in the broken apikey mode.
  decoy="$TEST_TMPDIR/.openclaw-main/agents/decoy/agent"
  mkdir -p "$decoy/codex-home"
  printf %s '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-hydra-placeholder"}' \
    > "$decoy/codex-home/auth.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  # The sandboxed derived store converged to the rotated fixture token…
  [ "$(jq -r '.auth_mode' "$decoy/codex-home/auth.json")" = "chatgpt" ]
  [ "$(jq -r '.tokens.access_token' "$decoy/codex-home/auth.json")" = "NEW_ACCESS" ]
}

@test "sync hook: standard store + CODEX_AUTH_ROOT unset → root DERIVED from store, fan-out sandboxed (not /root)" {
  # The REAL node-8 path (test 11 sets CODEX_AUTH_ROOT explicitly, so it only
  # covers the operator-override branch). Here STORE is the canonical
  # <root>/.openclaw-main/agents/main/agent/auth-profiles.json and CODEX_AUTH_ROOT
  # is UNSET, so codex-oauth-refresh must DERIVE _sync_root from the store's own
  # layout — neither refuse nor guess /root. The sandbox IS that derived root, so
  # a correct derivation fans out under TEST_TMPDIR and converges the decoy.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "openclaw 2026.7.1"; exit 0; }
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  # Canonical-shaped store under the sandbox root (copy the fixture profiles).
  store="$TEST_TMPDIR/.openclaw-main/agents/main/agent/auth-profiles.json"
  mkdir -p "$(dirname "$store")"
  cp "$CODEX_AUTH_STORE" "$store"
  # Derived decoy under the SAME root, in the broken apikey mode.
  decoy="$TEST_TMPDIR/.openclaw-main/agents/decoy/agent"
  mkdir -p "$decoy/codex-home"
  printf %s '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-hydra-placeholder"}' \
    > "$decoy/codex-home/auth.json"
  CODEX_AUTH_STORE="$store" CODEX_AUTH_ROOT= run "$SCRIPT"
  [ "$status" -eq 0 ]
  # Derivation worked → the fan-out reached the sandbox decoy (root = TEST_TMPDIR,
  # derived from the store path, NOT refused and NOT /root).
  [ "$(jq -r '.auth_mode' "$decoy/codex-home/auth.json")" = "chatgpt" ]
  [ "$(jq -r '.tokens.access_token' "$decoy/codex-home/auth.json")" = "NEW_ACCESS" ]
}

@test "sync hook: nonstandard store + no CODEX_AUTH_ROOT → sync REFUSED (never guesses /root), exit 1" {
  # The exact 2026-07-14 incident shape: throwaway CODEX_AUTH_STORE, no
  # sandbox root. The script must skip the fan-out loudly instead of
  # defaulting the targets to the live /root fleet.
  cat > "$TEST_TMPDIR/bin/fake-sync" <<SYNC
#!/bin/bash
touch "$TEST_TMPDIR/sync-ran"
exit 0
SYNC
  chmod +x "$TEST_TMPDIR/bin/fake-sync"
  CODEX_AUTH_ROOT= CODEX_AUTH_SYNC_BIN="$TEST_TMPDIR/bin/fake-sync" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sync SKIPPED"* ]]
  [ ! -e "$TEST_TMPDIR/sync-ran" ]
}

# --- openclaw >= 2026.8 break-glass gate ------------------------------------
# On 2.0 native in-process auto-refresh is the sole refresher; a second
# refresher racing it reproduces the 2026-06-08 refresh_token_reused
# incident. Stub `openclaw --version` directly in the test body (not via a
# VAR=x prefix on `run`, which bats delivers unreliably to stubs).

_stub_openclaw_version() {
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/bin/bash
[ "\$1" = "--version" ] && echo "openclaw $1"
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "break-glass gate: refuses to run on runtime >= 2026.8 without --break-glass" {
  _stub_openclaw_version "2026.8.1"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"2026.8"* ]]
  # Refused before ever touching the store or the network.
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
}

@test "break-glass gate: --break-glass overrides on runtime >= 2026.8" {
  _stub_openclaw_version "2026.8.1"
  run "$SCRIPT" --break-glass
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSING"* ]]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
}

@test "break-glass gate: is a no-op on runtime < 2026.8" {
  _stub_openclaw_version "2026.7.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSING"* ]]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
}

# QA bot finding (PR #897 round 2): an unknown/unparseable runtime must NOT
# be treated as a no-op — a false "still 7.x, safe to run" guess on an
# unidentifiable-but-actually-upgraded host races native refresh exactly like
# the >= 2026.8 case. Refuse loudly instead; --break-glass remains the sole
# override, and its own log line must say the runtime was unverified.
@test "break-glass gate: refuses to run when the runtime cannot be determined (empty output)" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && echo ""
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "OLD_ACCESS_A" ]
}

@test "break-glass gate: refuses to run when \`openclaw --version\` fails outright" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSING"* ]]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
}

@test "break-glass gate: --break-glass overrides when the runtime cannot be determined, and says so" {
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run "$SCRIPT" --break-glass
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUSING"* ]]
  [[ "$output" == *"--break-glass: runtime version could not be verified"* ]]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
}

@test "break-glass gate: --dry-run still refuses on runtime >= 2026.8 without --break-glass" {
  _stub_openclaw_version "2026.8.1"
  run "$SCRIPT" --dry-run
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSING"* ]]
}

@test "id_token in the response is captured into the profile as idToken" {
  cat > "$RESP_FILE" <<'JSON'
{"access_token":"NEW_ACCESS","refresh_token":"NEW_REFRESH","expires_in":864000,"token_type":"Bearer","id_token":"NEW_ID"}
JSON
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].idToken' "$CODEX_AUTH_STORE")" = "NEW_ID" ]
  [ "$(jq -r '.profiles["openai-codex:b@x.com"].idToken' "$CODEX_AUTH_STORE")" = "NEW_ID" ]
  # rotation fields still intact alongside the capture
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].refresh' "$CODEX_AUTH_STORE")" = "NEW_REFRESH" ]
}

@test "absent id_token: rotation succeeds and NO idToken key is invented" {
  # default RESP_FILE carries no id_token — the capture must be optional
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"] | has("idToken")' "$CODEX_AUTH_STORE")" = "false" ]
  [ "$(jq -r '.profiles["openai-codex:a@x.com"].access' "$CODEX_AUTH_STORE")" = "NEW_ACCESS" ]
}

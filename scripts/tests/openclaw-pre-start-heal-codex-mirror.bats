#!/usr/bin/env bats
# End-to-end wiring test: the REAL scripts/openclaw-pre-start-heal.sh dispatcher
# (byte-identical copy, sha-asserted) must run lib/codex-edge-mirror.sh for the
# `edge` profile and NOT for any other profile, and a mirror failure must stay
# non-fatal (the gateway still starts). The dispatcher hard-codes
# $SCRIPT_DIR/lib/*, so it is copied into a sandbox whose lib/ holds the REAL
# mirror (+ its real dependencies) and no-op stubs for the sibling healers —
# CI runs on the live node-8 host as root, so nothing here may reach /root.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  SB="$TEST_TMPDIR/sb"; mkdir -p "$SB/lib" "$TEST_TMPDIR/bin"
  cp "$HYDRA_REPO/scripts/openclaw-pre-start-heal.sh" "$SB/openclaw-pre-start-heal.sh"
  for f in codex-edge-mirror.sh version-compare.sh slack-notify.sh maintenance-flag.sh gateway-restart.sh deploy-notify.sh; do
    cp "$HYDRA_REPO/scripts/lib/$f" "$SB/lib/$f"
  done
  export HEALER_LOG="$TEST_TMPDIR/healers.log"
  for stub in ensure-codex-auth.sh ensure-codex-refresh-lock-shared.sh ensure-codex-version-pinned.sh ensure-sentry-mcp.sh ensure-secret-perms.sh ensure-session-budget-headroom.sh; do
    printf '#!/bin/bash\necho "%s $*" >> "$HEALER_LOG"\nexit 0\n' "$stub" > "$SB/lib/$stub"
  done
  chmod +x "$SB"/openclaw-pre-start-heal.sh "$SB"/lib/*.sh
  # openclaw stub: 2026.8.2 runtime, config always valid (Layer 1 exits 0 after the healers)
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
[ "$1" = "--version" ] && { echo "OpenClaw 2026.8.2 (test)"; exit 0; }
echo "Config valid: /nonexistent/openclaw.json"; exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-window"
  # Slack: stubbed muso records sends; token present by default so the
  # immediate page path is exercised; tests remove it to force the marker path.
  export PAGE_LOG="$TEST_TMPDIR/pages.log"
  cat > "$TEST_TMPDIR/bin/muso" <<STUB
#!/bin/bash
if [[ "\$*" == *"slack send"* ]]; then echo "\$*" >> "$PAGE_LOG"; fi
exit "\${STUB_MUSO_RC:-0}"
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  export MUSO_BIN="$TEST_TMPDIR/bin/muso"
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/slack.env"
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test\n' > "$MUSO_SLACK_ENV_FILE"
  export NOTIFY_UNIT_FAILED_MARKER_DIR="$TEST_TMPDIR/unit-failed-unpaged"
  export CODEX_MIRROR_STATE_DIR="$TEST_TMPDIR/mirror-state"
  # sandboxed cells for the mirror
  export CODEX_AUTH_ROOT="$TEST_TMPDIR/root"
  mkdir -p "$CODEX_AUTH_ROOT/.openclaw-main/state" "$CODEX_AUTH_ROOT/.openclaw-edge/state"
  seed_cells
}
teardown() { rm -rf "$TEST_TMPDIR"; }

jwt() {
  local hdr payload
  hdr="$(printf '{"alg":"RS256"}' | base64 | tr '+/' '-_' | tr -d '=\n')"
  payload="$(printf '{"https://api.openai.com/auth":{"chatgpt_account_id":"%s"},"exp":4102444800}' "$1" | base64 | tr '+/' '-_' | tr -d '=\n')"
  printf '%s.%s.sig' "$hdr" "$payload"
}
seed_cells() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");
    for (const p of ["main","edge"]) {
      const db=new DatabaseSync(process.argv[1]+"/.openclaw-"+p+"/state/openclaw.sqlite");
      db.exec("CREATE TABLE config_machine_state (state_key TEXT NOT NULL PRIMARY KEY, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL)");
      if (p==="main") db.prepare("insert into config_machine_state values (?,?,?)").run("authProfiles.store", JSON.stringify({version:1,profiles:{"openai:aaron@muso.ai":{type:"oauth",provider:"openai",email:"aaron@muso.ai",access:process.argv[2],refresh:"REAL-REFRESH",accountId:"acct-muso",chatgptPlanType:"pro",expires:4102444800000}}}), 1);
    }' "$CODEX_AUTH_ROOT" "$(jwt acct-muso)"
}
edge_profiles() {
  node --experimental-sqlite --no-warnings -e '
    const {DatabaseSync}=require("node:sqlite");const db=new DatabaseSync(process.argv[1],{readOnly:true});
    const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
    process.stdout.write(r?Object.keys(JSON.parse(r.value_json).profiles).join(","):"ABSENT");' "$CODEX_AUTH_ROOT/.openclaw-edge/state/openclaw.sqlite"
}

@test "the sandboxed dispatcher is the REAL scripts/openclaw-pre-start-heal.sh (byte-identical)" {
  [ "$(shasum -a 256 < "$SB/openclaw-pre-start-heal.sh")" = "$(shasum -a 256 < "$HYDRA_REPO/scripts/openclaw-pre-start-heal.sh")" ]
  [ "$(shasum -a 256 < "$SB/lib/codex-edge-mirror.sh")" = "$(shasum -a 256 < "$HYDRA_REPO/scripts/lib/codex-edge-mirror.sh")" ]
}

@test "pre-start edge: runs the mirror before ExecStart — edge's cell is populated, gateway start proceeds (exit 0)" {
  [ "$(edge_profiles)" = "ABSENT" ]
  run bash "$SB/openclaw-pre-start-heal.sh" edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"[codex-edge-mirror"* ]]
  [[ "$output" == *"WRITTEN	openai:aaron@muso.ai	added"* ]]
  [[ "$output" == *"Config valid — proceeding to start."* ]]
  [ "$(edge_profiles)" = "openai:aaron@muso.ai" ]
  grep -q "ensure-codex-auth.sh" "$HEALER_LOG"   # the sibling healers still ran
}

@test "pre-start main (non-edge control): the mirror is NOT invoked, edge's cell untouched" {
  run bash "$SB/openclaw-pre-start-heal.sh" main
  [ "$status" -eq 0 ]
  [[ "$output" != *"[codex-edge-mirror"* ]]
  [ "$(edge_profiles)" = "ABSENT" ]
}

@test "pre-start edge: a structural mirror failure is non-fatal (exit 0) AND the mirror pages immediately through the real dispatcher (critical, real mentions)" {
  rm -f "$CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite"
  run bash "$SB/openclaw-pre-start-heal.sh" edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: codex-edge-mirror.sh returned non-zero (non-fatal)"* ]]
  [[ "$output" == *"[codex-edge-mirror"*"paged #clio_devops"* ]]
  [[ "$output" == *"Config valid — proceeding to start."* ]]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"<@U"* ]]
  [[ "$page" == *"codex edge mirror could NOT run"*"profile \`edge\`"*"mode ensure"* ]]
  [[ "$page" == *"source store not found"* ]]
  [ ! -d "$NOTIFY_UNIT_FAILED_MARKER_DIR" ]
}

@test "pre-start edge: mirror failure + page delivery fails → durable marker for the watchdog, startup still proceeds" {
  rm -f "$CODEX_AUTH_ROOT/.openclaw-main/state/openclaw.sqlite"
  STUB_MUSO_RC=1 run bash "$SB/openclaw-pre-start-heal.sh" edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"page NOT delivered — durable marker"* ]]
  [[ "$output" == *"Config valid — proceeding to start."* ]]
  marker="$(ls "$NOTIFY_UNIT_FAILED_MARKER_DIR"/codex-edge-mirror@edge.*.unpaged | head -1)"
  [ -s "$marker" ]
  grep -q "source store not found" "$marker"
}

@test "pre-start edge: a HEALTHY mirror run pages nothing and leaves no marker" {
  run bash "$SB/openclaw-pre-start-heal.sh" edge
  [ "$status" -eq 0 ]
  [ ! -f "$PAGE_LOG" ]
  [ ! -d "$NOTIFY_UNIT_FAILED_MARKER_DIR" ]
}

@test "pre-start edge: a MISSING mirror script is skipped silently (guarded by -x) rather than crashing the start" {
  rm -f "$SB/lib/codex-edge-mirror.sh"
  run bash "$SB/openclaw-pre-start-heal.sh" edge
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex-edge-mirror"* ]]
}

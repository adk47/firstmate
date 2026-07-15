#!/usr/bin/env bats
# Tests for the gateway-LIVENESS path added to scripts/openclaw-watchdog.sh
# after the 2026-06-15 outage, where both gateways sat systemd `failed` for
# ~10 min and the watchdog logged "system idle, no action needed" every tick
# and never paged — because a down gateway emits zero agent runs and the
# activity-based "idle" branch swallowed it.
#
# The whole watchdog is run with every external command PATH-stubbed:
#   systemctl  — per-service status driven by files; restart "recovers" the svc
#   openclaw   — `config validate` returns valid unless a fixture says otherwise
#   journalctl — empty (→ 0 agent runs → the "idle" branch the bug hid behind)
#   python3 / sleep — no-ops (skip the scan-unanswered helpers + the 5s wait)
#   muso       — recorded; MUSO_SLACK_ENV_FILE is absent so slack_notify no-ops
# HYDRA_SECRETS_DIR points at a 0600 fixture so the secret-perm guard is silent.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/openclaw-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/sysctl" "$TEST_TMPDIR/oc" "$TEST_TMPDIR/secrets"
  export STUB_SYSCTL_DIR="$TEST_TMPDIR/sysctl"   # <svc>.status files
  export STUB_OPENCLAW_DIR="$TEST_TMPDIR/oc"     # <profile>.validate fixtures
  export SYSCTL_CALLS="$TEST_TMPDIR/sysctl-calls"; : > "$SYSCTL_CALLS"

  # Never read the real Slack token or page #clio_devops for real.
  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"   # absent → no token

  # Secret-perm guard sees a clean 0600 fixture (no drift alarm).
  printf 'x' > "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  chmod 600 "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  export HYDRA_SECRETS_DIR="$TEST_TMPDIR/secrets"

  # Hermeticity: the watchdog's codex checks + cooldown stamps must NOT read or
  # write the live node-8 fleet state (CI runs this suite ON the gateway host).
  # Redirect every external state path at a throwaway fixture.
  export WATCHDOG_STATE_DIR="$TEST_TMPDIR/state"; mkdir -p "$WATCHDOG_STATE_DIR"
  # Edge codex auth-store symlink → a valid (symlink-to-existing-file) fixture so
  # the symlink-integrity check reads "ok" instead of the real edge store.
  printf '{}' > "$TEST_TMPDIR/canon-auth.json"
  ln -s "$TEST_TMPDIR/canon-auth.json" "$TEST_TMPDIR/edge-auth.json"
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/edge-auth.json"
  # Codex refresh-lock convergence check → a converged fixture (edge dir is a
  # symlink to main's) so it reads clean instead of the real /root lock dirs.
  export CODEX_LOCK_ROOT="$TEST_TMPDIR/lockroot"
  mkdir -p "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks"
  ln -s "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks/oauth-refresh"

  # STUB_RESTART_RECOVERS=1 (default): a `systemctl restart` brings the service
  # to `active`. Set to 0 to model a restart that does NOT recover (the gateway
  # stays in whatever down state it was — exercises the "restart FAILED" path).
  export STUB_RESTART_RECOVERS=1
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSCTL_CALLS"
case "$1" in
  is-active)
    f="$STUB_SYSCTL_DIR/$2.status"
    [ -f "$f" ] && cat "$f" || echo active ;;
  restart)
    [ "${STUB_RESTART_RECOVERS:-1}" = "1" ] && echo active > "$STUB_SYSCTL_DIR/$2.status" ;;
  reset-failed|show|stop|start) : ;;
esac
exit 0
STUB

  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
prof=""
while [ $# -gt 0 ]; do
  case "$1" in --profile) prof="$2"; shift 2 ;; *) shift ;; esac
done
f="$STUB_OPENCLAW_DIR/$prof.validate"
[ -f "$f" ] && cat "$f" || echo "Config valid: /root/.openclaw-$prof/openclaw.json"
exit 0
STUB

  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/journalctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/python3"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/sleep"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR"/bin/*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }

set_status() { echo "$2" > "$STUB_SYSCTL_DIR/$1.status"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

@test "down main gateway is detected + auto-recovered even with ZERO agent activity (the bug)" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  run "$WD"
  [ "$status" -eq 0 ]
  # Liveness ran BEFORE the idle early-exit and acted:
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-main"* ]]
  [[ "$output" == *"reset-failed + restart"* ]]
  [[ "$output" == *"recovered (status now active)"* ]]
  # It really invoked the recovery sequence on the main service:
  grep -q "reset-failed openclaw-gateway-main" "$SYSCTL_CALLS"
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  # And the old "idle" branch still logged (proving liveness is independent of it):
  [[ "$output" == *"system idle, no action needed"* ]]
}

@test "both gateways active → no liveness action, normal idle path" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"GATEWAY DOWN"* ]]
  [[ "$output" == *"system idle, no action needed"* ]]
  ! grep -q "restart openclaw-gateway" "$SYSCTL_CALLS"
}

@test "down EDGE gateway is detected even when MAIN is idle (old block was unreachable)" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge failed
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-edge"* ]]
  grep -q "restart openclaw-gateway-edge" "$SYSCTL_CALLS"
}

@test "down gateway with INVALID config is NOT restarted (validate loop owns that alarm)" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  printf 'Invalid config at /root/.openclaw-main/openclaw.json:\n- bad: nope\n' \
    > "$STUB_OPENCLAW_DIR/main.validate"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"config INVALID — not restarting"* ]]
  ! grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "down gateway whose restart does NOT recover → pages 'restart FAILED' (critical branch)" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  export STUB_RESTART_RECOVERS=0   # restart leaves main still `failed`
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-main"* ]]
  # It tried to recover (reset-failed + restart) but the gateway stayed down:
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  [[ "$output" == *"restart FAILED — status now failed"* ]]
  # Recovery was NOT falsely declared:
  [[ "$output" != *"recovered (status now active)"* ]]
}

@test "restart-FAILED page carries real user-ID mentions, not the dead literal @aaron" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  export STUB_RESTART_RECOVERS=0
  # Make the page text observable: give slack_notify a token and swap the
  # silent no-op muso stub for one that records --text.
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test\n' > "$MUSO_SLACK_ENV_FILE"
  export MUSO_TEXTS="$TEST_TMPDIR/muso-texts"; : > "$MUSO_TEXTS"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "--text" ] && printf '%s\n' "$a" >> "$MUSO_TEXTS"
  prev="$a"
done
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/muso"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart FAILED"* ]]
  # The CRITICAL page really pings both owners (a literal "@aaron" renders as
  # plain text and pings nobody):
  grep -q '<@U0AL36NADEY>' "$MUSO_TEXTS"
  grep -q '<@U7RP6HKUZ>' "$MUSO_TEXTS"
  ! grep -q '@aaron' "$MUSO_TEXTS"
}

@test "drifted (0644) secret file is detected and re-tightened by the watchdog" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  chmod 644 "$HYDRA_SECRETS_DIR/llm-provider-keys.json"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRET PERMS TOO OPEN"* ]]
  [ "$(mode_of "$HYDRA_SECRETS_DIR/llm-provider-keys.json")" = "600" ]
}

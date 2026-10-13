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
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm the watchdog during CI (this runs on the live node-8 host). Pin the
  # flag at an absent throwaway path so maintenance_active() reads inactive.
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
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
  export WATCHDOG_LOCK_FILE="$TEST_TMPDIR/watchdog.lock"
  export HYDRA_SECRETS_DIR="$TEST_TMPDIR/secrets"

  # Hermeticity: the watchdog's codex checks + cooldown stamps must NOT read or
  # write the live node-8 fleet state (CI runs this suite ON the gateway host).
  # Redirect every external state path at a throwaway fixture.
  export WATCHDOG_STATE_DIR="$TEST_TMPDIR/state"; mkdir -p "$WATCHDOG_STATE_DIR"
  export HEAP_STATE_DIR="$TEST_TMPDIR/heapstate"; mkdir -p "$HEAP_STATE_DIR"
  # Edge codex auth-store symlink → a valid (symlink-to-existing-file) fixture so
  # the symlink-integrity check reads "ok" instead of the real edge store.
  printf '{}' > "$TEST_TMPDIR/canon-auth.json"
  ln -s "$TEST_TMPDIR/canon-auth.json" "$TEST_TMPDIR/edge-auth.json"
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/edge-auth.json"
  # On a >= 2026.8 runtime the tripwire reads the mirror's --check instead of the
  # symlink. Stub it clean; the real script would touch the live edge SQLite cell.
  cat > "$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh" <<'MSTUB'
#!/usr/bin/env bash
exit "${STUB_MIRROR_CHECK_RC:-0}"
MSTUB
  chmod +x "$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh"
  export WATCHDOG_EDGE_MIRROR_CHECK="$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh"
  export WATCHDOG_EDGE_MIRROR_TIMER="codex-edge-mirror.timer"
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
    # Real `systemctl is-active` prints the state AND exits 3 for every state
    # except `active` (empty/unreadable status file → prints nothing, exits 3).
    f="$STUB_SYSCTL_DIR/$2.status"
    st=active; [ -f "$f" ] && st=$(cat "$f")
    [ -n "$st" ] && echo "$st"
    [ "$st" = "active" ] && exit 0
    exit 3 ;;
  is-enabled)
    # The edge auth tripwire asserts the mirror timer on a >= 2026.8 runtime.
    echo "${STUB_UNIT_ENABLED:-enabled}" ;;
  restart)
    [ "${STUB_RESTART_RECOVERS:-1}" = "1" ] && echo active > "$STUB_SYSCTL_DIR/$2.status" ;;
  reset-failed|show|stop|start) : ;;
esac
exit 0
STUB

  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
  # openclaw_runtime_version() reads field 2 of line 1. The edge auth-store
  # tripwire branches on this, and an unparseable answer is a PAGE by design --
  # so the stub must speak it or every suite here reds out on a synthetic alert.
  echo "openclaw ${STUB_OPENCLAW_VERSION:-2026.8.2}"
  exit 0
fi
prof=""
while [ $# -gt 0 ]; do
  case "$1" in --profile) prof="$2"; shift 2 ;; *) shift ;; esac
done
f="$STUB_OPENCLAW_DIR/$prof.validate"
[ -f "$f" ] && cat "$f" || echo "Config valid: /root/.openclaw-$prof/openclaw.json"
exit 0
STUB

  # DR escalation: point the watchdog at a recorder stub — the real
  # dr-ai-healer.sh must NEVER spawn from a test run (CI runs on node-8; an
  # unstubbed escalation would fire a real OpenRouter call + real restarts).
  export DR_CALLS="$TEST_TMPDIR/dr-calls"; : > "$DR_CALLS"
  export DR_STATE_DIR="$TEST_TMPDIR/dr-state"
  export DR_HEALER="$TEST_TMPDIR/bin/dr-healer-stub"
  cat > "$DR_HEALER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DR_CALLS"
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

# MUS-5173: `is-active` exits non-zero for every non-active state, so the old
# `$(… || echo unknown)` appended "unknown" ("activating\nunknown") and no case
# arm ever matched — a planned restart paged as GATEWAY DOWN. Stubs exit 3 like
# the real thing; a stub that exits 0 cannot reproduce this at all.
wd_restart_calls() { grep -cE '^(restart|reset-failed) openclaw-gateway-main$' "$SYSCTL_CALLS" || true; }

@test "transient gateway state is skipped, not restarted or paged (activating|reloading|deactivating, is-active exits 3)" {
  printf 'MUSO_SLACK_BOT_TOKEN_DEVOPS=xoxb-test\n' > "$MUSO_SLACK_ENV_FILE"
  export MUSO_TEXTS="$TEST_TMPDIR/muso-texts"; : > "$MUSO_TEXTS"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$MUSO_TEXTS"\n' > "$TEST_TMPDIR/bin/muso"
  chmod +x "$TEST_TMPDIR/bin/muso"
  for st in activating reloading deactivating; do
    : > "$SYSCTL_CALLS"
    set_status openclaw-gateway-main "$st"
    set_status openclaw-gateway-edge active
    run "$WD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"openclaw-gateway-main transient state=${st}"* ]]
    [[ "$output" != *"GATEWAY DOWN"* ]]
    [ "$(wd_restart_calls)" -eq 0 ]
    # Only gateway-liveness pages count (unrelated host checks may page on a dev box):
    ! grep -qE 'gateway DOWN|gateway\* was|reset-failed' "$MUSO_TEXTS"
  done
}

@test "genuinely failed gateway (is-active prints failed, exits 3) still gets reset-failed + restart" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-main status=failed"* ]]
  [[ "$output" != *"transient state"* ]]
  grep -qx "reset-failed openclaw-gateway-main" "$SYSCTL_CALLS"
  grep -qx "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "is-active printing NOTHING resolves to status=unknown and still reaches the DOWN path" {
  set_status openclaw-gateway-main ""
  set_status openclaw-gateway-edge active
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-main status=unknown"* ]]
  grep -qx "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "restart poll breaks on the first failed sample instead of burning all six" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  export STUB_RESTART_RECOVERS=0
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart FAILED — status now failed"* ]]
  # 1 liveness read + exactly 1 poll read for main (old code: 1 + 6).
  [ "$(grep -cx 'is-active openclaw-gateway-main' "$SYSCTL_CALLS")" -eq 2 ]
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

@test "restart-FAILED escalates to the DR AI healer immediately (no strike accumulation)" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  export STUB_RESTART_RECOVERS=0
  run "$WD"
  [ "$status" -eq 0 ]
  grep -q -- '--trigger gateway_restart_failed_main' "$DR_CALLS"
}

@test "recovered restart does NOT escalate to the DR AI healer" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  run "$WD"   # STUB_RESTART_RECOVERS=1 default: restart brings it back
  [ "$status" -eq 0 ]
  [[ "$output" == *"recovered (status now active)"* ]]
  [ ! -s "$DR_CALLS" ]
}

@test "persistent codex token-expired signature escalates only after 3 consecutive strikes" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  # journalctl now emits the token-expired signature for every unit queried.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'openclaw[1]: auth error: authentication token is expired'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"; [ "$status" -eq 0 ]
  run "$WD"; [ "$status" -eq 0 ]
  [ ! -s "$DR_CALLS" ]                       # 2 strikes: not yet
  run "$WD"; [ "$status" -eq 0 ]
  grep -q -- '--trigger codex_token_expired' "$DR_CALLS"   # 3rd strike: escalate
  # Strike file was reset on escalation — the next tick starts from zero.
  [ ! -f "$DR_STATE_DIR/dr-strikes-codex_token_expired" ]
}

@test "a single historical error riding the 15-min window does NOT escalate (fresh-window strikes)" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  # journalctl branches on --since: the 15-min alert window still sees the old
  # error line, but the short strike window is quiet — the failure is over.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *" 3 min ago"*) : ;;   # fresh window: quiet (no new failures)
  *) echo 'openclaw[1]: auth error: authentication token is expired' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"; [ "$status" -eq 0 ]
  run "$WD"; [ "$status" -eq 0 ]
  run "$WD"; [ "$status" -eq 0 ]
  run "$WD"; [ "$status" -eq 0 ]
  [ ! -s "$DR_CALLS" ]   # 4 ticks of a stale line: never escalated
  [ ! -f "$DR_STATE_DIR/dr-strikes-codex_token_expired" ]
}

@test "MAIN-only invalidated-auth failures also strike and escalate (not edge-scoped)" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  # journalctl emits the invalidated-auth signature ONLY for the main unit.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *openclaw-gateway-main*) echo 'openclaw[1]: authentication token has been invalidated' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"; [ "$status" -eq 0 ]
  run "$WD"; [ "$status" -eq 0 ]
  [ ! -s "$DR_CALLS" ]
  run "$WD"; [ "$status" -eq 0 ]
  grep -q -- '--trigger codex_auth_invalidated' "$DR_CALLS"
}

@test "a clean tick clears codex strike counters (no escalation across interrupted streaks)" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'openclaw[1]: auth error: authentication token is expired'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"; run "$WD"                        # 2 strikes
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/journalctl"  # clean tick
  run "$WD"
  [ ! -f "$DR_STATE_DIR/dr-strikes-codex_token_expired" ]
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'openclaw[1]: auth error: authentication token is expired'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"; run "$WD"                        # streak restarts at 1, 2
  [ ! -s "$DR_CALLS" ]                        # never escalated
}

@test "symlinked DR state dir → watchdog skips strikes AND escalation (symlink-attack guard)" {
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  export STUB_RESTART_RECOVERS=0   # would normally escalate immediately
  mkdir -p "$TEST_TMPDIR/attacker-target"
  ln -s "$TEST_TMPDIR/attacker-target" "$DR_STATE_DIR"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart FAILED"* ]]           # detection/paging unaffected
  [[ "$output" == *"NOT escalating"* ]]
  [ ! -s "$DR_CALLS" ]                             # healer never invoked
  [ -z "$(ls -A "$TEST_TMPDIR/attacker-target")" ] # nothing written through the link
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

@test "an ACTIVE maintenance window makes the watchdog stand down (no restart, no page)" {
  # A window is open: the operator stopped the gateways on purpose. Even with main
  # DOWN, the watchdog must skip — NOT reset-failed/restart (that restart corrupted
  # the 2026-07 7.1 state archive) and NOT page.
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  printf '{"reason":"openclaw upgrade","expires_epoch":%s}' "$(( $(date -u +%s) + 3600 ))" \
    > "$HYDRA_MAINTENANCE_FLAG"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance: openclaw upgrade - skipping"* ]]
  # It did NOT touch the down gateway:
  if grep -q "restart openclaw-gateway" "$SYSCTL_CALLS"; then echo "active maintenance window still let the watchdog restart the gateway" >&2; false; fi
  if grep -q "reset-failed openclaw-gateway" "$SYSCTL_CALLS"; then echo "active maintenance window still let the watchdog reset-failed the gateway" >&2; false; fi
  [[ "$output" != *"GATEWAY DOWN"* ]]
}

@test "an EXPIRED maintenance flag does NOT disarm the watchdog (fail-safe)" {
  # A forgotten 'stop' leaves a stale flag; the reader ignores it, so protection
  # re-arms automatically. Main is down -> the watchdog must still recover it.
  set_status openclaw-gateway-main failed
  set_status openclaw-gateway-edge active
  printf '{"reason":"stale","expires_epoch":%s}' "$(( $(date -u +%s) - 60 ))" \
    > "$HYDRA_MAINTENANCE_FLAG"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"maintenance:"* ]]
  [[ "$output" == *"GATEWAY DOWN: openclaw-gateway-main"* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

_stub_edge_authfail() {
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *openclaw-gateway-edge*) echo 'openclaw[1]: authentication token has been invalidated' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
}

# Agent runs with zero successes → the STUCK branch, which reads the restart stamp.
_stub_stuck_agent_runs() {
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'openclaw[1]: run agent start'
echo 'openclaw[1]: run agent end isError=true'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
}

# ── corrupt cooldown stamps ───────────────────────────────────────────────────
#
# Both stamps were read with a bare `cat` straight into `$(( ))`. Neither site
# validated, and the two failure shapes are DIFFERENT — which is why both need
# their own test:
#   - `_codex_cooldown_ok` is called inside an `if` condition, so the arithmetic
#     error aborts the compound command and NEITHER branch runs: the alert is
#     silently skipped while the script sails on.
#   - the restart cooldown is a plain assignment, so ELAPSED is never set and
#     `set -u` kills the whole watchdog on the next read — it stops watching
#     everything, from one corrupt byte.

@test "a corrupt codex cooldown stamp does not silently swallow the auth alert" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '1abc' > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown"
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *openclaw-gateway-edge*) echo 'openclaw[1]: authentication token has been invalidated' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EDGE CODEX AUTH DEAD"* ]]
  [[ "$output" != *"value too great for base"* ]]
}

# The stability pair: a genuinely FRESH stamp must still suppress, or the fix
# would have simply deleted the cooldown.
@test "a fresh codex cooldown stamp still suppresses the auth alert" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  date +%s > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown"
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *openclaw-gateway-edge*) echo 'openclaw[1]: authentication token has been invalidated' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"EDGE CODEX AUTH DEAD"* ]]
}

# "Digits only" is not "safe for $(( ))". `08` is digits but invalid octal, so
# it aborts the same way `1abc` did — and a digit-only FUTURE stamp is worse
# than an abort: the age goes negative, which reads as "just alerted" and
# suppresses for centuries. Both paths get both cases.
@test "an octal-looking codex cooldown stamp does not swallow the auth alert" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '08' > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown"
  _stub_edge_authfail
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EDGE CODEX AUTH DEAD"* ]]
  [[ "$output" != *"value too great for base"* ]]
}

@test "a far-future codex cooldown stamp does not suppress the auth alert for centuries" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '9999999999' > "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-auth-cooldown"
  _stub_edge_authfail
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"EDGE CODEX AUTH DEAD"* ]]
}

@test "an octal-looking restart cooldown stamp does not kill the watchdog" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '08' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_stuck_agent_runs
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *"value too great for base"* ]]
}

# A future restart stamp made ELAPSED negative, so the cooldown never expired
# and the gateway was never restarted again — a stuck fleet with a watchdog
# that reports "SKIP" forever.
@test "a far-future restart cooldown stamp does not suppress the restart forever" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '9999999999' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_stuck_agent_runs
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SKIP: Last restart"* ]]
}

@test "a corrupt restart cooldown stamp does not kill the watchdog mid-tick" {
  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
  printf '1abc' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  # Agent runs with zero successes → the STUCK branch, which reads the stamp.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'openclaw[1]: run agent start'
echo 'openclaw[1]: run agent end isError=true'
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
  run "$WD"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *"value too great for base"* ]]
}

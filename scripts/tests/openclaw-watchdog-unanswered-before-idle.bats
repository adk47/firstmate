#!/usr/bin/env bats
# MUS-29979: the unanswered-@mention SCAN + PAGE must run BEFORE the "system idle"
# early exit. On 5 Nov 402 of 409 ticks (all 17 in the 11:56-12:30Z freeze) took
# that exit, so a dropped app_mention was never paged. The auto-RETRIGGER stays
# after the idle exit (it invokes agents, incl. `operations`; separate ruling).
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

  # A fake token so slack_notify reaches the (recording) muso stub; never real.
  export MUSO_SLACK_BOT_TOKEN_DEVOPS=test-token
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"

  # Secret-perm guard sees a clean 0600 fixture (no drift alarm).
  printf 'x' > "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  chmod 600 "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  export WATCHDOG_LOCK_FILE="$TEST_TMPDIR/watchdog.lock"
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
    f="$STUB_SYSCTL_DIR/$2.status"
    [ -f "$f" ] && cat "$f" || echo active ;;
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

  # Per-unit journal stub: emits $TEST_TMPDIR/journal-<unit> so main and edge
  # can be driven INDEPENDENTLY — the whole point of the per-gateway fingerprint.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
unit=""
while [ $# -gt 0 ]; do case "$1" in -u) unit="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$unit" ] && cat "$TEST_TMPDIR/journal-$unit" 2>/dev/null
exit 0
STUB
  # python3 stub: scan-unanswered.py answers from STUB_SCAN_OUT / STUB_SCAN_RC;
  # every other python3 call (retrigger, outage-notify, config probes) is a no-op.
  cat > "$TEST_TMPDIR/bin/python3" <<'PSTUB'
#!/usr/bin/env bash
case "$1" in
  */scan-unanswered.py)
    if [ "${2:-}" = "--commit" ]; then echo commit >> "$SCAN_CALLS"; exit 0; fi
    if [ "${2:-}" = "--no-dedup" ]; then
      echo scan-nodedup >> "$SCAN_CALLS"
      [ -n "${STUB_NODEDUP_OUT:-}" ] && printf '%s\n' "$STUB_NODEDUP_OUT"
      exit 0
    fi
    echo scan >> "$SCAN_CALLS"
    [ -n "${STUB_SCAN_HANG:-}" ] && exec /bin/sleep 30
    [ -n "${STUB_SCAN_OUT:-}" ] && printf '%s\n' "$STUB_SCAN_OUT"
    exit "${STUB_SCAN_RC:-0}" ;;
  */retrigger-unanswered.py) echo retrigger >> "$SCAN_CALLS"; exit 0 ;;
  -c) case "${2:-}" in *gateway*) echo stub-gw-token ;; esac; exit 0 ;;
esac
exit 0
PSTUB
  export SCAN_CALLS="$TEST_TMPDIR/scan-calls"; : > "$SCAN_CALLS"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/sleep"
  export MUSO_CALLS="$TEST_TMPDIR/muso-calls"; : > "$MUSO_CALLS"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MUSO_CALLS"
exit "${STUB_MUSO_RC:-0}"
STUB
  chmod +x "$TEST_TMPDIR"/bin/*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
}
teardown() { rm -rf "$TEST_TMPDIR"; }


_journal() { printf '%s\n' "$2" > "$TEST_TMPDIR/journal-$1"; }
_run_wd() {
  if [ -n "${WATCHDOG_BASH:-}" ]; then run "$WATCHDOG_BASH" "$WD"; else run "$WD"; fi
}

@test "idle tick (0 agent runs) still pages the unanswered mention, and still logs system idle" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_OUT="• @scout in #general — McLaren (12:13 UTC): please look"
  _run_wd; [ "$status" -eq 0 ]
  [[ "$output" == *"No agent activity — system idle"* ]]
  grep -q "1 unanswered @mentions" "$MUSO_CALLS"
  grep -q "McLaren" "$MUSO_CALLS"
}

@test "idle tick does NOT auto-retrigger (retrigger stays after the idle exit)" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_OUT="• @scout in #general — McLaren (12:13 UTC): please look"
  _run_wd; [ "$status" -eq 0 ]
  grep -q '^scan$' "$SCAN_CALLS"
  ! grep -q '^retrigger$' "$SCAN_CALLS"
}

@test "idle tick with nothing unanswered pages nothing" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  _run_wd; [ "$status" -eq 0 ]
  [[ "$output" == *"system idle"* ]]
  ! grep -q "unanswered" "$MUSO_CALLS"
}

@test "scan failure is loud: UNANSWERED SCAN FAILED rc=1, no restart, tick continues" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_RC=1
  _run_wd; [ "$status" -eq 0 ]
  [[ "$output" == *"UNANSWERED SCAN FAILED rc=1"* ]]
  [[ "$output" == *"system idle"* ]]
  ! grep -q '^restart' "$SYSCTL_CALLS"
}

@test "delivered page commits the page-once state" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_OUT="• @scout in #general — McLaren (12:13 UTC): please look"
  _run_wd; [ "$status" -eq 0 ]
  grep -q '^commit$' "$SCAN_CALLS"
}

@test "failed Slack send does NOT commit the state, so the mention is paged again next tick" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_OUT="• @scout in #general — McLaren (12:13 UTC): please look"
  export STUB_MUSO_RC=1
  _run_wd; [ "$status" -eq 0 ]
  [[ "$output" == *"UNANSWERED PAGE NOT DELIVERED"* ]]
  ! grep -q '^commit$' "$SCAN_CALLS"
}

@test "non-idle tick retriggers a mention already paged (retrigger gates on the un-deduped scan, not the page-once count)" {
  printf '%s\n' "run agent end isError=false" "run agent end isError=false" "run agent end isError=false" > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  # deduped scan prints nothing (mention already in the paged state); un-deduped still sees it
  export STUB_NODEDUP_OUT="• @scout in #general — McLaren (12:13 UTC): please look"
  _run_wd; [ "$status" -eq 0 ]
  grep -q '^scan-nodedup$' "$SCAN_CALLS"
  grep -q '^retrigger$' "$SCAN_CALLS"
}

@test "non-idle tick with nothing unanswered does not retrigger" {
  printf '%s\n' "run agent end isError=false" "run agent end isError=false" "run agent end isError=false" > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  _run_wd; [ "$status" -eq 0 ]
  ! grep -q '^retrigger$' "$SCAN_CALLS"
}

@test "a hanging scan is cut off by the timeout and logged as UNANSWERED SCAN FAILED rc=124" {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  export STUB_SCAN_HANG=1 UNANSWERED_SCAN_TIMEOUT=1
  _run_wd; [ "$status" -eq 0 ]
  [[ "$output" == *"UNANSWERED SCAN FAILED rc=124"* ]]
  [[ "$output" == *"system idle"* ]]
}

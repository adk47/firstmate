#!/usr/bin/env bats
# Behavioral tests for the STUCK-restart gate in scripts/openclaw-watchdog.sh
# (MUS-1298, CTO design F3 on MUS-1295).
#
# 29 Sep 2026 15:18:01 UTC: the watchdog logged "Check: 0 successes, 1 errors,
# 1 agent runs" and restarted the WHOLE Slack fleet off ONE failed run — a
# skill-workshop-review context-window overflow, an application error a
# restart cannot fix. `SUCCESS_COUNT -eq 0 && MSG_COUNT -gt 0` was the entire
# STUCK test: a 100% failure ratio over a single sample is not a signal.
#
# The fix adds two independent gates, both required before a restart fires:
#   1. MIN_RUNS_FOR_STUCK (default 3) — refuse to conclude STUCK below a real
#      sample size.
#   2. A liveness probe (3x, 10s apart, against :18789) — even at >= 3 failed
#      runs, if the gateway answers at all the failures are application-level
#      and a restart won't help.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
WD="$HYDRA_REPO/scripts/openclaw-watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  # Hermeticity: a real maintenance window (/run/hydra-maintenance) must not
  # disarm the watchdog during CI (this runs on the live node-8 host).
  export HYDRA_MAINTENANCE_FLAG="$TEST_TMPDIR/no-maintenance-window"
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/sysctl" "$TEST_TMPDIR/oc" "$TEST_TMPDIR/secrets"
  export STUB_SYSCTL_DIR="$TEST_TMPDIR/sysctl"
  export STUB_OPENCLAW_DIR="$TEST_TMPDIR/oc"
  export SYSCTL_CALLS="$TEST_TMPDIR/sysctl-calls"; : > "$SYSCTL_CALLS"

  unset MUSO_SLACK_BOT_TOKEN_DEVOPS
  export MUSO_SLACK_ENV_FILE="$TEST_TMPDIR/muso-slack.env"   # absent → no token

  printf 'x' > "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  chmod 600 "$TEST_TMPDIR/secrets/llm-provider-keys.json"
  export HYDRA_SECRETS_DIR="$TEST_TMPDIR/secrets"

  export WATCHDOG_STATE_DIR="$TEST_TMPDIR/state"; mkdir -p "$WATCHDOG_STATE_DIR"
  printf '{}' > "$TEST_TMPDIR/canon-auth.json"
  ln -s "$TEST_TMPDIR/canon-auth.json" "$TEST_TMPDIR/edge-auth.json"
  export WATCHDOG_EDGE_AUTH_PROFILES="$TEST_TMPDIR/edge-auth.json"
  cat > "$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh" <<'MSTUB'
#!/usr/bin/env bash
exit "${STUB_MIRROR_CHECK_RC:-0}"
MSTUB
  chmod +x "$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh"
  export WATCHDOG_EDGE_MIRROR_CHECK="$TEST_TMPDIR/bin/codex-edge-mirror-stub.sh"
  export WATCHDOG_EDGE_MIRROR_TIMER="codex-edge-mirror.timer"
  export CODEX_LOCK_ROOT="$TEST_TMPDIR/lockroot"
  mkdir -p "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks"
  ln -s "$CODEX_LOCK_ROOT/.openclaw-main/locks/oauth-refresh" "$CODEX_LOCK_ROOT/.openclaw-edge/locks/oauth-refresh"

  export STUB_RESTART_RECOVERS=1
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSCTL_CALLS"
case "$1" in
  is-active)
    f="$STUB_SYSCTL_DIR/$2.status"
    [ -f "$f" ] && cat "$f" || echo active ;;
  is-enabled)
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

  export DR_CALLS="$TEST_TMPDIR/dr-calls"; : > "$DR_CALLS"
  export DR_STATE_DIR="$TEST_TMPDIR/dr-state"
  export DR_HEALER="$TEST_TMPDIR/bin/dr-healer-stub"
  cat > "$DR_HEALER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DR_CALLS"
exit 0
STUB

  # Flat journalctl stub: emits N 'run agent end isError=true' lines regardless
  # of -u/--since (same fixture answers the MAIN_CODEX_LOGS, EDGE_LOGS, and
  # RECENT_LOGS calls; none of these lines match any codex-signature regex, so
  # only the run-count/success-count/error-count math is exercised).
  export JOURNAL_AGENT_RUNS_FILE="$TEST_TMPDIR/journal-agent-runs"; : > "$JOURNAL_AGENT_RUNS_FILE"
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
cat "$JOURNAL_AGENT_RUNS_FILE" 2>/dev/null
exit 0
STUB

  # curl stub for the liveness probe: returns the Nth line of
  # CURL_CODES_FILE for the Nth invocation (default, unset file: always "000",
  # i.e. a dead gateway — the safe default for tests that never reach the
  # probe). Every call is recorded so tests can assert probe count/spacing.
  export CURL_CODES_FILE="$TEST_TMPDIR/curl-codes"
  export CURL_CALLS="$TEST_TMPDIR/curl-calls"; : > "$CURL_CALLS"
  cat > "$TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_CALLS"
n=$(wc -l < "$CURL_CALLS" | tr -d ' ')
code=$(sed -n "${n}p" "$CURL_CODES_FILE" 2>/dev/null)
printf '%s' "${code:-000}"
exit 0
STUB

  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/python3"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMPDIR/bin/sleep"
  export MUSO_CALLS="$TEST_TMPDIR/muso-calls"; : > "$MUSO_CALLS"
  cat > "$TEST_TMPDIR/bin/muso" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MUSO_CALLS"
exit 0
STUB
  chmod +x "$TEST_TMPDIR"/bin/*
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  set_status openclaw-gateway-main active
  set_status openclaw-gateway-edge active
}
teardown() { rm -rf "$TEST_TMPDIR"; }

set_status() { echo "$2" > "$STUB_SYSCTL_DIR/$1.status"; }

# N failed runs, 0 successes: one 'run agent' line per run (per MUS-1295 CTO
# finding — MSG_COUNT is not double-counting; don't "fix" the grep).
_stub_n_failed_runs() {
  local n="$1" i
  : > "$JOURNAL_AGENT_RUNS_FILE"
  for ((i = 0; i < n; i++)); do
    echo "openclaw[1]: run agent end isError=true" >> "$JOURNAL_AGENT_RUNS_FILE"
  done
}

# The watchdog's shebang is #!/bin/bash and it uses `declare -A`, which needs
# bash 4+. CI (node-8, Linux) has bash 5 at /bin/bash; macOS ships 3.2, so the
# whole suite would only be verifiable in CI. WATCHDOG_BASH lets a developer
# run it locally against a modern bash without changing what production runs:
#   WATCHDOG_BASH=/opt/homebrew/bin/bash bats scripts/tests/openclaw-watchdog-stuck-threshold.bats
_run_wd() {
  if [ -n "${WATCHDOG_BASH:-}" ]; then run "$WATCHDOG_BASH" "$WD"; else run "$WD"; fi
}

@test "1 run / 0 successes: insufficient sample, restart path not reached" {
  _stub_n_failed_runs 1
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSUFFICIENT SAMPLE: 1 runs (< 3), 0 successes — not restarting"* ]]
  [[ "$output" != *"Restarting openclaw-gateway"* ]]
  run grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  [ "$status" -ne 0 ]
  # The 29 Sep incident shape: never even reached the liveness probe.
  [ ! -s "$CURL_CALLS" ]
}

@test "3 runs / 0 successes + probe alive: NOT STUCK, restart path not reached" {
  _stub_n_failed_runs 3
  printf '200\n' > "$CURL_CODES_FILE"   # first probe already answers
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK: 3 agent runs but 0 successes"* ]]
  [[ "$output" == *"NOT STUCK: gateway answering on :18789 — 3 failed runs are application-level"* ]]
  [[ "$output" != *"Restarting openclaw-gateway"* ]]
  run grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  [ "$status" -ne 0 ]
  # Gateway answered on the first probe — the other two never fired.
  [ "$(wc -l < "$CURL_CALLS" | tr -d ' ')" -eq 1 ]
}

@test "3 runs / 0 successes + 3 failed probes: restart path reached" {
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"   # all three probes dead
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK: 3 agent runs but 0 successes"* ]]
  [[ "$output" != *"NOT STUCK"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  # All three probes were actually attempted before restarting.
  [ "$(wc -l < "$CURL_CALLS" | tr -d ' ')" -eq 3 ]
}

@test "MIN_RUNS_FOR_STUCK is env-injectable" {
  export MIN_RUNS_FOR_STUCK=5
  _stub_n_failed_runs 4
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSUFFICIENT SAMPLE: 4 runs (< 5), 0 successes — not restarting"* ]]
  run grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  [ "$status" -ne 0 ]
}

@test "GATEWAY_LIVENESS_PROBE_URL is env-injectable and reaches curl" {
  export GATEWAY_LIVENESS_PROBE_URL="http://127.0.0.1:9999/custom"
  _stub_n_failed_runs 3
  printf '200\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  grep -q "127.0.0.1:9999/custom" "$CURL_CALLS"
}

# MUS-1298 round 2 (QA NO-GO on hydra#1030): a malformed MIN_RUNS_FOR_STUCK
# (non-numeric, zero, or negative) must not make `[ "$MSG_COUNT" -ge
# "$MIN_RUNS_FOR_STUCK" ]` either error out (skipping the STUCK block
# entirely — a dead gateway with 3+ failed runs then goes neither probed
# nor restarted) or neuter the sample-size floor back to the 29 Sep
# single-run-restart bug. Each case below must still reach the restart path
# on a genuinely stuck (3 failed runs, dead probe) gateway.

@test "MIN_RUNS_FOR_STUCK='three' (non-numeric): falls back to 3, restart path still reached" {
  export MIN_RUNS_FOR_STUCK=three
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIN_RUNS_FOR_STUCK='three' is not a positive integer — falling back to 3"* ]]
  [[ "$output" == *"STUCK: 3 agent runs but 0 successes"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "MIN_RUNS_FOR_STUCK=0 (non-positive): falls back to 3, restart path still reached" {
  export MIN_RUNS_FOR_STUCK=0
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIN_RUNS_FOR_STUCK='0' is not a positive integer — falling back to 3"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "MIN_RUNS_FOR_STUCK=-1 (negative): falls back to 3, restart path still reached" {
  export MIN_RUNS_FOR_STUCK=-1
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIN_RUNS_FOR_STUCK='-1' is not a positive integer — falling back to 3"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "MIN_RUNS_FOR_STUCK='' (empty): defaults to 3, restart path still reached" {
  export MIN_RUNS_FOR_STUCK=""
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"STUCK: 3 agent runs but 0 successes"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

@test "MIN_RUNS_FOR_STUCK=0 (non-positive) does not resurrect the single-run restart bug" {
  export MIN_RUNS_FOR_STUCK=0
  _stub_n_failed_runs 1
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSUFFICIENT SAMPLE: 1 runs (< 3), 0 successes — not restarting"* ]]
  [[ "$output" != *"Restarting openclaw-gateway"* ]]
  run grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
  [ "$status" -ne 0 ]
}

# MUS-1298 round 3 (GitHub QA bot NO-GO on hydra#1030 @ 1eccff79): the round-2
# guard (`^[1-9][0-9]*$`) bounds the SIGN but not the WIDTH. An all-digit
# override like 999999999999999999999999999999 (31 digits) exceeds bash's
# 64-bit signed integer range, so `[ "$MSG_COUNT" -lt "$MIN_RUNS_FOR_STUCK" ]`
# at the sample-size check and `-ge` at the STUCK check both emit "integer
# expression expected" and evaluate false — the STUCK block is skipped
# exactly like the unbounded-sign bug the round-2 fix closed. Must still
# reach the restart path on a genuinely stuck (3 failed runs, dead probe)
# gateway.
@test "MIN_RUNS_FOR_STUCK=<31-digit value> (oversized): falls back to 3, restart path still reached" {
  export MIN_RUNS_FOR_STUCK=999999999999999999999999999999
  _stub_n_failed_runs 3
  printf '000\n000\n000\n' > "$CURL_CODES_FILE"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIN_RUNS_FOR_STUCK='999999999999999999999999999999' is not a positive integer — falling back to 3"* ]]
  [[ "$output" == *"STUCK: 3 agent runs but 0 successes"* ]]
  [[ "$output" == *"Restarting openclaw-gateway..."* ]]
  grep -q "restart openclaw-gateway-main" "$SYSCTL_CALLS"
}

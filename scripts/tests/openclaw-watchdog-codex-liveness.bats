#!/usr/bin/env bats
# Behavioral tests for the CODEX LIVENESS debounce in scripts/openclaw-watchdog.sh.
#
# This state machine answers the only question that was true throughout the
# 2026-07-27 outage — "is the fleet actually being served by codex, or by the
# paid openrouter rung?" — while all three structural guards read CLEAN.
#
# It needed two review fixes before landing, and BOTH were silent-in-production
# failures that a regex test could never catch:
#   1. it re-counted ONE historical fallback line on every overlapping window,
#      so the "2 consecutive ticks" debounce fired ~4min after a single
#      transient blip (watchdog runs */2 but reads a 15min window);
#   2. it fingerprinted `tail -n1` over main+edge CONCATENATED, so a stale edge
#      line masked new main events and SUPPRESSED the page while main degraded.
# One direction false-pages, the other goes silent during a real outage. These
# cases exist so neither can come back.
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
}
teardown() { rm -rf "$TEST_TMPDIR"; }

_journal() { printf '%s\n' "$2" > "$TEST_TMPDIR/journal-$1"; }
_fallback_line() { echo "Jul 28 $1 node[1]: [model-fallback/decision] model fallback decision: decision=candidate_succeeded requested=openai/gpt-5.6-sol candidate=openrouter/openai/gpt-5.6-luna reason=unknown"; }
_streak() { cat "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-streak" 2>/dev/null || echo 0; }

# The watchdog's shebang is #!/bin/bash and it uses `declare -A`, which needs
# bash 4+. CI (node-8, Linux) has bash 5 at /bin/bash; macOS ships 3.2, so the
# whole suite would only be verifiable in CI. WATCHDOG_BASH lets a developer run
# it locally against a modern bash without changing what production executes:
#   WATCHDOG_BASH=/opt/homebrew/bin/bash bats scripts/tests/openclaw-watchdog-codex-liveness.bats
_run_wd() {
  if [ -n "${WATCHDOG_BASH:-}" ]; then run "$WATCHDOG_BASH" "$WD"; else run "$WD"; fi
}

@test "liveness: the SAME line seen across overlapping windows holds the streak at 1" {
  # The watchdog fires every 2min but reads 15min of journal, so one event is
  # visible for ~7 ticks. Without the fingerprint this reached the 2-tick
  # threshold and paged on a single self-recovering blip.
  _journal openclaw-gateway-main "$(_fallback_line 12:00:00)"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"
  _run_wd; [ "$status" -eq 0 ]
  [ "$(_streak)" -eq 1 ]
  _run_wd; [ "$status" -eq 0 ]
  [ "$(_streak)" -eq 1 ]      # same line -> held, NOT 2
  _run_wd; [ "$status" -eq 0 ]
  [ "$(_streak)" -eq 1 ]
}

@test "liveness: two DISTINCT events advance the streak to the paging threshold" {
  _journal openclaw-gateway-main "$(_fallback_line 12:00:00)"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"
  _run_wd; [ "$(_streak)" -eq 1 ]
  _journal openclaw-gateway-main "$(_fallback_line 12:05:00)"
  _run_wd; [ "$(_streak)" -ge 2 ]
}

@test "liveness: a stale EDGE line must not mask a new MAIN event" {
  # The concatenation bug: `tail -n1` over main-then-edge always returned edge's
  # last match, so a persistent edge line pinned the fingerprint and the streak
  # never advanced while main kept falling back — silence during a real outage.
  _journal openclaw-gateway-edge "$(_fallback_line 09:00:00)"
  _journal openclaw-gateway-main "$(_fallback_line 12:00:00)"
  _run_wd; [ "$(_streak)" -eq 1 ]
  _journal openclaw-gateway-main "$(_fallback_line 12:05:00)"   # edge unchanged
  _run_wd
  [ "$(_streak)" -ge 2 ]
}

@test "liveness: a clean window clears BOTH state files" {
  _journal openclaw-gateway-main "$(_fallback_line 12:00:00)"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"
  _run_wd; [ "$(_streak)" -eq 1 ]
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  _run_wd
  [ ! -e "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-streak" ]
  [ ! -e "$WATCHDOG_STATE_DIR/openclaw-watchdog-codex-liveness-lastline" ]
}

@test "liveness: a codex-served (silent) window never starts a streak" {
  # A turn served by the primary logs NO fallback decision at all, so healthy
  # traffic must leave no state behind.
  _journal openclaw-gateway-main "Jul 28 12:00:00 node[1]: [agent] run ended with stopReason=stop"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"
  _run_wd; [ "$status" -eq 0 ] || { echo "EXIT=$status"; echo "$output" | tail -25; false; }
  [ "$(_streak)" -eq 0 ]
}

@test "liveness: the gateway STARTUP config line is not a degradation" {
  # Present on every boot, and main restarts on memory pressure many times a day.
  _journal openclaw-gateway-main "Jul 28 12:00:00 node[1]: - openrouter/openai/gpt-5.6-luna model configured, enabled automatically."
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"
  _run_wd; [ "$status" -eq 0 ]
  [ "$(_streak)" -eq 0 ]
}

#!/usr/bin/env bats
# Behavioral tests for the heap-TROUGH proactive drain-restart in
# scripts/openclaw-watchdog.sh (MUS-1009 A2 / MUS-1588).
#
# 6 main-gateway heap-limit crashes in 8 days. Live heap is a sawtooth — one
# process went 5.66 -> 3.96 -> 3.08 -> 5.85 -> 4.23 GiB inside 40 minutes — so
# neither a single sample nor the latest reading is a usable trigger. The
# MINIMUM of heapUsedBytes over a trailing 60-min window is the only
# monotonic signal (it read 0.46 GiB at 05:00 UTC, 4.03 at 17:00, 5.86 at
# 18:00, with the OOM at 18:59:17 on the incident night).
#
# Two independent gates, both required before a restart fires:
#   1. HEAP_TROUGH_MIN_SAMPLES (default 6) — a journal read with too few (or
#      zero) heapUsedBytes= samples must never default to firing.
#   2. HEAP_TROUGH_RESTART_BYTES (default 4 GiB) — the window's MINIMUM, not
#      its latest or peak value, must be at/above the threshold.
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

  # Hermeticity: cooldown stamps + drain-restart state must NOT read/write the
  # live node-8 fleet state (CI runs this suite ON the gateway host).
  export WATCHDOG_STATE_DIR="$TEST_TMPDIR/state"; mkdir -p "$WATCHDOG_STATE_DIR"
  # The persisted heap samples live in their own root-owned dir, never under
  # the /tmp-default WATCHDOG_STATE_DIR (predictable root-written path).
  export HEAP_STATE_DIR="$TEST_TMPDIR/heapstate"; mkdir -p "$HEAP_STATE_DIR"
  # Never contend with the live cron's real lock (CI runs ON node-8).
  export WATCHDOG_LOCK_FILE="$TEST_TMPDIR/watchdog.lock"
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

  # gateway_main_pid (drain_restart_gateway): `systemctl show -p MainPID
  # --value <svc>` returns STUB_MAINPID_BEFORE on the first call (the
  # pre-request capture) and STUB_MAINPID_AFTER on every call after — so
  # await_gateway_restart sees the "new" PID on its very first poll and the
  # safe drain path completes without ever needing the hard fallback.
  export STUB_MAINPID_BEFORE=111 STUB_MAINPID_AFTER=222
  export MAINPID_CALLS="$TEST_TMPDIR/mainpid-calls"; : > "$MAINPID_CALLS"
  export STUB_RESTART_RECOVERS=1
  # gateway_main_pid uses `show -p MainPID`; the heap-trough trigger separately
  # reads `show -p InvocationID` to scope its journal read to the CURRENTLY
  # RUNNING process (MUS-1600 review finding 2 — a unit+time-only window can
  # be computed almost entirely from a process a crash already killed).
  export STUB_INVOCATION_ID="inv-current-000"
  # Two call shapes appear across this script: check_gateway_liveness() calls
  # `is-active <svc>` (no flags, reads STDOUT text, always expects exit 0 —
  # the base watchdog-bats convention); gateway-restart.sh calls
  # `is-active/is-failed --quiet <svc>` (flag before the unit, exit-code-only,
  # real systemctl semantics). _svc_arg finds the unit regardless of position
  # so both shapes read the SAME per-service status file.
  cat > "$TEST_TMPDIR/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSCTL_CALLS"
_svc_arg() {
  shift
  for a in "$@"; do
    case "$a" in --*) : ;; *) printf '%s' "$a"; return ;; esac
  done
}
case "$1" in
  is-active)
    svc="$(_svc_arg "$@")"
    f="$STUB_SYSCTL_DIR/$svc.status"
    st=$( [ -f "$f" ] && cat "$f" || echo active )
    if printf '%s' "$*" | grep -q -- '--quiet'; then
      [ "$st" = "active" ] && exit 0 || exit 3
    else
      echo "$st"; exit 0   # check_gateway_liveness() reads stdout, not rc
    fi ;;
  is-enabled)
    echo "${STUB_UNIT_ENABLED:-enabled}" ;;
  is-failed)
    svc="$(_svc_arg "$@")"
    f="$STUB_SYSCTL_DIR/$svc.status"
    st=$( [ -f "$f" ] && cat "$f" || echo active )
    [ "$st" = "failed" ] && exit 0 || exit 1 ;;
  show)
    if [ "$3" = "MainPID" ]; then
      n=$(( $(cat "$MAINPID_CALLS" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$MAINPID_CALLS"
      if [ "$n" -le 1 ]; then echo "$STUB_MAINPID_BEFORE"; else echo "$STUB_MAINPID_AFTER"; fi
    elif [ "$3" = "InvocationID" ]; then
      echo "${STUB_INVOCATION_ID-inv-current-000}"
    fi ;;
  restart)
    svc="$(_svc_arg "$@")"
    [ "${STUB_RESTART_RECOVERS:-1}" = "1" ] && echo active > "$STUB_SYSCTL_DIR/$svc.status" ;;
  reset-failed|stop|start) : ;;
esac
exit 0
STUB

  # openclaw stub: config-validate answers (existing watchdog convention) PLUS
  # the drain-restart request (`--profile <p> gateway restart --safe --json`)
  # drain_restart_gateway issues — recorded so tests can prove the restart
  # went through THIS path, not a bare `systemctl restart`.
  export OPENCLAW_CALLS="$TEST_TMPDIR/openclaw-calls"; : > "$OPENCLAW_CALLS"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPENCLAW_CALLS"
if [ "$1" = "--version" ]; then
  echo "openclaw ${STUB_OPENCLAW_VERSION:-2026.8.2}"
  exit 0
fi
# `gateway stability --type diagnostic.memory.sample --json` — the gateway's
# UNCONDITIONAL memory sample stream (MUS-1588 bot finding: the journal's
# `memory pressure:` lines are conditional + rate-limited, so they hold no
# below-threshold samples). Served from $TEST_TMPDIR/stability.json; absent
# fixture = a gateway that has recorded no samples yet.
case " $* " in
  *" gateway stability "*)
    [ -n "${STUB_STABILITY_RC:-}" ] && exit "$STUB_STABILITY_RC"
    # Widens the check-then-stamp window so two overlapping ticks can both
    # pass the cooldown check before either stamps it (the cron race).
    [ -n "${STUB_STABILITY_SLEEP:-}" ] && sleep "$STUB_STABILITY_SLEEP"
    if [ -f "$TEST_TMPDIR/stability.json" ]; then cat "$TEST_TMPDIR/stability.json"
    else echo '{"events":[],"summary":{}}'; fi
    exit 0 ;;
esac
prof=""; mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) prof="$2"; shift 2 ;;
    gateway)   mode="gateway"; shift ;;
    *)         shift ;;
  esac
done
if [ "$mode" = "gateway" ]; then
  # Records whether the cooldown stamp already existed at the moment the safe-
  # restart request went out — i.e. BEFORE the (up to 390s) drain, not after
  # drain_restart_gateway returns. Used to catch a regression to the ordering
  # the original review flagged: stamping only on return leaves every
  # overlapping cron tick during the drain free to fire its own restart.
  if [ -f "$HEAP_STATE_DIR/openclaw-watchdog-cooldown" ]; then
    echo stamped > "$TEST_TMPDIR/cooldown-at-drain-request"
  else
    echo not-stamped > "$TEST_TMPDIR/cooldown-at-drain-request"
  fi
  echo '{"ok":true,"result":"scheduled","message":"safe restart requested"}'
  exit 0
fi
f="$STUB_OPENCLAW_DIR/$prof.validate"
[ -f "$f" ] && cat "$f" || echo "Config valid: /root/.openclaw-$prof/openclaw.json"
exit 0
STUB

  # DR escalation: point the watchdog at a recorder stub — the real
  # dr-ai-healer.sh must NEVER spawn from a test run.
  export DR_CALLS="$TEST_TMPDIR/dr-calls"; : > "$DR_CALLS"
  export DR_STATE_DIR="$TEST_TMPDIR/dr-state"
  export DR_HEALER="$TEST_TMPDIR/bin/dr-healer-stub"
  cat > "$DR_HEALER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DR_CALLS"
exit 0
STUB

  # Per-unit journal stub: emits $TEST_TMPDIR/journal-<unit> regardless of
  # --since, so a single fixture answers every window this script reads
  # (the codex checks' 15min/3min, crash-loop's 10min). None of our
  # heap-pressure lines match any codex/run-agent/restart-log signature, so
  # this is safe to share across all of them.
  #
  # The heap-trough trigger additionally passes a bare `_SYSTEMD_INVOCATION_ID=`
  # match (real journalctl field-match syntax) to scope to the CURRENTLY
  # RUNNING process; when present, serve $TEST_TMPDIR/journal-<unit>-inv-<id>
  # instead — a SEPARATE fixture from the unit-wide one, so a test can prove a
  # dead (previous-invocation) process's samples are excluded even though the
  # unit+time window would otherwise still see them.
  cat > "$TEST_TMPDIR/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
unit="" inv=""
for a in "$@"; do
  case "$a" in _SYSTEMD_INVOCATION_ID=*) inv="${a#_SYSTEMD_INVOCATION_ID=}" ;; esac
done
while [ $# -gt 0 ]; do case "$1" in -u) unit="$2"; shift 2 ;; *) shift ;; esac; done
if [ -n "$unit" ]; then
  if [ -n "$inv" ]; then
    cat "$TEST_TMPDIR/journal-$unit-inv-$inv" 2>/dev/null
  else
    cat "$TEST_TMPDIR/journal-$unit" 2>/dev/null
  fi
fi
exit 0
STUB
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main-inv-$STUB_INVOCATION_ID"
  : > "$TEST_TMPDIR/journal-openclaw-gateway-edge"

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

  # Fast drain loop for tests that DO reach drain_restart_gateway (sleep is
  # already a no-op stub above; these just document/bound the intent).
  # The fixtures space as few as 6 samples across 60 min (~11.6 min apart);
  # the production default max gap (10 min) is exercised by its own tests.
  export HEAP_TROUGH_MAX_GAP_MIN=15
  export GATEWAY_DRAIN_DEADLINE_SECS=5
  export GATEWAY_DRAIN_POLL_SECS=1
}
teardown() { rm -rf "$TEST_TMPDIR"; }

set_status() { echo "$2" > "$STUB_SYSCTL_DIR/$1.status"; }

# The watchdog's shebang is #!/bin/bash and it uses `declare -A`, which needs
# bash 4+. CI (node-8, Linux) has bash 5 at /bin/bash; macOS ships 3.2, so the
# whole suite would only be verifiable in CI without this. WATCHDOG_BASH lets
# a developer run it locally against a modern bash without changing what
# production executes:
#   WATCHDOG_BASH=/opt/homebrew/bin/bash bats scripts/tests/openclaw-watchdog-heap-trough.bats
_run_wd() {
  if [ -n "${WATCHDOG_BASH:-}" ]; then run "$WATCHDOG_BASH" "$WD"; else run "$WD"; fi
}

# _gib <value> — GiB (float) to an exact integer byte count.
_gib() { awk -v g="$1" 'BEGIN{printf "%d", g*1024*1024*1024}'; }

# _sample_rows <oldest_age_min> <newest_age_min> <gib> ... — "<ts_ms> <bytes>"
# rows, oldest first, evenly spaced from <oldest_age_min> to <newest_age_min>
# minutes ago.
_sample_rows() {
  local oldest="$1" newest="$2"; shift 2
  local now; now=$(date +%s)
  local n=$# i=0 g
  for g in "$@"; do
    awk -v now="$now" -v o="$oldest" -v w="$newest" -v i="$i" -v n="$n" -v g="$g" 'BEGIN{
      age = (n>1) ? o - (o-w)*i/(n-1) : w
      printf "%d %d\n", (now - age*60)*1000, g*1024*1024*1024 }'
    i=$((i+1))
  done
}

# _write_stability <oldest_age_min> <newest_age_min> <gib> ... — what the
# gateway's ring buffer returns, in the REAL pretty-printed shape. The trailing
# summary block carries a decoy tiny heapUsedBytes (like the live `latest`
# field) — a parser that reads past "events" would see it and mis-evaluate.
_write_stability() {
  {
    printf '{\n  "generatedAt": "x",\n  "events": [\n'
    local first=1 ts b
    while read -r ts b; do
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {\n      "seq": 1,\n      "ts": %s,\n      "type": "diagnostic.memory.sample",\n      "memory": {\n        "rssBytes": 1,\n        "heapUsedBytes": %s,\n        "externalBytes": 1\n      }\n    }' "$ts" "$b"
    done < <(_sample_rows "$@")
    printf '\n  ],\n  "summary": {\n    "memory": {\n      "latest": {\n        "heapUsedBytes": 123\n      },\n      "maxHeapUsedBytes": 123\n    }\n  }\n}\n'
  } > "$TEST_TMPDIR/stability.json"
}

# _stub_heap_samples <gib> ... — the gateway has been up and sampled across
# the whole evaluation window: values evenly spread over the window, oldest
# first, ending 1 minute ago.
_stub_heap_samples() {
  _write_stability "$(( ${HEAP_TROUGH_WINDOW_MIN:-60} - 1 ))" 1 "$@"
}

# _seed_state <invocation-id> <oldest_age_min> <newest_age_min> <gib> ... —
# samples the watchdog persisted on EARLIER ticks (the ring buffer only keeps
# ~10 minutes, so the 60-min window has to be accumulated across ticks).
_seed_state() {
  local inv="$1"; shift
  { printf '# %s\n' "$inv"; _sample_rows "$@"; } > "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples"
}

# _journal_pressure_lines <gib> ... — the conditional `memory pressure:` lines
# the journal carries (ONLY while above the adaptive threshold). The trigger
# must NOT derive the trough from these.
_journal_pressure_lines() {
  : > "$TEST_TMPDIR/journal-openclaw-gateway-main-inv-$STUB_INVOCATION_ID"
  local g
  for g in "$@"; do
    echo "Sep 30 18:30:00 ovh-node-8 openclaw-gateway-main[123]: [diagnostics/memory] memory pressure: level=critical reason=rss_threshold heapUsedBytes=$(awk -v g="$g" 'BEGIN{printf "%d", g*1024*1024*1024}') pid=123" \
      >> "$TEST_TMPDIR/journal-openclaw-gateway-main-inv-$STUB_INVOCATION_ID"
  done
}

drain_requested() { grep -q -- "--profile main gateway restart --safe --json" "$OPENCLAW_CALLS"; }
no_drain_requested() { ! grep -q -- "--profile main gateway restart --safe --json" "$OPENCLAW_CALLS"; }
no_bare_restart() { ! grep -q "^restart openclaw-gateway-main$" "$SYSCTL_CALLS"; }

@test "trough >= 4.0 GiB restarts even though the latest sample is not the window's peak" {
  # 6 samples (>= HEAP_TROUGH_MIN_SAMPLES), all >= 4.0 GiB, trough = 4.05.
  # The LAST (most recent) sample, 4.30, is well below the window's own peak
  # (5.80) — guards against a regression that reads only the newest line
  # instead of scanning the whole window for the true minimum.
  _stub_heap_samples 4.05 5.80 4.60 4.90 5.10 4.30
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.05)"* ]]
  [[ "$output" == *">= $(_gib 4.0) threshold"* ]]
  [[ "$output" == *"drain-restarting openclaw-gateway-main"* ]]
  drain_requested
  [[ "$output" == *"drain-restarted openclaw-gateway-main proactively"* ]]
}

@test "tonight's real numbers (peak 5.85, trough 3.08) do NOT restart — the false-positive case" {
  # The exact sawtooth from the incident (issue MUS-1588), plus one filler
  # sample (5.00, still above the 3.08 trough) to clear HEAP_TROUGH_MIN_SAMPLES
  # without changing the minimum. A `heap >= 6.0`-style level check, or a
  # max-based bug, would restart here; the trough (3.08 GiB) must not.
  _stub_heap_samples 5.66 3.96 3.08 5.85 4.23 5.00
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 3.08)"* ]]
  [[ "$output" == *"threshold) — healthy, no action"* ]]
  no_drain_requested
  [ ! -s "$MUSO_CALLS" ]
}

@test "fewer than HEAP_TROUGH_MIN_SAMPLES does not restart, even with every sample above threshold" {
  _stub_heap_samples 4.50 4.80 5.10   # 3 samples, all >= 4.0, but < default 6
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: 3 heapUsedBytes sample(s)"* ]]
  [[ "$output" == *"(< 6 required) — not evaluating, NOT restarting"* ]]
  no_drain_requested
}

@test "zero samples from the gateway does not restart, and does not crash the tick" {
  rm -f "$TEST_TMPDIR/stability.json"   # gateway has recorded no samples at all
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: 0 heapUsedBytes sample(s)"* ]]
  [[ "$output" == *"NOT restarting"* ]]
  no_drain_requested
  # An empty parse must not trip `set -e` under `pipefail` — status -eq 0
  # above proves the tick completed rather than aborting mid-script.
}

@test "an ACTIVE maintenance window suppresses the heap-trough restart" {
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50   # would otherwise clearly restart
  printf '{"reason":"openclaw upgrade","expires_epoch":%s}' "$(( $(date -u +%s) + 3600 ))" \
    > "$HYDRA_MAINTENANCE_FLAG"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"maintenance: openclaw upgrade - skipping"* ]]
  [[ "$output" != *"HEAP TROUGH"* ]]
  no_drain_requested
}

@test "restart goes through drain_restart_gateway, not a bare systemctl restart" {
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  # The safe-restart CLI request is issued (only drain_restart_gateway does this):
  drain_requested
  # gateway-restart.sh's own log prefix proves the lib actually ran, not just
  # that SOME restart happened:
  [[ "$output" == *"[gateway-restart]"* ]]
  [[ "$output" == *"restarted after drain"* ]]
  # And the STUCK path's bare `systemctl restart` line never fires in this tick
  # (no agent-run activity was stubbed, so MSG_COUNT stays 0 — belt & braces
  # against the two restart reasons being confused for one another):
  no_bare_restart
}

@test "a drain_restart_gateway FAILURE pages critical and escalates to the DR healer" {
  # A genuinely down-and-staying-down unit: `is-failed` reports failed from
  # the start (await_gateway_restart bails to the hard fallback immediately
  # rather than waiting out the full drain deadline), and STUB_RESTART_RECOVERS=0
  # means the hard fallback's own `systemctl restart` never flips it active
  # either — both restart paths genuinely fail. (The pre-existing gateway-
  # liveness check also reacts to the same down unit earlier in the tick —
  # expected, and orthogonal to the assertions below.)
  set_status openclaw-gateway-main failed
  export STUB_RESTART_RECOVERS=0
  export GATEWAY_HARD_POLL_TRIES=1 GATEWAY_HARD_POLL_SECS=1
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: drain-restart of openclaw-gateway-main FAILED"* ]]
  grep -q -- '--trigger heap_trough_restart_failed' "$DR_CALLS"
  # Cooldown still stamps on failure — a broken restart must not retry every tick:
  [ -f "$HEAP_STATE_DIR/openclaw-watchdog-cooldown" ]
}

@test "a fresh cooldown stamp suppresses a second heap-trough restart within COOLDOWN_MIN" {
  date +%s > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: SKIP restart"* ]]
  no_drain_requested
}

@test "HEAP_TROUGH_RESTART_BYTES and HEAP_TROUGH_MIN_SAMPLES env overrides are honoured" {
  export HEAP_TROUGH_RESTART_BYTES=6442450944   # 6.0 GiB — nothing in the fixture reaches this
  export HEAP_TROUGH_MIN_SAMPLES=3
  export HEAP_TROUGH_MAX_GAP_MIN=60   # 3 samples span the window sparsely; coverage has its own tests
  _stub_heap_samples 5.00 5.10 5.20   # 3 samples clears the lowered sample floor...
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 5.00)"* ]]
  # ...but none reach the raised 6.0 GiB threshold, so still no restart:
  [[ "$output" == *"(< 6442450944 threshold)"* ]]
  no_drain_requested
}

@test "HEAP_TROUGH_WINDOW_MIN override is reflected in the evaluated window" {
  # The helper spreads its samples over the OVERRIDDEN window, so this pins
  # that the override is threaded into both the log line and the evaluation
  # (samples older than the window are pruned, so a hardcoded 60 would change
  # which samples count).
  export HEAP_TROUGH_WINDOW_MIN=5
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"in last 5min"* ]]
  [[ "$output" != *"in last 60min"* ]]
  drain_requested
}

@test "a trough exactly AT the threshold still restarts (>=, not >)" {
  # All 6 samples exactly 4.0 GiB: trough == HEAP_TROUGH_RESTART_BYTES exactly.
  # Catches a boundary regression from `-lt` to `-le` on the healthy-branch
  # comparison, which would wrongly read an exact-threshold trough as "below"
  # and skip the restart.
  _stub_heap_samples 4.0 4.0 4.0 4.0 4.0 4.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.0)"* ]]
  [[ "$output" == *">= $(_gib 4.0) threshold"* ]]
  drain_requested
}

@test "the cooldown stamp is written BEFORE the drain request, not after it returns" {
  # MUS-1600 review finding 1: the watchdog is a lockless */2 cron; stamping
  # only on drain_restart_gateway's return leaves every overlapping tick
  # during a busy-gateway drain (up to GATEWAY_DRAIN_DEADLINE_SECS, default
  # 390s) free to fire its own restart. The openclaw stub's gateway-mode
  # branch records whether the cooldown file already existed the moment the
  # safe-restart request actually went out.
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  drain_requested
  [ "$(cat "$TEST_TMPDIR/cooldown-at-drain-request")" = "stamped" ]
}

@test "a dead process's persisted samples do not survive into the freshly-restarted process's evaluation" {
  # MUS-1600 review finding 2: the watchdog persists samples across ticks, so
  # the file can hold the process a crash just killed. 8 samples >= threshold
  # were persisted under the PREVIOUS invocation; the fresh process (new
  # InvocationID) has sampled once so far. A restart is a hard boundary: the
  # old samples must be discarded, not read as the new process's trough.
  _seed_state "inv-dead-999" 59 10 5.00 5.10 5.20 5.30 5.40 5.50 5.60 5.70
  _write_stability 1 1 0.46
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: 1 heapUsedBytes sample(s)"* ]]
  [[ "$output" == *"NOT restarting"* ]]
  no_drain_requested
}

@test "REGRESSION (QA bot): warnings above 4 GiB with an intervening ordinary sample below 4 GiB must not restart" {
  # The journal only carries `memory pressure:` lines while the process is
  # ABOVE the adaptive pressure threshold, and rate-limits them. So the
  # journal can hold six warnings at 4.2-5.0 GiB while the heap GC-dropped to
  # 3.0 GiB in between with no line emitted. The unconditional sample stream
  # sees that dip. Deriving the trough from the warnings alone would restart
  # a healthy gateway here.
  _journal_pressure_lines 4.2 4.5 4.8 5.0 4.6 4.4
  _stub_heap_samples 4.2 4.5 3.0 4.8 5.0 4.6 4.4 4.3
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 3.0)"* ]]
  [[ "$output" == *"healthy, no action"* ]]
  no_drain_requested
}

@test "the trough is accumulated across ticks: the ring buffer alone only holds ~10 minutes" {
  # Earlier ticks persisted the first half of the window; THIS tick's RPC
  # returns only the most recent samples. The low sample (3.0) is only in the
  # persisted half: a read of the ring alone would see min 4.5 and restart.
  _seed_state "$STUB_INVOCATION_ID" 59 32 4.6 3.0 4.8 4.7
  _write_stability 25 1 4.5 4.6 4.7 4.8 4.9 5.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 3.0)"* ]]
  no_drain_requested
}

@test "persisted + fresh samples ALL above threshold across the whole window do restart" {
  _seed_state "$STUB_INVOCATION_ID" 59 32 4.6 4.1 4.8 4.7
  _write_stability 25 1 4.5 4.6 4.7 4.8 4.9 5.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.1)"* ]]
  drain_requested
}

@test "a gap in the window larger than HEAP_TROUGH_MAX_GAP_MIN fails closed (a dip could hide in it)" {
  export HEAP_TROUGH_MAX_GAP_MIN=10
  # 8 samples >= 4 GiB, but nothing between 45 and 15 minutes ago.
  _seed_state "$STUB_INVOCATION_ID" 59 45 4.5 4.6 4.7 4.8
  _write_stability 15 1 4.5 4.6 4.7 4.8
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not cover the last 60min"* ]]
  [[ "$output" == *"NOT restarting"* ]]
  no_drain_requested
}

@test "a gateway observed for less than the window (just restarted / watchdog just deployed) does not restart" {
  export HEAP_TROUGH_MAX_GAP_MIN=10
  _write_stability 20 1 4.5 4.6 4.7 4.8 4.9 5.0 5.1 5.2 5.3
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not cover the last 60min"* ]]
  no_drain_requested
}

@test "an unreachable stability RPC does not restart off stale persisted samples" {
  export HEAP_TROUGH_MAX_GAP_MIN=10
  _seed_state "$STUB_INVOCATION_ID" 59 20 4.5 4.6 4.7 4.8 4.9 5.0 5.1 5.2
  export STUB_STABILITY_RC=1
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not cover the last 60min"* ]]
  no_drain_requested
}

@test "a persisted sample OLDER than the window is ignored (a stale dip must not suppress a real restart)" {
  # 3.0 GiB sample from 100 minutes ago, outside the 60-min window; everything
  # inside the window is >= 4 GiB and fully covered. The old dip is not part
  # of the trailing-window minimum, so this restarts.
  { printf '# %s\n' "$STUB_INVOCATION_ID"; _sample_rows 100 100 3.0; _sample_rows 59 32 4.6 4.7 4.8 4.9; } \
    > "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples"
  _write_stability 25 1 4.5 4.6 4.7 4.8 4.9 5.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.5)"* ]]
  drain_requested
}

@test "an overlong heapUsedBytes in the RPC output is dropped, never compared (no exit-2 fall-through)" {
  # 5 valid samples + 1 with a 25-digit value in the RPC JSON: only 5 count,
  # so the floor of 6 refuses; the bogus value must neither count nor reach a
  # shell `[ -lt ]` (exit 2 inside an `elif` falls through to the restart branch).
  _write_stability 59 1 5.0 5.1 5.2 5.3 5.4 5.5
  sed -i.bak "$(grep -n '"heapUsedBytes"' "$TEST_TMPDIR/stability.json" | sed -n 6p | cut -d: -f1)s/[0-9]\{6,\}/9999999999999999999999999/" "$TEST_TMPDIR/stability.json"
  grep -q 9999999999999999999999999 "$TEST_TMPDIR/stability.json"
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: 5 heapUsedBytes sample(s)"* ]]
  no_drain_requested
}

@test "an unreadable InvocationID fails closed instead of falling back to the unscoped read" {
  # If we can't even tell which process is running, we can't verify the
  # trough is ABOUT that process — same fail-safe posture as zero samples,
  # not a reason to fall back to the restart-crossing unit+time read finding 2
  # exists to avoid. The unit-wide fixture below has 6 clearly-restart-worthy
  # samples; the empty InvocationID must still suppress the restart.
  export STUB_INVOCATION_ID=""
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not read openclaw-gateway-main's InvocationID"* ]]
  no_drain_requested
}

@test "a non-numeric HEAP_TROUGH_MIN_SAMPLES falls back to the default rather than failing open" {
  # `[ 6 -lt "abc" ]` exits 2 (not 1), and an `if` condition is exempt from
  # `set -e`, so an unguarded override would silently fall through past the
  # sample-count `elif`/`else` as though the floor were cleared — not an
  # error, not the default, just skipped. 3 samples must still fail the
  # (restored) default floor of 6.
  export HEAP_TROUGH_MIN_SAMPLES="abc"
  _stub_heap_samples 5.00 5.10 5.20
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(< 6 required) — not evaluating, NOT restarting"* ]]
  no_drain_requested
}

@test "a non-numeric HEAP_TROUGH_RESTART_BYTES falls back to the default rather than restarting a healthy gateway" {
  # MUS-1667 review finding 1: `[ N -lt "4GiB" ]` exits 2, and the `if` is
  # exempt from `set -e`, so this would otherwise fall through to the
  # RESTART branch regardless of the actual trough -- the worse direction of
  # the twin HEAP_TROUGH_MIN_SAMPLES guard above (restarting production, not
  # just clearing a floor). 6 samples at 0.5 GiB are nowhere near any real
  # threshold; the restored default (4294967296) must keep this healthy.
  export HEAP_TROUGH_RESTART_BYTES="4GiB"
  _stub_heap_samples 0.5 0.5 0.5 0.5 0.5 0.5
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(< 4294967296 threshold) — healthy, no action"* ]]
  no_drain_requested
}

@test "a drain that falls back to hard restart notifies via GATEWAY_FALLBACK_NOTIFY_FN, not silently" {
  # MUS-1667 review finding 2: the safe path never completes (MainPID never
  # "changes") but the hard fallback DOES recover -- drain_restart_gateway
  # returns 0 and this trigger takes its SUCCESS branch, even though the
  # drain itself silently degraded to a hard SIGTERM kill. The fallback
  # itself must be reported, not just the overall "it's back" outcome.
  # (Needs a real-looking token so slack_notify doesn't early-return before
  # ever reaching the muso stub — same convention as
  # openclaw-watchdog-liveness.bats's "restart-FAILED page carries real
  # user-ID mentions" test.)
  export STUB_MAINPID_AFTER="$STUB_MAINPID_BEFORE"   # safe path's PID never "changes"
  export GATEWAY_DRAIN_DEADLINE_SECS=1 GATEWAY_DRAIN_POLL_SECS=1
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
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"drain-restarted openclaw-gateway-main proactively"* ]]   # success branch taken
  grep -q "hard restart fallback" "$MUSO_TEXTS"   # ...but the degrade was still reported
}

# ── Heap-trough cooldown _sane_epoch hardening ────────────────────────────────
# The STUCK path's equivalent cooldown carries 4 dedicated cases
# (openclaw-watchdog-liveness.bats: octal-looking, corrupt, far-future,
# fresh). This trigger reuses the same _sane_epoch helper on the same
# COOLDOWN_FILE but had none of its own (MUS-1667 review finding 4) --
# deleting the _sane_epoch call left the suite green. A corrupt/future stamp
# here is the inverse failure direction of finding 1: it SUPPRESSES a
# restart indefinitely, which is the OOM this trigger exists to prevent.

@test "a corrupt heap-trough cooldown stamp does not kill the watchdog mid-tick" {
  printf '1abc' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" != *"value too great for base"* ]]
  drain_requested   # corrupt stamp normalises to 0 -> "no recent restart" -> not suppressed
}

@test "an octal-looking heap-trough cooldown stamp does not swallow the restart" {
  printf '08' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" != *"value too great for base"* ]]
  drain_requested
}

@test "a far-future heap-trough cooldown stamp does not suppress the restart forever" {
  printf '9999999999' > "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" != *"SKIP restart"* ]]
  drain_requested
}

# ── Overlong digits-only overrides (GitHub Muso QA Bot, hydra#1046) ──────────
# Digits-only is NOT the same as "safely comparable by bash's [ -lt ]": both
# operands are represented as (at most) a signed 64-bit integer, so an
# all-digit value past ~19 digits makes the comparison ITSELF exit 2
# ("integer expected") rather than evaluating true/false — and since that
# comparison sits in an `if`/`elif`, `set -e` never traps it. Both knobs that
# feed a `[ -lt ]` comparison need a length bound, not just a digits-only one.

@test "an overlong HEAP_TROUGH_RESTART_BYTES does not drain-restart a healthy gateway" {
  # The bot's exact reproduction: a 24-digit value passes the digits-only
  # guard, but `[ 536870912 -lt 999...999 ]` exits 2, and the `elif` falls
  # through to the RESTART branch for a process nowhere near any real
  # threshold.
  export HEAP_TROUGH_RESTART_BYTES="999999999999999999999999"
  _stub_heap_samples 0.5 0.5 0.5 0.5 0.5 0.5
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(< 4294967296 threshold) — healthy, no action"* ]]
  no_drain_requested
}

@test "an overlong HEAP_TROUGH_MIN_SAMPLES does not restart on too few real samples" {
  # Same overflow class, reached through the LEADING sample-count check: with
  # only 1 real sample, `[ 1 -lt 999...999 ]` should read "insufficient
  # sample" and refuse -- if it instead exits 2 and falls through, a single
  # high reading can reach the RESTART branch with no real trough evidence.
  export HEAP_TROUGH_MIN_SAMPLES="999999999999999999999999"
  _stub_heap_samples 5.00
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(< 6 required) — not evaluating, NOT restarting"* ]]
  no_drain_requested
}

@test "an unsafe (symlinked) heap state dir is refused: victim not truncated, no restart" {
  # A local user who can pre-create the sample path as a symlink could make the
  # root cron job truncate any file. The dir gate (mirrors _dr_state_ok) must
  # refuse, log it, and skip the whole trigger. Never fall back to /tmp.
  mkdir -p "$TEST_TMPDIR/victim-dir"
  printf 'KEEP' > "$TEST_TMPDIR/victim-dir/openclaw-watchdog-heap-samples"
  rm -rf "$HEAP_STATE_DIR"; ln -s "$TEST_TMPDIR/victim-dir" "$HEAP_STATE_DIR"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"heap state dir"*"unsafe"* ]]
  [ "$(cat "$TEST_TMPDIR/victim-dir/openclaw-watchdog-heap-samples")" = "KEEP" ]
  [ "$(find "$TEST_TMPDIR/victim-dir" -type f | wc -l | tr -d ' ')" = "1" ]
  no_drain_requested
  no_bare_restart
}

@test "a future-dated persisted row is dropped and cannot freeze the window or hide the trough" {
  # One row at now+1h with a LOW heap (1 GiB). Poisoned behaviour: it becomes
  # `last`, so every later sample fails ts>last (window stops accumulating);
  # and unbounded stats would take its 1 GiB as the min. All real samples are
  # >= 4.5 GiB and cover the window, so the correct outcome is a restart.
  local fut=$(( ($(date +%s) + 3600) * 1000 ))
  { printf '# %s\n' "$STUB_INVOCATION_ID"; _sample_rows 59 32 4.6 4.7 4.8 4.9
    printf '%s %s\n' "$fut" "$(_gib 1.0)"; } > "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples"
  _write_stability 25 1 4.5 4.6 4.7 4.8 4.9 5.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.5)"* ]]
  drain_requested
  [ -z "$(grep "^$fut " "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples" || true)" ]
  [ "$(grep -c '^[0-9]' "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples")" -ge 10 ]
}

@test "the stats pass bounds the window itself: a failed trim cannot let a future row hide the trough" {
  # The trim normally removes the future row before stats run, so the stats
  # pass's own bounds are only reachable when the trim cannot happen (mktemp
  # failing). The 1 GiB future row must still not count as the minimum.
  printf '#!/bin/sh\nexit 1\n' > "$TEST_TMPDIR/bin/mktemp"; chmod +x "$TEST_TMPDIR/bin/mktemp"
  local fut=$(( ($(date +%s) + 3600) * 1000 ))
  { printf '# %s\n' "$STUB_INVOCATION_ID"; _sample_rows 59 32 4.6 4.7 4.8 4.9
    printf '%s %s\n' "$fut" "$(_gib 1.0)"; } > "$HEAP_STATE_DIR/openclaw-watchdog-heap-samples"
  _write_stability 25 1 4.5 4.6 4.7 4.8 4.9 5.0
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAP TROUGH: min heapUsedBytes=$(_gib 4.5)"* ]]
  drain_requested
}

# CTO ruling on bot Critical (hydra#1046, COOLDOWN_FILE under /tmp): the restart
# cooldown stamp is written as root, so it must live in the gated root-owned dir
# and be written with a rename that replaces, never follows, a planted symlink.
@test "the old /tmp-style cooldown path as a symlink: victim not truncated, restart still fires" {
  printf 'KEEP' > "$TEST_TMPDIR/victim"
  ln -s "$TEST_TMPDIR/victim" "$WATCHDOG_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/victim")" = "KEEP" ]
  drain_requested
  [ -f "$HEAP_STATE_DIR/openclaw-watchdog-cooldown" ]
}

@test "a symlink planted AT the cooldown path inside the state dir is replaced, not followed" {
  printf 'KEEP' > "$TEST_TMPDIR/victim"
  ln -s "$TEST_TMPDIR/victim" "$HEAP_STATE_DIR/openclaw-watchdog-cooldown"
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/victim")" = "KEEP" ]
  [ ! -L "$HEAP_STATE_DIR/openclaw-watchdog-cooldown" ]
  [[ "$(cat "$HEAP_STATE_DIR/openclaw-watchdog-cooldown")" =~ ^[0-9]+$ ]]
}

# Bot Important on hydra#1046 @ cbc43756: the cooldown check and claim are not
# atomic across overlapping */2 cron processes, so two ticks that both read "no
# cooldown" each fire their own drain_restart_gateway (and, after the drain
# deadline, two competing hard SIGTERMs). The sample-file append/trim races the
# same way. The whole tick is serialized with flock; a held lock skips, exit 0.
@test "two overlapping ticks issue exactly ONE safe-restart request; the loser skips" {
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  export STUB_STABILITY_SLEEP=2
  local runner="$TEST_TMPDIR/runner.sh"
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "${WATCHDOG_BASH:-$WD} ${WATCHDOG_BASH:+$WD}" > "$runner"
  chmod +x "$runner"
  "$runner" > "$TEST_TMPDIR/tick-a.out" 2>&1 &
  local a=$!
  sleep 0.5
  "$runner" > "$TEST_TMPDIR/tick-b.out" 2>&1 &
  local b=$!
  wait "$a"; local ra=$?
  wait "$b"; local rb=$?
  [ "$ra" -eq 0 ]
  [ "$rb" -eq 0 ]
  [ "$(grep -c -- "--profile main gateway restart --safe --json" "$OPENCLAW_CALLS")" = "1" ]
  grep -q "previous tick still running - skip" "$TEST_TMPDIR/tick-a.out" "$TEST_TMPDIR/tick-b.out"
}

@test "a released lock does not block the next tick" {
  _stub_heap_samples 5.00 5.10 5.20 5.30 5.40 5.50
  _run_wd
  [ "$status" -eq 0 ]
  [[ "$output" != *"previous tick still running"* ]]
  drain_requested
}

#!/usr/bin/env bats
# Tests for deploy.sh's post-restart readiness gate (wait_for_agents_bound).
#
# WHY THIS FILE EXISTS
# --------------------
# On 2026-08-18 deploy run 32138151653 rolled the fleet back. The gate reported
# "✓ All 9/9 agents bound on main after 0s" ONE SECOND before the restarted
# gateway's HTTP server started listening; Step 6b then ran `cron list --all
# --json`, got a refused connection, and reported it as an unverifiable cron
# store — reverting a PR whose diff never touched cron.
#
# The gate probed `openclaw agents list --bindings`, which reads the on-disk
# agent config and answers the full count with NO gateway at all. Measured on
# node-8 that day:
#
#   openclaw --profile main agents list --bindings --url http://127.0.0.1:19999 -> prints 9
#   openclaw --profile main agents list --bindings --timeout 1                  -> prints 9
#   openclaw --profile main health          --timeout 1                         -> rc 1
#
# So the gate could never fail, and every downstream step ran against a gateway
# that might not be up. These tests pin the difference: the probe must FAIL
# while the gateway is unreachable.
#
# deploy.sh has no bats suite (it is a script, not a lib — sourcing it would run
# a deploy), so this follows deploy-step5a-import.bats and EXTRACTS the shipped
# function out of deploy.sh, exercising the bytes that deploy rather than a copy
# that can drift.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin"

  # Extract wait_for_agents_bound AND check_gateway_not_crashlooping, then
  # PROVE both extractions worked. A silently empty extraction would make
  # every assertion below vacuous — the failure mode a gate must never have.
  awk '/^wait_for_agents_bound\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/fn.sh"
  [ -s "$TEST_TMPDIR/fn.sh" ] || { echo "wait_for_agents_bound extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q 'wait_for_agents_bound() {' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the opening line" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }

  awk '/^check_gateway_not_crashlooping\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/crashloop-fn.sh"
  [ -s "$TEST_TMPDIR/crashloop-fn.sh" ] || { echo "check_gateway_not_crashlooping extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q 'check_gateway_not_crashlooping() {' "$TEST_TMPDIR/crashloop-fn.sh" || { echo "extraction missing the opening line" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/crashloop-fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }

  # deploy.sh supplies these around the function; the tests supply them here.
  # fail() mirrors deploy.sh's own shape (log then exit 1) minus notify_slack,
  # which these tests have no reason to stub — the exit-1 contract is what
  # check_gateway_not_crashlooping's callers (and the workflow's failure()
  # rollback step) actually depend on.
  log() { printf '%s\n' "$*"; }
  fail() { log "FATAL: $*"; exit 1; }
  export DEPLOY_PATH="$TEST_TMPDIR/deploy"
  mkdir -p "$DEPLOY_PATH"

  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
  # Keep gateway_crash_looping's SubState sampling loop instant in tests — it
  # still runs its full GATEWAY_CRASHLOOP_STATE_SAMPLES (default 3) iterations,
  # just with no real sleep between them, so the sampling LOGIC is exercised
  # without paying real wall-clock time per test.
  export GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS=0
  # Same reasoning for gateway_nrestarts_retry's own retry loop (2026-09-23
  # QA finding on #1010): keep the retry LOGIC live (still runs the full
  # GATEWAY_NRESTARTS_RETRY_TRIES attempts) without paying real wall-clock
  # sleep per test.
  export GATEWAY_NRESTARTS_RETRY_INTERVAL_SECS=0
  # MIRROR deploy.sh's shell options (`set -euo pipefail`, line 2). pipefail is
  # load-bearing here: without it a failing `openclaw` inside the probe's
  # pipeline reads as success, and the "0\n0" double-zero bug that shipped in
  # this suite's first version stays invisible. A stub environment laxer than
  # production makes broken code look tested.
  set -o pipefail
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/fn.sh"
  # The crash-loop primitives (gateway_nrestarts / gateway_crash_looping /
  # gateway_journal_tail) are sourced from the REAL lib, same doctrine as
  # extracting wait_for_agents_bound out of deploy.sh — exercise the bytes
  # that ship, never a copy that can drift.
  # shellcheck source=../lib/gateway-restart.sh
  source "$HYDRA_REPO/scripts/lib/gateway-restart.sh"
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/crashloop-fn.sh"
}

# warmup_check <profile> <service> <baseline> — the exact sequence deploy.sh
# runs at every wait_for_agents_bound call site: wait (non-fatal on timeout),
# then the crash-loop gate.
warmup_check() {
  local profile="$1" svc="$2" baseline="$3"
  wait_for_agents_bound "$profile" 2 || true
  check_gateway_not_crashlooping "$svc" "$baseline"
}

# stub_systemctl <nrestarts> [substate(s)] [is_failed_rc] — controls the
# answers gateway_crash_looping reads.
#
# nrestarts seeds a STATEFUL counter file, not a fixed answer: a `systemctl
# restart <unit>` on the stubbed unit resets it to 0, mirroring the REAL
# systemd 255 behaviour measured live on node-8 (a crash-looping transient
# unit read NRestarts=4; `systemctl restart` on it read back 0 immediately
# after). Earlier revisions of this stub answered a fixed value regardless of
# `restart`, which is why the first crash-loop gate design (baseline captured
# BEFORE the deploy's own restart) passed its tests while missing the actual
# 2026-09-22 incident shape — the stub disagreed with systemd.
#
# substate(s) defaults to "running" (a healthy, non-restarting unit) and may
# be a comma-separated sequence (e.g. "auto-restart,running,auto-restart") —
# gateway_crash_looping now SAMPLES SubState multiple times across a short
# window rather than trusting one snapshot (a crash loop's `running` moments
# are real but brief), so a test modelling a flapping unit needs more than
# one canned answer. Each successive `show -p SubState` call consumes the
# next entry; the last entry repeats once the sequence is exhausted.
#
# is_failed_rc defaults to 1 (systemctl is-failed --quiet exits nonzero when
# the unit is NOT in the failed state).
#
# nrestarts_rc defaults to 0 (a healthy read). A nonzero value makes EVERY
# `show -p NRestarts --value` call fail (no output, exit nrestarts_rc) —
# models a `systemctl show`/SSH hiccup that doesn't clear on its own, i.e.
# gateway_nrestarts_retry exhausting every attempt (2026-09-23 QA finding on
# #1010's regression tests, below).
stub_systemctl() {
  local nrestarts="$1" substates="${2:-running}" is_failed_rc="${3:-1}" nrestarts_rc="${4:-0}"
  echo "$nrestarts" > "$TEST_TMPDIR/nrestarts"
  echo "$substates" > "$TEST_TMPDIR/substates"
  echo 0 > "$TEST_TMPDIR/substate_idx"
  cat > "$TEST_TMPDIR/bin/systemctl" <<STUB
#!/bin/bash
case "\$*" in
  "restart "*)
    echo 0 > "$TEST_TMPDIR/nrestarts"
    exit 0
    ;;
  "show -p NRestarts --value "*)
    if [ "$nrestarts_rc" != "0" ]; then exit $nrestarts_rc; fi
    cat "$TEST_TMPDIR/nrestarts"
    ;;
  "show -p SubState --value "*)
    idx=\$(cat "$TEST_TMPDIR/substate_idx")
    IFS=',' read -r -a arr <<< "\$(cat "$TEST_TMPDIR/substates")"
    last=\$(( \${#arr[@]} - 1 ))
    [ "\$idx" -gt "\$last" ] && idx="\$last"
    echo "\${arr[\$idx]}"
    echo \$(( idx + 1 )) > "$TEST_TMPDIR/substate_idx"
    ;;
  "is-failed --quiet "*) exit $is_failed_rc ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TEST_TMPDIR/bin/systemctl"
}

stub_journalctl() {
  # The content goes to a FILE and the stub cats it back verbatim. Pasting it
  # into `echo "..."` inside an unquoted heredoc let the shell strip any quotes
  # the journal line itself contained -- the stub rewrote its input.
  printf '%s\n' "${1:-<stub journal line>}" > "$TEST_TMPDIR/journal.txt"
  cat > "$TEST_TMPDIR/bin/journalctl" <<STUB
#!/bin/bash
cat "$TEST_TMPDIR/journal.txt"
STUB
  chmod +x "$TEST_TMPDIR/bin/journalctl"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# Write openclaw-<profile>.json declaring $2 enabled agents.
declare_agents() {
  local profile="$1" n="$2" i list=""
  for (( i = 1; i <= n; i++ )); do
    list="${list}{\"id\":\"a$i\",\"enabled\":true},"
  done
  printf '{"agents":{"list":[%s]}}' "${list%,}" > "$DEPLOY_PATH/openclaw-${profile}.json"
}

# The stub MIRRORS the measured production contract, and the asymmetry is the
# whole point: `agents list --bindings` succeeds with the gateway DOWN, while
# `health` fails. A stub that failed both would make the new probe pass for the
# wrong reason and prove nothing.
#
# $1 = gateway state: up | down | notok
# $2 = agent count the gateway reports (when up)
stub_openclaw() {
  local state="$1" n="${2:-0}"
  cat > "$TEST_TMPDIR/bin/openclaw" <<STUB
#!/bin/bash
state="$state"
n="$n"
STUB
  cat >> "$TEST_TMPDIR/bin/openclaw" <<'STUB'
args="$*"
case "$args" in
  *"agents list"*)
    # Local read of on-disk config: answers even with no gateway running.
    for (( i = 1; i <= 9; i++ )); do printf -- "- a%s\n" "$i"; done
    exit 0
    ;;
  *health*)
    case "$state" in
      down) echo "connect ECONNREFUSED 127.0.0.1:18789" >&2; exit 1 ;;
      notok) printf '{"ok":false,"agents":[]}\n'; exit 0 ;;
      up)
        printf '{"ok":true,"agents":['
        for (( i = 1; i <= n; i++ )); do
          [ "$i" -gt 1 ] && printf ','
          printf '{"agentId":"a%s"}' "$i"
        done
        printf ']}\n'
        exit 0
        ;;
    esac
    ;;
esac
exit 64
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
}

@test "passes once the gateway answers with the expected agents bound" {
  declare_agents main 9
  stub_openclaw up 9
  run wait_for_agents_bound main 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 9/9 agents bound"* ]]
}

@test "2026-08-18 regression: FAILS while the gateway is unreachable" {
  declare_agents main 9
  # `agents list --bindings` still prints 9 here — exactly the production
  # behaviour that made the old probe report "bound after 0s" against a gateway
  # that was not listening yet.
  stub_openclaw down 9
  run wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout"* ]]
  [[ "$output" != *"All 9/9 agents bound"* ]]
}

@test "an unreachable gateway yields ONE zero, not a pipefail double-zero" {
  # Regression: the probe was one pipeline ending in `|| echo 0`. Under
  # pipefail a failing `openclaw` made the pipeline non-zero even though the
  # parser had already printed its 0, so the fallback appended a SECOND zero.
  # `bound` became "0\n0": every poll died with
  #   ((: 0\n0: arithmetic syntax error in expression
  # and the timeout line read "0\n0/9". The refusal was still correct, which
  # is exactly why only the diagnostics gave it away.
  declare_agents main 9
  stub_openclaw down 9
  run --separate-stderr wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
  [[ "$stderr" != *"syntax error"* ]]
  [[ "$stderr" != *"arithmetic"* ]]
  # The count must render as a single well-formed value.
  [[ "$output" == *"0/9"* ]]
}

@test "a reachable gateway reporting ok=false is not 'bound'" {
  declare_agents main 9
  stub_openclaw notok 9
  run wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
}

@test "a partially bound gateway is not counted as fully bound" {
  declare_agents main 9
  stub_openclaw up 4
  run wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
  [[ "$output" == *"4/9"* ]]
}

@test "edge's single agent is handled like main's nine" {
  declare_agents edge 1
  stub_openclaw up 1
  run wait_for_agents_bound edge 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"All 1/1 agents bound"* ]]
}

@test "garbage from the CLI is not read as a successful bind" {
  declare_agents main 9
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
echo "Cannot GET /health"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  run wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
}

@test "an unreadable profile config is reported, not silently passed" {
  # No openclaw-main.json written at all.
  stub_openclaw up 9
  run wait_for_agents_bound main 4
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# check_gateway_not_crashlooping — 2026-09-22 incident (deploy run
# 35773324797): edge crash-looped 43x over ~17min after a restart while
# Step 6/6b logged only a non-fatal warning.
# ---------------------------------------------------------------------------

@test "crash loop: NRestarts increased since baseline -> deploy step FAILS with the named message" {
  declare_agents main 9
  stub_openclaw down 9          # crashing gateway never answers health
  stub_systemctl 5               # baseline will be 2; current is 5 -> increased
  stub_journalctl "openclaw plugin verification failed; refusing to report the gateway ready"
  run warmup_check main openclaw-gateway-main 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
  [[ "$output" == *"openclaw-gateway-main"* ]]
  [[ "$output" == *"NRestarts 2 -> 5"* ]]
  [[ "$output" == *"plugin verification failed"* ]]
}

@test "crash loop: unit stuck auto-restart with an UNCHANGED NRestarts still FAILS" {
  declare_agents edge 1
  stub_openclaw down 1
  # NRestarts unchanged (2 -> 2) but the unit is caught in the systemd
  # restart-backoff gap between crashes -- this must be caught independently
  # of the counter, since a check timed exactly between two crashes could
  # read the same counter value twice.
  stub_systemctl 2 auto-restart
  stub_journalctl "crash-loop journal line"
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "crash loop: unit in systemd's own failed state (start-limit hit) still FAILS" {
  declare_agents edge 1
  stub_openclaw down 1
  # NRestarts unchanged (2 -> 2) and the substate check alone would read
  # healthy ("running"), but `systemctl is-failed` reports the unit AS
  # failed (rc 0) -- systemd gave up after hitting its start-limit-burst.
  # This is the third independent signal gateway_crash_looping checks, and
  # it must be caught even when neither the counter nor SubState moved.
  stub_systemctl 2 running 0
  stub_journalctl "start-limit-hit: openclaw-gateway-edge.service"
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "slow bind: active, not restarting, never binds within timeout -> warns and CONTINUES" {
  declare_agents main 9
  stub_openclaw down 9          # never binds within the (short) test timeout
  stub_systemctl 2 running       # NRestarts unchanged, healthy substate
  run warmup_check main openclaw-gateway-main 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"timeout"* ]]
  if [[ "$output" == *"CRASH-LOOPING"* ]]; then
    echo "slow bind must not be reported as a crash loop" >&2
    return 1
  fi
}

@test "pre-existing non-zero NRestarts with no NEW restarts -> baseline respected, CONTINUES" {
  declare_agents main 9
  stub_openclaw up 9
  # The unit had already restarted 5 times before THIS deploy touched it
  # (baseline=5); current is still 5 -> no restart happened since our own
  # restart, so this must not trip.
  stub_systemctl 5 running
  run warmup_check main openclaw-gateway-main 5
  [ "$status" -eq 0 ]
  if [[ "$output" == *"CRASH-LOOPING"* ]]; then
    echo "a pre-existing NRestarts value must not itself trip the gate" >&2
    return 1
  fi
}

@test "main-freeze shape (#984): active, unresponsive health probe, NRestarts unchanged -> CONTINUES" {
  declare_agents main 9
  stub_openclaw down 9          # frozen main: health probe cannot be reached
  # A frozen main is ACTIVE and holds its post-restart PID: it never crashes
  # and systemd never restarts it, so NRestarts stays at baseline and the
  # substate stays "running" the whole time -- this is the exact shape this
  # gate must never misread as a crash loop.
  stub_systemctl 0 running
  run warmup_check main openclaw-gateway-main 0
  [ "$status" -eq 0 ]
  if [[ "$output" == *"CRASH-LOOPING"* ]]; then
    echo "a frozen-but-active main must not be reported as a crash loop" >&2
    return 1
  fi
}

@test "a crash loop is fatal even when the gateway happens to be bound at check time" {
  # A flapping unit can be transiently up when the poll lands -- the crash
  # loop must still be caught by the restart counter, not masked by a lucky
  # bind.
  declare_agents edge 1
  stub_openclaw up 1
  stub_systemctl 9 running       # baseline 2 -> current 9: crash-looped
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "an empty baseline (no restart performed this deploy) is a no-op, never fatal" {
  declare_agents main 9
  stub_openclaw up 9
  stub_systemctl 99 running       # NRestarts is irrelevant with no baseline
  run check_gateway_not_crashlooping openclaw-gateway-main ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# UNREADABLE_BASELINE — 2026-09-23 QA finding on #1010: a transient
# `systemctl show`/SSH failure right after a restart that DID happen used to
# fold into the same "" a skipped restart passes, making the gate a silent
# no-op on exactly the class of failure it exists to survive. A restart that
# DID happen but whose baseline read never succeeded must be represented by
# the UNREADABLE_BASELINE sentinel, never "", and must still catch a genuine
# crash loop via the state-only (is-failed / auto-restart) signals.
# ---------------------------------------------------------------------------

@test "UNREADABLE_BASELINE + crash-looping unit -> deploy step still FAILS" {
  declare_agents edge 1
  stub_openclaw down 1
  # NRestarts itself is irrelevant here (the baseline was never read), but
  # the unit is stuck in systemd's auto-restart backoff -- the state-only
  # fallback must catch this from is-failed/SubState alone.
  stub_systemctl 2 auto-restart
  stub_journalctl "crash-loop journal line"
  run warmup_check edge openclaw-gateway-edge UNREADABLE_BASELINE
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
  [[ "$output" == *"openclaw-gateway-edge"* ]]
}

@test "UNREADABLE_BASELINE + healthy unit -> continues, no false rollback" {
  declare_agents main 9
  stub_openclaw up 9
  stub_systemctl 2 running       # healthy: not failed, not auto-restarting
  run warmup_check main openclaw-gateway-main UNREADABLE_BASELINE
  [ "$status" -eq 0 ]
  if [[ "$output" == *"CRASH-LOOPING"* ]]; then
    echo "an unreadable baseline on a healthy unit must not be reported as a crash loop" >&2
    return 1
  fi
}

@test "UNREADABLE_BASELINE logs a WARN naming the unit, on both the healthy and crash-looping paths" {
  declare_agents main 9
  stub_openclaw up 9
  stub_systemctl 2 running
  run check_gateway_not_crashlooping openclaw-gateway-main UNREADABLE_BASELINE
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"openclaw-gateway-main"* ]]
  [[ "$output" == *"unreadable"* ]]
}

@test "restart skipped (empty baseline) never invokes the crash-loop state checks at all" {
  # Distinct from the UNREADABLE_BASELINE tests above: an empty baseline
  # means THIS deploy never restarted the unit, so the gate must be a pure
  # no-op -- not merely "concludes healthy", but never touches systemctl at
  # all. A systemctl stub that would fail any call (nrestarts_rc=1, plus a
  # crash-looking substate) proves the no-op path short-circuits before
  # reading state, not that it happens to read a healthy one.
  declare_agents main 9
  stub_openclaw up 9
  stub_systemctl 99 auto-restart 0 1
  run check_gateway_not_crashlooping openclaw-gateway-main ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# gateway_nrestarts_retry — the retry primitive itself, sourced from the
# real lib (scripts/lib/gateway-restart.sh).
# ---------------------------------------------------------------------------

@test "gateway_nrestarts_retry succeeds once the read stops failing, within the bounded tries" {
  # nrestarts_rc=1 makes every `show -p NRestarts --value` call fail; a real
  # transient hiccup clears on its own within a couple of attempts, so this
  # models that by having the retry loop itself observe success -- the stub
  # cannot flip mid-run, so instead this pins the OTHER half: with
  # nrestarts_rc=0 (healthy), a single attempt succeeds without needing to
  # exhaust GATEWAY_NRESTARTS_RETRY_TRIES.
  stub_systemctl 4 running 1 0
  run gateway_nrestarts_retry openclaw-gateway-main
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "gateway_nrestarts_retry gives up after every attempt fails, rc 1, nothing echoed" {
  export GATEWAY_NRESTARTS_RETRY_TRIES=3
  stub_systemctl 4 running 1 1     # every NRestarts read fails
  run gateway_nrestarts_retry openclaw-gateway-main
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "flapping unit: a crash loop is still caught when the FIRST SubState sample lands on running" {
  # A single snapshot has roughly a coin-flip chance of landing during the
  # brief `running` window between two crashes (live-measured on node-8: a
  # crash-looping unit was caught reading SubState=running mid-loop). This
  # pins gateway_crash_looping's multi-sample fix: the first of
  # GATEWAY_CRASHLOOP_STATE_SAMPLES (default 3) reads land on "running", the
  # unit is genuinely crash-looping, and a later sample must still catch it.
  declare_agents edge 1
  stub_openclaw up 1
  stub_systemctl 2 "running,running,auto-restart"
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "flapping unit: never landing on a bad SubState within the sampled window CONTINUES" {
  # The inverse of the above: if every sample lands on "running" (and
  # NRestarts never moved), this must NOT fail -- the sampling window is
  # bounded, not infinite, so a unit that is genuinely healthy for the whole
  # window must read as healthy.
  declare_agents edge 1
  stub_openclaw up 1
  stub_systemctl 2 "running,running,running"
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -eq 0 ]
  if [[ "$output" == *"CRASH-LOOPING"* ]]; then
    echo "a unit reading healthy on every sample must not be reported as a crash loop" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 2026-09-22 incident shape, exactly: edge was ALREADY crash-looping when
# Step 6 restarted it (pre-restart NRestarts=16). A baseline captured BEFORE
# the restart (the first-pass design) reads 16, the restart's `systemctl
# restart` resets the REAL counter to 0, and 30s later current is ~1-2 --
# `current(1-2) > old_baseline(16)` is FALSE, so the gate never fires. This
# is exactly why the fix moves baseline capture to AFTER the restart, using
# the real restart machinery (hard_restart_gateway) rather than a canned
# baseline argument, so the reset-on-restart behaviour is actually exercised.
# ---------------------------------------------------------------------------

@test "2026-09-22 incident shape: already crash-looping pre-restart, hard-restarted, keeps crashing -> FAILS" {
  # Reproduces the incident's full failure combination, not just one half of
  # it: (a) the baseline is captured the OLD (wrong) way -- BEFORE
  # hard_restart_gateway runs, exactly like deploy.sh's first-pass Step 6
  # Phase A -- so it reads the PRE-restart value (16); `systemctl restart`
  # (fired by hard_restart_gateway below) resets the REAL counter to 0, so
  # `current(0) > old_baseline(16)` is false and the NRestarts comparison
  # alone can never catch this, by construction, regardless of which version
  # of the library code runs. (b) the SubState fallback's FIRST sample lands
  # on "running" -- live-measured on node-8 as a real, reachable state
  # between two crashes -- so a single-snapshot read (the pre-fix library
  # code) also misses it. Only sampling multiple times (the fix) reaches the
  # later "auto-restart" sample and catches the loop.
  declare_agents edge 1
  stub_openclaw down 1   # keeps crashing after the restart too
  export GATEWAY_HARD_POLL_TRIES=1
  export GATEWAY_HARD_POLL_SECS=0
  stub_systemctl 16 "running,auto-restart,auto-restart"
  old_baseline="$(gateway_nrestarts openclaw-gateway-edge)"   # OLD ordering: captured BEFORE the restart
  [ "$old_baseline" = "16" ]
  hard_restart_gateway openclaw-gateway-edge                 # systemd resets the real counter to 0
  run warmup_check edge openclaw-gateway-edge "$old_baseline"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
  [[ "$output" == *"openclaw-gateway-edge"* ]]
}

# ---------------------------------------------------------------------------
# Static ordering guard: deploy.sh's *_baseline_nrestarts capture must happen
# AFTER the restart it's baselining, never before. This can't be pinned by
# calling the extracted functions in isolation (every test above supplies its
# own baseline argument directly, bypassing deploy.sh's own capture-timing
# entirely) -- the ordering lives in inline Step 6 / cron_store_heal_start
# script body, not inside a function bats can call and assert on the return
# of. A source-line-order check is the only thing that would have caught the
# first-pass regression (baseline captured before finish_gateway_restart /
# hard_restart_gateway) before it shipped.
# ---------------------------------------------------------------------------

@test "deploy.sh: main's baseline capture line comes AFTER its finish_gateway_restart call" {
  local restart_line baseline_line
  restart_line="$(grep -n 'finish_gateway_restart "openclaw-gateway-main"' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  baseline_line="$(grep -n 'main_baseline_nrestarts=\$(gateway_nrestarts_retry "openclaw-gateway-main")' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$restart_line" ]
  [ -n "$baseline_line" ]
  if [ "$baseline_line" -le "$restart_line" ]; then
    echo "main's baseline capture (line $baseline_line) is not after its restart call (line $restart_line) -- this is the exact 2026-09-22 regression shape" >&2
    return 1
  fi
}

@test "deploy.sh: edge's baseline capture line comes AFTER its finish_gateway_restart call" {
  local restart_line baseline_line
  restart_line="$(grep -n 'finish_gateway_restart "openclaw-gateway-edge"' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  baseline_line="$(grep -n 'edge_baseline_nrestarts=\$(gateway_nrestarts_retry "openclaw-gateway-edge")' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$restart_line" ]
  [ -n "$baseline_line" ]
  if [ "$baseline_line" -le "$restart_line" ]; then
    echo "edge's baseline capture (line $baseline_line) is not after its restart call (line $restart_line) -- this is the exact 2026-09-22 regression shape" >&2
    return 1
  fi
}

@test "deploy.sh: cron_store_heal_start's baseline capture line comes AFTER its hard_restart_gateway call" {
  local restart_line baseline_line
  restart_line="$(grep -n 'hard_restart_gateway "\$svc" || return 1' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  baseline_line="$(grep -n 'baseline=\$(gateway_nrestarts_retry "\$svc") || baseline="UNREADABLE_BASELINE"' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$restart_line" ]
  [ -n "$baseline_line" ]
  if [ "$baseline_line" -le "$restart_line" ]; then
    echo "cron_store_heal_start's baseline capture (line $baseline_line) is not after its restart call (line $restart_line) -- this is the exact 2026-09-22 regression shape" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Production WIRING (QA on #1010): the behavioural tests above drive
# check_gateway_not_crashlooping through a test-only wrapper, so on their own
# they stay green if deploy.sh stops CALLING the gate. Verified before these
# were added: deleting the real call at each of the three sites left all 28
# tests green. These read deploy.sh itself. A call that is deleted, commented
# out (`#` or `:`), moved before its wait, or handed the wrong baseline fails.
# ---------------------------------------------------------------------------

# _live_line <regex>: line number of the first UNCOMMENTED line matching regex.
_live_line() {
  grep -nE "^[[:space:]]*$1" "$DEPLOY_SH" | head -1 | cut -d: -f1
}

@test "deploy.sh wiring: main's crash-loop gate runs right after main's bind wait, with main's baseline" {
  local wait_line gate_line
  wait_line="$(_live_line 'wait_for_agents_bound "main" 30')"
  gate_line="$(_live_line 'check_gateway_not_crashlooping "openclaw-gateway-main" "\$\{main_baseline_nrestarts')"
  if [ -z "$gate_line" ]; then
    echo "no live check_gateway_not_crashlooping call for main (deleted or commented out)" >&2
    return 1
  fi
  [ -n "$wait_line" ]
  if [ "$gate_line" -ne $(( wait_line + 1 )) ]; then
    echo "main's gate (line $gate_line) is not the line right after its bind wait (line $wait_line)" >&2
    return 1
  fi
}

@test "deploy.sh wiring: edge's crash-loop gate runs right after edge's bind wait, with edge's baseline" {
  local wait_line gate_line
  wait_line="$(_live_line 'wait_for_agents_bound "edge" 30')"
  gate_line="$(_live_line 'check_gateway_not_crashlooping "openclaw-gateway-edge" "\$\{edge_baseline_nrestarts')"
  if [ -z "$gate_line" ]; then
    echo "no live check_gateway_not_crashlooping call for edge (deleted or commented out)" >&2
    return 1
  fi
  [ -n "$wait_line" ]
  if [ "$gate_line" -ne $(( wait_line + 1 )) ]; then
    echo "edge's gate (line $gate_line) is not the line right after its bind wait (line $wait_line)" >&2
    return 1
  fi
}

@test "deploy.sh wiring: cron_store_heal_start runs restart -> baseline -> bind wait -> crash-loop gate, in that order" {
  local body restart baseline wait gate
  # The function body only, so a same-named call elsewhere can't satisfy this.
  body="$(sed -n '/^[[:space:]]*cron_store_heal_start() {/,/^[[:space:]]*}$/p' "$DEPLOY_SH")"
  [ -n "$body" ]
  restart="$(grep -nE '^[[:space:]]*hard_restart_gateway "\$svc"' <<<"$body" | head -1 | cut -d: -f1)"
  baseline="$(grep -nE '^[[:space:]]*baseline=\$\(gateway_nrestarts_retry "\$svc"\)' <<<"$body" | head -1 | cut -d: -f1)"
  wait="$(grep -nE '^[[:space:]]*wait_for_agents_bound "\$profile"' <<<"$body" | head -1 | cut -d: -f1)"
  gate="$(grep -nE '^[[:space:]]*check_gateway_not_crashlooping "\$svc" "\$baseline"' <<<"$body" | head -1 | cut -d: -f1)"
  if [ -z "$gate" ]; then
    echo "cron_store_heal_start has no live crash-loop gate call handed \$baseline" >&2
    return 1
  fi
  # Separate lines on purpose: `set -e` ignores a failure inside an && list
  # unless it is the LAST command, the same trap as a bare `! cmd`.
  [ -n "$restart" ]
  [ -n "$baseline" ]
  [ -n "$wait" ]
  if ! { [ "$restart" -lt "$baseline" ] && [ "$baseline" -lt "$wait" ] && [ "$wait" -lt "$gate" ]; }; then
    echo "cron_store_heal_start order is restart=$restart baseline=$baseline wait=$wait gate=$gate; expected strictly increasing" >&2
    return 1
  fi
}

# QA on #1010: an invalid sample count used to mean ZERO samples -- `seq 1 0`
# (or a non-number) never runs the loop, which then falls through to "not
# crash-looping". Each case below holds NRestarts UNCHANGED so only the state
# sampling can catch the loop, which is exactly what the bad count disabled.
@test "an invalid GATEWAY_CRASHLOOP_STATE_SAMPLES=0 still samples: stuck auto-restart FAILS" {
  declare_agents edge 1
  stub_openclaw down 1
  stub_systemctl 2 auto-restart
  stub_journalctl "crash-loop journal line"
  GATEWAY_CRASHLOOP_STATE_SAMPLES=0 run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "a non-numeric GATEWAY_CRASHLOOP_STATE_SAMPLES still samples: stuck auto-restart FAILS" {
  declare_agents edge 1
  stub_openclaw down 1
  stub_systemctl 2 auto-restart
  stub_journalctl "crash-loop journal line"
  GATEWAY_CRASHLOOP_STATE_SAMPLES=abc run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "the journal tail (newlines, quotes) goes to the log, never into the fail() message" {
  # fail() forwards its text to notify_slack, which interpolates it raw into a
  # JSON body; a multi-line, quote-bearing tail there makes the payload invalid.
  declare_agents edge 1
  stub_openclaw down 1
  stub_systemctl 2 auto-restart
  stub_journalctl $'first "quoted" line\nsecond line with a "quote"'
  run warmup_check edge openclaw-gateway-edge 2
  [ "$status" -ne 0 ]
  local fatal
  fatal="$(grep -F 'FATAL:' <<<"$output")"
  [ -n "$fatal" ]
  # exactly one FATAL line, and it carries none of the journal text
  [ "$(grep -cF 'FATAL:' <<<"$output")" -eq 1 ]
  if grep -qF 'quoted' <<<"$fatal"; then
    echo "journal text leaked into the fail() message: $fatal" >&2
    return 1
  fi
  if grep -qF '"' <<<"$fatal"; then
    echo "a double quote reached the fail() message: $fatal" >&2
    return 1
  fi
  # ...while the full tail is still in the log
  [[ "$output" == *'| first "quoted" line'* ]]
  [[ "$output" == *'| second line with a "quote"'* ]]
}

# QA on #1010 (third finding of this shape): GATEWAY_NRESTARTS_RETRY_TRIES was
# fed straight to `seq`. At 0 or a non-number the post-restart baseline read
# never ran, every call site fell to UNREADABLE_BASELINE, and the weaker
# state-only fallback took over. A unit whose counter IS climbing, but whose
# every SubState sample lands on a brief `running` window, was then accepted.
# These use the production capture line verbatim, then simulate the crashes.
_capture_then_crash_then_check() {
  local baseline
  baseline=$(gateway_nrestarts_retry "openclaw-gateway-edge") || baseline="UNREADABLE_BASELINE"
  echo 3 > "$TEST_TMPDIR/nrestarts"   # the unit crash-restarted 3 times since
  check_gateway_not_crashlooping "openclaw-gateway-edge" "$baseline"
}

@test "an invalid GATEWAY_NRESTARTS_RETRY_TRIES=0 still reads the baseline: a climbing counter FAILS even while state looks healthy" {
  stub_systemctl 0 "running,running,running,running"
  stub_journalctl "crash-loop journal line"
  GATEWAY_NRESTARTS_RETRY_TRIES=0 GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS=0 run _capture_then_crash_then_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
  [[ "$output" == *"invalid GATEWAY_NRESTARTS_RETRY_TRIES='0'"* ]]
}

@test "a non-numeric GATEWAY_NRESTARTS_RETRY_TRIES still reads the baseline: a climbing counter FAILS even while state looks healthy" {
  stub_systemctl 0 "running,running,running,running"
  stub_journalctl "crash-loop journal line"
  GATEWAY_NRESTARTS_RETRY_TRIES=abc GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS=0 run _capture_then_crash_then_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"CRASH-LOOPING"* ]]
}

@test "a valid retry count with a healthy, unchanged unit still continues (no false rollback)" {
  stub_systemctl 0 "running,running,running,running"
  _healthy() {
    local baseline
    baseline=$(gateway_nrestarts_retry "openclaw-gateway-edge") || baseline="UNREADABLE_BASELINE"
    check_gateway_not_crashlooping "openclaw-gateway-edge" "$baseline"
  }
  GATEWAY_CRASHLOOP_STATE_INTERVAL_SECS=0 run _healthy
  [ "$status" -eq 0 ]
}


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

  # Extract the function, then PROVE the extraction worked. A silently empty
  # extraction would make every assertion below vacuous — the failure mode a
  # gate must never have.
  awk '/^wait_for_agents_bound\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/fn.sh"
  [ -s "$TEST_TMPDIR/fn.sh" ] || { echo "extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q 'wait_for_agents_bound() {' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the opening line" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }

  # deploy.sh supplies these around the function; the tests supply them here.
  log() { printf '%s\n' "$*"; }
  export DEPLOY_PATH="$TEST_TMPDIR/deploy"
  mkdir -p "$DEPLOY_PATH"

  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH
  # MIRROR deploy.sh's shell options (`set -euo pipefail`, line 2). pipefail is
  # load-bearing here: without it a failing `openclaw` inside the probe's
  # pipeline reads as success, and the "0\n0" double-zero bug that shipped in
  # this suite's first version stays invisible. A stub environment laxer than
  # production makes broken code look tested.
  set -o pipefail
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/fn.sh"
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

#!/usr/bin/env bats
# The agent exec posture must be enforced by the DEPLOY, not only by PR CI.
#
# guardrails-1101 gap 2 / H1 (PR #1627) shipped scripts/check-agent-exec-policy.py with a `--live` mode documented
# "post-deploy", but nothing ever called it: the only call site was pr-validate.yml, which reads the REPO copy at
# review time. A hot edit on node-8, a partial rsync, or a hand-reverted live file could therefore drop scout's
# deny and deploy CLEAN, silently restoring a root shell for an agent that reads untrusted text. These tests run the
# two real deploy.sh blocks extracted from the script (same extraction pattern as assert-support-deny.bats):
#
#   Step 1     pre-sync  - the REPO tree being deployed must satisfy the registry (no --live: see below)
#   Step 4d.5b post-sync - node-8's LIVE configs must equal the repo's posture, before the Step 6 restart
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  ROOT="$TEST_TMPDIR/repo"
  mkdir -p "$ROOT/scripts" "$ROOT/policies" "$TEST_TMPDIR/bin"
  cp "$HYDRA_REPO/scripts/check-agent-exec-policy.py" "$ROOT/scripts/"
  cp "$HYDRA_REPO/policies/agent-exec-policy.json" "$ROOT/policies/"
  cp "$HYDRA_REPO/openclaw-main.json" "$HYDRA_REPO/openclaw-edge.json" "$ROOT/"

  # Step 1's `needs_target "main"` block, verbatim from deploy.sh.
  awk '/^log "Step 1\/8: Validating config files\.\.\."$/{s=1} s && /^if needs_target "main"; then$/{p=1} p{print} p && /^fi$/{exit}' \
    "$DEPLOY_SH" > "$TEST_TMPDIR/step1-main.sh"
  # Step 4d.5b, verbatim: from the argv build to the closing fi.
  awk '/^_exec_live_args=\(\)$/{p=1} p{print} p && /^fi$/{exit}' \
    "$DEPLOY_SH" > "$TEST_TMPDIR/step4d5b.sh"

  # Stub ONLY the `--live` invocation so the live-gate tests assert the ARGV the deploy passes without reading
  # /root/.openclaw-*, while Step 1 still runs the REAL script against the copied configs (a blanket stub would
  # make the Step-1 tests pass vacuously).
  export REAL_PYTHON3; REAL_PYTHON3="$(command -v python3)"
  export STUB_CALLS="$TEST_TMPDIR/python-calls"
  : > "$STUB_CALLS"
  cat > "$TEST_TMPDIR/bin/python3" <<'STUB'
#!/bin/bash
if [[ " $* " == *" --live "* ]]; then
  printf '%s\n' "$*" >> "$STUB_CALLS"
  exit "${STUB_PY_RC:-0}"
fi
exec "$REAL_PYTHON3" "$@"
STUB
  chmod +x "$TEST_TMPDIR/bin/python3"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

drop() {  # drop one deny entry from the copied main config (scout's deny is the H1 surface)
  python3 - "$ROOT/openclaw-main.json" "$1" <<'PY'
import json, sys
p, name = sys.argv[1], sys.argv[2]
c = json.load(open(p))
for a in c["agents"]["list"]:
    if a["id"] == "scout":
        a["tools"]["deny"] = [t for t in a["tools"]["deny"] if t != name]
json.dump(c, open(p, "w"))
PY
}

shims='needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }; log() { echo "$*"; }; fail() { echo "FAIL: $*"; exit 1; }'

run_step1() {
  bash -c "set -euo pipefail; TARGET=\"\$1\"; SCRIPT_DIR=\"\$2/scripts\"; HYDRA_ROOT=\"\$2\"; $shims
    source \"\$3\"; echo STEP1-MAIN-OK" _ "$1" "$ROOT" "$TEST_TMPDIR/step1-main.sh"
}

run_live_gate() {
  bash -c "set -euo pipefail; TARGET=\"\$1\"; SCRIPT_DIR=\"\$2/scripts\"; $shims
    source \"\$3\"; echo LIVE-GATE-OK" _ "$1" "$ROOT" "$TEST_TMPDIR/step4d5b.sh"
}

# ------------------------------------------------------------------ wiring (the regression this file exists for)

@test "deploy.sh still runs the exec-posture check in BOTH places" {
  grep -q 'check-agent-exec-policy.py' "$TEST_TMPDIR/step1-main.sh" \
    || { echo "deploy.sh Step 1 no longer runs check-agent-exec-policy.py (pre-sync repo gate gone)" >&2; return 1; }
  grep -q 'check-agent-exec-policy.py.*--live' "$TEST_TMPDIR/step4d5b.sh" \
    || { echo "deploy.sh Step 4d.5b no longer runs check-agent-exec-policy.py --live (post-sync live gate gone)" >&2; return 1; }
}

@test "the pre-sync gate must NOT pass --live (it would deadlock every PR that legitimately changes a posture)" {
  # Before the sync the live file is still the PREVIOUS posture by definition, so a pre-sync --live compare fails on
  # exactly the deploys that are supposed to fix something — including the one that added scout's deny.
  ! grep -q -- '--live' "$TEST_TMPDIR/step1-main.sh"
}

@test "the post-sync gate runs before the Step 6 restart (a failure must not reload the gateway)" {
  local gate restart
  gate="$(grep -n 'Step 4d.5b' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  restart="$(grep -n 'Step 6/8: Restarting OpenClaw Gateway' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
  [ -n "$gate" ] && [ -n "$restart" ] && [ "$gate" -lt "$restart" ]
}

# ------------------------------------------------------------------ Step 1 (repo, pre-sync)

@test "Step 1: the shipped configs pass" {
  run run_step1 main
  [ "$status" -eq 0 ]
  [[ "$output" == *"STEP1-MAIN-OK"* ]]
  [[ "$output" == *"Agent exec posture: repo configs match"* ]]
}

@test "Step 1: dropping scout's exec deny stops the deploy and names it" {
  drop exec
  run run_step1 main
  [ "$status" -ne 0 ]
  [[ "$output" == *"scout: posture=denied but tools.deny lacks ['exec']"* ]]
  [[ "$output" == *"FAIL: agent exec posture"* ]]
  [[ "$output" != *"STEP1-MAIN-OK"* ]]
}

@test "Step 1: an unreadable repo config stops the deploy (exit 2 is never a pass)" {
  echo '{not json' > "$ROOT/openclaw-main.json"
  run run_step1 main
  [ "$status" -eq 1 ]   # 4d.5b does not run; the JSON check above already failed… or the posture check did
  grep -q 'not valid JSON' <<< "$output"
}

@test "Step 1 --target edge: the main gate does not run" {
  drop exec
  run run_step1 edge
  [ "$status" -eq 0 ]
  [[ "$output" != *"Agent exec posture"* ]]
}

# ------------------------------------------------------------------ Step 4d.5b (live, post-sync)

@test "Step 4d.5b --target main: compares just the main profile" {
  run run_live_gate main
  [ "$status" -eq 0 ]
  [[ "$output" == *"LIVE-GATE-OK"* ]]
  grep -q -- '--live --live-profile main$' "$STUB_CALLS"
  ! grep -q -- '--live-profile edge' "$STUB_CALLS"
}

@test "Step 4d.5b --target edge: compares just the edge profile" {
  run run_live_gate edge
  [ "$status" -eq 0 ]
  grep -q -- '--live --live-profile edge$' "$STUB_CALLS"
  ! grep -q -- '--live-profile main' "$STUB_CALLS"
}

@test "Step 4d.5b --target all: compares both profiles" {
  run run_live_gate all
  [ "$status" -eq 0 ]
  grep -q -- '--live-profile main' "$STUB_CALLS"
  grep -q -- '--live-profile edge' "$STUB_CALLS"
}

@test "Step 4d.5b: a live posture mismatch fails the deploy before the restart" {
  STUB_PY_RC=1 run run_live_gate main
  [ "$status" -ne 0 ]
  [[ "$output" == *"node-8's LIVE configs do not match"* ]]
  [[ "$output" != *"LIVE-GATE-OK"* ]]
}

@test "Step 4d.5b: an unreadable live config (exit 2) also fails the deploy" {
  STUB_PY_RC=2 run run_live_gate all
  [ "$status" -ne 0 ]
  [[ "$output" != *"LIVE-GATE-OK"* ]]
}

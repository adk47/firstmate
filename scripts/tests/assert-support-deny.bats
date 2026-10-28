#!/usr/bin/env bats
# Caroline's deny list (captain 2026-10-28 12:1xZ / 12:3xZ) must survive EVERY deploy that targets edge.
# QA on #1464: validate-shared-config.sh runs only for `all` / multi-profile deploys, so the check also
# lives in deploy.sh Step 1 under `needs_target "edge"`. These tests run the real lib and the real
# Step-1 edge block extracted from deploy.sh (same extraction pattern as deploy-caddy-bind-gate.bats).
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"
LIB="$HYDRA_REPO/scripts/lib/assert-support-deny.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  ROOT="$TEST_TMPDIR/repo"; mkdir -p "$ROOT/scripts/lib"
  cp "$LIB" "$ROOT/scripts/lib/"
  cp "$HYDRA_REPO/openclaw-edge.json" "$ROOT/openclaw-edge.json"
  # The Step-1 edge validation block, verbatim from deploy.sh.
  awk '/^log "Step 1\/8: Validating config files\.\.\."$/{s=1} s && /^if needs_target "edge"; then$/{p=1} p{print} p && /^fi$/{exit}' \
    "$DEPLOY_SH" > "$TEST_TMPDIR/step1-edge.sh"
  grep -q 'assert-support-deny.sh' "$TEST_TMPDIR/step1-edge.sh" \
    || { echo "deploy.sh Step 1 edge block no longer runs assert-support-deny.sh" >&2; return 1; }
}

teardown() { rm -rf "$TEST_TMPDIR"; }

drop() {  # drop one deny entry from the copied edge config
  python3 - "$ROOT/openclaw-edge.json" "$1" <<'PY'
import json, sys
p, name = sys.argv[1], sys.argv[2]
c = json.load(open(p))
for a in c["agents"]["list"]:
    if a["id"] == "support":
        a["tools"]["deny"] = [t for t in a["tools"]["deny"] if t != name]
json.dump(c, open(p, "w"))
PY
}

run_step1() {  # run the extracted block as deploy.sh would, for the given --target
  bash -c '
    set -euo pipefail
    TARGET="$1"; SCRIPT_DIR="$2/scripts"; HYDRA_ROOT="$2"
    needs_target() { [[ "$TARGET" == "all" || ",$TARGET," == *",$1,"* ]]; }
    log()  { echo "$*"; }
    fail() { echo "FAIL: $*"; exit 1; }
    source "$3"
    echo "STEP1-EDGE-OK"
  ' _ "$1" "$ROOT" "$TEST_TMPDIR/step1-edge.sh"
}

@test "the repo openclaw-edge.json carries the full 15-entry support deny" {
  run bash "$LIB" "$HYDRA_REPO/openclaw-edge.json"
  [ "$status" -eq 0 ]
}

@test "lib: a missing entry fails and names it" {
  drop dedupe_check
  run bash "$LIB" "$ROOT/openclaw-edge.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dedupe_check"* ]]
}

@test "lib: an unreadable config is exit 2, never a pass" {
  echo '{not json' > "$ROOT/openclaw-edge.json"
  run bash "$LIB" "$ROOT/openclaw-edge.json"
  [ "$status" -eq 2 ]
}

@test "deploy.sh --target edge: an incomplete deny list stops Step 1 (the QA #1464 bypass)" {
  drop credits_verify
  run run_step1 edge
  [ "$status" -ne 0 ]
  [[ "$output" == *"support tools.deny is missing ['credits_verify']"* ]]
  [[ "$output" == *"FAIL: openclaw-edge.json: the Caroline support tools.deny is incomplete"* ]]
  [[ "$output" != *"STEP1-EDGE-OK"* ]]
}

@test "deploy.sh --target all: an incomplete deny list stops Step 1 too" {
  drop proof_on_file
  run run_step1 all
  [ "$status" -ne 0 ]
  [[ "$output" == *"proof_on_file"* ]]
}

@test "deploy.sh --target edge: the complete list passes Step 1" {
  run run_step1 edge
  [ "$status" -eq 0 ]
  [[ "$output" == *"STEP1-EDGE-OK"* ]]
}

@test "deploy.sh --target main: the edge check does not run (edge config untouched)" {
  drop credits_verify
  run run_step1 main
  [ "$status" -eq 0 ]
  [[ "$output" != *"support tools.deny"* ]]
}

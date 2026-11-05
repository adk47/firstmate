#!/usr/bin/env bats
# Tests for check-ops-intake-policy.sh: the CI guard over
# policies/ops-requesters.json + policies/ops-intake-actions.json.
#
# The mutations are the point: each one is a plausible "just this once" edit that
# would turn the ops-intake router's guardrail into decoration while every other
# test still passes - a W2 action blessed for a person, a class pointed at an
# irreversible write, a W1 write with no inverse, a cap set to zero.
#
# Hermetic: every case runs the guard against temp COPIES through
# OPS_INTAKE_REQUESTERS / OPS_INTAKE_ACTIONS / OPENCLAW_MAIN_CONFIG.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-ops-intake-policy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  cp "$HYDRA_REPO/policies/ops-requesters.json" "$TEST_TMPDIR/requesters.json"
  cp "$HYDRA_REPO/policies/ops-intake-actions.json" "$TEST_TMPDIR/actions.json"
  cp "$HYDRA_REPO/openclaw-main.json" "$TEST_TMPDIR/openclaw-main.json"
  export OPS_INTAKE_REQUESTERS="$TEST_TMPDIR/requesters.json"
  export OPS_INTAKE_ACTIONS="$TEST_TMPDIR/actions.json"
  export OPENCLAW_MAIN_CONFIG="$TEST_TMPDIR/openclaw-main.json"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

jq_edit() { jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

@test "passes on the real repo files" {
  unset OPS_INTAKE_REQUESTERS OPS_INTAKE_ACTIONS OPENCLAW_MAIN_CONFIG
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "the shipped policy grants W2 to nobody" {
  run jq -r '.tiers.W2.requesters | length' "$HYDRA_REPO/policies/ops-intake-actions.json"
  [ "$output" = "0" ]
}

@test "FAILS when a person is granted a W2 write" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.tiers.W2.requesters = ["U038BM16T7W"]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"W2.requesters is non-empty"* ]]
}

@test "FAILS when a class is pointed at a W2 action" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.classes["gdpr-hide"].write_action = "admin_profile_delete"'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"admin_profile_delete"* ]]
}

@test "FAILS when a W2 action is also listed in the W1 tier" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.tiers.W1.actions.refund = {inverse:"x"}'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"also listed in a read-only or W1 tier"* ]]
}

@test "FAILS when a W1 action loses its inverse" {
  jq_edit "$OPS_INTAKE_ACTIONS" 'del(.tiers.W1.actions.clickup_status_move.inverse)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"declares no inverse"* ]]
}

@test "FAILS when a cap is zeroed (a zero cap is a violation, not unlimited)" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.caps.w1_per_requester_per_hour = 0'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"must be a violation"* ]]
}

@test "FAILS when a non-staff id is given a write tier" {
  jq_edit "$OPS_INTAKE_REQUESTERS" '.requesters.U0RANDOM = {name:"x", tier:"W1", staff:false}'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"non-staff id U0RANDOM"* ]]
}

@test "FAILS when the staff W1 grant is dropped" {
  jq_edit "$OPS_INTAKE_REQUESTERS" '.requesters.U038BM16T7W.tier = "R"'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"U038BM16T7W must carry tier W1"* ]]
}

@test "FAILS when a class disappears from the table" {
  jq_edit "$OPS_INTAKE_ACTIONS" 'del(.classes["proof-review"])'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"class set is"* ]]
}

@test "FAILS when the router is pointed at a channel the account is not bound to" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.channels.C0BBTAVP44X = "#cs_priority"'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not bind it"* ]]
}

@test "FAILS when the plugin entry is disabled" {
  jq_edit "$OPENCLAW_MAIN_CONFIG" '.plugins.entries["ops-intake"].enabled = false'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"enabled is not true"* ]]
}

@test "FAILS when the reply contract loses its promises" {
  jq_edit "$OPS_INTAKE_ACTIONS" '.reply.pending_requires_due_at = false'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pending_requires_due_at"* ]]
}

@test "exit 2 on an unreadable policy file" {
  echo "not json" > "$TEST_TMPDIR/actions.json"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 2 ]
}

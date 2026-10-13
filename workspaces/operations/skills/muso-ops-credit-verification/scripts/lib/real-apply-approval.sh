#!/usr/bin/env bash
# real-apply-approval.sh — is REAL apply approved for the credit-verification
# batch? Sourced by dispatch-cv-batch.sh (entry gate) and apply-verdicts.sh (the
# write boundary, which also covers a direct Lobster invocation that skips the
# dispatcher).
#
# The answer comes from the TRACKED registry policies/credit-approval-automation.json,
# resolved from THIS file's own location. Deliberately there is NO environment
# override: a caller-settable path would let any agent with exec point the gate at
# a JSON file it wrote itself (QA finding on hydra#1138). Tests exercise the gate by
# copying the scripts into a temp tree that carries its own registry.
#
# Approved means automations["credit-verification-batch"] has approved == true
# AND a non-empty approved_by AND approval_ref. Anything else (file missing,
# unreadable, malformed, approved without who/where) is NOT approved: fail closed.

cv_approval_registry_path() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # lib -> scripts -> muso-ops-credit-verification -> skills -> operations -> workspaces -> repo root
  printf '%s\n' "$lib_dir/../../../../../../policies/credit-approval-automation.json"
}

cv_real_apply_approved() {
  local reg
  reg="$(cv_approval_registry_path)"
  jq -e '
    .automations["credit-verification-batch"] as $a
    | ($a.approved == true)
      and (($a.approved_by // "") | tostring | length > 0)
      and (($a.approval_ref // "") | tostring | length > 0)
  ' "$reg" >/dev/null 2>&1
}

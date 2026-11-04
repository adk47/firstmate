#!/usr/bin/env bats
# A profile-merge-only approver (muso-cli#64 merge-approvers.txt) exists ONLY with a recorded
# captain decision in policies/credit-approval-automation.json (firstmate 041, 2026-10-28).
# Proves: the repo source lists exactly the captain-approved decider handle; a listed handle without
# an approved registry row is
# refused in both modes; an approved row admits exactly that handle; scopes never mix with the
# capability list; deploy.sh checks before install, re-checks the installed copy, removes a stale
# copy when the source is absent, and rsyncs the file.
# Hermetic: temp files only; nothing under /etc or /root is read or written.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HELPER="$HYDRA_REPO/scripts/lib/check-merge-approvers.sh"
SRC="$HYDRA_REPO/workspaces/operations/skills/muso-ops-admin/config/merge-approvers.txt"
REG="$HYDRA_REPO/policies/credit-approval-automation.json"
DEPLOY="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TMP="$(mktemp -d)"
  export MERGE_APPROVERS_DEST="$TMP/merge-approvers.txt"
  export CAP_APPROVERS_FILE="$TMP/capability-approvers.txt"
  printf '# empty\n' > "$CAP_APPROVERS_FILE"
}

teardown() {
  rm -rf "$TMP"
}

registry() { # $1 approved(true|false) $2 approved_by $3 approval_ref $4 handle
  jq --argjson a "$1" --arg by "$2" --arg ref "$3" --arg h "$4" \
    '.automations["profile-merge-approver"] |= (.approved = $a | .approved_by = (if $by == "" then null else $by end)
      | .approval_ref = (if $ref == "" then null else $ref end) | .merge_approver = $h)' "$REG" > "$TMP/reg.json"
  export CREDIT_APPROVAL_REGISTRY="$TMP/reg.json"
}

@test "repo: merge-approvers.txt lists fable-decider and nothing else, and passes" {
  run "$HELPER" --check-repo "$SRC"
  [ "$status" -eq 0 ]
  [ "$(grep -vE '^[[:space:]]*(#|$)' "$SRC")" = "fable-decider" ]
}

@test "repo: the registry row is ON, captain-approved, and names the handle" {
  run jq -e '.automations["profile-merge-approver"]
    | .approved == true and .merge_approver == "fable-decider"
      and (.approved_by | length) > 0 and (.approval_ref | length) > 0
      and .scope == "profile-merge-only"' "$REG"
  [ "$status" -eq 0 ]
}

@test "repo: the handle is NOT on the global tier2 approver list (scopes never mix)" {
  local tier2="$HYDRA_REPO/workspaces/operations/skills/muso-ops-admin/config/tier2-approvers.txt"
  [ -r "$tier2" ]
  ! grep -vE '^[[:space:]]*(#|$)' "$tier2" | grep -qxF fable-decider
}

@test "a handle on the GLOBAL approver list next to the source is refused (the scope escape)" {
  # QA #1473 Important: muso-cli#64 mergeScoped() asks "is --confirmed-by a GLOBAL approver?" FIRST.
  # A handle on both lists therefore takes the ordinary global approval path, which requires NO
  # decider admission and lets the handle approve every other approval-tier verb. The checker must
  # reject that overlap - by reading the list, not by trusting a snapshot assertion.
  local cfg="$TMP/cfg"; mkdir -p "$cfg"
  printf 'fable-decider\n' > "$cfg/merge-approvers.txt"
  printf 'someone-else\n' > "$cfg/tier2-approvers.txt"
  registry true Captain "conv|captain-1103-14x|decider-run-1" fable-decider
  run "$HELPER" --check-repo "$cfg/merge-approvers.txt"
  [ "$status" -eq 0 ]                                   # not on the global list -> clean
  # MUTATED list: the same two files, one line added to the global list
  printf 'someone-else\nfable-decider\n' > "$cfg/tier2-approvers.txt"
  run "$HELPER" --check-repo "$cfg/merge-approvers.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"*"GLOBAL approver list"* ]]
  [[ "$output" == *"tier2-approvers.txt"* ]]
}

@test "the INSTALLED copy is checked against approvers.txt, the file muso-cli actually reads" {
  local cfg="$TMP/cfg"; mkdir -p "$cfg"
  printf 'fable-decider\n' > "$cfg/merge-approvers.txt"
  printf 'someone-else\n' > "$cfg/approvers.txt"
  registry true Captain "conv|captain-1103-14x|decider-run-1" fable-decider
  MERGE_APPROVERS_DEST="$cfg/merge-approvers.txt" run "$HELPER" --verify-installed
  [ "$status" -eq 0 ]
  printf 'someone-else\nfable-decider\n' > "$cfg/approvers.txt"
  MERGE_APPROVERS_DEST="$cfg/merge-approvers.txt" run "$HELPER" --verify-installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"*"GLOBAL approver list"* ]]
  [[ "$output" == *"approvers.txt"* ]]
}

@test "GLOBAL_APPROVERS_FILE overrides which global list is consulted" {
  local cfg="$TMP/cfg"; mkdir -p "$cfg"
  printf 'fable-decider\n' > "$cfg/merge-approvers.txt"
  printf 'fable-decider\n' > "$TMP/elsewhere.txt"
  registry true Captain "conv|captain-1103-14x|decider-run-1" fable-decider
  GLOBAL_APPROVERS_FILE="$TMP/elsewhere.txt" run "$HELPER" --check-repo "$cfg/merge-approvers.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"elsewhere.txt"* ]]
}

@test "a listed handle with the row still approved:false is refused" {
  printf 'fable-decider\n' > "$TMP/src.txt"
  registry false "" "" fable-decider
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"*"fable-decider"* ]]
}

@test "approved:true without approved_by or approval_ref is refused" {
  printf 'fable-decider\n' > "$TMP/src.txt"
  registry true "" "captain-1028-213x" fable-decider
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  registry true "captain" "" fable-decider
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
}

@test "an approved row admits exactly its handle, case-insensitively" {
  printf '# c\nFable-Decider  # inline\n' > "$TMP/src.txt"
  registry true "captain" "captain-1028-213x+214x" fable-decider
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 0 ]
  printf 'fable-decider\nsomeone-else\n' > "$TMP/src.txt"
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"someone-else"* ]]
}

@test "a handle also on the capability list is refused (scopes never mix)" {
  printf 'fable-decider\n' > "$TMP/src.txt"
  printf 'fable-decider\n' > "$CAP_APPROVERS_FILE"
  registry true "captain" "captain-1028-213x" fable-decider
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scopes never mix"* ]]
}

@test "a non-handle entry (email, spaces, shell) is refused" {
  registry true "captain" "captain-1028-213x" fable-decider
  for bad in 'aaron@muso.ai' 'two words' '$(id)'; do
    printf '%s\n' "$bad" > "$TMP/src.txt"
    run "$HELPER" --check-repo "$TMP/src.txt"
    [ "$status" -eq 1 ]
  done
}

@test "--verify-installed: missing or empty installed copy is clean; an unregistered one is refused" {
  registry false "" "" fable-decider
  run "$HELPER" --verify-installed
  [ "$status" -eq 0 ]
  printf 'fable-decider\n' > "$MERGE_APPROVERS_DEST"
  run "$HELPER" --verify-installed
  [ "$status" -eq 1 ]
}

@test "usage errors exit 2" {
  run "$HELPER"
  [ "$status" -eq 2 ]
  run "$HELPER" --check-repo "$TMP/nope.txt"
  [ "$status" -eq 2 ]
}

@test "deploy.sh checks the source before install, re-checks the installed copy, and removes a stale copy" {
  check_line=$(grep -n 'check-merge-approvers.sh" --check-repo "$MUSO_OPS_CFG/merge-approvers.txt"' "$DEPLOY" | head -1 | cut -d: -f1)
  install_line=$(grep -n 'install -m 600 "$MUSO_OPS_CFG/merge-approvers.txt"' "$DEPLOY" | head -1 | cut -d: -f1)
  verify_line=$(grep -n 'check-merge-approvers.sh" --verify-installed' "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$check_line" ] && [ -n "$install_line" ] && [ -n "$verify_line" ]
  [ "$check_line" -lt "$install_line" ]
  [ "$install_line" -lt "$verify_line" ]
  grep -q 'rm -f "$MUSO_CFG_DIR/merge-approvers.txt"' "$DEPLOY"
}

@test "deploy.sh rsync ships merge-approvers.txt (the config dir is otherwise excluded)" {
  grep -qF -- "--include='muso-ops-admin/config/merge-approvers.txt'" "$DEPLOY"
}

# ---- deploy.sh behaviour: the merge-list block runs on its own (QA #1473) ------------------
# Extract the block exactly as deploy.sh has it and run it with stub fail/log, a temp config dir
# and NO tier2-approvers.txt / bulk-destructive-exclude.txt: a missing prerequisite must never
# leave a stale merge approver installed.
run_merge_block() { # $1 = DEPLOY_PATH (fake repo root with config + registry)
  local snippet="$TMP/block.sh"
  awk '/^  # Verb-scoped profile-merge approver list/{on=1} /^  # Smoke \(warn-only/{on=0} on' "$DEPLOY" > "$snippet"
  [ -s "$snippet" ]
  mkdir -p "$1/scripts/lib"
  cp "$HELPER" "$1/scripts/lib/check-merge-approvers.sh"
  cat > "$TMP/run.sh" <<EOF
set -uo pipefail
fail() { echo "FAIL: \$*"; exit 1; }
log() { echo "LOG: \$*"; }
DEPLOY_PATH="$1"
MUSO_CFG_DIR="$TMP/cfg"
MUSO_OPS_CFG="$1/workspaces/operations/skills/muso-ops-admin/config"
unset MERGE_APPROVERS_DEST CAP_APPROVERS_FILE CREDIT_APPROVAL_REGISTRY
source "$snippet"
EOF
  run bash "$TMP/run.sh"
}

fake_repo() { # $1 merge-approvers content or "ABSENT"
  R="$TMP/repo"
  mkdir -p "$R/workspaces/operations/skills/muso-ops-admin/config" "$R/policies" "$TMP/cfg"
  cp "$REG" "$R/policies/credit-approval-automation.json"
  printf '# empty\n' > "$R/workspaces/operations/skills/muso-ops-admin/config/capability-approvers.txt"
  [ "$1" = ABSENT ] || printf '%s' "$1" > "$R/workspaces/operations/skills/muso-ops-admin/config/merge-approvers.txt"
  # deliberately NO tier2-approvers.txt / bulk-destructive-exclude.txt
}

@test "deploy block is not nested in the tier2/bulk render (2-space indent, after its fi)" {
  grep -qE '^  if \[ -r "\$MUSO_OPS_CFG/merge-approvers.txt" \]; then$' "$DEPLOY"
  outer_fi=$(awk '/if \[ -r "\$MUSO_OPS_CFG\/tier2-approvers.txt" \]/{on=1} on && /^  fi$/{print NR; exit}' "$DEPLOY")
  block=$(grep -n '^  if \[ -r "\$MUSO_OPS_CFG/merge-approvers.txt" \]' "$DEPLOY" | cut -d: -f1)
  [ -n "$outer_fi" ] && [ -n "$block" ] && [ "$outer_fi" -lt "$block" ]
}

@test "deploy: prerequisites missing + source absent + stale installed approver -> removed" {
  fake_repo ABSENT
  printf 'fable-decider\n' > "$TMP/cfg/merge-approvers.txt"
  run_merge_block "$R"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/cfg/merge-approvers.txt" ]
}

@test "deploy: prerequisites missing + source lists an unregistered handle -> deploy fails AND the stale copy is removed" {
  fake_repo $'fable-decider\nnot-a-registered-approver\n'
  printf 'fable-decider\n' > "$TMP/cfg/merge-approvers.txt"
  run_merge_block "$R"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL:"* ]]
  [ ! -e "$TMP/cfg/merge-approvers.txt" ]
}

@test "deploy: prerequisites missing + empty source -> the empty list is installed" {
  fake_repo $'# empty\n'
  run_merge_block "$R"
  [ "$status" -eq 0 ]
  [ -e "$TMP/cfg/merge-approvers.txt" ]
  if grep -vE '^[[:space:]]*(#|$)' "$TMP/cfg/merge-approvers.txt"; then false; fi
}

@test "main's approved fable-decider CREDIT row (L12) does not make fable-decider a merge approver" {
  # the credit row (L12) approves a credit automation; only a row with merge_approver=<handle> can
  # authorize a merge. Drop this PR's row and the same handle must be refused on the strength of L12.
  jq 'del(.automations["profile-merge-approver"])' "$REG" > "$TMP/credit-only.json"
  run jq -e '.automations["fable-decider"].approved == true and (.automations["fable-decider"].merge_approver == null)' "$TMP/credit-only.json"
  [ "$status" -eq 0 ]
  printf 'fable-decider\n' > "$TMP/src.txt"
  CREDIT_APPROVAL_REGISTRY="$TMP/credit-only.json" run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
}

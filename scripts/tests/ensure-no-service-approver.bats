#!/usr/bin/env bats
# Caroline's approval-tier writes stay shut across deploys (firstmate stop switch 2026-10-27;
# captain order 2026-10-26 23:30Z). The 13:16Z deploy re-installed the service approver
# `caroline-autonomous` that firstmate had removed from node-8 at 09:31Z. These tests prove:
#   - the repo source and the file the deploy renders from it list NO approver;
#   - the edge config keeps credits_verify / profiles_consolidate / profiles_claim_self OFF;
#   - scripts/lib/ensure-no-service-approver.sh refuses an approver in every mode;
#   - deploy.sh checks the source BEFORE installing it, re-checks the installed copy, and
#     strips MUSO_CAPABILITY_APPROVER from edge.env instead of requiring it.
# Hermetic: temp files only; nothing under /etc or /root is read or written.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HELPER="$HYDRA_REPO/scripts/lib/ensure-no-service-approver.sh"
SRC="$HYDRA_REPO/workspaces/operations/skills/muso-ops-admin/config/capability-approvers.txt"
DEPLOY="$HYDRA_REPO/scripts/deploy.sh"
EDGE_CFG="$HYDRA_REPO/openclaw-edge.json"

setup() {
  TMP="$(mktemp -d)"
  export CAP_APPROVERS_DEST="$TMP/capability-approvers.txt"
  export EDGE_ENV_FILE="$TMP/edge.env"
}

teardown() {
  rm -rf "$TMP"
}

# ---- the repo state -----------------------------------------------------------------------

@test "repo: capability-approvers.txt lists no approver" {
  run "$HELPER" --check-repo "$SRC"
  [ "$status" -eq 0 ]
  if grep -vE '^[[:space:]]*(#|$)' "$SRC"; then false; fi
}

@test "repo: no caroline-autonomous entry anywhere in the approver source" {
  if grep -iE '^[[:space:]]*caroline-autonomous[[:space:]]*$' "$SRC"; then false; fi
}

@test "deploy output: the file deploy.sh installs from the repo lists no approver" {
  # deploy.sh renders with `install -m 600 SRC DEST`: a byte copy. Render it the same way.
  install -m 600 "$SRC" "$CAP_APPROVERS_DEST"
  run "$HELPER" --verify-installed
  [ "$status" -eq 0 ]
  [[ "$output" == *"lists no approver"* ]]
}

@test "repo: edge keeps every Caroline approval-tier verb OFF" {
  run jq -r '.plugins.entries["support-tools"].config | [.creditsVerifyEnabled, .profilesConsolidateEnabled, .profilesClaimSelfEnabled] | map(tostring) | join(",")' "$EDGE_CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "false,false,false" ]
}

# ---- --check-repo ---------------------------------------------------------------------------

@test "--check-repo refuses caroline-autonomous" {
  printf '# comment\n\ncaroline-autonomous\n' > "$TMP/src.txt"
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION"* ]]
  [[ "$output" == *"caroline-autonomous"* ]]
}

@test "--check-repo refuses ANY approver entry, not only the known handle" {
  printf '# comment\n  fable-decider  \n' > "$TMP/src.txt"
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fable-decider"* ]]
}

@test "--check-repo accepts a comments-only file" {
  printf '# only comments\n#caroline-autonomous (commented out)\n\n   \n' > "$TMP/src.txt"
  run "$HELPER" --check-repo "$TMP/src.txt"
  [ "$status" -eq 0 ]
}

@test "--check-repo on a missing source exits 2 (never reads as clean)" {
  run "$HELPER" --check-repo "$TMP/nope.txt"
  [ "$status" -eq 2 ]
}

# ---- --verify-installed ---------------------------------------------------------------------

@test "--verify-installed refuses an installed approver" {
  printf 'caroline-autonomous\n' > "$CAP_APPROVERS_DEST"
  run "$HELPER" --verify-installed
  [ "$status" -eq 1 ]
  [[ "$output" == *"caroline-autonomous"* ]]
}

@test "--verify-installed: a missing installed file is no approver (muso-cli fails closed on it)" {
  run "$HELPER" --verify-installed
  [ "$status" -eq 0 ]
}

# ---- --strip-edge-env ----------------------------------------------------------------------

@test "--strip-edge-env removes MUSO_CAPABILITY_APPROVER, keeps every other line, backs up, keeps the mode" {
  printf 'MUSO_ENV=prod\nMUSO_CAPABILITY_APPROVER=caroline-autonomous\nMUSO_REQUESTER=caroline@muso.ai\n' > "$EDGE_ENV_FILE"
  chmod 600 "$EDGE_ENV_FILE"
  run "$HELPER" --strip-edge-env
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed MUSO_CAPABILITY_APPROVER"* ]]
  if grep -q MUSO_CAPABILITY_APPROVER "$EDGE_ENV_FILE"; then false; fi
  grep -qx 'MUSO_ENV=prod' "$EDGE_ENV_FILE"
  grep -qx 'MUSO_REQUESTER=caroline@muso.ai' "$EDGE_ENV_FILE"
  ls "$TMP"/edge.env.bak-no-service-approver-* >/dev/null
  grep -q 'MUSO_CAPABILITY_APPROVER=caroline-autonomous' "$TMP"/edge.env.bak-no-service-approver-*
  mode=$(stat -c '%a' "$EDGE_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$EDGE_ENV_FILE")
  [ "$mode" = "600" ]
}

@test "--strip-edge-env also removes an exported form" {
  printf 'export MUSO_CAPABILITY_APPROVER=caroline-autonomous\nA=1\n' > "$EDGE_ENV_FILE"
  run "$HELPER" --strip-edge-env
  [ "$status" -eq 0 ]
  if grep -q MUSO_CAPABILITY_APPROVER "$EDGE_ENV_FILE"; then false; fi
  grep -qx 'A=1' "$EDGE_ENV_FILE"
}

@test "--strip-edge-env is idempotent: a clean env is left untouched and gets no backup" {
  printf 'MUSO_ENV=prod\n' > "$EDGE_ENV_FILE"
  run "$HELPER" --strip-edge-env
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do"* ]]
  if ls "$TMP"/edge.env.bak-no-service-approver-* 2>/dev/null; then false; fi
}

# ---- --check-host ---------------------------------------------------------------------------

@test "--check-host flags the env variable" {
  printf 'MUSO_CAPABILITY_APPROVER=caroline-autonomous\n' > "$EDGE_ENV_FILE"
  run "$HELPER" --check-host
  [ "$status" -eq 1 ]
  [[ "$output" == *"sets MUSO_CAPABILITY_APPROVER"* ]]
}

@test "--check-host flags an installed approver" {
  printf 'MUSO_ENV=prod\n' > "$EDGE_ENV_FILE"
  printf 'caroline-autonomous\n' > "$CAP_APPROVERS_DEST"
  run "$HELPER" --check-host
  [ "$status" -eq 1 ]
}

@test "--check-host is clean when both surfaces are empty" {
  printf 'MUSO_ENV=prod\n' > "$EDGE_ENV_FILE"
  printf '# none\n' > "$CAP_APPROVERS_DEST"
  run "$HELPER" --check-host
  [ "$status" -eq 0 ]
}

@test "unknown mode exits 2" {
  run "$HELPER" --apply
  [ "$status" -eq 2 ]
}

# ---- deploy.sh wiring -----------------------------------------------------------------------

@test "deploy.sh checks the source BEFORE installing it and re-checks the installed copy after" {
  check=$(grep -n 'ensure-no-service-approver.sh" --check-repo "$MUSO_OPS_CFG/capability-approvers.txt"' "$DEPLOY" | cut -d: -f1)
  inst=$(grep -n 'install -m 600 "$MUSO_OPS_CFG/capability-approvers.txt" "$MUSO_CFG_DIR/capability-approvers.txt"' "$DEPLOY" | cut -d: -f1)
  verify=$(grep -n 'ensure-no-service-approver.sh" --verify-installed' "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$check" ] && [ -n "$inst" ] && [ -n "$verify" ]
  [ "$check" -lt "$inst" ]
  [ "$inst" -lt "$verify" ]
}

@test "deploy.sh: a MISSING source still verifies the installed copy and fails on an approver" {
  # The else branch of the render: a missing source must never leave a stale installed approver.
  block=$(awk '/if \[ -r "\$MUSO_OPS_CFG\/capability-approvers.txt" \]; then/{on=1} on{print} on&&/^    fi$/{exit}' "$DEPLOY")
  else_part=${block#*$'\n    else\n'}
  [ "$else_part" != "$block" ]
  [[ "$else_part" == *'--verify-installed'* ]]
  [[ "$else_part" == *'fail "capability-approvers.txt source missing and the INSTALLED copy lists an approver'* ]]
}

@test "deploy.sh strips MUSO_CAPABILITY_APPROVER from edge.env and no longer requires it" {
  grep -q 'ensure-no-service-approver.sh" --strip-edge-env' "$DEPLOY"
  if grep -q 'edge_missing+=("MUSO_CAPABILITY_APPROVER' "$DEPLOY"; then false; fi
}

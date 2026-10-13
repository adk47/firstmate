#!/usr/bin/env bats
# MUS-1388 (child 3 of MUS-1374): the sanctioned root /scratch/ home and the
# root-level twins of five excludes that were scoped one directory too deep
# (workspaces/*/.openclaw/, *.jpeg, *.csv, intercom/, qa/pr-review*.json).
# Lockstep: every entry must be in deploy.sh RSYNC_EXCLUDES AND in
# .githooks/pre-commit required_excludes (Check 2), or the next edit that
# drops one passes review silently.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY="$HYDRA_REPO/scripts/deploy.sh"
HOOK="$HYDRA_REPO/.githooks/pre-commit"

ENTRIES=(
  "/scratch/" "/.openclaw/" "/intercom/" "/*.csv" "/*.xlsx" "/*.pdf"
  "/*.jpeg" "/*.jpg" "/*.png" "/pr-review*.json"
)

@test "every root-level exclude is in deploy.sh RSYNC_EXCLUDES" {
  local missing=()
  for e in "${ENTRIES[@]}"; do
    grep -qxF "  --exclude='$e'" "$DEPLOY" || missing+=("$e")
  done
  [ "${#missing[@]}" -eq 0 ] || { echo "missing in deploy.sh: ${missing[*]}"; return 1; }
}

@test "every root-level exclude is in pre-commit required_excludes" {
  local missing=() block
  block="$(awk '/^required_excludes=\(/{f=1;next} f&&/^\)/{exit} f' "$HOOK")"
  for e in "${ENTRIES[@]}"; do
    grep -qxF "  \"$e\"" <<<"$block" || missing+=("$e")
  done
  [ "${#missing[@]}" -eq 0 ] || { echo "missing in required_excludes: ${missing[*]}"; return 1; }
}

@test "no tracked file is hidden by the root-level excludes" {
  run bash -c "cd '$HYDRA_REPO' && git ls-files | grep -E '^[^/]+\.(csv|xlsx|pdf|jpe?g|png)\$|^intercom/|^\.openclaw/|^pr-review|^scratch/'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

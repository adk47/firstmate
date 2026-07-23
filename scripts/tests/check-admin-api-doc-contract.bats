#!/usr/bin/env bats
# Tests for check-admin-api-doc-contract.sh: the mechanical backstop that keeps the
# admin-API analytics-sources payload doc on {"link": ...} (PR #696) and blocks the
# dead {"url": ...} field from reappearing in any SKILL.md.
#
# Hermetic: runs the guard against a temp COPY of the repo's skill tree via the
# REPO_ROOT env override, so a test never edits the tracked sources.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-admin-api-doc-contract.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  mkdir -p "$TEST_TMPDIR/skills-all/muso-ops-tracks" "$TEST_TMPDIR/workspaces/operations/skills/other"
  cp "$HYDRA_REPO/skills-all/muso-ops-tracks/SKILL.md" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    || return 1
  export REPO_ROOT="$TEST_TMPDIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "passes on the real (patched) skill tree" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK:"* ]]
}

@test "fails if the dead url field resurfaces in the canonical tracks skill" {
  sed -i.bak 's/{"link":"https/{"url":"https/' "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"url":'* ]]
  [[ "$output" == *"muso-ops-tracks/SKILL.md"* ]]
}

@test "fails if the dead url field appears in a workspace skill doc" {
  printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{"url":"https://youtu.be/x"}'"'" \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails on the spaced form of the dead url field (whitespace tolerance)" {
  printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{ "url": "https://youtu.be/x" }'"'" \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "an unrelated link payload elsewhere cannot satisfy the add-link anchor" {
  # Strip the payload line under the analytics-sources POST but leave another
  # {"link": ...} elsewhere in the file: the bounded anchor must still fail.
  awk '/call POST "\/admin\/track\/<track_id>\/analytics-sources"/{print; getline; next} {print} END{print "unrelated example: '"'"'{\"link\":\"https://example.com\"}'"'"'"}' \
    "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"add-link example"* ]]
}

@test "fails on a multi-line pretty-printed dead url payload" {
  printf '%s\n' '```json' '{' '  "url": "https://youtu.be/x"' '}' '```' \
    > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails on an early match in a large skill doc (no early-close pipe hazard)" {
  { printf '%s\n' 'call POST "/admin/track/x/analytics-sources" '"'"'{"url":"https://youtu.be/x"}'"'"
    yes 'padding line far past any pipe buffer' | head -50000
  } > "$TEST_TMPDIR/workspaces/operations/skills/other/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/skills/other/SKILL.md"* ]]
}

@test "fails if the corrected add-link example is removed from the tracks skill" {
  grep -vF -- '{"link":' "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md" \
    > "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp"
  mv "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md.tmp" "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"add-link example"* ]]
}

@test "exits 2 (script error) when the workspaces directory is missing — never a vacuous pass" {
  rm -rf "$TEST_TMPDIR/workspaces"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Missing directory"* ]]
}

@test "exits 2 (script error) when the tracks skill file is missing" {
  rm -f "$TEST_TMPDIR/skills-all/muso-ops-tracks/SKILL.md"
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

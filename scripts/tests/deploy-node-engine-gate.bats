#!/usr/bin/env bats
# scripts/deploy.sh install_openclaw(): the Node gate must mirror the pinned
# runtime's engines.node bands, not a bare lower bound. openclaw 2026.8.35
# declares ">=22.22.3 <23 || >=24.15.0 <25 || >=25.9.0"; the bare floor waved
# 23.x, 24.0-24.14 and 25.0-25.8 through to `npm install -g`, replacing a
# working runtime with one that cannot boot. hydra deploys on LTS majors
# only, so >=25.9.0 is rejected on purpose. 22.23.1 (node-8 today) must stay
# green: it is the rollback path. Bash-3.2 compatible (no associative arrays).
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
DEPLOY_SH="$HYDRA_REPO/scripts/deploy.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  awk '/^install_openclaw\(\) \{$/,/^\}$/' "$DEPLOY_SH" > "$TEST_TMPDIR/fn.sh"
  [ -s "$TEST_TMPDIR/fn.sh" ] || { echo "extraction produced nothing — did the function move?" >&2; return 1; }
  grep -q '^}$' "$TEST_TMPDIR/fn.sh" || { echo "extraction missing the closing brace" >&2; return 1; }
  # shellcheck source=../lib/version-compare.sh
  source "$HYDRA_REPO/scripts/lib/version-compare.sh"
  # the constants as deploy.sh declares them (defaults, env overrides honoured)
  eval "$(grep -E '^(OPENCLAW_VERSION|OPENCLAW_NODE_FLOOR|OPENCLAW_NODE_24_FLOOR)=' "$DEPLOY_SH")"
  DEPLOY_PATH="$TEST_TMPDIR"; export DEPLOY_PATH
  NODE_VER=""
  NPM_MARKER="$TEST_TMPDIR/npm-ran"
  log() { echo "$*"; }
  node() { [ -n "$NODE_VER" ] && echo "v$NODE_VER"; return 0; }
  openclaw() { echo "OpenClaw 2026.1.1"; }   # older than the pin → proceeds toward npm
  state_user_versions() { printf ''; }
  npm() { : > "$NPM_MARKER"; return 0; }
  # shellcheck source=/dev/null
  source "$TEST_TMPDIR/fn.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

accepts() {
  NODE_VER="$1"
  run install_openclaw
  [ "$status" -eq 0 ]
  [ -e "$NPM_MARKER" ]
}
rejects() {
  NODE_VER="$1"
  run install_openclaw
  [ "$status" -eq 1 ]
  [ ! -e "$NPM_MARKER" ]   # failed BEFORE npm install -g
  [[ "$output" == *"✗ install_openclaw"* ]]
  [[ "$output" == *"22.22.3"* && "$output" == *"24.15.0"* ]]
}

@test "defaults: OPENCLAW_NODE_FLOOR stays 22.22.3 (rollback must pass), 24 band starts at 24.15.0" {
  [ "$OPENCLAW_NODE_FLOOR" = "22.22.3" ]
  [ "$OPENCLAW_NODE_24_FLOOR" = "24.15.0" ]
}
@test "22.22.2 rejected" { rejects 22.22.2; }
@test "22.22.3 accepted (band floor)" { accepts 22.22.3; }
@test "22.23.1 accepted (node-8 today — the rollback guard)" { accepts 22.23.1; }
@test "22.99.0 accepted" { accepts 22.99.0; }
@test "23.5.0 rejected (odd major, in neither band)" { rejects 23.5.0; }
@test "24.0.0 rejected" { rejects 24.0.0; }
@test "24.14.0 rejected (engines needs 24.15.0)" { rejects 24.14.0; }
@test "24.15.0 accepted (24 band floor)" { accepts 24.15.0; }
@test "24.16.0 accepted (the step-3 target)" { accepts 24.16.0; }
@test "24.99.0 accepted" { accepts 24.99.0; }
@test "25.9.0 rejected (engines allow it; hydra deploys on LTS majors only)" {
  rejects 25.9.0
  [[ "$output" == *"LTS"* ]]
}
@test "26.1.0 rejected" { rejects 26.1.0; }
@test "node missing / empty output rejected" {
  NODE_VER=""
  run install_openclaw
  [ "$status" -eq 1 ]
  [ ! -e "$NPM_MARKER" ]
  [[ "$output" == *"node not found"* ]]
}

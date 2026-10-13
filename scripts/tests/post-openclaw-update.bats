#!/usr/bin/env bats
# Tests for scripts/post-openclaw-update.sh — the post-`npm install -g openclaw`
# dist re-patcher. It must apply the inactive-session-delete patch ONLY on a
# runtime positively identified as pre-2026.8: on 2.0 the patch is retired, and
# an UNKNOWN runtime (empty/unparseable `openclaw --version`) must be a refusal,
# never a fall-through into the patch (QA finding, PR #899). PATH-shadows
# openclaw (feedback_bats_must_stub_openclaw) and the patch script itself.
bats_require_minimum_version 1.5.0
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/repo/scripts/lib"
  cp "$HYDRA_REPO/scripts/post-openclaw-update.sh" "$TEST_TMPDIR/repo/scripts/"
  cp "$HYDRA_REPO/scripts/lib/version-compare.sh" "$TEST_TMPDIR/repo/scripts/lib/"
  # the patch script is replaced by a recorder: it must never run unless called for
  cat > "$TEST_TMPDIR/repo/scripts/patch-openclaw-inactive-session-delete.sh" <<'STUB'
#!/bin/bash
echo "PATCH-INVOKED dist=${OPENCLAW_DIST_DIR:-unset}" >> "$TEST_TMPDIR/patch-calls"
STUB
  chmod +x "$TEST_TMPDIR/repo/scripts/patch-openclaw-inactive-session-delete.sh"
  cat > "$TEST_TMPDIR/repo/scripts/patch-openclaw-a2a-generation-scope.sh" <<'STUB'
#!/bin/bash
echo "A2A-INVOKED dist=${OPENCLAW_DIST_DIR:-unset}" >> "$TEST_TMPDIR/a2a-calls"
exit "${FAKE_A2A_EXIT:-0}"
STUB
  chmod +x "$TEST_TMPDIR/repo/scripts/patch-openclaw-a2a-generation-scope.sh"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then
  [ -n "${FAKE_OPENCLAW_VERSION_LINE+x}" ] && { printf '%s\n' "$FAKE_OPENCLAW_VERSION_LINE"; exit 0; }
  echo "OpenClaw ${FAKE_OPENCLAW_VERSION:-2026.7.1} (test)"; exit 0
fi
echo "test stub: unexpected openclaw call ($*)" >&2; exit 99
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH
  SCRIPT="$TEST_TMPDIR/repo/scripts/post-openclaw-update.sh"
}
teardown() { rm -rf "$TEST_TMPDIR"; }

@test "pre-2026.8 runtime: applies the inactive-session-delete patch" {
  export FAKE_OPENCLAW_VERSION="2026.7.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/patch-calls" ]
  grep -q "PATCH-INVOKED dist=/usr/lib/node_modules/openclaw/dist" "$TEST_TMPDIR/patch-calls"
}

@test "2026.8+ runtime: skips the retired patch, exits 0" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"retired-pending-reevaluation"* ]]
  [ ! -f "$TEST_TMPDIR/patch-calls" ]
}

@test "EMPTY openclaw --version: refuses (exit 1) and never invokes the patch" {
  export FAKE_OPENCLAW_VERSION_LINE=""
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot determine the openclaw runtime version"* ]]
  [ ! -f "$TEST_TMPDIR/patch-calls" ]
}

@test "UNPARSEABLE openclaw --version (garbage): refuses and never invokes the patch" {
  export FAKE_OPENCLAW_VERSION_LINE="OpenClaw banana (broken)"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_TMPDIR/patch-calls" ]
}

@test "a2a generation-scope patch runs on a pre-2026.8 runtime" {
  export FAKE_OPENCLAW_VERSION="2026.7.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "A2A-INVOKED dist=/usr/lib/node_modules/openclaw/dist" "$TEST_TMPDIR/a2a-calls"
}

@test "a2a generation-scope patch runs on 2026.8+ (outside the retired-patch gate)" {
  export FAKE_OPENCLAW_VERSION="2026.8.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/patch-calls" ]
  grep -q "A2A-INVOKED" "$TEST_TMPDIR/a2a-calls"
}

@test "a2a generation-scope patch failure fails the hook" {
  export FAKE_OPENCLAW_VERSION="2026.8.2" FAKE_A2A_EXIT=1
  run "$SCRIPT"
  [ "$status" -ne 0 ]
}

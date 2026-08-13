#!/usr/bin/env bats
# Regression tests for the narrow OpenClaw 2026.7.1 Codex compaction backport.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PATCHER="$HYDRA_REPO/scripts/patch-openclaw-codex-native-compaction.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export OPENCLAW_DIST_DIR="$TEST_TMPDIR/dist"
  mkdir -p "$OPENCLAW_DIST_DIR"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_vulnerable_fixture() {
  cat > "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js" <<'EOF'
if (isIntentionalNativeAutoCompactionSkip(result)) return {
	compacted: false,
	fallbackToContextEngine: true,
	failureReason: CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON
};
EOF
}

@test "patcher backports native-owned auto-compaction without legacy fallback" {
  write_vulnerable_fixture

  run "$PATCHER"
  [ "$status" -eq 0 ]
  run grep -F 'CLI native harness compaction skipped for ${params.provider}/${params.model}' "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"
  [ "$status" -eq 0 ]
  run grep -F "fallbackToContextEngine: true" "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"
  [ "$status" -eq 1 ]
  run node --check "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"
  [ "$status" -eq 0 ]
}

@test "patcher is idempotent after the backport is present" {
  write_vulnerable_fixture
  "$PATCHER"

  run "$PATCHER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already patched"* ]]
}

@test "patcher fails closed when the pinned runtime anchor drifts" {
  printf '%s\n' 'export const unrelated = true;' > "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"

  run "$PATCHER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchor"* ]]
}

@test "patcher rejects a fixed-marker decoy with a surviving vulnerable block" {
  cat > "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js" <<'EOF'
const decoy = 'log.info(`CLI native harness compaction skipped for ${params.provider}/${params.model}: ${CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON}`);';
if (isIntentionalNativeAutoCompactionSkip(result)) return {
	compacted: false,
	fallbackToContextEngine: true,
	failureReason: CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON
};
EOF

  run "$PATCHER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchor"* ]]
  grep -Fq 'fallbackToContextEngine: true' "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"
}

@test "syntax failure removes the temporary patch file" {
  write_vulnerable_fixture
  printf '%s\n' 'const invalid = ;' >> "$OPENCLAW_DIST_DIR/cli-compaction-fixture.js"

  run "$PATCHER"
  [ "$status" -ne 0 ]
  [ "$(find "$OPENCLAW_DIST_DIR" -maxdepth 1 -type f | wc -l)" -eq 1 ]

  run "$PATCHER"
  [ "$status" -ne 0 ]
  [[ "$output" != *"found 2"* ]]
}

@test "deploy reapplies the runtime backport after every OpenClaw install check" {
  install_line="$(grep -n '^if ! install_openclaw; then$' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"
  patch_line="$(grep -n -F 'bash "$HYDRA_ROOT/scripts/patch-openclaw-codex-native-compaction.sh"; then' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"

  [ -n "$install_line" ]
  [ -n "$patch_line" ]
  [ "$patch_line" -gt "$install_line" ]
  grep -Fq 'OPENCLAW_DIST_DIR=/usr/lib/node_modules/openclaw/dist' "$HYDRA_REPO/scripts/deploy.sh"
  grep -Fq 'fail "Codex-native automatic compaction backport failed"' "$HYDRA_REPO/scripts/deploy.sh"
}

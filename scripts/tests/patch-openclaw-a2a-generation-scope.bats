#!/usr/bin/env bats
# Tests for scripts/patch-openclaw-a2a-generation-scope.sh (MUS-6707 / MUS-6726).
# Fixtures mirror the 2026.8.35 bundle shape: ESM sessions-spawn-tool-*.js with
# the two a2a anchors, and a scope module exporting the function under alias `r`.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
PATCHER="$HYDRA_REPO/scripts/patch-openclaw-a2a-generation-scope.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  export OPENCLAW_DIST_DIR="$TEST_TMPDIR/dist"
  mkdir -p "$OPENCLAW_DIST_DIR"
  TARGET="$OPENCLAW_DIST_DIR/sessions-spawn-tool-AbC123.js"
  SCOPE="$OPENCLAW_DIST_DIR/prepared-model-runtime-generation-scope-XyZ789.js"
  write_fixtures
}

teardown() { rm -rf "$TEST_TMPDIR"; }

write_fixtures() {
  cat > "$TARGET" <<'JS'
import { h as other } from "./number-coercion-CLj0HTDM.js";
const runWithGatewayIndependentRootWorkContinuation = (f) => f();
const runWithoutOwnedSessionTranscriptWrites = (f) => f();
const runSessionsSendA2AFlow = async () => {};
const detach = (f, label) => Promise.resolve(f()).catch(() => label);
detach(() =>
	runWithGatewayIndependentRootWorkContinuation(() => runWithoutOwnedSessionTranscriptWrites(() => runSessionsSendA2AFlow({
		a: 1
	})), "session:a2a-send").catch((err) => {
	}));
JS
  # real bundle puts the first-import-only; keep the closing shape of the anchor
  printf '%s\n' 'function runOutsidePreparedModelRuntimePluginGenerationScope(run) { return run(); }' \
    'export { runOutsidePreparedModelRuntimePluginGenerationScope as r };' > "$SCOPE"
}

@test "first run patches: import added, call wrapped, one a2a label, parses, .bak kept" {
  run "$PATCHER"
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
  head -1 "$TARGET" | grep -Fxq 'import { r as runOutsidePreparedModelRuntimePluginGenerationScope } from "./prepared-model-runtime-generation-scope-XyZ789.js";'
  grep -Fq 'runWithGatewayIndependentRootWorkContinuation(() => runOutsidePreparedModelRuntimePluginGenerationScope(() => runWithoutOwnedSessionTranscriptWrites(() => runSessionsSendA2AFlow({' "$TARGET"
  grep -Fq '}))), "session:a2a-send")' "$TARGET"
  [ "$(grep -cF '"session:a2a-send"' "$TARGET")" -eq 1 ]
  node --input-type=module --check < "$TARGET"
  [ -f "$TARGET.bak" ]
}

@test "second run is idempotent: SKIP, exit 0, file unchanged" {
  "$PATCHER"
  before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 0 ]
  [[ "$output" == SKIP:* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
}

@test "open anchor drift: exit 1, version-changed error, file untouched, no .bak" {
  sed -i.orig 's/runWithoutOwnedSessionTranscriptWrites(() => runSessionsSendA2AFlow/runSessionsSendA2AFlow2/' "$TARGET"
  rm "$TARGET.orig"; before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OpenClaw version may have changed. Manual review needed."* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
  [ ! -f "$TARGET.bak" ]
}

@test "close anchor drift: exit 1, file untouched" {
  sed -i.orig 's/"session:a2a-send"/"session:a2a-send2"/' "$TARGET"
  rm "$TARGET.orig"; before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manual review needed."* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
}

@test "open anchor present twice: refuses (exactly-once guard)" {
  dup="$(grep -F 'runWithGatewayIndependentRootWorkContinuation(() => runWithoutOwned' "$TARGET")"
  printf '%s\n' "$dup" >> "$TARGET"
  before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"anchor not found exactly once"* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
}

@test "scope module no longer exports the function: import guard refuses" {
  printf '%s\n' 'export const x = 1;' > "$SCOPE"
  before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer exports runOutsidePreparedModelRuntimePluginGenerationScope"* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
}

@test "patched file that fails node --check is restored from .bak" {
  printf '%s\n' '}}}' >> "$TARGET"   # unrelated stray brace: patch is textually fine, parse is not
  before="$(shasum "$TARGET")"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"node --check"* ]]
  [ "$(shasum "$TARGET")" = "$before" ]
}

@test "missing or duplicate bundle files refuse" {
  rm "$SCOPE"
  run "$PATCHER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Manual review needed."* ]]
}

@test "deploy reapplies the a2a patch after every runtime install, failing loud" {
  install_line="$(grep -n '^if ! install_openclaw; then$' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"
  patch_line="$(grep -n -F 'bash "$HYDRA_ROOT/scripts/patch-openclaw-a2a-generation-scope.sh"; then' "$HYDRA_REPO/scripts/deploy.sh" | cut -d: -f1)"
  [ -n "$install_line" ]
  [ -n "$patch_line" ]
  [ "$patch_line" -gt "$install_line" ]
  grep -Fq 'fail "OpenClaw a2a generation-scope backport failed"' "$HYDRA_REPO/scripts/deploy.sh"
}

@test "post-update hook reapplies the a2a patch" {
  grep -Fq 'bash "$HYDRA_ROOT/scripts/patch-openclaw-a2a-generation-scope.sh"' "$HYDRA_REPO/scripts/post-openclaw-update.sh"
  grep -Fq 'ERROR: patch-openclaw-a2a-generation-scope.sh not found' "$HYDRA_REPO/scripts/post-openclaw-update.sh"
}

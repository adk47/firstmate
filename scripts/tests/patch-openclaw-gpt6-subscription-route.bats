#!/usr/bin/env bats
# patch-openclaw-gpt6-subscription-route.sh: adds gpt-6-sol/gpt-6-luna to the
# 2026.8.x dual-route list so the oauth-only fleet reaches them on the ChatGPT
# subscription instead of falling back to paid OpenRouter (MUS-5128, 9 Oct).

SCRIPT="$BATS_TEST_DIRNAME/../patch-openclaw-gpt6-subscription-route.sh"

setup() {
  DIST="$(mktemp -d)"
  export OPENCLAW_DIST_DIR="$DIST"
  # Verbatim shape of 2026.8.35's dist/model-route-contract-IBjMckUY.js region.
  cat > "$DIST/model-route-contract-TEST.js" <<'JS'
const OPENAI_GPT_6_ASTRA_MODEL_ID = "gpt-6-astra";
const OPENAI_GPT_61_SOL_MODEL_ID = "gpt-6.1-sol";
const OPENAI_GPT_56_VARIANT_MODEL_IDS = ["gpt-5.6-sol"];
const OPENAI_GPT_55_MODEL_ID = "gpt-5.5";
const OPENAI_DUAL_ROUTE_MODEL_IDS = [
	OPENAI_GPT_6_ASTRA_MODEL_ID,
	OPENAI_GPT_61_SOL_MODEL_ID,
	...OPENAI_GPT_56_VARIANT_MODEL_IDS,
	OPENAI_GPT_55_MODEL_ID
];
export { OPENAI_DUAL_ROUTE_MODEL_IDS };
JS
}

teardown() { rm -rf "$DIST"; }

ids() {
  node --input-type=module -e "import { OPENAI_DUAL_ROUTE_MODEL_IDS as x } from '$DIST/model-route-contract-TEST.js'; console.log(x.join(','))"
}

@test "fresh 2026.8 dist: adds gpt-6-sol and gpt-6-luna to the dual-route list" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
  [ "$(ids)" = "gpt-6-astra,gpt-6.1-sol,gpt-6-sol,gpt-6-luna,gpt-5.6-sol,gpt-5.5" ]
}

@test "second run is a no-op (SKIP) and the file is byte-identical" {
  bash "$SCRIPT"
  before=$(sha256sum "$DIST/model-route-contract-TEST.js")
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == SKIP:* ]]
  [ "$(sha256sum "$DIST/model-route-contract-TEST.js")" = "$before" ]
}

@test "anchor drift fails loud and leaves the file untouched" {
  sed -i.bak 's/OPENAI_GPT_61_SOL_MODEL_ID,/OPENAI_GPT_61_SOL_MODEL_ID, "x",/' "$DIST/model-route-contract-TEST.js"
  rm -f "$DIST"/*.bak
  before=$(sha256sum "$DIST/model-route-contract-TEST.js")
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchors drifted"* ]]
  [ "$(sha256sum "$DIST/model-route-contract-TEST.js")" = "$before" ]
}

@test "no target or two targets fails loud" {
  rm "$DIST/model-route-contract-TEST.js"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"found 0"* ]]
}

@test "missing dist dir fails loud" {
  OPENCLAW_DIST_DIR=/nonexistent run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "no temp file is left behind" {
  bash "$SCRIPT"
  [ -z "$(find "$DIST" -name '.hydra-gpt6-route-*')" ]
}

@test "deploy.sh runs the backport only for 2026.8.x and retires it at 2026.9" {
  D="$BATS_TEST_DIRNAME/../deploy.sh"
  grep -q 'patch-openclaw-gpt6-subscription-route.sh' "$D"
  grep -q 'version_at_least "2026.9" "$OPENCLAW_VERSION"' "$D"
}

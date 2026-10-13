#!/usr/bin/env bats
# patch-openclaw-soul-delivery.sh: delivers SOUL/memory/skills/cron-mode through the
# thread-level developerInstructions channel, because codex 0.156.1 overwrites the
# turn-level collaboration_mode payload on gpt-6 slugs (MUS-6632 / MUS-6600, 9 Oct).
# Partial application is the dangerous state: edit A alone double-sends ~53 kB on every
# gpt-5.6 turn, so every failure case asserts NEITHER file was touched.

SCRIPT="$BATS_TEST_DIRNAME/../patch-openclaw-soul-delivery.sh"

setup() {
  DIST="$(mktemp -d)"
  A="$DIST/run-attempt-TEST.js"
  B="$DIST/thread-lifecycle-TEST.js"
  # Verbatim shape of 2026.8.35 run-attempt-N7OkdQRM.js L7509-7513 and L7635.
  cat > "$A" <<'JS'
async function startCodexAttemptRuntime(resources) {
	const { prompt, state } = resources;
	const { context, turnState, buildRenderedCodexDeveloperInstructions, rebuildCodexTurnPromptTextFromCurrentProjection } = prompt;
	const { runtime, attemptTools, promptState } = context;
	const developerInstructions = joinPresentSections(turnState.promptBuild.developerInstructions, attemptTools.scheduledConfiguredMcp?.diagnosticNotice);
	return { developerInstructions, recorded: {
			developerInstructions: joinPresentSections(buildRenderedCodexDeveloperInstructions(), attemptTools.scheduledConfiguredMcp?.diagnosticNotice),
	} };
}
// Verbatim shape of run-attempt-BJ6tOQeE.mjs L3128-3134 (head of the rotation function) and its caller L5626-5641.
async function rotateOversizedCodexAppServerStartupBinding(params) {
	const binding = params.binding;
	if (!binding?.threadId) return { binding };
	if (binding.connectionScope === "supervision") return { binding };
	const sessionRecord = await readCodexSessionRecordForSessionFile(params.sessionFile);
	const rolloutFiles = await listCodexAppServerRolloutFilesForThread(params.agentDir, binding.threadId, params.codexHome, binding.rolloutPath);
	return { binding };
}
async function rotateStartupBindingForProjectedTurn(binding, turnState, buildRenderedCodexDeveloperInstructions) {
		const startupBindingResolution = await rotateOversizedCodexAppServerStartupBinding({
			binding,
			config: params.config,
			contextEngineActive: Boolean(activeContextEngine),
			projectedTurnTokens: estimateCodexAppServerProjectedTurnTokens({
				prompt: turnState.codexTurnPromptText,
				developerInstructions: buildRenderedCodexDeveloperInstructions()
			})
		});
		return startupBindingResolution;
}
JS
  # Verbatim shape of thread-lifecycle-DrbHJnLm.js L4613-4619.
  cat > "$B" <<'JS'
function buildTurnStartParams(params, options) {
	const modelSelection = params.modelSelection;
	const collaborationMode = modelSelection ? buildTurnCollaborationMode(params, {
		model: modelSelection.model,
		turnScopedDeveloperInstructions: options.turnScopedDeveloperInstructions,
		skillsCollaborationInstructions: options.skillsCollaborationInstructions,
		memoryCollaborationInstructions: options.memoryCollaborationInstructions
	}) : void 0;
	const useThreadPermissionProfile = options.appServer.networkProxy && !options.sandboxPolicy;
	return { collaborationMode, useThreadPermissionProfile };
}
JS
}

teardown() { rm -rf "$DIST" "${PLUGIN:-}"; }

# The tree that actually executes on a gateway: the codex plugin's own .mjs copy under
# <profile>/npm/projects/openclaw-codex-*/node_modules/@openclaw/codex/dist/.setup (canary, 9 Oct).
make_plugin() {
  PLUGIN="$(mktemp -d)"
  PA="$PLUGIN/run-attempt-PLUG.mjs"
  PB="$PLUGIN/thread-lifecycle-PLUG.mjs"
  { cat "$A"; echo 'export { startCodexAttemptRuntime };'; } > "$PA"
  { cat "$B"; echo 'export { buildTurnStartParams };'; } > "$PB"
}

sums() { sha256sum "$A" "$B"; }

@test "fresh dist: both edits applied, files parse" {
  run bash "$SCRIPT" "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
  # A: delivery line uses the rendered string; the old base-only line is gone.
  grep -qF 'const developerInstructions = joinPresentSections(buildRenderedCodexDeveloperInstructions(), attemptTools' "$A"
  ! grep -qF 'const developerInstructions = joinPresentSections(turnState.promptBuild' "$A"
  # B: nulling sits after the collaborationMode const and before useThreadPermissionProfile.
  line=$(grep -n 'collaborationMode.settings.developer_instructions = null;' "$B" | cut -d: -f1)
  [ "$(grep -c 'developer_instructions = null' "$B")" -eq 1 ]
  [ "$(grep -n '}) : void 0;' "$B" | cut -d: -f1)" -eq $((line - 1)) ]
  [ "$(grep -n 'const useThreadPermissionProfile' "$B" | cut -d: -f1)" -eq $((line + 1)) ]
  # The trajectory-recorder line is untouched (still exactly one).
  # recorder line + edit A + the rendered string passed to the rotation guard (C2) + the caller's own use.
  [ "$(grep -c 'buildRenderedCodexDeveloperInstructions()' "$A")" -eq 4 ]
  [ "$(grep -c 'renderedHasSoul' "$A")" -eq 2 ]
  node --check "$A"
  node --check "$B"
}

@test "patched code nulls the turn payload and delivers the full string" {
  bash "$SCRIPT" "$DIST"
  run node --input-type=module -e "
    import fs from 'node:fs';
    const b = fs.readFileSync('$B','utf8')
      .replace('function buildTurnStartParams', 'globalThis.fn = function buildTurnStartParams');
    globalThis.buildTurnCollaborationMode = () => ({ settings: { developer_instructions: 'FULL' } });
    (0, eval)(b);
    const r = globalThis.fn({ modelSelection: { model: 'm' } }, { appServer: {} });
    console.log(String(r.collaborationMode.settings.developer_instructions));
    console.log(String(globalThis.fn({}, { appServer: {} }).collaborationMode));
  "
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "null" ]
  [ "${lines[1]}" = "undefined" ]
}

# Run the patched rotation function against real rollout files. $1 = rollout first-developer text,
# $2 = renderedHasSoul, $3 = connectionScope. Prints "rotated" or "kept".
rotation() {
  local rollout="$DIST/rollout.jsonl" text="$1"
  printf '%s\n' '{"type":"session_meta","payload":{}}' \
    "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"$text\"}]}}" > "$rollout"
  node --input-type=module -e "
    import fs from 'node:fs/promises';
    import src from 'node:fs';
    globalThis.fs = fs;
    globalThis.readCodexSessionRecordForSessionFile = async () => undefined;
    globalThis.listCodexAppServerRolloutFilesForThread = async () => [{ path: '$rollout', bytes: 1 }];
    let cleared = 0;
    globalThis.embeddedAgentLog = { warn() {} };
    (0, eval)(src.readFileSync('$A', 'utf8'));
    const out = await rotateOversizedCodexAppServerStartupBinding({
      binding: { threadId: 't1', connectionScope: '${3:-}' || undefined },
      renderedHasSoul: $2,
      bindingStore: { mutate: async (_i, op) => { if (op.kind === 'clear' && op.threadId === 't1') cleared++; } },
      identity: {},
    });
    console.log(cleared === 1 && out.binding === undefined ? 'rotated' : 'kept');
  "
}

@test "anchor C: a bound thread whose rollout predates SOUL rotates, and only then" {
  bash "$SCRIPT" "$DIST"
  node --check "$A"
  [ "$(rotation 'base only' true)" = "rotated" ]
  # fresh thread (SOUL already in the first developer item): never rotates again
  [ "$(rotation '<AGENT_SOUL>x</AGENT_SOUL>' true)" = "kept" ]
  # lightweight cron by design carries no SOUL: must not loop on it
  [ "$(rotation 'base only' false)" = "kept" ]
  # supervision bindings are left alone
  [ "$(rotation 'base only' true supervision)" = "kept" ]
}

@test "anchor C: the caller passes whether the rendered string carries SOUL" {
  bash "$SCRIPT" "$DIST"
  grep -qF 'renderedHasSoul: (buildRenderedCodexDeveloperInstructions() ?? "").includes("<AGENT_SOUL>"),' "$A"
}

@test "anchor C missing at either site: fails loud, neither file modified" {
  cp "$A" "$DIST/a.keep"
  sed -i.bak 's/const rolloutFiles = await listCodexAppServerRolloutFilesForThread/const files = await listCodexAppServerRolloutFilesForThread/' "$A"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchors drifted"* ]]
  [ "$(sums)" = "$before" ]
  cp "$DIST/a.keep" "$A"
  sed -i.bak 's/projectedTurnTokens: estimateCodexAppServerProjectedTurnTokens/projectedTurnTokens: other/' "$A"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [ "$(sums)" = "$before" ]
}

@test "anchor C half-applied (C1 without C2) fails loud, not SKIP" {
  bash "$SCRIPT" "$DIST"
  sed -i.bak '/renderedHasSoul: (buildRendered/d' "$A"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" != SKIP:* ]]
  [ "$(sums)" = "$before" ]
}

@test "a tree hotpatched with A+B only gets C added and nothing else changes" {
  sed -i.bak 's/joinPresentSections(turnState.promptBuild.developerInstructions/joinPresentSections(buildRenderedCodexDeveloperInstructions()/' "$A"
  sed -i.bak 's/^\tconst useThreadPermissionProfile/\tif (collaborationMode) collaborationMode.settings.developer_instructions = null;\n&/' "$B"; rm -f "$DIST"/*.bak
  cp "$B" "$DIST/b.hot"
  run bash "$SCRIPT" "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == OK:* ]]
  cmp "$B" "$DIST/b.hot"
  [ "$(grep -c 'renderedHasSoul' "$A")" -eq 2 ]
  [ "$(grep -c 'developer_instructions = null' "$B")" -eq 1 ]
  run bash "$SCRIPT" "$DIST"
  [[ "$output" == SKIP:* ]]
}

@test "second run is a no-op (SKIP) and both files are byte-identical" {
  bash "$SCRIPT" "$DIST"
  cp "$A" "$DIST/a.snap"; cp "$B" "$DIST/b.snap"
  run bash "$SCRIPT" "$DIST"
  [ "$status" -eq 0 ]
  [[ "$output" == SKIP:* ]]
  cmp "$A" "$DIST/a.snap"
  cmp "$B" "$DIST/b.snap"
}

@test "anchor A missing: fails loud and neither file is modified" {
  sed -i.bak 's/turnState.promptBuild.developerInstructions/turnState.other/' "$A"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchors drifted"* ]]
  [ "$(sums)" = "$before" ]
}

@test "anchor B missing: fails loud and neither file is modified (no A-only double-send)" {
  sed -i.bak 's/memoryCollaborationInstructions: options.memoryCollaborationInstructions/memoryCollaborationInstructions: 1/; s/}) : void 0;/}) : null;/' "$B"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchors drifted"* ]]
  [ "$(sums)" = "$before" ]
  grep -qF 'turnState.promptBuild.developerInstructions' "$A"
}

@test "anchor A present twice: drift, neither file modified" {
  # read into a variable first: GNU grep refuses to read and append to the same file
  _dup=$(grep -F 'const developerInstructions = joinPresentSections(turnState' "$A")
  printf '%s\n' "$_dup" >> "$A"
  [ "$(grep -cF 'const developerInstructions = joinPresentSections(turnState' "$A")" -eq 2 ]
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"anchors drifted"* ]]
  [ "$(sums)" = "$before" ]
}

@test "already-patched A + unpatched B fails, not SKIP, and does not touch B" {
  sed -i.bak 's/joinPresentSections(turnState.promptBuild.developerInstructions/joinPresentSections(buildRenderedCodexDeveloperInstructions()/' "$A"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" != SKIP:* ]]
  [ "$(sums)" = "$before" ]
}

@test "unpatched A + already-patched B fails, not SKIP" {
  sed -i.bak 's/^\tconst useThreadPermissionProfile/\tif (collaborationMode) collaborationMode.settings.developer_instructions = null;\n&/' "$B"; rm -f "$DIST"/*.bak
  before=$(sums)
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" != SKIP:* ]]
  [ "$(sums)" = "$before" ]
}

@test "no target or two targets fails loud" {
  rm "$B"
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"found 1 and 0"* ]]
  cp "$A" "$DIST/run-attempt-OTHER.js"
  run bash "$SCRIPT" "$DIST"
  [ "$status" -ne 0 ]
}

@test "missing dist dir fails loud" {
  run bash "$SCRIPT" "/nonexistent/*"
  [ "$status" -ne 0 ]
}

@test "no temp file is left behind" {
  bash "$SCRIPT" "$DIST"
  [ -z "$(find "$DIST" -name '.hydra-soul-delivery-*')" ]
}

@test "a .mjs plugin tree is patched, files parse as ESM, second run SKIPs" {
  make_plugin
  run bash "$SCRIPT" "$PLUGIN"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^OK: ' <<<"$output")" -eq 1 ]
  grep -qF 'joinPresentSections(buildRenderedCodexDeveloperInstructions(), attemptTools' "$PA"
  [ "$(grep -c 'developer_instructions = null' "$PB")" -eq 1 ]
  node --check "$PA"
  node --check "$PB"
  [ -z "$(find "$PLUGIN" -name '.hydra-soul-delivery-*')" ]
  run bash "$SCRIPT" "$PLUGIN"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^SKIP: ' <<<"$output")" -eq 1 ]
}

@test "no arguments is a usage error and touches nothing" {
  before=$(sums)
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "$(sums)" = "$before" ]
}

@test "a glob that matches nothing FAILS, even when another profile patched fine" {
  run bash "$SCRIPT" "$DIST" "/nonexistent/*/dist/.setup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no plugin dist directory matches"* ]]
}

@test "two profiles: both trees patched; one drifted tree fails the run and stays untouched" {
  make_plugin
  sed 's/turnState.promptBuild.developerInstructions/turnState.promptBuild.somethingElse/' "$PA" > "$PA.new" && mv "$PA.new" "$PA"
  before=$(sha256sum "$PA" "$PB")
  run bash "$SCRIPT" "$DIST" "$PLUGIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$PLUGIN"* ]]
  [ "$before" = "$(sha256sum "$PA" "$PB")" ]
}

@test "a glob matching several generations patches every one" {
  make_plugin
  OLD="$PLUGIN-old"; mkdir "$OLD"; cp "$PA" "$PB" "$OLD/"
  run bash "$SCRIPT" "$PLUGIN*"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^OK: ' <<<"$output")" -eq 2 ]
  [ "$(grep -c 'developer_instructions = null' "$OLD/thread-lifecycle-PLUG.mjs")" -eq 1 ]
  rm -rf "$OLD"
}

@test "tripwire: the post-patch re-read exists and counts both anchors" {
  grep -q 'post-patch check failed' "$SCRIPT"
  grep -q 'count(afterB, bInsert) !== 1' "$SCRIPT"
  grep -q 'count(afterA, c1Insert) !== 1' "$SCRIPT"
}

@test "deploy.sh: gated per profile, runs AFTER the codex plugin install (Step 4d.5), skips at 2026.10" {
  D="$BATS_TEST_DIRNAME/../deploy.sh"
  grep -q 'version_at_least "2026.10" "$OPENCLAW_VERSION"' "$D"
  install_line=$(grep -n 'install_external_plugin "@openclaw/codex"' "$D" | tail -1 | cut -d: -f1)
  call_line=$(grep -n 'bash "$HYDRA_ROOT/scripts/patch-openclaw-soul-delivery.sh"' "$D" | head -1 | cut -d: -f1)
  [ -n "$install_line" ] && [ -n "$call_line" ]
  [ "$call_line" -gt "$install_line" ]
  # one glob per profile, gated by needs_target
  grep -q 'openclaw-\${_profile}/npm/projects/openclaw-codex-' "$D"
  grep -q 'needs_target "\$_profile"' "$D"
}

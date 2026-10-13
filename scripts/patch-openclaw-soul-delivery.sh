#!/usr/bin/env bash
# Deliver SOUL / memory / skills / cron-mode through the thread-level
# developerInstructions channel, which codex cannot overwrite (MUS-6600, 9 Oct).
#
# Why: codex 0.156.1 substitutes the gpt-6 catalog's `collaboration_modes.default`
# (896 chars) for the client's turn-level collaborationMode.settings.developer_instructions,
# so SOUL, memory, <available_skills> and the cron-mode instructions never reach the
# model on any gpt-6 slug. OpenClaw 2026.8.35 already composes the full string
# (buildRenderedCodexDeveloperInstructions) but only records it in the trajectory;
# thread start/resume gets the base only. Two edits, applied together:
#   A. run-attempt-*: thread-level developerInstructions uses the rendered (full) string.
#   B. thread-lifecycle-* (buildTurnStartParams): null the turn-level payload, so
#      gpt-5.6 does not receive the same ~53 kB twice.
# A without B double-sends on every gpt-5.6 turn, so the script resolves BOTH anchors in a
# tree and writes nothing in that tree unless both are applicable.
# Third edit, C (run-attempt-*, same file as A): codex does NOT re-apply developerInstructions
# on thread/resume, so a gpt-6 thread opened before A+B keeps running without SOUL for as long
# as it lives. C makes rotateOversizedCodexAppServerStartupBinding also rotate a bound thread
# whose rollout's first developer item lacks <AGENT_SOUL> while the instructions about to be
# sent contain it. The existing rotation path starts a fresh thread and re-projects the
# conversation history; after it the new rollout has SOUL, so it fires once per stale thread.
# Never fires when the rendered instructions have no SOUL (lightweight cron by design), nor on
# supervision bindings (the function returns earlier). C is two sites, both-or-neither. A tree
# hotpatched with A+B only is a legal state and gets C added on top; every other mix fails loud. Dist filenames are
# content-hashed; targets are found by content.
#
# WHICH TREE RUNS (canary, 9 Oct): the code that executes on a gateway is the external
# codex plugin's own copy, <profile>/npm/projects/openclaw-codex-*/node_modules/@openclaw/
# codex/dist/.setup/{run-attempt,thread-lifecycle}-*.mjs (the g-<hash> dir changes per plugin
# generation). Patching the core dist (/usr/lib/node_modules/openclaw/dist) changed nothing:
# gpt-6 first developer item stayed 5675 chars with no AGENT_SOUL, so core dist is NOT a target.
#
# Usage: patch-openclaw-soul-delivery.sh <dist-dir-glob>...   (one glob per targeted profile)
# Every glob must match at least one directory (zero = FAIL, never a silent skip). Several
# matches (old plugin generations left on disk) are all patched: each tree is atomic and
# idempotent, an unused generation is harmless to patch, and one that has drifted fails loud
# rather than being skipped. After patching, each tree is re-read and must hold exactly one
# fixed anchor A and one null-insert B, so a green run implies the fix is on disk.
#
# Retire when the installed release ships `developer_instructions: ... : null` natively:
# @openclaw/codex@2026.10.1-beta.2 does, 2026.9.9 does NOT (the deploy gate applies this
# on 2026.8.x and 2026.9.x and skips at >= 2026.10; so the anchors fail loud there until MUS-6470 re-points the globs).
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "ERROR: usage: $0 <dist-dir-glob>..." >&2
  exit 2
fi

failed=0
roots=()
for pattern in "$@"; do
  matched=0
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    roots+=("$dir"); matched=1
  done < <(compgen -G "$pattern" || true)
  if [[ "$matched" -eq 0 ]]; then
    echo "ERROR: no plugin dist directory matches: $pattern" >&2
    failed=1
  fi
done

find_target() {
  local root="$1" glob="$2" marker="$3" candidate
  find "$root" -maxdepth 1 -type f \( -name "$glob.js" -o -name "$glob.mjs" \) -print \
    | while IFS= read -r candidate; do
        grep -qF -- "$marker" "$candidate" && printf '%s\n' "$candidate"
      done
}

patch_root() {
local root="$1" result
local -a target_a target_b
mapfile -t target_a < <(find_target "$root" 'run-attempt-*' 'const developerInstructions = joinPresentSections(')
mapfile -t target_b < <(find_target "$root" 'thread-lifecycle-*' 'function buildTurnStartParams(params, options) {')

if [[ "${#target_a[@]}" -ne 1 || "${#target_b[@]}" -ne 1 ]]; then
  echo "ERROR: $root: expected one run-attempt and one thread-lifecycle patch target; found ${#target_a[@]} and ${#target_b[@]} (anchor drift)" >&2
  return 1
fi

result=$(node --input-type=module - "${target_a[0]}" "${target_b[0]}" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const [targetA, targetB] = process.argv.slice(2);
const sourceA = fs.readFileSync(targetA, "utf8");
const sourceB = fs.readFileSync(targetB, "utf8");

const aVulnerable = "\tconst developerInstructions = joinPresentSections(turnState.promptBuild.developerInstructions, attemptTools.scheduledConfiguredMcp?.diagnosticNotice);\n";
const aFixed = "\tconst developerInstructions = joinPresentSections(buildRenderedCodexDeveloperInstructions(), attemptTools.scheduledConfiguredMcp?.diagnosticNotice);\n";
// The trajectory recorder already calls the rendered builder; this anchor includes the
// leading `const developerInstructions =` so it can never match that line.
const bAnchor = "\t}) : void 0;\n";
const bInsert = "\tif (collaborationMode) collaborationMode.settings.developer_instructions = null;\n";
const bBoundary = "\tconst useThreadPermissionProfile = ";

// C1: inside rotateOversizedCodexAppServerStartupBinding, right after the rollout files are listed.
const c1Anchor = "\tconst rolloutFiles = await listCodexAppServerRolloutFilesForThread(params.agentDir, binding.threadId, params.codexHome, binding.rolloutPath);\n";
const c1Insert = [
  "\tif (params.renderedHasSoul === true) {",
  "\t\tlet predatesSoul = false;",
  "\t\tfor (const file of rolloutFiles) {",
  "\t\t\tconst own = file.handle ? void 0 : await fs.open(file.path, \"r\").catch(() => void 0);",
  "\t\t\tconst handle = file.handle ?? own;",
  "\t\t\ttry {",
  "\t\t\t\tif (!handle) continue;",
  "\t\t\t\tconst head = Buffer.alloc(262144);",
  "\t\t\t\tconst { bytesRead } = await handle.read(head, 0, head.length, 0);",
  "\t\t\t\tconst line = head.toString(\"utf8\", 0, bytesRead).split(\"\\n\").find((entry) => entry.includes('\"type\":\"response_item\"') && entry.includes('\"role\":\"developer\"'));",
  "\t\t\t\tif (line === void 0) continue;",
  "\t\t\t\tpredatesSoul = !line.includes(\"<AGENT_SOUL>\");",
  "\t\t\t\tif (!predatesSoul) break;",
  "\t\t\t} catch {} finally {",
  "\t\t\t\tawait own?.close();",
  "\t\t\t}",
  "\t\t}",
  "\t\tif (predatesSoul) {",
  "\t\t\tawait Promise.all(rolloutFiles.map(async (file) => {",
  "\t\t\t\tawait file.handle?.close();",
  "\t\t\t}));",
  "\t\t\tembeddedAgentLog.warn(\"codex app-server bound thread predates soul delivery; starting a fresh thread\", { threadId: binding.threadId });",
  "\t\t\tawait params.bindingStore.mutate(params.identity, {",
  "\t\t\t\tkind: \"clear\",",
  "\t\t\t\tthreadId: binding.threadId",
  "\t\t\t});",
  "\t\t\treturn { binding: void 0 };",
  "\t\t}",
  "\t}",
  ""
].join("\n");
// C2: the only caller that computes the rendered string passes whether it carries SOUL.
const c2Anchor = "\t\t\tprojectedTurnTokens: estimateCodexAppServerProjectedTurnTokens({\n";
const c2Insert = "\t\t\trenderedHasSoul: (buildRenderedCodexDeveloperInstructions() ?? \"\").includes(\"<AGENT_SOUL>\"),\n";

const count = (haystack, needle) => haystack.split(needle).length - 1;

// B lives inside buildTurnStartParams: slice that function's head so the anchor is unique.
const fnStart = sourceB.indexOf("function buildTurnStartParams(params, options) {");
const bHead = fnStart < 0 ? "" : sourceB.slice(fnStart);
const bVulnerable = "const collaborationMode = modelSelection ? buildTurnCollaborationMode(";
const bAt = bHead.indexOf(bVulnerable);
const bEnd = bAt < 0 ? -1 : bHead.indexOf(bAnchor + bBoundary, bAt);
const bFixedEnd = bAt < 0 ? -1 : bHead.indexOf(bAnchor + bInsert + bBoundary, bAt);

const state = {
  aVulnerable: count(sourceA, aVulnerable),
  aFixed: count(sourceA, aFixed),
  bFunction: count(sourceB, "function buildTurnStartParams(params, options) {"),
  bCollaborationConst: count(sourceB, bVulnerable),
  bVulnerable: bEnd >= 0 ? 1 : 0,
  bFixed: bFixedEnd >= 0 ? 1 : 0,
};

const aDone = state.aVulnerable === 0 && state.aFixed === 1;
const aTodo = state.aVulnerable === 1 && state.aFixed === 0;
const bDone = state.bFunction === 1 && state.bCollaborationConst === 1 && state.bVulnerable === 0 && state.bFixed === 1;
const bTodo = state.bFunction === 1 && state.bCollaborationConst === 1 && state.bVulnerable === 1 && state.bFixed === 0;

state.c1Anchor = count(sourceA, c1Anchor);
state.c1Fixed = count(sourceA, c1Insert);
state.c2Anchor = count(sourceA, c2Anchor);
state.c2Fixed = count(sourceA, c2Insert);
// C is two sites; the anchors stay present after patching (the insert goes next to them).
const cDone = state.c1Anchor === 1 && state.c1Fixed === 1 && state.c2Anchor === 1 && state.c2Fixed === 1;
const cTodo = state.c1Anchor === 1 && state.c1Fixed === 0 && state.c2Anchor === 1 && state.c2Fixed === 0;

if (aDone && bDone && cDone) {
  process.stdout.write("ALREADY");
  process.exit(0);
}
// Mixed states (one edit present, the other not) are the dangerous partial application.
// The one legal mix is A+B already applied with C still to do (a hotpatched tree).
const abTodo = aTodo && bTodo;
if (!((abTodo || (aDone && bDone)) && (cTodo || cDone) && !(abTodo && cDone))) {
  console.error(`ERROR: ${path.dirname(targetA)}: soul-delivery anchors drifted: ${JSON.stringify(state)}`);
  process.exit(1);
}

let patchedA = sourceA;
if (abTodo) patchedA = patchedA.replace(aVulnerable, () => aFixed);
if (cTodo) patchedA = patchedA.replace(c1Anchor, () => c1Anchor + c1Insert).replace(c2Anchor, () => c2Insert + c2Anchor);
const bIndex = fnStart + bEnd + bAnchor.length;
const patchedB = abTodo ? sourceB.slice(0, bIndex) + bInsert + sourceB.slice(bIndex) : sourceB;

const staged = [];
try {
  for (const [target, content] of [[targetA, patchedA], [targetB, patchedB]]) {
    if (content === (target === targetA ? sourceA : sourceB)) continue;
    const temporary = path.join(path.dirname(target), `.hydra-soul-delivery-${process.pid}-${path.basename(target)}.tmp${path.extname(target)}`);
    staged.push([temporary, target]);
    fs.writeFileSync(temporary, content, { mode: fs.statSync(target).mode });
    const syntax = spawnSync(process.execPath, ["--check", temporary], { encoding: "utf8" });
    if (syntax.status !== 0) {
      process.stderr.write(syntax.stderr || "ERROR: patched runtime failed syntax validation\n");
      throw new Error("patched runtime failed syntax validation");
    }
  }
  // Both validated: only now replace the live files.
  for (const [temporary, target] of staged) fs.renameSync(temporary, target);
} finally {
  for (const [temporary] of staged) { try { fs.unlinkSync(temporary); } catch {} }
}
// Re-read what is now on disk: a green run must mean the fix is live in this tree.
const afterA = fs.readFileSync(targetA, "utf8");
const afterB = fs.readFileSync(targetB, "utf8");
if (count(afterA, aFixed) !== 1 || count(afterA, aVulnerable) !== 0 || count(afterB, bInsert) !== 1
  || count(afterA, c1Insert) !== 1 || count(afterA, c2Insert) !== 1) {
  console.error(`ERROR: ${path.dirname(targetA)}: post-patch check failed, fix is not active`);
  process.exit(1);
}
process.stdout.write("PATCHED");
NODE
) || return 1

case "$result" in
  PATCHED) echo "OK: $root: SOUL/memory/skills/cron-mode now delivered via thread-level developerInstructions (turn-level payload nulled)" ;;
  ALREADY) echo "SKIP: $root: soul-delivery patch already applied" ;;
  *) echo "ERROR: $root: unexpected patch result: $result" >&2; return 1 ;;
esac
}

for root in "${roots[@]}"; do
  patch_root "$root" || failed=1
done
exit "$failed"

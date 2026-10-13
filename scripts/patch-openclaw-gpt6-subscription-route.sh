#!/usr/bin/env bash
# Teach OpenClaw 2026.8.x that gpt-6-sol / gpt-6-luna have a ChatGPT-subscription route.
#
# Why: 2026.8.35's model-route contract lists only gpt-6-astra and gpt-6.1-sol among
# the gpt-6 ids (OPENAI_DUAL_ROUTE_MODEL_IDS). An unlisted id resolves to the Platform
# (api-key) route only; hydra's openai auth is oauth-only, so every turn on
# openai/gpt-6-sol was rejected "Explicit auth order for openai has no usable profiles"
# and fell back to paid openrouter/openai/gpt-6-luna (9 Oct, after #1118).
# codex 0.156.1 already serves both ids (models_cache.json), and 2026.9.x adds exactly
# these two ids to the same list (OPENAI_GPT_6_MODEL_IDS), so this is a backport.
#
# Retire when OPENCLAW_VERSION >= 2026.9 (the deploy gate skips it there; the anchor
# check makes it fail loud on any other drift).
set -euo pipefail

DIST_DIR="${OPENCLAW_DIST_DIR:-/usr/lib/node_modules/openclaw/dist}"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "ERROR: OpenClaw dist directory not found: $DIST_DIR" >&2
  exit 1
fi

mapfile -t targets < <(
  find "$DIST_DIR" -maxdepth 1 -type f -name 'model-route-contract-*.js' -print \
    | while IFS= read -r candidate; do
        grep -q 'const OPENAI_DUAL_ROUTE_MODEL_IDS = \[' "$candidate" && printf '%s\n' "$candidate"
      done
)

if [[ "${#targets[@]}" -ne 1 ]]; then
  echo "ERROR: expected one model-route-contract patch target; found ${#targets[@]} (anchor drift)" >&2
  exit 1
fi

result=$(node --input-type=module - "${targets[0]}" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const target = process.argv[2];
const source = fs.readFileSync(target, "utf8");

const vulnerable = "const OPENAI_DUAL_ROUTE_MODEL_IDS = [\n\tOPENAI_GPT_6_ASTRA_MODEL_ID,\n\tOPENAI_GPT_61_SOL_MODEL_ID,\n\t...OPENAI_GPT_56_VARIANT_MODEL_IDS,";
const fixed = "const OPENAI_DUAL_ROUTE_MODEL_IDS = [\n\tOPENAI_GPT_6_ASTRA_MODEL_ID,\n\tOPENAI_GPT_61_SOL_MODEL_ID,\n\t\"gpt-6-sol\",\n\t\"gpt-6-luna\",\n\t...OPENAI_GPT_56_VARIANT_MODEL_IDS,";

const count = (haystack, needle) => haystack.split(needle).length - 1;
const state = { vulnerable: count(source, vulnerable), fixed: count(source, fixed) };

if (state.vulnerable === 0 && state.fixed === 1) {
  process.stdout.write("ALREADY");
  process.exit(0);
}
if (!(state.vulnerable === 1 && state.fixed === 0)) {
  console.error(`ERROR: gpt-6 route anchors drifted: ${JSON.stringify(state)}`);
  process.exit(1);
}

const stat = fs.statSync(target);
const temporary = path.join(path.dirname(target), `.hydra-gpt6-route-${process.pid}-${path.basename(target)}.tmp.js`);
try {
  fs.writeFileSync(temporary, source.replace(vulnerable, fixed), { mode: stat.mode });
  const syntax = spawnSync(process.execPath, ["--check", temporary], { encoding: "utf8" });
  if (syntax.status !== 0) {
    process.stderr.write(syntax.stderr || "ERROR: patched runtime failed syntax validation\n");
    throw new Error("patched runtime failed syntax validation");
  }
  fs.renameSync(temporary, target);
} finally {
  try { fs.unlinkSync(temporary); } catch {}
}
process.stdout.write("PATCHED");
NODE
)

case "$result" in
  PATCHED) echo "OK: gpt-6-sol/gpt-6-luna now have a ChatGPT-subscription route" ;;
  ALREADY) echo "SKIP: gpt-6 subscription route backport already patched" ;;
  *) echo "ERROR: unexpected patch result: $result" >&2; exit 1 ;;
esac

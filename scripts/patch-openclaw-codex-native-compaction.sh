#!/usr/bin/env bash
# Backport the openclaw 2026.7.2 Codex-native compaction fix onto the pinned
# 2026.7.1 runtime. Remove this patch after a staged upgrade verifies a release
# that contains the upstream behavior.
set -euo pipefail

DIST_DIR="${OPENCLAW_DIST_DIR:-/usr/lib/node_modules/openclaw/dist}"

if [ ! -d "$DIST_DIR" ]; then
  echo "ERROR: OpenClaw dist directory not found: $DIST_DIR" >&2
  exit 1
fi

mapfile -t targets < <(
  find "$DIST_DIR" -maxdepth 1 -type f -name 'cli-compaction-*.js' -print \
    | while IFS= read -r candidate; do
        grep -q 'isIntentionalNativeAutoCompactionSkip' "$candidate" && printf '%s\n' "$candidate"
      done
)

if [ "${#targets[@]}" -ne 1 ]; then
  echo "ERROR: expected exactly one Codex CLI compaction patch target in $DIST_DIR; found ${#targets[@]} (anchor drift)" >&2
  exit 1
fi

target="${targets[0]}"
result=$(node --input-type=module - "$target" <<'NODE'
import fs from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const target = process.argv[2];
const source = fs.readFileSync(target, "utf8");
const vulnerable = /^([ \t]*)if \(isIntentionalNativeAutoCompactionSkip\(result\)\) return \{\n\1\tcompacted: false,\n\1\tfallbackToContextEngine: true,\n\1\tfailureReason: CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON\n\1\};/gm;
const fixedMarker = 'log.info(`CLI native harness compaction skipped for ${params.provider}/${params.model}: ${CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON}`);';
const fixedAnchor = /^([ \t]*)if \(isIntentionalNativeAutoCompactionSkip\(result\)\) \{\n\1\tlog\.info\(`CLI native harness compaction skipped for \$\{params\.provider\}\/\$\{params\.model\}: \$\{CODEX_APP_SERVER_OWNS_AUTO_COMPACTION_REASON\}`\);\n\1\treturn \{ compacted: false \};\n\1\}/gm;
const vulnerableMatches = [...source.matchAll(vulnerable)];
const fixedMatches = [...source.matchAll(fixedAnchor)];
const markerCount = source.split(fixedMarker).length - 1;

if (fixedMatches.length === 1 && vulnerableMatches.length === 0 && markerCount === 1) {
  process.stdout.write("ALREADY");
  process.exit(0);
}

if (vulnerableMatches.length !== 1 || fixedMatches.length !== 0 || markerCount !== 0) {
  console.error(`ERROR: compaction anchors are vulnerable=${vulnerableMatches.length}, fixed=${fixedMatches.length}, markers=${markerCount}; expected 1/0/0 (anchor drift)`);
  process.exit(1);
}

const indent = vulnerableMatches[0][1];
const fixed = [
  `${indent}if (isIntentionalNativeAutoCompactionSkip(result)) {`,
  `${indent}\t${fixedMarker}`,
  `${indent}\treturn { compacted: false };`,
  `${indent}}`,
].join("\n");
const updated = source.replace(vulnerable, fixed);
if ([...updated.matchAll(fixedAnchor)].length !== 1 || [...updated.matchAll(vulnerable)].length !== 0) {
  console.error("ERROR: patched compaction block did not match the verified fixed shape");
  process.exit(1);
}
const stat = fs.statSync(target);
const temporary = path.join(path.dirname(target), `.hydra-codex-compaction-${process.pid}.tmp.js`);
try {
  fs.writeFileSync(temporary, updated, { mode: stat.mode });
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
  PATCHED) echo "OK: backported Codex-native automatic compaction behavior in $target" ;;
  ALREADY) echo "SKIP: Codex-native automatic compaction behavior already patched in $target" ;;
  *) echo "ERROR: unexpected patch result: $result" >&2; exit 1 ;;
esac

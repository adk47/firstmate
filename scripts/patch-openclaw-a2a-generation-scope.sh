#!/usr/bin/env bash
# Patch OpenClaw so the detached sessions_send announce flow escapes the
# prepared-model-runtime plugin generation scope (MUS-6707 root cause).
#
# Without this, `session:a2a-send` continuations inherit the generation scope of
# the turn that spawned them. When a config/plugin reload supersedes that
# generation, the announce turn fails with "prepared model runtime plugin
# generation was superseded", is silently dropped, and walks the fallback chain
# to OpenRouter (~118/day).
#
# Anchors (OpenClaw 2026.10.x, hashes change every release; resolved by glob):
#   sessions-spawn-tool-*.js:1278  runWithGatewayIndependentRootWorkContinuation(() => runWithoutOwnedSessionTranscriptWrites(() => runSessionsSendA2AFlow({
#   sessions-spawn-tool-*.js:1293  })), "session:a2a-send")
# Shape copied from drain-*.js:1042 (same fix shipped upstream for
# `session:followup-drain`): "Detached queue drains re-admit on the current
# generation, never a predecessor's scope."
#
# Idempotent, fail-closed, .bak + verify + restore. See MUS-6707 / MUS-6726.
set -euo pipefail

DIST_DIR="${OPENCLAW_DIST_DIR:-/usr/lib/node_modules/openclaw/dist}"
MARKER="runOutsidePreparedModelRuntimePluginGenerationScope"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "ERROR: OpenClaw dist directory not found: $DIST_DIR" >&2
  exit 1
fi

mapfile -t targets < <(find "$DIST_DIR" -maxdepth 1 -type f -name 'sessions-spawn-tool-*.js' | sort)
mapfile -t scopes < <(find "$DIST_DIR" -maxdepth 1 -type f -name 'prepared-model-runtime-generation-scope-*.js' | sort)

if [[ "${#targets[@]}" -ne 1 || "${#scopes[@]}" -ne 1 ]]; then
  echo "ERROR: expected one sessions-spawn-tool and one generation-scope file; found target=${#targets[@]} scope=${#scopes[@]}. OpenClaw version may have changed. Manual review needed." >&2
  exit 1
fi
target="${targets[0]}"
scope="${scopes[0]}"

if grep -q "$MARKER" "$target"; then
  echo "SKIP: a2a generation-scope patch already applied to $(basename "$target")"
  exit 0
fi

open_anchor='runWithGatewayIndependentRootWorkContinuation(() => runWithoutOwnedSessionTranscriptWrites(() => runSessionsSendA2AFlow({'
close_anchor='})), "session:a2a-send")'
for anchor in "$open_anchor" "$close_anchor"; do
  if [[ "$(grep -cF -- "$anchor" "$target")" -ne 1 ]]; then
    echo "ERROR: anchor not found exactly once in $(basename "$target"): $anchor. OpenClaw version may have changed. Manual review needed." >&2
    exit 1
  fi
done

# The scope module exports the function under a minified alias; read it, don't assume it.
alias_name=$(grep -oE "${MARKER} as [A-Za-z_\$][A-Za-z0-9_\$]*" "$scope" | awk '{print $3}' || true)
if [[ -z "$alias_name" ]]; then
  echo "ERROR: $(basename "$scope") no longer exports $MARKER. OpenClaw version may have changed. Manual review needed." >&2
  exit 1
fi
import_line="import { ${alias_name} as ${MARKER} } from \"./$(basename "$scope")\";"

cp -p "$target" "$target.bak"

restore() {
  echo "ERROR: $1; restoring $(basename "$target") from .bak" >&2
  cp -p "$target.bak" "$target"
  exit 1
}

tmp="${target%.js}.hydra-a2a-scope.tmp.js"
node --input-type=module - "$target" "$tmp" "$open_anchor" "$close_anchor" "$import_line" "$MARKER" <<'NODE' || { rm -f "$tmp"; restore "patch script failed"; }
import fs from "node:fs";
const [target, tmp, openAnchor, closeAnchor, importLine, marker] = process.argv.slice(2);
let src = fs.readFileSync(target, "utf8");
const firstImport = src.indexOf("import ");
if (firstImport !== 0) throw new Error("file does not start with an import");
src = src.replace(openAnchor, () => openAnchor.replace("runWithGatewayIndependentRootWorkContinuation(() => ", `runWithGatewayIndependentRootWorkContinuation(() => ${marker}(() => `));
src = src.replace(closeAnchor, () => `}))), "session:a2a-send")`);
src = `${importLine}\n${src}`;
fs.writeFileSync(tmp, src, { mode: fs.statSync(target).mode });
NODE

# Parse as an ESM module explicitly: plain `node --check file.js` can exit 0 on an
# import + invalid syntax (Node 22), which would ship unusable JS to the live gateway.
node --input-type=module --check < "$tmp" 2>/dev/null || { rm -f "$tmp"; restore "patched file failed node --check"; }
mv "$tmp" "$target"

# Verify: import once, wrapper once, still exactly one a2a-send label, and it parses.
if [[ "$(grep -c "$MARKER" "$target")" -ne 2 ]] \
  || [[ "$(grep -cF -- '"session:a2a-send"' "$target")" -ne 1 ]] \
  || [[ "$(grep -cF -- "$import_line" "$target")" -ne 1 ]] \
  || ! node --input-type=module --check < "$target" 2>/dev/null; then
  restore "post-patch verification failed"
fi

echo "OK: a2a announce flow now escapes the generation scope ($(basename "$target"); backup at $(basename "$target").bak)"

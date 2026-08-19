#!/usr/bin/env bash
# Backport a non-interrupting sessions.delete precondition onto OpenClaw 2026.7.1.
# Remove this patch after a staged runtime upgrade verifies native
# `requireInactive` support with the same lifecycle-lock semantics.
set -euo pipefail

DIST_DIR="${OPENCLAW_DIST_DIR:-/usr/lib/node_modules/openclaw/dist}"

if [[ ! -d "$DIST_DIR" ]]; then
  echo "ERROR: OpenClaw dist directory not found: $DIST_DIR" >&2
  exit 1
fi

mapfile -t schema_targets < <(
  find "$DIST_DIR" -maxdepth 1 -type f -name 'schema-*.js' -print \
    | while IFS= read -r candidate; do
        grep -q 'const SessionsDeleteParamsSchema = Type.Object({' "$candidate" && printf '%s\n' "$candidate"
      done
)
mapfile -t handler_targets < <(
  find "$DIST_DIR" -maxdepth 1 -type f -name 'sessions-*.js' -print \
    | while IFS= read -r candidate; do
        grep -q '"sessions.delete": async' "$candidate" && printf '%s\n' "$candidate"
      done
)

if [[ "${#schema_targets[@]}" -ne 1 || "${#handler_targets[@]}" -ne 1 ]]; then
  echo "ERROR: expected one schema and one sessions.delete patch target; found schema=${#schema_targets[@]} handler=${#handler_targets[@]} (anchor drift)" >&2
  exit 1
fi

result=$(node --input-type=module - "${schema_targets[0]}" "${handler_targets[0]}" <<'NODE'
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const schemaPath = process.argv[2];
const handlerPath = process.argv[3];
const schemaSource = fs.readFileSync(schemaPath, "utf8");
const handlerSource = fs.readFileSync(handlerPath, "utf8");

const schemaVulnerable = "\texpectedSessionUpdatedAt: Type.Optional(Type.Number({ minimum: 0 })),\n\temitLifecycleHooks: Type.Optional(Type.Boolean()),";
const schemaFixed = "\texpectedSessionUpdatedAt: Type.Optional(Type.Number({ minimum: 0 })),\n\trequireInactive: Type.Optional(Type.Boolean()),\n\temitLifecycleHooks: Type.Optional(Type.Boolean()),";
const handlerVulnerable = [
	"\t\t\t\texpectedSessionStillCurrent = !rejectExpectedSessionMismatch(loadSessionEntry(key, { agentId: requestedAgentId }).entry);",
	"\t\t\t\tif (!expectedSessionStillCurrent) return;",
	"\t\t\t\tadmittedWorkReleased = await interruptSessionWorkAdmissions({",
].join("\n");
const handlerFixed = [
	"\t\t\t\tconst currentDeleteEntry = loadSessionEntry(key, { agentId: requestedAgentId }).entry;",
	"\t\t\t\texpectedSessionStillCurrent = !rejectExpectedSessionMismatch(currentDeleteEntry);",
	"\t\t\t\tif (!expectedSessionStillCurrent) return;",
	"\t\t\t\tif (p.requireInactive === true && (isSessionWorkAdmissionActive(storePath, deleteLifecycleIdentities) || replyRunRegistry.isActive(target.canonicalKey ?? key) || replyRunRegistry.isActive(key) || hasVisibleActiveSessionRun({",
	"\t\t\t\t\tcontext,",
	"\t\t\t\t\trequestedKey: key,",
	"\t\t\t\t\tcanonicalKey: target.canonicalKey ?? key,",
	"\t\t\t\t\tsessionId: currentDeleteEntry?.sessionId,",
	"\t\t\t\t\tdefaultAgentId: resolveDefaultAgentId(cfg)",
	"\t\t\t\t}))) {",
	"\t\t\t\t\tadmittedWorkReleased = false;",
	"\t\t\t\t\treturn;",
	"\t\t\t\t}",
	"\t\t\t\tadmittedWorkReleased = await interruptSessionWorkAdmissions({",
].join("\n");

const count = (source, needle) => source.split(needle).length - 1;
const state = {
  schemaVulnerable: count(schemaSource, schemaVulnerable),
  schemaFixed: count(schemaSource, schemaFixed),
  handlerVulnerable: count(handlerSource, handlerVulnerable),
  handlerFixed: count(handlerSource, handlerFixed),
};

if (state.schemaVulnerable === 0 && state.schemaFixed === 1 && state.handlerVulnerable === 0 && state.handlerFixed === 1) {
  process.stdout.write("ALREADY");
  process.exit(0);
}
const freshInstall = state.schemaVulnerable === 1 && state.schemaFixed === 0 && state.handlerVulnerable === 1 && state.handlerFixed === 0;
const interruptedSafeInstall = state.schemaVulnerable === 1 && state.schemaFixed === 0 && state.handlerVulnerable === 0 && state.handlerFixed === 1;
if (!freshInstall && !interruptedSafeInstall) {
  console.error(`ERROR: inactive-delete anchors drifted: ${JSON.stringify(state)}`);
  process.exit(1);
}

// Install enforcement before exposing the new parameter in the public schema.
// If the process stops between renames, the next run completes the safe
// handler-fixed/schema-vulnerable state instead of rejecting it as drift.
const updates = [];
if (freshInstall) updates.push([handlerPath, handlerSource.replace(handlerVulnerable, handlerFixed)]);
updates.push([schemaPath, schemaSource.replace(schemaVulnerable, schemaFixed)]);
const temporaries = [];
try {
  for (const [target, source] of updates) {
    const stat = fs.statSync(target);
    const temporary = path.join(path.dirname(target), `.hydra-inactive-delete-${process.pid}-${path.basename(target)}.tmp.js`);
    fs.writeFileSync(temporary, source, { mode: stat.mode });
    temporaries.push([temporary, target]);
    const syntax = spawnSync(process.execPath, ["--check", temporary], { encoding: "utf8" });
    if (syntax.status !== 0) {
      process.stderr.write(syntax.stderr || "ERROR: patched runtime failed syntax validation\n");
      throw new Error("patched runtime failed syntax validation");
    }
  }
  for (const [temporary, target] of temporaries) fs.renameSync(temporary, target);
} finally {
  for (const [temporary] of temporaries) {
    try { fs.unlinkSync(temporary); } catch {}
  }
}
process.stdout.write("PATCHED");
NODE
)

case "$result" in
  PATCHED) echo "OK: added non-interrupting requireInactive session deletion" ;;
  ALREADY) echo "SKIP: inactive-session delete backport already patched" ;;
  *) echo "ERROR: unexpected patch result: $result" >&2; exit 1 ;;
esac

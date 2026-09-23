/**
 * Mtime-cached loader for Caroline's SOUL.md, fed to Jev v2 as
 * `agent_instructions` (jev-router.ts's buildJevStateV2). Unlike
 * caroline-inventory-loader.ts's checked-in-JSON loader (cached forever,
 * process lifetime), this file lives outside the plugin's own tree — on
 * edge/node-8 it's deployed to /opt/hydra/workspaces/support/SOUL.md by
 * scripts/deploy.sh's rsync (repo root -> DEPLOY_PATH), confirmed against
 * openclaw-edge.json's `agents.defaults.workspace` and channel.ts's
 * existing INTERCOM_MEDIA_WORKSPACE_DIR precedent ("on edge this is
 * /opt/hydra/workspaces/support"). A deploy can change its content without
 * a gateway restart, so this loader re-stats on every call and only
 * re-reads when mtime moved — "read once and cache it, with an mtime check
 * so a deploy updates it" per the coordinator's spec.
 *
 * Fail-soft: an unreadable path (missing file, permissions, ENOENT) returns
 * null rather than throwing — the caller (createJevTurnRunner) is expected
 * to fall back to v2-policy state and mark the shadow row accordingly. Logs
 * one warn per distinct unreadable path per process lifetime, not on every
 * call, to avoid flooding logs on a sustained outage.
 */
import { readFileSync, statSync } from "node:fs";

export const DEFAULT_AGENT_INSTRUCTIONS_PATH = "/opt/hydra/workspaces/support/SOUL.md";

interface CachedInstructions {
  path: string;
  mtimeMs: number;
  content: string;
}

let cached: CachedInstructions | null = null;
let warnedPaths = new Set<string>();

/**
 * Returns SOUL.md's current content, or null if it can't be read.
 * `path` overrides DEFAULT_AGENT_INSTRUCTIONS_PATH when provided
 * (jev.agentInstructionsPath in config).
 */
export function loadAgentInstructions(
  path: string | undefined,
  log?: { warn: (msg: string) => void },
): string | null {
  const resolvedPath = path && path.trim() !== "" ? path : DEFAULT_AGENT_INSTRUCTIONS_PATH;
  try {
    const stat = statSync(resolvedPath);
    if (cached && cached.path === resolvedPath && cached.mtimeMs === stat.mtimeMs) {
      return cached.content;
    }
    const content = readFileSync(resolvedPath, "utf8");
    cached = { path: resolvedPath, mtimeMs: stat.mtimeMs, content };
    return content;
  } catch (err) {
    if (!warnedPaths.has(resolvedPath)) {
      warnedPaths.add(resolvedPath);
      log?.warn(
        `[intercom:jev] agent instructions unreadable at ${resolvedPath}: ${err} — v2 falling back to v2-policy state`,
      );
    }
    return null;
  }
}

// Test-only: each test file wants a clean cache/warn-once state.
export function __resetAgentInstructionsCacheForTests(): void {
  cached = null;
  warnedPaths = new Set();
}

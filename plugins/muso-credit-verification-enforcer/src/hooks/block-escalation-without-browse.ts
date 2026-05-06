import { isCreditVerificationSession } from "../context.js";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

type BeforeToolCallEvent = {
  toolName: string;
  params: Record<string, unknown>;
  runId?: string;
  toolCallId?: string;
};

type ToolContext = {
  agentId?: string;
  sessionKey?: string;
  sessionId?: string;
  runId?: string;
  toolName: string;
  toolCallId?: string;
};

type BeforeToolCallResult = {
  params?: Record<string, unknown>;
  block?: boolean;
  blockReason?: string;
};

/**
 * Block per-credit escalation Slack posts that lack the per-profile evidence
 * floor — the agent must have actually opened **multiple Tier-1 sources** in
 * the current run window before claiming "unverifiable, please review."
 *
 * Why this exists (PR #232, 2026-04-30 → tightened in PR #233):
 *   Run 20260430-130332-c1f8f9 escalated 500/500 credits with exactly 1
 *   browser call across the entire run. Run 20260430-111343-1605a8 flagged
 *   460/460 the same way. The dispatcher's per-profile gate (PR #232,
 *   change 2) covers approve+flag, but escalations bypass the dispatcher
 *   entirely — they go straight through the MCP message tool. Without
 *   this hook, the existing OPERATIONAL_ALLOWLIST passes them through.
 *
 *   PR #232 added a >=1 session-wide browser-load threshold. PR #233
 *   raises that to >=2 distinct Tier-1 hostnames (matching the dispatcher's
 *   approve/flag quorum), so a single decorative browser call no longer
 *   satisfies the gate. Tier-1 hostnames are the same set the dispatcher
 *   counts: music.apple.com / musicbrainz.org / discogs.com /
 *   allmusic.com (with optional www. prefix). Spotify is excluded —
 *   the credits dialog is login-gated for headless browsers.
 *
 *   The SKILL's escalation template names the *profile name* (string), not
 *   the *profile id* (UUID), so a per-profile gate can't be enforced from
 *   the message body alone. Session-wide >=2 Tier-1 is the practical floor
 *   and still catches the documented failure mode (run-wide 1 browse).
 *
 * Resolution:
 *   - Session log discovery: same idiom as session-evidence.sh
 *     (search /root/.openclaw-{main,dev}/agents for recently-modified
 *      .jsonl files), but in-process to avoid 500× shell-out.
 *   - Run window: read OPS_RUNLOG_DIR/latest.txt → run_started.ts
 *     (matches resolve_run_started_ts in batch-verify-profile.sh).
 *   - JSONL parsing: pair toolCall (name=browser) with toolResult
 *     (not isError, non-empty content) — same definition session-
 *     evidence.sh's count_ok uses. URL host is extracted from
 *     toolCall.arguments.url and matched against the Tier-1 set.
 *
 * Failure modes:
 *   - Session log not findable (no recent .jsonl, no override) → fail
 *     OPEN. This is an infra/discovery problem, not a bypass signal,
 *     and we don't want a missing log file to break legitimate
 *     escalations during a hot-patch window.
 *   - Hook throws (file read error, JSONL malformed in unexpected way)
 *     → fail OPEN via the wrapping try/catch in index.ts.
 *
 * Bypass: CV_REQUIRED_PROFILE_BROWSE=0 (same env var as the dispatcher).
 */

const ESCALATION_SHAPE = /ESCALATION\s+[—\-]|please review\.\s*Reply\s*"approve"/i;

// Per-profile claim extraction. The SKILL escalation template emits a
// `Profile-ID: <uuid>` line (PR #233 follow-up); this PR extends it with
// `Credited-Name:`, `Track-Title:`, and `Roles:` lines so the hook can
// enforce a response-text per-profile floor. When all four are present,
// the hook checks that >=PER_PROFILE_TIER1_FLOOR distinct Tier-1 browser
// loads in the run window have response text containing the credited
// name AND either the track title or one of the role tokens (matches
// the runlog gate's rule — see lib/browser-evidence.sh). When the body
// lacks these lines, falls back to the older session-wide
// >=REQUIRED_TIER1_HOSTS floor so older-shape escalations stay blocked
// when run-wide investigation is missing, but escapes the per-profile
// bar (visible in audit because they lack the lines).
const PROFILE_ID_RE = /Profile-ID:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
const CREDITED_NAME_RE = /Credited-Name:\s*([^\r\n]+)/i;
const TRACK_TITLE_RE = /Track-Title:\s*([^\r\n]+)/i;
const ROLES_RE = /Roles?:\s*([^\r\n]+)/i;

const MESSAGE_TOOL_NAMES = new Set(["message", "slack_message", "send_message"]);

// Map agentId → the openclaw profile + agent dir its session logs live under.
// Operations agent runs on the main gateway. Used by resolveSessionLog() to
// scope discovery to the correct tree — mirrors browser-evidence-audit.sh's
// workspace-scoped session-search-root, but keyed on agentId (the audit
// keys on script path because it's invoked from within the workspace).
const AGENT_SESSION_DIRS: Record<string, string> = {
  operations: "/root/.openclaw-main/agents/operations/sessions",
};
// Fallback search root for legacy callers that don't supply agentId. Kept as
// the original net so older shapes still get blocked, just without the
// per-agent scoping guarantee.
const FALLBACK_SESSION_DIRS = [
  "/root/.openclaw-main/agents",
];
const SESSION_MAX_AGE_MIN = 10;

// Same Tier-1 host set the dispatcher uses (CV_TIER1_HOSTS in
// batch-verify-profile.sh). Match host against this list AFTER stripping
// optional www. prefix. When extending: update the dispatcher in lockstep.
// Spotify is NOT in this set — its credits dialog is login-gated for
// headless browsers (rows render as `-` for guests even with the
// "More options → View credits" click sequence), so loading Spotify
// produces no verifiable per-profile evidence.
const TIER1_HOSTS = new Set([
  "music.apple.com",
  "musicbrainz.org",
  "discogs.com",
  "allmusic.com",
]);

// Minimum distinct Tier-1 hostnames with successful browser loads required
// before any escalation post is allowed. Matches CV_REQUIRED_LOADS=2 in the
// dispatcher (same default; both can be overridden via env if we ever need
// to ramp temporarily). Read at CALL time, not import time, so a hot-tune
// of the env (without restarting the gateway) takes effect on the next call.
function getRequiredTier1Hosts(): number {
  const raw = process.env.CV_REQUIRED_LOADS;
  return raw && /^\d+$/.test(raw) ? Number(raw) : 2;
}

// Per-profile Tier-1 floor when Profile-ID is present in the body. Same
// value as getRequiredTier1Hosts() — but the count is gated on loads that
// demonstrably reference THIS profile (response text contains
// credited_name AND either track_title or one of the role tokens).
function getPerProfileTier1Floor(): number {
  return getRequiredTier1Hosts();
}

// Built per-call so CV_REQUIRED_LOADS overrides surface in the user-facing
// message — keeping the floor advertised in the body matches what the gate
// actually enforces at the same call site.
function buildBlockReason(floor: number): string {
  return (
    `🔍 ESCALATION posts require successful browser loads of at least ${floor}\n` +
    "distinct Tier-1 hosts (Apple Music / MusicBrainz / Discogs / AllMusic)\n" +
    "in the current run window. The session log shows fewer than that —\n" +
    "the agent has not gathered enough evidence to declare the credit\n" +
    "unverifiable.\n\n" +
    "Open the profile's primary Tier-1 page before posting the escalation:\n" +
    "  browser(https://musicbrainz.org/artist/<mbid>)\n" +
    "  browser(https://music.apple.com/<region>/artist/<id>)\n\n" +
    "Then load at least one more supporting Tier-1 source to ground the\n" +
    "unverifiable verdict in real evidence, and re-post the escalation. The\n" +
    "previous >=1-load floor was raised in PR #233 because a single decorative\n" +
    "browser call satisfied it without proving the agent actually investigated\n" +
    "(runs 20260430-111343-1605a8 / 20260430-130332-c1f8f9 each posted 460-500\n" +
    "decisions with 1 browser call across the entire run)."
  );
}

function extractText(params: Record<string, unknown>): string {
  if (typeof params.text === "string" && params.text.length > 0) return params.text;
  if (typeof params.body === "string" && params.body.length > 0) return params.body;
  if (typeof params.message === "string" && params.message.length > 0) return params.message;
  if (typeof params.markdown === "string" && params.markdown.length > 0) return params.markdown;
  return "";
}

function walkJsonl(dir: string, depth: number, cb: (p: string) => void): void {
  if (depth < 0) return;
  type DirentLike = { name: string; isDirectory(): boolean; isFile(): boolean };
  let entries: DirentLike[];
  try {
    entries = readdirSync(dir, { withFileTypes: true }) as unknown as DirentLike[];
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      walkJsonl(p, depth - 1, cb);
    } else if (e.isFile() && e.name.endsWith(".jsonl") && !e.name.endsWith(".trajectory.jsonl")) {
      // *.trajectory.jsonl is a run-summary metadata file (schemaVersion 1
      // with .data wrappers) emitted alongside the real message-stream
      // .jsonl. Skip it — no toolCall content there and it has a more
      // recent mtime so it would otherwise win the most-recently-modified
      // pick. Verified on hydra 2026-05-04.
      cb(p);
    }
  }
}

/**
 * Find the session JSONL whose evidence applies to this escalation post.
 *
 * Discovery order:
 *   1. CV_SESSION_LOG_OVERRIDE — explicit override (used by tests).
 *   2. agentId-scoped lookup — restricts the search to
 *      `/root/.openclaw-main/agents/<agentId>/sessions` instead of the
 *      whole `/root/.openclaw-main/agents/` tree. This excludes the other
 *      workspace agents that share the main gateway (ceo / cmo / etc.) so
 *      a stray non-operations log can't win the most-recently-modified
 *      contest. (Originally this also separated ops vs ops-dev; ops-dev
 *      has since been retired but the per-agent dir still narrows the
 *      search by ~10× on a busy gateway.)
 *      Within the scoped dir we prefer:
 *        a. a file whose basename or path contains `sessionKey` (exact
 *           per-session pin — the precise scope when openclaw names files
 *           after sessionKey),
 *        b. otherwise, the most-recently-modified .jsonl in the cutoff
 *           window (recoverable when sessionKey is absent or sanitized).
 *   3. Legacy fallback — when agentId is unknown (older runtime shapes),
 *      walk both profile trees and pick most-recent. Same behavior as
 *      before; preserved so unscoped callers still get blocked.
 */
function resolveSessionLog(
  agentId: string | undefined,
  sessionKey: string | undefined,
): string | undefined {
  const override = process.env.CV_SESSION_LOG_OVERRIDE;
  if (override) return existsSync(override) ? override : undefined;
  const cutoff = Date.now() - SESSION_MAX_AGE_MIN * 60 * 1000;

  const scopedRoot = agentId ? AGENT_SESSION_DIRS[agentId] : undefined;
  const roots = scopedRoot ? [scopedRoot] : FALLBACK_SESSION_DIRS;

  let bySessionKey: { path: string; mtime: number } | undefined;
  let latest: { path: string; mtime: number } | undefined;

  for (const root of roots) {
    if (!existsSync(root)) continue;
    walkJsonl(root, 3, (p) => {
      let mtime: number;
      try {
        mtime = statSync(p).mtimeMs;
      } catch {
        return;
      }
      if (mtime < cutoff) return;
      // Prefer a file whose path/basename contains the sessionKey verbatim —
      // openclaw's session storage typically names files after the session
      // identifier, so this is the precise per-session pin. We still apply
      // the mtime cutoff to skip stale persisted sessions.
      if (sessionKey && p.includes(sessionKey)) {
        if (!bySessionKey || mtime > bySessionKey.mtime) {
          bySessionKey = { path: p, mtime };
        }
      }
      if (!latest || mtime > latest.mtime) latest = { path: p, mtime };
    });
  }

  return bySessionKey?.path ?? latest?.path;
}

function resolveRunStartedTs(): string | undefined {
  const dir = process.env.OPS_RUNLOG_DIR;
  if (!dir) return undefined;
  const latestPath = join(dir, "latest.txt");
  if (!existsSync(latestPath)) return undefined;
  let runlogPath: string;
  try {
    runlogPath = readFileSync(latestPath, "utf-8").trim();
  } catch {
    return undefined;
  }
  if (!runlogPath || !existsSync(runlogPath)) return undefined;
  let content: string;
  try {
    content = readFileSync(runlogPath, "utf-8");
  } catch {
    return undefined;
  }
  for (const line of content.split("\n")) {
    if (!line) continue;
    try {
      const e = JSON.parse(line);
      if (e?.event === "run_started" && typeof e.ts === "string") return e.ts as string;
    } catch {
      /* ignore */
    }
  }
  return undefined;
}

function urlHost(url: string): string | undefined {
  try {
    const u = new URL(url);
    return u.hostname.replace(/^www\./, "");
  } catch {
    return undefined;
  }
}

/**
 * Stream the in-window successful browser loads with their hostname, URL, and
 * lowercased response text. The response text is the source of truth for the
 * per-profile claim-match gate (matches lib/browser-evidence.sh's rule).
 *
 * Returns chronological list of {host, url, textLc} for successful browser
 * loads (toolCall paired with non-error, non-empty toolResult).
 */
function listSuccessfulBrowserLoadsInRun(
  sessionLog: string,
  runStartedTs: string | undefined,
): Array<{ host: string; url: string; textLc: string }> {
  let content: string;
  try {
    content = readFileSync(sessionLog, "utf-8");
  } catch {
    return [];
  }
  const lines = content.split("\n");
  // Phase 1: toolCallId → {host, url} for browser calls in window.
  const browserCalls = new Map<string, { host: string; url: string }>();
  for (const line of lines) {
    if (!line) continue;
    let row: { timestamp?: string; message?: { content?: unknown } };
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof row !== "object" || row === null) continue;
    if (runStartedTs && typeof row.timestamp === "string" && row.timestamp < runStartedTs) {
      continue;
    }
    const items = row.message?.content;
    if (!Array.isArray(items)) continue;
    for (const it of items) {
      if (
        !it ||
        typeof it !== "object" ||
        (it as { type?: unknown }).type !== "toolCall" ||
        (it as { name?: unknown }).name !== "browser" ||
        typeof (it as { id?: unknown }).id !== "string"
      ) {
        continue;
      }
      const args = (it as { arguments?: unknown }).arguments;
      const url = args && typeof args === "object" ? (args as { url?: unknown }).url : undefined;
      if (typeof url !== "string" || url.length === 0) continue;
      const host = urlHost(url);
      if (!host) continue;
      browserCalls.set((it as { id: string }).id, { host, url });
    }
  }
  if (browserCalls.size === 0) return [];
  // Phase 2: emit chronologically with response text — in this codebase the
  // JSONL is written in append order, so file order is chronological. Walk
  // again and emit the pair when a successful toolResult matches one of our
  // calls.
  const ordered: Array<{ host: string; url: string; textLc: string }> = [];
  for (const line of lines) {
    if (!line) continue;
    let row: {
      timestamp?: string;
      message?: {
        role?: string;
        toolCallId?: string;
        isError?: boolean;
        content?: Array<{ text?: string }>;
      };
    };
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof row !== "object" || row === null) continue;
    if (runStartedTs && typeof row.timestamp === "string" && row.timestamp < runStartedTs) {
      continue;
    }
    const msg = row.message;
    if (!msg || msg.role !== "toolResult") continue;
    if (typeof msg.toolCallId !== "string") continue;
    const call = browserCalls.get(msg.toolCallId);
    if (!call) continue;
    if (msg.isError === true) continue;
    const text = (msg.content ?? [])
      .map((c) => (typeof c?.text === "string" ? c.text : ""))
      .join(" ");
    if (text.length === 0) continue;
    ordered.push({ host: call.host, url: call.url, textLc: text.toLowerCase() });
  }
  return ordered;
}

/**
 * Per-profile Tier-1 quorum: count distinct Tier-1 hosts whose successful
 * browser response text proves the claim — text contains credited_name AND
 * (text contains track_title OR text contains any role token). Same rule as
 * the runlog gate (lib/browser-evidence.sh) — keep them in lockstep.
 *
 * Returns the number of distinct Tier-1 hostnames satisfying the rule.
 * Returns 0 immediately if credited_name is empty (can't prove the claim
 * without the credited person's name).
 */
function countPerProfileTier1Hosts(
  loads: Array<{ host: string; url: string; textLc: string }>,
  credit: { creditedName: string; trackTitle: string; roles: string },
): number {
  const nameLc = credit.creditedName.trim().toLowerCase();
  if (nameLc.length === 0) return 0;
  const trackLc = credit.trackTitle.trim().toLowerCase();
  const roleTokens = credit.roles
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.length > 0);
  const matched = new Set<string>();
  for (const { host, textLc } of loads) {
    if (!TIER1_HOSTS.has(host)) continue;
    if (!textLc.includes(nameLc)) continue;
    const hasTrack = trackLc.length > 0 && textLc.includes(trackLc);
    const hasRole = roleTokens.some((t) => textLc.includes(t));
    if (hasTrack || hasRole) matched.add(host);
  }
  return matched.size;
}

/**
 * Count distinct Tier-1 hostnames with at least one successful browser load
 * in the current run window. Mirrors session-evidence.sh's count_ok semantics
 * (toolCall paired with non-error, non-empty toolResult), filtered to Tier-1
 * hosts only and deduped by hostname.
 *
 * Two-phase parse:
 *   Phase 1: build {toolCallId → hostname} for browser toolCalls in window
 *            whose URL host is in TIER1_HOSTS.
 *   Phase 2: for each toolResult in window matching one of those ids, if
 *            the result is not isError and has non-empty text, record the
 *            hostname as confirmed.
 * Returns the size of the confirmed-hostname Set.
 */
function countDistinctTier1HostsInRun(
  sessionLog: string,
  runStartedTs: string | undefined,
): number {
  let content: string;
  try {
    content = readFileSync(sessionLog, "utf-8");
  } catch {
    return 0;
  }
  const lines = content.split("\n");
  // Phase 1: toolCallId → Tier-1 hostname (filtered).
  const tier1Calls = new Map<string, string>();
  for (const line of lines) {
    if (!line) continue;
    let row: { timestamp?: string; message?: { content?: unknown } };
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof row !== "object" || row === null) continue;
    if (runStartedTs && typeof row.timestamp === "string" && row.timestamp < runStartedTs) {
      continue;
    }
    const items = row.message?.content;
    if (!Array.isArray(items)) continue;
    for (const it of items) {
      if (
        !it ||
        typeof it !== "object" ||
        (it as { type?: unknown }).type !== "toolCall" ||
        (it as { name?: unknown }).name !== "browser" ||
        typeof (it as { id?: unknown }).id !== "string"
      ) {
        continue;
      }
      const args = (it as { arguments?: unknown }).arguments;
      const url = args && typeof args === "object" ? (args as { url?: unknown }).url : undefined;
      if (typeof url !== "string" || url.length === 0) continue;
      const host = urlHost(url);
      if (!host || !TIER1_HOSTS.has(host)) continue;
      tier1Calls.set((it as { id: string }).id, host);
    }
  }
  if (tier1Calls.size === 0) return 0;
  // Phase 2: confirmed Tier-1 hosts (toolResult paired + successful + has text).
  const confirmedHosts = new Set<string>();
  for (const line of lines) {
    if (!line) continue;
    let row: {
      timestamp?: string;
      message?: {
        role?: string;
        toolCallId?: string;
        isError?: boolean;
        content?: Array<{ text?: string }>;
      };
    };
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof row !== "object" || row === null) continue;
    if (runStartedTs && typeof row.timestamp === "string" && row.timestamp < runStartedTs) {
      continue;
    }
    const msg = row.message;
    if (!msg || msg.role !== "toolResult") continue;
    if (typeof msg.toolCallId !== "string") continue;
    const host = tier1Calls.get(msg.toolCallId);
    if (!host) continue;
    if (msg.isError === true) continue;
    const text = (msg.content ?? [])
      .map((c) => (typeof c?.text === "string" ? c.text : ""))
      .join(" ");
    if (text.length === 0) continue;
    confirmedHosts.add(host);
  }
  return confirmedHosts.size;
}

export function blockEscalationWithoutBrowse(
  event: BeforeToolCallEvent,
  ctx: ToolContext,
): BeforeToolCallResult | undefined {
  if (!MESSAGE_TOOL_NAMES.has(event.toolName)) return undefined;
  if (!isCreditVerificationSession(ctx.sessionKey, ctx.runId, ctx.agentId)) {
    return undefined;
  }

  const text = extractText(event.params ?? {});
  if (text.length === 0) return undefined;
  if (!ESCALATION_SHAPE.test(text)) return undefined;

  // Test/debug bypass — same env var as the dispatcher's CV_REQUIRED_PROFILE_BROWSE.
  if (process.env.CV_REQUIRED_PROFILE_BROWSE === "0") return undefined;

  const sessionLog = resolveSessionLog(ctx.agentId, ctx.sessionKey);
  if (!sessionLog) {
    // Fail-OPEN on discovery failure: missing session log is an infra
    // issue (no recent activity, permissions, override misconfigured),
    // not a bypass signal. Block-unsanctioned-batch-message + the
    // dispatcher remain as backstops. Log so the breach is greppable —
    // silent fail-open + agent that finds a way to break discovery
    // would otherwise let all escalations through unnoticed.
    const scopedRoot = ctx.agentId ? AGENT_SESSION_DIRS[ctx.agentId] : undefined;
    const searched = scopedRoot ? [scopedRoot] : FALLBACK_SESSION_DIRS;
    console.warn(
      `[credit-verification-enforcer] WARN: escalation gate fail-OPEN — session log not discovered. ` +
        `agent=${ctx.agentId ?? "?"} session=${ctx.sessionKey ?? "?"} runId=${ctx.runId ?? "?"} ` +
        `searched=${searched.join(",")} cv_session_log_override=${process.env.CV_SESSION_LOG_OVERRIDE ?? "(unset)"}`,
    );
    return undefined;
  }

  const runStartedTs = resolveRunStartedTs();

  // Two-tier check:
  //   (1) If Profile-ID + Credited-Name lines are present, enforce per-profile
  //       claim-match floor — counts only Tier-1 loads whose response text
  //       proves the claim for THIS profile (matches lib/browser-evidence.sh).
  //   (2) Fallback: session-wide >=REQUIRED_TIER1_HOSTS distinct Tier-1.
  //       Older-shape escalations (no Profile-ID / Credited-Name lines) still
  //       need run-wide investigation but escape the per-profile bar.
  const profileMatch = text.match(PROFILE_ID_RE);
  const creditedNameMatch = text.match(CREDITED_NAME_RE);
  if (profileMatch && creditedNameMatch) {
    const profileId = profileMatch[1].toLowerCase();
    const creditedName = creditedNameMatch[1].trim();
    const trackTitle = text.match(TRACK_TITLE_RE)?.[1]?.trim() ?? "";
    const roles = text.match(ROLES_RE)?.[1]?.trim() ?? "";
    const loads = listSuccessfulBrowserLoadsInRun(sessionLog, runStartedTs);
    const perProfileCount = countPerProfileTier1Hosts(loads, {
      creditedName,
      trackTitle,
      roles,
    });
    const perProfileFloor = getPerProfileTier1Floor();
    if (perProfileCount >= perProfileFloor) return undefined;

    console.warn(
      `[credit-verification-enforcer] blocked escalation — per-profile Tier-1 claim-match floor not met. ` +
        `agent=${ctx.agentId ?? "?"} session=${ctx.sessionKey ?? "?"} runId=${ctx.runId ?? "?"} ` +
        `profileId=${profileId} creditedName="${creditedName}" trackTitle="${trackTitle}" roles="${roles}" ` +
        `perProfileTier1=${perProfileCount}/${perProfileFloor} ` +
        `runStartedTs=${runStartedTs ?? "(none)"} sessionLog=${sessionLog}`,
    );

    return {
      block: true,
      blockReason:
        buildBlockReason(perProfileFloor) +
        `\n\nPer-profile claim-match gate: the escalation body names\n` +
        `  Profile-ID:    ${profileId}\n` +
        `  Credited-Name: ${creditedName}\n` +
        `  Track-Title:   ${trackTitle || "<missing>"}\n` +
        `  Roles:         ${roles || "<missing>"}\n` +
        `but only ${perProfileCount}/${perProfileFloor} distinct Tier-1 hosts in this\n` +
        `run window have response text containing the credited name AND either\n` +
        `the track title or one of the role tokens.\n\n` +
        `Load Tier-1 pages and verify the response text shows the credited\n` +
        `person at the credit context (Apple Music / MusicBrainz /\n` +
        `Discogs / AllMusic). One investigation can't ground multiple\n` +
        `profiles' escalations — the agent must produce per-profile evidence.`,
    };
  }

  // Fallback: no Profile-ID line. Older session-wide floor still applies.
  const requiredHosts = getRequiredTier1Hosts();
  const count = countDistinctTier1HostsInRun(sessionLog, runStartedTs);
  if (count >= requiredHosts) return undefined;

  console.warn(
    `[credit-verification-enforcer] blocked escalation — session-wide Tier-1 floor not met (no Profile-ID line). ` +
      `agent=${ctx.agentId ?? "?"} session=${ctx.sessionKey ?? "?"} runId=${ctx.runId ?? "?"} ` +
      `runStartedTs=${runStartedTs ?? "(none)"} sessionLog=${sessionLog} ` +
      `tier1Hosts=${count}/${requiredHosts} text="${text.slice(0, 80)}…"`,
  );

  return { block: true, blockReason: buildBlockReason(requiredHosts) };
}

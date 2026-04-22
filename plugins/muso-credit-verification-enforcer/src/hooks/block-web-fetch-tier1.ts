import { isCreditVerificationSession } from "../context.js";

/** Local mirror of openclaw's `PluginHookBeforeToolCallEvent`. */
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
 * Tier 1 hosts for credit verification. Must stay in sync with CV_TIER1_HOSTS
 * in workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh
 * (the bash-layer approve gate) and the SKILL.md rendering.
 *
 * Stored as plain hostnames. Match is case-insensitive and tolerates a
 * leading `www.` prefix on the URL.
 */
const TIER1_HOSTS = [
  "open.spotify.com",
  "music.apple.com",
  "musicbrainz.org",
  "discogs.com",
  "allmusic.com",
  "tidal.com",
];

const BLOCK_REASON =
  "web_fetch is disabled on Tier 1 music-data hosts during credit verification.\n\n" +
  "Tier 1 sources (Spotify / Apple Music / MusicBrainz / Discogs / AllMusic /\n" +
  "Tidal) are JavaScript-rendered — web_fetch returns the raw HTML shell, not\n" +
  "the data the browser tool sees. Multiple credit-verification incidents have\n" +
  "involved web_fetch substituting for browser on these hosts, producing\n" +
  "'grounded' approvals based on empty or wrong data.\n\n" +
  "Use the `browser` tool instead:\n" +
  "  • browser open <url> → browser snapshot (reads rendered text)\n\n" +
  "The bash-layer approve gate (muso-admin-api.sh) will refuse the approve\n" +
  "if it sees any web_fetch call to these hosts in the session anyway —\n" +
  "this hook just shortens the feedback loop to the moment of the call.";

function extractHost(urlString: string): string | undefined {
  try {
    const parsed = new URL(urlString);
    return parsed.hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return undefined;
  }
}

export function blockWebFetchTier1(
  event: BeforeToolCallEvent,
  ctx: ToolContext,
): BeforeToolCallResult | undefined {
  if (event.toolName !== "web_fetch") return undefined;
  if (!isCreditVerificationSession(ctx.sessionKey, ctx.runId)) return undefined;

  const urlParam = event.params?.url;
  if (typeof urlParam !== "string" || urlParam.length === 0) return undefined;

  const host = extractHost(urlParam);
  if (!host) return undefined;
  if (!TIER1_HOSTS.includes(host)) return undefined;

  console.warn(
    `[credit-verification-enforcer] blocked web_fetch on Tier 1 host=${host} in session=${ctx.sessionKey}`,
  );

  return { block: true, blockReason: BLOCK_REASON };
}

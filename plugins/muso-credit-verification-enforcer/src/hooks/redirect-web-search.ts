import { isCreditVerificationSession } from "../context.js";

/** Local mirror of openclaw's `PluginHookBeforeToolCallEvent` — structural
 *  compatibility verified at the `api.on<"before_tool_call">` registration. */
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

const BLOCK_REASON =
  "web_search is disabled for credit verification on this gateway because the\n" +
  "DuckDuckGo backend is blocked by bot-detection (tracked in GH issue #107).\n\n" +
  "Use the `browser` tool to load a search engine URL directly:\n" +
  "  • https://duckduckgo.com/?q=<URL-encoded query>\n" +
  "  • https://www.bing.com/search?q=<URL-encoded query>\n" +
  "  • https://www.google.com/search?q=<URL-encoded query>\n\n" +
  "Then load each candidate URL with `browser` to verify content. Per\n" +
  "muso-ops-credit-verification SKILL.md Step 3 grounding rule, every source\n" +
  "cited in your verdict must come from a successful browser load this turn.";

export function redirectWebSearch(
  event: BeforeToolCallEvent,
  ctx: ToolContext,
): BeforeToolCallResult | undefined {
  if (event.toolName !== "web_search") return undefined;
  if (!isCreditVerificationSession(ctx.sessionKey, ctx.runId, ctx.agentId)) return undefined;

  console.warn(
    `[credit-verification-enforcer] blocked web_search agent=${ctx.agentId ?? "?"} session=${ctx.sessionKey ?? "?"} runId=${ctx.runId ?? "?"}; redirected to browser`,
  );

  return { block: true, blockReason: BLOCK_REASON };
}

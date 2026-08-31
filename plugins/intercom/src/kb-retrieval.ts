/**
 * Mandatory pre-retrieval RAG for the Intercom CS agent (Caroline).
 *
 * SOUL.md tells Caroline to search her knowledge base before answering; this is
 * the MECHANICAL guarantee. On every answer-bearing inbound, the handler runs a
 * KB-retrieval leg CONCURRENTLY with personalization enrichment (handler.ts), and
 * the top hits are injected as a delimited `[KNOWLEDGE_BASE]` block in
 * `buildAgentRawBody` BEFORE the model generates. Mirrors the fail-soft,
 * time-boxed contract of enrichment: any error / timeout / unavailable index
 * degrades to "no block" and the reply still goes out. Prose != enforcement.
 *
 * Retrieval transport is openclaw's in-process memory-search manager
 * (`getActiveMemorySearchManager`), which is cached per-agent (no cold start) and
 * runs in the gateway process, so this needs no `exec`, no CLI, no HTTP, and is
 * unaffected by `tools.deny:["exec"]`.
 *
 * minScore = 0 is DELIBERATE. Verified live: the natural-language query "what
 * happens to my founding member status if my payment fails" scores ~0.33 against
 * the exact answer chunk and is dropped to "No matches" by any non-trivial floor
 * (this is the Ton Cordero failure). We inject the top-K and let the model judge
 * relevance rather than risk injecting nothing.
 */

import { getActiveMemorySearchManager } from "openclaw/plugin-sdk/memory-host-search";
import { getRuntimeConfig } from "openclaw/plugin-sdk/runtime-config-snapshot";
import type { IntercomAccountConfig, IntercomSessionState, KbSnippet } from "./types.js";

export type { KbSnippet };

/** A retrieval backend: query -> ranked snippets. Injected so the orchestration is unit-testable. */
export type KbSearcher = (
  query: string,
  opts: { maxResults: number; minScore: number },
) => Promise<KbSnippet[]>;

export const DEFAULT_KB_TIMEOUT_MS = 1500;
export const DEFAULT_KB_MAX_RESULTS = 5;
export const DEFAULT_KB_MIN_SCORE = 0;
const DEFAULT_AGENT_ID = "support";

// Bare closers / acknowledgments that need no grounding (mirror of SOUL.md
// "Reading the room"). Kept as the single source of truth so the inbound
// skip-gate and the doctrine can't drift. Emoji are matched as-is.
export const INBOUND_CLOSERS: ReadonlySet<string> = new Set([
  "ok", "okay", "k", "kk", "thanks", "thank you", "thankyou", "ty", "tysm", "tyvm",
  "got it", "gotcha", "cool", "great", "perfect", "np", "no worries", "nw",
  "sounds good", "will do", "👍", "🙏", "👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿",
]);

/**
 * True when an inbound message needs no KB grounding: a bare closer/ack, or empty
 * (media-only turns reach the model with no text to ground). Intent-based, never
 * length-based: "refund?" / "founder?" are short but answer-bearing.
 */
export function isSkippableInbound(message: string): boolean {
  if (!message) return true;
  // Normalize: trim, lowercase, drop surrounding punctuation (keep letters/emoji).
  const norm = message.trim().toLowerCase().replace(/^[\s.,!?；;]+|[\s.,!?；;]+$/g, "").trim();
  if (norm.length === 0) return true;
  return INBOUND_CLOSERS.has(norm);
}

/**
 * Skip-gate + time-box + fail-open around a searcher. Returns [] (never throws)
 * on skip, error, or timeout, so a retrieval problem can never block or drop a
 * customer reply.
 */
export async function retrieveKbSnippets(
  message: string,
  searcher: KbSearcher,
  opts: { timeoutMs?: number; maxResults?: number; minScore?: number },
): Promise<KbSnippet[]> {
  if (isSkippableInbound(message)) return [];
  const timeoutMs = opts.timeoutMs ?? DEFAULT_KB_TIMEOUT_MS;
  const searchOpts = {
    maxResults: opts.maxResults ?? DEFAULT_KB_MAX_RESULTS,
    minScore: opts.minScore ?? DEFAULT_KB_MIN_SCORE,
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const timeout = new Promise<KbSnippet[]>((resolve) => {
      timer = setTimeout(() => resolve([]), timeoutMs);
    });
    const result = await Promise.race([searcher(message, searchOpts), timeout]);
    return Array.isArray(result) ? result : [];
  } catch {
    return [];
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/**
 * Render the injected `[KNOWLEDGE_BASE]` block. SNIPPET TEXT ONLY: never the path
 * or citation — SOUL forbids naming reference files to customers, and the
 * sanitizer bans filenames. Empty snippets -> empty string (no block).
 */
export function renderKnowledgeBaseBlock(snippets: KbSnippet[]): string {
  if (!snippets || snippets.length === 0) return "";
  const bullets = snippets
    .map((s) => `- ${s.snippet.replace(/\s+/g, " ").trim()}`)
    .filter((b) => b.length > 2);
  if (bullets.length === 0) return "";
  return [
    "[KNOWLEDGE_BASE] (verified Muso facts -- ground your answer in these; never quote filenames or IDs to the customer)",
    ...bullets,
    "[/KNOWLEDGE_BASE]",
  ].join("\n");
}

// Outbound regurgitation guard, mirroring stripConversationContext: a model that
// echoes the injected block must not leak it to the customer.
const KB_BLOCK_REGEX = /\[KNOWLEDGE_BASE\][\s\S]*?\[\/KNOWLEDGE_BASE\]\s*/g;
const KB_OPEN_LINE_REGEX = /^\[KNOWLEDGE_BASE\][^\n]*\n?/gm;

export function stripKnowledgeBase(
  reply: string,
  log?: { warn: (msg: string) => void },
  context?: { conversationId?: string },
): string {
  if (!reply.includes("[KNOWLEDGE_BASE]")) return reply;
  log?.warn?.(
    `[intercom] outbound stripped [KNOWLEDGE_BASE] regurgitation conv=${context?.conversationId ?? "?"} sample=${reply.slice(0, 200)}`,
  );
  return reply.replace(KB_BLOCK_REGEX, "").replace(KB_OPEN_LINE_REGEX, "").trim();
}

/**
 * Build the per-account KB retrieval hook, or undefined when disabled. Mirrors
 * buildEnrichFn: returns a fail-soft `(state, message) => Promise<void>` that
 * stores results on `state.kbSnippets` (and never rejects). The real searcher
 * uses the in-process cached memory-search manager for the support agent.
 */
export function buildKbRetrieveFn(
  account: IntercomAccountConfig,
  log?: { warn?: (m: string) => void; info?: (m: string) => void },
): ((state: IntercomSessionState, message: string) => Promise<void>) | undefined {
  const cfg = account.kbRetrieval;
  if (cfg?.enabled !== true) return undefined;
  const agentId = cfg.agentId ?? DEFAULT_AGENT_ID;

  const searcher: KbSearcher = async (query, searchOpts) => {
    const runtimeCfg = getRuntimeConfig();
    const { manager, error } = await getActiveMemorySearchManager({
      cfg: runtimeCfg,
      agentId,
      purpose: "default",
    });
    if (!manager) {
      log?.warn?.(`[intercom:kb] no memory-search manager for agent=${agentId}${error ? ` (${error})` : ""}`);
      return [];
    }
    const results = await manager.search(query, {
      maxResults: searchOpts.maxResults,
      minScore: searchOpts.minScore,
    });
    return (results ?? []).map((r) => ({ snippet: r.snippet, path: r.path, score: r.score }));
  };

  const retrieveOpts = {
    ...(typeof cfg.timeoutMs === "number" ? { timeoutMs: cfg.timeoutMs } : {}),
    ...(typeof cfg.maxResults === "number" ? { maxResults: cfg.maxResults } : {}),
    ...(typeof cfg.minScore === "number" ? { minScore: cfg.minScore } : {}),
  };

  return async (state, message) => {
    state.kbSnippets = await retrieveKbSnippets(message, searcher, retrieveOpts);
  };
}

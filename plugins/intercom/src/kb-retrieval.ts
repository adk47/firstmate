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
import { citationUrlForPath, isHelpCentrePath, loadHelpManifest, type HelpManifest } from "./help-manifest.js";
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

/** Max help-centre hits in one block; curated reference hits keep the remaining slots. */
export const HELP_CENTRE_MAX_SNIPPETS = 2;
/** Over-fetch factor so 60 help-centre files cannot crowd every curated hit out of the raw top-K. */
const KB_OVERFETCH = 4;
/** Window growth per extra pass when the previous window held no curated hit. */
const KB_WIDEN = 5;
/** Safety bound on extra passes (5 -> 20, 100, 500, 2500 hits); the shared time box also applies. */
const KB_MAX_WIDEN_PASSES = 4;

/** Map a raw memory-search hit to a KbSnippet; citationUrl comes from the manifest, never from snippet text. */
export function toKbSnippet(
  r: { snippet: string; path?: string; score?: number },
  manifest: HelpManifest | null,
): KbSnippet {
  const citationUrl = citationUrlForPath(r.path, manifest);
  return { snippet: r.snippet, path: r.path, score: r.score, ...(citationUrl ? { citationUrl } : {}) };
}

/**
 * Reserve slots: curated hits keep priority, help-centre hits are capped. Asks
 * the inner searcher for extra results (curated files can rank below many
 * help-centre chunks), then keeps curated in rank order and fills the rest with
 * at most HELP_CENTRE_MAX_SNIPPETS help-centre hits, total <= maxResults.
 */
export function withHelpCentreCap(inner: KbSearcher): KbSearcher {
  return async (query, opts) => {
    const fetchWindow = async (factor: number) => {
      const asked = opts.maxResults * factor;
      const all = await inner(query, { ...opts, maxResults: asked });
      return { all, truncated: all.length >= asked };
    };
    let factor = KB_OVERFETCH;
    let { all, truncated } = await fetchWindow(factor);
    // Help-centre keeps at most HELP_CENTRE_MAX_SNIPPETS slots, so once this many
    // curated hits are in hand more widening cannot change the output. The floor of 1
    // preserves the old behaviour when maxResults <= HELP_CENTRE_MAX_SNIPPETS.
    const curatedQuota = Math.max(1, opts.maxResults - HELP_CENTRE_MAX_SNIPPETS);
    const curatedCount = () => all.filter((s) => !isHelpCentrePath(s.path)).length;
    // A full window short of the curated quota may be hiding curated hits below many
    // help-centre chunks: keep widening until the quota is met or the corpus is exhausted.
    for (let pass = 0; pass < KB_MAX_WIDEN_PASSES && truncated && curatedCount() < curatedQuota; pass++) {
      factor *= KB_WIDEN;
      ({ all, truncated } = await fetchWindow(factor));
    }
    const curated = all.filter((s) => !isHelpCentrePath(s.path)).slice(0, opts.maxResults);
    const help = all
      .filter((s) => isHelpCentrePath(s.path))
      .slice(0, Math.min(HELP_CENTRE_MAX_SNIPPETS, opts.maxResults - curated.length));
    return [...curated, ...help];
  };
}

/**
 * Render the injected `[KNOWLEDGE_BASE]` block. Never the file path. The one
 * identifier the customer may see is a help-centre article link, handed over as
 * an explicit per-snippet field in a subordinate section. Empty snippets -> "".
 */
export function renderKnowledgeBaseBlock(snippets: KbSnippet[]): string {
  if (!snippets || snippets.length === 0) return "";
  const clean = (t: string) => t.replace(/\s+/g, " ").trim();
  const isHelp = (s: KbSnippet) => isHelpCentrePath(s.path) || !!s.citationUrl;
  const curated = snippets.filter((s) => !isHelp(s)).map((s) => `- ${clean(s.snippet)}`);
  const help = snippets
    .filter(isHelp)
    .map((s) => `- ${clean(s.snippet)}${s.citationUrl ? ` [article link: ${s.citationUrl}]` : ""}`);
  const bullets = [...curated, ...help].filter((b) => b.length > 2);
  if (bullets.length === 0) return "";
  const lines = [
    "[KNOWLEDGE_BASE] (verified Muso facts -- ground your answer in these; never quote filenames or IDs to the customer, except a help-centre article link given below)",
    ...curated.filter((b) => b.length > 2),
  ];
  const helpBullets = help.filter((b) => b.length > 2);
  if (helpBullets.length > 0) {
    lines.push(
      "Help-centre articles (supporting; the facts above win if they differ). If one clearly answers the question, you may close with one final line `More detail here: <article link>` using ONLY an article link shown here, exactly as written. Otherwise add no link:",
      ...helpBullets,
    );
  }
  lines.push("[/KNOWLEDGE_BASE]");
  return lines.join("\n");
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
    const manifest = loadHelpManifest();
    return (results ?? []).map((r) => toKbSnippet(r, manifest));
  };

  const retrieveOpts = {
    ...(typeof cfg.timeoutMs === "number" ? { timeoutMs: cfg.timeoutMs } : {}),
    ...(typeof cfg.maxResults === "number" ? { maxResults: cfg.maxResults } : {}),
    ...(typeof cfg.minScore === "number" ? { minScore: cfg.minScore } : {}),
  };

  return async (state, message) => {
    state.kbSnippets = await retrieveKbSnippets(message, withHelpCentreCap(searcher), retrieveOpts);
  };
}

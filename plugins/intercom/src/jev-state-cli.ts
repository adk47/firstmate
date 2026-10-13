/**
 * jev-state-cli.ts — state-parity CLI for the Jev eval harness
 * (scripts/jev-eval-build.sh / scripts/jev-eval-run.sh). Reads a JSON thread
 * on stdin and prints, on stdout, the EXACT `state` object
 * `buildJevState` (jev-router.ts) would send for one turn of that thread —
 * built from the same TS code the production router runs, never a Python
 * reimplementation.
 *
 * Input (stdin), one JSON object:
 *   {
 *     "parts": [{"author": "user"|"bot"|"admin"|<other>, "body": string, "created_at"?: number|string}, ...],
 *     "turn_index": <index into parts of the CUSTOMER turn to build state for>,
 *     "known_facts"?: {"founding"?: number, "plan"?: string,
 *                      "prior_chats"?: {"count": number, "most_recent_title"?: string, "most_recent_at"?: string}}
 *   }
 *
 * Usage:
 *   node dist/jev-state-cli.js --variant v1 < thread.json > state.json
 *
 * --variant selects a builder from VARIANTS (default "v1" — today's
 * buildJevState, byte-identical). A future `--variant v2-*` plugs in by
 * adding an entry to VARIANTS; nothing else in this file changes shape.
 *
 * Author mapping (production parity — see plugins/intercom/src/handler.ts's
 * buildRecentPartsFromLiveConversation, the ONLY place production turns raw
 * Intercom authors into buildJevState's `"user"|"bot"` roles):
 *   - author "user" | "lead" | "contact" -> "user" (Intercom customer author
 *     types — buildRecentPartsFromLiveConversation treats all three as the
 *     customer).
 *   - author "bot" -> "bot" (Caroline's own admin id in production; this
 *     harness format has no separate admin-id field, so a part must already
 *     be labelled "bot" by whatever built the thread to count as Caroline's
 *     own reply).
 *   - anything else (e.g. "admin") -> DROPPED, matching production's
 *     "other admins (human takeover replies) are deliberately excluded —
 *     Jev classifies Caroline's own turns, not a human agent's."
 *   - HTML tags are stripped the same way production strips them
 *     (`replace(/<[^>]*>/g, "").trim()`), even though harness threads are
 *     expected to already be plaintext (Intercom `display_as=plaintext`).
 *
 * KNOWN MISMATCH vs. production (documented, not silently papered over):
 * production's buildRecentPartsFromLiveConversation also filters on Intercom
 * `part_type === "comment"` (dropping internal notes / assignments / closes)
 * before it ever looks at author type. This harness's thread schema carries
 * no `part_type` field, so every part in `parts` is assumed to already be a
 * visible comment — the burden is on whatever builds the thread (Intercom
 * conversation ingestion in jev-eval-build.sh) to have dropped non-comment
 * parts before turn_index is computed. If that assumption is ever violated,
 * this CLI silently includes a part production would have excluded.
 *
 * `turn_count` mirrors production's `state.userTurnCount` (handler.ts): the
 * count of CUSTOMER-authored parts at indices 0..turn_index inclusive, not
 * the raw part index.
 */
import { readFileSync } from "node:fs";
import {
  buildJevState,
  buildJevStateV2,
  CLOSER_PHRASES,
  type BuildJevStateInput,
  type BuildJevStateV2Input,
  type JevV2Author,
} from "./jev-router.js";
import { loadCarolineToolCapabilities } from "./caroline-inventory-loader.js";

export interface JevStateCliPart {
  author: string;
  body: string;
  created_at?: number | string;
}

export interface JevStateCliKnownFacts {
  founding?: number;
  plan?: string;
  prior_chats?: { count: number; most_recent_title?: string; most_recent_at?: string };
}

export interface JevStateCliThread {
  parts: JevStateCliPart[];
  turn_index: number;
  known_facts?: JevStateCliKnownFacts;
}

const CUSTOMER_AUTHOR_TYPES = new Set(["user", "lead", "contact"]);

function stripHtml(body: string): string {
  return (body ?? "").replace(/<[^>]*>/g, "").trim();
}

// null = production drops this author entirely (see module doc).
function mapAuthor(author: string): "user" | "bot" | null {
  if (CUSTOMER_AUTHOR_TYPES.has(author)) return "user";
  if (author === "bot") return "bot";
  return null;
}

function assertThread(thread: unknown): asserts thread is JevStateCliThread {
  if (typeof thread !== "object" || thread === null) {
    throw new Error("input must be a JSON object");
  }
  const t = thread as Record<string, unknown>;
  if (!Array.isArray(t.parts)) {
    throw new Error("thread.parts must be an array");
  }
  if (!Number.isInteger(t.turn_index)) {
    throw new Error("thread.turn_index must be an integer");
  }
  const idx = t.turn_index as number;
  if (idx < 0 || idx >= (t.parts as unknown[]).length) {
    throw new Error(`thread.turn_index ${idx} out of range for ${(t.parts as unknown[]).length} parts`);
  }
}

function countCustomerTurnsThrough(parts: JevStateCliPart[], turnIndex: number): number {
  let n = 0;
  for (let i = 0; i <= turnIndex; i++) {
    if (CUSTOMER_AUTHOR_TYPES.has(parts[i].author)) n += 1;
  }
  return n;
}

/** v1 — today's production builder (jev-router.ts's buildJevState), applied
 * to the parts/turn_index/known_facts shape above. */
export function buildStateV1(thread: JevStateCliThread): Record<string, unknown> {
  assertThread(thread);
  const { parts, turn_index: turnIndex, known_facts: knownFacts } = thread;

  const current = parts[turnIndex];
  if (!CUSTOMER_AUTHOR_TYPES.has(current.author)) {
    throw new Error(
      `thread.turn_index ${turnIndex} does not point at a customer-authored part (author=${current.author})`,
    );
  }

  const recentParts = parts
    .slice(0, turnIndex)
    .map((p) => {
      const role = mapAuthor(p.author);
      if (!role) return null;
      const body = stripHtml(p.body);
      if (!body) return null;
      return { author: role, body };
    })
    .filter((p): p is { author: "user" | "bot"; body: string } => p !== null);

  const input: BuildJevStateInput = {
    message: stripHtml(current.body),
    recentParts,
    turnCount: countCustomerTurnsThrough(parts, turnIndex),
    founding: knownFacts?.founding,
    plan: knownFacts?.plan,
    priorChats: knownFacts?.prior_chats
      ? {
          count: knownFacts.prior_chats.count,
          mostRecentTitle: knownFacts.prior_chats.most_recent_title,
          mostRecentAt: knownFacts.prior_chats.most_recent_at,
        }
      : undefined,
  };
  return buildJevState(input);
}

// v2 author mapping (jev-router.ts's buildJevStateV2 / handler.ts's v2 parts
// builder): "user"|"lead"|"contact" -> customer (same Intercom customer
// author types as v1), "bot" -> caroline (Caroline's own admin id), "admin"
// -> human_agent (the whole point of v2: a human takeover reply is now
// VISIBLE to Jev instead of dropped, per the spec's bug (c)). Anything else
// is dropped, same as v1.
function mapAuthorV2(author: string): JevV2Author | null {
  if (CUSTOMER_AUTHOR_TYPES.has(author)) return "customer";
  if (author === "bot") return "caroline";
  if (author === "admin") return "human_agent";
  return null;
}

function buildV2Parts(parts: JevStateCliPart[]): { author: JevV2Author; body: string; createdAt?: number | string }[] {
  return parts
    .map((p) => {
      const role = mapAuthorV2(p.author);
      if (!role) return null;
      const body = stripHtml(p.body);
      if (!body) return null;
      return { author: role, body, ...(p.created_at !== undefined ? { createdAt: p.created_at } : {}) };
    })
    .filter((p): p is { author: JevV2Author; body: string; createdAt?: number | string } => p !== null);
}

interface V2BaseOptions {
  tools?: BuildJevStateV2Input["tools"];
  policy?: BuildJevStateV2Input["policy"];
  agentInstructions?: string;
}

function buildStateV2Base(thread: JevStateCliThread, opts: V2BaseOptions): Record<string, unknown> {
  assertThread(thread);
  const { parts, turn_index: turnIndex, known_facts: knownFacts } = thread;

  const current = parts[turnIndex];
  if (!CUSTOMER_AUTHOR_TYPES.has(current.author)) {
    throw new Error(
      `thread.turn_index ${turnIndex} does not point at a customer-authored part (author=${current.author})`,
    );
  }

  const recentParts = buildV2Parts(parts.slice(0, turnIndex));

  const input: BuildJevStateV2Input = {
    message: stripHtml(current.body),
    recentParts,
    turnCount: countCustomerTurnsThrough(parts, turnIndex),
    founding: knownFacts?.founding,
    plan: knownFacts?.plan,
    priorChats: knownFacts?.prior_chats
      ? {
          count: knownFacts.prior_chats.count,
          mostRecentTitle: knownFacts.prior_chats.most_recent_title,
          mostRecentAt: knownFacts.prior_chats.most_recent_at,
        }
      : undefined,
    tools: opts.tools,
    policy: opts.policy,
    agentInstructions: opts.agentInstructions,
  };
  return buildJevStateV2(input);
}

/** v2-min — v2 state shape, no tools/policy. */
export function buildStateV2Min(thread: JevStateCliThread): Record<string, unknown> {
  return buildStateV2Base(thread, {});
}

/** v2-policy — v2 state shape plus tools/policy from caroline-tool-capabilities.json. */
export function buildStateV2Policy(thread: JevStateCliThread): Record<string, unknown> {
  const capabilities = loadCarolineToolCapabilities();
  return buildStateV2Base(thread, {
    tools: capabilities?.tools,
    policy: capabilities?.policy,
  });
}

/**
 * v2-soul — v2-policy plus the full text of workspaces/support/SOUL.md as
 * `agent_instructions`, loaded from the path in env `JEV_SOUL_PATH`. Eval-only:
 * never used by the live router (nothing in handler.ts/channel.ts reads
 * JEV_SOUL_PATH). Throws if the env var is unset — a soul-less "v2-soul" run
 * would silently measure v2-policy instead, which is worse than failing loud.
 */
export function buildStateV2Soul(thread: JevStateCliThread): Record<string, unknown> {
  const soulPath = process.env.JEV_SOUL_PATH;
  if (!soulPath) {
    throw new Error("JEV_SOUL_PATH must be set to use --variant v2-soul");
  }
  const agentInstructions = readFileSync(soulPath, "utf8");
  const capabilities = loadCarolineToolCapabilities();
  return buildStateV2Base(thread, {
    tools: capabilities?.tools,
    policy: capabilities?.policy,
    agentInstructions,
  });
}

export type JevStateVariantBuilder = (thread: JevStateCliThread) => Record<string, unknown>;

// Variant -> builder map. Add a "v2-*" entry here to plug in a future
// builder; the CLI's --variant flag and buildState() below never change.
export const VARIANTS: Record<string, JevStateVariantBuilder> = {
  v1: buildStateV1,
  "v2-min": buildStateV2Min,
  "v2-policy": buildStateV2Policy,
  "v2-soul": buildStateV2Soul,
};

export function buildState(variant: string, thread: unknown): Record<string, unknown> {
  const builder = VARIANTS[variant];
  if (!builder) {
    throw new Error(`unknown --variant '${variant}' (known: ${Object.keys(VARIANTS).join(", ")})`);
  }
  assertThread(thread);
  return builder(thread);
}

// --- CLI entry (skipped when this module is imported by a test) ---

function readStdin(): Promise<string> {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let variant = "v1";
  let dumpCloserPhrases = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--variant") {
      variant = args[i + 1];
      i += 1;
    } else if (args[i] === "--dump-closer-phrases") {
      dumpCloserPhrases = true;
    } else {
      process.stderr.write(`jev-state-cli: unknown argument: ${args[i]}\n`);
      process.exit(2);
    }
  }

  // Reads nothing from stdin -- the eval harness (scripts/jev-eval-build.sh)
  // uses this to get production's exact closer-phrase list (jev-router.ts's
  // CLOSER_PHRASES) instead of hardcoding an independent copy (QA re-review
  // finding 4 on PR #1021).
  if (dumpCloserPhrases) {
    process.stdout.write(JSON.stringify([...CLOSER_PHRASES]) + "\n");
    return;
  }

  const raw = await readStdin();
  let thread: unknown;
  try {
    thread = JSON.parse(raw);
  } catch (err) {
    process.stderr.write(`jev-state-cli: stdin is not valid JSON: ${(err as Error).message}\n`);
    process.exit(2);
    return;
  }

  try {
    const state = buildState(variant, thread);
    process.stdout.write(JSON.stringify(state) + "\n");
  } catch (err) {
    process.stderr.write(`jev-state-cli: ${(err as Error).message}\n`);
    process.exit(2);
  }
}

// Run only when invoked directly (`node dist/jev-state-cli.js`), never on
// import — vitest imports buildState/buildStateV1/VARIANTS without wanting a
// stdin read to hang the test process.
const invokedDirectly =
  typeof process.argv[1] === "string" &&
  (process.argv[1].endsWith("jev-state-cli.js") || process.argv[1].endsWith("jev-state-cli.ts"));
if (invokedDirectly) {
  main();
}

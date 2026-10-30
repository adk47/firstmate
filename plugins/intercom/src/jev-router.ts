/**
 * Pure decision logic for the Jev pre-turn router
 * (docs/designs/2026-09-22-jev-caroline-router.md §B). Builds the Jev
 * `state` payload, decides an action from the returned `answers`, renders
 * the `[ROUTING]` block Caroline is instructed to follow, and formats both
 * the JudgeOutput shim (replaces the dead OpenRouter judge) and the
 * `[intercom:jev]` log line.
 *
 * `decide` is pure — no I/O, no clock reads beyond what's passed in — so it
 * is unit-testable without stubbing fetch. The HTTP call and the per-turn
 * "no second request" memoization live in `createJevTurnRunner` below,
 * which channel.ts constructs fresh once per webhook request and shares
 * between the Jev-backed judge (via buildRiskOptions) and the main routing
 * call in handler.ts.
 */
import { callJev, DEFAULT_JEV_MODEL, DEFAULT_JEV_TIMEOUT_MS } from "./jev-client.js";
import { loadCarolineQuestions, loadCarolineQuestionsV2, loadCarolineToolCapabilities } from "./caroline-inventory-loader.js";
import type { CarolineIntentMeta, CarolineSkillMeta } from "./caroline-inventory-loader.js";
import { loadAgentInstructions } from "./caroline-agent-instructions-loader.js";
import type { IntercomSessionState, RiskAssessment, RiskActionType } from "./types.js";
import { DEFAULT_JEV_ACTIONS } from "./types.js";
import type { JudgeInput, JudgeOutput } from "./escalation.js";

// --- Answer shapes (docs/designs/2026-09-22-jev-caroline-router.md; verified
// against scripts/tests/fixtures/jev/*.json) ---

export interface JevAnswerChoice {
  type: "choice";
  choice: string;
  probabilities?: Record<string, number>;
  confidence?: number;
}
export interface JevAnswerNoul {
  type: "noul";
  noul: number;
}
export interface JevAnswerScore {
  type: "score";
  score: number;
  legend?: Record<string, string>;
  probabilities?: Record<string, number>;
  confidence?: number;
}
export type JevAnswer = JevAnswerChoice | JevAnswerNoul | JevAnswerScore;
export type JevAnswers = Record<string, JevAnswer>;

export interface JevBands {
  bad_faith: number;
  no_reply: number;
  human_required: number;
}

export type JevAction = "route" | "decline" | "silence" | "escalate" | "none";

// Per-branch kill switches — see types.ts's DEFAULT_JEV_ACTIONS for the
// backtest rationale. Mirrors IntercomAccountConfig.jev.actions.
export interface JevActionsConfig {
  decline: boolean;
  silence: boolean;
  escalate: boolean;
}

export interface JevDecision {
  action: JevAction;
  block: string | null;
  escalation?: RiskAssessment;
  // Set when a band was hit but the branch's action is switched off in
  // config, so decide() returned `route` instead. Logged as
  // `suppressed=<branch>` on the [intercom:jev] line so
  // jev-shadow-report.sh can still count what it would have done.
  suppressed?: "silence" | "escalate";
}

// --- buildJevState ---

export interface BuildJevStateInput {
  message: string;
  recentParts?: { author: "user" | "bot"; body: string }[];
  turnCount: number;
  // known_facts inputs — all optional, all omitted from the payload when
  // absent. NOTE: the design doc's known_facts also lists
  // `subscription_status`; there is no corresponding field anywhere in this
  // plugin's types (KnownFacts / AccountSnapshot / EnrichmentState all lack
  // it — verified via `grep -rn "subscription_status\|subscriptionStatus"
  // src/*.ts`). Omitted here rather than guessed; flagged in the
  // implementer report as a spec gap.
  founding?: number;
  plan?: string;
  priorChats?: { count: number; mostRecentTitle?: string; mostRecentAt?: string };
}

const MAX_PARTS = 10;
const MAX_PART_CHARS = 500;

export function buildJevState(input: BuildJevStateInput): Record<string, unknown> {
  const lastParts = (input.recentParts ?? []).slice(-MAX_PARTS).map((p) => ({
    author: p.author,
    text: p.body.length > MAX_PART_CHARS ? p.body.slice(0, MAX_PART_CHARS) : p.body,
  }));
  const knownFacts: Record<string, unknown> = {};
  if (input.founding !== undefined) knownFacts.founding = input.founding;
  if (input.plan !== undefined) knownFacts.plan = input.plan;
  if (input.priorChats !== undefined) knownFacts.prior_chats = input.priorChats;

  return {
    message: input.message,
    last_parts: lastParts,
    turn_count: input.turnCount,
    ...(Object.keys(knownFacts).length > 0 ? { known_facts: knownFacts } : {}),
  };
}

// --- buildJevStateV2 ---
//
// v2 state adds three things v1 lacks (docs/designs/2026-09-22 misses,
// backfilled per the 2026-09-23 review of live Jev misses):
//   (a) agent_last_message — the most recent non-customer part (Caroline OR
//       a human agent), whoever it is, so the model can judge for itself
//       whether it asked the customer for something and whether the
//       customer's reply supplies it. Per TypeSafe's split (code supplies
//       facts, the model judges meaning), this deliberately carries no
//       code-side "did it ask a question" judgement — an earlier
//       keyword-gated `open_request`/`isOpenRequestShaped` rule was English-
//       only and missed the exact Spanish case that motivated it
//       ("Envíame el enlace..."), and it nulled the field whenever a human
//       agent (e.g. Jan) was last, discarding "thanks Jan, worked straight
//       away" as evidence. Replaced 2026-09-23 per coordinator review.
//   (b) a human_agent author, so a human takeover reply is visible to Jev
//       instead of silently dropped (v1's buildJevState has no author for
//       it at all — handler.ts's buildRecentPartsFromLiveConversation drops
//       those parts before v1 ever sees them).
//   (c) tools/policy carried on every call, so Jev can judge
//       resolution_path/tool_can_answer against Caroline's REAL declared
//       capabilities instead of inferring them from a CLI/HTTP string.

export type JevV2Author = "customer" | "caroline" | "human_agent";

export interface JevV2Part {
  author: JevV2Author;
  body: string;
  createdAt?: number | string;
}

export interface JevV2ToolCapability {
  name: string;
  answers: string[];
  cannot_answer: string[];
  needs: string;
}

export interface JevV2Policy {
  human_gated: string[];
  kb_topics: string[];
}

export interface BuildJevStateV2Input {
  message: string;
  recentParts?: JevV2Part[];
  turnCount: number;
  founding?: number;
  plan?: string;
  priorChats?: { count: number; mostRecentTitle?: string; mostRecentAt?: string };
  tools?: JevV2ToolCapability[];
  policy?: JevV2Policy;
  agentInstructions?: string;
}

const MAX_THREAD_PARTS = 12;
const MAX_THREAD_PART_CHARS = 1500;

export interface JevV2AgentLastMessage {
  author: "caroline" | "human_agent";
  text: string;
}

/**
 * Walks backward from the end of `recentParts` (which, like v1, excludes the
 * current customer message/burst) to find the most recent non-customer
 * part — Caroline's or a human agent's, whoever wrote it last. This is the
 * single "what did the agent side last say" fact; whether it asked the
 * customer for something is left to the model (supplying_requested_info),
 * not decided here. Returns null only when no agent has spoken yet in this
 * thread.
 */
function findAgentLastMessage(parts: JevV2Part[]): JevV2AgentLastMessage | null {
  for (let i = parts.length - 1; i >= 0; i--) {
    const part = parts[i];
    if (part.author === "caroline" || part.author === "human_agent") {
      return { author: part.author, text: part.body };
    }
  }
  return null;
}

export function buildJevStateV2(input: BuildJevStateV2Input): Record<string, unknown> {
  const parts = input.recentParts ?? [];

  const thread = parts.slice(-MAX_THREAD_PARTS).map((p) => ({
    author: p.author,
    text: p.body.length > MAX_THREAD_PART_CHARS ? p.body.slice(0, MAX_THREAD_PART_CHARS) : p.body,
  }));

  const agentLastMessage = findAgentLastMessage(parts);

  const knownFacts: Record<string, unknown> = {};
  if (input.founding !== undefined) knownFacts.founding = input.founding;
  if (input.plan !== undefined) knownFacts.plan = input.plan;
  if (input.priorChats !== undefined) knownFacts.prior_chats = input.priorChats;

  return {
    customer_last_message: input.message,
    agent_last_message: agentLastMessage,
    thread,
    turn_count: input.turnCount,
    ...(Object.keys(knownFacts).length > 0 ? { known_facts: knownFacts } : {}),
    tools: input.tools ?? [],
    policy: input.policy ?? { human_gated: [], kb_topics: [] },
    ...(input.agentInstructions !== undefined ? { agent_instructions: input.agentInstructions } : {}),
  };
}

// --- decide ---

const RISK_ACTION_TYPES: ReadonlySet<RiskActionType> = new Set<RiskActionType>([
  "subscription-refund",
  "data-deletion",
  "dispute",
  "support-general",
]);

// The inventory's `action_type_on_handoff` is a free-form per-intent string
// (design doc example: "credit-verify"), but RiskAssessment.suggestedActionType
// is the closed RiskActionType union that drives ClickUp's ticket actionType
// field. Any value outside that union falls back to "support-general" — the
// same fallback escalation-action.ts already applies to a missing
// suggestedActionType — rather than widening the union speculatively.
// Flagged in the implementer report as an unresolved spec conflict between
// the two workstreams.
function toRiskActionType(value: string | undefined): RiskActionType {
  if (value && (RISK_ACTION_TYPES as ReadonlySet<string>).has(value)) return value as RiskActionType;
  return "support-general";
}

function choiceProb(answer: JevAnswer | undefined, key: string): number {
  if (!answer || answer.type !== "choice") return 0;
  // Defense in depth (QA finding 2, 2026-09-22 PR #999): `in` throws on a
  // non-object RHS. `probabilities` is typed as an object, but this guards
  // against a value that bypassed jev-client's validation instead of
  // trusting the type at runtime.
  const probs = answer.probabilities;
  if (probs && typeof probs === "object" && key in probs) return probs[key];
  if (answer.choice === key) return answer.confidence ?? 1;
  return 0;
}

function noulValue(answer: JevAnswer | undefined): number {
  if (!answer || answer.type !== "noul") return 0;
  return answer.noul;
}

function findIntentMeta(answers: JevAnswers, intents: CarolineIntentMeta[]): CarolineIntentMeta | undefined {
  const intentAns = answers.intent;
  const intentName = intentAns?.type === "choice" ? intentAns.choice : undefined;
  if (!intentName) return undefined;
  return intents.find((i) => i.intent === intentName);
}

// Live-probe finding (2026-09-22, relayed by the coordinator mid-build): Jev's
// `intent` answer is strong (0.92-1.00 on real requests) but its `first_tool`
// answer is weak whenever several read tools overlap (observed: credits_search
// 0.38 instead of credit_verification_check for "credits not approved";
// profile_status instead of dedupe_check for "merge my two profiles"). The
// inventory's per-intent `first_read_tool` is a deterministic table lookup, so
// once `intent` itself is confident it is a better source than Jev's own,
// weaker `first_tool` choice. Same logic for `skill`, via the inventory's
// skill `tools_used` list. Both table lookups are skipped (falling back to
// Jev's own answer) when intent is "other", below threshold, or the inventory
// files aren't available yet (fail-soft — see caroline-inventory-loader.ts).
const INTENT_TABLE_CONFIDENCE_THRESHOLD = 0.6;

function intentChoiceAndProb(answers: JevAnswers): { intent: string | undefined; p: number } {
  const a = answers.intent;
  if (!a || a.type !== "choice") return { intent: undefined, p: 0 };
  return { intent: a.choice, p: a.confidence ?? a.probabilities?.[a.choice] ?? 0 };
}

// A skill "maps" to an intent when it's the ONE skill in the inventory whose
// tools_used includes that intent's first_read_tool or any of its write_tools.
// An ambiguous match (0 or 2+ skills) is not a table hit — falls back to Jev's
// own `skill` answer rather than guessing among several.
function findSkillForIntent(
  intentMeta: CarolineIntentMeta | undefined,
  skills: CarolineSkillMeta[],
): CarolineSkillMeta | undefined {
  if (!intentMeta) return undefined;
  const candidateTools = [intentMeta.first_read_tool, ...(intentMeta.write_tools ?? [])].filter(
    (t): t is string => typeof t === "string" && t.length > 0,
  );
  if (candidateTools.length === 0) return undefined;
  const matches = skills.filter((s) => (s.tools_used ?? []).some((t) => candidateTools.includes(t)));
  return matches.length === 1 ? matches[0] : undefined;
}

// Credit, document, claim and merge questions are hand-off only (captain 2026-10-28): for
// them the ticket IS the action, so "do not create a ticket" must never apply (QA on #1451).
const ROUTE_INSTRUCTIONS =
  "Follow this routing unless a tool result contradicts it. path=caroline_tool means: use\n" +
  "the tool, do not create a ticket, EXCEPT credit, document, claim and merge questions:\n" +
  "there the verification-handoff ticket IS the action, always file it. path=ask_customer\n" +
  "means: ask for exactly the one missing item, nothing else.";

// The design doc gives the decline block only as prose ("decline in one
// sentence, do not offer help, no ticket") rather than a literal quoted
// block. Rendered here as an instruction line, wrapped the same way as the
// route block. Flagged in the implementer report as an inferred literal.
const DECLINE_BLOCK = ["[ROUTING]", "decline in one sentence, do not offer help, no ticket", "[/ROUTING]"].join("\n");

// Defense in depth (QA finding 2, 2026-09-22 PR #999): callJev validates the
// nested answer shape before ever returning `ok: true`, but this formatter
// must independently never throw on an unexpected value — a future gap in
// that validation must not be able to abort a customer's turn. `p` is typed
// `number` for every real call site; the runtime guard exists purely for a
// value that bypassed jev-client's validation.
function fmt(p: number): string {
  return typeof p === "number" && Number.isFinite(p) ? p.toFixed(2) : "?";
}

// Real-conversation backtest finding (197 turns, relayed by the coordinator
// mid-build): Jev's `resolution_path.no_reply` alone is not a safe silence
// gate — on real data "Hi you got some news ?" scored no_reply 0.96 and "Ok
// but I don't received the email" scored 0.81, and silencing either would
// strand a waiting customer. `isCloserShaped` is the deterministic guard: a
// message only counts as a wrap-up (safe to go quiet on) when, after
// stripping signature lines/punctuation, it has no '?' and is either an
// exact match against SOUL.md's closer-word list (workspaces/support/SOUL.md
// "Acknowledge once, then go quiet", verbatim) or is three words or fewer.
// This guard applies ONLY to the no_reply silence branch below — the
// bad-faith decline-then-silence branch is unchanged.
// Exported (not just module-private) so jev-state-cli.ts's
// --dump-closer-phrases mode can hand the eval harness (scripts/
// jev-eval-build.sh) this exact list on request, instead of it hardcoding
// its own independent copy that can silently drift from production.
export const CLOSER_PHRASES = new Set([
  // Verbatim from workspaces/support/SOUL.md "Reading the room" (line ~62).
  "ok",
  "k",
  "thanks",
  "ty",
  "got it",
  "cool",
  "great",
  "perfect",
  "np",
  "no worries",
  "sounds good",
  "will do",
  "👍",
  "🙏",
  // Safe additions beyond SOUL's list — not in SOUL, added here because
  // they're unambiguous wrap-ups.
  "thank you",
  "thanks so much",
]);

const SIGNATURE_LINE_RE = /^(--\s*$|sent from |regards,?$|best,?$|cheers,?$)/i;

export function isCloserShaped(message: string): boolean {
  const lines = message
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !SIGNATURE_LINE_RE.test(l));
  const joined = lines.join(" ").trim();
  if (joined.length === 0) return false;
  if (joined.includes("?")) return false;

  // Punctuation-stripped but emoji-PRESERVED, so an exact phrase match can
  // still hit bare-emoji closers like "👍"/"🙏" (stripping emoji first would
  // reduce those to an empty string before the phrase check ever runs).
  const stripped = joined
    .replace(/[.,!;:()"'`~*_]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
  if (stripped.length === 0) return false;
  // EXACT phrase match only. There used to be a fallback treating any message
  // of three words or fewer as a closer; the Phase 1b hand-labelled set
  // (docs/designs/2026-09-22-jev-caroline-router.md) showed what it admits: a
  // customer writing "urgent" after an escalation scored no_reply 0.89, and a
  // bare profile link (one "word") scored 0.64. Both needed a reply, both
  // would have been silenced. Short is not the same as finished.
  return CLOSER_PHRASES.has(stripped);
}

function choiceLabelAndProb(answer: JevAnswer | undefined): { label: string; p: number } {
  if (!answer || answer.type !== "choice") return { label: "none", p: 0 };
  const p = answer.confidence ?? answer.probabilities?.[answer.choice] ?? 0;
  return { label: answer.choice, p };
}

// QA finding 3 (2026-09-22 PR #999), re-opened one band lower (MUS-1598):
// the `actions` kill switches stop the PLUGIN from taking an action, but the
// [ROUTING] block is advisory text Caroline is told to follow
// (workspaces/support/AGENTS.md), so naming a path the plugin declined to
// act on routes the action around the switch anyway. The original fix
// masked a label only while its action flag was off — but `renderRouteBlock`
// has exactly three call sites (all inside `decide()`), and every one of
// them is reached ONLY on a turn where the gated action did NOT fire (the
// two suppressed-branch early returns, and the plain fall-through below
// band — see the documented false positive "Hi you got some news ?": scores
// no_reply 0.97 but isn't closer-shaped, so it never reaches the
// suppressed-silence branch, and decide() never silenced it). A block that
// exists at all is therefore always a turn the gated action skipped, at ANY
// value of `actions` — so the `actions[branch] === true` escape hatch could
// never be correct: it just moved the leak from "action off" to "below
// band". Masking is now UNCONDITIONAL: a label in PATH_KILL_SWITCH is never
// named in a rendered block, full stop. Masked HERE, at the single choke
// point, so every call site is covered by construction rather than per-site.
const PATH_KILL_SWITCH: Record<string, keyof JevActionsConfig> = {
  no_reply: "silence",
  human_required: "escalate",
};

// `caroline_tool` / `ask_customer` (and the "none" placeholder for a missing
// answer) have no kill switch and are always allowed.
function isPathAllowed(label: string): boolean {
  return PATH_KILL_SWITCH[label] === undefined;
}

// Floor for a SUBSTITUTED path only. `resolution_path` has exactly four
// options (ask_customer, caroline_tool, human_required, no_reply — see
// caroline-questions.json), so the uniform prior is 0.25: a fallback scoring
// below that is not evidence for that path, it is noise the model
// effectively rejected. Since AGENTS.md tells Caroline to FOLLOW the block,
// handing her a 0.02 path is worse than handing her none, so below the floor
// the line is omitted. The floor deliberately does NOT apply to a top path
// the model actually chose and that is allowed — that is genuinely its
// answer at whatever confidence it carries, and flooring it away would
// suppress real routing signal.
const FALLBACK_PATH_MIN_PROB = 0.25;

/**
 * The `path:` line, or null when no allowed path can honestly be named.
 * When the top path is disabled we fall back to the highest-probability
 * ALLOWED entry in `probabilities`, rendered with ITS own probability — never
 * the disabled path's — and only when that probability clears
 * FALLBACK_PATH_MIN_PROB. When `probabilities` is absent, not a plain object,
 * holds no allowed numeric entry, or the best allowed entry is below the
 * floor, the line is OMITTED rather than invented: a wrong path is worse than
 * no path, and the block's other lines still carry the routing signal.
 */
function renderPathLine(answer: JevAnswer | undefined): string | null {
  const top = choiceLabelAndProb(answer);
  if (isPathAllowed(top.label)) return `path: ${top.label} (${fmt(top.p)})`;

  const probs = answer && answer.type === "choice" ? answer.probabilities : undefined;
  // Same defensive posture as choiceProb: `probabilities` is typed as an
  // object, but a value that bypassed jev-client's validation must degrade,
  // not throw. An array is "unusable" too — its numeric indices are not path
  // labels.
  if (!probs || typeof probs !== "object" || Array.isArray(probs)) return null;

  let best: { label: string; p: number } | undefined;
  for (const [label, p] of Object.entries(probs)) {
    if (!isPathAllowed(label)) continue;
    if (typeof p !== "number" || !Number.isFinite(p)) continue;
    if (!best || p > best.p) best = { label, p };
  }
  // `>=` so a fallback sitting exactly on the uniform prior is still named —
  // at the prior it is not yet evidence AGAINST the path.
  if (!best || best.p < FALLBACK_PATH_MIN_PROB) return null;
  return `path: ${best.label} (${fmt(best.p)})`;
}

// v2-only: resolution_path gains `answer_from_knowledge` and `acknowledge` options
// (`answer_from_knowledge` below)
// (caroline-questions.v2.json) with no analogue in v1 and no kill switch —
// it's a read from the KB, not an action decline()'s bands gate. When it's
// the top (allowed) path, the [ROUTING] block gets an explicit instruction
// telling Caroline to answer from memory_search rather than inventing a
// tool call, since none of the existing lines (first_tool/skill) apply.
// `acknowledge` (a first thanks, a goodbye, "are you a bot?") gets the same
// treatment: none of the tool/skill lines apply, so say so explicitly.
const V2_PATH_NOTES: Readonly<Record<string, string>> = {
  answer_from_knowledge: "path note: answer from the knowledge base (memory_search), no tool call needed.",
  acknowledge: "path note: a short courtesy reply is enough, no tool call or ticket needed.",
};

function v2PathNote(answer: JevAnswer | undefined): string | null {
  if (answer?.type !== "choice") return null;
  return Object.prototype.hasOwnProperty.call(V2_PATH_NOTES, answer.choice) ? V2_PATH_NOTES[answer.choice] : null;
}

// `actions` is still REQUIRED here (no default), even though the path mask
// below (`isPathAllowed`) no longer reads it — masking a PATH_KILL_SWITCH
// label is now unconditional, so there is no live branch left for `actions`
// to control. It stays on the signature anyway: every one of decide()'s
// three call sites already has its local `actions` binding in scope right
// next to the action-gating checks above it, and keeping the parameter
// required means a future call site still has to produce a real
// JevActionsConfig to compile, rather than this function quietly growing an
// implicit "no gate state available" caller. If a future kill-switched path
// genuinely needs conditional masking again, `actions` is already threaded
// through to `renderPathLine`'s call site here rather than needing to be
// re-plumbed from scratch.
function renderRouteBlock(
  answers: JevAnswers,
  intents: CarolineIntentMeta[],
  skills: CarolineSkillMeta[],
  actions: JevActionsConfig,
  questionsVersion: "v1" | "v2" = "v1",
): string {
  const pathLine = renderPathLine(answers.resolution_path);
  const answerFromKnowledgeLine = questionsVersion === "v2" ? v2PathNote(answers.resolution_path) : null;
  const intent = choiceLabelAndProb(answers.intent);

  const { intent: intentChoice, p: intentP } = intentChoiceAndProb(answers);
  const intentMeta = intentChoice && intentChoice !== "other" ? intents.find((i) => i.intent === intentChoice) : undefined;
  const confidentIntent = Boolean(intentMeta) && intentP >= INTENT_TABLE_CONFIDENCE_THRESHOLD;

  const toolLine =
    confidentIntent && intentMeta?.first_read_tool
      ? `first_tool: ${intentMeta.first_read_tool} (from intent)`
      : (() => {
          const tool = choiceLabelAndProb(answers.first_tool);
          return `first_tool: ${tool.label} (${fmt(tool.p)})`;
        })();

  const matchedSkill = confidentIntent ? findSkillForIntent(intentMeta, skills) : undefined;
  const skillLine = matchedSkill
    ? `skill: ${matchedSkill.name} (from intent)`
    : (() => {
        const skill = choiceLabelAndProb(answers.skill);
        return `skill: ${skill.label} (${fmt(skill.p)})`;
      })();

  return [
    "[ROUTING]",
    ...(pathLine ? [pathLine] : []),
    ...(answerFromKnowledgeLine ? [answerFromKnowledgeLine] : []),
    `intent: ${intent.label} (${fmt(intent.p)})`,
    toolLine,
    skillLine,
    ROUTE_INSTRUCTIONS,
    "[/ROUTING]",
  ].join("\n");
}

/**
 * decide — pure. `state` is read-only here (only `state.jev.badFaithDeclinedAt`
 * is inspected); the caller is responsible for writing the returned decision
 * back onto session state.
 *
 * `message` is the raw customer message that produced `answers` — used only
 * by the no_reply branch's `isCloserShaped` guard (see above).
 */
export function decide(
  answers: JevAnswers,
  bands: JevBands,
  message: string,
  state: Pick<IntercomSessionState, "jev"> | undefined,
  intents: CarolineIntentMeta[] = [],
  skills: CarolineSkillMeta[] = [],
  actions: JevActionsConfig = DEFAULT_JEV_ACTIONS,
  // v2-only. v1 callers never pass this, so v1's decisions are provably
  // unchanged — every branch below that reads it defaults to v1 behaviour.
  questionsVersion: "v1" | "v2" = "v1",
): JevDecision {
  // Gated on actions.decline as a whole — the once-per-conversation
  // decline-then-silence pair is "part of decline" (see DEFAULT_JEV_ACTIONS'
  // doc comment), so switching decline off disables both the first-hit
  // decline AND the follow-up silence, not just the first hit.
  if (actions.decline) {
    const badFaith = noulValue(answers.off_topic_or_bad_faith);
    if (badFaith >= bands.bad_faith) {
      const alreadyDeclined = Boolean(state?.jev?.badFaithDeclinedAt);
      if (!alreadyDeclined) {
        return { action: "decline", block: DECLINE_BLOCK };
      }
      return { action: "silence", block: null };
    }
  }

  // v2 override: if Jev is confident the customer is supplying something
  // agent_last_message asked for, that is by definition not a no-reply/
  // closer message — never silence it, no matter what resolution_path/
  // no_reply scored. v1 never reads supplying_requested_info
  // (the question doesn't exist in caroline-questions.json), so this is a
  // no-op for v1 callers.
  const supplyingRequestedInfo = questionsVersion === "v2" ? noulValue(answers.supplying_requested_info) : 0;
  const isSupplyingRequestedInfo = questionsVersion === "v2" && supplyingRequestedInfo >= 0.5;

  const noReplyP = choiceProb(answers.resolution_path, "no_reply");
  if (!isSupplyingRequestedInfo && noReplyP >= bands.no_reply && isCloserShaped(message)) {
    if (!actions.silence) {
      return {
        action: "route",
        block: renderRouteBlock(answers, intents, skills, actions, questionsVersion),
        suppressed: "silence",
      };
    }
    return { action: "silence", block: null };
  }

  const resolutionPath = answers.resolution_path;
  const isHumanRequiredChoice = resolutionPath?.type === "choice" && resolutionPath.choice === "human_required";
  const humanRequiredP = choiceProb(resolutionPath, "human_required");
  if (isHumanRequiredChoice && humanRequiredP >= bands.human_required) {
    if (!actions.escalate) {
      return {
        action: "route",
        block: renderRouteBlock(answers, intents, skills, actions, questionsVersion),
        suppressed: "escalate",
      };
    }
    const intentMeta = findIntentMeta(answers, intents);
    return {
      action: "escalate",
      block: null,
      escalation: {
        triggered: true,
        source: "judge",
        reason: "jev:human_required",
        suggestedActionType: toRiskActionType(intentMeta?.action_type_on_handoff),
        confidence: humanRequiredP >= 0.9 ? "high" : "medium",
      },
    };
  }

  return { action: "route", block: renderRouteBlock(answers, intents, skills, actions, questionsVersion) };
}

/**
 * renderJevBlock — the accessor channel.ts's buildAgentRawBody calls to pull
 * the block string out of persisted session state. Gated on action so a
 * stale state.jev from an earlier turn (e.g. after an escalate/silence turn
 * overwrote it, or before it's ever been set) never renders.
 */
export function renderJevBlock(jev: IntercomSessionState["jev"] | undefined): string | null {
  if (!jev) return null;
  if (jev.action !== "route" && jev.action !== "decline") return null;
  return jev.block ?? null;
}

// --- toJudgeOutput (replaces the OpenRouter judge in buildRiskOptions) ---

export function toJudgeOutput(answers: JevAnswers, bands: JevBands, intents: CarolineIntentMeta[] = []): JudgeOutput {
  const humanRequiredP = choiceProb(answers.resolution_path, "human_required");
  const shouldHandoff = humanRequiredP >= bands.human_required;
  const intentMeta = findIntentMeta(answers, intents);
  return {
    shouldHandoff,
    reasons: shouldHandoff ? ["human_required"] : [],
    suggestedActionType: toRiskActionType(shouldHandoff ? intentMeta?.action_type_on_handoff : undefined),
    confidence: humanRequiredP >= 0.9 ? "high" : shouldHandoff ? "medium" : "low",
  };
}

// --- log line ---

function choiceField(answer: JevAnswer | undefined): string {
  const { label, p } = choiceLabelAndProb(answer);
  return `${label}:${fmt(p)}`;
}

function scoreField(answer: JevAnswer | undefined): string {
  if (!answer || answer.type !== "score") return "unknown:0.00";
  // score is continuous (see jev-client's validator); label it by the
  // nearest level so the log reads "Frustrated:0.88", not "2.12:0.88".
  const key = Number.isFinite(answer.score) ? String(Math.round(answer.score)) : String(answer.score);
  const label = answer.legend?.[key] ?? key;
  const p = answer.confidence ?? answer.probabilities?.[key] ?? 0;
  return `${label}:${fmt(p)}`;
}

export function formatJevLogLine(input: {
  conversationId: string;
  action: JevAction;
  answers: JevAnswers | null;
  latencyMs: number;
  // Set when a band was hit but the branch's action was switched off in
  // config (decide() returned `route` instead) — see JevDecision.suppressed.
  // Appended only when present so the line format is unchanged otherwise.
  suppressed?: "silence" | "escalate";
}): string {
  const answers: JevAnswers = input.answers ?? {};
  const humanP = choiceProb(answers.resolution_path, "human_required");
  const base =
    `[intercom:jev] conv=${input.conversationId} action=${input.action} ` +
    `path=${choiceField(answers.resolution_path)} intent=${choiceField(answers.intent)} ` +
    `tool=${choiceField(answers.first_tool)} skill=${choiceField(answers.skill)} ` +
    `bad_faith=${fmt(noulValue(answers.off_topic_or_bad_faith))} human=${fmt(humanP)} ` +
    `frustration=${scoreField(answers.frustration)} ms=${input.latencyMs}`;
  return input.suppressed ? `${base} suppressed=${input.suppressed}` : base;
}

// --- per-turn runner (real I/O; the "no second request" memoization) ---

export interface JevTurnInput {
  message: string;
  turnCount: number;
  recentParts?: { author: "user" | "bot"; body: string }[];
  founding?: number;
  plan?: string;
  priorChats?: { count: number; mostRecentTitle?: string; mostRecentAt?: string };
  // v2-only. Used instead of `recentParts` when the runner is configured
  // with questionsVersion "v2" (see JevRunnerConfig) — carries the
  // human_agent author v1's shape has no room for.
  recentPartsV2?: JevV2Part[];
}

export interface JevTurnResult {
  ok: true;
  answers: JevAnswers;
  latencyMs: number;
  // Carried through only so the caller (handler.ts) can append the
  // best-effort shadow-log row (jev-shadow-log.ts) once it also knows the
  // `actual` action `decide()` picked — the runner itself has no visibility
  // into that decision.
  model: string;
  usage: unknown;
  httpStatus: number;
  state: Record<string, unknown>;
  questions: Record<string, unknown>;
  // v2-only. "v2-soul" when SOUL.md was read successfully this call,
  // "v2-policy-fallback" when it was unreadable and buildJevStateV2 ran
  // without agent_instructions. Undefined on every v1 call — never sent,
  // per spec, so a v1 row's state_variant stays absent rather than "v1".
  stateVariant?: string;
}

// A failed turn — timeout/network/http/shape from callJev, or the questions
// inventory being unavailable (never reaches callJev at all, so httpStatus
// is null). Carried all the way to handler.ts so it can still append a
// failure shadow row (jev.sh-shape: rc=2 for timeout/network/http, rc=3 for
// shape — handler.ts maps `reason === "shape"` to 3, everything else
// including "questions_unavailable" to 2) while the turn proceeds exactly
// as today (handler.ts branches on `.ok`, never on `=== null`).
export interface JevTurnFailure {
  ok: false;
  reason: string;
  httpStatus: number | null;
  latencyMs: number;
  // The payload the failed call carried, so the failure shadow row hashes the
  // REAL state/questions instead of sha256("{}"). Absent only on
  // "questions_unavailable", which fails before either exists.
  state?: unknown;
  questions?: unknown;
  model?: string;
  // See JevTurnResult.stateVariant — set even on a failed call, since the
  // SOUL.md read (success or fallback) happens before callJev, independent
  // of whether the HTTP call itself later fails.
  stateVariant?: string;
}

export type JevTurnOutcome = JevTurnResult | JevTurnFailure;

export interface JevRunnerConfig {
  apiKey: string;
  model?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
  // Default "v1". "v2" swaps in buildJevStateV2 + caroline-questions.v2.json
  // (with tools/policy from caroline-tool-capabilities.json) instead of the
  // v1 state/questions — everything else about the runner (memoization,
  // timeout, shape) is unchanged.
  questionsVersion?: "v1" | "v2";
  // v2-only. Absolute path to Caroline's SOUL.md, read (mtime-cached) and
  // sent as agent_instructions on every v2 call. Defaults to
  // DEFAULT_AGENT_INSTRUCTIONS_PATH (caroline-agent-instructions-loader.js)
  // when omitted. Never consulted on a v1 call.
  agentInstructionsPath?: string;
}

/**
 * Creates a memoized per-turn Jev caller: the FIRST invocation (from
 * whichever consumer runs first — the Jev-backed judge inside
 * buildRiskOptions, gated on turn count, or the unconditional post-enrichment
 * call in handler.ts) makes the HTTP call; every later invocation within the
 * same webhook request reuses that same in-flight/settled promise, so at
 * most one Jev call happens per turn regardless of how many consumers ask
 * for it. Callers must construct a FRESH runner per webhook request (channel.ts
 * does this inside the per-request handler, alongside buildRiskOptions) —
 * a runner shared across requests would wrongly memoize across turns.
 */
export function createJevTurnRunner(
  cfg: JevRunnerConfig,
  log?: { warn: (msg: string) => void },
): (input: JevTurnInput) => Promise<JevTurnOutcome> {
  let cached: Promise<JevTurnOutcome> | undefined;
  return (input: JevTurnInput) => {
    if (!cached) {
      cached = (async (): Promise<JevTurnOutcome> => {
        const isV2 = cfg.questionsVersion === "v2";
        const questions = isV2 ? loadCarolineQuestionsV2(log) : loadCarolineQuestions(log);
        if (!questions) {
          return { ok: false, reason: "questions_unavailable", httpStatus: null, latencyMs: 0 };
        }
        // v2-only: never invoked on a v1 call, so v1 never pays the stat()
        // cost and v1 state can never carry agent_instructions (buildJevState's
        // input has no such field to begin with — see BuildJevStateInput).
        let stateVariant: string | undefined;
        const state = isV2
          ? (() => {
              const capabilities = loadCarolineToolCapabilities(log);
              const agentInstructions = loadAgentInstructions(cfg.agentInstructionsPath, log);
              stateVariant = agentInstructions !== null ? "v2-soul" : "v2-policy-fallback";
              return buildJevStateV2({
                message: input.message,
                recentParts: input.recentPartsV2 ?? [],
                turnCount: input.turnCount,
                founding: input.founding,
                plan: input.plan,
                priorChats: input.priorChats,
                tools: capabilities?.tools,
                policy: capabilities?.policy,
                ...(agentInstructions !== null ? { agentInstructions } : {}),
              });
            })()
          : buildJevState({
              message: input.message,
              recentParts: input.recentParts,
              turnCount: input.turnCount,
              founding: input.founding,
              plan: input.plan,
              priorChats: input.priorChats,
            });
        const result = await callJev({
          apiKey: cfg.apiKey,
          model: cfg.model ?? DEFAULT_JEV_MODEL,
          timeoutMs: cfg.timeoutMs ?? DEFAULT_JEV_TIMEOUT_MS,
          state,
          questions,
          fetchImpl: cfg.fetchImpl,
          log,
        });
        if (!result.ok) {
          return {
            ok: false,
            reason: result.reason,
            httpStatus: result.httpStatus,
            latencyMs: result.latencyMs,
            state,
            questions,
            model: cfg.model ?? DEFAULT_JEV_MODEL,
            ...(stateVariant !== undefined ? { stateVariant } : {}),
          };
        }
        return {
          ok: true,
          answers: result.answers as JevAnswers,
          latencyMs: result.latencyMs,
          model: result.model,
          usage: result.usage,
          httpStatus: result.httpStatus,
          state,
          questions,
          ...(stateVariant !== undefined ? { stateVariant } : {}),
        };
      })();
    }
    return cached;
  };
}

/**
 * Wraps a per-turn runner as the OpenRouter judge replacement wired into
 * buildRiskOptions when `account.jev.enabled`. `JudgeInput` carries no
 * conversationId/turnCount (see escalation.ts's `deps.judge` call site), so
 * those are captured by the caller via `turnCountOf` at construction time —
 * channel.ts builds this once per webhook request, when the real per-request
 * `state` is already in scope.
 *
 * `actions.escalate` gates this exactly like it gates decide()'s escalate
 * branch (docs/designs/2026-09-22-jev-caroline-router.md Finding 1): with
 * escalate off, this always resolves `null` (no handoff) rather than ever
 * computing `shouldHandoff:true` from `toJudgeOutput` — the judge path must
 * not be able to escalate through a kill switch that decide() itself honors.
 * channel.ts additionally skips installing this judge at all when escalate
 * is off (belt and braces); this in-function gate is the load-bearing one.
 */
export function createJevBackedJudge(
  runner: (input: JevTurnInput) => Promise<JevTurnOutcome>,
  bands: JevBands,
  turnCountOf: () => number,
  intents: CarolineIntentMeta[],
  actions: JevActionsConfig = DEFAULT_JEV_ACTIONS,
): (input: JudgeInput) => Promise<JudgeOutput | null> {
  return async (input: JudgeInput): Promise<JudgeOutput | null> => {
    if (!actions.escalate) return null;
    // QA NO-GO on #1022 (finding 2): this runner is the SAME memoized
    // instance handler.ts later calls via runJev (buildRiskOptions's doc
    // comment above). recentPartsV2 must ride along here too, or a v2-
    // configured runner that fires from THIS call first permanently caches
    // a state built from an empty thread (createJevTurnRunner's "no second
    // request" memoization never re-derives state from a later call).
    const result = await runner({
      message: input.currentMessage,
      turnCount: turnCountOf(),
      recentParts: input.recentParts,
      recentPartsV2: input.recentPartsV2,
    });
    if (!result.ok) return null;
    return toJudgeOutput(result.answers, bands, intents);
  };
}

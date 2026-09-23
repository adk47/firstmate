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
import { loadCarolineQuestions } from "./caroline-inventory-loader.js";
import type { CarolineIntentMeta, CarolineSkillMeta } from "./caroline-inventory-loader.js";
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

const ROUTE_INSTRUCTIONS =
  "Follow this routing unless a tool result contradicts it. path=caroline_tool means: use\n" +
  "the tool, do not create a ticket. path=ask_customer means: ask for exactly the one\n" +
  "missing item, nothing else.";

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
const CLOSER_PHRASES = new Set([
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

// QA finding 3 (2026-09-22 PR #999): the `actions` kill switches stop the
// PLUGIN from taking an action, but the [ROUTING] block is advisory text
// Caroline is told to follow (workspaces/support/AGENTS.md), so naming a
// path whose action is switched off routes the action around the switch —
// `path: no_reply (0.97)` with `actions.silence=false` still gets Caroline
// to emit [[NO_REPLY]]. All three of decide()'s renderRouteBlock call sites
// leaked it, including the plain fall-through (the documented false
// positive "Hi you got some news ?" scores no_reply 0.97 but is not
// closer-shaped, so it never reaches the suppressed-silence branch at all).
// Masked HERE, at the single choke point, so every call site is covered by
// construction rather than per-site.
const PATH_KILL_SWITCH: Record<string, keyof JevActionsConfig> = {
  no_reply: "silence",
  human_required: "escalate",
};

// `caroline_tool` / `ask_customer` (and the "none" placeholder for a missing
// answer) have no kill switch and are always allowed.
function isPathAllowed(label: string, actions: JevActionsConfig): boolean {
  const branch = PATH_KILL_SWITCH[label];
  return branch === undefined || actions[branch] === true;
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
function renderPathLine(answer: JevAnswer | undefined, actions: JevActionsConfig): string | null {
  const top = choiceLabelAndProb(answer);
  if (isPathAllowed(top.label, actions)) return `path: ${top.label} (${fmt(top.p)})`;

  const probs = answer && answer.type === "choice" ? answer.probabilities : undefined;
  // Same defensive posture as choiceProb: `probabilities` is typed as an
  // object, but a value that bypassed jev-client's validation must degrade,
  // not throw. An array is "unusable" too — its numeric indices are not path
  // labels.
  if (!probs || typeof probs !== "object" || Array.isArray(probs)) return null;

  let best: { label: string; p: number } | undefined;
  for (const [label, p] of Object.entries(probs)) {
    if (!isPathAllowed(label, actions)) continue;
    if (typeof p !== "number" || !Number.isFinite(p)) continue;
    if (!best || p > best.p) best = { label, p };
  }
  // `>=` so a fallback sitting exactly on the uniform prior is still named —
  // at the prior it is not yet evidence AGAINST the path.
  if (!best || best.p < FALLBACK_PATH_MIN_PROB) return null;
  return `path: ${best.label} (${fmt(best.p)})`;
}

// `actions` is deliberately REQUIRED (no default): a new call site that
// cannot supply it must fail to compile rather than silently render an
// unmasked block. decide()'s own `actions` parameter carries the restrictive
// DEFAULT_JEV_ACTIONS default (silence/escalate off).
function renderRouteBlock(
  answers: JevAnswers,
  intents: CarolineIntentMeta[],
  skills: CarolineSkillMeta[],
  actions: JevActionsConfig,
): string {
  const pathLine = renderPathLine(answers.resolution_path, actions);
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

  const noReplyP = choiceProb(answers.resolution_path, "no_reply");
  if (noReplyP >= bands.no_reply && isCloserShaped(message)) {
    if (!actions.silence) {
      return { action: "route", block: renderRouteBlock(answers, intents, skills, actions), suppressed: "silence" };
    }
    return { action: "silence", block: null };
  }

  const resolutionPath = answers.resolution_path;
  const isHumanRequiredChoice = resolutionPath?.type === "choice" && resolutionPath.choice === "human_required";
  const humanRequiredP = choiceProb(resolutionPath, "human_required");
  if (isHumanRequiredChoice && humanRequiredP >= bands.human_required) {
    if (!actions.escalate) {
      return { action: "route", block: renderRouteBlock(answers, intents, skills, actions), suppressed: "escalate" };
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

  return { action: "route", block: renderRouteBlock(answers, intents, skills, actions) };
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
}

export type JevTurnOutcome = JevTurnResult | JevTurnFailure;

export interface JevRunnerConfig {
  apiKey: string;
  model?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
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
        const questions = loadCarolineQuestions(log);
        if (!questions) {
          return { ok: false, reason: "questions_unavailable", httpStatus: null, latencyMs: 0 };
        }
        const state = buildJevState({
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
          return { ok: false, reason: result.reason, httpStatus: result.httpStatus, latencyMs: result.latencyMs };
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
    const result = await runner({
      message: input.currentMessage,
      turnCount: turnCountOf(),
      recentParts: input.recentParts,
    });
    if (!result.ok) return null;
    return toJudgeOutput(result.answers, bands, intents);
  };
}

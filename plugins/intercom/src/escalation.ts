import type {
  EscalationResult,
  IntercomSessionState,
  RiskAssessment,
  RiskActionType,
} from "./types.js";
import { DEFAULT_JUDGE_MIN_TURNS, DEFAULT_TURN_HARD_CAP } from "./types.js";
// Type-only, so this is safe against jev-router.ts's own type-only import of
// JudgeInput/JudgeOutput from this file (erased at compile time — no runtime
// cycle). QA NO-GO on #1022 (finding 2): the risk judge needs the v2 parts
// too, not just v1's recentParts — see JudgeInput.recentPartsV2 below.
import type { JevV2Part } from "./jev-router.js";

// Layer 0: Magic-keyword consent — explicit "talk to a human" requests.
const MAGIC_KEYWORD_PATTERNS: RegExp[] = [
  /\btalk to a (human|person|real|agent)\b/i,
  /\bi want a human\b/i,
  /\bhuman please\b/i,
  /\breal person\b/i,
  /\bspeak to (someone|a person)\b/i,
  /\bagent please\b/i,
];

function checkMagicKeyword(message: string): boolean {
  return MAGIC_KEYWORD_PATTERNS.some((p) => p.test(message));
}

// Layer 1: Content-pattern rules. Each rule maps to a `reason` and a
// `suggestedActionType` that drive the ClickUp ticket's actionType field.
interface RiskRule {
  reason: string;
  actionType: RiskActionType;
  patterns: RegExp[];
}

const RISK_RULES: RiskRule[] = [
  {
    // Dispute-grade billing signals ONLY. Plain "refund" / "money back" /
    // "cancel my subscription" deliberately do NOT rule-escalate: commit 7484ade
    // removed "refund" from the legacy triggers so exit intents flow to the agent,
    // and the refund-retention skill (PRs #649/#657) runs a 3-gate save flow that
    // creates the subscription-refund action-request itself once retention is
    // exhausted. Reintroducing those keywords here (PR #238) pre-empted that skill
    // on its own triggers — a founding member's "Please cancel my subscription"
    // was handed off 3s after arrival with zero save attempt (conv
    // 215475695183812, 2026-08-28). Do not add them back; the safety nets for a
    // mishandled exit are the magic keywords, the turn-count cap, and the judge.
    reason: "refund_intent",
    actionType: "subscription-refund",
    patterns: [
      /\bchargeback\b/i,
      /\bbilling dispute\b/i,
      /\binvoice dispute\b/i,
      /\bunauthorized charge\b/i,
    ],
  },
  {
    // Account closure/deletion — NOT subscription cancellation, which the retention
    // skill owns (see above). data-deletion is the same tier (3) as subscription-refund,
    // so SLA and priority are unchanged; it is the ticket LABEL ops triages on that would
    // otherwise read "[refund]" for a request that is nothing of the sort.
    reason: "cancel_intent",
    actionType: "data-deletion",
    patterns: [
      /\bclose\s+(my )?account\b/i,
      /\bdelete\s+(my )?account\b/i,
    ],
  },
  {
    reason: "fraud_complaint",
    actionType: "dispute",
    patterns: [
      /\bfraud(?:ulent)?\b/i,
      /\brip[ -]?off\b/i,
      /\bscam\b/i,
      /\breport (you|this) to\b/i,
      /\bbbb\b/i,
      /\bbetter business bureau\b/i,
    ],
  },
  {
    reason: "public_shaming_intent",
    actionType: "support-general",
    // Standalone platform names (youtube/twitter/etc.) match routine product
    // questions in a music-credits product ("my YouTube credits aren't showing"),
    // so platform names must be paired with a shaming verb to fire.
    patterns: [
      /\btell\s+(everyone|my friends|everybody|the world)\b/i,
      /\bsocial media\b/i,
      /\b(post|share|expose|blast|review|rant|warn)\b[^.]{0,40}\b(youtube|twitter|x\.com|instagram|tiktok|facebook|reddit)\b/i,
      /\b(youtube|twitter|x\.com|instagram|tiktok|facebook|reddit)\b[^.]{0,40}\b(post|share|expose|blast|review|rant|warn)\b/i,
      /\bscorched earth\b/i,
      /\bgoing public\b/i,
    ],
  },
  {
    reason: "legal_threat",
    actionType: "dispute",
    patterns: [
      /\blawyer\b/i,
      /\battorney\b/i,
      /\blawsuit\b/i,
      /\bsue\b/i,
      /\bcourt\b/i,
      /\bsubpoena\b/i,
      /\blegal action\b/i,
      /\blegal threat\b/i,
    ],
  },
  {
    reason: "security_incident",
    actionType: "support-general",
    patterns: [
      /\bhacked\b/i,
      /\bcompromised\b/i,
      /\bunauthorized access\b/i,
      /\bstolen account\b/i,
      /\bpassword breach\b/i,
    ],
  },
  {
    reason: "abuse_report",
    actionType: "support-general",
    patterns: [
      /\bharassment\b/i,
      /\babuse report\b/i,
      /\bthreatening\b/i,
      /\bphishing\b/i,
    ],
  },
];

// Observability: one [intercom:judge] journal line per judge invocation (or
// per turn where the judge was reachable but not invoked), so we can tell
// "never trips" from "silently times out" from the edge journal alone. Never
// carries message content — only the fixed key=value fields below.
// The reason vocabulary the judge prompt asks for (judge.ts). Kept here as the
// log-side allowlist so a free-text reason can never reach the journal.
const JUDGE_REASONS: ReadonlySet<string> = new Set([
  "frustration",
  "repeated_question",
  "stuck_in_loop",
  "refund_intent",
  "cancel_intent",
  "public_shaming_intent",
  "ambiguous",
]);

function logJudgeSkip(
  log: AssessRiskDeps["log"],
  conversationId: string | undefined,
  reason: "min_turns" | "hard_cap" | "rule_escalated" | "disabled",
): void {
  log?.warn?.(`[intercom:judge] conv=${conversationId ?? "?"} outcome=skipped reason=${reason}`);
}

function logJudgeOutcome(
  log: AssessRiskDeps["log"],
  conversationId: string | undefined,
  outcome: "verdict" | "null" | "error",
  out: JudgeOutput | null | undefined,
  ms: number,
): void {
  const shouldHandoff = out ? String(out.shouldHandoff) : "-";
  const confidence = out ? out.confidence : "-";
  const actionType = out ? out.suggestedActionType : "-";
  // The judge validates `reasons` only as string[]; the model is asked for the
  // fixed tokens in JUDGE_REASONS but nothing stops it echoing customer text.
  // Log only known tokens; anything else collapses to a single `unknown`.
  const known = out ? out.reasons.filter((r) => JUDGE_REASONS.has(r)) : [];
  const unknownCount = out ? out.reasons.length - known.length : 0;
  const reasonTokens = unknownCount > 0 ? [...known, "unknown"] : known;
  const reasons = reasonTokens.length ? reasonTokens.join(",") : "-";
  log?.warn?.(
    `[intercom:judge] conv=${conversationId ?? "?"} outcome=${outcome} shouldHandoff=${shouldHandoff} ` +
    `confidence=${confidence} actionType=${actionType} reasons=${reasons} ms=${Math.round(ms)}`,
  );
}

function checkRules(message: string): { reason: string; actionType: RiskActionType; matched: string } | null {
  for (const rule of RISK_RULES) {
    for (const p of rule.patterns) {
      if (p.test(message)) {
        return { reason: rule.reason, actionType: rule.actionType, matched: p.source };
      }
    }
  }
  return null;
}

// Legacy rules — frozen verbatim from the pre-PR ESCALATION_RULES so behavior
// when riskAssessment.enabled=false is byte-identical to baseline. The new
// broadened rules above (RISK_RULES) only fire on the new path. Delete this
// block AND the legacy export below once riskAssessment.enabled is true on all
// profiles and one week of clean traffic has elapsed.
interface LegacyEscalationRule {
  category: string;
  patterns: RegExp[];
}

const LEGACY_ESCALATION_RULES: LegacyEscalationRule[] = [
  {
    category: "billing",
    patterns: [
      /\bchargeback\b/i,
      /\bbilling dispute\b/i,
      /\binvoice dispute\b/i,
      /\bpayment failed\b/i,
      /\bunauthorized charge\b/i,
    ],
  },
  {
    category: "legal",
    patterns: [
      /\blawyer\b/i,
      /\battorney\b/i,
      /\blawsuit\b/i,
      /\bsue\b/i,
      /\bcourt\b/i,
      /\bsubpoena\b/i,
      /\blegal action\b/i,
      /\blegal threat\b/i,
    ],
  },
  {
    category: "security",
    patterns: [
      /\bhacked\b/i,
      /\bcompromised\b/i,
      /\bunauthorized access\b/i,
      /\bstolen account\b/i,
      /\bpassword breach\b/i,
    ],
  },
  {
    category: "abuse",
    patterns: [
      /\bharassment\b/i,
      /\babuse report\b/i,
      /\bthreatening\b/i,
      /\bphishing\b/i,
    ],
  },
];

export function checkEscalation(message: string): EscalationResult {
  if (!message) return { triggered: false };
  for (const rule of LEGACY_ESCALATION_RULES) {
    for (const pattern of rule.patterns) {
      if (pattern.test(message)) {
        return { triggered: true, category: rule.category, matchedPattern: pattern.source };
      }
    }
  }
  return { triggered: false };
}

export interface AssessRiskDeps {
  judge?: (input: JudgeInput) => Promise<JudgeOutput | null>;
  judgeMinTurnCount?: number;
  turnCountHardCap?: number;
  log?: { warn: (msg: string) => void };
}

export interface JudgeInput {
  knownFacts: import("./types.js").KnownFacts;
  recentParts: { author: "user" | "bot"; body: string }[];
  currentMessage: string;
  // v2 twin of recentParts, mirroring JevTurnInput.recentPartsV2 (jev-router.ts).
  // QA NO-GO on #1022 (finding 2): the Jev-backed judge (createJevBackedJudge)
  // and the live runJev call share ONE memoized runner per webhook request
  // (createJevTurnRunner's "no second request" cache) — whichever fires
  // first permanently decides the cached state. Omitting this let a v2-
  // configured runner's FIRST call (from the judge, via assessRisk) cache a
  // state built from an empty thread and a null agent_last_message, which
  // the later real runJev call then silently reused. Undefined on every v1
  // turn, same posture as recentPartsV2 elsewhere.
  recentPartsV2?: JevV2Part[];
}

export interface JudgeOutput {
  shouldHandoff: boolean;
  reasons: string[];
  suggestedActionType: RiskActionType;
  confidence: "low" | "medium" | "high";
}

export async function assessRisk(
  message: string,
  recentParts: JudgeInput["recentParts"],
  state: IntercomSessionState,
  deps: AssessRiskDeps,
  // v2 twin of recentParts — optional, undefined on every v1 turn. See
  // JudgeInput.recentPartsV2 for why this must reach deps.judge.
  recentPartsV2?: JudgeInput["recentPartsV2"],
): Promise<RiskAssessment> {
  if (!message) return { triggered: false };

  // Layer 0 — magic keyword. Always wins; bypasses dedupe gate (caller's responsibility).
  if (checkMagicKeyword(message)) {
    logJudgeSkip(deps.log, state.conversationId, "rule_escalated");
    return {
      triggered: true,
      source: "user_request",
      reason: "user_requested_human",
      suggestedActionType: "support-general",
      confidence: "high",
    };
  }

  // Layer 1a — content rules.
  const ruleHit = checkRules(message);
  if (ruleHit) {
    logJudgeSkip(deps.log, state.conversationId, "rule_escalated");
    return {
      triggered: true,
      source: "rule",
      reason: ruleHit.reason,
      matchedPattern: ruleHit.matched,
      suggestedActionType: ruleHit.actionType,
      confidence: "high",
    };
  }

  // Layer 1b — hard turn-count cap. Force a handoff once the user has had
  // turnCountHardCap exchanges (consecutive customer messages with no reply in
  // between count once: handler.ts continuesCustomerBurst) without a rule or judge
  // already firing — protects against unbounded loops even when no other layer matches.
  // Sessions persisted before userExchangeCount existed fall back to the message count.
  const cap = deps.turnCountHardCap ?? DEFAULT_TURN_HARD_CAP;
  const turns = state.userTurnCount ?? 0;
  const exchanges = state.userExchangeCount ?? turns;
  if (exchanges >= cap && !state.escalationFiredAt) {
    logJudgeSkip(deps.log, state.conversationId, "hard_cap");
    return {
      triggered: true,
      source: "rule",
      reason: "turn_count_cap",
      suggestedActionType: "support-general",
      confidence: "medium",
    };
  }

  // Layer 2 — LLM judge backstop. Optional: callers may inject deps.judge to
  // enable; otherwise this layer is skipped.
  // Behavior on judge error: skip (fail-open). Decided over fail-closed
  // escalation to avoid runaway escalation on transient OpenRouter blips. The
  // turn-count cap above is the unconditional safety net.
  const minTurns = deps.judgeMinTurnCount ?? DEFAULT_JUDGE_MIN_TURNS;
  if (deps.judge && turns >= minTurns && !state.escalationFiredAt) {
    const startedAt = Date.now();
    try {
      const out = await deps.judge({
        knownFacts: state.knownFacts ?? {},
        recentParts,
        currentMessage: message,
        recentPartsV2,
      });
      logJudgeOutcome(deps.log, state.conversationId, out ? "verdict" : "null", out, Date.now() - startedAt);
      if (out && out.shouldHandoff && out.confidence !== "low") {
        return {
          triggered: true,
          source: "judge",
          reason: out.reasons.join(","),
          suggestedActionType: out.suggestedActionType,
          confidence: out.confidence,
        };
      }
    } catch (err) {
      logJudgeOutcome(deps.log, state.conversationId, "error", null, Date.now() - startedAt);
      deps.log?.warn?.(
        `[intercom:risk] judge call failed turns=${turns} errClass=${(err as Error)?.constructor?.name ?? "unknown"} message=${(err as Error)?.message ?? String(err)}`,
      );
    }
  } else {
    // Judge reachable (message not otherwise escalated) but not invoked.
    // escalationFiredAt already true means a prior layer already escalated
    // this conversation, so it's bucketed with the other pre-judge triggers.
    const reason = !deps.judge ? "disabled" : state.escalationFiredAt ? "rule_escalated" : "min_turns";
    logJudgeSkip(deps.log, state.conversationId, reason);
  }

  return { triggered: false };
}

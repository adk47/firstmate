import type {
  EscalationResult,
  IntercomSessionState,
  RiskAssessment,
  RiskActionType,
} from "./types.js";
import { DEFAULT_JUDGE_MIN_TURNS, DEFAULT_TURN_HARD_CAP } from "./types.js";

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
): Promise<RiskAssessment> {
  if (!message) return { triggered: false };

  // Layer 0 — magic keyword. Always wins; bypasses dedupe gate (caller's responsibility).
  if (checkMagicKeyword(message)) {
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
    return {
      triggered: true,
      source: "rule",
      reason: ruleHit.reason,
      matchedPattern: ruleHit.matched,
      suggestedActionType: ruleHit.actionType,
      confidence: "high",
    };
  }

  // Layer 1b — hard turn-count cap. Force a handoff once the user has sent
  // turnCountHardCap messages without a rule or judge already firing — protects
  // against unbounded loops even when no other layer matches.
  const cap = deps.turnCountHardCap ?? DEFAULT_TURN_HARD_CAP;
  const turns = state.userTurnCount ?? 0;
  if (turns >= cap && !state.escalationFiredAt) {
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
    try {
      const out = await deps.judge({
        knownFacts: state.knownFacts ?? {},
        recentParts,
        currentMessage: message,
      });
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
      deps.log?.warn?.(
        `[intercom:risk] judge call failed turns=${turns} errClass=${(err as Error)?.constructor?.name ?? "unknown"} message=${(err as Error)?.message ?? String(err)}`,
      );
    }
  }

  return { triggered: false };
}

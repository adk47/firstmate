import type { EscalationResult } from "./types.js";

interface EscalationRule {
  category: string;
  patterns: RegExp[];
}

const ESCALATION_RULES: EscalationRule[] = [
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

  for (const rule of ESCALATION_RULES) {
    for (const pattern of rule.patterns) {
      if (pattern.test(message)) {
        return {
          triggered: true,
          category: rule.category,
          matchedPattern: pattern.source,
        };
      }
    }
  }

  return { triggered: false };
}

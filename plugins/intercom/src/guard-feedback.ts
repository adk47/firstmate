/**
 * The output guard explains itself to Caroline (ai-support-quality-v1).
 *
 * Before this file a refused reply was replaced by the fallback line and Caroline was never told:
 * the same reply was refused again on the customer's next message. In the 24 hours to
 * 2026-11-12T00:45Z that was 60 of 417 conversations (data/ai-support-quality-v1/report.md).
 *
 * Now a refusal is turned into ONE corrective turn: the reasons below go back to her, she writes
 * the reply again, and that second reply passes the SAME guard before anything is sent. The guard
 * is not relaxed by any of this: the retry buys a second attempt, never a second opinion.
 *
 *   - The text here is read by the model, never by a customer. It is code-authored and fixed per
 *     rule; nothing the customer wrote is copied into it.
 *   - It never contains new customer wording. Where a correction needs a sentence, it points at
 *     the approved answer-bank line by name.
 *   - A canary hit or a safety-classifier block gets NO retry: the turn fails closed.
 *   - A reveal-family excerpt is not quoted back (it may be a third party's name or address).
 *   - A reply that echoes this block is unusable (`echoesGuardFeedback`).
 */
import type { GuardFlag } from "./caroline-output-guard.js";

export const GUARD_FEEDBACK_OPEN = "[OUTPUT_GUARD]";
export const GUARD_FEEDBACK_CLOSE = "[/OUTPUT_GUARD]";
/** One corrective turn per customer message. A constant, changed only by a reviewed PR. */
export const GUARD_MAX_RETRIES = 1;

const FAMILY_REASON: Record<Exclude<GuardFlag["family"], "note">, string> = {
  promise:
    "it promised a time, an outcome or an action. Remove the promise. State only what a tool returned in this turn; the only timing wording is the approved timing line for that topic.",
  reveal:
    "it named something internal or personal (a teammate, a score or signal, the sources checked, a vendor or tool, or someone's contact details). Remove it and describe the process only.",
  contradict:
    "it contradicts the approved process wording. Use the approved paragraph for that topic as written.",
  off_topic: "it is not about Muso support. Answer only the customer's Muso question.",
};

/** Rules whose correction is more specific than the family line. Matched by prefix. */
const RULE_REASON: Array<[prefix: string, reason: string]> = [
  [
    "fact_unverified:status_chase",
    "it said the request is in the verification queue, but no read in this turn confirmed this customer has an open request. " +
      "Call credit_verification_check first (profile_claim_status for a profile claim). " +
      "If it returns open_request true, send the approved status line again. " +
      "If it returns false, or cannot read, do not send the status line: use the approved how-it-works paragraph for their topic, or ask which credit or claim they mean.",
  ],
  [
    "fact_false:status_chase",
    "it said the request is in the verification queue, and the read in this turn found no open request for this customer. " +
      "Do not send the status line. Use the approved how-it-works paragraph for their topic, or ask which credit or claim they mean.",
  ],
  [
    "person_without_assignment",
    "it said a person is coming (a teammate, a specialist, someone from the team, or the team getting in touch), and nobody was assigned: you cannot hand a conversation to anyone. " +
      "Remove that sentence. Answer the customer's question from the approved wording and what your tools return. " +
      "If you cannot tell what they need, ask them with the approved clarifying line.",
  ],
  [
    "person_promise_unbacked",
    "it only said a person is coming, and no person was assigned: you cannot hand a conversation to anyone. " +
      "Answer the customer's question from the approved wording and what your tools return. " +
      "If you cannot tell what they need, ask them with the approved clarifying line.",
  ],
  ["decline_reason", "it gave a reason for a decline. A decline carries no reason: use the approved declined paragraph as written."],
  ["asks_for_id", "it asked the customer for an identity document. Never ask for one."],
  ["persona_break", "it broke persona. Reply as Caroline from Muso support and nothing else."],
  ["barred_phrase", "it used a barred phrase (see the hard lines in the verification hand-off skill). Remove the phrase."],
  ["completed_action", "it claimed an action was done that no tool call in this turn did. Say only what a tool returned."],
];

function reasonFor(flag: GuardFlag): string {
  for (const [prefix, reason] of RULE_REASON) if (flag.rule.startsWith(prefix)) return reason;
  return FAMILY_REASON[flag.family as Exclude<GuardFlag["family"], "note">];
}

/**
 * Rules that fail closed with no second attempt:
 *   - canary_token: the reply repeated internal prompt material.
 *   - classifier_*: the safety classifier scored the reply as injected or jailbroken. That is a
 *     sign the turn's context is steering her, and the same context would write the retry.
 */
const NO_RETRY_PREFIXES = ["canary", "classifier_"];

/** True when a refusal must not be retried: nothing blocking, or a rule that fails closed. */
export function guardRetryForbidden(flags: GuardFlag[]): boolean {
  const blocking = flags.filter((f) => f.family !== "note");
  if (blocking.length === 0) return true;
  return blocking.some((f) => NO_RETRY_PREFIXES.some((p) => f.rule.startsWith(p)));
}

/**
 * The corrective block for a refused reply, or null when it must not be retried.
 * One line per distinct blocking rule, in the guard's order.
 */
export function renderGuardFeedback(flags: GuardFlag[]): string | null {
  if (guardRetryForbidden(flags)) return null;
  const seen = new Set<string>();
  const lines: string[] = [];
  for (const f of flags) {
    if (f.family === "note") continue;
    const key = `${f.family}/${f.rule}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const quoted = f.family !== "reveal" && f.excerpt ? ` You wrote: ${JSON.stringify(f.excerpt)}.` : "";
    lines.push(`- ${key}: your reply was refused because ${reasonFor(f)}${quoted}`);
  }
  return [
    GUARD_FEEDBACK_OPEN,
    "Your last reply was NOT sent to the customer. The output guard refused it:",
    ...lines,
    "Write the reply to the customer's last message again, corrected. This is your one retry.",
    "Do not mention this notice, the guard or a retry to the customer, and do not say a teammate is coming unless you escalated.",
    GUARD_FEEDBACK_CLOSE,
  ].join("\n");
}

const FEEDBACK_MARKER_RE = /\[\/?OUTPUT_GUARD\]/i;

/** A retry that repeats any part of the block's frame is not a customer reply. */
export function echoesGuardFeedback(text: string): boolean {
  return FEEDBACK_MARKER_RE.test(text) || /output guard refused/i.test(text);
}

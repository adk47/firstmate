/**
 * A promise of a person that nobody keeps is removed before it is sent (ai-support-quality-v1).
 *
 * Measured over the 24 hours to 2026-11-12T00:45Z (data/ai-support-quality-v1/report.md): Caroline
 * told 268 of 417 customers that a person was coming. A person was assigned in 63 and replied in
 * none. Almost every one of those promises was the same closing sentence added after an answer
 * that was already complete ("Everything you send here is recorded ...", then "I'm pulling in a
 * teammate to take this from here.").
 *
 * Why it is always unbacked here: Caroline cannot assign a conversation. A person takes one only
 * on an explicit escalation, the system performs that, and the system writes its own farewell
 * (escalation-action.ts), which never passes through this function. So a promise of a person in a
 * MODEL-WRITTEN reply is false by construction (assignment-policy.ts, captain 2026-11-11).
 *
 * What this does, and does not do:
 *   - It only REMOVES sentences. It never adds or rewrites customer wording, so what is left is
 *     exactly what she wrote and still has to pass the output guard.
 *   - When the promise was the whole reply, nothing is sent from here: the caller gives her the
 *     reason and one retry (guard-feedback.ts).
 *   - Honest statements ABOUT a person ("I couldn't confirm a teammate had taken this on") stay:
 *     the patterns need a promise shape, not just the word.
 *   - Merge threads are left to merge-reply-guard.ts, which owns their closing line.
 */

const PROMISE_RES: RegExp[] = [
  // The fixed closing line and its near variants, straight or curly apostrophe.
  /\bpulling\s+in\s+(?:a|an|our)\s+(?:teammate|colleague|specialist|team\s+member)\b/i,
  /\b(?:a|an|our|the)\s+(?:teammate|colleague|specialist|team\s+member)\s+(?:will|is\s+going\s+to|can|could|to)\b/i,
  /\b(?:someone|somebody)\s+(?:from|on|in)\s+(?:the|our)\s+team\s+(?:will|is\s+going\s+to|can|could)\b/i,
  /\b(?:pass|hand|transfer|escalat)\w*\s+(?:you|this\s+conversation)\s+(?:over\s+)?to\s+(?:a|an|our|the)\s+(?:teammate|colleague|specialist|person|human|team\s+member)\b/i,
  // Spanish, as observed in the live inbox.
  /\bun[a]?\s+compañer[oa]\s+(?:se|te|la|lo|le|que|va|podrá|revisará)\b/i,
  /\bpedir(?:le)?\s+a\s+un[a]?\s+compañer[oa]\b/i,
];

export const UNBACKED_HANDOFF_RULE = "person_promise_unbacked";

// A negation that governs the match itself: at most two words between it and the match, and no
// clause break. "I can't hand this conversation to a person" is honest and stays; "I can't answer
// this myself, so I'm pulling in a teammate" is still a promise (the negation is another clause).
const NEGATED_BEFORE_RE = /(?:\b(?:can't|cannot|can\s+not|won't|will\s+not|couldn't|could\s+not|don't|do\s+not|didn't|not|never|unable\s+to|no\s+puedo|no)\s+)(?:[\w']+\s+){0,2}$/i;
const NEGATED_AFTER_RE = /^\s*(?:not|never|no\s+longer)\b|^n't\b/i;

export function isPersonPromise(sentence: string): boolean {
  const s = sentence.replace(/[’‘]/g, "'");
  for (const re of PROMISE_RES) {
    const m = re.exec(s);
    if (!m) continue;
    const before = s.slice(0, m.index);
    const after = s.slice(m.index + m[0].length);
    if (NEGATED_BEFORE_RE.test(before) || NEGATED_AFTER_RE.test(after)) continue;
    return true;
  }
  return false;
}

export interface UnbackedHandoffResult {
  /** The reply without the promise sentences. May be empty. */
  body: string;
  /** The sentences removed, in order. */
  removed: string[];
  /** True when promise sentences were found and nothing else was left. */
  onlyPromise: boolean;
}

// A sentence, with the whitespace that follows it kept so paragraphs survive.
const SENTENCE_RE = /[^.!?\n]+(?:[.!?]+|(?=\n)|$)[ \t]*/g;

export function stripUnbackedHandoff(reply: string): UnbackedHandoffResult {
  const removed: string[] = [];
  const paragraphs = reply.split(/(\n+)/);
  const out: string[] = [];
  for (const chunk of paragraphs) {
    if (/^\n+$/.test(chunk) || chunk === "") {
      out.push(chunk);
      continue;
    }
    const kept: string[] = [];
    for (const sentence of chunk.match(SENTENCE_RE) ?? [chunk]) {
      if (isPersonPromise(sentence)) removed.push(sentence.trim());
      else kept.push(sentence);
    }
    out.push(kept.join("").replace(/[ \t]+$/u, ""));
  }
  if (removed.length === 0) return { body: reply, removed, onlyPromise: false };
  const body = out
    .join("")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return { body, removed, onlyPromise: body.length === 0 };
}

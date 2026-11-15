/**
 * A hand-back turn must not be answered with a greeting.
 *
 * firstmate 2026-11-15 15:03Z: the backlog drain's first ten live hand-backs reached Caroline as a
 * fresh customer message, and she answered "Anytime!" / "You are welcome" to people who had been
 * waiting months on an open promise. The cause was that the note carried a reason code and nothing
 * else, so the only thing in her turn was the customer's last word — and on a thread we went quiet
 * on, that word is usually "thanks".
 *
 * `filters.ts renderHandbackBlock` fixes the cause by putting the promise, its date and the wait in
 * front of her. This is the belt to that braces: if a hand-back turn still comes back as a
 * pleasantry, it is refused rather than sent, because "Anytime!" to someone waiting three months is
 * worse than the fallback line.
 *
 * The test is deliberately crude — strip every pleasantry, and if almost nothing is left, it was a
 * pleasantry. A status update always names an item, a missing thing or a done thing, and those words
 * are not on the list.
 */

/** The rule name a guard-feedback line and a ledger row carry. */
export const HANDBACK_GREETING_RULE = "handback_greeting";

/**
 * Words that carry no status. Matched case-insensitively and removed before the length test.
 *
 * Kept as one alternation rather than a list of regexes so the "did anything survive" question is a
 * single pass. Order matters only for readability: the longest forms come first so "thank you" is
 * removed before "you".
 */
const PLEASANTRY =
  /\b(what can i (help|do) (you )?(with|for)( today)?|how can i (help|assist)( you)?( today)?|let me know if you need anything else|let me know if there'?s anything else|let me know if you have any (other )?questions|feel free to reach out|have a (great|good) day|all the best|happy to help|glad to help|my pleasure|you'?re welcome|you are welcome|no problem|thank you|thanks|thankyou|cheers|anytime|hello|hey|hi|great|perfect|awesome|got it|sure|okay|ok|np)\b/gi;

/** Below this many letters left after the pleasantries are removed, the reply was a pleasantry. */
const MIN_SUBSTANCE_CHARS = 20;

/**
 * True when the reply is only a greeting, a thanks or a "you're welcome" — i.e. it says nothing
 * about the item the customer is waiting on.
 */
export function isGreetingOnlyReply(text: string): boolean {
  const plain = String(text ?? "")
    .replace(/<[^>]*>/g, " ")
    .replace(/[\u2014\u2013]/g, "-")
    .replace(/\s+/g, " ")
    .trim();
  if (!plain) return false;
  const substance = plain.replace(PLEASANTRY, " ").replace(/[^A-Za-z0-9]/g, "");
  return substance.length < MIN_SUBSTANCE_CHARS;
}

/**
 * The violation for a hand-back turn, or null.
 *
 * `handback` is the session's hand-back context: when it is absent this turn was not a hand-back and
 * the check does not apply, so an ordinary "Anytime!" to a customer who said thanks is still fine.
 */
export function handbackGreetingViolation(text: string, handback: unknown): string | null {
  if (!handback) return null;
  return isGreetingOnlyReply(text) ? HANDBACK_GREETING_RULE : null;
}

/**
 * The verification-queue status line, when the customer never asked about a request.
 *
 * firstmate 2026-11-15 16:26Z, from the old-bot population: a customer on 215473830027987 asked
 * about DOUBLE-COUNTED STREAMS and was told "your request is in the verification queue". There was
 * no request in question and he had not asked about one, so the sentence was about the wrong thing —
 * the same failure class as answering the wrong link. The queue line is only truthful when there IS
 * a request and the customer asked about it, so `askedAboutRequest` gates it mechanically rather
 * than by asking a model to remember.
 */
export const HANDBACK_UNASKED_STATUS_RULE = "handback_unasked_status_line";

/** The phrases that assert a request is sitting somewhere waiting to be worked. */
const QUEUE_ASSERTION =
  /\b(in|on|at)\s+(the\s+|our\s+|a\s+)?(verification\s+|review\s+|support\s+|credit\s+)?queue\b|\b(your|the)\s+(request|claim|merge|application)\s+(is|has been|was)\s+(now\s+)?(in|with|submitted|escalated|sent)|\bbeing\s+(reviewed|verified|processed|looked at)\s+by\b|\bin\s+line\s+to\s+be\b/i;

/**
 * The violation, or null.
 *
 * Only fires on a hand-back turn where the customer did not ask about a request: on an ordinary
 * turn, or on a thread where the customer did ask, the line is allowed.
 */
export function handbackUnaskedStatusViolation(text: string, handback: unknown): string | null {
  const ctx = handback as { askedAboutRequest?: boolean } | null | undefined;
  if (!ctx) return null;
  if (ctx.askedAboutRequest === true) return null;
  const plain = String(text ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");
  return QUEUE_ASSERTION.test(plain) ? HANDBACK_UNASKED_STATUS_RULE : null;
}

/**
 * Intentional no-reply signal for the Intercom CS agent (Caroline).
 *
 * SOUL.md "Reading the room" tells Caroline to stay quiet when a customer's
 * message needs no reply -- a bare acknowledgment or conversation-closer
 * ("ok", "thanks", "👍") after she's already helped. To do that she emits this
 * token, and nothing else. The flush path in channel.ts detects it and posts
 * nothing; the 👀 ack reaction stays on the customer's message as the
 * read-receipt, so the silence reads as "seen, nothing to add" -- not another
 * robotic confirmation, and not a broken bot.
 *
 * This is deliberately distinct from the silent_dispatch alarm
 * (silent-dispatch.ts): a no-reply turn DOES produce a buffered chunk (this
 * token), so detectSilentDispatch returns {silent:false} and never pages. The
 * #280 alarm stays reserved for genuine zero-output failures.
 */

export const NO_REPLY_SENTINEL = "[[NO_REPLY]]";

// Match the sentinel anywhere, case-insensitive, tolerant of inner whitespace.
// Only ever used with String.replace (never .test()/.exec()) so the global flag
// carries no shared-lastIndex hazard.
const NO_REPLY_REGEX = /\[\[\s*NO_REPLY\s*\]\]/gi;

/**
 * Remove any no-reply sentinel(s) from reply text and trim. Defensive: if the
 * model emits the token alongside real content, we drop the token so it never
 * reaches a customer and post the remaining text.
 */
export function stripNoReplySentinel(joined: string): string {
  return joined.replace(NO_REPLY_REGEX, "").trim();
}

/**
 * True when the agent's whole reply is the no-reply sentinel -- i.e. Caroline
 * chose to stay silent. A reply that contains the token AND real text is NOT a
 * no-reply (we post the real text instead of swallowing a genuine answer), and
 * an empty/blank reply is NOT a no-reply (that is a real zero-output, which the
 * silent_dispatch alarm should still catch).
 */
export function isIntentionalNoReply(joined: string): boolean {
  // The token was present (something was removed) AND nothing else remains.
  return joined.trim().length > 0 && stripNoReplySentinel(joined).length === 0;
}

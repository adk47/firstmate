/**
 * Priority signal for the Intercom CS agent (Caroline).
 *
 * SOUL.md "Priority signal" tells Caroline to emit this token when a customer
 * is complaining about a DATA problem (wrong/missing credits, wrong profile
 * data, account/data corruption, OR analytics/stream-counts being wrong). The
 * flush path in channel.ts detects it, STRIPS it so the customer never sees it,
 * still posts her (cleaned) reply as normal, and TAGS the conversation
 * `ai:data-complaint` so the Lane B watchdog can fold it into its count.
 *
 * It does NOT page anyone on its own. Leadership is paged only when the watchdog
 * sees the same data category cross MANY users (a systemic cluster), not on each
 * individual complaint (Aaron 2026-06-23 — he wants systemic issues, not noise).
 *
 * This is deliberately distinct from the `[[NO_REPLY]]` sentinel (no-reply.ts)
 * and from the heavyweight human-takeover escalation (escalation-action.ts):
 *   - NO_REPLY *suppresses* the post. PRIORITY *keeps* the (stripped) post and
 *     *adds* the classify-and-tag side-effect. The token may co-exist with real
 *     reply text.
 *   - The handoff escalation pulls Caroline OUT (reassigns to a human, posts a
 *     "pulling in a teammate" farewell). The priority signal leaves her IN — it
 *     is purely an internal classification; she keeps helping the customer.
 *
 * Optional payload: `[[PRIORITY: <reason>]]` carries Caroline's read of the
 * complaint (model-generated, UNTRUSTED). It's retained for context; the
 * watchdog groups by the deterministic data CATEGORY it derives, not this text.
 */

export const PRIORITY_SENTINEL = "[[PRIORITY]]";

/**
 * Conversation tag applied by Lane A when Caroline classifies a customer message
 * as a data complaint. The Lane B systemic watchdog
 * (scripts/intercom-data-complaint-watchdog.py) FOLDS tagged conversations into
 * its cross-user cluster count (alongside its own keyword detection). Keep the
 * value in sync with DATA_COMPLAINT_TAG there.
 */
export const DATA_COMPLAINT_TAG = "ai:data-complaint";

// Match `[[PRIORITY]]` or `[[PRIORITY: some reason]]` anywhere, case-insensitive,
// tolerant of inner whitespace. The reason group stops at the closing `]` so it
// can never swallow the bracket.
//
// Two module-level instances, no per-call allocation:
//  - PRIORITY_REGEX (global): for stripPrioritySentinel's String.replace, which
//    needs `g` to remove every occurrence.
//  - PRIORITY_DETECT_REGEX (non-global twin, compiled once from the same source):
//    for detectPrioritySignal's single .exec(). A non-global regex keeps
//    lastIndex at 0, so reusing this one instance across calls is safe — the
//    shared-lastIndex hazard only exists for a global regex's .exec().
const PRIORITY_REGEX = /\[\[\s*PRIORITY\s*(?::\s*([^\]]*?)\s*)?\]\]/gi;
const PRIORITY_DETECT_REGEX = new RegExp(PRIORITY_REGEX.source, "i");

export interface PrioritySignal {
  fired: boolean;
  // The short reason after the colon, trimmed; null when the bare token was
  // used or no reason was given.
  reason: string | null;
}

/**
 * Detect whether Caroline emitted the priority token, and capture its optional
 * reason. Returns the FIRST token's reason if several are present (defensive --
 * doctrine is one token per reply).
 */
export function detectPrioritySignal(joined: string): PrioritySignal {
  const m = PRIORITY_DETECT_REGEX.exec(joined);
  if (!m) return { fired: false, reason: null };
  const reason = m[1] && m[1].trim().length > 0 ? m[1].trim() : null;
  return { fired: true, reason };
}

/**
 * Remove every priority token (with or without a reason) from reply text and
 * trim. The customer must never see the token, so this runs in the outbound
 * strip pipeline before the reply is posted.
 */
export function stripPrioritySentinel(joined: string): string {
  return joined.replace(PRIORITY_REGEX, "").trim();
}

/**
 * Strip OpenClaw's model-fallback notice from Caroline's outbound Intercom replies.
 *
 * When the primary model fails (auth, rate_limit, timeout, ...), the OpenClaw
 * gateway falls back to the next model in the chain AND emits an operational
 * notice describing the swap, e.g.:
 *
 *   ↪️ Model Fallback: openrouter/openai/gpt-5.4-mini (selected openai/gpt-5.5; auth)
 *
 * That notice is a SEPARATE reply payload (flagged `isFallbackNotice`) that the
 * gateway PREPENDS to the assistant's real reply; it carries
 * `deliverDespiteSourceReplySuppression`, so reply-suppression does not stop it.
 * The Intercom plugin buffers every delivered chunk and flushes them as one
 * Intercom message, so the notice rode out to a customer in front of Caroline's
 * actual answer (incident 2026-06-19, conv with "Nitin").
 *
 * The notice is operational telemetry, NOT customer-facing content. It is wanted
 * in the main (Slack-facing) gateway — internal operators should see a model
 * degradation — but it must never reach a support customer. main does not route
 * through this plugin, so stripping here is correctly scoped to Caroline only.
 *
 * Two strip layers exist (see channel.ts):
 *   1. The `deliver` callback drops any payload flagged `isFallbackNotice`
 *      before it is buffered (semantically exact; also keeps the chunk count
 *      honest for the no-reply / silent-dispatch logic).
 *   2. This regex runs on the joined reply body as a deterministic backstop, in
 *      case the flag does not survive onto the object the embedded `deliver`
 *      callback receives under the codex runtime.
 *
 * The notice format (OpenClaw `buildFallbackNotice`) is byte-stable across
 * 5.27 -> 6.x -> main. We match the STRUCTURE — the header plus the trailing
 * `(selected …; …)` (or the `cleared` variant's `(was …)`) parenthetical — and
 * never the open-ended reason text, so the match survives new failover reasons
 * and minor format wobble. The leading ↪️ emoji is optional because an earlier
 * sanitizer pass may already have stripped it.
 */

// Structural match:
//   - optional leading ↪️ (U+21AA, with optional U+FE0F variation selector)
//   - "Model Fallback" with the optional " cleared" variant
//   - ":" then the active-model ref (any run of non-"(" chars; model refs never
//     contain "(", and the real reply only begins AFTER the notice, so this can
//     never spill past the notice's own parenthetical)
//   - the "(selected …; …)" or "(was …)" parenthetical that always terminates it
// Case-insensitive and global (a single turn can carry both a fallback and a
// cleared notice). Used only with String.replace/String.match — never
// .test()/.exec() — so the `g` flag carries no shared-lastIndex hazard.
export const MODEL_FALLBACK_NOTICE_RE =
  /(?:↪️?\s*)?Model Fallback(?: cleared)?:[^(]*\((?:selected|was)[^)]*\)/gi;

/**
 * Remove any model-fallback notice(s) from reply text and trim. Returns the
 * input unchanged when no notice is present (apart from the trim). Defensive on
 * non-string input.
 */
export function stripModelFallbackNotice(text: string): string {
  if (typeof text !== "string") return text;
  return text.replace(MODEL_FALLBACK_NOTICE_RE, "").trim();
}

/**
 * Return the matched notice strings (for an audit log) without mutating the
 * body, or null when there is no notice. Kept separate from the strip so the
 * caller can log the exact degradation that was hidden from the customer.
 */
export function findModelFallbackNotices(text: string): string[] | null {
  if (typeof text !== "string") return null;
  return text.match(MODEL_FALLBACK_NOTICE_RE);
}

/**
 * True when `text` consists ENTIRELY of model-fallback notice(s) — i.e. a
 * delivered chunk that is the gateway notice and nothing else. The `deliver`
 * callback uses this to drop such a chunk whether or not the runtime preserved
 * the `isFallbackNotice` flag, so a standalone notice never enters the buffered
 * chunks and never counts as customer-facing output (keeping the no-reply /
 * silent-dispatch logic symmetric across both strip layers).
 *
 * A chunk that merely PREPENDS a notice to a real reply is NOT notice-only
 * (real text survives the strip) — that chunk is kept and the flush-time
 * backstop strips the notice from the joined body, so no reply is ever dropped.
 */
export function isOnlyModelFallbackNotice(text: string): boolean {
  if (typeof text !== "string") return false;
  if (text.trim().length === 0) return false;
  // Cheap substring gate so normal reply chunks never pay for the regex.
  if (!text.includes("Model Fallback")) return false;
  return stripModelFallbackNotice(text).length === 0;
}

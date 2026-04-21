/**
 * Mechanical outbound email guardrail for the Intercom CS agent.
 *
 * Customer-facing replies may only contain emails in ALLOWED_OUTBOUND_EMAILS.
 * Any other email is replaced with support@muso.ai and reported to the caller
 * so the caller can log it. This is the deterministic enforcement layer —
 * the SOUL.md rule is paired instruction-layer defense, not the guarantee.
 *
 * See docs/2026-04-17-cs-agent-email-guardrail-design.md.
 */

export const ALLOWED_OUTBOUND_EMAILS: ReadonlySet<string> = new Set([
  "support@muso.ai",
  "jan@muso.ai",
]);

const REPLACEMENT = "support@muso.ai";

// TLD class is [a-zA-Z]{2,} — cannot consume periods, so trailing punctuation
// like "nick@example.com." matches only "nick@example.com". Tests lock this in.
//
// NOTE: the /g flag makes this regex stateful (lastIndex persists across
// calls). This file only uses .replace(), which internally resets lastIndex,
// so we're safe. If you add a .test() or .exec() call that reuses this
// constant, reset lastIndex first or the second call in a loop will skip
// matches. Prefer a fresh RegExp for iterative use.
const EMAIL_PATTERN = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/g;

// Upper bound on body length run through the regex. The two greedy character
// classes (local-part and domain) overlap on letters/digits/dots, which lets
// a pathological input like "aaaa...@bbbb..." trigger quadratic backtracking
// (benchmark: 50 KB hits ~6 s on Node 20). Intercom replies are realistically
// <4 KB; any body past this cap is truncated before the regex runs. Truncation
// is safer than the alternative (sync event-loop stall of 25 s+ on 100 KB
// pathological input blocks every other webhook).
const MAX_BODY_LENGTH = 16_000;

export interface SanitizeResult {
  body: string;
  redactions: string[];
}

export function sanitizeOutboundBody(body: string): SanitizeResult {
  // The IntercomClient interface types `body: string`, but channel.ts's
  // sendText callback receives the params as `any`, so a non-string body
  // could reach this point. Coerce with an explicit marker rather than
  // letting .replace() throw on null/undefined or, worse, dispatch to an
  // object's own .replace method and bypass sanitization entirely.
  if (typeof body !== "string") {
    return { body: REPLACEMENT, redactions: [`<non-string body: ${typeof body}>`] };
  }

  const truncated = body.length > MAX_BODY_LENGTH;
  const input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const redactions: string[] = [];
  const cleaned = input.replace(EMAIL_PATTERN, (match) => {
    if (ALLOWED_OUTBOUND_EMAILS.has(match.toLowerCase())) {
      return match;
    }
    redactions.push(match);
    return REPLACEMENT;
  });
  // Surface truncation via the redactions channel so the log line shows it.
  // Dropped tail is real data loss; callers need to see when it happens.
  // Extremely unlikely for Intercom replies (<4 KB realistically), but if it
  // ever fires in prod that's an anomaly worth investigating, not silencing.
  if (truncated) {
    redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  }
  return { body: cleaned, redactions };
}

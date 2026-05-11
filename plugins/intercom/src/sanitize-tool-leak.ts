/**
 * Mechanical outbound tool-leak guardrail for the Intercom CS agent.
 *
 * Customer-facing replies must not contain internal tool names, architecture
 * terms, or "the system says..." phrasing. This sanitizer is the deterministic
 * enforcement layer -- SOUL.md prose is paired instruction-layer defense, not
 * the guarantee. Mirrors the shape of sanitize-email.ts so the wrapper in
 * outbound.ts can compose both predictably.
 */

export interface ToolLeakSanitizeResult {
  body: string;
  redactions: string[];
}

const REDACTED = "[REDACTED]";
const MAX_BODY_LENGTH = 16_000;

const PATTERNS: RegExp[] = [
  // tool tokens
  /\bprofile_status\b/g,
  /\bprofile_lookup\b/g,
  /\bcredits_search\b/g,
  /\bcreate_ticket\b/g,
  /\bsubscription_status\b/g,
  // defense-in-depth: scrub the bare word "ticket". Low false-positive
  // risk in Caroline's domain (music credits / profiles / subscriptions /
  // refunds). SOUL.md tells the model not to say "ticket" — this is
  // the mechanical backstop.
  /\bticket\b/gi,
  // internal phrases (case-insensitive)
  /\btool failed\b/gi,
  /\berror fetching\b/gi,
  /\bunable to look up\b/gi,
  /\bthe system says\b/gi,
  /\bmy system\b/gi,
  /\bthere was an issue with\b/gi,
  // architecture words
  /\bClickUp\b/gi,
  /\bopenclaw\b/gi,
  /\bHYDRA\b/g, // case-sensitive: only the all-caps internal moniker
];

export function sanitizeToolLeak(body: string): ToolLeakSanitizeResult {
  if (typeof body !== "string") {
    return { body: REDACTED, redactions: [`<non-string body: ${typeof body}>`] };
  }
  const truncated = body.length > MAX_BODY_LENGTH;
  let input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const redactions: string[] = [];
  for (const pat of PATTERNS) {
    input = input.replace(pat, (match) => {
      redactions.push(match);
      return REDACTED;
    });
  }
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  // A replacement string ("[REDACTED]") can be longer than the matched token,
  // so the post-replacement body may still exceed MAX_BODY_LENGTH even after
  // the pre-truncation above. Hard-cap the output to stay within the limit.
  const finalBody = input.length > MAX_BODY_LENGTH ? input.slice(0, MAX_BODY_LENGTH) : input;
  return { body: finalBody, redactions };
}

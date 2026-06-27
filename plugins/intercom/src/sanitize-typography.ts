/**
 * Mechanical outbound typography guardrail for the Intercom CS agent (Caroline).
 *
 * SOUL.md tells Caroline never to use the em-dash (rewrite with a comma, period,
 * or parentheses). That prose is the instruction-layer defense; this sanitizer is
 * the deterministic GUARANTEE: no em-dash ever reaches a customer, regardless of
 * what the model emits (and the gpt-5.4-mini fallback emits them constantly).
 *
 * Design choice — a pure CHAR SWAP to the U+2013 en-dash, NOT a comma/whitespace
 * rewrite: swapping one code point for another can never mangle a sentence, merge
 * paragraphs, double a space, or eat a leading/trailing space. The job here is
 * only "no em-dash leaves the building"; making the prose read naturally (commas,
 * periods) is the model's job via SOUL, and the en-dash is the zero-risk backstop
 * for the leaks. Mirrors the {body, redactions} shape of sanitize-tool-leak.ts so
 * the wrapper in outbound.ts can compose all passes predictably.
 *
 * Scope is the em-dash FAMILY only — the model can reach for look-alikes:
 *   U+2014 — em dash, U+2015 ― horizontal bar, U+2E3A ⸺ two-em, U+2E3B ⸻ three-em.
 * Deliberately NOT touched (they carry meaning): U+2013 en-dash (ranges), ASCII
 * hyphen / "--" (compounds, CLI flags), U+2010–U+2012, and U+2212 minus. NFC/NFKC
 * will not fold an em-dash, so an explicit char-class replace is mandatory.
 */

export interface TypographySanitizeResult {
  body: string;
  redactions: string[];
}

const REDACTED_MARKER = "<em-dash→en-dash>";
const MAX_BODY_LENGTH = 16_000;
const EN_DASH = "–";

// em (U+2014), horizontal bar (U+2015), two-em (U+2E3A), three-em (U+2E3B).
const EM_DASH_FAMILY = /[—―⸺⸻]/g;

export function sanitizeTypography(body: string): TypographySanitizeResult {
  if (typeof body !== "string") {
    // Unreachable in the composed outbound pipeline (this pass always runs on a
    // string returned by the email + tool-leak passes); guarded for parity with
    // the sibling sanitizers' fail-closed posture.
    return { body: "", redactions: [`<non-string body: ${typeof body}>`] };
  }
  const truncated = body.length > MAX_BODY_LENGTH;
  const input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const redactions: string[] = [];
  const out = input.replace(EM_DASH_FAMILY, () => {
    redactions.push(REDACTED_MARKER);
    return EN_DASH;
  });
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  // The en-dash is one code point like the em-dash, so the swap never changes
  // length; the cap is belt-and-braces parity with the other sanitizers.
  const finalBody = out.length > MAX_BODY_LENGTH ? out.slice(0, MAX_BODY_LENGTH) : out;
  return { body: finalBody, redactions };
}

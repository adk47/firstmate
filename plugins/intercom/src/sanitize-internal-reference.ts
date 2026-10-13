/**
 * Mechanical outbound internal-reference guardrail for the Intercom CS agent (Caroline).
 *
 * On 2026-10-09 Caroline told a customer "reference `869fep919`" — a bare ClickUp task id.
 * sanitize-tool-leak.ts bans the words "ticket" / "ClickUp" but a bare id contains neither,
 * so nothing caught it. This pass rewrites any ClickUp task id down to a neutral phrase
 * (rewrite, not drop — same precedent as sanitize-handoff-claim.ts) so an internal id can
 * never reach a customer.
 *
 * Kept OUT of sanitize-tool-leak.ts on purpose: that PATTERNS array is a word list mirrored
 * into SANITIZER_WORDS in scripts/intercom-ops-write.sh and compared as a set by CI; a
 * character-class regex does not belong in that contract.
 *
 * Composes AFTER sanitize-email / sanitize-tool-leak / sanitize-typography in outbound.ts
 * and mirrors their { body, redactions } shape.
 */

export interface InternalReferenceSanitizeResult {
  body: string;
  redactions: string[];
}

const MAX_BODY_LENGTH = 16_000;

const REPLACEMENT = "our records";

// ClickUp support-list ids: "86" + a digit + 6 lowercase alphanumerics (9 chars). Anchors
// that keep real shapes out (each is pinned by an adversarial case in the test file):
//  - (?<![\w-]) / (?![\w-]): the id must be a whole token. `-` counts as a token char so a
//    UUID group, ISRC, Spotify id or any longer alnum run is never carved up.
//  - (?=\d*[a-z]): at least one letter, so an all-digit 9-char order/phone number is safe.
//  - lowercase only (no `i` flag): ClickUp ids are lowercase.
// An optional leading label ("reference", "task id", ...) and wrapping quote/backtick/paren
// are swallowed so the rewrite reads "…under our records", not "reference our records".
const INTERNAL_REF =
  /(?:(?:[Rr]eference|[Rr]ef|[Tt]ask|[Cc]ase)(?:\s+(?:id|ID|number))?[\s:#]*)?[`'"(\[]?(?<![\w-])(86\d(?=\d*[a-z])[a-z0-9]{6})(?![\w-])[`'")\]]?/g;

export function sanitizeInternalReference(body: string): InternalReferenceSanitizeResult {
  if (typeof body !== "string") {
    return { body: "", redactions: [`<non-string body: ${typeof body}>`] };
  }
  const redactions: string[] = [];
  let input = body;
  if (input.length > MAX_BODY_LENGTH) {
    redactions.push(`<truncated: ${input.length} -> ${MAX_BODY_LENGTH} bytes>`);
    input = input.slice(0, MAX_BODY_LENGTH);
  }
  const out = input.replace(INTERNAL_REF, (_m, id: string) => {
    redactions.push(id);
    return REPLACEMENT;
  });
  return { body: out, redactions };
}

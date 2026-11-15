/**
 * Mechanical outbound false-handoff-claim guardrail for the Intercom CS agent (Caroline).
 *
 * Caroline's honesty rule (workspaces/support/SOUL.md) forbids claiming a follow-up was
 * created unless she actually called create_ticket AND received a success THIS
 * conversation; when she hasn't, the sanctioned wording is a statement of intent that
 * also records the follow-up: "I have recorded this and will update you here as soon as
 * there is news." That rule was prose-only, and a real
 * conversation shipped "added these ... and raised it with the team" with no ticket
 * behind it (no ClickUp task, no audit-log hit). This sanitizer is the deterministic
 * enforcement layer: when no ticket was confirmed for the conversation, it rewrites a
 * completed-action handoff claim down to the honest fallback (answer-bank.ts HONEST_FALLBACK,
 * whose "I have recorded this" outbound.ts makes true before the send), so a
 * confabulated reassurance can never reach the customer.
 *
 * Composes AFTER sanitize-email / sanitize-tool-leak / sanitize-typography in
 * outbound.ts and mirrors their { body, redactions } shape. It deliberately matches only
 * COMPLETED-action claims (the actual lie); pure future promises ("I'll flag this…") and
 * the sanctioned fallback itself are left untouched.
 */

import { HONEST_FALLBACK } from "./answer-bank.js";

export interface HandoffClaimSanitizeResult {
  body: string;
  redactions: string[];
}

const MAX_BODY_LENGTH = 16_000;

// The exact, verbatim honest fallback from SOUL.md (answer-bank.ts, one source). It states an
// intent and a completed action on OUR OWN record ("I have recorded this"), which outbound.ts makes
// true before the send; by construction it must never match the families below.
const FALLBACK = HONEST_FALLBACK;

// Family A — first-person COMPLETED action verb + a human-handoff target. Catches the
// real lie: "I've flagged this for our team", "I raised it with the team", "I've sent
// this to engineering", "I've added these ... and raised it with the team". The leading
// I/we prefix is required and matches only the completed forms ("I've" / "I have" /
// "we've" / "we have"), NOT "I'll" — so future promises are excluded. Both the straight
// (') and typographic (’ U+2019) apostrophe are accepted, because the model (esp. the
// gpt-5.4-mini fallback, per sanitize-typography.ts) emits curly quotes and NO upstream
// pass normalizes them. The [^.?!;]{0,60}? clamp keeps the verb and the target inside the
// same clause — excluding `;` so two independent clauses ("I've sent you an email; the
// team is standing by") don't get stitched into a false match.
const CLAIM_A =
  /\b(?:i(?:['’]ve|\s+have)?|we(?:['’]ve|\s+have)?)\s+(?:just\s+|already\s+)?(?:flagged|raised|sent|routed|escalated|forwarded|submitted|reported|passed|looped|notified|added|filed|opened|created|logged)\b[^.?!;]{0,60}?\b(?:team|engineering|eng|devs?|developers?|ops|support team|a (?:person|human|colleague|specialist)|the right (?:people|person|team)|someone (?:on|from) (?:the|our) team)\b/i;

// Family B — the request as passive subject: "this has been sent to the team", "your
// request is with engineering", "it's been escalated to the team". Same apostrophe and
// `;`-exclusion handling as Family A.
const CLAIM_B =
  /\b(?:this|it|that|your (?:request|case|issue|profile)|the (?:request|issue))(?:['’]s)?\s+(?:has been|have been|been|is|was)\s+(?:now\s+)?(?:flagged|raised|sent|routed|escalated|forwarded|submitted|passed|with|in (?:the )?hands of)\b[^.?!;]{0,60}?\b(?:team|engineering|eng|devs?|developers?|ops|support)\b/i;

// Invented follow-up PROMISE ("you'll hear back within…"). Only stripped when it co-occurs
// with a handoff claim in the same unbacked reply (a promised follow-up that was never
// filed is itself a fabrication, SOUL.md). Deliberately requires a promise framing
// ("you'll hear back" / "follow up within" / "get back to you within"), NOT a bare
// "within N days" — so a FACTUAL timeframe ("refunds are processed within 5 business
// days") is left intact even when a claim is being rewritten.
const INVENTED_SLA =
  /\byou['’]?ll hear back\b|\bfollow[- ]?up within\b|\bget back to you within\b/i;

// Family C (MUS-1516) — a quoted reference number is the STRONGEST possible
// handoff claim, and the one shape Families A/B never covered (no verb required:
// "Your reference numbers are 869f7v9v2, 869f7va3b and 869f7vabr." has no "I've
// flagged"/"raised"/etc). A ClickUp task id is a bare 9-character lowercase
// alnum token (e.g. "869f7v9v2" — the 27 Sep incident; "869dgkzga" —
// sanitize-reasoning-leak.test.ts's fixture).
//
// Containment (design call ③ on MUS-1471): \b on both sides means this can ONLY
// match a token that is EXACTLY 9 word-characters end to end — \b lands only at
// the edges of a contiguous run of word-characters, never inside one, so a
// profile/order UUID (ticket-format.ts's musoProfileUrl; order-lookup.ts's
// order_ref) can never match: its hyphen-separated segments are 8/4/4/4/12
// characters, none of them 9. Lowercase-only excludes the order number
// (core-backend createOrder.js: customAlphabet('0-9A-Z',10)(5) — 5 UPPERCASE+
// digit characters) even if its length ever changed. "At least one digit AND
// at least one letter" is enforced in code, not the regex (extractReferenceIds
// below), to keep the character class simple. Both halves matter: a bare
// all-digit run (a long Prodigi order id, a confirmation code) is excluded,
// and so is a bare all-letter run — a plain 9-letter English word
// ("processed", "reference" are both exactly 9 letters) would otherwise
// false-positive on ordinary prose. A genuine id missing either a digit or a
// letter is a false negative only, which downgrades toward the honest
// fallback — the safe direction (design call ②).
const REFERENCE_ID_RE = /\b[0-9a-z]{9}\b/g;

function extractReferenceIds(sentence: string): string[] {
  const matches = sentence.match(REFERENCE_ID_RE);
  if (!matches) return [];
  return matches.filter((id) => /[a-z]/.test(id) && /[0-9]/.test(id));
}

// True iff `sentence` quotes a reference-shaped token that is NOT in
// `filedIds` — this conversation's actual create_ticket result(s). Any single
// unbacked token is enough to redact the whole sentence (never blank the id in
// place: "Your reference numbers are , and ." must never ship).
function sentenceHasUnbackedReference(sentence: string, filedIds: ReadonlySet<string>): boolean {
  return extractReferenceIds(sentence).some((id) => !filedIds.has(id));
}

function isClaim(sentence: string): boolean {
  return CLAIM_A.test(sentence) || CLAIM_B.test(sentence);
}

// Split into sentences while KEEPING each sentence's trailing punctuation and the
// whitespace that followed it, so rebuilding the kept sentences is loss-less. A body
// with no terminator falls to the final alternative and is treated as one sentence.
function splitSentences(body: string): string[] {
  const matches = body.match(/[^.!?]*[.!?]+\s*|[^.!?]+$/g);
  return matches && matches.length > 0 ? matches : [body];
}

// Redact every sentence `isTrigger` flags: the first gets replaced by FALLBACK
// (fallback emitted once), the rest are dropped silently. When `dropSla` is set,
// a sentence matching INVENTED_SLA is ALSO dropped (no fallback) even if it
// isn't itself a trigger — this is what lets a co-occurring or standalone SLA
// promise collapse once the body is already being processed.
function redactSentences(
  sentences: string[],
  isTrigger: (sentence: string) => boolean,
  dropSla: boolean,
): { out: string[]; redactions: string[] } {
  const redactions: string[] = [];
  let fallbackEmitted = false;
  const out: string[] = [];
  for (const sentence of sentences) {
    if (isTrigger(sentence)) {
      redactions.push(sentence.trim());
      if (!fallbackEmitted) {
        // Preserve the claim's trailing whitespace so following sentences stay spaced
        // (empty when the claim was the final sentence → fall back to a single space).
        const trailing = sentence.match(/\s*$/)?.[0] || " ";
        out.push(FALLBACK + trailing);
        fallbackEmitted = true;
      }
      continue; // drop any subsequent trigger sentences (fallback emitted once)
    }
    if (dropSla && INVENTED_SLA.test(sentence)) {
      redactions.push(sentence.trim());
      continue; // drop the unbacked SLA promise (co-occurring or standalone)
    }
    out.push(sentence);
  }
  return { out, redactions };
}

function finalize(out: string[], redactions: string[]): HandoffClaimSanitizeResult {
  let finalBody = out.join("").trim();
  if (finalBody.length === 0) finalBody = FALLBACK;
  if (finalBody.length > MAX_BODY_LENGTH) finalBody = finalBody.slice(0, MAX_BODY_LENGTH);
  return { body: finalBody, redactions };
}

export function sanitizeHandoffClaim(
  body: string,
  opts: { ticketConfirmed: boolean; filedTicketIds?: readonly string[] },
): HandoffClaimSanitizeResult {
  if (typeof body !== "string") {
    return { body: FALLBACK, redactions: [`<non-string body: ${typeof body}>`] };
  }

  // Fail-closed by construction (design call ② on MUS-1471): an omitted
  // filedTicketIds — an old caller, or a missing/stale id store upstream
  // (plugins/intercom/src/ticket-success-signal.ts's getFiledTicketIds already
  // returns [] in that case) — resolves to an empty set, so every
  // reference-shaped token in the body is treated as unbacked. A lost signal
  // can only downgrade a reply toward the honest fallback, never license a
  // fake or foreign id.
  const filedIds = new Set(opts.filedTicketIds ?? []);

  const truncated = body.length > MAX_BODY_LENGTH;
  const input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const sentences = splitSentences(input);

  if (opts.ticketConfirmed) {
    // A real, confirmed ticket makes a completed-action claim and its SLA
    // promise TRUE — those are untouched. But (MUS-1516 AC6 / the :80
    // short-circuit this closes) a confirmed ticket must not license a quoted
    // id THIS conversation never filed, so the reference-id family is still
    // checked on its own.
    if (!sentences.some((s) => sentenceHasUnbackedReference(s, filedIds))) {
      return { body, redactions: [] };
    }
    const { out, redactions } = redactSentences(
      sentences,
      (s) => sentenceHasUnbackedReference(s, filedIds),
      /* dropSla */ false, // the SLA promise is still true given the real ticket
    );
    if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
    return finalize(out, redactions);
  }

  const isUnbackedClaim = (s: string) => isClaim(s) || sentenceHasUnbackedReference(s, filedIds);
  if (!sentences.some(isUnbackedClaim) && !sentences.some((s) => INVENTED_SLA.test(s))) {
    // No unbacked handoff claim, unbacked reference id, or standalone SLA
    // promise → leave the reply alone. (A factual timeframe with no claim never
    // matches INVENTED_SLA — see that regex's own carve-out comment.)
    return { body, redactions: [] };
  }

  const { out, redactions } = redactSentences(sentences, isUnbackedClaim, /* dropSla */ true);
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  return finalize(out, redactions);
}

/**
 * Mechanical outbound false-handoff-claim guardrail for the Intercom CS agent (Caroline).
 *
 * Caroline's honesty rule (workspaces/support/SOUL.md) forbids claiming a follow-up was
 * created unless she actually called create_ticket AND received a success THIS
 * conversation; when she hasn't, the sanctioned wording is a statement of intent —
 * "I'll make sure this gets to the team." That rule was prose-only, and a real
 * conversation shipped "added these ... and raised it with the team" with no ticket
 * behind it (no ClickUp task, no audit-log hit). This sanitizer is the deterministic
 * enforcement layer: when no ticket was confirmed for the conversation, it rewrites a
 * completed-action handoff claim down to the honest fallback (and drops a co-occurring
 * invented SLA), so a confabulated reassurance can never reach the customer.
 *
 * Composes AFTER sanitize-email / sanitize-tool-leak / sanitize-typography in
 * outbound.ts and mirrors their { body, redactions } shape. It deliberately matches only
 * COMPLETED-action claims (the actual lie); pure future promises ("I'll flag this…") and
 * the sanctioned fallback itself are left untouched.
 */

export interface HandoffClaimSanitizeResult {
  body: string;
  redactions: string[];
}

const MAX_BODY_LENGTH = 16_000;

// The exact, verbatim honest fallback from SOUL.md. A statement of INTENT, not a
// completed-action claim, so by construction it must never match the families below.
const FALLBACK = "I'll make sure this gets to the team.";

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

export function sanitizeHandoffClaim(
  body: string,
  opts: { ticketConfirmed: boolean },
): HandoffClaimSanitizeResult {
  if (typeof body !== "string") {
    return { body: FALLBACK, redactions: [`<non-string body: ${typeof body}>`] };
  }
  // A real, confirmed ticket makes the claim TRUE — never touch the reply. This is the
  // guarantee that legitimate post-ticket replies pass through unchanged.
  if (opts.ticketConfirmed) return { body, redactions: [] };

  const truncated = body.length > MAX_BODY_LENGTH;
  const input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;

  const sentences = splitSentences(input);
  if (!sentences.some((s) => isClaim(s))) {
    // No unbacked handoff claim → leave the reply alone (do NOT strip standalone SLAs;
    // without a claim they are far more likely to be factual than a false promise).
    return { body, redactions: [] };
  }

  const redactions: string[] = [];
  let fallbackEmitted = false;
  const out: string[] = [];
  for (const sentence of sentences) {
    if (isClaim(sentence)) {
      redactions.push(sentence.trim());
      if (!fallbackEmitted) {
        // Preserve the claim's trailing whitespace so following sentences stay spaced
        // (empty when the claim was the final sentence → fall back to a single space).
        const trailing = sentence.match(/\s*$/)?.[0] || " ";
        out.push(FALLBACK + trailing);
        fallbackEmitted = true;
      }
      continue; // drop any subsequent claim sentences (fallback emitted once)
    }
    if (INVENTED_SLA.test(sentence)) {
      redactions.push(sentence.trim());
      continue; // drop the co-occurring, now-unbacked SLA promise
    }
    out.push(sentence);
  }
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);

  let finalBody = out.join("").trim();
  if (finalBody.length === 0) finalBody = FALLBACK;
  if (finalBody.length > MAX_BODY_LENGTH) finalBody = finalBody.slice(0, MAX_BODY_LENGTH);
  return { body: finalBody, redactions };
}

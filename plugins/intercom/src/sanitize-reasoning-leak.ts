/**
 * Mechanical outbound reasoning-preamble guardrail for the Intercom CS agent.
 *
 * Caroline runs on a reasoning model (gpt-5.5 via the codex runtime) and
 * intermittently emits its internal monologue as part of the assistant
 * *content* instead of (or as well as) the real reply, and the whole thing gets
 * delivered to the customer. Two observed shapes:
 *   - 2026-05-29 (conv 215474275882654): a short first-person planning preamble,
 *     a markdown horizontal rule, then the real reply.
 *   - 2026-05-31 (conv 215474520232724): the ENTIRE reply was inner monologue --
 *     quoting SKILL.md rules, the structured JSON, a "forbidden words" checklist,
 *     "I am ready to output" -- with NO separator and the real reply only at the
 *     very end.
 *
 * The reasoning knobs do not fix this (the prose is in the content lane, not a
 * separate reasoning lane), and no other sanitizer strips a free-form preamble.
 * SOUL.md prose is the paired instruction-layer defense; this is the
 * deterministic enforcement layer.
 *
 * Mirrors the shape of `sanitize-tool-leak.ts` / `sanitize-email.ts`, with one
 * addition: an `action` discriminator. When a leak is detected but there is no
 * way to recover a clean reply, the guard returns `escalate` rather than
 * shipping a guessed/amputated body -- a wrong strip could re-expose the very
 * reasoning (and the PII inside it) this guard exists to suppress. The caller
 * (channel.ts flush site, alongside `stripConversationContext`) routes
 * `escalate` to a human instead of replying.
 *
 * Detection layers, in order of confidence:
 *   1. INTERNAL markers -- chain-of-thought / tooling tells (SKILL.md, the
 *      structured-JSON fields, "do not use the words", "ready to output", ...).
 *      Near-zero false-positive: their presence means the model dumped its
 *      scaffolding. Scanned across the whole body.
 *   2. META markers -- narration about composing the reply or about the
 *      recipient ("I'll send a warm response", "looking at the previous
 *      history"). The 2026-05-29 family. Scanned in the head only, because a
 *      genuine reply can contain similar phrasing deeper in the body.
 */

export type ReasoningLeakAction = "pass" | "stripped" | "escalate";

export type ReasoningLeakReason =
  | "internal-monologue"
  | "no-separator"
  | "empty-remainder"
  | "meta-remainder"
  | "internal-remainder"
  | "non-string";

export interface ReasoningLeakResult {
  body: string;
  redactions: string[];
  action: ReasoningLeakAction;
  matchedMarkers: string[];
  reason?: ReasoningLeakReason;
  droppedSample?: string;
}

// META markers are leading-preamble tells, so only scan the head: this bounds
// regex cost and avoids matching legitimate third-person prose deep in a long
// reply. INTERNAL markers are scanned across the whole (capped) body -- a
// monologue dump can run for thousands of chars and the strongest tells often
// sit past the head.
const HEAD_SCAN_LIMIT = 1200;
// A real reply recovered after the separator must be at least this long to be
// worth sending; shorter than this and we escalate rather than ship a fragment.
const MIN_REPLY_CHARS = 15;
// Pre-truncate before the regex passes to avoid pathological backtracking on
// huge inputs (mirrors the cap in the sibling sanitizers).
const MAX_BODY_LENGTH = 16_000;

// A markdown horizontal rule: a line that is ONLY ---, ***, or ___ (3+), with
// optional surrounding spaces. `m` flag anchors to line starts/ends so an
// inline "Pro---annual" is never treated as a separator.
const HR_LINE = /^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$/gm;

const APOS = "['’]"; // straight or curly apostrophe
const ILL = `i(?:${APOS}?ll|\\s+will)`; // "I'll" / "Ill" / "I will"
const TONE = "(?:warm|friendly|brief|short|polite|professional|reassuring|quick|nice|casual|kind|gentle|personal)";

// INTERNAL markers: chain-of-thought / tooling tells that essentially never
// appear in a genuine customer-facing reply. Any single match means the agent
// leaked its scaffolding into the content.
const INTERNAL: { name: string; re: RegExp }[] = [
  { name: "skill-md", re: /\bSKILL\.md\b/ },
  { name: "do-not-use-words", re: /\bdo not use (?:the )?words?\b/i },
  { name: "forbidden-words", re: /\bforbidden words?\b/i },
  { name: "report-back-to-customer", re: /\breport back to the (?:customer|user)\b/i },
  { name: "customer-facing-reply", re: /\bcustomer[- ]facing (?:reply|response|message)\b/i },
  { name: "ready-to-output", re: /\bready to output\b/i },
  { name: "write-final-reply", re: /\bwrite the final (?:reply|response|message)\b/i },
  { name: "the-final-reply", re: /\bthe final (?:reply|response)\b/i },
  { name: "tone-calibration", re: /\btone calibration\b/i },
  { name: "structured-json", re: /\bstructured (?:json|response)\b/i },
  { name: "json-submitted", re: /(?:\bsubmitted:\s*true\b|\{\s*submitted\b)/i },
  { name: "json-ticket-id", re: /\bticket_id\b/i },
  { name: "json-action-type", re: /\baction_type\b/i },
  { name: "sla-placeholder", re: /<\s*sla\s*>/i },
  { name: "lets-check-rules", re: /\blet['’]?s\s+(?:double[- ]?)?check\b[^.\n]{0,40}\b(?:rules|forbidden|words|if there)\b/i },
  { name: "rules-on-how-to", re: /\bthe rules?\s+on how to\b/i },
];

// STRONG meta markers: phrasings unlikely in a genuine reply; presence alone
// signals a leaked plan (the 2026-05-29 family).
const META_STRONG: { name: string; re: RegExp }[] = [
  { name: "looking-at-history", re: /\blooking at the (?:previous|prior|earlier)\s+(?:history|conversation|context|thread|messages?|exchange)\b/i },
  { name: "in-pronoun-artist-name", re: /\bin (?:her|his|their)\s+(?:artist|stage|legal|real|professional)\s+name\b/i },
  { name: "ill-compose-toned-reply", re: new RegExp(`\\b${ILL}\\s+(?:send|craft|write|draft|compose|put together)\\s+(?:a|an|the)\\s+(?:${TONE}[,\\s/]+)+(?:response|reply|message|note|answer)\\b`, "i") },
  { name: "ill-respond-in-pronoun", re: new RegExp(`\\b${ILL}\\s+(?:respond|reply|write|send)\\b[^.!?\\n]*\\bin (?:her|his|their)\\b`, "i") },
  { name: "since-pronoun-checking", re: /\bsince (?:she|he|they)(?:['’]s|['’]re| is| are)?\s+(?:checking back|checking in|following up|reaching out|getting back|asking again)\b/i },
  { name: "pronoun-previously-requested", re: /\b(?:she|he|they)\s+(?:had|has|have)\s+(?:previously|earlier|already)\s+(?:requested|asked|reached out|contacted|submitted|mentioned)\b/i },
];

// WEAK meta markers: meta-ish but plausible in ordinary prose. Only count toward
// the threshold in combination (>=2), never alone.
const META_WEAK: { name: string; re: RegExp }[] = [
  { name: "confirming-received", re: /\bconfirming that (?:i['’]?ve|i have|we['’]?ve|we have)\s+received\b/i },
  { name: "let-pronoun-know", re: /\blet (?:her|him|them) know\b/i },
  { name: "the-customer-noun", re: /\b(?:the|this) (?:customer|user|recipient|sender)\b/i },
  { name: "previous-history", re: /\bprevious history\b/i },
  { name: "pronoun-possessive-msg", re: /\b(?:her|his|their) (?:message|request|claim|profile|email|link|account|inquiry)\b/i },
];

function matchNames(text: string, markers: { name: string; re: RegExp }[]): string[] {
  return markers.filter((m) => m.re.test(text)).map((m) => m.name);
}

function metaScore(text: string): { strong: string[]; weak: string[] } {
  return { strong: matchNames(text, META_STRONG), weak: matchNames(text, META_WEAK) };
}

function startsWithMeta(text: string): boolean {
  // Only the leading ~200 chars matter for "is the remainder itself reasoning".
  const head = text.slice(0, 200);
  return matchNames(head, META_STRONG).length > 0 || matchNames(head, INTERNAL).length > 0;
}

function sample(text: string): string {
  return text.replace(/\s+/gu, " ").trim().slice(0, 200);
}

/**
 * Find the last horizontal-rule line whose start index is within the head
 * window. Returns the [start, end) span of that HR line, or null.
 */
function findHeadSeparator(input: string): { start: number; end: number } | null {
  HR_LINE.lastIndex = 0;
  let last: { start: number; end: number } | null = null;
  let match: RegExpExecArray | null;
  while ((match = HR_LINE.exec(input)) !== null) {
    if (match.index >= HEAD_SCAN_LIMIT) break;
    last = { start: match.index, end: match.index + match[0].length };
    if (match.index === HR_LINE.lastIndex) HR_LINE.lastIndex++; // zero-width guard
  }
  return last;
}

export function sanitizeReasoningLeak(body: string): ReasoningLeakResult {
  if (typeof body !== "string") {
    return {
      body: "",
      redactions: [`<non-string body: ${typeof body}>`],
      action: "escalate",
      matchedMarkers: [],
      reason: "non-string",
    };
  }

  // The cap is SCAN-ONLY: it bounds regex cost on huge inputs and must NEVER be
  // returned as the delivered body, or a legitimate >16k reply with no leak would
  // be silently truncated before Intercom (QA review, PR #421). Separator/marker
  // offsets all sit within the first HEAD_SCAN_LIMIT chars, so they map cleanly
  // onto the original `body` — the recovered remainder is sliced from `body`.
  const scan = body.length > MAX_BODY_LENGTH ? body.slice(0, MAX_BODY_LENGTH) : body;
  // INTERNAL tells are scanned across the whole (capped) body -- they are the
  // highest-confidence signal and can appear anywhere in a monologue dump.
  const internalAll = matchNames(scan, INTERNAL);
  const sep = findHeadSeparator(scan);

  if (sep) {
    const preText = scan.slice(0, sep.start);
    // Recover the remainder from the ORIGINAL body so a >16k real reply survives.
    const remainder = body.slice(sep.end).replace(/^\s+/u, "");
    const preInternal = matchNames(preText, INTERNAL);
    const { strong, weak } = metaScore(preText);
    const leadingLeak = preInternal.length >= 1 || strong.length >= 1 || weak.length >= 2;

    if (leadingLeak) {
      const matchedMarkers = [...preInternal, ...strong, ...weak];
      const droppedSample = sample(preText);
      if (remainder.length < MIN_REPLY_CHARS) {
        return { body, redactions: ["<reasoning preamble: empty remainder>"], action: "escalate", matchedMarkers, reason: "empty-remainder", droppedSample };
      }
      // Scan the remainder capped (cost bound), but return it in full.
      const remInternal = matchNames(remainder.slice(0, MAX_BODY_LENGTH), INTERNAL);
      if (remInternal.length >= 1) {
        return { body, redactions: ["<reasoning preamble: internal remainder>"], action: "escalate", matchedMarkers: [...matchedMarkers, ...remInternal], reason: "internal-remainder", droppedSample };
      }
      if (startsWithMeta(remainder)) {
        return { body, redactions: ["<reasoning preamble: meta remainder>"], action: "escalate", matchedMarkers, reason: "meta-remainder", droppedSample };
      }
      return { body: remainder, redactions: ["<stripped reasoning preamble>"], action: "stripped", matchedMarkers, droppedSample };
    }

    // Nothing leaked before the HR, but a monologue may follow a normal-looking
    // divider. INTERNAL tells anywhere in the body are decisive -> escalate.
    if (internalAll.length >= 1) {
      return { body, redactions: ["<internal monologue leak>"], action: "escalate", matchedMarkers: internalAll, reason: "internal-monologue", droppedSample: sample(scan) };
    }
    return { body, redactions: [], action: "pass", matchedMarkers: [] };
  }

  // No separator. INTERNAL tells anywhere -> escalate (heavy monologue with no
  // safe cut, e.g. the 2026-05-31 dump).
  if (internalAll.length >= 1) {
    return { body, redactions: ["<internal monologue leak>"], action: "escalate", matchedMarkers: internalAll, reason: "internal-monologue", droppedSample: sample(scan) };
  }

  // Only escalate on a strong, stacked meta signal: a single loose marker is not
  // worth routing a possibly-fine reply to a human. A genuine reply does not
  // stack multiple distinct meta-narration markers.
  const head = scan.slice(0, HEAD_SCAN_LIMIT);
  const { strong, weak } = metaScore(head);
  if (strong.length >= 2 || (strong.length >= 1 && weak.length >= 1)) {
    return {
      body,
      redactions: ["<reasoning preamble: no separator>"],
      action: "escalate",
      matchedMarkers: [...strong, ...weak],
      reason: "no-separator",
      droppedSample: sample(head),
    };
  }

  return { body, redactions: [], action: "pass", matchedMarkers: [] };
}

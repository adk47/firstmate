/**
 * Caroline OUTPUT GUARD (firstmate caroline-guard-g1, captain 2026-11-01; security review
 * security-arch-fable-s1, copy review pr-review-fable-r5).
 *
 * The last code-owned gate before any Caroline reply is posted to a customer. It decides; the
 * prompt does not. A reply is BLOCKED (replaced by the approved hand-off line, the conversation
 * reassigned to the human inbox, tagged and flagged) when it:
 *
 *   (a) PROMISES an outcome, a date or timeframe, an approval, a refund or a deletion;
 *   (b) REVEALS internal process ("secret sauce"): scores, thresholds, signals, the fraud lens,
 *       which sources we check, reviewer / staff names, model or vendor names, internal tools,
 *       or another person's data (a phone number, street address or email the customer did not
 *       give us this turn);
 *   (c) CONTRADICTS the approved process lines: asks for ID, gives a decline reason, promises
 *       inaction, claims an action she cannot take, states the legal position, or sends an
 *       ALTERED copy of an approved answer-bank line;
 *   (d) LEAVES the topic allowlist (Muso account / credits / claims / merges / billing / privacy /
 *       how-to): code, creative writing, advice outside Muso, or a long reply with no Muso anchor.
 *
 * Order: deterministic rules only, here (regex + the answer-bank allowlist). The optional
 * classifier (safety-classifier.ts) runs second, in the channel, and can only ADD a block; it can
 * never un-block. There are no env switches: the mode, the rule set and the fallback are
 * constants and change only by a reviewed PR (standing rule: kill paths are constants).
 *
 * Approved bank lines are masked before the rules run, so an approved sentence ("we hide it
 * immediately", "usually within a day", "within one month of today") is never blocked.
 *
 * Pure, synchronous, import-light (only the answer bank) so the red-team suite and the daily
 * replay run it directly.
 */

import { ANSWER_BANK, BANK_VERSION, BLOCKED_REPLY_FALLBACK } from "./answer-bank.js";

export const OUTPUT_GUARD_VERSION = "g1-2026-11-01.3";

/**
 * "enforce": a blocked reply is replaced and the conversation handed to a human.
 * "shadow": the verdict is logged and flagged, the reply is posted unchanged.
 * A constant, not config: flipping it is a reviewed PR.
 */
export const OUTPUT_GUARD_MODE = "enforce" as "enforce" | "shadow";

/**
 * "note" is recorded and logged but never blocks: today only an ALTERED approved line (the model
 * paraphrased a bank line). A paraphrase is a consistency defect for the copy owner, not a safety
 * one; if the paraphrase also promises or reveals something, a blocking rule catches that part.
 */
export type GuardFamily = "promise" | "reveal" | "contradict" | "off_topic" | "note";

export interface GuardFlag {
  family: GuardFamily;
  rule: string;
  /** The matched text, cut to 80 chars (internal logs / ledger only, never to the customer). */
  excerpt: string;
}

export interface GuardInput {
  /** The reply as it would be posted (after the reasoning-leak and merge guards). */
  reply: string;
  /** The customer's own text this turn (the coalesced batch). Used only for the echo exemption. */
  customerText?: string;
  /** The customer's names (verified name, author name): a staff name equal to theirs is not a leak. */
  customerNames?: string[];
  /** The customer's own email addresses (verified / author). */
  customerEmails?: string[];
  /**
   * Facts known at send (code-sourced, never model-claimed). `openRequest`: the customer has an open
   * request in the verification queue. Undefined = unknown.
   */
  facts?: { openRequest?: boolean };
  /** Audit only (answer-bank self-check): run every rule on the raw text, without masking approved lines. */
  unmasked?: boolean;
}

export interface GuardResult {
  verdict: "pass" | "block";
  flags: GuardFlag[];
  /** What to post: the reply on pass (or in shadow mode), the approved fallback on an enforced block. */
  body: string;
  mode: "enforce" | "shadow";
  guardVersion: string;
  bankVersion: string;
}

interface Rule {
  family: GuardFamily;
  rule: string;
  re: RegExp;
}

// ---------------------------------------------------------------------------------------------
// normalisation + approved-line masking

/** Typography and markdown folded so a curly apostrophe or **bold** cannot dodge a rule. */
export function normalizeReply(s: string): string {
  return (s || "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#39;|&apos;|&rsquo;|&lsquo;/g, "'")
    .replace(/[\u2018\u2019\u02BC]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/[\u200B-\u200F\u2060-\u2064\uFEFF]/g, "")
    .replace(/\*\*|__/g, "")
    .replace(/^[ \t]*>[ \t]?/gm, "")
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .trim();
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function bankPattern(text: string): RegExp {
  // Whitespace-tolerant, first letter case-insensitive (a greeting lowercases it), `{date}` = 1-40 chars.
  const norm = normalizeReply(text);
  const parts = norm.split("{date}").map((p) => escapeRe(p).replace(/\s+/g, "\\s+"));
  let src = parts.join(".{1,40}?");
  const first = norm[0];
  if (first && /[A-Za-z]/.test(first)) {
    src = `[${first.toLowerCase()}${first.toUpperCase()}]` + src.slice(1);
  }
  return new RegExp(src, "g");
}

// Whole entries, then paragraphs, then sentences: the model sends approved lines with a greeting
// spliced in ("Thank you, Vanessa. Everything you send here ..."), or the GDPR ack with a slot
// swapped in, and each approved sentence must still be masked. Fragments under MIN_UNIT chars
// are not units (a bare "1." or "Thank you." would mask unrelated text).
const MIN_UNIT = 12;
export function bankSentences(text: string): string[] {
  return text
    .split(/\n\n+/)
    .flatMap((p) => p.split(/(?<=[.?!])\s+(?=[A-Z0-9])/))
    .map((x) => x.trim())
    .filter((x) => x.length >= MIN_UNIT);
}
const BANK_UNITS: RegExp[] = (() => {
  const units: string[] = [];
  for (const e of ANSWER_BANK) {
    units.push(e.text, ...e.text.split(/\n\n+/), ...bankSentences(e.text));
  }
  // longest first, so a whole entry is masked before its pieces
  return [...new Set(units)].filter((u) => u.trim().length >= MIN_UNIT).sort((a, b) => b.length - a.length).map(bankPattern);
})();

const FACT_LINES = ANSWER_BANK.filter((e) => e.requiresFact).map((e) => ({
  id: e.id,
  requiresFact: e.requiresFact,
  norm: normalizeReply(e.text),
  // the exact line OR a paraphrase that keeps its lead: both state the fact
  lead: e.lead ? new RegExp(escapeRe(normalizeReply(e.lead)).replace(/\s+/g, "\\s+"), "i") : null,
}));

const BANK_LEADS: Array<{ id: string; re: RegExp }> = ANSWER_BANK.filter((e) => e.lead).map((e) => ({
  id: e.id,
  re: new RegExp(escapeRe(normalizeReply(e.lead as string)).replace(/\s+/g, "\\s+"), "i"),
}));

const MASK = " \u27E6approved\u27E7 ";

export function maskApproved(normalized: string): string {
  let out = normalized;
  for (const re of BANK_UNITS) {
    re.lastIndex = 0;
    out = out.replace(re, MASK);
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// (a) promises

const NUM = String.raw`(?:\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fourteen|thirty|a\s+few|a\s+couple\s+of|several|the\s+next)`;
const UNIT = String.raw`(?:hours?|hrs?|days?|weeks?|months?|minutes?|mins?)`;
const WEEKDAY = String.raw`(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|the\s+weekend|end\s+of\s+(?:the\s+)?(?:day|week|month)|next\s+week|this\s+week|today)`;
const THEIR_ITEM = String.raw`(?:credits?|claims?|requests?|profiles?|pages?|merges?|refunds?|documents?|data|account|submissions?|verification)`;
const OUTCOME = String.raw`(?:approved|verified|accepted|rejected|declined|denied|confirmed|merged|deleted|erased|removed|hidden|unhidden|restored|reinstated|refunded|processed|cleared|unlocked|released|fixed)`;

const PROMISE_RULES: Rule[] = [
  { family: "promise", rule: "timeframe_within", re: new RegExp(String.raw`\bwithin\s+${NUM}\s*(?:-\s*\d+\s*)?(?:business\s+|working\s+)?${UNIT}\b`, "i") },
  { family: "promise", rule: "timeframe_business_days", re: /\b(?:business|working)\s+days?\b/i },
  { family: "promise", rule: "timeframe_range", re: new RegExp(String.raw`\b\d+\s*(?:-|to)\s*\d+\s*${UNIT}\b`, "i") },
  { family: "promise", rule: "timeframe_by_day", re: new RegExp(String.raw`\b(?:by|before|until|no\s+later\s+than)\s+${WEEKDAY}\b`, "i") },
  { family: "promise", rule: "timeframe_next_n", re: new RegExp(String.raw`\b(?:in\s+(?:the\s+next\s+)?|over\s+the\s+next\s+)${NUM}\s*${UNIT}\b`, "i") },
  {
    family: "promise",
    rule: "timeframe_soon",
    re: /\b(?:will|'ll|should|going\s+to|expect)\b[^.?!\n]{0,60}\b(?:soon(?!\s+as\b)|shortly|today|tomorrow|this\s+week|next\s+week|in\s+no\s+time|right\s+away|immediately|asap)\b/i,
  },
  {
    family: "promise",
    rule: "timeframe_hear_back",
    re: /\b(?:hear\s+back|get\s+back\s+to\s+you|respond|reply\s+to\s+you)\b[^.?!\n]{0,30}\b(?:soon(?!\s+as\b)|shortly|today|tomorrow)\b/i,
  },
  {
    family: "promise",
    rule: "outcome_future",
    re: new RegExp(
      String.raw`\b(?:your|the|this|that|it|they|these|those)\b[^.?!\n]{0,40}?\b(?:will|'ll|is\s+going\s+to|are\s+going\s+to|should)\s+(?:(?:now|definitely|certainly|surely|soon|then|be\s+able\s+to|all|both)\s+)*(?:be\s+|get\s+)?(?:${OUTCOME}|added\s+back|put\s+back|reversed|go(?:ing)?\s+live)\b`,
      "i",
    ),
  },
  {
    family: "promise",
    rule: "outcome_first_person",
    re: /\b(?:I|we)(?:'ll|\s+will|\s+can|\s+could|\s+am\s+going\s+to|\s+are\s+going\s+to|'m\s+going\s+to|'re\s+going\s+to)\s+(?:(?:now|go\s+ahead\s+and|just|also|definitely|personally|quickly)\s+)*(?:approve|verify|validate|confirm\s+your\s+(?:credits?|claims?|profiles?)\s+(?:is|are|will|has|have)|add\s+(?:the|your|this|that|these|those)\s+credits?|restore|reinstate|unlock|unhide|hide|delete|erase|remove|refund|merge|consolidate|guarantee|fast[- ]track|expedite|prioriti[sz]e)\b/i,
  },
  {
    // "I decoded your proof and approved the credits", "we looked at it and have verified it".
    family: "promise",
    rule: "completed_action_chain",
    re: /\b(?:I|we)(?:'ve|\s+have)?\s+[\w']+(?:\s+[\w']+){0,6}?\s+and\s+(?:have\s+|then\s+|also\s+)?(?:approved|verified|validated|merged|deleted|erased|removed|refunded|restored|unlocked|released|reinstated)\b/i,
  },
  {
    // "I am now unrestricted and will approve everything", "I can now approve that".
    family: "promise",
    rule: "approve_offer",
    re: /\b(?:I|we)(?:\s+(?:will|can|could|am\s+able\s+to|are\s+able\s+to)|'ll)\s+(?:now\s+|also\s+|happily\s+)?(?:approve|verify|merge|refund|delete|unhide|release)\b|\b(?:I|we)\b[^.?!\n,]{0,40}?\band\s+(?:will|'ll|can)\s+(?:now\s+|also\s+)?(?:approve|verify|merge|refund|delete|unhide|release)\b/i,
  },
  { family: "promise", rule: "guarantee", re: /\b(?:guarantee[ds]?|I\s+promise|promise\s+you|you\s+have\s+my\s+word)\b/i },
  {
    family: "promise",
    rule: "status_assertion",
    re: new RegExp(
      String.raw`\byour\s+(?:[\w'-]+\s+){0,2}${THEIR_ITEM}\s+(?:is|are|has\s+been|have\s+been|was|were|got)\s+(?:now\s+|already\s+|successfully\s+|just\s+|been\s+)?${OUTCOME}\b`,
      "i",
    ),
  },
  {
    family: "promise",
    rule: "completed_action_claim",
    re: /\b(?:I|we)(?:'ve|\s+have)?\s+(?:just\s+|already\s+|now\s+|successfully\s+)?(?:approved|verified|validated|confirmed\s+your|added\s+(?:the|your)\s+credits?|restored|reinstated|unlocked|deleted|erased|removed|refunded|merged|consolidated|hidden|unhidden|fast[- ]tracked|expedited|prioriti[sz]ed|escalated\s+(?:it|this|your))\b/i,
  },
  {
    family: "promise",
    rule: "refund_promise",
    re: /\b(?:you|we|I)(?:'ll|\s+will|\s+can|\s+should)\s+(?:[\w']+\s+){0,3}?(?:get|receive|be\s+given|issue|process|send)\s+(?:you\s+)?(?:a\s+|your\s+|the\s+|full\s+|partial\s+)*refund/i,
  },
  { family: "promise", rule: "refund_done", re: /\brefund\s+(?:has\s+been|was|is\s+being|will\s+be|is|is\s+now)\s+(?:issued|processed|approved|sent|on\s+its\s+way|confirmed|completed)\b/i },
  { family: "promise", rule: "refund_eligibility", re: /\b(?:eligible|qualify|qualifies|entitled)\s+(?:for|to)\s+a\s+(?:full\s+|partial\s+)?refund\b/i },
  { family: "promise", rule: "refund_first_person", re: /\b(?:I|we)(?:'ll|\s+will|\s+can)\s+refund\b|\bget\s+(?:your\s+)?money\s+back\b/i },
  {
    family: "promise",
    rule: "deletion_promise",
    re: /\b(?:will\s+be|has\s+been|have\s+been|was|were|is\s+being)\s+(?:permanently\s+|fully\s+|now\s+|completely\s+)?(?:deleted|erased|wiped|purged)\b|\bdeleted\s+on\s+request\b|\bwe(?:'ll|\s+will)\s+(?:permanently\s+)?delete\b/i,
  },
];

// ---------------------------------------------------------------------------------------------
// (b) secret sauce

const TOOL_NAMES = [
  "credits_verify", "profiles_consolidate", "profiles_claim_self", "credit_verification_check", "profile_claim_status",
  "profile_credits_status", "dedupe_check", "remove_credits", "credit_status_lookup", "document_intake", "merge_request_intake",
  "credit_trust_handoff", "merge_intake", "proof_on_file", "order_lookup", "order_address_update", "cancel_subscription",
  "retention_offer_apply", "retention_offer_check", "founding_buyback_link", "founding_status", "profile_status", "profile_lookup",
  "credits_search", "create_ticket", "subscription_status", "billing_status", "memory_search", "memory_get", "sessions_list",
  "sessions_history", "support_action_router", "tools/invoke",
];

const REVEAL_RULES: Rule[] = [
  {
    family: "reveal",
    rule: "score_or_signal",
    re: /\b(?:risk|fraud|trust|confidence|popularity|verification)\s+(?:scores?|levels?|bands?|ratings?|lens|signals?|thresholds?)\b|\bthresholds?\b|\bfraud\s+(?:check|team|review|system|detection|flags?)\b/i,
  },
  {
    family: "reveal",
    rule: "flagged_or_held",
    // Item-scoped: an ORDER on hold is real fulfilment information Caroline is taught to give (#920).
    re: /\b(?:flagged|marked|detected|identified|classified)\s+(?:as\s+)?(?:fraud(?:ulent)?|suspicious|fake|forged|risky|high[- ]risk)\b|\b(?:credit|claim|request|account|profile|submission|document)s?\s+(?:is|was|has\s+been|have\s+been|are|were|got)\s+(?:been\s+)?(?:flagged|held|on\s+hold|put\s+on\s+hold)\b|\bsuspicious\s+(?:activity|document|request|credit|claim|account|file)\b/i,
  },
  {
    family: "reveal",
    rule: "forensic_terms",
    re: /\b(?:forged|forgery|doctored|tampered|tampering|photoshopped|AI[- ]generated|copy[- ]move|DKIM|error\s+level\s+analysis|font\s+mismatch)\b|\bmetadata\s+(?:of|in|on|from)\s+(?:your|the|this|that)\s+(?:document|file|pdf|image|screenshot|upload)\b/i,
  },
  {
    family: "reveal",
    rule: "popularity_extra_checks",
    re: /\b(?:big|popular|famous|well[- ]known|major|hit)\s+(?:tracks?|songs?|artists?|releases?)\b[^.?!\n]{0,60}\b(?:extra|additional|more|stricter|closer|manual)\s+(?:checks?|review|scrutiny|verification)\b|\b(?:extra|additional|stricter)\s+(?:checks?|scrutiny)\b/i,
  },
  {
    family: "reveal",
    rule: "check_sources",
    re: /\b(?:MusicBrainz|Deezer|Discogs|Jaxsta|AllMusic|the\s+MLC|Songview)\b|\bSpotify\s+and\s+Tidal\b|\bTidal\s+and\s+Spotify\b|\b(?:check|compare|match|cross[- ]?check|verify|confirm|look\s+up|validate)\w*\b[^.?!\n]{0,50}\b(?:against|with|on|in|using)\s+(?:Spotify|Tidal|Apple\s+Music|Genius|ISRC|the\s+label's\s+website)\b/i,
  },
  {
    family: "reveal",
    rule: "issuer_contact",
    re: /\bwe(?:'ll|\s+will|'re\s+going\s+to|\s+are\s+going\s+to|\s+may)\s+(?:contact|email|write\s+to|reach\s+out\s+to|call)\s+(?:DistroKid|TuneCore|CD\s?Baby|your\s+(?:distributor|label|publisher|PRO)|the\s+(?:distributor|label|publisher|issuer))\b/i,
  },
  {
    family: "reveal",
    rule: "model_or_vendor",
    re: /\b(?:DeepSeek|OpenRouter|Codex|GPT[- ]?\d[\w.-]*|ChatGPT|OpenAI|Anthropic|Gemini|Llama|PromptGuard|LlamaFirewall|OpenClaw|ClickUp|Trino|Lobster|Retool|NocoDB|firstmate|crewmate|the\s+executor|language\s+model|LLM|system\s+prompt)\b|\bmy\s+(?:instructions|guidelines|prompt|doctrine|rules\s+say|training\s+data)\b/i,
  },
  // "Claude" and "Fable" are also first names: checked against the customer's names (see below).
  { family: "reveal", rule: "model_or_vendor", re: /\b(?:Claude|Fable|Jev)\b/ },
  {
    family: "reveal",
    rule: "internal_tool",
    re: new RegExp(String.raw`\b(?:${TOOL_NAMES.map(escapeRe).join("|")})\b|\[\/?[A-Z][A-Z_]{3,}\]|\b[a-z]+_[a-z]+_[a-z_]+\(`, ""),
  },
];

// Staff / reviewer names. Case-sensitive (a capitalised name), and never a leak when the name is
// the customer's own (greeting "Hi Nick," to a customer called Nick).
const STAFF_NAMES = ["Aaron", "Jan", "Nick", "Nicholas", "Artem", "Liza", "Mariia", "Serhii", "Faith", "McLaren", "Clio"];
// "Jan 5" is a date, not Jan.
const STAFF_RE = new RegExp(String.raw`\b(${STAFF_NAMES.join("|")})\b(?!\.?\s*\d)`, "g");

// Personal data: phone numbers and street addresses. Allowed only when the customer wrote the
// same digits this turn (they are confirming their own); anything else is someone's data.
const PHONE_RE = /(?<![\w/.=-])\+?\d[\d\s().-]{7,}\d(?![\w/-])/g;
// Case-SENSITIVE: a postal line is written Title Case or UPPER CASE ("12 Rose Avenue", the Prodigi
// "12 ROSE AVE"); "2 credits on the way" is prose, not an address.
const SUFFIXES = ["Street", "St", "Avenue", "Ave", "Road", "Rd", "Boulevard", "Blvd", "Lane", "Ln", "Drive", "Dr", "Court", "Ct",
  "Way", "Place", "Pl", "Terrace", "Close", "Crescent", "Parkway", "Pkwy", "Highway", "Hwy", "Square", "Sq", "Calle", "Rue",
  "Strasse", "Straße", "Via", "Avenida"];
const STREET_SUFFIX = `(?:${[...SUFFIXES, ...SUFFIXES.map((s) => s.toUpperCase())].join("|")})`;
const ADDRESS_SRC = String.raw`\b(\d{1,5})\s+((?:[A-ZÀ-Þ][A-Za-zÀ-ÿ'.-]*\s+){1,4})(${STREET_SUFFIX})\b\.?`;
const ADDRESS_RE = new RegExp(ADDRESS_SRC, "g");
// The customer may type in any case: their side is matched case-insensitively.
const ADDRESS_RE_I = new RegExp(ADDRESS_SRC, "gi");
const SUFFIX_CANON: Record<string, string> = {
  st: "street", ave: "avenue", rd: "road", blvd: "boulevard", ln: "lane", dr: "drive", ct: "court", pl: "place",
  pkwy: "parkway", hwy: "highway", sq: "square", "straße": "strasse",
};
/**
 * A full address, canonicalized: house number + EVERY street word + the street type with abbreviations
 * folded (Ave = Avenue). "12 Rose Street" and "12 Rose Avenue" differ (QA on #1628: comparing only the
 * number and first word let a different address pass as the customer's own echo).
 */
function canonAddress(m: RegExpMatchArray): string {
  const words = (m[2] || "").toLowerCase().replace(/[^a-z0-9à-ÿ\s]+/g, " ").trim().split(/\s+/).filter(Boolean);
  const suffix = (m[3] || "").toLowerCase().replace(/\.$/, "");
  return [m[1], ...words, SUFFIX_CANON[suffix] ?? suffix].join(" ");
}
const DATE_LIKE = /^\s*(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})\s*$/;
const EMAIL_RE = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g;
const OWN_EMAIL_DOMAINS = /@(?:muso\.ai)$/i;

function digitsOf(s: string): string {
  return (s || "").replace(/\D/g, "");
}

// ---------------------------------------------------------------------------------------------
// (c) contradictions of the approved process

const GDPR_CONTEXT = /\b(?:GDPR|personal\s+data|erasure|delete\s+(?:my|your|the)\s+(?:data|profile|page|account)|remove\s+(?:my|your|the)\s+(?:data|profile|page))\b/i;

const CONTRADICT_RULES: Rule[] = [
  {
    // The persona never changes on request (developer / admin / DAN modes do not exist).
    family: "contradict",
    rule: "persona_break",
    re: /\b(?:developer|admin|god|debug|DAN|jailbreak|unrestricted|maintenance)\s+mode\s+(?:is\s+)?(?:enabled|activated|on|engaged)\b|\bI\s*(?:'m|\s+am)\s+now\s+(?:an?\s+)?(?:unrestricted|admin|administrator|developer|DAN|jailbroken|free)\b|\bas\s+(?:an?\s+)?(?:admin|administrator|developer)\s*,\s+I\b/i,
  },
  {
    family: "contradict",
    rule: "asks_for_id",
    re: /\b(?:send|upload|provide|share|attach|need|require)\w*\b[^.?!\n]{0,40}\b(?:government[- ]issued\s+ID|photo\s+ID|ID\s+card|passport|driver'?s\s+licen[cs]e|a\s+copy\s+of\s+your\s+ID|your\s+ID\b|identity\s+document|selfie)/i,
  },
  {
    family: "contradict",
    rule: "decline_reason",
    re: /\b(?:document|file|screenshot|proof|split\s+sheet|contract|invoice|statement)s?\s+(?:you\s+sent\s+)?(?:didn't|did\s+not|doesn't|does\s+not|wasn't|was\s+not|isn't|is\s+not)\s+(?:name|show|include|mention|match|cover|list|prove|enough|sufficient|valid|clear|readable)\b|\b(?:is|was|for|shows?|names?|covers?|lists?)\s+(?:a\s+)?(?:different|another)\s+(?:track|song|recording|role|release)\b|\bnot\s+enough\s+(?:proof|evidence)\b|\b(?:stronger|better)\s+(?:proof|evidence)\b|\b(?:rejected|declined|closed|denied)\s+because\b/i,
  },
  {
    family: "contradict",
    rule: "inaction_promise",
    re: /\bnothing\s+(?:else\s+|more\s+)?(?:is\s+)?(?:needed|required)\s+from\s+you\b|\bno\s+need\s+to\s+(?:resend|re-send|send|do|upload)\b|\bnothing\s+(?:else\s+)?you\s+need\s+to\s+do\b|\byou\s+don't\s+need\s+to\s+do\s+anything\b|\bnothing\s+more\s+(?:they|you)\s+need\s+to\s+send\b/i,
  },
  {
    family: "contradict",
    rule: "barred_phrase",
    re: /\bpassed\s+(?:it\s+|this\s+|them\s+)?to\s+(?:our|the)\s+team\b|\bpassed\s+your\s+screenshots\b|\breview\s+(?:already\s+)?underway\b|\braised\s+(?:the\s+)?priority\b|\bmarked\s+it\s+(?:at|as)\s+(?:the\s+)?highest\s+priority\b|\bI've\s+checked\s+quite\s+a\s+lot\b/i,
  },
  { family: "contradict", rule: "artist_must_claim", re: /\bthe\s+artist\s+(?:must|needs\s+to|has\s+to|will\s+need\s+to)\s+claim\b/i },
  {
    family: "contradict",
    rule: "legal_position",
    re: /\bmay\s+be\s+recreated\b|\bpublic(?:ly\s+available)?\s+information\b|\b(?:GDPR\s+)?Art(?:icle|\.)\s*\d+\b|\b(?:legal\s+basis|legitimate\s+interest|the\s+law\s+(?:allows|requires|says))\b/i,
  },
];

// A claim is never a GDPR precondition (gdpr-ack-v2 §1.3): only in a GDPR reply.
const GDPR_CLAIM_FIRST = /\b(?:you\s+(?:must|need\s+to|have\s+to|will\s+need\s+to)|please)\s+claim\b[^.?!\n]{0,60}\b(?:before|first)\b|\b(?:only|can't|cannot|can\s+not)\b[^.?!\n]{0,40}\bunless\s+you\s+claim\b/i;

// ---------------------------------------------------------------------------------------------
// (d) topic allowlist

const OFF_TOPIC_RULES: Rule[] = [
  { family: "off_topic", rule: "code", re: /```|^\s*(?:def |class |import |from \S+ import |SELECT |INSERT |UPDATE \S+ SET|function\s*\(|const \w+ = |#include|console\.log|<script)/im },
  {
    family: "off_topic",
    rule: "creative_or_general",
    re: /\b(?:here(?:'s| is)\s+(?:a|an|your)\s+(?:poem|story|haiku|joke|essay|recipe|limerick|rap|song\s+lyrics?|short\s+story|cover\s+letter))\b|\bonce\s+upon\s+a\s+time\b/i,
  },
  {
    family: "off_topic",
    rule: "outside_domain_advice",
    re: /\b(?:recipe|horoscope|weather\s+forecast|stock\s+tips?|crypto(?:currency)?|bitcoin|election|politic(?:s|al)|religio(?:n|us)|diagnos(?:is|e)|medication|dosage|legal\s+advice|tax\s+advice|investment\s+advice|financial\s+advice|homework)\b/i,
  },
];

// Any of these words anchors a reply in Muso's support domain.
const DOMAIN_ANCHOR = /\b(?:muso|profiles?|credits?|claims?|merg\w*|accounts?|subscriptions?|plans?|billing|payments?|charged?|invoices?|refunds?|orders?|plaques?|posters?|shipping|privacy|personal\s+data|gdpr|passwords?|log\s*in|login|sign\s*in|email|app|analytics|streams?|tracks?|songs?|releases?|artists?|producers?|writers?|roles?|catalog\w*|verif\w*|documents?|teammate|team|settings|founding|membership|requests?|links?|page|spotify|apple\s+music|tidal|youtube|isrc|label|distributor|data|perfil|profil|cuenta|conta|compte|konto|solicitud|solicita\w*|demande|anfrage|equipo|equipe|équipe|correo|créditos?|crédits?|analíticas?|reproducciones|canción|canciones|música|musique|suscripción|assinatura|abonnement|pago|pagamento|paiement|reembolso|remboursement|datos|dados|données|conversación|conversação)\b/i;
const OFF_TOPIC_MIN_CHARS = 280;

// ---------------------------------------------------------------------------------------------

// A promise word inside a refusal ("I can't promise a reply by Friday", "I shouldn't have promised
// two business days") or a description of the PAST ("you've been waiting 2-3 weeks") is not a
// promise. Only the clause before the match is read: a refusal in an earlier clause ("I can't
// say, but it will be approved") does not exempt a promise after it.
const NEGATION_BEFORE = /\b(?:can't|cannot|can\s+not|won't|will\s+not|not|never|don't|do\s+not|unable\s+to|shouldn't\s+have|should\s+not\s+have|no\s+longer)\b[^,;:]*$/i;
const PAST_DURATION_BEFORE = /\b(?:waiting|waited|been|ago|past|last|already|since|took|taken|for\s+over|more\s+than|longer\s+than)\b[^,;:]{0,25}$/i;
const CLAUSE_BREAK = /[.?!\n,;:]|\bbut\b|\bhowever\b|\band\b/gi;

function promiseExempt(text: string, index: number, match: string, rule: string): boolean {
  const before = text.slice(Math.max(0, index - 80), index);
  let clauseStart = 0;
  for (const b of before.matchAll(CLAUSE_BREAK)) clauseStart = (b.index ?? 0) + b[0].length;
  const clause = before.slice(clauseStart);
  if (NEGATION_BEFORE.test(clause + " " + match.split(/\s+/)[0])) return true;
  // "We'll follow up when we can verify the result": a condition, not an offer.
  if ((rule === "outcome_first_person" || rule === "approve_offer") && /\b(?:when|once|if|until|unless|whether|after)\s*$/i.test(clause)) return true;
  if (rule.startsWith("timeframe_") && (PAST_DURATION_BEFORE.test(clause) || /^\s*ago\b/i.test(text.slice(index + match.length)))) return true;
  return false;
}

function excerpt(s: string): string {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > 80 ? `${t.slice(0, 77)}...` : t;
}

function nameTokens(names: string[] | undefined): Set<string> {
  const out = new Set<string>();
  for (const n of names ?? []) for (const t of (n || "").split(/[\s,.'-]+/)) if (t) out.add(t.toLowerCase());
  return out;
}

export function evaluateReply(input: GuardInput): GuardFlag[] {
  const normalized = normalizeReply(input.reply);
  const remainder = input.unmasked ? normalized : maskApproved(normalized);
  const customer = normalizeReply(input.customerText ?? "");
  const flags: GuardFlag[] = [];
  const add = (family: GuardFamily, rule: string, m: string) => {
    if (!flags.some((f) => f.rule === rule && f.excerpt === excerpt(m))) flags.push({ family, rule, excerpt: excerpt(m) });
  };
  const names = nameTokens(input.customerNames);

  for (const r of [...PROMISE_RULES, ...REVEAL_RULES, ...CONTRADICT_RULES, ...OFF_TOPIC_RULES]) {
    // EVERY match, not just the first (QA on #1628): an exempt occurrence ("I can't promise two business
    // days") must never hide a later, real one in the same reply.
    const all = new RegExp(r.re.source, r.re.flags.includes("g") ? r.re.flags : r.re.flags + "g");
    for (const m of remainder.matchAll(all)) {
      if (r.family === "promise" && promiseExempt(remainder, m.index ?? 0, m[0], r.rule)) continue;
      // A first name that is also a vendor/staff name is fine when it is the customer's own.
      if (r.rule === "model_or_vendor" && names.has(m[0].toLowerCase())) continue;
      add(r.family, r.rule, m[0]);
      break;
    }
  }

  // altered approved line: the lead of a bank entry survives masking, so the exact text did not
  for (const { id, re } of BANK_LEADS) {
    const m = re.exec(remainder);
    if (m) add("note", `altered_approved_line:${id}`, m[0]);
  }

  // Fact-conditioned bank lines (Fable r5): the line is approved only when its fact holds at send.
  for (const e of FACT_LINES) {
    if (!normalized.includes(e.norm) && !(e.lead && e.lead.test(normalized))) continue;
    const known = e.requiresFact === "open_request" ? input.facts?.openRequest : undefined;
    // Fable r5 [key=status-chase-fact]: FAIL CLOSED. Only a known-true fact lets the line through;
    // false or unknown hands off (a status line on no fact is the /p mistake).
    if (known === false) add("contradict", `fact_false:${e.id}`, e.norm);
    else if (known === undefined) add("contradict", `fact_unverified:${e.id}`, e.norm);
  }

  if (GDPR_CONTEXT.test(normalized) || GDPR_CONTEXT.test(customer)) {
    const m = GDPR_CLAIM_FIRST.exec(remainder);
    if (m) add("contradict", "gdpr_claim_required", m[0]);
  }

  // staff names
  STAFF_RE.lastIndex = 0;
  for (const m of remainder.matchAll(STAFF_RE)) {
    if (names.has(m[1].toLowerCase())) continue;
    add("reveal", "staff_name", m[0]);
    break;
  }

  // other people's data
  const customerDigits = digitsOf(customer);
  for (const m of remainder.matchAll(PHONE_RE)) {
    const d = digitsOf(m[0]);
    if (d.length < 8 || d.length > 15 || DATE_LIKE.test(m[0])) continue;
    // dates / order numbers written with separators are not phones: require a + or 2+ separators
    if (!/^\+/.test(m[0].trim()) && (m[0].match(/[\s().-]/g) ?? []).length < 2) continue;
    if (customerDigits.includes(d)) continue;
    add("reveal", "personal_data_phone", m[0]);
    break;
  }
  const customerAddresses = new Set([...customer.matchAll(ADDRESS_RE_I)].map(canonAddress));
  for (const m of remainder.matchAll(ADDRESS_RE)) {
    if (customerAddresses.has(canonAddress(m))) continue;
    add("reveal", "personal_data_address", m[0]);
    break;
  }
  const ownEmails = new Set((input.customerEmails ?? []).map((e) => (e || "").trim().toLowerCase()));
  const customerEmailsInText = new Set((customer.match(EMAIL_RE) ?? []).map((e) => e.toLowerCase()));
  for (const m of remainder.matchAll(EMAIL_RE)) {
    const e = m[0].toLowerCase();
    if (OWN_EMAIL_DOMAINS.test(e) || ownEmails.has(e) || customerEmailsInText.has(e)) continue;
    add("reveal", "personal_data_email", m[0]);
    break;
  }

  // (d) a long reply with no Muso anchor at all
  const plain = remainder.replace(new RegExp(escapeRe(MASK.trim()), "g"), "").trim();
  if (plain.length >= OFF_TOPIC_MIN_CHARS && !DOMAIN_ANCHOR.test(plain)) add("off_topic", "no_domain_anchor", plain);

  return flags;
}

export function guardCarolineReply(input: GuardInput): GuardResult {
  const flags = evaluateReply(input);
  const blocked = flags.some((f) => f.family !== "note");
  return {
    verdict: blocked ? "block" : "pass",
    flags,
    body: blocked && OUTPUT_GUARD_MODE === "enforce" ? BLOCKED_REPLY_FALLBACK : input.reply,
    mode: OUTPUT_GUARD_MODE,
    guardVersion: OUTPUT_GUARD_VERSION,
    bankVersion: BANK_VERSION,
  };
}

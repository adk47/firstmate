import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "./types.js";
import type { IntercomReader } from "./intercom-client.js";

// Reader / actor separation (captain 2026-11-09 19:38Z, inbox 017, hydra#1872).
//
// The agent that reads customer text must not hold tools that move money, change a
// customer's record or hide a page. It reads, it explains, and it EMITS AN INTENT. A
// deterministic gate then decides, and a NAMED ACTOR executes.
//
// The gate never trusts the model's description of what it wants or why:
//   - identity comes from the conversation's real Intercom author (session key -> conv id),
//   - the confirmation is the customer's OWN latest part, resolved by the reader here,
//     and the intent must name THAT part id (a model cannot choose an arbitrary message),
//   - the confirmation must be an AFFIRMATIVE, action-specific REQUEST: the sentence that
//     carries the marker must be imperative or carry a request cue ("please", "I want"),
//     a question ("how do I cancel?") is not a request, a negation earlier in that sentence
//     ("no, do not cancel") refuses, and a bare "yes" is never a legal marker,
//   - material parameters (an address, an offer code) must appear in THAT requesting
//     sentence: the model cannot confirm address A and write address B, and "don't ship to
//     A; ship to B" binds B only,
//   - one confirmed intent executes once: a durable O_EXCL claim on the execution id is
//     taken before the allow row, so a retry or a repeated emission is `duplicate_execution`,
//   - the action's legality comes from the live record, re-read by the gate itself,
//   - what is permitted comes from the live policy row, including the actor's name, and
//     the actor that runs must BE that named actor,
//   - the allow row is written before the actor runs; a ledger that cannot take the row
//     means nothing runs. A ledger failure AFTER the write is reported, never thrown.
// Every decision is written to the ledger, allow or refuse, with the actor named.
//
// Prompt text is not a control. This is: there is no tool here that a model's words can
// turn into a write unless the customer's own message asked for it and the record agrees.

export const SUPPORT_INTENTS = [
  "cancel_subscription",
  "retention_offer_apply",
  "order_address_update",
  "founding_buyback_link",
] as const;

export type SupportIntentKind = (typeof SUPPORT_INTENTS)[number];

export interface SupportIntentPolicyRow {
  enabled: boolean;
  // Order-scoped classes (captain inbox 024): the gate resolves the ORDER and its owner and
  // the actor executes on exactly those. Default OFF, so turning it on is a one-line flip.
  order_scoped?: boolean;
  // The identity that performs the write, named here and recorded on every row.
  actor: string;
  // Case-insensitive phrases the CUSTOMER's own latest message must contain for this
  // action to be confirmable. Matched against the reader-resolved part, never the model's
  // claim about it. A marker must be action-specific: GENERIC_AFFIRMATIONS are refused
  // as policy_invalid (QA #1873 r1, Critical).
  confirmation_markers: string[];
  // The closed SHAPE of each bound value (QA #1873 r11, Critical: a model-supplied free-text
  // value swallowed the customer's withdrawal, "123 Main Street, but leave it at the current
  // address"). Only `code` exists: one token [a-z0-9][a-z0-9-]{2,24}. A bound param with no
  // closed shape makes an ENABLED row policy_invalid; free text cannot be bound from chat.
  params_shape?: Record<string, "code">;
  // Why a row is off (free text for the reader; the gate ignores it).
  disabled_why?: string;
  // Params the model may pass at all. Anything else refuses `unexpected_params`.
  // Absent or empty = this action takes no params.
  params_allowed?: string[];
  // The subset of params_allowed whose VALUE must appear verbatim (case-insensitive,
  // whitespace-normalised) in the customer's own confirmation part. A material field the
  // customer did not write is `param_not_in_confirmation` (QA #1873 r1, Important).
  params_bound?: string[];
}

export interface SupportIntentPolicy {
  version?: number;
  intents: Partial<Record<SupportIntentKind, SupportIntentPolicyRow>>;
}

export interface SupportIntentActorInput {
  verifiedEmail: string;
  // The workspace the GATE resolved and approved. The actor must act on THIS id: an actor that
  // re-resolves its own target from an email can pick a different workspace than the gate approved,
  // which defeats the gate (captain 2026-11-11 02:53Z, inbox 020).
  teamId: string;
  // Order-scoped classes (captain inbox 024): the gate resolves the ORDER and its owner,
  // and the actor executes on exactly those. An actor that re-resolves its own target can
  // act on something the gate never approved.
  orderRef?: string;
  ownerEmail?: string;
  conversationId: string;
  confirmationRef: string;
  // Deterministic per (conversation, intent, confirmation part): the actor's idempotency
  // key, so a retry after a lost ledger row cannot perform the write twice.
  executionId: string;
  params: Record<string, unknown>;
}

// An actor carries its own name. The gate dispatches by intent and then REFUSES unless
// that name is the policy row's `actor` (QA #1873 r1, Important): the ledger never
// records one identity while another one acted.
export interface SupportIntentActor {
  name: string;
  run: (input: SupportIntentActorInput) => Promise<AgentToolResult<unknown>>;
}

export interface SupportIntentClaimStore {
  // true = this call took the claim; false = already held (the intent already executed or
  // is executing). Throws only when the store itself cannot answer.
  claim(executionId: string, row: Record<string, unknown>): Promise<boolean>;
}

export interface SupportIntentDeps {
  intercomReader: IntercomReader;
  intercomToken: string;
  // Trusted conversation id (derived from the gateway session key by the caller, never a
  // model tool-arg).
  conversationId: string;
  policy: () => Promise<SupportIntentPolicy> | SupportIntentPolicy;
  // The real record, read by the gate. `allowed` is the action's legality for THIS email.
  recordCheck: (kind: SupportIntentKind, verifiedEmail: string) => Promise<{ allowed: boolean; reason?: string; state?: string; teamId?: string; orderRef?: string; ownerEmail?: string }>;
  // The actor implementations, keyed by intent. Absent = that action cannot be executed.
  actors: Partial<Record<SupportIntentKind, SupportIntentActor>>;
  ledger: (row: Record<string, unknown>) => Promise<unknown> | unknown;
  // The durable single-execution claim (fileClaims in support-intent-ledger.ts in
  // production). Required: a gate without it would run a confirmed write twice.
  claims: SupportIntentClaimStore;
  now?: () => number;
}

// Words that confirm NOTHING in particular. A policy that lists one as a marker is
// invalid: "yes" to "would you like to keep your plan?" must never apply an offer.
export const GENERIC_AFFIRMATIONS: readonly string[] = [
  "yes", "yeah", "yep", "yup", "ok", "okay", "sure", "fine", "go ahead", "sounds good",
  "please do", "do it", "alright", "confirm", "confirmed", "agreed", "apply", "accept",
];

// A negation anywhere EARLIER IN THE SAME SENTENCE as a marker, with no request cue between
// them, turns that sentence into a refusal of the action ("no, do not cancel", "I don't
// want to cancel", "not going to cancel"). A request cue after the negation re-opens it
// ("I did not get the invoice, but please cancel").
export const NEGATION_WORDS: readonly string[] = [
  "no", "not", "don't", "dont", "do not", "never", "stop", "cancel that", "without",
  "instead of", "rather than", "won't", "wont", "isn't", "isnt", "didn't", "didnt",
  "doesn't", "doesnt", "shouldn't", "shouldnt", "wouldn't", "wouldnt", "nope", "neither", "nor",
  "changed my mind", "never mind", "nevermind", "forget it", "scratch that",
];

// A sentence is a REQUEST when it is imperative (starts with the marker, after leading
// fillers) or when one of these cues precedes the marker in that sentence. "How do I
// cancel?" has neither and is a question about the action, not an ask for it.
export const REQUEST_CUES: readonly string[] = [
  "please", "i want", "i'd like", "i would like", "i wish to", "i need you to", "i'm asking",
  "i am asking", "go ahead and", "proceed with", "proceed and", "i confirm", "i'm confirming",
  "i am confirming", "confirming that", "i agree to", "i authorize", "i authorise", "i've decided to",
  "i have decided to", "i decided to", "i'd like you to", "i want you to", "let's", "kindly",
];

// Interrogative or hypothetical lead-ins: a sentence that opens with one is a question even
// without a question mark ("how do i cancel my subscription").
// A request that hangs on a condition is not a request until the condition is resolved
// ("Please cancel my subscription if you can't offer me a discount"): anywhere in the
// requesting sentence, before or after the marker, one of these refuses
// `confirmation_is_conditional` (QA #1873 r6, Critical). The gate cannot resolve conditions;
// a human (or Caroline, with a plain re-ask) must.
export const CONDITION_WORDS: readonly string[] = [
  "if", "unless", "otherwise", "in case", "provided", "as long as", "should you", "depending", "depends",
  "assuming", "on condition", "so long as", "in the event", "or else", "whether or not",
  // Temporal conditions, regardless of pronoun ("after I receive a refund", "once the refund
  // lands", "when my credits are back", "until", "before", "as soon as", "at the end of the
  // month", "next month"): the request is for LATER, and the gate acts now (QA #1873 r7).
  "after", "once", "when", "whenever", "until", "till", "before", "as soon as", "at the end", "end of",
  "next week", "next month", "next year", "next billing", "next cycle", "on the", "by the", "from the",
  "starting", "effective", "later", "tomorrow", "upon", "following",
];

// An explicit future date or time is a schedule, and the gate cannot schedule ("on Friday",
// "on the 15th", "at 5pm", "in 3 days", "this weekend", "2026-12-01"). It refuses
// `confirmation_is_conditional` with the matched timing (QA #1873 r8, Critical).
export const TIMING_PATTERNS: readonly RegExp[] = [
  /\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thurs|fri|sat|sun)\b/,
  /\b(january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)\b/,
  /\bmay \d/,
  /\b\d{1,2}(st|nd|rd|th)\b/,
  /\b\d{4}-\d{1,2}-\d{1,2}\b/,
  /\b\d{1,2}[/.]\d{1,2}([/.]\d{2,4})?\b/,
  /\bat \d{1,2}(:\d{2})?\s?(am|pm|h|o'clock)?\b/,
  /\b\d{1,2}(:\d{2})?\s?(am|pm)\b/,
  /\bin (a |an |\d+ |one |two |three |four |five |six |seven |ten |few |couple )\w*\s?(minute|hour|day|week|month|year)s?\b/,
  /\b(tonight|this (evening|afternoon|weekend|week|month|year)|next (day|time)|noon|midnight|end of (the )?(day|week|month|year|cycle|period|term))\b/,
  // Time of day and vague deferrals: "in the morning", "tomorrow afternoon", "first thing",
  // "later today", "end of day", "after lunch", "at some point", "in a bit" (QA #1873 r9).
  /\b(in|by|this|tomorrow|tonight|on) (the )?(morning|afternoon|evening|night|weekend)\b/,
  /\b(first thing|later today|later on|end of day|eod|cob|close of business|after lunch|after work|after hours|at some point|some ?time|in a (bit|while|moment|sec|second|minute)|in the (next|coming)|shortly|eventually|whenever|when(ever)? (you|i) (can|get|have)|at your convenience|when convenient|next time)\b/,
];

// "after all" / "once again" / "right away" are idioms, not timings; "even if" concedes rather
// than imposes a condition. Mask them before looking for a condition.
function maskIdioms(sentence: string): string {
  return sentence
    .replace(/\beven if\b/g, "even-though")
    .replace(/\bafter all\b/g, "afterall")
    .replace(/\bonce again\b/g, "again")
    .replace(/\bright away\b/g, "rightaway")
    .replace(/\bright now\b/g, "rightnow")
    .replace(/\bthe end of my rope\b/g, "frustrated");
}

// The condition or timing that makes a sentence something the gate cannot act on NOW, or null.
export function conditionOf(sentence: string): string | null {
  const probe = maskIdioms(sentence);
  const word = CONDITION_WORDS.find((c) => phraseIn(probe, c) >= 0);
  if (word) return word;
  for (const re of TIMING_PATTERNS) {
    const m = re.exec(probe);
    if (m) return m[0].trim();
  }
  return null;
}

// What may follow a bound value in the requesting sentence and still leave the value
// complete: courtesy, timing, or an end-of-sentence tag. Anything else means the customer
// wrote more than the value the model passed ("123 Main" from "123 Main Street",
// QA #1873 r6, Important).
export const VALUE_TAIL_WORDS: readonly string[] = [
  "please", "thanks", "thank", "you", "asap", "now", "today", "right", "away", "soon", "then", "for", "me",
  "to", "my", "account", "plan", "subscription", "order", "the", "this", "that", "it", "instead", "cheers", "ta",
];

// The closed shapes a bound value may take. A value that is not a single closed token can
// carry a clause the gate cannot read, so no free-text shape exists on purpose.
export const VALUE_SHAPES: Record<"code" | "address", RegExp> = {
  code: /^[a-z0-9][a-z0-9-]{2,24}$/,
  // A structured postal address, not free text (captain inbox 021): at least three
  // comma-separated parts (street, city, postal/region), no newlines, bounded length.
  // The gate still requires the value to be quoted from the customer's own words.
  address: /^[^\n,]{3,80}(,[^\n,]{2,60}){2,4}$/,
};

export function valueShapeProblem(shape: string | undefined, value: string): "no_shape" | "malformed" | null {
  if (!shape || !(shape in VALUE_SHAPES)) return "no_shape";
  return VALUE_SHAPES[shape as "code" | "address"].test(value) ? null : "malformed";
}

// What may sit between the marker and the bound value ("apply the offer CODE save50",
// "ship my order to THE NEW ADDRESS 456 elm street"). Anything else is part of the value the
// customer wrote and the model dropped ("Main Street" from "123 Main Street").
export const VALUE_LEAD_WORDS: readonly string[] = [
  "code", "coupon", "promo", "voucher", "the", "is", "of", "with", "using", "at", "to", "my", "new", "address",
  "offer", "discount", "it", "order", "this", "that", "following", "below", "here", "be", "should", "now", "please",
];

// The bound value must be the customer's COMPLETE value: a whole-word phrase in the requesting
// sentence AFTER the marker, with nothing but lead words before it and tail words after it.
// Returns null when it binds, else why not.
export function boundValueProblem(sentence: string, needle: string, marker = ""): "absent" | "partial" | null {
  const markerAt = marker ? phraseIn(sentence, marker) : -1;
  const from = markerAt >= 0 ? markerAt + marker.length : 0;
  const rel = phraseIn(sentence.slice(from), needle);
  if (rel < 0) return phraseIn(sentence, needle) < 0 ? "absent" : "partial";
  const at = from + rel;
  const words = (s: string) => s.replace(/[,.!;:]/g, " ").split(" ").filter(Boolean);
  const lead = words(sentence.slice(from, at));
  const tail = words(sentence.slice(at + needle.length));
  if (markerAt >= 0 && !lead.every((w) => VALUE_LEAD_WORDS.includes(w))) return "partial";
  return tail.every((w) => VALUE_TAIL_WORDS.includes(w)) ? null : "partial";
}

export const QUESTION_LEADS: readonly string[] = [
  "how do i", "how can i", "how would i", "how to", "can i", "could i", "may i", "should i", "do i",
  "what if", "what happens if", "what happens when", "what would happen", "is it possible", "is there a way",
  "would it be possible", "if i", "when i", "what does", "what is", "what are", "why", "where do i",
  "does it", "do you", "did you", "are you", "will i", "will it", "would i",
];

// Phrases that make a sentence ABOUT the action rather than a request FOR it. A request cue
// does not rescue them: "please tell me how to cancel" asks for instructions, "I want to
// know if I can cancel" asks for information, "please explain the cancel policy" asks for
// an explanation. Any of these before the marker in the requesting sentence, with no later
// request cue between it and the marker, refuses `confirmation_asks_about_the_action`
// (QA #1873 r3, Critical).
export const ABOUT_PHRASES: readonly string[] = [
  "how to", "how do i", "how can i", "how would i", "how i can", "how i would", "how i could", "how one",
  "the way to", "the steps to", "the process to", "the process of", "the process for", "the procedure",
  "instructions", "instruction on", "tell me", "let me know", "explain", "describe", "walk me through",
  "show me", "help me understand", "understand", "know if", "know whether", "know how", "know what",
  "to know", "wondering", "curious", "what happens", "what would happen", "what will happen", "whether",
  "if i", "when i", "before i", "in case i", "information about", "information on", "info on", "info about",
  "details about", "details on", "policy", "policies", "terms", "option to", "options to", "possible to",
  "able to", "a way to", "any way to", "thinking about", "thinking of", "considering", "might", "maybe",
  "perhaps", "question about", "questions about", "asking about", "ask about", "clarify", "confirm whether",
  "confirm if", "check if", "check whether", "find out", "figure out", "learn",
];

// Words a request may open with before the marker and still be imperative ("yes, cancel it").
const LEADING_FILLERS: readonly string[] = ["yes", "yeah", "yep", "ok", "okay", "sure", "so", "then", "just", "and", "also", "please", "kindly", "alright", "right", "well"];

function normalize(s: unknown): string {
  return String(s ?? "")
    .toLowerCase()
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Whole-word(s) match of a phrase inside text.
function phraseIn(text: string, phrase: string): number {
  const m = new RegExp(`(^|[^a-z0-9'])${escapeRe(phrase)}(?![a-z0-9'])`).exec(text);
  return m ? m.index + m[1].length : -1;
}

// The customer's part, split into sentences: a decision is made per sentence so that
// "don't ship to A; ship to B" binds to the second sentence only.
// Line boundaries are sentence boundaries, so they are cut BEFORE normalize() collapses
// whitespace (QA #1873 r5: an unpunctuated newline must not glue two instructions together).
export function splitSentences(snippet: string): string[] {
  return String(snippet ?? "")
    .split(/\r?\n+/)
    .flatMap((line) => normalize(line).split(/(?<=[.!?;])\s+|;\s*|(?<=[.!?])(?=[a-z])/))
    .map((s) => s.trim())
    .filter(Boolean);
}

export type MarkerVerdict =
  | { asked: true; marker: string; sentence: string }
  | { asked: false; reason: "confirmation_does_not_ask_for_this_action" }
  | { asked: false; reason: "confirmation_is_a_question"; marker: string; sentence: string }
  | { asked: false; reason: "confirmation_asks_about_the_action"; marker: string; about: string; sentence: string }
  | { asked: false; reason: "confirmation_not_a_request"; marker: string; sentence: string }
  | { asked: false; reason: "confirmation_reversed"; marker: string; negation: string; sentence: string }
  | { asked: false; reason: "confirmation_is_conditional"; marker: string; condition: string; sentence: string }
  | { asked: false; reason: "confirmation_negated"; marker: string; negation: string; sentence: string }
  | { asked: false; reason: "confirmation_followed_by_more"; marker: string; more: string; sentence: string };

// What may FOLLOW the request and leave it the customer's final instruction: courtesy, urgency
// and the bound value's tail words. Anything else after the request, in the same sentence or
// a later one, is "more" the gate cannot read (a withdrawal, a qualifier, a second ask), so
// the request is refused `confirmation_followed_by_more` and Caroline asks for a one-line
// confirmation (QA #1873 r10, Critical: "Actually, I do not want to.", "I would rather keep
// it", "leave it active" evaded every negation list). A closed allowlist of what may follow,
// not an open list of what withdraws.
export const TRAILING_OK_WORDS: readonly string[] = [
  "please", "kindly", "thanks", "thank", "you", "thx", "ty", "cheers", "regards", "best", "kind", "sincerely",
  "much", "appreciated", "appreciate", "it", "bye", "goodbye", "have", "a", "good", "nice", "great", "day",
  "week", "weekend", "one", "asap", "immediately", "now", "right", "away", "today", "soon", "and", "also",
  "for", "me", "to", "my", "account", "order", "subscription", "plan", "the", "this", "that", "ok", "okay",
  "yes", "confirm", "confirmed", "confirming", "i", "am", "sure", "certain", "definitely", "absolutely",
  "all", "done", "cool", "ta", "many", "lot", "lots", "in", "advance", "hi", "hello", "hey", "team", "support",
  "your", "help", "again", "afterall", "rightaway", "rightnow", "link", "offer", "code", "address",
];

// The words of `text` once the bound values and punctuation are removed; the first word that
// is not allowed to follow a request, or null when nothing substantive follows.
export function trailingProblem(text: string, boundValues: readonly string[] = [], allowLead = false): string | null {
  let rest = text;
  for (const v of boundValues) {
    const at = v ? phraseIn(rest, v) : -1;
    if (at >= 0) rest = `${rest.slice(0, at)} ${rest.slice(at + v.length)}`;
  }
  const words = maskIdioms(rest).replace(/[,.!;:?'"()\-]/g, " ").split(" ").filter(Boolean);
  return words.find((w) => !TRAILING_OK_WORDS.includes(w) && !(allowLead && VALUE_LEAD_WORDS.includes(w))) ?? null;
}

type SentenceVerdict = Exclude<MarkerVerdict, { reason: "confirmation_does_not_ask_for_this_action" }>;

// Every occurrence of the marker in the sentence is judged: if ANY occurrence is negated the
// sentence is contradictory and refuses ("please cancel my subscription, no wait, do not
// cancel my subscription"); otherwise the first occurrence's verdict stands (QA r4).
function judgeSentence(sentence: string, marker: string): SentenceVerdict | null {
  let first: SentenceVerdict | null = null;
  let from = 0;
  for (;;) {
    const i = phraseIn(sentence.slice(from), marker);
    if (i < 0) break;
    const v = judgeOccurrence(sentence, marker, from + i);
    if (!v.asked && v.reason === "confirmation_negated") return v;
    first = first ?? v;
    from = from + i + marker.length;
  }
  return first;
}

function judgeOccurrence(sentence: string, marker: string, at: number): SentenceVerdict {
  const before = sentence.slice(0, at).trim();

  // Question: a trailing "?" or an interrogative lead-in.
  if (sentence.endsWith("?") || QUESTION_LEADS.some((q) => phraseIn(before, q) === 0 || before === q)) {
    return { asked: false, reason: "confirmation_is_a_question", marker, sentence };
  }

  // Negation earlier in the sentence, unless a request cue sits between it and the marker.
  let lastNegation: { word: string; at: number } | null = null;
  for (const n of NEGATION_WORDS) {
    const i = phraseIn(before, n);
    if (i >= 0 && (!lastNegation || i > lastNegation.at)) lastNegation = { word: n, at: i };
  }
  let lastCue = -1;
  for (const c of REQUEST_CUES) {
    const i = phraseIn(before, c);
    if (i > lastCue) lastCue = i;
  }
  if (lastNegation && lastCue <= lastNegation.at) {
    return { asked: false, reason: "confirmation_negated", marker, negation: lastNegation.word, sentence };
  }

  // About-the-action: "please tell me how to cancel". The LAST such phrase before the marker
  // must be followed by a request cue for the sentence to still be an ask ("explain the
  // policy, then please cancel" - the cue after "explain" re-opens it).
  let lastAbout: { word: string; at: number } | null = null;
  for (const a of ABOUT_PHRASES) {
    let from = 0;
    for (;;) {
      const i = phraseIn(before.slice(from), a);
      if (i < 0) break;
      const abs = from + i;
      if (!lastAbout || abs > lastAbout.at) lastAbout = { word: a, at: abs };
      from = abs + a.length;
    }
  }
  if (lastAbout && lastCue <= lastAbout.at) {
    return { asked: false, reason: "confirmation_asks_about_the_action", marker, about: lastAbout.word, sentence };
  }

  // Imperative: the marker opens the sentence once leading fillers are stripped.
  const stripped = before.replace(/[,!.]/g, " ").split(" ").filter(Boolean).filter((w) => !LEADING_FILLERS.includes(w));
  const imperative = stripped.length === 0;
  if (!imperative && lastCue < 0) return { asked: false, reason: "confirmation_not_a_request", marker, sentence };

  // Conditional or scheduled: anywhere in the sentence ("cancel my subscription if ...",
  // "if ... cancel", "... on Friday", "... at 5pm").
  const condition = conditionOf(sentence);
  if (condition) return { asked: false, reason: "confirmation_is_conditional", marker, condition, sentence };
  return { asked: true, marker, sentence };
}

// Exported so the tests and the policy check can pin the exact rule.
// The FINAL applicable instruction decides (QA #1873 r4, Critical). Sentences are judged in
// order; the last sentence that mentions a marker is the customer's standing instruction.
// If it is an affirmative request, the part asks (and bound params bind to THAT sentence);
// if it is negated after an earlier affirmative, the customer reversed themselves and the
// part is refused `confirmation_reversed` ("Please cancel my subscription. Actually, do not
// cancel it."). A negation BEFORE the affirmative is a correction toward it ("don't ship to
// A; ship to B") and the affirmative stands. A later question or mention about the action
// after an affirmative does not undo it ("Please cancel my subscription. Does it cancel
// today?"), but with no affirmative anywhere the most specific refusal is returned.
// Function words that never carry the action: the HEAD of a marker is its first other token
// ("cancel my subscription" -> cancel, "do not renew" -> renew, "i'll take the offer" -> take).
const MARKER_STOP_WORDS = new Set(["do", "not", "don't", "dont", "my", "the", "our", "it", "to", "me", "a", "an", "is", "yes", "i'll", "i", "with", "of", "on", "that", "this", "please"]);

export function markerHeads(markers: readonly string[]): string[] {
  const heads = new Set<string>();
  for (const m of markers) {
    const head = normalize(m).split(" ").find((t) => t && !MARKER_STOP_WORDS.has(t));
    if (head) heads.add(head);
  }
  return [...heads];
}

// A later sentence REVERSES an earlier request when it negates the action's verb even without
// the full object ("Please cancel my subscription. Actually, do not cancel it."): a negation
// word followed by a marker head, with no request cue re-opening it in between. A sentence
// that is NOTHING but a negation and retraction words ("actually do not", "no, never mind",
// "wait, no!") reverses too; "No refund needed." carries other words and does not.
const RETRACTION_WORDS = new Set(["actually", "wait", "never", "mind", "forget", "it", "that", "sorry", "scratch", "ignore", "hold", "on", "second", "thought", "oh", "hmm", "um", "nevermind", "i", "changed", "my", "but", "though", "after", "all", "now", "nah", "then"]);
const NEGATION_TOKENS = new Set(NEGATION_WORDS.flatMap((n) => n.split(" ")));
function negatesAction(sentence: string, heads: readonly string[]): { negation: string; head: string } | null {
  const words = sentence.replace(/[,!.;:]/g, " ").split(" ").filter(Boolean);
  const bare = NEGATION_WORDS.find((n) => phraseIn(sentence, n) >= 0);
  if (bare && words.every((w) => NEGATION_TOKENS.has(w) || RETRACTION_WORDS.has(w) || LEADING_FILLERS.includes(w))) {
    return { negation: bare, head: "" };
  }
  let best: { negation: string; head: string; at: number } | null = null;
  for (const head of heads) {
    let from = 0;
    for (;;) {
      const i = phraseIn(sentence.slice(from), head);
      if (i < 0) break;
      const at = from + i;
      const before = sentence.slice(0, at);
      let lastNeg: { word: string; at: number } | null = null;
      for (const n of NEGATION_WORDS) {
        const j = phraseIn(before, n);
        if (j >= 0 && (!lastNeg || j > lastNeg.at)) lastNeg = { word: n, at: j };
      }
      let lastCue = -1;
      for (const c of REQUEST_CUES) {
        const j = phraseIn(before, c);
        if (j > lastCue) lastCue = j;
      }
      if (lastNeg && lastCue <= lastNeg.at && (!best || at < best.at)) best = { negation: lastNeg.word, head, at };
      from = at + head.length;
    }
  }
  return best ? { negation: best.negation, head: best.head } : null;
}

export function evaluateConfirmation(snippetRaw: string, markers: readonly string[], boundValues: readonly string[] = []): MarkerVerdict {
  const sentences = splitSentences(snippetRaw);
  const cleanMarkers = markers.map(normalize).filter(Boolean);
  if (!sentences.length || !cleanMarkers.length) return { asked: false, reason: "confirmation_does_not_ask_for_this_action" };
  const heads = markerHeads(cleanMarkers);
  const bound = boundValues.map(normalize).filter(Boolean);
  const rank: Record<string, number> = { confirmation_negated: 5, confirmation_is_conditional: 4, confirmation_asks_about_the_action: 3, confirmation_is_a_question: 2, confirmation_followed_by_more: 2, confirmation_not_a_request: 1 };
  let refusal: SentenceVerdict | null = null;
  let lastAsked: SentenceVerdict | null = null;
  let reversal: SentenceVerdict | null = null;
  for (const sentence of sentences) {
    let asked: SentenceVerdict | null = null;
    let negated: SentenceVerdict | null = null;
    for (const marker of cleanMarkers) {
      const v = judgeSentence(sentence, marker);
      if (!v) continue;
      if (v.asked) {
        asked = asked ?? v;
        continue;
      }
      if (v.reason === "confirmation_negated") negated = negated ?? v;
      if (!refusal || rank[v.reason] > rank[refusal.asked ? "" : refusal.reason]) refusal = v;
    }
    // After an affirmative, a sentence that negates the action (full marker or just its verb)
    // is a reversal; one sentence that both asks and negates is contradictory on its face.
    if (!negated && !asked && lastAsked) {
      const n = negatesAction(sentence, heads);
      if (n) negated = { asked: false, reason: "confirmation_negated", marker: n.head, negation: n.negation, sentence };
    }
    // A withdrawal AFTER the affirmative marker in the SAME sentence ("please cancel my
    // subscription, but do not cancel it") - judged on the remainder of the sentence, where
    // the verb head alone is enough (QA #1873 r5).
    if (!negated && asked) {
      const at = phraseIn(sentence, asked.marker);
      const rest = at >= 0 ? sentence.slice(at + asked.marker.length) : "";
      const n = rest ? negatesAction(rest, heads) : null;
      if (n) negated = { asked: false, reason: "confirmation_negated", marker: n.head || asked.marker, negation: n.negation, sentence };
    }
    if (negated && (asked || lastAsked)) {
      reversal = negated;
      lastAsked = null;
      continue;
    }
    if (asked) {
      // The request must be the FINAL thing the customer says in its sentence: after the
      // marker only courtesy, urgency and the bound value may follow (QA #1873 r10).
      const at = phraseIn(sentence, asked.marker);
      const rest = at >= 0 ? sentence.slice(at + asked.marker.length) : "";
      const condition = rest ? conditionOf(rest) : null;
      if (condition) {
        refusal = { asked: false, reason: "confirmation_is_conditional", marker: asked.marker, condition, sentence };
        lastAsked = null;
        reversal = null;
        continue;
      }
      // Only courtesy, lead words and a shape-clean bound value may follow the marker; the
      // value is removed first, so a value can never swallow a withdrawal (QA #1873 r11).
      // A bound value the customer did not write here is refused by boundValueProblem()
      // (absent) with the precise reason; the trailing check judges the rest.
      const absent = bound.length > 0 && bound.every((v) => phraseIn(rest, v) < 0);
      const more = rest && !absent ? trailingProblem(rest, bound, true) : null;
      if (more) {
        refusal = { asked: false, reason: "confirmation_followed_by_more", marker: asked.marker, more, sentence };
        lastAsked = null;
        reversal = null;
        continue;
      }
      lastAsked = asked;
      reversal = null;
      continue;
    }
    // A later sentence that carries a condition or a timing qualifies the standing request
    // ("Please cancel my subscription. But not until Friday." / "Only if there is no fee.");
    // the gate cannot act on it now (QA #1873 r8, Critical). Refuse on doubt: even "If you
    // have questions, email me" after a request is read as a qualifier, and Caroline re-asks.
    if (lastAsked && !negated) {
      const condition = conditionOf(sentence);
      if (condition) {
        refusal = { asked: false, reason: "confirmation_is_conditional", marker: lastAsked.marker, condition, sentence };
        lastAsked = null;
        reversal = null;
        continue;
      }
      // Any later sentence that is not pure courtesy is "more" after the request: the
      // customer's final instruction is no longer the request (QA #1873 r10, Critical).
      const more = trailingProblem(sentence, bound);
      if (more) {
        refusal = { asked: false, reason: "confirmation_followed_by_more", marker: lastAsked.marker, more, sentence };
        lastAsked = null;
        reversal = null;
      }
    }
  }
  if (lastAsked) return lastAsked;
  if (reversal && reversal.asked === false && reversal.reason === "confirmation_negated") {
    return { asked: false, reason: "confirmation_reversed", marker: reversal.marker, negation: reversal.negation, sentence: reversal.sentence };
  }
  return refusal ?? { asked: false, reason: "confirmation_does_not_ask_for_this_action" };
}

// A marker that is a bare verb or a bare noun authorizes the wrong action: "cancel" lets
// "please cancel my order" satisfy cancel_subscription (QA #1873 r4, Critical). Every marker
// must carry the OBJECT of its own intent; these words alone are refused as policy_invalid.
export const BROAD_MARKERS: readonly string[] = [
  "cancel", "cancelling", "canceling", "cancellation", "stop", "end", "quit", "terminate", "close",
  "apply", "accept", "take", "offer", "discount", "deal",
  "address", "ship", "ship to", "send it to", "send to", "deliver to", "update", "change", "shipping",
  "founding", "buyback", "buy back", "link", "refund", "delete", "remove",
  "unsubscribe", "unsubscribe me", "subscription", "plan", "membership", "renew", "renewal",
];

export function policyRowProblem(row: SupportIntentPolicyRow): string | null {
  const markers = (row.confirmation_markers ?? []).map(normalize).filter(Boolean);
  if (markers.length === 0) return "no_confirmation_markers";
  const generic = markers.find((m) => GENERIC_AFFIRMATIONS.includes(m));
  if (generic) return `generic_marker:${generic}`;
  const broad = markers.find((m) => BROAD_MARKERS.includes(m));
  if (broad) return `broad_marker:${broad}`;
  if (typeof row.actor !== "string" || !row.actor.trim()) return "no_actor";
  const allowed = new Set(row.params_allowed ?? []);
  const unbound = (row.params_bound ?? []).find((p) => !allowed.has(p));
  if (unbound) return `bound_param_not_allowed:${unbound}`;
  if (row.enabled) {
    const shapes = row.params_shape ?? {};
    const unshaped = (row.params_bound ?? []).find((p) => !(shapes[p] && shapes[p] in VALUE_SHAPES));
    if (unshaped) return `unclosed_bound_param:${unshaped}`;
  }
  return null;
}

const IntentKindSchema = Type.Union([
  Type.Literal("cancel_subscription"),
  Type.Literal("retention_offer_apply"),
  Type.Literal("order_address_update"),
  Type.Literal("founding_buyback_link"),
]);

const Parameters = Type.Object({
  intent: IntentKindSchema,
  confirmation_ref: Type.String({
    minLength: 1,
    description:
      "The Intercom message id of the CUSTOMER's own message that asks for this action, exactly as support_intent_lookup or the conversation context showed it. Must match the customer's latest part or the intent is refused.",
  }),
  params: Type.Optional(
    Type.Record(Type.String(), Type.Unknown(), {
      description:
        "Action-specific fields the policy allows for this intent (e.g. the new shipping address). A material field must appear verbatim in the customer's own message or the intent is refused. The gate re-reads the record; nothing here is trusted for identity or eligibility.",
    }),
  ),
});

type Params = Static<typeof Parameters>;

function decision(ok: boolean, body: Record<string, unknown>): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ ok, ...body }));
}

function errText(err: unknown): string {
  return String((err as Error)?.message ?? err);
}

export function executionIdFor(conversationId: string, kind: string, confirmationRef: string): string {
  return `${conversationId}:${kind}:${confirmationRef}`;
}

export function createSupportIntentTool(deps: SupportIntentDeps): AgentTool<typeof Parameters, unknown> {
  const now = deps.now ?? (() => Date.now());

  return {
    name: "support_intent",
    label: "Support Intent",
    description:
      "The ONLY way to change a customer's subscription, offer, order address or buyback link. You do not hold those tools. " +
      "Emit the typed intent here: the gate checks the customer's own message, re-reads the live record, and a named actor performs it or refuses it. " +
      "Pass confirmation_ref = the customer's latest message id. " +
      "Returns { ok: true, decision: 'executed', actor, evidence } or { ok: false, decision: 'refused', reason } — a refusal is final for this turn: tell the customer what you cannot do and hand off if they insist.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const kind = params.intent as SupportIntentKind;
      const executionId = executionIdFor(deps.conversationId, kind, params.confirmation_ref);
      const base = {
        ts: new Date(now()).toISOString(),
        kind: "support_intent",
        intent: kind,
        conversation_id: deps.conversationId,
        confirmation_ref: params.confirmation_ref,
        execution_id: executionId,
      };

      // A refusal row that cannot be written is reported, not thrown: the refusal itself
      // is the safe outcome and the caller still needs the reason.
      const refuse = async (reason: string, extra: Record<string, unknown> = {}) => {
        const row = { ...base, decision: "refuse", reason, ...extra };
        let ledgerWriteFailed: string | undefined;
        try {
          await deps.ledger(row);
        } catch (err) {
          ledgerWriteFailed = errText(err);
        }
        return decision(false, {
          decision: "refused",
          reason,
          ...extra,
          ...(ledgerWriteFailed ? { ledger_write_failed: true, ledger_error: ledgerWriteFailed } : {}),
        });
      };

      let policy: SupportIntentPolicy;
      try {
        policy = await deps.policy();
      } catch (err) {
        return refuse("policy_unavailable", { route_to_human: true, detail: errText(err) });
      }
      const row = policy?.intents?.[kind];
      if (!row) return refuse("unknown_intent");
      if (row.enabled !== true) return refuse("intent_disabled");
      const problem = policyRowProblem(row);
      if (problem) return refuse("policy_invalid", { route_to_human: true, detail: problem });

      // 1. Identity: the conversation's real author, never a tool-arg. A reader that cannot
      //    answer (502, timeout) is a refusal with a ledger row, never a throw (QA r4).
      let email: string | null | undefined;
      try {
        email = await deps.intercomReader.getAuthorEmail(deps.conversationId, deps.intercomToken);
      } catch (err) {
        return refuse("identity_unavailable", { route_to_human: true, detail: errText(err) });
      }
      if (!email) return refuse("unverified_identity", { route_to_human: true });

      // 2. Confirmation: the customer's OWN latest part, resolved here. The intent must name
      //    that exact part and that part must ask for this action, affirmatively. A model
      //    that invents a reference, or points at any other message, cannot get past this;
      //    neither can "no, do not cancel".
      let part: Awaited<ReturnType<typeof deps.intercomReader.getLatestCustomerPart>>;
      try {
        part = await deps.intercomReader.getLatestCustomerPart(deps.conversationId, deps.intercomToken);
      } catch (err) {
        return refuse("confirmation_unavailable", { route_to_human: true, detail: errText(err) });
      }
      if (!part) return refuse("no_confirmation_evidence", { route_to_human: true });
      if (part.id !== params.confirmation_ref) {
        return refuse("stale_or_foreign_confirmation", { expected_ref: part.id });
      }
      // The decision reads the COMPLETE customer message. A reader that only carries the
      // 200-character snippet, or a snippet that ends in the truncation mark, is not evidence
      // of what the customer finally said (QA #1873 r9, Critical): refuse, never guess.
      const words = typeof part.text === "string" ? part.text : part.snippet;
      if (typeof words !== "string" || (typeof part.text !== "string" && (part.snippet ?? "").endsWith("\u2026"))) {
        return refuse("confirmation_truncated", { route_to_human: true, snippet_chars: (part.snippet ?? "").length });
      }
      const given = params.params ?? {};
      const boundValues: string[] = [];
      for (const k of row.params_bound ?? []) {
        if (!(k in given)) continue;
        const raw = typeof given[k] === "string" ? (given[k] as string) : JSON.stringify(given[k] ?? "");
        const shape = valueShapeProblem(row.params_shape?.[k], normalize(raw));
        if (shape) return refuse("param_malformed", { param: k, why: shape, shape: row.params_shape?.[k] ?? null });
        boundValues.push(raw);
      }
      const verdict = evaluateConfirmation(words, row.confirmation_markers ?? [], boundValues);
      if (!verdict.asked) {
        if (verdict.reason === "confirmation_does_not_ask_for_this_action") return refuse(verdict.reason);
        const extra: Record<string, unknown> = { marker: verdict.marker, sentence: verdict.sentence.slice(0, 200) };
        if (verdict.reason === "confirmation_negated" || verdict.reason === "confirmation_reversed") extra.negation = verdict.negation;
        if (verdict.reason === "confirmation_asks_about_the_action") extra.about = verdict.about;
        if (verdict.reason === "confirmation_is_conditional") extra.condition = verdict.condition;
        if (verdict.reason === "confirmation_followed_by_more") {
          extra.more = verdict.more;
          extra.route_to_human = true;
        }
        return refuse(verdict.reason, extra);
      }

      // 2b. Parameters: only the allowed keys, and every material value must be something
      //     the customer wrote IN THE REQUESTING SENTENCE ("don't ship to A; ship to B"
      //     binds B, never A).
      const allowed = new Set(row.params_allowed ?? []);
      const unexpected = Object.keys(given).filter((k) => !allowed.has(k));
      if (unexpected.length) return refuse("unexpected_params", { params: unexpected });
      for (const key of row.params_bound ?? []) {
        if (!(key in given)) continue;
        const value = given[key];
        const needle = normalize(typeof value === "string" ? value : JSON.stringify(value ?? ""));
        const problem = needle ? boundValueProblem(verdict.sentence, needle, verdict.marker) : "absent";
        if (problem) {
          return refuse("param_not_in_confirmation", { param: key, why: problem, sentence: verdict.sentence.slice(0, 200) });
        }
      }

      // 3. Legality: the gate re-reads the live record itself.
      let record: { allowed: boolean; reason?: string; state?: string; teamId?: string; orderRef?: string; ownerEmail?: string };
      try {
        record = await deps.recordCheck(kind, email);
      } catch (err) {
        return refuse("record_unavailable", { route_to_human: true, detail: errText(err) });
      }
      if (!record?.allowed) {
        return refuse("record_state", { record_state: record?.state ?? null, detail: record?.reason ?? null });
      }

      // 3b. The actor: dispatched by intent, then VERIFIED against the policy's named actor.
      const teamId = String(record.teamId ?? "");
      if (!teamId) return refuse("record_unresolved", { route_to_human: true, detail: "the gate could not resolve exactly one workspace" });

      // 3b-ii. Order-scoped classes: the gate must have resolved the order AND its owner.
      // The row opts in (default off), so the ruling is a one-line flip either way.
      const orderScoped = row.order_scoped === true;
      const orderRef = String(record.orderRef ?? "");
      const ownerEmail = String(record.ownerEmail ?? "");
      if (orderScoped && (!orderRef || !ownerEmail)) {
        return refuse("record_unresolved", { route_to_human: true, detail: "the gate could not resolve the order and its owner" });
      }

      const actor = deps.actors[kind];
      if (!actor || typeof actor.run !== "function") return refuse("actor_unavailable", { route_to_human: true, actor: row.actor });
      if (actor.name !== row.actor) {
        return refuse("actor_mismatch", { route_to_human: true, actor: row.actor, bound_actor: actor.name ?? null });
      }

      // 3c. One confirmed intent executes ONCE. The durable claim is taken first: a second
      //     emission of the same (conversation, intent, confirmation part) - a model repeating
      //     itself, a retry after a lost ledger row, a second gateway process - finds it held
      //     and never reaches the actor. A store that cannot answer is a refusal too.
      let claimed: boolean;
      try {
        claimed = await deps.claims.claim(executionId, { ...base, actor: row.actor, verified_email: email });
      } catch (err) {
        return refuse("claim_unavailable", { route_to_human: true, detail: errText(err) });
      }
      if (!claimed) return refuse("duplicate_execution", { route_to_human: true, execution_id: executionId });

      // 3d. The allow row is the gate's commitment. If it cannot be written, nothing runs -
      //     and the claim stays taken, so the same confirmation cannot be retried blind.
      try {
        await deps.ledger({ ...base, decision: "allow", actor: row.actor, verified_email: email, marker: verdict.marker, ...(orderScoped ? { order_ref: orderRef, owner_email: ownerEmail } : {}) });
      } catch (err) {
        return refuse("ledger_unavailable", { route_to_human: true, detail: errText(err), execution_id: executionId });
      }

      // 4. Execution by the named actor. The gate has already decided; the actor only acts.
      // From here a ledger failure is REPORTED in the result (the write has happened and a
      // thrown error would hide that), never thrown.
      const recordExecuted = async (row: Record<string, unknown>): Promise<string | undefined> => {
        try {
          await deps.ledger(row);
          return undefined;
        } catch (err) {
          return errText(err);
        }
      };
      const ledgerTail = (failed: string | undefined) => (failed ? { ledger_write_failed: true, ledger_error: failed, route_to_human: true } : {});

      let result: AgentToolResult<unknown>;
      try {
        result = await actor.run({
          verifiedEmail: email,
          conversationId: deps.conversationId,
          confirmationRef: part.id,
          executionId,
          teamId,
          ...(orderScoped ? { orderRef, ownerEmail } : {}),
          params: given,
        });
      } catch (err) {
        const failed = await recordExecuted({ ...base, decision: "executed", actor: row.actor, verified_email: email, outcome: "error", detail: errText(err) });
        return decision(false, { decision: "refused", reason: "actor_failed", route_to_human: true, ...ledgerTail(failed) });
      }

      const text = result?.content?.[0]?.type === "text" ? result.content[0].text : "";
      let parsed: Record<string, unknown> = {};
      try {
        parsed = text ? JSON.parse(text) : {};
      } catch {
        parsed = { raw: text.slice(0, 400) };
      }
      const outcome = parsed?.ok === true ? "ok" : "refused_by_actor";
      const failed = await recordExecuted({ ...base, decision: "executed", actor: row.actor, verified_email: email, outcome, actor_reason: parsed?.reason ?? null });

      if (parsed?.ok !== true) {
        return decision(false, { decision: "refused", reason: String(parsed?.reason ?? "actor_failed"), actor: row.actor, route_to_human: true, ...ledgerTail(failed) });
      }
      return decision(true, { decision: "executed", actor: row.actor, execution_id: executionId, evidence: parsed, ...ledgerTail(failed) });
    },
  };
}

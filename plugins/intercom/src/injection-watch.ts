/**
 * PROMPT-INJECTION WATCH for Caroline's inbound text (firstmate caroline-guard-g1; Fable
 * security-arch-fable-s1 handoff-contract §6: "flag + audit, never act").
 *
 * Detection only. Nothing here changes what Caroline is asked, what she answers, or what any
 * system decides: the customer's message is dispatched exactly as before. A hit is
 *   1. appended to the injection ledger (INJECTION_LEDGER_PATH, JSONL, 0600);
 *   2. tagged on the Intercom conversation (INJECTION_TAG) so a human sees it in the inbox;
 *   3. paged to the supervision channel on a BURST (fleet-wide) or a REPEAT SENDER (one contact);
 *   4. summarised daily by scripts/injection-watch.py digest, which also writes the fraud-lens
 *      watch CANDIDATES file (never the approved watchlist itself: promotion is a reviewed PR).
 *
 * The same rule set runs over support@ email text and uploaded-proof text extracts on the Python
 * side (scripts/lib/injection_watch.py). The two copies are pinned equal by
 * scripts/tests/test_injection_watch.py (it dumps INJECTION_RULES from this file with
 * `node --experimental-strip-types`), so this file stays import-free.
 *
 * Constants, no env switches (standing rule): the ledger path, the thresholds and the tag change
 * only by a reviewed PR.
 */

export const INJECTION_WATCH_VERSION = "iw-2026-11-04.6";

/**
 * How long a ledger row lives. The daily run (`scripts/injection-watch.py prune`) enforces it; this copy exists so
 * the parity test can pin both sides to the same number. A HIGH hit's masked context is the only customer-derived
 * text the ledger holds (Fable s1 on #1665), and text at rest with no lifetime is how a defensible design rots.
 */
export const LEDGER_RETENTION_DAYS = 30;

/**
 * The retention prune and every ledger writer serialize on ONE lock: an atomic directory create next to the ledger
 * (`ledger.jsonl.ledger.lock`). A delete cannot be made safe against an appender with a timestamp check alone, so the
 * two take turns instead (QA on #1665). Same constant on the Python side; the parity test pins them equal.
 *
 * This lock is the FAST path, not the guarantee: the prune independently refuses to unlink any generation whose inode
 * is still held open by a live process, so a stolen lock or a bypassed append can cost ordering but never a row.
 * `LEDGER_LOCK_STALE_MS` is long because the holder heartbeats the lock while it works, so "no heartbeat for this
 * long" means the holder died -- not that it is slow.
 */
export const LEDGER_LOCK_SUFFIX = ".ledger.lock";
export const LEDGER_LOCK_STALE_MS = 300_000;
export const LEDGER_LOCK_WAIT_MS = 5_000;
export const INJECTION_LEDGER_PATH = "/var/lib/hydra/injection-watch/ledger.jsonl";
export const INJECTION_TAG = "ai:injection-watch";
/** Fleet-wide: this many hit-turns inside BURST_WINDOW_MS pages once per window. */
export const BURST_THRESHOLD = 5;
export const BURST_WINDOW_MS = 60 * 60 * 1000;
/** One contact: this many hit-turns inside REPEAT_WINDOW_MS pages once per contact per window. */
export const REPEAT_THRESHOLD = 3;
export const REPEAT_WINDOW_MS = 24 * 60 * 60 * 1000;

export type Severity = "high" | "medium" | "low";

export interface InjectionRule {
  rule: string;
  severity: Severity;
  /** JS regex source; the Python mirror compiles the same source (only portable syntax here). */
  source: string;
  /** "i" or "" (plus "m" where a rule is line-anchored). */
  flags: string;
}

const STAFF = "jan|aaron|nick|nicholas|artem|clio|caroline|fable|ops|admin|support|muso";

// Portable syntax only (no lookbehind, no named groups, no \p{}): Python's `re` compiles these too.
export const INJECTION_RULES: readonly InjectionRule[] = [
  {
    rule: "ignore_instructions",
    severity: "high",
    source:
      String.raw`\b(?:ignore|disregard|forget|override|bypass|skip)\b[^.\n]{0,40}\b(?:previous|prior|above|earlier|all|your|the|any|these|those)\b[^.\n]{0,25}\b(?:instructions?|prompts?|rules?|guidelines?|directives?|policies|polic(?:y)|system\s+message|guardrails?)\b`,
    flags: "i",
  },
  {
    rule: "new_persona",
    severity: "high",
    source:
      String.raw`\bfrom\s+now\s+on,?\s+you\s+(?:are|will|must)\b|\byou\s+are\s+now\s+(?:a|an|in|the|my)\b|\bnew\s+(?:system\s+)?instructions?\s*:|\bpretend\s+(?:to\s+be|you\s+are)\b|\bact\s+as\s+(?:an?\s+)?(?:admin|administrator|developer|system|root|operator|superuser|unrestricted)\b`,
    flags: "i",
  },
  {
    rule: "jailbreak_mode",
    severity: "high",
    source: String.raw`\b(?:developer|god|admin|debug|DAN|jailbreak|maintenance|sudo|unrestricted)\s+mode\b|\bdo\s+anything\s+now\b`,
    flags: "i",
  },
  {
    rule: "prompt_extraction",
    severity: "high",
    source:
      String.raw`\b(?:reveal|print|show|repeat|output|dump|list|display|tell\s+me)\b[^.\n]{0,30}\b(?:system\s+prompt|your\s+(?:instructions|prompt|rules|tools|guidelines|configuration|config)|hidden\s+instructions|initial\s+prompt|raw\s+json|tool\s+list|available\s+tools)\b`,
    flags: "i",
  },
  {
    rule: "role_marker",
    severity: "high",
    source:
      String.raw`(?:^|>)\s*(?:system|assistant|developer|tool)\s*:|<\|?(?:im_start|im_end|system|endoftext|eot_id|start_header_id)\|?>|\[/?(?:SYSTEM|INST|SYS|CONVERSATION_CONTEXT|CUSTOMER_MESSAGE|KNOWLEDGE_BASE|ATTACHMENT_STATUS|ROUTING|ADMIN)\]|</?(?:system|instructions?|admin|tool_call)>|#{2,}\s*(?:system|instructions?)\b`,
    flags: "im",
  },
  {
    rule: "staff_impersonation",
    severity: "medium",
    source:
      String.raw`\b(?:it'?s|this\s+is|i\s+am|i'm|from|signed|regards,?|on\s+behalf\s+of)\s+(?:jan|aaron|nick|nicholas|artem|clio)\b|\b(?:jan|aaron|nick)\s+(?:said|told|approved|authori[sz]ed|ok'?d|okayed|asked\s+you|confirmed|wants\s+you)\b|\b(?:muso|the)\s+(?:ops|operations|admin|support|verification|engineering|management)\s+team\s+(?:said|told|approved|authori[sz]ed|asked\s+you|confirmed|instructed)\b|\bi\s*(?:'m|am)\s+(?:a|an|the)?\s*(?:muso\s+)?(?:admin|administrator|employee|staff\s+member|developer|engineer|moderator)\b|\bfrom:\s*[^\s@]+@muso\.ai\b`,
    flags: "i",
  },
  {
    rule: "approval_command",
    severity: "medium",
    source:
      String.raw`\b(?:approved|verified|authori[sz]ed|confirmed)\s+by\s+(?:` + STAFF + String.raw`|the\s+team|management)\b|\b(?:auto-?approve|force[- ]approve|mark\s+(?:it|this|them|these|my\s+\w+)\s+as\s+(?:approved|verified))\b|\bapprove\b[^.\n]{0,40}\b(?:without|skip|bypass|override)\b|\byou\s+(?:are|have\s+been)\s+(?:authori[sz]ed|allowed|permitted|cleared)\s+to\s+(?:approve|verify|merge|delete|remove|refund)\b|\bAPPROVED\b`,
    flags: "",
  },
  {
    rule: "tool_name",
    severity: "medium",
    source:
      String.raw`\b(?:credits_verify|profiles_consolidate|profiles_claim_self|credit_verification_check|profile_claim_status|profile_credits_status|dedupe_check|remove_credits|credit_status_lookup|document_intake|merge_request_intake|credit_trust_handoff|merge_intake|proof_on_file|order_lookup|order_address_update|cancel_subscription|retention_offer_apply|founding_buyback_link|create_ticket|sessions_list|sessions_history|tool_call|function_call)\b|tools/invoke|/hooks/agent|"arguments"\s*:`,
    flags: "i",
  },
  {
    // Unicode tag characters (ASCII smuggling) and bidi overrides: invisible to a human reader.
    rule: "hidden_unicode",
    severity: "high",
    source: String.raw`[\u202A-\u202E\u2066-\u2069]|\uDB40[\uDC00-\uDC7F]`,
    flags: "",
  },
  {
    rule: "hidden_markup",
    severity: "medium",
    source:
      String.raw`<!--|display\s*:\s*none|visibility\s*:\s*hidden|font-size\s*:\s*0(?:\.\d+)?(?:px|pt|em)?\s*[;"']|color\s*:\s*(?:#fff(?:fff)?|white)\b|opacity\s*:\s*0(?:\.0+)?\s*[;"']`,
    flags: "i",
  },
  {
    // A long base64 run that is not part of a URL (the Python side also decodes it, see below).
    rule: "base64_blob",
    severity: "low",
    source: String.raw`(?:^|[\s"'(:,])[A-Za-z0-9+/]{120,}={0,2}(?=$|[\s"'),.])`,
    flags: "",
  },
];

// Zero-width characters are common in pasted text; only a run of them is a signal.
const ZERO_WIDTH = /[\u200B\u200C\u200E\u200F\u2060-\u2064\uFEFF]/g;
export const ZERO_WIDTH_MIN = 3;

export interface InjectionHit {
  rule: string;
  severity: Severity;
  /** The matched text, cut to 120 chars (ledger only). */
  excerpt: string;
  /**
   * HIGH hits only: a short MASKED window around the match, so a hit can be reviewed after the fact
   * (the bare match text of `role_marker` is just "Assistant:" - no signal). PII is redacted, the
   * length is bounded, and this is derived from the customer's text, never acted on.
   */
  context?: string;
}

const COMPILED = INJECTION_RULES.map((r) => ({ ...r, re: new RegExp(r.source, r.flags) }));

// Masked context window for HIGH hits: bounded, PII-redacted, one line. Constants, never env switches.
export const CONTEXT_RADIUS = 60;
export const CONTEXT_MAX = 160;
export const CONTEXT_SNAP = 32;
const MASK_EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
// A phone has an international prefix or real separators: a bare digit run is an order/credit id, not a phone.
const MASK_PHONE = /\+\d[\d\s().-]{6,}\d|\(?\d{2,4}\)?[\s.-]\d{2,4}[\s.-]\d{2,4}/g;
// No word boundary: an ORDER-123456789 or AB123456789 keeps its digits inside a token (QA on #1665).
const MASK_LONG_NUMBER = /\d{6,}/g;
// A claim code carries no long digit run at all (XK4F7Q), so it needs its own pass: any 6+ character token with
// both a digit and a capital is treated as a code (Fable s1 on #1665). Over-redacting a review excerpt is safe.
const MASK_CODE_TOKEN = /[A-Za-z0-9][A-Za-z0-9_-]*/g;

function maskCode(tok: string): string {
  return tok.length >= 6 && /\d/.test(tok) && /[A-Z]/.test(tok) ? "[code]" : tok;
}

/**
 * Redact the identifiers a hit may carry: emails, phone-like runs, any 6+ digit run, then claim-code-shaped
 * tokens (6+ chars with a digit and a capital: XK4F7Q). Deterministic; over-redacting is the safe direction.
 */
/**
 * A redaction of EXACTLY `len` characters: the tag plus fillers, or just fillers when the span is too short to name.
 * Keeping the length is what makes a window taken over masked text line up with the original offsets, so a slice can
 * never cut an identifier in half (QA on #1665, phone fragment at the left edge).
 */
function padMask(kind: string, len: number): string {
  const tag = `[${kind}]`;
  if (len >= tag.length) return tag + "#".repeat(len - tag.length);
  return "#".repeat(len);
}

/**
 * Redact the identifiers a hit may carry: emails, phone-like runs, any 6+ digit run, then claim-code-shaped
 * tokens (6+ chars with a digit and a capital: XK4F7Q). Deterministic; over-redacting is the safe direction.
 *
 * The output is the SAME LENGTH as the input: masking runs over the whole text BEFORE any window is taken, so a
 * fragment of a phone that starts outside the window cannot survive (QA on #1665). Same rule on the Python side.
 */
export function maskPii(s: string): string {
  return (s || "")
    .replace(MASK_EMAIL, (m) => padMask("email", m.length))
    .replace(MASK_PHONE, (m) => padMask("phone", m.length))
    .replace(MASK_LONG_NUMBER, (m) => padMask("number", m.length))
    .replace(MASK_CODE_TOKEN, (tok) => (maskCode(tok) === "[code]" ? padMask("code", tok.length) : tok));
}

/**
 * Cut to CONTEXT_MAX on a WORD boundary, then drop a trailing digit run: a hard character cut can split
 * "…or +1 (555)" out of a masked phone and leak a fragment of it into the ledger.
 */
function boundContext(body: string): string {
  if (body.length <= CONTEXT_MAX) return body;
  return `${body
    .slice(0, CONTEXT_MAX - 3)
    .replace(/\s+\S*$/, "")
    .replace(/[\s(]*[+\d][\d().\s-]*$/, "")}...`;
}

/** Widen a window to word boundaries (at most CONTEXT_SNAP chars): slicing mid-token can cut a phone. */
function snapWindow(text: string, from: number, to: number, index: number, end: number): [number, number] {
  const floor = Math.max(0, index - CONTEXT_RADIUS - CONTEXT_SNAP);
  let f = from;
  while (f > floor && !/\s/.test(text[f - 1])) f--;
  const ceiling = Math.min(text.length, end + CONTEXT_RADIUS + CONTEXT_SNAP);
  let t = to;
  while (t < ceiling && t < text.length && !/\s/.test(text[t - 1])) t++;
  return [f, t];
}

/** The masked window around a match at `index` (length `len`), masked, bounded, one line. */
export function maskedContext(text: string, index: number, len: number): string {
  // Mask the WHOLE text first, then window the masked string. Masking after the slice is what let a phone that
  // started before the window survive as a fragment ("010-9999") in the 30-day ledger (QA on #1665); masking first
  // makes that impossible, and maskPii is length-preserving so these offsets are still the original ones.
  const masked = maskPii(text);
  const [from, to] = snapWindow(
    masked,
    Math.max(0, index - CONTEXT_RADIUS),
    Math.min(masked.length, index + len + CONTEXT_RADIUS),
    index,
    index + len,
  );
  const body = masked.slice(from, to).replace(/\s+/g, " ").trim();
  // Belt and braces at BOTH edges: a fragment of a digit run must never be the first or last thing kept.
  const safe =
    body
      .replace(/[\s(]*[+\d][\d().\s-]*$/, "")
      .replace(/^[\s()]*[+\d][\d().\s-]*(?=\s|$)/, "")
      .trim() || body;
  return `${from > 0 ? "..." : ""}${boundContext(safe)}${to < text.length ? "..." : ""}`;
}

function cut(s: string, n = 120): string {
  const t = s.replace(/\s+/g, " ").trim();
  return t.length > n ? `${t.slice(0, n - 3)}...` : t;
}

/** Decoded base64 that itself reads as an injection is escalated to high. */
function decodeBase64(blob: string): string {
  try {
    const raw = blob.trim().replace(/^[\s"'(:,]+/, "");
    // Buffer exists on node; the guard runs only in the gateway and in tests.
    return Buffer.from(raw, "base64").toString("utf8");
  } catch {
    return "";
  }
}

export function scanForInjection(text: string): InjectionHit[] {
  const t = (text || "").slice(0, 200_000);
  const hits: InjectionHit[] = [];
  for (const r of COMPILED) {
    const m = r.re.exec(t);
    if (!m) continue;
    let severity: Severity = r.severity;
    if (r.rule === "base64_blob") {
      const decoded = decodeBase64(m[0]);
      if (decoded && COMPILED.some((x) => x.rule !== "base64_blob" && x.severity === "high" && x.re.test(decoded))) severity = "high";
    }
    const hit: InjectionHit = { rule: r.rule, severity, excerpt: cut(m[0]) };
    // Only HIGH hits get context: the ledger is otherwise deliberately text-free, and review needs a
    // sentence, not a bare "Assistant:" (firstmate decision 2026-11-03).
    if (severity === "high") hit.context = maskedContext(t, m.index ?? 0, m[0].length);
    hits.push(hit);
  }
  const zw = t.match(ZERO_WIDTH);
  if (zw && zw.length >= ZERO_WIDTH_MIN) hits.push({ rule: "zero_width_run", severity: "low", excerpt: `${zw.length} zero-width chars` });
  return hits;
}

export function topSeverity(hits: InjectionHit[]): Severity | null {
  if (hits.some((h) => h.severity === "high")) return "high";
  if (hits.some((h) => h.severity === "medium")) return "medium";
  return hits.length ? "low" : null;
}

// ---------------------------------------------------------------------------------------------
// burst / repeat-sender pager state (in memory; the daily digest re-derives repeats from the ledger)

export interface PageDecision {
  burst: boolean;
  repeatSender: boolean;
}

export class InjectionPager {
  private fleet: number[] = [];
  private perContact = new Map<string, number[]>();
  private lastBurstPage = Number.NEGATIVE_INFINITY;
  private lastRepeatPage = new Map<string, number>();

  /** Record one hit-turn; returns which pages (if any) are due now. Low-only turns never page. */
  record(contactKey: string, severity: Severity, now: number): PageDecision {
    if (severity === "low") return { burst: false, repeatSender: false };
    this.fleet = this.fleet.filter((t) => now - t < BURST_WINDOW_MS);
    this.fleet.push(now);
    const list = (this.perContact.get(contactKey) ?? []).filter((t) => now - t < REPEAT_WINDOW_MS);
    list.push(now);
    this.perContact.set(contactKey, list);
    if (this.perContact.size > 5000) {
      // bounded memory: forget the oldest contacts
      const first = this.perContact.keys().next().value;
      if (first !== undefined) this.perContact.delete(first);
    }
    const burst = this.fleet.length >= BURST_THRESHOLD && now - this.lastBurstPage >= BURST_WINDOW_MS;
    if (burst) this.lastBurstPage = now;
    const lastRepeat = this.lastRepeatPage.get(contactKey) ?? Number.NEGATIVE_INFINITY;
    const repeatSender = list.length >= REPEAT_THRESHOLD && now - lastRepeat >= REPEAT_WINDOW_MS;
    if (repeatSender) this.lastRepeatPage.set(contactKey, now);
    return { burst, repeatSender };
  }
}

// ---------------------------------------------------------------------------------------------
// ledger row (the writer lives in safety-ledger.ts: this file stays import-free)

export interface InjectionLedgerRow {
  ts: string;
  kind: "inbound_injection";
  source: "intercom" | "support_email" | "proof_extract";
  ref: string;
  contact_id?: string | null;
  contact_role?: string | null;
  external_id?: string | null;
  email_sha256?: string | null;
  /** The turn this row is about (Intercom: newest part id of the batch). Digest dedupe key with text_sha256. */
  turn_id?: string | null;
  /** sha256 of the scanned text: a retried read of the same text collapses, a different turn never does. */
  text_sha256?: string | null;
  severity: Severity;
  hits: InjectionHit[];
  classifier?: { label: string; score: number | null } | null;
  version: string;
}

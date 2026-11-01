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

export const INJECTION_WATCH_VERSION = "iw-2026-11-01.1";
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
}

const COMPILED = INJECTION_RULES.map((r) => ({ ...r, re: new RegExp(r.source, r.flags) }));

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
    hits.push({ rule: r.rule, severity, excerpt: cut(m[0]) });
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

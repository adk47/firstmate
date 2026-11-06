/**
 * Side-effect half of the Caroline safety layer (caroline-guard-g1). The decisions are pure and
 * live in caroline-output-guard.ts (outbound) and injection-watch.ts (inbound); this file only
 * records and routes them: ledger row, conversation tag, hand-off to the human inbox, supervision
 * page. channel.ts calls exactly two functions: watchInbound() and guardOutbound().
 *
 * Invariants (pinned by tests/caroline-safety.test.ts):
 *   - watchInbound never changes, delays past its timeout, or drops the customer's message; it
 *     returns nothing the dispatch uses. Detection only.
 *   - guardOutbound returns the body to post. On an enforced block that is the approved hand-off
 *     line AND the conversation is reassigned to the human inbox (the line is then true). A
 *     failure in any side effect (ledger, tag, page) never turns a block into a pass.
 */
import { guardCarolineReply, OUTPUT_GUARD_MODE, type GuardResult } from "./caroline-output-guard.js";
import { isHandoffConflict } from "./outbound.js";
import {
  INJECTION_TAG,
  INJECTION_WATCH_VERSION,
  InjectionPager,
  scanForInjection,
  topSeverity,
  type InjectionLedgerRow,
} from "./injection-watch.js";
import { createHash } from "node:crypto";
import { appendSafetyLedger, emailSha256 } from "./safety-ledger.js";
import { classifierBlocksOutbound, classifyText, OUTBOUND_BLOCK_SCORE, type ClassifierResult } from "./safety-classifier.js";
import { BLOCKED_REPLY_FALLBACK } from "./answer-bank.js";

export const OUTPUT_GUARD_TAG = "ai:output-guard";

export interface SafetyLog {
  info?: (m: string) => void;
  warn?: (m: string) => void;
  error?: (m: string) => void;
}

export interface SafetyClient {
  addTag(conversationId: string, name: string, adminId: string): Promise<void>;
  assignConversation(params: { conversationId: string; adminId: string; assigneeId: string }): Promise<unknown>;
}

export interface SafetyAccount {
  botAdminId: string;
  defaultInboxId?: string;
  fallbackSlackSupervisionChannel?: string;
  /**
   * Classifier rollout stage (IntercomAccountConfig.safetyClassifier). Absent = "enforce", the
   * historical behaviour, so a host that never sets the key keeps exactly what it does today.
   */
  safetyClassifier?: { mode?: "shadow" | "enforce" };
}

export interface SafetyDeps {
  classify?: (text: string) => Promise<ClassifierResult>;
  appendLedger?: (row: Record<string, unknown>) => Promise<string | null>;
  page?: (text: string) => Promise<boolean>;
  now?: () => number;
}

const sharedPager = new InjectionPager();

function deps(d: SafetyDeps | undefined, account: SafetyAccount, tag: string, conversationId: string, log?: SafetyLog) {
  return {
    classify: d?.classify ?? ((t: string) => classifyText(t)),
    appendLedger: d?.appendLedger ?? ((row: Record<string, unknown>) => appendSafetyLedger(row)),
    // channel.ts passes the supervision-webhook pager; without one the page is a grep-able ALERT line.
    page:
      d?.page ??
      (async (text: string) => {
        log?.error?.(`[intercom:ALERT] [${tag}] safety page (no pager wired) conv=${conversationId}: ${text}`);
        return false;
      }),
    now: d?.now ?? (() => Date.now()),
  };
}

// ---------------------------------------------------------------------------------------------
// inbound

export interface InboundWatchParams {
  client: SafetyClient;
  account: SafetyAccount;
  conversationId: string;
  contactId: string;
  contactEmail?: string | null;
  /** The customer's text this turn (the coalesced batch, BEFORE our context blocks are added). */
  text: string;
  /** Customer-controlled attachment metadata (file names, declared types). */
  attachmentNames?: string[];
  /** This turn's identity (newest Intercom part id): two turns in one conversation are two hit-turns. */
  turnId?: string | null;
  tag: string;
  log?: SafetyLog;
  deps?: SafetyDeps;
  pager?: InjectionPager;
  /** Test seam: the per-process classifier-health counter. */
  health?: ClassifierHealth;
}

export interface InboundWatchResult {
  severity: "high" | "medium" | "low" | null;
  rules: string[];
  classifier: ClassifierResult;
}

// ---------------------------------------------------------------------------------------------
// classifier health (QA on #1628): an outage on CLEAN traffic writes no hit row, so availability is
// counted on EVERY call, in and out, and flushed as one `classifier_health` ledger row per window.
// The daily digest sums these rows; a sidecar that was down for hours and back by the 06:10 probe
// still shows as N unavailable calls.

export const CLASSIFIER_HEALTH_WINDOW_MS = 15 * 60 * 1000;

export class ClassifierHealth {
  private windowStart: number | null = null;
  private calls = { inbound: 0, outbound: 0 };
  private unavailable = { inbound: 0, outbound: 0 };

  /** Count one call; returns the row to append when the window closed, else null. */
  record(direction: "inbound" | "outbound", label: ClassifierResult["label"], now: number): Record<string, unknown> | null {
    if (this.windowStart === null) this.windowStart = now;
    this.calls[direction]++;
    if (label === "unavailable") this.unavailable[direction]++;
    return this.flushIfDue(now);
  }

  /** The window row when the window has closed (by a call OR by the clock), else null. */
  flushIfDue(now: number): Record<string, unknown> | null {
    if (this.windowStart === null || now - this.windowStart < CLASSIFIER_HEALTH_WINDOW_MS) return null;
    if (this.calls.inbound + this.calls.outbound === 0) {
      this.windowStart = null;
      return null;
    }
    const row = {
      ts: new Date(now).toISOString(),
      kind: "classifier_health",
      source: "intercom",
      window_start: new Date(this.windowStart).toISOString(),
      calls: this.calls.inbound + this.calls.outbound,
      unavailable: this.unavailable.inbound + this.unavailable.outbound,
      by_direction: { calls: { ...this.calls }, unavailable: { ...this.unavailable } },
    };
    this.windowStart = now;
    this.calls = { inbound: 0, outbound: 0 };
    this.unavailable = { inbound: 0, outbound: 0 };
    return row;
  }
}

const sharedHealth = new ClassifierHealth();
// Totals also close on the CLOCK (an idle gateway still writes its last window); unref'd so it never
// holds the process open. Unavailable calls do not depend on this: each one is persisted at once.
setInterval(() => {
  const row = sharedHealth.flushIfDue(Date.now());
  if (row) void appendSafetyLedger(row);
}, 60_000).unref?.();

async function classifyCounted(
  d: ReturnType<typeof deps>,
  health: ClassifierHealth,
  direction: "inbound" | "outbound",
  text: string,
  log: SafetyLog | undefined,
  tag: string,
): Promise<ClassifierResult> {
  const result = await d.classify(text).catch((): ClassifierResult => ({ label: "unavailable", score: null }));
  if (result.label === "unavailable") {
    // Persisted PER CALL (QA on #1628): an outage on clean traffic survives an idle period and a restart,
    // and the daily digest counts these rows, never an in-memory counter.
    const err = await d.appendLedger({
      ts: new Date(d.now()).toISOString(),
      kind: "classifier_unavailable",
      source: "intercom",
      direction,
    });
    if (err) log?.error?.(`[intercom:ALERT] [${tag}] classifier-unavailable ledger append failed: ${err}`);
  }
  const row = health.record(direction, result.label, d.now());
  if (row) {
    const err = await d.appendLedger(row);
    if (err) log?.error?.(`[intercom:ALERT] [${tag}] classifier-health ledger append failed: ${err}`);
  }
  return result;
}

export async function watchInbound(p: InboundWatchParams): Promise<InboundWatchResult> {
  const d = deps(p.deps, p.account, p.tag, p.conversationId, p.log);
  const pager = p.pager ?? sharedPager;
  const scanned = [p.text, ...(p.attachmentNames ?? [])].join("\n");
  const hits = scanForInjection(scanned);
  const classifier = await classifyCounted(d, p.health ?? sharedHealth, "inbound", p.text, p.log, p.tag);
  if (classifier.label === "injection" || classifier.label === "jailbreak") {
    hits.push({ rule: `classifier_${classifier.label}`, severity: (classifier.score ?? 0) >= 0.9 ? "medium" : "low", excerpt: `score=${classifier.score}` });
  }
  const severity = topSeverity(hits);
  const result: InboundWatchResult = { severity, rules: hits.map((h) => h.rule), classifier };
  if (!severity) return result;

  const row: InjectionLedgerRow = {
    ts: new Date(d.now()).toISOString(),
    kind: "inbound_injection",
    source: "intercom",
    ref: p.conversationId,
    contact_id: p.contactId || null,
    contact_role: null,
    external_id: null,
    email_sha256: emailSha256(p.contactEmail),
    turn_id: p.turnId || null,
    text_sha256: createHash("sha256").update(scanned).digest("hex"),
    severity,
    hits,
    classifier,
    version: INJECTION_WATCH_VERSION,
  };
  p.log?.warn?.(
    `[intercom:injection-watch] [${p.tag}] conv=${p.conversationId} contact=${p.contactId} severity=${severity} rules=${result.rules.join(",")} classifier=${classifier.label}${classifier.score !== null ? `:${classifier.score}` : ""} (detection only, message dispatched unchanged)`,
  );
  const err = await d.appendLedger(row as unknown as Record<string, unknown>);
  if (err) p.log?.error?.(`[intercom:ALERT] [${p.tag}] injection ledger append failed conv=${p.conversationId}: ${err}`);
  // Low-only turns (a zero-width run from a mail client, an unexplained base64 blob) are ledger
  // rows for the digest; they are not worth a human's attention in the inbox or a page.
  if (severity === "low") return result;
  p.client.addTag(p.conversationId, INJECTION_TAG, p.account.botAdminId).catch((e) =>
    p.log?.warn?.(`[intercom:injection-watch] [${p.tag}] tag ${INJECTION_TAG} failed conv=${p.conversationId}: ${e}`),
  );
  const due = pager.record(p.contactId || `conv:${p.conversationId}`, severity, d.now());
  if (due.burst || due.repeatSender) {
    const why = [due.burst ? "BURST (fleet-wide hits in the last hour)" : "", due.repeatSender ? "REPEAT SENDER (same contact, 24 h)" : ""]
      .filter(Boolean)
      .join(" + ");
    await d
      .page(
        `:shield: Prompt-injection watch: ${why}. Latest conv ${p.conversationId}, severity ${severity}, rules ${result.rules.join(", ")}. ` +
          `Detection only: nothing was acted on. Ledger: /var/lib/hydra/injection-watch/ledger.jsonl`,
      )
      .catch(() => false);
  }
  return result;
}

// ---------------------------------------------------------------------------------------------
// outbound

export interface OutboundGuardParams {
  client: SafetyClient;
  account: SafetyAccount;
  conversationId: string;
  reply: string;
  customerText: string;
  customerNames?: string[];
  customerEmails?: string[];
  /** Code-sourced facts at send (see GuardInput.facts). */
  facts?: { openRequest?: boolean };
  /** Per-deploy canary token (see GuardInput.canary). Resolved by the caller, never read from env here. */
  canary?: string;
  tag: string;
  log?: SafetyLog;
  deps?: SafetyDeps;
  /** Test seam: the per-process classifier-health counter. */
  health?: ClassifierHealth;
}

export interface OutboundGuardOutcome {
  body: string;
  blocked: boolean;
  result: GuardResult;
  classifier: ClassifierResult;
  /** Blocked + enforced only: where the conversation actually ended up. */
  assignment?: "team_inbox" | "already_assigned" | "unassigned" | "FAILED" | "not_enforced";
}

export async function guardOutbound(p: OutboundGuardParams): Promise<OutboundGuardOutcome> {
  const d = deps(p.deps, p.account, p.tag, p.conversationId, p.log);
  const result = guardCarolineReply({
    reply: p.reply,
    customerText: p.customerText,
    customerNames: p.customerNames,
    customerEmails: p.customerEmails,
    facts: p.facts,
    canary: p.canary,
  });
  // Classifier second: only when the rules passed, and it can only ADD a block.
  // Rollout stage comes from CONFIG, never from the ambient environment (a pinned test asserts this
  // file never reads an environment variable). Absent or unrecognised = "enforce": the conservative
  // direction is the one this lane already ships.
  const classifierMode = p.account.safetyClassifier?.mode === "shadow" ? "shadow" : "enforce";
  let classifier: ClassifierResult = { label: "unavailable", score: null };
  if (result.verdict === "pass") {
    classifier = await classifyCounted(d, p.health ?? sharedHealth, "outbound", p.reply, p.log, p.tag);
    if (classifierBlocksOutbound(classifier)) {
      if (classifierMode === "shadow") {
        // SHADOW (the 24 h measurement window, Fable safety lead §5): record exactly what ENFORCE
        // would have blocked, and post the reply unchanged. The ledger row IS the measurement -- the
        // false-positive rate is computed from these rows, so this must never be folded into
        // `flags` or `verdict`, where the normal note/block paths would both distort it.
        p.log?.warn?.(
          `[intercom:output-guard] [${p.tag}] conv=${p.conversationId} SHADOW-CLASSIFIER-BLOCK label=${classifier.label} score=${classifier.score} threshold=${OUTBOUND_BLOCK_SCORE} (posted unchanged)`,
        );
        const shadowErr = await d.appendLedger({
          ts: new Date(d.now()).toISOString(),
          kind: "classifier_shadow_block",
          source: "intercom",
          direction: "outbound",
          ref: p.conversationId,
          label: classifier.label,
          score: classifier.score,
          threshold: OUTBOUND_BLOCK_SCORE,
        });
        if (shadowErr) {
          p.log?.error?.(
            `[intercom:ALERT] [${p.tag}] classifier-shadow ledger append failed conv=${p.conversationId}: ${shadowErr}`,
          );
        }
      } else {
        result.verdict = "block";
        result.flags.push({ family: "reveal", rule: `classifier_${classifier.label}`, excerpt: `score=${classifier.score}` });
        if (OUTPUT_GUARD_MODE === "enforce") result.body = BLOCKED_REPLY_FALLBACK;
      }
    }
  }
  if (result.verdict === "pass") {
    // Notes (a paraphrased bank line) never block; they are logged for the copy owner's digest.
    if (result.flags.length > 0) {
      p.log?.warn?.(
        `[intercom:output-guard] [${p.tag}] conv=${p.conversationId} NOTE rules=${result.flags.map((f) => f.rule).join(",")} (posted unchanged)`,
      );
      const noteErr = await d.appendLedger({
        ts: new Date(d.now()).toISOString(),
        kind: "output_note",
        source: "intercom",
        ref: p.conversationId,
        flags: result.flags,
        guard_version: result.guardVersion,
        bank_version: result.bankVersion,
      });
      if (noteErr) p.log?.error?.(`[intercom:ALERT] [${p.tag}] output-guard ledger append failed conv=${p.conversationId}: ${noteErr}`);
    }
    return { body: result.body, blocked: false, result, classifier };
  }

  const enforced = OUTPUT_GUARD_MODE === "enforce";
  const rules = result.flags.map((f) => `${f.family}/${f.rule}`);
  p.log?.error?.(
    `[intercom:output-guard] [${p.tag}] conv=${p.conversationId} ${enforced ? "BLOCKED" : "SHADOW-BLOCK"} rules=${rules.join(",")} ` +
      `excerpts=${JSON.stringify(result.flags.map((f) => f.excerpt))} guard=${result.guardVersion} bank=${result.bankVersion}`,
  );
  p.client.addTag(p.conversationId, OUTPUT_GUARD_TAG, p.account.botAdminId).catch((e) =>
    p.log?.warn?.(`[intercom:output-guard] [${p.tag}] tag ${OUTPUT_GUARD_TAG} failed conv=${p.conversationId}: ${e}`),
  );

  // The fallback says a teammate takes it from here: make that true before it is posted. One retry;
  // the ACTUAL outcome is what the ledger row and the page report (QA on #1628: a failed reassign
  // must never be reported as "with the team inbox").
  let assignment: "team_inbox" | "already_assigned" | "unassigned" | "FAILED" | "not_enforced" = "not_enforced";
  if (enforced) {
    const assigneeId = p.account.defaultInboxId || "0";
    // A conflict naming the NON-BOT assignee we asked for is the desired end state, not a failure
    // (read-back 2026-11-03: conv 215476670359602 paged "STILL ASSIGNED TO THE BOT" while a human,
    // admin 5465657, already held it). Same rule escalation-action.ts already applies to conflicts.
    // A conflict naming the BOT is NOT a hand-off: that conversation really is still bot-owned.
    // Only a REAL hand-off target counts (configured, and not the bot): see isHandoffConflict.
    const alreadyWithTarget = (e: unknown) => isHandoffConflict(e, p.account);
    let lastErr: unknown = null;
    let already = false;
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await p.client.assignConversation({ conversationId: p.conversationId, adminId: p.account.botAdminId, assigneeId });
        lastErr = null;
        break;
      } catch (e) {
        lastErr = e;
        if (alreadyWithTarget(e)) {
          already = true;
          lastErr = null;
          break;
        }
      }
    }
    assignment = lastErr
      ? "FAILED"
      : already
        ? "already_assigned"
        : p.account.defaultInboxId
          ? "team_inbox"
          : "unassigned";
    if (lastErr) {
      p.log?.error?.(`[intercom:ALERT] [${p.tag}] output-guard reassignment FAILED twice conv=${p.conversationId}: ${lastErr}`);
    } else if (already) {
      p.log?.info?.(
        `[intercom:output-guard] [${p.tag}] conv=${p.conversationId} already assigned to ${assigneeId}: hand-off already held, no reassignment needed`,
      );
    }
  }

  const err = await d.appendLedger({
    ts: new Date(d.now()).toISOString(),
    kind: "output_guard",
    source: "intercom",
    ref: p.conversationId,
    mode: result.mode,
    enforced,
    assignment,
    flags: result.flags,
    classifier,
    guard_version: result.guardVersion,
    bank_version: result.bankVersion,
  });
  if (err) p.log?.error?.(`[intercom:ALERT] [${p.tag}] output-guard ledger append failed conv=${p.conversationId}: ${err}`);
  if (!enforced) return { body: p.reply, blocked: false, result, classifier, assignment };

  const where =
    assignment === "team_inbox"
      ? "The conversation is now with the team inbox: please answer it."
      : assignment === "already_assigned"
        ? "The conversation was ALREADY assigned to the hand-off target: a human already holds it, nothing to do."
        : assignment === "unassigned"
        ? "The conversation is now UNASSIGNED (no defaultInboxId configured): please pick it up from Unassigned."
        : "REASSIGNMENT FAILED: the conversation is STILL ASSIGNED TO THE BOT, so no human queue holds it. " +
          "Assign it to yourself in Intercom now and answer it.";
  await d
    .page(
      `${assignment === "FAILED" ? ":rotating_light:" : ":no_entry:"} Caroline's reply was blocked by the output guard ` +
        `(conv ${p.conversationId}; ${rules.join(", ")}). The customer got the hand-off line. ${where}`,
    )
    .catch(() => false);
  return { body: result.body, blocked: true, result, classifier, assignment };
}

import type { ContactConversationsPage, ConversationSummary, IntercomClient, IntercomConversation } from "./types.js";
import { MAX_OUTBOUND_MESSAGE_IDS } from "./types.js";
import { sanitizeOutboundBody } from "./sanitize-email.js";
import { sanitizeToolLeak } from "./sanitize-tool-leak.js";
import { sanitizeTypography } from "./sanitize-typography.js";
import { sanitizeHelpLinks } from "./sanitize-help-links.js";
import { loadHelpManifest, type HelpManifest } from "./help-manifest.js";
import { sanitizeHandoffClaim } from "./sanitize-handoff-claim.js";
import { sanitizeInternalReference } from "./sanitize-internal-reference.js";
import { wasTicketFiledRecently, getFiledTicketIds } from "./ticket-success-signal.js";

// --- Outbound reply retry (design §7 Rate Limiting) ---
// "Intercom returns 429 with Retry-After. Retry with capped exponential
// backoff + jitter (max 3 retries, max 30s total wait). v1 retry is in-memory."
// Without this, a single 429 or transient 5xx on the customer-facing reply send
// threw all the way up to the caller's catch, which only logged and dropped the
// reply — the "silent dispatch" (customer message processed, reply never sent).
export const REPLY_MAX_RETRIES = 3; // retries AFTER the first attempt (max 4 sends)
export const REPLY_BASE_BACKOFF_MS = 500; // base for exponential backoff
export const REPLY_MAX_BACKOFF_MS = 8_000; // per-attempt cap
export const REPLY_MAX_TOTAL_WAIT_MS = 30_000; // cumulative wait budget across retries

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

/**
 * Compute the delay before the next retry attempt.
 * - For a 429, Intercom tells us how long to wait via Retry-After. That is a
 *   server-directed MINIMUM, not a hint: retrying before the window clears
 *   just earns another 429 and burns a retry, dropping the reply early — the
 *   exact failure this retry path exists to prevent. So honor it as a floor
 *   (RateLimitError.retryAfterSeconds * 1000) and add jitter ON TOP, rather
 *   than jittering the wait down toward zero. Bounded by the TOTAL wait
 *   budget (REPLY_MAX_TOTAL_WAIT_MS), NOT the per-attempt exponential cap:
 *   the 8s per-attempt cap is right for our own 5xx backoff, but clipping a
 *   server directive below its value (e.g. Retry-After 30 → 8s) just makes us
 *   retry before the window clears and burn the budget early. A directive
 *   that fits inside the budget is honored in full; sendReplyWithRetry then
 *   clamps by the budget actually remaining.
 * - For 5xx there is no server directive, so use capped exponential backoff
 *   (base * 2^(attempt-1)) with full jitter in [0, ceiling] (AWS "full
 *   jitter") to de-correlate retries when many conversations hit at once.
 * `attempt` is 1-based (1 = delay before the 1st retry).
 */
export function computeReplyBackoffMs(
  attempt: number,
  err: unknown,
  rand: () => number = Math.random,
): number {
  if (err instanceof RateLimitError) {
    // Retry-After is a floor, not a ceiling: never sleep less than the
    // server-directed wait. Jitter is additive (anti-thundering-herd). Bound
    // by the TOTAL wait budget, not the per-attempt exponential cap — clipping
    // a server directive that fits in the budget would retry before the window
    // clears. The wrapper's cumulative-wait clamp further bounds by what's left.
    const floorMs = err.retryAfterSeconds * 1000;
    const jitterMs = Math.floor(rand() * REPLY_BASE_BACKOFF_MS);
    return Math.min(floorMs + jitterMs, REPLY_MAX_TOTAL_WAIT_MS);
  }
  // 5xx: capped exponential backoff with full jitter in [0, ceiling].
  const ceiling = Math.min(
    REPLY_BASE_BACKOFF_MS * Math.pow(2, Math.max(0, attempt - 1)),
    REPLY_MAX_BACKOFF_MS,
  );
  return Math.floor(rand() * ceiling);
}

/**
 * True for errors worth retrying: 429 (RateLimitError) and 5xx
 * (IntercomServerError). 4xx other than 429 (404 / permission / validation)
 * are NOT retryable — retrying them just wastes the budget and delays the
 * inevitable drop.
 */
export function isRetryableReplyError(err: unknown): boolean {
  return err instanceof RateLimitError || err instanceof IntercomServerError;
}

/**
 * Wrap a single-attempt reply send with capped exponential backoff + jitter.
 * Retries only retryable errors (429 / 5xx) up to REPLY_MAX_RETRIES, bounded by
 * REPLY_MAX_TOTAL_WAIT_MS of cumulative sleep. On exhaustion, emits a grep-able
 * `[intercom:ALERT] reply dropped after retries` line so the silent drop becomes
 * observable, then rethrows the last error for the caller's own handling.
 */
export async function sendReplyWithRetry<T>(
  attempt: () => Promise<T>,
  ctx: { conversationId: string },
  opts: {
    maxRetries?: number;
    maxTotalWaitMs?: number;
    sleepFn?: (ms: number) => Promise<void>;
    rand?: () => number;
    onAlert?: (msg: string) => void;
  } = {},
): Promise<T> {
  const maxRetries = opts.maxRetries ?? REPLY_MAX_RETRIES;
  const maxTotalWaitMs = opts.maxTotalWaitMs ?? REPLY_MAX_TOTAL_WAIT_MS;
  const sleepFn = opts.sleepFn ?? sleep;
  const onAlert = opts.onAlert ?? ((msg: string) => { try { console.error(msg); } catch { /* noop */ } });

  let totalWaited = 0;
  let attempts = 0;
  let lastErr: unknown;
  for (let i = 0; i <= maxRetries; i++) {
    try {
      return await attempt();
    } catch (err) {
      attempts++;
      lastErr = err;
      const triesLeft = maxRetries - i;
      if (!isRetryableReplyError(err) || triesLeft <= 0) break;
      let delay = computeReplyBackoffMs(i + 1, err, opts.rand);
      if (totalWaited + delay > maxTotalWaitMs) {
        delay = maxTotalWaitMs - totalWaited;
        if (delay <= 0) break; // budget exhausted — stop retrying
      }
      totalWaited += delay;
      await sleepFn(delay);
    }
  }
  // Only genuine retry EXHAUSTION on a still-retryable error is the "silent
  // dispatch after retries" this alert makes observable. Two cases must NOT
  // fire it, because their terminal failure is deterministic, not transient:
  //   - a non-retryable 4xx (404 / permission) on the FIRST attempt
  //     (attempts === 1), and
  //   - a non-retryable 4xx that surfaces on a LATER attempt after a transient
  //     429/5xx (attempts > 1 but lastErr is non-retryable).
  // Gating on isRetryableReplyError(lastErr) covers both — labeling either as
  // "dropped after retries" would mislabel a deterministic config bug as a
  // transient-exhaustion event. Both still surface via the rethrow below to
  // the caller's own error log.
  if (attempts > 1 && isRetryableReplyError(lastErr)) {
    onAlert(
      `[intercom:ALERT] reply dropped after retries conv=${ctx.conversationId} ` +
      `attempts=${attempts} maxRetries=${maxRetries} waitedMs=${totalWaited} error=${lastErr}`,
    );
  }
  throw lastErr;
}

export class MockIntercomClient implements IntercomClient {
  calls = {
    replyToConversation: [] as Array<{ conversationId: string; adminId: string; body: string }>,
    assignConversation: [] as Array<{ conversationId: string; adminId: string; assigneeId: string }>,
    addTag: [] as Array<{ conversationId: string; name: string; adminId: string }>,
    getConversation: [] as Array<{ conversationId: string }>,
    closeConversation: [] as Array<{ conversationId: string; adminId: string; body?: string }>,
    snoozeConversation: [] as Array<{ conversationId: string; adminId: string; snoozedUntil: number }>,
    listContactConversations: [] as Array<{ contactId: string; excludeConversationId?: string; limit?: number; timeoutMs?: number }>,
  };

  private messageCounter = 0;

  async replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }> {
    this.calls.replyToConversation.push(params);
    this.messageCounter++;
    return { messageId: `mock_msg_${this.messageCounter}` };
  }

  async assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void> {
    this.calls.assignConversation.push(params);
  }

  async addTag(conversationId: string, name: string, adminId: string): Promise<void> {
    this.calls.addTag.push({ conversationId, name, adminId });
  }

  async getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation> {
    // Default returns the legacy webhook shape (`assignee: null`) rather
    // than the real v2.11 API shape (`admin_assignee_id`). This is
    // intentional — it exercises the handler's fallback branch and keeps
    // existing backward-compat tests honest. Tests that need the v2.11
    // shape override `client.getConversation` inline with `admin_assignee_id`.
    this.calls.getConversation.push(params);
    return {
      type: "conversation",
      id: params.conversationId,
      title: null,
      created_at: Date.now() / 1000,
      updated_at: Date.now() / 1000,
      open: true,
      state: "open",
      assignee: null,
    };
  }

  async closeConversation(params: {
    conversationId: string;
    adminId: string;
    body?: string;
  }): Promise<void> {
    this.calls.closeConversation.push(params);
  }

  async snoozeConversation(params: {
    conversationId: string;
    adminId: string;
    snoozedUntil: number;
  }): Promise<void> {
    this.calls.snoozeConversation.push(params);
  }

  async listContactConversations(params: {
    contactId: string;
    excludeConversationId?: string;
    limit?: number;
    timeoutMs?: number;
  }): Promise<ContactConversationsPage> {
    this.calls.listContactConversations.push(params);
    return { conversations: [], totalCount: 0 };
  }
}

export class RealIntercomClient implements IntercomClient {
  private token: string;
  private baseUrl = "https://api.intercom.io";

  constructor(token: string) {
    this.token = token;
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.token}`,
      "Content-Type": "application/json",
      Accept: "application/json",
      "Intercom-Version": "2.11",
    };
  }

  private checkRateLimit(response: Response): void {
    if (response.status === 429) {
      const raw = response.headers.get("Retry-After");
      const seconds = raw ? parseInt(raw, 10) : NaN;
      throw new RateLimitError(Number.isFinite(seconds) && seconds > 0 ? seconds : 5);
    }
  }

  private async readErrorBody(response: Response): Promise<string> {
    try {
      return await response.text();
    } catch {
      return "<unreadable>";
    }
  }

  private async parseJson(response: Response, operation: string): Promise<any> {
    try {
      return await response.json();
    } catch {
      throw new Error(`Intercom ${operation}: invalid JSON response (status ${response.status})`);
    }
  }

  async replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }> {
    // Retry transient failures (429 / 5xx) with capped exponential backoff +
    // jitter so a single rate-limit or server blip doesn't silently drop the
    // customer-facing reply (design §7). 4xx (other than 429) still throws on
    // the first attempt — see replyToConversationOnce.
    return sendReplyWithRetry(
      () => this.replyToConversationOnce(params),
      { conversationId: params.conversationId },
    );
  }

  private async replyToConversationOnce(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }> {
    const url = `${this.baseUrl}/conversations/${params.conversationId}/reply`;
    const response = await fetch(url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        message_type: "comment",
        type: "admin",
        admin_id: params.adminId,
        body: params.body,
      }),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      const message = `Intercom replyToConversation failed: ${response.status} ${response.statusText} - ${errorBody}`;
      // 5xx is transient → typed so the retry wrapper can back off and retry.
      // 4xx (404 / permission / validation) is a plain Error → not retried.
      if (response.status >= 500) {
        throw new IntercomServerError(response.status, message);
      }
      throw new Error(message);
    }

    const data = await this.parseJson(response, "replyToConversation");
    // Intercom's /conversations/{id}/reply endpoint returns the full
    // conversation object. `data.id` is the conversation id, NOT the new
    // part/message id — the new part is the last entry in
    // conversation_parts.conversation_parts. Previously we returned
    // `data.id`, which meant every reply shared the same "messageId"
    // (the conv id), silently breaking isSelfReply() dedup and making
    // log lines useless for correlating replies.
    const parts = data?.conversation_parts?.conversation_parts;
    const lastPart = Array.isArray(parts) ? parts.at(-1) : null;
    return { messageId: lastPart?.id ?? "" };
  }

  async assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void> {
    const url = `${this.baseUrl}/conversations/${params.conversationId}/parts`;
    const response = await fetch(url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        message_type: "assignment",
        type: "admin",
        admin_id: params.adminId,
        assignee_id: params.assigneeId,
      }),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      // Try to parse Intercom's structured error response to detect the
      // "already assigned to this admin" case, which is an expected no-op
      // after gateway restarts / concurrent webhooks / manual reassigns.
      // Callers check `instanceof IntercomAssignmentConflictError` instead
      // of substring-matching the message (which breaks when Intercom
      // renames the error code — the exact failure class this PR is
      // fixing elsewhere).
      try {
        const parsed = JSON.parse(errorBody);
        const code = parsed?.errors?.[0]?.code;
        if (code === "conversation_already_assigned_to_assignee") {
          throw new IntercomAssignmentConflictError(
            `${params.conversationId} already assigned to ${params.assigneeId}`,
          );
        }
      } catch (err) {
        // Re-throw the structured error we just created, but let
        // JSON.parse failures fall through to the generic error below.
        if (err instanceof IntercomAssignmentConflictError) throw err;
      }
      throw new Error(`Intercom assignConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }
  }

  async addTag(conversationId: string, name: string, adminId: string): Promise<void> {
    // Intercom tags a conversation by tag ID, not name. POST /tags with a name
    // is idempotent "create or fetch" and returns the tag (with its id); we
    // then attach that id to the conversation. Two round-trips, but tagging
    // only fires once per flagged conversation, so no caching is warranted.
    const tagUrl = `${this.baseUrl}/tags`;
    const tagResponse = await fetch(tagUrl, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ name }),
    });
    this.checkRateLimit(tagResponse);
    if (!tagResponse.ok) {
      const errorBody = await this.readErrorBody(tagResponse);
      throw new Error(`Intercom addTag (resolve "${name}") failed: ${tagResponse.status} ${tagResponse.statusText} - ${errorBody}`);
    }
    const tag = await this.parseJson(tagResponse, "addTag/resolve");
    const tagId = tag?.id;
    if (!tagId) {
      throw new Error(`Intercom addTag: tag "${name}" resolved without an id`);
    }

    const attachUrl = `${this.baseUrl}/conversations/${conversationId}/tags`;
    const attachResponse = await fetch(attachUrl, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ id: String(tagId), admin_id: adminId }),
    });
    this.checkRateLimit(attachResponse);
    if (!attachResponse.ok) {
      const errorBody = await this.readErrorBody(attachResponse);
      throw new Error(`Intercom addTag (attach "${name}") failed: ${attachResponse.status} ${attachResponse.statusText} - ${errorBody}`);
    }
  }

  async getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation> {
    const url = `${this.baseUrl}/conversations/${params.conversationId}`;
    const response = await fetch(url, {
      method: "GET",
      headers: this.headers(),
      signal: AbortSignal.timeout(5000),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      throw new Error(`Intercom getConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }

    return await this.parseJson(response, "getConversation");
  }

  async closeConversation(params: {
    conversationId: string;
    adminId: string;
    body?: string;
  }): Promise<void> {
    // Closing is a "close" part on the same /parts endpoint as assignment.
    // A `body`, when present, is posted as the closing comment (sanitized
    // upstream by SanitizingIntercomClient). We omit `body` entirely when
    // absent so the close stays silent (no customer-visible message).
    const url = `${this.baseUrl}/conversations/${params.conversationId}/parts`;
    const payload: Record<string, unknown> = {
      message_type: "close",
      type: "admin",
      admin_id: params.adminId,
    };
    if (params.body) payload.body = params.body;
    const response = await fetch(url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify(payload),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      throw new Error(`Intercom closeConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }
  }

  async snoozeConversation(params: {
    conversationId: string;
    adminId: string;
    snoozedUntil: number;
  }): Promise<void> {
    const url = `${this.baseUrl}/conversations/${params.conversationId}/parts`;
    const response = await fetch(url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        message_type: "snoozed",
        admin_id: params.adminId,
        snoozed_until: params.snoozedUntil,
      }),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      throw new Error(`Intercom snoozeConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }
  }

  async listContactConversations(params: {
    contactId: string;
    excludeConversationId?: string;
    limit?: number;
    timeoutMs?: number;
  }): Promise<ContactConversationsPage> {
    // One round-trip: POST /conversations/search returns enough per row
    // (id/title/state/updated_at/source.body) to summarize without follow-up
    // GETs. NOTE: this endpoint 406s without Accept: application/json —
    // headers() already sends it; the regression test pins the header.
    // The search API has no documented sort param, so order client-side.
    // Excluding the current conversation server-side keeps total_count an
    // exact prior count even when the contact has more history than one page.
    // contact_ids matches conversations the contact PARTICIPATES in (incl.
    // admin-initiated outbound ones), not just those they authored. MUST be
    // queried with = (list-membership on this field), NOT ~ (contains):
    // verified live 2026-06-11 — ~ returns total_count 0 for every contact
    // despite the docs operator table listing it as valid for String, while
    // = returns the contact's full conversation list.
    const url = `${this.baseUrl}/conversations/search`;
    const contactQuery = { field: "contact_ids", operator: "=", value: params.contactId };
    const query = params.excludeConversationId
      ? {
          operator: "AND",
          value: [contactQuery, { field: "id", operator: "!=", value: params.excludeConversationId }],
        }
      : contactQuery;
    const response = await fetch(url, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({
        query,
        pagination: { per_page: params.limit ?? 5 },
      }),
      signal: AbortSignal.timeout(params.timeoutMs ?? 5000),
    });

    this.checkRateLimit(response);

    if (!response.ok) {
      const errorBody = await this.readErrorBody(response);
      throw new Error(`Intercom listContactConversations failed: ${response.status} ${response.statusText} - ${errorBody}`);
    }

    const data = await this.parseJson(response, "listContactConversations");
    const rows: any[] = Array.isArray(data?.conversations) ? data.conversations : [];
    const conversations = rows
      .map((c): ConversationSummary => ({
        id: String(c?.id ?? ""),
        title: typeof c?.title === "string" && c.title ? c.title : null,
        state: (c?.state === "closed" || c?.state === "snoozed" ? c.state : "open"),
        updatedAt: new Date(Number(c?.updated_at ?? 0) * 1000).toISOString(),
        snippet: String(c?.source?.body ?? "").replace(/<[^>]*>/g, "").trim().slice(0, 120),
      }))
      .filter((c) => c.id)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
    return {
      conversations,
      totalCount: typeof data?.total_count === "number" ? data.total_count : conversations.length,
    };
  }
}

/**
 * Minimal structural logger shape: the wrapper only needs `.error`. Matches a
 * subset of the OpenClaw `ctx.log` shape, and of `console`, so both work.
 */
export type SanitizerLogger = { error?: (msg: string) => void };

/**
 * Wraps an IntercomClient and replaces any outbound email address that is not
 * in ALLOWED_OUTBOUND_EMAILS with `support@muso.ai` before delegating to the
 * inner client.
 *
 * TypeScript `implements IntercomClient` enforces method-set completeness: if
 * the interface gains a method, this class fails to compile until a
 * pass-through is added. It does NOT guarantee that a new body-carrying
 * method routes the body through the sanitizer — the author of such a
 * method must still call `sanitizeOutboundBody` explicitly. The compiler
 * is one of three defense layers (wrapper, factory, pre-commit lint); no
 * single layer alone is the guarantee.
 *
 * See docs/designs/2026-04-17-cs-agent-email-guardrail-design.md.
 */
export class SanitizingIntercomClient implements IntercomClient {
  constructor(
    private readonly inner: IntercomClient,
    private readonly log?: SanitizerLogger,
    private readonly helpManifestLoader: () => HelpManifest | null = loadHelpManifest,
  ) {}

  /**
   * Help-centre link gate. The manifest is read only when a reply actually
   * contains an article URL. A null manifest fails closed (links stripped) and
   * is logged to the internal log only; the customer sees a normal answer.
   */
  private helpLinkPass(body: string, conversationId: string): string {
    const probe = sanitizeHelpLinks(body, null);
    if (probe.redactions.length === 0) return body;
    const manifest = this.helpManifestLoader();
    const pass = sanitizeHelpLinks(body, manifest);
    // A valid citation survives with no redactions: nothing to report.
    if (pass.redactions.length > 0) {
      const msg = `[intercom:help-link] conv=${conversationId} stripped=${pass.redactions.length}${manifest ? "" : " manifest=unavailable"} urls=${JSON.stringify(pass.redactions)}`;
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    return pass.body;
  }

  async replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string; dropped?: true }> {
    const emailPass = sanitizeOutboundBody(params.body);
    if (emailPass.redactions.length > 0) {
      // Dedupe for the audit line so a single markdown-linked email
      // (`[x@y.z](mailto:x@y.z)`) doesn't double-count and inflate the
      // 7-day signal-review window described in the design doc.
      const unique = Array.from(new Set(emailPass.redactions));
      const msg = `[intercom:email-leak] conv=${params.conversationId} count=${unique.length} redacted=${JSON.stringify(unique)}`;
      // Logging must never block delivery: the sanitizer has already done its
      // job by this point. If log.error throws (broken backend, buggy logger),
      // fall through to console.error so the leak is still observable, but
      // never let the exception propagate and drop the already-sanitized reply.
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    const toolPass = sanitizeToolLeak(emailPass.body);
    if (toolPass.redactions.length > 0) {
      // Dedupe for the audit line — mirrors the email-leak dedup logic above.
      const unique = Array.from(new Set(toolPass.redactions));
      const msg = `[intercom:tool-leak] conv=${params.conversationId} count=${unique.length} redacted=${JSON.stringify(unique)}`;
      // Logging must never block delivery (same contract as email path above).
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    const typoPass = sanitizeTypography(this.helpLinkPass(toolPass.body, params.conversationId));
    if (typoPass.redactions.length > 0) {
      const msg = `[intercom:typography] conv=${params.conversationId} count=${typoPass.redactions.length}`;
      // Logging must never block delivery (same contract as the passes above).
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    // False-handoff-claim pass (honesty enforcement). A completed-action claim like
    // "I've flagged this for our team" is only honest if create_ticket actually
    // succeeded for this conversation; the cross-plugin signal (set by support-tools on
    // a successful file) tells us. When it did not, rewrite the claim down to the
    // sanctioned "I'll make sure this gets to the team." fallback. Runs after the other
    // text passes; a lost/absent signal errs toward the honest fallback.
    const ticketConfirmed = wasTicketFiledRecently(params.conversationId);
    // MUS-1516: which ids this conversation actually filed, so the guard can
    // tell a real quoted reference number from one it never filed.
    const filedTicketIds = getFiledTicketIds(params.conversationId);
    const handoffPass = sanitizeHandoffClaim(typoPass.body, { ticketConfirmed, filedTicketIds });
    if (handoffPass.redactions.length > 0) {
      const unique = Array.from(new Set(handoffPass.redactions));
      const msg = `[intercom:false-handoff-claim] conv=${params.conversationId} count=${unique.length} rewritten=${JSON.stringify(unique)}`;
      // Logging must never block delivery (same contract as the passes above).
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    // Internal-reference pass: a bare ClickUp task id must never reach a customer
    // (sanitize-tool-leak bans the words, not the id). Rewrites to a neutral phrase.
    // Runs AFTER the handoff guard so that guard still sees 86… ids and can swap a false
    // claim for the honest fallback; this pass is the backstop for whatever it keeps.
    const refPass = sanitizeInternalReference(handoffPass.body);
    if (refPass.redactions.length > 0) {
      const unique = Array.from(new Set(refPass.redactions));
      const msg = `[intercom:internal-reference] conv=${params.conversationId} count=${unique.length} rewritten=${JSON.stringify(unique)}`;
      // Logging must never block delivery (same contract as the passes above).
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
    }
    // The channel's empty-reply guard runs before this wrapper, so a reply that was
    // only a citation the gate removed would otherwise post `body: ""`. Post nothing, and
    // alert: no other mechanism pages a dropped reply (the wrapper returns messageId "").
    if (refPass.body.trim().length === 0 && params.body.trim().length > 0) {
      const msg = `[intercom:ALERT] [intercom:empty-after-sanitize] conv=${params.conversationId} posting nothing`;
      try {
        this.log?.error?.(msg);
      } catch {
        try { console.error(msg); } catch { /* noop */ }
      }
      return { messageId: "", dropped: true };
    }
    return this.inner.replyToConversation({ ...params, body: refPass.body });
  }

  async assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void> {
    return this.inner.assignConversation(params);
  }

  async addTag(conversationId: string, name: string, adminId: string): Promise<void> {
    // Tag name is an internal constant (ai:data-complaint), never customer-
    // facing — nothing to sanitize. Pass through.
    return this.inner.addTag(conversationId, name, adminId);
  }

  async getConversation(params: {
    conversationId: string;
  }): Promise<IntercomConversation> {
    return this.inner.getConversation(params);
  }

  async closeConversation(params: {
    conversationId: string;
    adminId: string;
    body?: string;
  }): Promise<void> {
    // No close-note is passed today, but if one ever is, route it through the
    // same email + tool-leak sanitizer as replyToConversation (defense-in-depth)
    // before it can reach a customer.
    if (params.body) {
      const emailPass = sanitizeOutboundBody(params.body);
      const toolPass = sanitizeToolLeak(emailPass.body);
      const typoPass = sanitizeTypography(this.helpLinkPass(toolPass.body, params.conversationId));
      const refPass = sanitizeInternalReference(typoPass.body);
      // A note the gate emptied must not go out as `body: ""`, and closing without it
      // would swallow the intended answer and drop the conversation from the open
      // queue. Leave it open for a human and alert: nothing else reports it.
      if (refPass.body.trim().length === 0) {
        const msg = `[intercom:ALERT] [intercom:empty-after-sanitize] conv=${params.conversationId} close suppressed \u2014 note emptied by help-link gate, conversation left open for a human`;
        try {
          this.log?.error?.(msg);
        } catch {
          try { console.error(msg); } catch { /* noop */ }
        }
        return;
      }
      return this.inner.closeConversation({ ...params, body: refPass.body });
    }
    return this.inner.closeConversation(params);
  }

  async snoozeConversation(params: {
    conversationId: string;
    adminId: string;
    snoozedUntil: number;
  }): Promise<void> {
    return this.inner.snoozeConversation(params);
  }

  async listContactConversations(params: {
    contactId: string;
    excludeConversationId?: string;
    limit?: number;
    timeoutMs?: number;
  }): Promise<ContactConversationsPage> {
    // Read path — nothing outbound to a customer to sanitize. The summaries'
    // customer-controlled text is sanitized at the point of context injection
    // (sanitizeEnrichmentValue in channel.ts), not here.
    return this.inner.listContactConversations(params);
  }
}

/**
 * The only sanctioned way to construct an outbound Intercom client.
 * Always wraps `RealIntercomClient` in `SanitizingIntercomClient`.
 *
 * Construction of `RealIntercomClient` directly is blocked by a
 * pre-commit lint outside this file.
 */
export function createIntercomClient(
  token: string,
  log?: SanitizerLogger,
): IntercomClient {
  return new SanitizingIntercomClient(new RealIntercomClient(token), log);
}

export class RateLimitError extends Error {
  retryAfterSeconds: number;
  constructor(retryAfterSeconds: number) {
    super(`Rate limited. Retry after ${retryAfterSeconds}s`);
    this.name = "RateLimitError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

/**
 * Thrown for Intercom 5xx responses (transient server-side failures). Carries
 * the status so the outbound reply retry can distinguish retryable 5xx from
 * non-retryable 4xx (404 / permission / validation), which throw a plain Error.
 */
export class IntercomServerError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "IntercomServerError";
    this.status = status;
  }
}

/**
 * Thrown by `assignConversation` when Intercom reports the conversation is
 * already assigned to the specified assignee. This is an expected no-op
 * (gateway restart, concurrent webhook, manual reassign in Intercom UI),
 * not an error — callers should catch it and sync local state.
 */
export class IntercomAssignmentConflictError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IntercomAssignmentConflictError";
  }
}

export function trackOutboundMessageId(messageId: string, outboundIds: string[]): void {
  // Defend against `""` poisoning `outboundMessageIds`: if it landed in the
  // array, `isSelfReply(filters.ts)` would false-positive on any admin_reply
  // webhook whose part.id also parses to "", silently filtering legitimate
  // human-admin takeovers. Guard at the boundary so all callers are safe.
  if (!messageId) return;
  if (outboundIds.length >= MAX_OUTBOUND_MESSAGE_IDS) {
    outboundIds.shift();
  }
  outboundIds.push(messageId);
}

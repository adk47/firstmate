import type { ContactConversationsPage, ConversationSummary, IntercomClient, IntercomConversation } from "./types.js";
import { MAX_OUTBOUND_MESSAGE_IDS } from "./types.js";
import { sanitizeOutboundBody } from "./sanitize-email.js";
import { sanitizeToolLeak } from "./sanitize-tool-leak.js";

export class MockIntercomClient implements IntercomClient {
  calls = {
    replyToConversation: [] as Array<{ conversationId: string; adminId: string; body: string }>,
    assignConversation: [] as Array<{ conversationId: string; adminId: string; assigneeId: string }>,
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
      throw new Error(`Intercom replyToConversation failed: ${response.status} ${response.statusText} - ${errorBody}`);
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
    // admin-initiated outbound ones), not just those they authored. It's a
    // multi-valued String search field, so use ~ (contains) rather than = —
    // exact equality can miss multi-participant conversations. Containment of
    // a full fixed-length contact id can't match a different contact.
    const url = `${this.baseUrl}/conversations/search`;
    const contactQuery = { field: "contact_ids", operator: "~", value: params.contactId };
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
 * See docs/2026-04-17-cs-agent-email-guardrail-design.md.
 */
export class SanitizingIntercomClient implements IntercomClient {
  constructor(
    private readonly inner: IntercomClient,
    private readonly log?: SanitizerLogger,
  ) {}

  async replyToConversation(params: {
    conversationId: string;
    adminId: string;
    body: string;
  }): Promise<{ messageId: string }> {
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
    return this.inner.replyToConversation({ ...params, body: toolPass.body });
  }

  async assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
  }): Promise<void> {
    return this.inner.assignConversation(params);
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
      return this.inner.closeConversation({ ...params, body: toolPass.body });
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

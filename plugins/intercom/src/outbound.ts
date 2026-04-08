import type { IntercomClient, IntercomConversation } from "./types.js";
import { MAX_OUTBOUND_MESSAGE_IDS } from "./types.js";

export class MockIntercomClient implements IntercomClient {
  calls = {
    replyToConversation: [] as Array<{ conversationId: string; adminId: string; body: string }>,
    assignConversation: [] as Array<{ conversationId: string; adminId: string; assigneeId: string }>,
    getConversation: [] as Array<{ conversationId: string }>,
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

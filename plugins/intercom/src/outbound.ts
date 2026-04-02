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
    return { messageId: data.id ?? "" };
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

export function trackOutboundMessageId(messageId: string, outboundIds: string[]): void {
  if (outboundIds.length >= MAX_OUTBOUND_MESSAGE_IDS) {
    outboundIds.shift();
  }
  outboundIds.push(messageId);
}

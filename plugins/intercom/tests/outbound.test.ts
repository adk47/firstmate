import { describe, it, expect, vi, afterEach } from "vitest";
import { MockIntercomClient, RealIntercomClient, trackOutboundMessageId } from "../src/outbound.js";

describe("MockIntercomClient", () => {
  it("records replyToConversation calls", async () => {
    const client = new MockIntercomClient();
    const result = await client.replyToConversation({
      conversationId: "conv_1",
      adminId: "admin_1",
      body: "Hello!",
    });
    expect(result.messageId).toBeTruthy();
    expect(client.calls.replyToConversation).toHaveLength(1);
    expect(client.calls.replyToConversation[0].body).toBe("Hello!");
  });

  it("records assignConversation calls", async () => {
    const client = new MockIntercomClient();
    await client.assignConversation({
      conversationId: "conv_1",
      adminId: "admin_1",
      assigneeId: "admin_2",
    });
    expect(client.calls.assignConversation).toHaveLength(1);
  });

  it("returns sequential message IDs", async () => {
    const client = new MockIntercomClient();
    const r1 = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "1" });
    const r2 = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "2" });
    expect(r1.messageId).not.toBe(r2.messageId);
  });
});

describe("RealIntercomClient", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("constructs with token", () => {
    const client = new RealIntercomClient("test_token");
    expect(client).toBeDefined();
  });

  it("replyToConversation returns the new part id, not the conversation id", async () => {
    // Regression: Intercom's /conversations/{id}/reply endpoint returns
    // the full conversation, whose `id` is the conversation id. The new
    // message part is the last entry in conversation_parts. Previously
    // we returned `data.id`, which silently broke isSelfReply() dedup.
    globalThis.fetch = vi.fn(async () => {
      return new Response(
        JSON.stringify({
          type: "conversation",
          id: "215473828430407", // conversation id
          conversation_parts: {
            conversation_parts: [
              { type: "conversation_part", id: "part_old_1" },
              { type: "conversation_part", id: "part_new_xyz" },
            ],
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("test_token");
    const result = await client.replyToConversation({
      conversationId: "215473828430407",
      adminId: "4359478",
      body: "hi",
    });
    expect(result.messageId).toBe("part_new_xyz");
    expect(result.messageId).not.toBe("215473828430407");
  });

  it("replyToConversation returns empty messageId when no parts are present", async () => {
    globalThis.fetch = vi.fn(async () => {
      return new Response(
        JSON.stringify({ type: "conversation", id: "conv_1" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("test_token");
    const result = await client.replyToConversation({
      conversationId: "conv_1",
      adminId: "admin_1",
      body: "hi",
    });
    expect(result.messageId).toBe("");
  });
});

describe("trackOutboundMessageId", () => {
  it("adds message ID to array", () => {
    const ids: string[] = [];
    trackOutboundMessageId("msg_1", ids);
    expect(ids).toContain("msg_1");
  });

  it("evicts oldest when exceeding limit", () => {
    const ids = Array.from({ length: 500 }, (_, i) => `msg_${i}`);
    trackOutboundMessageId("msg_new", ids);
    expect(ids.length).toBe(500);
    expect(ids).not.toContain("msg_0");
    expect(ids).toContain("msg_new");
  });

  it("ignores empty-string messageId (poisoning guard)", () => {
    // Regression: replyToConversation returns "" when the Intercom response
    // has no conversation_parts. If that "" lands in outboundMessageIds,
    // isSelfReply() false-positives on any admin_reply whose part.id also
    // parses to "", silently filtering legitimate human-admin takeovers.
    const ids: string[] = [];
    trackOutboundMessageId("", ids);
    expect(ids).toHaveLength(0);
  });
});

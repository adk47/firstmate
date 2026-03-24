import { describe, it, expect } from "vitest";
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
  it("constructs with token", () => {
    const client = new RealIntercomClient("test_token");
    expect(client).toBeDefined();
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
});

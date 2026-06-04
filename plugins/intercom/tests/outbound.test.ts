import { describe, it, expect, vi, afterEach } from "vitest";
import { MockIntercomClient, RealIntercomClient, trackOutboundMessageId, SanitizingIntercomClient, createIntercomClient } from "../src/outbound.js";
import type { IntercomClient, IntercomConversation } from "../src/types.js";

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

describe("close/snooze primitives (dormant capability)", () => {
  const originalFetch = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("MockIntercomClient records closeConversation and snoozeConversation calls", async () => {
    const client = new MockIntercomClient();
    await client.closeConversation({ conversationId: "c1", adminId: "a1" });
    await client.snoozeConversation({ conversationId: "c2", adminId: "a1", snoozedUntil: 123 });
    expect(client.calls.closeConversation).toHaveLength(1);
    expect(client.calls.closeConversation[0].conversationId).toBe("c1");
    expect(client.calls.snoozeConversation).toHaveLength(1);
    expect(client.calls.snoozeConversation[0].snoozedUntil).toBe(123);
  });

  it("RealIntercomClient.closeConversation POSTs a close part to /parts", async () => {
    let captured: { url: string; body: any } | null = null;
    globalThis.fetch = vi.fn(async (url: any, init: any) => {
      captured = { url: String(url), body: JSON.parse(init.body) };
      return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("tok");
    await client.closeConversation({ conversationId: "215", adminId: "5763097" });

    expect(captured!.url).toBe("https://api.intercom.io/conversations/215/parts");
    expect(captured!.body).toMatchObject({ message_type: "close", type: "admin", admin_id: "5763097" });
    expect(captured!.body.body).toBeUndefined();
  });

  it("RealIntercomClient.closeConversation includes an optional body when provided", async () => {
    let captured: any = null;
    globalThis.fetch = vi.fn(async (_url: any, init: any) => {
      captured = JSON.parse(init.body);
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("tok");
    await client.closeConversation({ conversationId: "215", adminId: "a1", body: "all set" });
    expect(captured.body).toBe("all set");
  });

  it("RealIntercomClient.snoozeConversation POSTs a snoozed part with snoozed_until", async () => {
    let captured: any = null;
    globalThis.fetch = vi.fn(async (_url: any, init: any) => {
      captured = JSON.parse(init.body);
      return new Response("{}", { status: 200 });
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("tok");
    await client.snoozeConversation({ conversationId: "215", adminId: "a1", snoozedUntil: 1780000000 });
    expect(captured).toMatchObject({ message_type: "snoozed", admin_id: "a1", snoozed_until: 1780000000 });
  });

  it("RealIntercomClient.closeConversation throws on a non-ok response", async () => {
    globalThis.fetch = vi.fn(async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;
    const client = new RealIntercomClient("tok");
    await expect(
      client.closeConversation({ conversationId: "c", adminId: "a" }),
    ).rejects.toThrow(/closeConversation failed/);
  });

  it("SanitizingIntercomClient.closeConversation passes through and sanitizes a leaked email in the body", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.closeConversation({ conversationId: "c1", adminId: "a1", body: "reach me at random@gmail.com" });
    expect(inner.calls.closeConversation).toHaveLength(1);
    expect(inner.calls.closeConversation[0].body).not.toContain("random@gmail.com");
  });

  it("SanitizingIntercomClient.snoozeConversation passes through to the inner client", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.snoozeConversation({ conversationId: "c1", adminId: "a1", snoozedUntil: 5 });
    expect(inner.calls.snoozeConversation).toHaveLength(1);
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

describe("SanitizingIntercomClient", () => {
  it("passes a clean body through unchanged and emits no log", async () => {
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, {
      error: (msg) => logged.push(msg),
    });
    await client.replyToConversation({
      conversationId: "conv_1",
      adminId: "admin_1",
      body: "Email support@muso.ai for help.",
    });
    expect(inner.calls.replyToConversation).toHaveLength(1);
    expect(inner.calls.replyToConversation[0].body).toBe("Email support@muso.ai for help.");
    expect(logged).toEqual([]);
  });

  it("sanitizes a body containing a disallowed email before delegating", async () => {
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, {
      error: (msg) => logged.push(msg),
    });
    await client.replyToConversation({
      conversationId: "conv_42",
      adminId: "admin_1",
      body: "Please email nick@muso.ai for help.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("Please email support@muso.ai for help.");
    expect(logged).toHaveLength(1);
    expect(logged[0]).toContain("[intercom:email-leak]");
    expect(logged[0]).toContain("conv=conv_42");
    expect(logged[0]).toContain("count=1");
    expect(logged[0]).toContain('"nick@muso.ai"');
  });

  it("works without a logger (silent redaction)", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.replyToConversation({
      conversationId: "c1",
      adminId: "a1",
      body: "Contact nick@muso.ai please.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("Contact support@muso.ai please.");
  });

  it("does not log when logger has no error method", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, {});
    await client.replyToConversation({
      conversationId: "c1",
      adminId: "a1",
      body: "Contact nick@muso.ai please.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("Contact support@muso.ai please.");
  });

  it("returns the inner client's messageId unchanged", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    const first = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "hi" });
    const second = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "hi" });
    expect(inner.calls.replyToConversation).toHaveLength(2);
    expect(first.messageId).toBe("mock_msg_1");
    expect(second.messageId).toBe("mock_msg_2");
  });

  it("passes assignConversation through unmodified", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.assignConversation({
      conversationId: "c1",
      adminId: "a1",
      assigneeId: "a2",
    });
    expect(inner.calls.assignConversation).toHaveLength(1);
    expect(inner.calls.assignConversation[0]).toEqual({
      conversationId: "c1",
      adminId: "a1",
      assigneeId: "a2",
    });
  });

  it("passes getConversation through unmodified", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    const result = await client.getConversation({ conversationId: "c1" });
    expect(inner.calls.getConversation).toHaveLength(1);
    expect(result.id).toBe("c1");
  });

  it("propagates errors from the inner client", async () => {
    const inner = new MockIntercomClient();
    inner.replyToConversation = async () => {
      throw new Error("network down");
    };
    const client = new SanitizingIntercomClient(inner);
    await expect(
      client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "hi" }),
    ).rejects.toThrow("network down");
  });

  it("emits the leak log BEFORE calling the inner client (observable even if inner throws)", async () => {
    const events: string[] = [];
    const inner: IntercomClient = {
      replyToConversation: async () => {
        events.push("inner");
        throw new Error("net");
      },
      assignConversation: async () => {},
      getConversation: async () => ({} as IntercomConversation),
    };
    const client = new SanitizingIntercomClient(inner, {
      error: (m) => events.push(`log:${m.slice(0, 25)}`),
    });
    await expect(
      client.replyToConversation({ conversationId: "c", adminId: "a", body: "ping nick@muso.ai" }),
    ).rejects.toThrow("net");
    expect(events[0]).toMatch(/^log:/);
    expect(events[1]).toBe("inner");
  });

  it("does not mutate the caller's params object", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    const params = { conversationId: "c1", adminId: "a1", body: "contact nick@muso.ai please." };
    const snapshot = { ...params };
    await client.replyToConversation(params);
    expect(params).toEqual(snapshot);
    expect(params.body).toBe("contact nick@muso.ai please.");
    expect(inner.calls.replyToConversation[0].body).toBe("contact support@muso.ai please.");
  });

  it("dedupes repeated redactions in the log line count and array", async () => {
    const logged: string[] = [];
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, {
      error: (m) => logged.push(m),
    });
    // Markdown-style email link: same address appears twice in the body.
    await client.replyToConversation({
      conversationId: "c42",
      adminId: "a1",
      body: "See [nick@muso.ai](mailto:nick@muso.ai) for details.",
    });
    expect(logged).toHaveLength(1);
    expect(logged[0]).toContain("count=1");
    expect(logged[0]).toContain('["nick@muso.ai"]');
  });

  it("never drops the reply if the logger itself throws", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, {
      error: () => {
        throw new Error("logger broken");
      },
    });
    await client.replyToConversation({
      conversationId: "c",
      adminId: "a",
      body: "contact nick@muso.ai",
    });
    // The inner client got the sanitized body even though the logger threw.
    expect(inner.calls.replyToConversation).toHaveLength(1);
    expect(inner.calls.replyToConversation[0].body).toBe("contact support@muso.ai");
  });

  it("scrubs tool-leak tokens via SanitizingIntercomClient", async () => {
    const inner = new MockIntercomClient();
    const log = { error: vi.fn() };
    const client = new SanitizingIntercomClient(inner, log);
    await client.replyToConversation({
      conversationId: "c1",
      adminId: "a",
      body: "Let me call profile_status — actually I'll just check.",
    });
    expect(inner.calls.replyToConversation[0].body).not.toContain("profile_status");
    expect(inner.calls.replyToConversation[0].body).toContain("[REDACTED]");
    expect(log.error).toHaveBeenCalledWith(expect.stringContaining("[intercom:tool-leak]"));
  });

  it("scrubs both email AND tool-leak in one body", async () => {
    const inner = new MockIntercomClient();
    const log = { error: vi.fn() };
    const client = new SanitizingIntercomClient(inner, log);
    await client.replyToConversation({
      conversationId: "c1",
      adminId: "a",
      body: "Email nick@example.com or call profile_lookup directly.",
    });
    const body = inner.calls.replyToConversation[0].body;
    expect(body).not.toMatch(/nick@example\.com|profile_lookup/);
    const lines = (log.error.mock.calls as any[]).map((c) => c[0] as string);
    expect(lines.some((l) => l.includes("[intercom:email-leak]"))).toBe(true);
    expect(lines.some((l) => l.includes("[intercom:tool-leak]"))).toBe(true);
  });
});

describe("createIntercomClient", () => {
  it("returns a SanitizingIntercomClient wrapping a RealIntercomClient", () => {
    const client = createIntercomClient("test_token");
    expect(client).toBeInstanceOf(SanitizingIntercomClient);
  });

  it("forwards log to the wrapper", async () => {
    const logged: string[] = [];
    const inner = new MockIntercomClient();
    const c = new SanitizingIntercomClient(inner, { error: (m) => logged.push(m) });
    await c.replyToConversation({ conversationId: "c1", adminId: "a1", body: "contact nick@muso.ai" });
    expect(logged).toHaveLength(1);
  });
});

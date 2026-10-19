import { describe, it, expect, vi, afterEach } from "vitest";
import {
  MockIntercomClient,
  RealIntercomClient,
  trackOutboundMessageId,
  SanitizingIntercomClient,
  createIntercomClient,
  sendReplyWithRetry,
  computeReplyBackoffMs,
  isRetryableReplyError,
  RateLimitError,
  IntercomServerError,
  REPLY_MAX_RETRIES,
  REPLY_MAX_BACKOFF_MS,
  REPLY_BASE_BACKOFF_MS,
  REPLY_MAX_TOTAL_WAIT_MS,
} from "../src/outbound.js";
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

  it("normalizes em-dashes to en-dashes on the universal reply chokepoint", async () => {
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, {
      error: (msg) => logged.push(msg),
    });
    await client.replyToConversation({
      conversationId: "conv_em",
      adminId: "admin_1",
      body: "Happy to help — your plan renews on the 1st.",
    });
    // Proves the typography pass fires at the one seam every reply path goes through.
    expect(inner.calls.replyToConversation[0].body).toBe("Happy to help – your plan renews on the 1st.");
    expect(inner.calls.replyToConversation[0].body).not.toContain("—");
    expect(logged.some((m) => m.includes("[intercom:typography]") && m.includes("conv=conv_em"))).toBe(true);
  });

  it("emits the typography line in the exact shape fetch-audit.sh parses", async () => {
    // CONSUMER CONTRACT. This line is not just a log: the Caroline weekly review
    // reads it to tell Caroline's OWN em-dash usage apart from this sanitizer's
    // rewrites. Because the swap is guaranteed, a scan of SENT bodies sees only
    // en-dashes, so without this count the review grades our guardrail instead of
    // the agent -- which is exactly what produced a false "6 en-dash voice tells"
    // finding and the SOUL.md rewrite in PR #892.
    //
    // Consumers (keep in lockstep if this format changes):
    //   workspaces/operations/skills/muso-caroline-weekly-review/scripts/fetch-audit.sh
    //     greps /intercom:typography/ then `conv=[0-9]+` and `count=[0-9]+`
    //   .../scripts/scan-voice.sh  subtracts that count per conversation
    //
    // A shape change here degrades that measurement SILENTLY: zero parsed rows on
    // a readable journal renders as "measured zero rewrites", not "unavailable".
    //
    // This drives the REAL client and parses what it actually logged. Asserting
    // on a locally-built template string instead would be a tautology: it can
    // never fail when outbound.ts changes the format, which is the only event
    // this test exists to catch.
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, {
      error: (msg) => logged.push(msg),
    });
    const conversationId = "12345"; // real Intercom ids are numeric; conv=[0-9]+ relies on it
    await client.replyToConversation({
      conversationId,
      adminId: "admin_1",
      body: "one — two — three — four", // three em-dashes -> count=3
    });

    const line = logged.find((m) => /intercom:typography/.test(m));
    expect(line).toBeDefined();
    // Exactly the three greps fetch-audit.sh step 1c runs over the journal.
    expect(line!.match(/conv=([0-9]+)/)?.[1]).toBe(conversationId);
    expect(line!.match(/count=([0-9]+)/)?.[1]).toBe("3");
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

  it("rewrites a false handoff claim to the honest fallback when no ticket was filed", async () => {
    const SIGNAL_KEY = "__musoSupportTicketSignal";
    delete (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (msg) => logged.push(msg) });
    await client.replyToConversation({
      conversationId: "conv_hc1",
      adminId: "admin_1",
      body: "I've flagged this for our team.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("I'll make sure this gets to the team.");
    expect(logged.some((m) => m.includes("[intercom:false-handoff-claim]") && m.includes("conv=conv_hc1") && m.includes("count=1"))).toBe(true);
  });

  it("passes the same handoff claim through when a ticket WAS filed this conversation", async () => {
    const SIGNAL_KEY = "__musoSupportTicketSignal";
    const g = globalThis as unknown as Record<string, unknown>;
    const store = new Map<string, number>();
    store.set("conv_hc2", Date.now()); // simulate a fresh support-tools create_ticket success
    g[SIGNAL_KEY] = store;
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (msg) => logged.push(msg) });
    await client.replyToConversation({
      conversationId: "conv_hc2",
      adminId: "admin_1",
      body: "I've flagged this for our team.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("I've flagged this for our team.");
    expect(logged.some((m) => m.includes("[intercom:false-handoff-claim]"))).toBe(false);
    delete g[SIGNAL_KEY];
  });

  // MUS-1516: end-to-end wiring of the new filed-id store through outbound.ts into
  // sanitizeHandoffClaim's `filedTicketIds` option. The unit tests in
  // sanitize-handoff-claim.test.ts cover the guard logic itself; these confirm
  // outbound.ts actually reads plugins/intercom/src/ticket-success-signal.ts's new
  // getFiledTicketIds and passes it through.
  it("redacts a reference number this conversation never filed (no ids store at all)", async () => {
    const IDS_KEY = "__musoSupportTicketIds";
    delete (globalThis as unknown as Record<string, unknown>)[IDS_KEY];
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (msg) => logged.push(msg) });
    await client.replyToConversation({
      conversationId: "conv_ref1",
      adminId: "admin_1",
      body: "Your reference number is 869f7v9v2.",
    });
    expect(inner.calls.replyToConversation[0].body).toBe("I'll make sure this gets to the team.");
    expect(logged.some((m) => m.includes("[intercom:false-handoff-claim]") && m.includes("conv=conv_ref1"))).toBe(true);
  });

  it("passes through a reference number that WAS filed in this conversation", async () => {
    const IDS_KEY = "__musoSupportTicketIds";
    const g = globalThis as unknown as Record<string, unknown>;
    const store = new Map<string, { atMs: number; ids: string[] }>();
    store.set("conv_ref2", { atMs: Date.now(), ids: ["869f7v9v2"] });
    g[IDS_KEY] = store;
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (msg) => logged.push(msg) });
    await client.replyToConversation({
      conversationId: "conv_ref2",
      adminId: "admin_1",
      body: "Your reference number is 869f7v9v2.",
    });
    // Filed, so the handoff guard keeps it; the internal-reference backstop then rewrites it.
    expect(inner.calls.replyToConversation[0].body).toBe("Your reference number is our records.");
    expect(logged.some((m) => m.includes("[intercom:false-handoff-claim]"))).toBe(false);
    delete g[IDS_KEY];
  });

  // Nick, 13 Oct: no internal id ever reaches a customer, even one this conversation
  // filed. The handoff guard lets filed ids through, so the internal-reference pass
  // runs after it as the backstop and rewrites them (sanitize-internal-reference.ts).
  // It must run AFTER the handoff guard, or an unfiled 86… id is garbled to "our records"
  // before the guard can replace the false claim with the honest fallback.
  it("rewrites a ClickUp-shaped id even when this conversation filed it", async () => {
    const IDS_KEY = "__musoSupportTicketIds";
    const g = globalThis as unknown as Record<string, unknown>;
    const store = new Map<string, { atMs: number; ids: string[] }>();
    store.set("conv_ref3", { atMs: Date.now(), ids: ["869fep919"] });
    g[IDS_KEY] = store;
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, { error: () => {} });
    await client.replyToConversation({
      conversationId: "conv_ref3",
      adminId: "admin_1",
      body: "Your reference number is 869fep919.",
    });
    expect(inner.calls.replyToConversation[0].body).not.toContain("869fep919");
    delete g[IDS_KEY];
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

describe("listContactConversations (prior-chat recall)", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  const SEARCH_RESULT = {
    type: "conversation.list",
    total_count: 2,
    conversations: [
      {
        type: "conversation",
        id: "conv_old",
        title: "Analytics question",
        state: "closed",
        updated_at: 1764576000, // 2025-12-01
        source: { body: "<p>my analytics are not updating</p>", author: { type: "user", id: "u1" } },
      },
      {
        type: "conversation",
        id: "conv_new",
        title: null,
        state: "open",
        updated_at: 1767168000, // 2025-12-31
        source: { body: "<p>question about my latest release</p>", author: { type: "user", id: "u1" } },
      },
    ],
  };

  it("POSTs /conversations/search filtered by contact_ids with the Accept header (406 guard)", async () => {
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify(SEARCH_RESULT), { status: 200 }));
    globalThis.fetch = fetchSpy as any;
    const client = new RealIntercomClient("tok");
    await client.listContactConversations({ contactId: "u1" });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const [url, init] = fetchSpy.mock.calls[0] as any[];
    expect(url).toBe("https://api.intercom.io/conversations/search");
    expect(init.method).toBe("POST");
    // Without Accept: application/json the search endpoint returns 406.
    expect(init.headers.Accept).toBe("application/json");
    expect(init.headers["Intercom-Version"]).toBe("2.11");
    const body = JSON.parse(init.body);
    // = (list-membership), NOT ~ (contains): ~ on contact_ids returns 0 for
    // every contact on the live API (verified 2026-06-11) and silently killed
    // prior-chat recall in prod.
    expect(body.query).toEqual({ field: "contact_ids", operator: "=", value: "u1" });
    expect(body.pagination).toEqual({ per_page: 5 });
  });

  it("excludes the current conversation server-side via a compound query", async () => {
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify(SEARCH_RESULT), { status: 200 }));
    globalThis.fetch = fetchSpy as any;
    const client = new RealIntercomClient("tok");
    await client.listContactConversations({ contactId: "u1", excludeConversationId: "conv_now" });

    const body = JSON.parse((fetchSpy.mock.calls[0] as any[])[1].body);
    expect(body.query).toEqual({
      operator: "AND",
      value: [
        { field: "contact_ids", operator: "=", value: "u1" },
        { field: "id", operator: "!=", value: "conv_now" },
      ],
    });
  });

  it("includes multi-contact / admin-initiated conversations the contact participated in", async () => {
    // Regression: rows where someone else authored the source message (e.g.
    // an outbound admin message or a second participant) must still count —
    // the contact_ids ~ query matches participation, and the mapper must not
    // re-filter by author.
    const MULTI_CONTACT_RESULT = {
      type: "conversation.list",
      total_count: 1,
      conversations: [
        {
          type: "conversation",
          id: "conv_outbound",
          title: "Checking in on your claim",
          state: "closed",
          updated_at: 1764576000,
          source: { body: "<p>following up on your profile claim</p>", author: { type: "admin", id: "admin_9" } },
        },
      ],
    };
    globalThis.fetch = vi.fn(async () => new Response(JSON.stringify(MULTI_CONTACT_RESULT), { status: 200 })) as any;
    const client = new RealIntercomClient("tok");
    const out = await client.listContactConversations({ contactId: "u1" });
    expect(out.totalCount).toBe(1);
    expect(out.conversations).toHaveLength(1);
    expect(out.conversations[0].id).toBe("conv_outbound");
  });

  it("uses the provided timeoutMs for the abort signal (defaults to 5000)", async () => {
    const timeoutSpy = vi.spyOn(AbortSignal, "timeout");
    globalThis.fetch = vi.fn(async () => new Response(JSON.stringify(SEARCH_RESULT), { status: 200 })) as any;
    const client = new RealIntercomClient("tok");
    await client.listContactConversations({ contactId: "u1", timeoutMs: 800 });
    expect(timeoutSpy).toHaveBeenLastCalledWith(800);
    await client.listContactConversations({ contactId: "u1" });
    expect(timeoutSpy).toHaveBeenLastCalledWith(5000);
    timeoutSpy.mockRestore();
  });

  it("maps results to summaries sorted by updated_at desc, with HTML-stripped snippets — no per-conversation GETs", async () => {
    const fetchSpy = vi.fn(async () => new Response(JSON.stringify(SEARCH_RESULT), { status: 200 }));
    globalThis.fetch = fetchSpy as any;
    const client = new RealIntercomClient("tok");
    const { conversations: out, totalCount } = await client.listContactConversations({ contactId: "u1" });

    expect(fetchSpy).toHaveBeenCalledTimes(1); // single round-trip
    expect(totalCount).toBe(2);
    expect(out).toHaveLength(2);
    expect(out[0].id).toBe("conv_new"); // most recent first
    expect(out[0].title).toBeNull();
    expect(out[0].snippet).toBe("question about my latest release"); // tags stripped
    expect(out[1].id).toBe("conv_old");
    expect(out[1].title).toBe("Analytics question");
    expect(out[1].state).toBe("closed");
    expect(typeof out[0].updatedAt).toBe("string"); // ISO, not epoch
    expect(out[0].updatedAt.startsWith("2025-12-31")).toBe(true);
  });

  it("carries total_count through even when it exceeds the fetched page", async () => {
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ ...SEARCH_RESULT, total_count: 12 }), { status: 200 }),
    ) as any;
    const client = new RealIntercomClient("tok");
    const out = await client.listContactConversations({ contactId: "u1", limit: 2 });
    expect(out.conversations).toHaveLength(2);
    expect(out.totalCount).toBe(12);
  });

  it("returns an empty page on an empty result", async () => {
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ type: "conversation.list", total_count: 0, conversations: [] }), { status: 200 }),
    ) as any;
    const client = new RealIntercomClient("tok");
    expect(await client.listContactConversations({ contactId: "u1" })).toEqual({ conversations: [], totalCount: 0 });
  });

  it("throws RateLimitError on 429", async () => {
    globalThis.fetch = vi.fn(async () =>
      new Response("{}", { status: 429, headers: { "Retry-After": "7" } }),
    ) as any;
    const client = new RealIntercomClient("tok");
    await expect(client.listContactConversations({ contactId: "u1" })).rejects.toMatchObject({
      name: "RateLimitError",
      retryAfterSeconds: 7,
    });
  });

  it("MockIntercomClient records the call and returns an empty page", async () => {
    const client = new MockIntercomClient();
    const out = await client.listContactConversations({ contactId: "u1" });
    expect(out).toEqual({ conversations: [], totalCount: 0 });
    expect(client.calls.listContactConversations).toHaveLength(1);
  });

  it("SanitizingIntercomClient passes through (read-only path)", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.listContactConversations({ contactId: "u1" });
    expect(inner.calls.listContactConversations).toHaveLength(1);
  });
});

describe("isRetryableReplyError", () => {
  it("treats 429 (RateLimitError) and 5xx (IntercomServerError) as retryable", () => {
    expect(isRetryableReplyError(new RateLimitError(3))).toBe(true);
    expect(isRetryableReplyError(new IntercomServerError(503, "boom"))).toBe(true);
  });

  it("does NOT retry plain errors (4xx like 404 / permission)", () => {
    expect(isRetryableReplyError(new Error("404 not found"))).toBe(false);
    expect(isRetryableReplyError(new Error("403 forbidden"))).toBe(false);
    expect(isRetryableReplyError("oops")).toBe(false);
  });
});

describe("computeReplyBackoffMs", () => {
  it("honors Retry-After as a FLOOR for 429: never sleeps less than the server-directed wait, jitter added on top", () => {
    // Retry-After is a server directive, not a hint. Retrying before the
    // window clears just earns another 429 and burns a retry, dropping the
    // reply early — so the wait MUST be >= retryAfter*1000. The old code used
    // Retry-After as the jitter CEILING (rand=0 → 0ms wait), which this test
    // now forbids: that was the regression that defeated the whole retry path.
    // rand=0 → exactly the floor, never below it.
    expect(computeReplyBackoffMs(1, new RateLimitError(2), () => 0)).toBe(2000);
    // rand→max → floor + full additive jitter (REPLY_BASE_BACKOFF_MS), still ≤ cap.
    expect(computeReplyBackoffMs(1, new RateLimitError(2), () => 1)).toBe(2000 + REPLY_BASE_BACKOFF_MS);
  });

  it("uses capped exponential backoff for 5xx", () => {
    const err = new IntercomServerError(500, "boom");
    // base=500, attempt 1 → 500, attempt 2 → 1000, attempt 3 → 2000 (rand=1 = full)
    expect(computeReplyBackoffMs(1, err, () => 1)).toBe(500);
    expect(computeReplyBackoffMs(2, err, () => 1)).toBe(1000);
    expect(computeReplyBackoffMs(3, err, () => 1)).toBe(2000);
  });

  it("caps 5xx exponential backoff at the per-attempt cap, but bounds 429 Retry-After by the TOTAL budget", () => {
    // 5xx exponential backoff is OUR choice (not a server directive), so the
    // tight per-attempt cap (8s) applies.
    const err = new IntercomServerError(500, "boom");
    expect(computeReplyBackoffMs(20, err, () => 1)).toBe(REPLY_MAX_BACKOFF_MS);
    // 429: the 8s per-attempt cap must NOT clip a server-directed Retry-After
    // that still fits inside the total budget. A Retry-After between the
    // per-attempt cap (8s) and the total budget (30s) is honored IN FULL —
    // clipping it to 8s is the residual bug that retried ~22s early and burned
    // the budget before the server's window cleared.
    expect(computeReplyBackoffMs(1, new RateLimitError(12), () => 0)).toBe(12_000);
    // A Retry-After larger than the whole budget is clamped to the budget
    // (sendReplyWithRetry then further clamps by the budget actually remaining).
    expect(computeReplyBackoffMs(1, new RateLimitError(9999), () => 1)).toBe(REPLY_MAX_TOTAL_WAIT_MS);
  });
});

describe("sendReplyWithRetry", () => {
  const noSleep = async () => {};

  it("returns immediately on first success (no retries, no alert)", async () => {
    const attempt = vi.fn(async () => ({ messageId: "m1" }));
    const onAlert = vi.fn();
    const out = await sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, onAlert });
    expect(out).toEqual({ messageId: "m1" });
    expect(attempt).toHaveBeenCalledTimes(1);
    expect(onAlert).not.toHaveBeenCalled();
  });

  it("retries on 429 then succeeds", async () => {
    let n = 0;
    const attempt = vi.fn(async () => {
      n++;
      if (n < 3) throw new RateLimitError(1);
      return { messageId: "ok" };
    });
    const onAlert = vi.fn();
    const out = await sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, rand: () => 0.5, onAlert });
    expect(out).toEqual({ messageId: "ok" });
    expect(attempt).toHaveBeenCalledTimes(3);
    expect(onAlert).not.toHaveBeenCalled();
  });

  it("retries on 5xx then succeeds", async () => {
    let n = 0;
    const attempt = vi.fn(async () => {
      n++;
      if (n < 2) throw new IntercomServerError(502, "bad gateway");
      return { messageId: "ok" };
    });
    const out = await sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, rand: () => 0.5 });
    expect(out).toEqual({ messageId: "ok" });
    expect(attempt).toHaveBeenCalledTimes(2);
  });

  it("does NOT retry a 4xx (plain Error) — fails on first attempt, no alert", async () => {
    const attempt = vi.fn(async () => { throw new Error("404 not found"); });
    const onAlert = vi.fn();
    await expect(
      sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, onAlert }),
    ).rejects.toThrow("404 not found");
    expect(attempt).toHaveBeenCalledTimes(1);
    // Non-retryable failures are surfaced to the caller's own catch; the
    // "dropped after retries" alert is reserved for exhausted retryable errors.
    expect(onAlert).not.toHaveBeenCalled();
  });

  it("emits a grep-able alert and rethrows after exhausting retries on persistent 429", async () => {
    const attempt = vi.fn(async () => { throw new RateLimitError(1); });
    const onAlert = vi.fn();
    await expect(
      sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, rand: () => 0.5, onAlert }),
    ).rejects.toBeInstanceOf(RateLimitError);
    // First attempt + REPLY_MAX_RETRIES retries.
    expect(attempt).toHaveBeenCalledTimes(REPLY_MAX_RETRIES + 1);
    expect(onAlert).toHaveBeenCalledTimes(1);
    expect(onAlert.mock.calls[0][0]).toContain("[intercom:ALERT] reply dropped after retries");
    expect(onAlert.mock.calls[0][0]).toContain("conv=c1");
  });

  it("does NOT alert when a later attempt fails with a non-retryable error after a transient 429", async () => {
    // Transient 429 (retryable) on attempt 1, then a deterministic 404 (plain
    // Error, non-retryable) on attempt 2. attempts > 1, but the TERMINAL error
    // is deterministic — firing "reply dropped after retries" here would
    // mislabel a config bug as transient retry-exhaustion. The 404 still
    // rethrows to the caller's own error handling.
    let n = 0;
    const attempt = vi.fn(async () => {
      n++;
      if (n === 1) throw new RateLimitError(1);
      throw new Error("404 not found");
    });
    const onAlert = vi.fn();
    await expect(
      sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn: noSleep, rand: () => 0, onAlert }),
    ).rejects.toThrow("404 not found");
    expect(attempt).toHaveBeenCalledTimes(2);
    expect(onAlert).not.toHaveBeenCalled();
  });

  it("stops retrying once the cumulative wait budget is exhausted", async () => {
    const attempt = vi.fn(async () => { throw new IntercomServerError(500, "boom"); });
    const sleepFn = vi.fn(noSleep);
    await expect(
      sendReplyWithRetry(attempt, { conversationId: "c1" }, {
        sleepFn,
        rand: () => 1, // full ceiling each time
        maxTotalWaitMs: 600, // only enough for the first 500ms backoff
        onAlert: () => {},
      }),
    ).rejects.toBeInstanceOf(IntercomServerError);
    // attempt 1 fails → sleep 500ms (budget 600 ok); attempt 2 fails → next
    // backoff 1000ms would exceed remaining 100ms budget → clamp to 100 then
    // remaining budget 0 → stop. So 1 real sleep, then a clamped sleep, then halt.
    expect(sleepFn.mock.calls.length).toBeLessThanOrEqual(REPLY_MAX_RETRIES);
    // Did not run the full retry count because the budget cut it short.
    expect(attempt.mock.calls.length).toBeLessThan(REPLY_MAX_RETRIES + 1);
  });

  it("honors a large 429 Retry-After up to the total budget — does NOT retry early at the 8s per-attempt cap", async () => {
    // Server directs a 30s wait. The retry must sleep the full budget before
    // trying again — NOT 8s (the per-attempt exponential cap), which would
    // retry ~22s early, earn another 429, and drop the reply before the
    // server's window ever cleared. This is the residual blocker QA caught
    // after the first Retry-After fix.
    const attempt = vi.fn(async () => { throw new RateLimitError(30); });
    const sleeps: number[] = [];
    const sleepFn = async (ms: number) => { sleeps.push(ms); };
    await expect(
      sendReplyWithRetry(attempt, { conversationId: "c1" }, { sleepFn, rand: () => 0, onAlert: () => {} }),
    ).rejects.toBeInstanceOf(RateLimitError);
    // Exactly one backoff, sized to the full 30s budget (not clipped to 8s).
    expect(sleeps).toEqual([REPLY_MAX_TOTAL_WAIT_MS]);
    // Initial attempt + one retry, then the budget is exhausted.
    expect(attempt).toHaveBeenCalledTimes(2);
  });
});

describe("RealIntercomClient.replyToConversation retry wiring", () => {
  const originalFetch = globalThis.fetch;
  afterEach(() => {
    vi.useRealTimers();
    globalThis.fetch = originalFetch;
  });

  const okBody = JSON.stringify({
    type: "conversation",
    id: "conv_1",
    conversation_parts: { conversation_parts: [{ type: "conversation_part", id: "part_new" }] },
  });

  it("retries a 429 from the live reply endpoint and ultimately succeeds", async () => {
    vi.useFakeTimers();
    let calls = 0;
    globalThis.fetch = vi.fn(async () => {
      calls++;
      if (calls === 1) return new Response("rate limited", { status: 429, headers: { "Retry-After": "1" } });
      return new Response(okBody, { status: 200, headers: { "Content-Type": "application/json" } });
    }) as unknown as typeof fetch;

    const client = new RealIntercomClient("tok");
    const p = client.replyToConversation({ conversationId: "conv_1", adminId: "a1", body: "hi" });
    // Drive the in-process backoff sleep to completion.
    await vi.runAllTimersAsync();
    const result = await p;
    expect(result.messageId).toBe("part_new");
    expect(calls).toBe(2);
  });

  it("does NOT retry a 404 from the live reply endpoint (fails fast)", async () => {
    const fetchSpy = vi.fn(async () => new Response("not found", { status: 404 }));
    globalThis.fetch = fetchSpy as unknown as typeof fetch;

    const client = new RealIntercomClient("tok");
    await expect(
      client.replyToConversation({ conversationId: "conv_1", adminId: "a1", body: "hi" }),
    ).rejects.toThrow(/replyToConversation failed: 404/);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});

describe("SanitizingIntercomClient help-centre link gate", () => {
  const GOOD = "https://help.muso.ai/en/articles/1111111-claim";
  const manifest = { articles: { "1111111": { slug: "claim", title: "Claim", url: GOOD } } };
  const send = async (body: string, loader: () => any, errors: string[] = []) => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, { error: (m) => errors.push(m) }, loader);
    await client.replyToConversation({ conversationId: "c1", adminId: "a1", body });
    return inner.calls.replyToConversation[0].body;
  };

  it("delivers a manifest-valid citation unchanged", async () => {
    const body = `Answer.\nMore detail here: ${GOOD}`;
    expect(await send(body, () => manifest)).toBe(body);
  });
  it("does not log a valid citation as an error", async () => {
    const errors: string[] = [];
    await send(`Answer.\nMore detail here: ${GOOD}`, () => manifest, errors);
    expect(errors).toEqual([]);
  });
  it.each([
    ["unlisted citation only", "More detail here: https://help.muso.ai/en/articles/9-fake", () => manifest],
    ["valid citation, manifest unavailable", `More detail here: ${GOOD}`, () => null],
  ])("posts nothing when the gate leaves an empty reply: %s", async (_n, body, loader) => {
    const inner = new MockIntercomClient();
    const errors: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (m: string) => { errors.push(m); } }, loader as any);
    const res = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body });
    expect(inner.calls.replyToConversation).toHaveLength(0);
    expect(res.messageId).toBe("");
    expect(res.dropped).toBe(true);
    // Ops alert on the [intercom:ALERT] prefix (channel.ts); nothing else pages a dropped reply.
    expect(errors.some((m) => m.startsWith("[intercom:ALERT] [intercom:empty-after-sanitize] conv=c1 posting nothing"))).toBe(true);
  });
  it.each([
    ["unlisted citation only", "More detail here: https://help.muso.ai/en/articles/9-fake", () => manifest],
    ["valid citation, manifest unavailable", `More detail here: ${GOOD}`, () => null],
  ])("does not close when the gate empties a close note: %s", async (_n, body, loader) => {
    const inner = new MockIntercomClient();
    const errors: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (m: string) => { errors.push(m); } }, loader as any);
    await client.closeConversation({ conversationId: "c1", adminId: "a1", body });
    expect(inner.calls.closeConversation).toHaveLength(0);
    expect(errors).toContain("[intercom:ALERT] [intercom:empty-after-sanitize] conv=c1 close suppressed — note emptied by help-link gate, conversation left open for a human");
  });
  it("leaves dropped undefined for a delivered reply", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner, { error: () => {} } as any, () => manifest as any);
    const res = await client.replyToConversation({ conversationId: "c1", adminId: "a1", body: "Hello there." });
    expect(inner.calls.replyToConversation).toHaveLength(1);
    expect(res.dropped).toBeUndefined();
  });
  it("strips an invented link and logs internally only", async () => {
    const errors: string[] = [];
    const out = await send("Answer.\nMore detail here: https://help.muso.ai/en/articles/99-x", () => manifest, errors);
    expect(out).toBe("Answer.");
    expect(errors.join()).toContain("[intercom:help-link]");
  });
  it("strips an invented link written with an explicit :443 port", async () => {
    const out = await send("Answer.\nMore detail here: https://help.muso.ai:443/en/articles/9999999-invented", () => manifest);
    expect(out).toBe("Answer.");
  });
  it("strips an invented link whose anchor href carries a tab inside the path", async () => {
    const out = await send('Answer.\n<a href="https://help.muso.ai/en/ar\tticles/9999999-invented">guide</a>', () => manifest);
    expect(out).toBe("Answer.");
  });
  it("strips a line-split invented link that sits next to a valid citation", async () => {
    const valid = `More detail here: ${GOOD}`;
    const out = await send(`Answer.\n${valid}\n<a href="https://help.muso.ai/en/ar\narticles/9999999-invented">x</a>`, () => manifest);
    expect(out).not.toContain("9999999");
    expect(out).toContain(valid);
  });
  it.each([
    ["scheme-less LF split", "See help.muso.ai/en/ar\nticles/9999999-invented for details"],
    ["3-part LF split", "See https://help.muso.ai/en/\nar\nticles/9999999-invented ok"],
    ["CRLF split", "See https://help.muso.ai/en/ar\r\nticles/9999999-invented"],
    ["raw tab", "See https://help.muso.ai/en/art\ticles/9999999-invented"],
    ["&NewLine; entity", '<a href="https://help.muso.ai/en/ar&NewLine;ticles/9999999-invented">x</a>'],
    ["%09", "See https://help.muso.ai/en/ar%09ticles/9999999-invented"],
    ["%0a", "See https://help.muso.ai/en/ar%0aticles/9999999-invented"],
  ])("variant table through the client: %s never reaches the customer", async (_n, tail) => {
    const out = await send(`Answer.\n${tail}`, () => manifest);
    expect(out).not.toContain("9999999");
    expect(out).toContain("Answer.");
  });
  it("strips an invented link written with a percent-encoded path", async () => {
    const out = await send("Answer.\nMore detail here: https://help.muso.ai/en/%61rticles/9999999-invented", () => manifest);
    expect(out).toBe("Answer.");
  });
  it("strips an invented link whose host is HTML-entity encoded in an anchor and logs it", async () => {
    const errors: string[] = [];
    const out = await send('Answer.\n<a href="https://help&#46;muso.ai/en/articles/9999999-invented">guide</a>', () => manifest, errors);
    expect(out).not.toContain("9999999");
    expect(out).toContain("Answer.");
    expect(errors.join()).toContain("[intercom:help-link]");
  });
  it("fails closed when the manifest is unavailable, customer sees no trace", async () => {
    const errors: string[] = [];
    const out = await send(`Answer.\nMore detail here: ${GOOD}`, () => null, errors);
    expect(out).toBe("Answer.");
    expect(errors.join()).toContain("manifest=unavailable");
  });
  it("never loads the manifest for a reply with no article URL", async () => {
    let loads = 0;
    await send("Plain, see help.muso.ai.", () => { loads++; return null; });
    expect(loads).toBe(0);
  });
});

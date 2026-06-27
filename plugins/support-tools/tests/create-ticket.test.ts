import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreateTicketTool, teamOptionFor } from "../src/tools/create-ticket.js";
import { intercomDeeplink } from "../src/tools/ticket-format.js";
import { SessionTicketRegistry } from "../src/session-ticket-registry.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("createCreateTicketTool", () => {
  let mockClient: HttpClient;
  let limiter: RateLimiter;

  beforeEach(() => { mockClient = { get: vi.fn(), post: vi.fn() }; limiter = new RateLimiter(); });

  it("creates a ClickUp task with correct structure", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_abc123" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Customer wants Producer credit on Track X", conversationSummary: "Customer asked about missing credit." });
    expect(mockClient.post).toHaveBeenCalledWith("https://api.clickup.com/api/v2/list/901000600160/task", { headers: { Authorization: "pk_test" }, body: expect.objectContaining({ name: "[credit-claim] Customer wants Producer credit on Track X — user@example.com", status: "to do", priority: 3, tags: ["hydra-action-request", "tier-1", "action:credit-claim", "team:catalog"], markdown_description: expect.stringContaining("---ACTION-REQUEST---"), custom_fields: [{ id: "field_uuid_2", value: "user@example.com" }] }) });
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed).toEqual({
      submitted: true,
      ticket_id: "task_abc123",
      sla: "2 business days",
      action_type: "credit-claim",
      tier: 1,
    });
  });

  it("includes profile ID custom field when provided", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_def456" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_123",
      summary: "Merge two profiles",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    const fields = body.custom_fields as { id: string; value: string }[];
    expect(fields).toContainEqual({ id: "field_uuid_1", value: "prof_123" });
    expect(body.priority).toBe(2);
    expect(body.tags).toEqual(["hydra-action-request", "tier-2", "action:profile-merge", "team:catalog"]);
  });

  it("stamps a deterministic Prodigi address validation on order-fulfillment tickets", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_order1" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_order" });
    // The garbled address from the Prodigi email: street in the name slot, no phone.
    await tool.execute("call_1", {
      actionType: "order-fulfillment",
      customerEmail: "mary@prodigi.com",
      summary: "Prodigi asked to confirm the shipping address for order 6a468d83",
      details: {
        order_id: "6a468d83-b71d-4720-bb12-79ae8dfa55f8",
        prodigi_order_id: "66812882101295104",
        whats_wrong: "address bounced by Prodigi",
        proposed_corrected_address: {
          name: "av enriqullo Nro 36, los cedrozgos",
          line1: "apto 1101",
          city: "santo domingo",
          postcode: "11108",
          country: "DOMINICAN REPUBLIC",
        },
      },
      conversationSummary: "Vendor requested an address correction for a Dominican Republic order.",
    });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.tags).toEqual(["hydra-action-request", "tier-1", "action:order-fulfillment", "team:growth"]);
    const md = body.markdown_description as string;
    const json = JSON.parse(/---ACTION-REQUEST---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST---/.exec(md)![1]);
    expect(json.details.address_validation.ok).toBe(false);
    expect(json.details.address_validation.missing).toContain("Phone number");
    expect(json.details.address_validation.warnings).toContain("recipient_name_looks_like_a_street_address");
  });

  it("does not add address_validation to non-order tickets", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_plain" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_plain" });
    await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "x", conversationSummary: "y", details: { proposed_corrected_address: { name: "n" } } });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.markdown_description as string).not.toContain("address_validation");
  });

  it("blocks when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 2; i++) { strictLimiter.check("session_abc", "create_ticket", 60, 2); }
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: strictLimiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Test", conversationSummary: "Test." });
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed).toEqual({ submitted: false, reason: "rate_limited" });
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("auto-assigns profile-merge tickets when profileMergeAssigneeId is configured", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_merge1" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc", profileMergeAssigneeId: 12345678 });
    await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "Merge two profiles",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.assignees).toEqual([12345678]);
  });

  it("does NOT auto-assign profile-merge when profileMergeAssigneeId is not configured", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_merge2" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "Merge two profiles",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.assignees).toBeUndefined();
  });

  it("rejects profile-merge missing customerProfileId", async () => {
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com",
      summary: "Merge two profiles",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(false);
    expect(parsed.reason).toBe("profile_merge_capture_incomplete");
    expect(parsed.missing).toContain("customerProfileId");
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("rejects profile-merge missing details.duplicate_profile_urls", async () => {
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "Merge two profiles",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa" },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(false);
    expect(parsed.reason).toBe("profile_merge_capture_incomplete");
    expect(parsed.missing).toContain("details.duplicate_profile_urls");
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("rejects profile-merge missing details.main_profile_url", async () => {
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "Merge two profiles",
      details: { duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(false);
    expect(parsed.reason).toBe("profile_merge_capture_incomplete");
    expect(parsed.missing).toContain("details.main_profile_url");
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("accepts survivor_profile_url as a synonym for details.main_profile_url", async () => {
    // The kept profile is the "survivor" (the name dedupe_check / the
    // consolidate tool use) AND the "main" profile (this ticket's required
    // field) — the same profile. A capture that supplies only survivor_profile_url
    // is complete and must submit on the FIRST attempt, not bounce as
    // capture-incomplete (the original first-call failure on conv
    // 215474855199857, 2026-06-26).
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_synonym" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_syn" });
    const result = await tool.execute("call_1", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "Merge two profiles",
      details: { survivor_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "Customer has duplicate profiles.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(true);
    // The rendered ticket carries the main profile URL, resolved from the survivor.
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.markdown_description).toContain("https://credits.muso.ai/profile/aaa");
  });

  it("validation rejection does NOT consume rate-limit budget", async () => {
    // Per silent-failure review: a malformed profile-merge call must not eat
    // one of the 2-per-60s slots, otherwise the agent's retry-with-fixed-fields
    // gets a misleading rate_limited error.
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_rl" });
    // Fire 3 malformed calls — should all be rejected for incomplete capture,
    // not for rate-limit, because validation runs first.
    for (let i = 0; i < 3; i++) {
      const r = await tool.execute(`call_${i}`, {
        actionType: "profile-merge", customerEmail: "user@example.com",
        summary: "merge", conversationSummary: "duplicate.",
      });
      const parsed = JSON.parse((r.content[0] as { text: string }).text);
      expect(parsed.reason).toBe("profile_merge_capture_incomplete");
    }
    // A well-formed call after 3 rejections should still succeed (budget intact).
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "t_after_retry" } });
    const ok = await tool.execute("call_ok", {
      actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_main",
      summary: "merge",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "duplicate.",
    });
    const parsedOk = JSON.parse((ok.content[0] as { text: string }).text);
    expect(parsedOk.submitted).toBe(true);
  });

  it("does NOT auto-reject other action types for missing profile-merge fields", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_x" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", {
      actionType: "credit-claim", customerEmail: "user@example.com",
      summary: "Add credit", conversationSummary: "Missing producer credit.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(true);
  });

  it("does NOT auto-assign for non-profile-merge action types even when assignee is configured", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_claim1" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc", profileMergeAssigneeId: 12345678 });
    await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Add producer credit", conversationSummary: "Customer requested missing credit." });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.assignees).toBeUndefined();
  });

  it("returns structured queue_busy on ClickUp API failure", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: false, error: "API error", status: 500 });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, sessionTickets: new SessionTicketRegistry(), clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Test", conversationSummary: "Test." });
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed).toEqual({ submitted: false, reason: "queue_busy" });
  });
});

function makeHttp(overrides: Partial<HttpClient> = {}): HttpClient {
  return {
    get: vi.fn(async () => ({ ok: true, data: {} as any })),
    post: vi.fn(async () => ({ ok: true, data: { id: "abc123" } as any })),
    put: vi.fn(async () => ({ ok: true, data: {} as any })),
    ...overrides,
  } as unknown as HttpClient;
}

function makeDeps(overrides: Partial<Parameters<typeof createCreateTicketTool>[0]> = {}) {
  return {
    http: makeHttp(),
    rateLimiter: new RateLimiter(),
    sessionTickets: new SessionTicketRegistry(),
    clickupApiKey: "k",
    clickupListId: "list",
    clickupProfileIdFieldId: "pf",
    clickupUserEmailFieldId: "ef",
    sessionId: "sess-1",
    sessionKey: "agent:support:intercom:direct:conv-1",
    intercomWorkspaceId: "dwjzhcge",
    ...overrides,
  };
}

describe("createCreateTicketTool — structured returns", () => {
  it("returns structured success on ticket creation", async () => {
    const tool = createCreateTicketTool(makeDeps());
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "stuck streams",
      conversationSummary: "customer reports stale dashboard",
    } as any);
    const parsed = JSON.parse((result.content[0] as any).text as string);
    expect(parsed).toEqual({
      submitted: true,
      ticket_id: "abc123",
      sla: "2 business days",
      action_type: "analytics-followup",
      tier: 1,
    });
  });

  it("returns structured queue_busy on ClickUp 5xx", async () => {
    const http = makeHttp({ post: vi.fn(async () => ({ ok: false, status: 503, error: "upstream" } as any)) });
    const tool = createCreateTicketTool(makeDeps({ http }));
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "x",
      conversationSummary: "y",
    } as any);
    const parsed = JSON.parse((result.content[0] as any).text as string);
    expect(parsed).toEqual({ submitted: false, reason: "queue_busy" });
  });

  it("returns structured rate_limited when session cap exceeded", async () => {
    // Distinct action types — same-type repeats are follow-up comments now
    // (see create-ticket-dedupe.test.ts) and have their own budget.
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await tool.execute("c1", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    await tool.execute("c2", { actionType: "credit-claim", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const result = await tool.execute("c3", { actionType: "credit-correction", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const parsed = JSON.parse((result.content[0] as any).text as string);
    expect(parsed).toEqual({ submitted: false, reason: "rate_limited" });
  });

  it("never returns customer-facing English in any path", async () => {
    const deps = makeDeps({ http: makeHttp({ post: vi.fn(async () => ({ ok: false, status: 500, error: "x" } as any)) }) });
    const tool = createCreateTicketTool(deps);
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "s",
      conversationSummary: "c",
    } as any);
    const text = (result.content[0] as any).text as string;
    expect(() => JSON.parse(text)).not.toThrow();
    expect(text).not.toMatch(/ticket|support@muso\.ai|already submitted|Unable/i);
  });

  it("includes analytics-followup in tags passed to ClickUp", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "abc" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }) }));
    await tool.execute("c", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "s",
      conversationSummary: "c",
    } as any);
    const calledBody = (post.mock.calls[0]?.[1] as any)?.body;
    expect(calledBody?.tags).toContain("analytics-followup");
    expect(calledBody?.tags).toContain("hydra-action-request");
    expect(calledBody?.tags).toContain("tier-1");
  });
});

describe("create-ticket enrichment + tier-2 validation", () => {
  // Live runtime session key (per-channel-peer): the segment is the peer-kind
  // (direct/group), with NO workspaceId and NO ":conversation:". The app-id comes
  // from config (makeDeps default "dwjzhcge"), not the key.
  const INTERCOM_SESSION_KEY = "agent:support:intercom:direct:215473921553266";
  const CONV_ID = "215473921553266";

  it("sets the Intercom Link field from the session key (convId) + the configured app-id", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }), sessionKey: INTERCOM_SESSION_KEY, intercomWorkspaceId: "dwjzhcge", clickupIntercomLinkFieldId: "il" }));
    await tool.execute("c", { actionType: "credit-claim", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const fields = (post.mock.calls[0][1] as any).body.custom_fields as { id: string; value: string }[];
    expect(fields).toContainEqual({ id: "il", value: intercomDeeplink("dwjzhcge", CONV_ID) });
  });

  it("omits the Intercom Link for a non-Intercom / unparseable session key and still files the ticket", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }), sessionKey: "unknown", clickupIntercomLinkFieldId: "il" }));
    const res = await tool.execute("c", { actionType: "credit-claim", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const fields = (post.mock.calls[0][1] as any).body.custom_fields as { id: string; value: string }[];
    expect(fields.find((f) => f.id === "il")).toBeUndefined();
    expect(JSON.parse((res.content[0] as any).text).submitted).toBe(true);
  });

  it("sets the Muso URL field from the profile id when configured", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }), clickupMusoUrlFieldId: "mu" }));
    await tool.execute("c", { actionType: "credit-claim", customerEmail: "u@example.com", customerProfileId: "abc123", summary: "s", conversationSummary: "c" } as any);
    const fields = (post.mock.calls[0][1] as any).body.custom_fields as { id: string; value: string }[];
    expect(fields).toContainEqual({ id: "mu", value: "https://credits.muso.ai/profile/abc123" });
  });

  it("sets the Team field, mapping catalog vs growth actions to distinct options", async () => {
    expect(teamOptionFor("credit-claim")).not.toBe(teamOptionFor("subscription-refund"));
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }), clickupTeamFieldId: "tm" }));
    await tool.execute("c", { actionType: "subscription-refund", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const fields = (post.mock.calls[0][1] as any).body.custom_fields as { id: string; value: string }[];
    expect(fields).toContainEqual({ id: "tm", value: teamOptionFor("subscription-refund") });
  });

  it("blocks tier-2 profile-mutating actions without a profile id, but never tier-1", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }) }));
    const blocked = await tool.execute("c1", { actionType: "profile-update", customerEmail: "u@example.com", summary: "change name", conversationSummary: "c" } as any);
    const bp = JSON.parse((blocked.content[0] as any).text);
    expect(bp.submitted).toBe(false);
    expect(bp.reason).toBe("capture_incomplete");
    expect(bp.action_type).toBe("profile-update");
    expect(post).not.toHaveBeenCalled();
    const ok = await tool.execute("c2", { actionType: "credit-claim", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    expect(JSON.parse((ok.content[0] as any).text).submitted).toBe(true);
    expect(post).toHaveBeenCalledTimes(1);
  });

  it("keeps the profile id out of the title (custom fields carry it)", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "t1" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }) }));
    await tool.execute("c", { actionType: "credit-claim", customerEmail: "u@example.com", customerProfileId: "abcd1234efgh", summary: "s", conversationSummary: "c" } as any);
    const name = (post.mock.calls[0][1] as any).body.name as string;
    expect(name).toBe("[credit-claim] s — u@example.com");
  });
});

import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreateTicketTool, buildTicketDescription, getTierForAction, TIER_SLAS } from "../src/tools/create-ticket.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("getTierForAction", () => {
  it("returns tier 1 for credit-claim", () => { expect(getTierForAction("credit-claim")).toBe(1); });
  it("returns tier 2 for profile-merge", () => { expect(getTierForAction("profile-merge")).toBe(2); });
  it("returns tier 2 for unmerge-request", () => { expect(getTierForAction("unmerge-request")).toBe(2); });
  it("returns tier 3 for data-deletion", () => { expect(getTierForAction("data-deletion")).toBe(3); });
  it("defaults to tier 1 for unknown action types", () => { expect(getTierForAction("unknown-action")).toBe(1); });
});

describe("buildTicketDescription", () => {
  it("builds description with action request markers", () => {
    const desc = buildTicketDescription({ summary: "Customer wants to claim a credit", actionType: "credit-claim", tier: 1, customerEmail: "user@example.com", conversationSummary: "Customer asked about a missing Producer credit on Track X.", sessionId: "session_abc" });
    expect(desc).toContain("Customer wants to claim a credit");
    expect(desc).toContain("---ACTION-REQUEST---");
    expect(desc).toContain("---END-ACTION-REQUEST---");
    expect(desc).toContain('"action_type": "credit-claim"');
    expect(desc).toContain('"approval_tier": 1');
    expect(desc).toContain('"customer_email": "user@example.com"');
    expect(desc).toContain('"cs_session_id": "session_abc"');
  });

  it("includes optional profileId and details when provided", () => {
    const desc = buildTicketDescription({ summary: "Test", actionType: "credit-claim", tier: 1, customerEmail: "user@example.com", customerProfileId: "prof_123", details: { trackName: "Song Title" }, conversationSummary: "Summary.", sessionId: "session_abc" });
    expect(desc).toContain('"customer_profile_id": "prof_123"');
    expect(desc).toContain('"trackName": "Song Title"');
  });
});

describe("TIER_SLAS", () => {
  it("tier 1 is '2 business days'", () => { expect(TIER_SLAS[1]).toBe("2 business days"); });
  it("maps tier 2 to 5 business days", () => { expect(TIER_SLAS[2]).toBe("5 business days"); });
  it("maps tier 3 to 5-10 business days", () => { expect(TIER_SLAS[3]).toBe("5-10 business days"); });
});

describe("createCreateTicketTool", () => {
  let mockClient: HttpClient;
  let limiter: RateLimiter;

  beforeEach(() => { mockClient = { get: vi.fn(), post: vi.fn() }; limiter = new RateLimiter(); });

  it("creates a ClickUp task with correct structure", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_abc123" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Customer wants Producer credit on Track X", conversationSummary: "Customer asked about missing credit." });
    expect(mockClient.post).toHaveBeenCalledWith("https://api.clickup.com/api/v2/list/901000600160/task", { headers: { Authorization: "pk_test" }, body: expect.objectContaining({ name: "Action Request: credit-claim", status: "to do", priority: 3, tags: ["hydra-action-request", "tier-1"], custom_fields: [{ id: "field_uuid_2", value: "user@example.com" }] }) });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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
    expect(body.tags).toEqual(["hydra-action-request", "tier-2"]);
  });

  it("blocks when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 2; i++) { strictLimiter.check("session_abc", "create_ticket", 60, 2); }
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: strictLimiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Test", conversationSummary: "Test." });
    const text = (result.content[0] as { type: "text"; text: string }).text;
    const parsed = JSON.parse(text);
    expect(parsed).toEqual({ submitted: false, reason: "rate_limited" });
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("auto-assigns profile-merge tickets when profileMergeAssigneeId is configured", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_merge1" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc", profileMergeAssigneeId: 12345678 });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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

  it("validation rejection does NOT consume rate-limit budget", async () => {
    // Per silent-failure review: a malformed profile-merge call must not eat
    // one of the 2-per-60s slots, otherwise the agent's retry-with-fixed-fields
    // gets a misleading rate_limited error.
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_rl" });
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
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", {
      actionType: "credit-claim", customerEmail: "user@example.com",
      summary: "Add credit", conversationSummary: "Missing producer credit.",
    });
    const parsed = JSON.parse((result.content[0] as { text: string }).text);
    expect(parsed.submitted).toBe(true);
  });

  it("does NOT auto-assign for non-profile-merge action types even when assignee is configured", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_claim1" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc", profileMergeAssigneeId: 12345678 });
    await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Add producer credit", conversationSummary: "Customer requested missing credit." });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    expect(body.assignees).toBeUndefined();
  });

  it("returns structured queue_busy on ClickUp API failure", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: false, error: "API error", status: 500 });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
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
    clickupApiKey: "k",
    clickupListId: "list",
    clickupProfileIdFieldId: "pf",
    clickupUserEmailFieldId: "ef",
    sessionId: "sess-1",
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
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await tool.execute("c1", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    await tool.execute("c2", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const result = await tool.execute("c3", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
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

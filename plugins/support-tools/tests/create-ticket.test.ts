import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreateTicketTool, buildTicketDescription, getTierForAction, TIER_SLAS } from "../src/tools/create-ticket.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("getTierForAction", () => {
  it("returns tier 1 for credit-claim", () => { expect(getTierForAction("credit-claim")).toBe(1); });
  it("returns tier 2 for profile-merge", () => { expect(getTierForAction("profile-merge")).toBe(2); });
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
  it("maps tier 1 to 48h", () => { expect(TIER_SLAS[1]).toBe("48 hours"); });
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
    expect(mockClient.post).toHaveBeenCalledWith("https://api.clickup.com/api/v2/list/901000600160/task", { headers: { Authorization: "pk_test", "Content-Type": "application/json" }, body: expect.objectContaining({ name: "Action Request: credit-claim", status: "to do", priority: 3, custom_fields: [{ id: "field_uuid_2", value: "user@example.com" }] }) });
    const text = (result.content[0] as { type: "text"; text: string }).text;
    expect(text).toContain("task_abc123");
    expect(text).toContain("48 hours");
  });

  it("includes profile ID custom field when provided", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { id: "task_def456" } });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    await tool.execute("call_1", { actionType: "profile-merge", customerEmail: "user@example.com", customerProfileId: "prof_123", summary: "Merge two profiles", conversationSummary: "Customer has duplicate profiles." });
    const body = vi.mocked(mockClient.post).mock.calls[0][1].body as Record<string, unknown>;
    const fields = body.custom_fields as { id: string; value: string }[];
    expect(fields).toContainEqual({ id: "field_uuid_1", value: "prof_123" });
    expect(body.priority).toBe(2);
  });

  it("blocks when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 2; i++) { strictLimiter.check("session_abc", "create_ticket", 60, 2); }
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: strictLimiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Test", conversationSummary: "Test." });
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("already submitted") });
    expect(mockClient.post).not.toHaveBeenCalled();
  });

  it("returns error on ClickUp API failure", async () => {
    vi.mocked(mockClient.post).mockResolvedValue({ ok: false, error: "API error", status: 500 });
    const tool = createCreateTicketTool({ http: mockClient, rateLimiter: limiter, clickupApiKey: "pk_test", clickupListId: "901000600160", clickupProfileIdFieldId: "field_uuid_1", clickupUserEmailFieldId: "field_uuid_2", sessionId: "session_abc" });
    const result = await tool.execute("call_1", { actionType: "credit-claim", customerEmail: "user@example.com", summary: "Test", conversationSummary: "Test." });
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Unable to create a ticket") });
  });
});

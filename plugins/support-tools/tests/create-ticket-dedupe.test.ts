import { describe, it, expect, vi } from "vitest";
import { createCreateTicketTool } from "../src/tools/create-ticket.js";
import { SessionTicketRegistry } from "../src/session-ticket-registry.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

const TASK_URL_RE = /\/api\/v2\/list\/[^/]+\/task$/;
const COMMENT_URL_RE = /\/api\/v2\/task\/([^/]+)\/comment$/;

function makeHttp(overrides: Partial<HttpClient> = {}): HttpClient {
  return {
    get: vi.fn(async () => ({ ok: true, data: { tasks: [] } as any })),
    post: vi.fn(async (url: string) =>
      COMMENT_URL_RE.test(url)
        ? ({ ok: true, data: { id: "comment_1" } as any })
        : ({ ok: true, data: { id: "task_1" } as any })),
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
    clickupListId: "list9",
    clickupProfileIdFieldId: "pf",
    clickupUserEmailFieldId: "ef",
    sessionId: "sess-1",
    ...overrides,
  };
}

const CLAIM = {
  actionType: "credit-claim",
  customerEmail: "u@example.com",
  summary: "add producer credit",
  conversationSummary: "customer asked for a credit",
} as const;

async function run(tool: ReturnType<typeof createCreateTicketTool>, params: Record<string, unknown>, call = "c") {
  const result = await tool.execute(call, params as any);
  return JSON.parse((result.content[0] as any).text as string);
}

describe("SessionTicketRegistry", () => {
  it("returns the recorded ticket within the TTL and null after it", () => {
    const reg = new SessionTicketRegistry();
    const t0 = 1_000_000;
    reg.record("s1", "credit-claim", "a@x.com", "tk1", t0);
    expect(reg.get("s1", "credit-claim", "a@x.com", t0 + 60_000)).toBe("tk1");
    expect(reg.get("s1", "credit-claim", "a@x.com", t0 + 25 * 60 * 60_000)).toBeNull();
  });

  it("scopes entries by session AND action type AND customer email", () => {
    const reg = new SessionTicketRegistry();
    reg.record("s1", "credit-claim", "a@x.com", "tk1");
    expect(reg.get("s1", "data-deletion", "a@x.com")).toBeNull();
    expect(reg.get("s2", "credit-claim", "a@x.com")).toBeNull();
    // Two customers collapsing onto the same sessionId (e.g. "unknown") must
    // never see each other's tickets.
    expect(reg.get("s1", "credit-claim", "b@y.com")).toBeNull();
    expect(reg.get("s1", "credit-claim", "A@X.com")).toBe("tk1");
  });

  it("invalidate() drops the entry", () => {
    const reg = new SessionTicketRegistry();
    reg.record("s1", "credit-claim", "a@x.com", "tk1");
    reg.invalidate("s1", "credit-claim", "a@x.com");
    expect(reg.get("s1", "credit-claim", "a@x.com")).toBeNull();
  });

  it("sweeps expired entries on record()", () => {
    const reg = new SessionTicketRegistry();
    const t0 = 1_000_000;
    reg.record("s1", "credit-claim", "a@x.com", "tk1", t0);
    reg.record("s2", "credit-claim", "b@y.com", "tk2", t0 + 25 * 60 * 60_000);
    expect(reg.get("s1", "credit-claim", "a@x.com", t0 + 25 * 60 * 60_000)).toBeNull();
    expect(reg.get("s2", "credit-claim", "b@y.com", t0 + 25 * 60 * 60_000)).toBe("tk2");
  });
});

describe("create_ticket dedupe", () => {
  it("appends a comment instead of creating a second ticket for the same session + action type", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);

    const first = await run(tool, CLAIM, "c1");
    expect(first).toMatchObject({ submitted: true, ticket_id: "task_1" });

    const second = await run(tool, { ...CLAIM, summary: "customer added the track URL" }, "c2");
    expect(second).toEqual({
      submitted: true,
      updated_existing: true,
      ticket_id: "task_1",
      sla: "2 business days",
      action_type: "credit-claim",
      tier: 1,
    });

    const post = vi.mocked(deps.http.post);
    const taskPosts = post.mock.calls.filter(([url]) => TASK_URL_RE.test(url as string));
    const commentPosts = post.mock.calls.filter(([url]) => COMMENT_URL_RE.test(url as string));
    expect(taskPosts).toHaveLength(1);
    expect(commentPosts).toHaveLength(1);
    expect(commentPosts[0][0]).toContain("/task/task_1/comment");
    const commentBody = (commentPosts[0][1] as any).body;
    expect(commentBody.notify_all).toBe(false);
    expect(commentBody.comment_text).toContain("**Customer follow-up** (credit-claim): customer added the track URL");
    expect(commentBody.comment_text).toContain("---ACTION-REQUEST-UPDATE---");
  });

  // MUS-1516: the append (follow-up-comment) path is the OTHER call site that must
  // record the filed id — a conversation whose second create_ticket call merely
  // commented on the existing ticket still needs that id backed for the intercom
  // reference-id guard (design call ① on MUS-1471 — "both must record the id").
  it("records the existing ticket's id on the follow-up-comment (append) path too", async () => {
    const IDS_KEY = "__musoSupportTicketIds";
    delete (globalThis as unknown as Record<string, unknown>)[IDS_KEY];
    const deps = makeDeps({ sessionKey: "agent:support:intercom:direct:conv_append1" });
    const tool = createCreateTicketTool(deps);

    await run(tool, CLAIM, "c1"); // creates task_1
    const second = await run(tool, { ...CLAIM, summary: "customer added the track URL" }, "c2"); // appends
    expect(second).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "task_1" });

    const store = (globalThis as unknown as Record<string, unknown>)[IDS_KEY] as Map<string, { atMs: number; ids: string[] }> | undefined;
    expect(store?.get("conv_append1")?.ids).toEqual(["task_1"]);
  });

  it("still creates a new ticket for a different action type in the same session", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM, "c1");
    const second = await run(tool, { ...CLAIM, actionType: "support-general", summary: "wants a human" }, "c2");
    expect(second.updated_existing).toBeUndefined();
    expect(second.submitted).toBe(true);
    const taskPosts = vi.mocked(deps.http.post).mock.calls.filter(([url]) => TASK_URL_RE.test(url as string));
    expect(taskPosts).toHaveLength(2);
  });

  it("finds an existing open ticket via ClickUp lookup when the registry is empty (restart survival)", async () => {
    const now = Date.now();
    const get = vi.fn(async () => ({
      ok: true,
      data: {
        tasks: [
          { id: "old_closed", status: { status: "complete" }, date_created: String(now - 1000) },
          { id: "older_open", status: { status: "to do" }, date_created: String(now - 60_000) },
          { id: "newest_open", status: { status: "to do" }, date_created: String(now - 1000), custom_fields: [{ id: "ef", value: "u@example.com" }] },
          { id: "stale_open", status: { status: "to do" }, date_created: String(now - 8 * 24 * 60 * 60_000) },
        ],
      } as any,
    }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);

    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "newest_open" });

    // Lookup filtered by the email custom field + the action tag.
    const url = vi.mocked(get).mock.calls[0][0] as string;
    expect(url).toContain("/api/v2/list/list9/task?");
    expect(url).toContain(encodeURIComponent("action:credit-claim"));
    expect(url).toContain(encodeURIComponent('"value":"u@example.com"'));

    const taskPosts = vi.mocked(deps.http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string));
    expect(taskPosts).toHaveLength(0);
  });

  it("creates a ticket when the ClickUp lookup fails (fail-soft, never blocks filing)", async () => {
    const get = vi.fn(async () => ({ ok: false, error: "boom", status: 500 } as any));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
  });

  it("falls back to creating a new ticket when the comment POST fails", async () => {
    const post = vi.fn(async (url: string) =>
      COMMENT_URL_RE.test(url)
        ? ({ ok: false, error: "API error", status: 500 } as any)
        : ({ ok: true, data: { id: "task_2" } as any }));
    const deps = makeDeps({ http: makeHttp({ post }) });
    const tool = createCreateTicketTool(deps);

    deps.sessionTickets.record("sess-1", "credit-claim", "u@example.com", "task_1");
    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_2" });
    expect(result.updated_existing).toBeUndefined();
  });

  it("invalidates a registry hit pointing at a closed ticket and files a new one", async () => {
    // Ops resolved the ticket mid-conversation: the follow-up must NOT be
    // appended to the closed task (nobody reads it) — file fresh instead.
    const get = vi.fn(async (url: string) =>
      /\/task\//.test(url)
        ? ({ ok: true, data: { id: "task_1", status: { status: "resolved", type: "done" } } } as any)
        : ({ ok: true, data: { tasks: [] } } as any));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    deps.sessionTickets.record("sess-1", "credit-claim", "u@example.com", "task_1");
    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
    const commentPosts = vi.mocked(deps.http.post).mock.calls.filter(([u]) => COMMENT_URL_RE.test(u as string));
    expect(commentPosts).toHaveLength(0);
  });

  it("matches an in-progress ticket in the lookup (a human working it is still open)", async () => {
    const now = Date.now();
    const get = vi.fn(async () => ({
      ok: true,
      data: { tasks: [{ id: "wip_1", status: { status: "in progress", type: "custom" }, date_created: String(now - 1000), custom_fields: [{ id: "ef", value: "u@example.com" }] }] } as any,
    }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "wip_1" });
  });

  it("never appends onto intercom-auto-handoff escalation tickets", async () => {
    const now = Date.now();
    const get = vi.fn(async () => ({
      ok: true,
      data: { tasks: [{ id: "handoff_1", status: { status: "to do" }, date_created: String(now - 1000), tags: [{ name: "intercom-auto-handoff" }] }] } as any,
    }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, CLAIM);
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
  });

  it("skips the cross-conversation lookup for profile-merge (sweep auto-close hazard)", async () => {
    const get = vi.fn(async () => ({ ok: true, data: { tasks: [] } as any }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, {
      actionType: "profile-merge", customerEmail: "u@example.com", customerProfileId: "prof_1",
      summary: "merge",
      details: { main_profile_url: "https://credits.muso.ai/profile/aaa", duplicate_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "dup profiles",
    });
    expect(result.submitted).toBe(true);
    expect(vi.mocked(get).mock.calls).toHaveLength(0);
  });

  it("skips the cross-conversation lookup for track-merge (sweep auto-close hazard)", async () => {
    const get = vi.fn(async () => ({ ok: true, data: { tasks: [] } as any }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, {
      actionType: "track-merge", customerEmail: "u@example.com",
      summary: "merge tracks",
      details: { track_merge_pairs: [{ master: "A", duplicates: ["A-dup"] }] },
      conversationSummary: "dup tracks",
    });
    expect(result.submitted).toBe(true);
    expect(vi.mocked(get).mock.calls).toHaveLength(0);
  });

  it("meters the lookup GET in its own bucket (10/60min)", async () => {
    // A retry-looping session must not hammer ClickUp search unbounded —
    // after the lookup budget is gone, calls proceed straight to the create
    // gate (which rate-limits the writes).
    const get = vi.fn(async () => ({ ok: true, data: { tasks: [] } as any }));
    const post = vi.fn(async () => ({ ok: false, error: "API error", status: 503 } as any));
    const deps = makeDeps({ http: makeHttp({ get, post }) });
    const tool = createCreateTicketTool(deps);
    for (let i = 0; i < 14; i++) await run(tool, CLAIM, `c${i}`);
    const listGets = vi.mocked(get).mock.calls.filter(([u]) => (u as string).includes("/list/"));
    expect(listGets.length).toBe(10);
  });

  it("follow-up comments do not consume the 2-per-session create budget", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM, "c1"); // create #1
    await run(tool, CLAIM, "c2"); // follow-up comment
    await run(tool, CLAIM, "c3"); // follow-up comment
    // Second CREATE (different action type) must still be allowed.
    const second = await run(tool, { ...CLAIM, actionType: "support-general" }, "c4");
    expect(second.submitted).toBe(true);
    expect(second.updated_existing).toBeUndefined();
  });

  it("rate-limits runaway follow-ups in their own bucket", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM, "c0"); // create
    for (let i = 0; i < 5; i++) {
      const r = await run(tool, CLAIM, `f${i}`);
      expect(r.updated_existing).toBe(true);
    }
    const sixth = await run(tool, CLAIM, "f5");
    expect(sixth).toEqual({ submitted: false, reason: "rate_limited" });
    // It must NOT have leaked into creating a brand-new duplicate ticket.
    const taskPosts = vi.mocked(deps.http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string));
    expect(taskPosts).toHaveLength(1);
  });

  it("registers lookup hits so subsequent follow-ups skip the list search", async () => {
    const now = Date.now();
    const get = vi.fn(async (url: string) =>
      url.includes("/list/")
        ? ({ ok: true, data: { tasks: [{ id: "found_1", status: { status: "to do" }, date_created: String(now - 1000), custom_fields: [{ id: "ef", value: "u@example.com" }] }] } } as any)
        : ({ ok: true, data: { id: "found_1", status: { status: "to do" } } } as any));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM, "c1");
    await run(tool, CLAIM, "c2");
    const listGets = vi.mocked(get).mock.calls.filter(([u]) => (u as string).includes("/list/"));
    expect(listGets).toHaveLength(1);
  });
});

describe("create_ticket title gist", () => {
  it("uses titleGist for the title when provided", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, { ...CLAIM, titleGist: "Producer credit missing on Track X" });
    const post = vi.mocked(deps.http.post);
    const body = (post.mock.calls[0][1] as any).body;
    expect(body.name).toBe("[credit-claim] Producer credit missing on Track X — u@example.com");
  });

  it("falls back to the summary when titleGist is absent", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM);
    const body = (vi.mocked(deps.http.post).mock.calls[0][1] as any).body;
    expect(body.name).toBe("[credit-claim] add producer credit — u@example.com");
  });
});

describe("create_ticket body, due date and tags", () => {
  it("sends markdown_description with human section + machine JSON block", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, { ...CLAIM, customerProfileId: "prof_1", details: { track: "Song X" } });
    const body = (vi.mocked(deps.http.post).mock.calls[0][1] as any).body;
    expect(body.description).toBeUndefined();
    expect(body.markdown_description).toContain("**Customer:** u@example.com");
    expect(body.markdown_description).toContain("**Profile:** https://credits.muso.ai/profile/prof_1");
    expect(body.markdown_description).toContain("- track: Song X");
    const m = /---ACTION-REQUEST---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST---/.exec(body.markdown_description);
    expect(m).not.toBeNull();
    expect(JSON.parse(m![1]).action_type).toBe("credit-claim");
  });

  it("sets a due_date from the tier SLA", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    const before = Date.now();
    await run(tool, CLAIM);
    const body = (vi.mocked(deps.http.post).mock.calls[0][1] as any).body;
    expect(body.due_date_time).toBe(false);
    expect(typeof body.due_date).toBe("number");
    // #515 pins SLA due dates to noon UTC (date-only ClickUp due). A "2 business
    // day" SLA lands on noon of the target UTC day — up to ~12h earlier than the
    // raw now+2bd, so as little as ~1.5 days out when filed late in the UTC day,
    // and up to ~4.5 days across a weekend. (The old `>= now+2d-60s` lower bound
    // broke every afternoon UTC once noon-pinning landed.)
    expect(new Date(body.due_date).getUTCHours()).toBe(12); // noon-UTC pinned (#515)
    expect(body.due_date).toBeGreaterThanOrEqual(before + 36 * 60 * 60_000 - 60_000);
    expect(body.due_date).toBeLessThanOrEqual(before + 5 * 24 * 60 * 60_000);
  });

  it("adds team + escalation tags", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    await run(tool, {
      ...CLAIM,
      actionType: "support-general",
      details: { escalation_reason: "customer_requested_human" },
    });
    const body = (vi.mocked(deps.http.post).mock.calls[0][1] as any).body;
    expect(body.tags).toEqual([
      "hydra-action-request",
      "tier-1",
      "action:support-general",
      "team:growth",
      "escalation:customer-requested-human",
    ]);
  });

  it("marks profile-scoped credit-verification tickets automation-ready regardless of ids or recommendation", async () => {
    const profileId = "11111111-1111-4111-8111-111111111111";
    const requestId = "22222222-2222-4222-8222-222222222222";
    // Eligibility is a UUID profile. Exact cr_ids only narrow the runner's
    // scope; the `recommendation` field is deliberately ignored — full
    // rationale on hasAutomationReadyUvnScope in src/tools/create-ticket.ts.
    for (const details of [
      { pending_credits: [{ cr_id: requestId }], recommendation: "recommend-approve" },
      { pending_credits: [{ cr_id: requestId }], recommendation: "needs-human" },
      { pending_credits: [{ cr_id: requestId }] },
      // The live shape (measured 2026-09-04: 39 of 40 tickets): no cr_ids at all.
      { pending_credits: [{ role: "Mixing", track_title: "Song" }], proof: { kind: "private" } },
      { credit_request_id: requestId },
      {},
      undefined,
    ]) {
      const readyDeps = makeDeps();
      const readyTool = createCreateTicketTool(readyDeps);
      await run(readyTool, {
        ...CLAIM,
        actionType: "credit-verify",
        customerProfileId: profileId,
        details,
      });
      const readyBody = (vi.mocked(readyDeps.http.post).mock.calls[0][1] as any).body;
      expect(readyBody.tags).toContain("automation:uvn-under30");
    }

    for (const params of [
      { customerProfileId: profileId, details: { pending_credits: [{ cr_id: "not-a-uuid" }] } },
      { customerProfileId: profileId, details: { pending_credits: "not-a-list" } },
      { customerProfileId: "not-a-uuid", details: { pending_credits: [{ cr_id: requestId }] } },
      { customerProfileId: undefined, details: { pending_credits: [{ cr_id: requestId }] } },
    ]) {
      const manualDeps = makeDeps();
      const manualTool = createCreateTicketTool(manualDeps);
      await run(manualTool, { ...CLAIM, actionType: "credit-verify", ...params });
      const manualBody = (vi.mocked(manualDeps.http.post).mock.calls[0][1] as any).body;
      expect(manualBody.tags).not.toContain("automation:uvn-under30");
    }
  });
});

// SLA-breach escalation on follow-up appends (2026-05 Sandy Vee incident:
// the customer's overdue follow-ups must visibly escalate the existing
// ticket, not just bury a comment in it).
describe("create_ticket escalation follow-up", () => {
  const TAG_URL_RE = /\/api\/v2\/task\/([^/]+)\/tag\/(.+)$/;

  async function fileThenFollowUp(deps: ReturnType<typeof makeDeps>, details?: Record<string, unknown>) {
    const tool = createCreateTicketTool(deps);
    await run(tool, CLAIM, "c1");
    return run(tool, { ...CLAIM, summary: "it has been weeks", details }, "c2");
  }

  it("sla_breach_customer_followup append tags the ticket and bumps priority to urgent", async () => {
    const deps = makeDeps();
    const second = await fileThenFollowUp(deps, { escalation_reason: "sla_breach_customer_followup" });
    expect(second).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "task_1" });

    const tagCall = vi.mocked(deps.http.post).mock.calls.find(([url]) => TAG_URL_RE.test(url));
    expect(tagCall).toBeDefined();
    expect(decodeURIComponent(tagCall![0])).toContain("/task/task_1/tag/escalation:sla-breach-customer-followup");

    const putCalls = vi.mocked(deps.http.put).mock.calls;
    expect(putCalls).toHaveLength(1);
    expect(putCalls[0][0]).toContain("/task/task_1");
    expect((putCalls[0][1] as any).body).toEqual({ priority: 1 });
  });

  it("non-urgent escalation reason tags but does not bump priority", async () => {
    const deps = makeDeps();
    await fileThenFollowUp(deps, { escalation_reason: "on_behalf_claim_manual_review" });
    const tagCall = vi.mocked(deps.http.post).mock.calls.find(([url]) => TAG_URL_RE.test(url));
    expect(decodeURIComponent(tagCall![0])).toContain("escalation:on-behalf-claim-manual-review");
    expect(vi.mocked(deps.http.put).mock.calls).toHaveLength(0);
  });

  it("plain follow-up (no escalation_reason) neither tags nor bumps", async () => {
    const deps = makeDeps();
    await fileThenFollowUp(deps);
    expect(vi.mocked(deps.http.post).mock.calls.some(([url]) => TAG_URL_RE.test(url))).toBe(false);
    expect(vi.mocked(deps.http.put).mock.calls).toHaveLength(0);
  });

  it("unknown escalation_reason is ignored (no tag, no bump)", async () => {
    const deps = makeDeps();
    await fileThenFollowUp(deps, { escalation_reason: "made_up_reason" });
    expect(vi.mocked(deps.http.post).mock.calls.some(([url]) => TAG_URL_RE.test(url))).toBe(false);
    expect(vi.mocked(deps.http.put).mock.calls).toHaveLength(0);
  });

  it("tag/priority failures still return updated_existing (comment already landed)", async () => {
    const deps = makeDeps({
      http: makeHttp({
        post: vi.fn(async (url: string) => {
          if (COMMENT_URL_RE.test(url)) return { ok: true, data: { id: "comment_1" } as any };
          if (TAG_URL_RE.test(url)) return { ok: false, error: "API error", status: 500 } as any;
          return { ok: true, data: { id: "task_1" } as any };
        }),
        put: vi.fn(async () => ({ ok: false, error: "API error", status: 500 } as any)),
      }),
    });
    const second = await fileThenFollowUp(deps, { escalation_reason: "sla_breach_customer_followup" });
    expect(second).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "task_1" });
  });
});

// MUS-6588: 2026-10-09 a create_ticket call with customer_email "" took the
// cross-conversation lookup and appended Sony's correction onto another
// customer's ticket (27 misfiles on 19 tickets since 2026-09-09, 13 of them
// GDPR/deletion). ClickUp returns unrelated tasks for `value: ""`.
describe("create_ticket cross-conversation dedupe never trusts an unusable or unverified email", () => {
  const now = Date.now();
  const stranger = (extra: Record<string, unknown> = {}) => ({
    id: "strangers_ticket",
    status: { status: "to do" },
    date_created: String(now - 1000),
    custom_fields: [{ id: "ef", value: "fabian@example.com" }],
    ...extra,
  });
  const listGet = (tasks: unknown[], single?: unknown) =>
    vi.fn(async (url: string) =>
      url.includes("/list/")
        ? ({ ok: true, data: { tasks } } as any)
        : ({ ok: true, data: single ?? { id: "x" } } as any));
  const posts = (deps: ReturnType<typeof makeDeps>) => {
    const calls = vi.mocked(deps.http.post).mock.calls;
    return {
      creates: calls.filter(([u]) => TASK_URL_RE.test(u as string)),
      comments: calls.filter(([u]) => COMMENT_URL_RE.test(u as string)),
    };
  };

  it.each([
    ["credit-correction", "empty", ""],
    ["credit-correction", "whitespace-only", "   "],
    ["credit-correction", "not an email", "not-an-email"],
    ["data-deletion", "empty (GDPR erasure must never land on a stranger's ticket)", ""],
  ])("%s with %s customerEmail creates a new ticket and never comments", async (actionType, _label, email) => {
    const get = listGet([stranger()]);
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, { ...CLAIM, actionType, customerEmail: email });
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
    const { creates, comments } = posts(deps);
    expect(creates).toHaveLength(1);
    expect(comments).toHaveLength(0);
    // The lookup itself is skipped: nothing to ask ClickUp.
    expect(vi.mocked(get).mock.calls.filter(([u]) => (u as string).includes("/list/"))).toHaveLength(0);
  });

  it("trims the email once: padded real email still dedupes against a matching ticket", async () => {
    const get = listGet([stranger({ id: "mine", custom_fields: [{ id: "ef", value: "u@example.com" }] })]);
    const deps = makeDeps({ http: makeHttp({ get }) });
    const result = await run(createCreateTicketTool(deps), { ...CLAIM, customerEmail: "  U@Example.com " });
    expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "mine" });
    expect(decodeURIComponent(vi.mocked(get).mock.calls[0][0] as string)).toContain('"value":"U@Example.com"');
  });

  it("real email + list payload carries a matching email field (case-insensitive) => still appends, no extra GET", async () => {
    const get = listGet([stranger({ id: "mine", custom_fields: [{ id: "other", value: "z" }, { id: "ef", value: "U@EXAMPLE.com" }] })]);
    const deps = makeDeps({ http: makeHttp({ get }) });
    const result = await run(createCreateTicketTool(deps), CLAIM);
    expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "mine" });
    expect(vi.mocked(get).mock.calls).toHaveLength(1);
  });

  it("real email + candidate belongs to a DIFFERENT customer => creates, never comments", async () => {
    const get = listGet([stranger()]);
    const deps = makeDeps({ http: makeHttp({ get }) });
    const result = await run(createCreateTicketTool(deps), CLAIM);
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
    expect(posts(deps).comments).toHaveLength(0);
  });

  it("list payload omits custom_fields => ONE single-task GET verifies the email, then appends", async () => {
    const get = listGet(
      [stranger({ id: "mine", custom_fields: undefined })],
      { id: "mine", status: { status: "to do" }, custom_fields: [{ id: "ef", value: "u@example.com" }] },
    );
    const deps = makeDeps({ http: makeHttp({ get }) });
    const result = await run(createCreateTicketTool(deps), CLAIM);
    expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "mine" });
    const urls = vi.mocked(get).mock.calls.map(([u]) => u as string);
    expect(urls).toHaveLength(2);
    expect(urls[1]).toBe("https://api.clickup.com/api/v2/task/mine");
  });

  it("list payload omits custom_fields and the single GET shows another customer => creates", async () => {
    const get = listGet(
      [stranger({ custom_fields: undefined })],
      { id: "strangers_ticket", custom_fields: [{ id: "ef", value: "fabian@example.com" }] },
    );
    const deps = makeDeps({ http: makeHttp({ get }) });
    const result = await run(createCreateTicketTool(deps), CLAIM);
    expect(result.updated_existing).toBeUndefined();
    expect(posts(deps).comments).toHaveLength(0);
  });

  it("email cannot be read at all (single GET fails or has no email field) => creates, never appends unverified", async () => {
    for (const single of [undefined, { id: "strangers_ticket", custom_fields: [] }]) {
      const get = vi.fn(async (url: string) =>
        url.includes("/list/")
          ? ({ ok: true, data: { tasks: [stranger({ custom_fields: undefined })] } } as any)
          : single ? ({ ok: true, data: single } as any) : ({ ok: false, status: 500 } as any));
      const deps = makeDeps({ http: makeHttp({ get }) });
      const result = await run(createCreateTicketTool(deps), CLAIM);
      expect(result.updated_existing).toBeUndefined();
      expect(posts(deps).comments).toHaveLength(0);
    }
  });

  it("same-conversation registry hit with an empty email still appends (intra-conversation dedupe unchanged)", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    const empty = { ...CLAIM, customerEmail: "" };
    await run(tool, empty, "c1");
    const second = await run(tool, empty, "c2");
    expect(second).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "task_1" });
  });
});

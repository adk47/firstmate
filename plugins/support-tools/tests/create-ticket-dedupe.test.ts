import { describe, it, expect, vi } from "vitest";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createCreateTicketTool, NO_TIMEFRAME_NOTES } from "../src/tools/create-ticket.js";
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
      sla: null,
      customer_timing: NO_TIMEFRAME_NOTES.unspecified,
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

  it("files a second unmerge from another conversation as its own ticket, never appended to the open one", async () => {
    const get = vi.fn(async () => ({
      ok: true,
      data: { tasks: [
        { id: "open_unmerge", status: { status: "to do" }, date_created: String(Date.now() - 1000), custom_fields: [{ id: "ef", value: "u@example.com" }] },
      ] } as any,
    }));
    const deps = makeDeps({ http: makeHttp({ get }) });
    const tool = createCreateTicketTool(deps);
    const result = await run(tool, {
      actionType: "unmerge-request", customerEmail: "u@example.com", customerProfileId: "prof_1",
      summary: "separate profile C",
      details: { merged_profile_urls: ["https://credits.muso.ai/profile/ccc"] },
      conversationSummary: "wrong merge",
    });
    expect(result).toMatchObject({ submitted: true, ticket_id: "task_1" });
    expect(result.updated_existing).toBeUndefined();
    expect(vi.mocked(deps.http.post).mock.calls.some(([u]) => COMMENT_URL_RE.test(u as string))).toBe(false);
  });

  it("still appends a same-conversation unmerge follow-up to its ticket", async () => {
    // ClickUp keeps the filed description, so the follow-up can rewrite its merge_intake.
    let description: string | undefined;
    const deps = makeDeps({ http: makeHttp({
      post: vi.fn(async (url: string, o: any) => {
        if (COMMENT_URL_RE.test(url)) return { ok: true, data: { id: "comment_1" } as any };
        description = o.body.markdown_description;
        return { ok: true, data: { id: "task_1" } as any };
      }),
      get: vi.fn(async (url: string) => url.includes("include_markdown_description=true")
        ? { ok: true, data: { markdown_description: description } as any }
        : { ok: true, data: { tasks: [], status: { status: "to do", type: "open" } } as any }),
    }) });
    const tool = createCreateTicketTool(deps);
    const params = {
      actionType: "unmerge-request", customerEmail: "u@example.com", customerProfileId: "prof_1",
      summary: "separate profile B",
      details: { merged_profile_urls: ["https://credits.muso.ai/profile/bbb"] },
      conversationSummary: "wrong merge",
    };
    expect(await run(tool, params, "c1")).toMatchObject({ submitted: true, ticket_id: "task_1" });
    const second = await run(tool, { ...params, summary: "one more detail" }, "c2");
    expect(second).toMatchObject({ submitted: true, ticket_id: "task_1", updated_existing: true });
  });

  it("files a second, DIFFERENT unmerge in the same conversation as its own ticket", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    const base = {
      actionType: "unmerge-request", customerEmail: "u@example.com", customerProfileId: "prof_1",
      conversationSummary: "wrong merges",
    };
    const first = await run(tool, { ...base, summary: "separate profile B",
      details: { merged_profile_urls: ["https://credits.muso.ai/profile/bbb"] } }, "c1");
    expect(first).toMatchObject({ submitted: true });
    const second = await run(tool, { ...base, summary: "also separate profile C",
      details: { merged_profile_urls: ["https://credits.muso.ai/profile/ccc"] } }, "c2");
    expect(second.submitted).toBe(true);
    expect(second.updated_existing).toBeUndefined();
    const taskPosts = vi.mocked(deps.http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string));
    expect(taskPosts).toHaveLength(2);
    expect(vi.mocked(deps.http.post).mock.calls.some(([u]) => COMMENT_URL_RE.test(u as string))).toBe(false);
  });

  describe("merge follow-ups widen the open ticket's merge_intake", () => {
    const B = "https://credits.muso.ai/profile/bbb";
    const C = "https://credits.muso.ai/profile/ccc";
    const base = {
      actionType: "unmerge-request", customerEmail: "u@example.com", customerProfileId: "prof_1",
      conversationSummary: "wrong merge",
    };
    const intakeOf = (markdown: string) => {
      const block = markdown.split("---ACTION-REQUEST---\n")[1].split("\n---END-ACTION-REQUEST---")[0];
      return JSON.parse(block).details.merge_intake;
    };
    // ClickUp as the tool sees it: each filed task keeps its description, which a GET with
    // include_markdown_description returns and a PUT markdown_content replaces.
    function liveClickup(opts: { putOk?: boolean; tagOk?: (tag: string, attempt: number, id: string) => boolean;
                                 createOk?: (n: number) => boolean; getOk?: (id: string) => boolean;
                                 deleteOk?: boolean } = {}) {
      const attempts = new Map<string, number>();
      const closed = new Set<string>();
      const descriptions = new Map<string, string>();
      const tags = new Map<string, string[]>();
      const comments = new Map<string, string[]>();
      let n = 0;
      const http = makeHttp({
        post: vi.fn(async (url: string, o: any) => {
          const tagged = url.match(/\/task\/([^/]+)\/tag\/([^/]+)$/);
          if (tagged) {
            const tag = decodeURIComponent(tagged[2]);
            const attempt = (attempts.get(url) ?? 0) + 1;
            attempts.set(url, attempt);
            if (opts.tagOk && !opts.tagOk(tag, attempt, tagged[1])) return { ok: false, error: "API error", status: 500 } as any;
            tags.set(tagged[1], [...(tags.get(tagged[1]) ?? []), decodeURIComponent(tagged[2])]);
            return { ok: true, data: {} as any };
          }
          const commented = url.match(COMMENT_URL_RE);
          if (commented) {
            comments.set(commented[1], [...(comments.get(commented[1]) ?? []), o.body.comment_text]);
            return { ok: true, data: { id: "comment_1" } as any };
          }
          if (opts.createOk && !opts.createOk(n + 1)) return { ok: false, error: "API error", status: 429 } as any;
          const id = `task_${++n}`;
          descriptions.set(id, o.body.markdown_description);
          tags.set(id, [...(o.body.tags ?? [])]);
          return { ok: true, data: { id } as any };
        }),
        delete: vi.fn(async (url: string) => {
          if (opts.deleteOk === false) return { ok: false, error: "API error", status: 500 } as any;
          const [, id, tag] = url.match(/\/task\/([^/]+)\/tag\/([^/]+)$/)!;
          tags.set(id, (tags.get(id) ?? []).filter((t) => t !== decodeURIComponent(tag)));
          return { ok: true, data: {} as any };
        }),
        get: vi.fn(async (url: string) => {
          const id = url.split("/task/")[1]?.split("?")[0];
          if (id && opts.getOk && !opts.getOk(id)) return { ok: false, error: "API error", status: 429 } as any;
          if (url.includes("include_markdown_description=true")) {
            return { ok: true, data: { id, markdown_description: descriptions.get(id) } as any };
          }
          return { ok: true, data: { id, tags: (tags.get(id) ?? []).map((name) => ({ name })),
            status: closed.has(id) ? { status: "closed", type: "closed" } : { status: "to do", type: "open" } } as any };
        }),
        put: vi.fn(async (url: string, o: any) => {
          if (opts.putOk === false) return { ok: false, error: "API error", status: 500 } as any;
          descriptions.set(url.split("/task/")[1], o.body.markdown_content);
          return { ok: true, data: {} as any };
        }),
      });
      return { http, descriptions, tags, comments, closed };
    }

    it("appends an overlapping follow-up and rewrites the description's intake to the union", async () => {
      const { http, descriptions } = liveClickup();
      const deps = makeDeps({ http });
      const tool = createCreateTicketTool(deps);
      await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
      const second = await run(tool, { ...base, summary: "and C too", details: { merged_profile_urls: [B, C] } }, "c2");
      expect(second).toMatchObject({ submitted: true, ticket_id: "task_1", updated_existing: true });
      expect(second.merge_intake_update_failed).toBeUndefined();
      const posts = vi.mocked(http.post).mock.calls;
      expect(posts.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(1);
      expect(posts.filter(([u]) => COMMENT_URL_RE.test(u as string))).toHaveLength(1);
      expect(vi.mocked(http.put).mock.calls.map(([u]) => u)).toEqual(["https://api.clickup.com/api/v2/task/task_1"]);
      const markdown = descriptions.get("task_1")!;
      expect(markdown).toContain("**Request:** separate B");
      expect(intakeOf(markdown)).toMatchObject({ kind: "unmerge-request", keep: "prof_1", others: [B, C], complete: true });

      const third = await run(tool, { ...base, summary: "C detail", details: { merged_profile_urls: [C] } }, "c3");
      expect(third).toMatchObject({ ticket_id: "task_1", updated_existing: true });
      expect(intakeOf(descriptions.get("task_1")!).others).toEqual([B, C]);
    });

    it("replaces only the ACTION-REQUEST block, keeping a human's edits to the description", async () => {
      const { http, descriptions } = liveClickup();
      const tool = createCreateTicketTool(makeDeps({ http }));
      await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
      const edited = `**Ops note:** customer prefers email, called 10-20.\n\n${descriptions.get("task_1")!}\n\nReviewed by Sam.`;
      descriptions.set("task_1", edited);
      await run(tool, { ...base, summary: "and C too", details: { merged_profile_urls: [B, C] } }, "c2");
      const after = descriptions.get("task_1")!;
      const [beforeBlock, afterBlock] = [edited.split("---ACTION-REQUEST---\n"), after.split("---ACTION-REQUEST---\n")];
      expect(afterBlock[0]).toBe(beforeBlock[0]);
      expect(after.split("\n---END-ACTION-REQUEST---")[1]).toBe(edited.split("\n---END-ACTION-REQUEST---")[1]);
      expect(intakeOf(after).others).toEqual([B, C]);
      expect(JSON.parse(afterBlock[1].split("\n---END-ACTION-REQUEST---")[0]).details.merged_profile_urls).toEqual([B]);
    });

    it("holds the ticket merge-intake-stale and spools it once when the intake cannot be widened", async () => {
      for (const setup of ["put-fails", "block-missing", "tag-fails"] as const) {
        const dir = mkdtempSync(join(tmpdir(), "intake-stale-spool-"));
        const { http, descriptions, tags } = liveClickup({ putOk: setup === "block-missing",
          tagOk: (tag) => setup !== "tag-fails" || tag !== "merge-intake-stale" });
        const tool = createCreateTicketTool(makeDeps({ http, keepConflictSpoolDir: dir }));
        await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
        if (setup === "block-missing") descriptions.set("task_1", "## rewritten by a human, no action block");
        const second = await run(tool, { ...base, summary: "and C too", details: { merged_profile_urls: [B, C] } }, "c2");
        expect(second).toMatchObject({ submitted: false, reason: "merge_intake_not_updated", ticket_id: "task_1" });
        expect(second.hint).toContain("Human Handoff");
        if (setup === "block-missing") {
          expect(http.put).not.toHaveBeenCalled();
          expect(descriptions.get("task_1")).toBe("## rewritten by a human, no action block");
        } else {
          expect(http.put).toHaveBeenCalledTimes(2);
          // The executor's view is unchanged: the canonical intake still names only B.
          expect(intakeOf(descriptions.get("task_1")!).others).toEqual([B]);
        }
        const held = setup !== "tag-fails";
        expect((tags.get("task_1") ?? []).includes("merge-intake-stale")).toBe(held);
        const files = readdirSync(dir);
        expect(files).toHaveLength(1);
        expect(JSON.parse(readFileSync(join(dir, files[0]), "utf8")))
          .toMatchObject({ ticket_ids: ["task_1"], intake_unwritten: true, held });
      }
    });

    it("widens the intake when the description write lands on its retry", async () => {
      const live = liveClickup();
      const put = live.http.put;
      let puts = 0;
      live.http.put = vi.fn(async (url: string, o: any) =>
        (++puts === 1 ? { ok: false, error: "API error", status: 429 } as any : put(url, o)));
      const dir = mkdtempSync(join(tmpdir(), "intake-stale-spool-"));
      const tool = createCreateTicketTool(makeDeps({ http: live.http, keepConflictSpoolDir: dir }));
      await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
      const second = await run(tool, { ...base, summary: "and C too", details: { merged_profile_urls: [B, C] } }, "c2");
      expect(second).toMatchObject({ submitted: true, ticket_id: "task_1", updated_existing: true });
      expect(intakeOf(live.descriptions.get("task_1")!).others).toEqual([B, C]);
      expect(live.tags.get("task_1") ?? []).not.toContain("merge-intake-stale");
      expect(readdirSync(dir)).toEqual([]);
    });

    it("routes a follow-up to the ticket whose targets it names, and a target-less one to the newest", async () => {
      const { http } = liveClickup();
      const tool = createCreateTicketTool(makeDeps({ http }));
      await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
      await run(tool, { ...base, summary: "separate C", details: { merged_profile_urls: [C] } }, "c2");
      expect(await run(tool, { ...base, summary: "one more thing", details: { suspect_artist_names: ["DJ X"] } }, "c3"))
        .toMatchObject({ ticket_id: "task_2", updated_existing: true });
      expect(await run(tool, { ...base, summary: "B detail", details: { merged_profile_urls: [B] } }, "c4"))
        .toMatchObject({ ticket_id: "task_1", updated_existing: true });
      expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(2);
    });

    it("parses a description ClickUp round-tripped (escaped underscores, inserted blank lines)", async () => {
      const { http, descriptions } = liveClickup();
      const tool = createCreateTicketTool(makeDeps({ http }));
      await run(tool, { ...base, summary: "separate B", details: { merged_profile_urls: [B] } }, "c1");
      const roundTripped = descriptions.get("task_1")!.replace(/_/g, "\\_").replace(/\n/g, "\n\n");
      expect(() => JSON.parse(roundTripped.split("---ACTION-REQUEST---")[1].split("---END-ACTION-REQUEST---")[0]))
        .toThrow();
      descriptions.set("task_1", roundTripped);
      const second = await run(tool, { ...base, summary: "and C too", details: { merged_profile_urls: [B, C] } }, "c2");
      expect(second).toMatchObject({ ticket_id: "task_1", updated_existing: true });
      expect(second.merge_intake_update_failed).toBeUndefined();
      const after = descriptions.get("task_1")!;
      expect(after.split("---ACTION-REQUEST---")[0]).toBe(roundTripped.split("---ACTION-REQUEST---")[0]);
      const block = JSON.parse(after.split("---ACTION-REQUEST---")[1].split("---END-ACTION-REQUEST---")[0]);
      expect(block).toMatchObject({ action_type: "unmerge-request", customer_email: "u@example.com",
        details: { merged_profile_urls: [B], merge_intake: { keep: "prof_1", others: [B, C] } } });
    });

    describe("a request keeping something different is never unioned: both tickets are held", () => {
      const A = "https://credits.muso.ai/profile/aaa";
      const merge = { actionType: "profile-merge", customerEmail: "u@example.com", customerProfileId: "prof_1",
        conversationSummary: "dup profiles" };
      const isFollowUp = (text: string) => text.includes("---ACTION-REQUEST-UPDATE---");
      const conflictTags = (tags: Map<string, string[]>, id: string) =>
        (tags.get(id) ?? []).filter((t) => t.startsWith("merge-keep-conflict")).sort();
      const spoolDir = () => mkdtempSync(join(tmpdir(), "keep-conflict-spool-"));
      const unlimited = { check: () => ({ allowed: true }) } as unknown as RateLimiter;

      it("files its own ticket, tags both merge-keep-conflict naming the sibling, and comments on each", async () => {
        const { http, descriptions, tags, comments } = liveClickup();
        const tool = createCreateTicketTool(makeDeps({ http }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const swapped = await run(tool, { ...merge, summary: "actually keep B",
          details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(swapped).toMatchObject({ submitted: true, ticket_id: "task_2" });
        expect(swapped.updated_existing).toBeUndefined();
        expect(swapped.merge_keep_conflict_flag_failed).toBeUndefined();
        expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(2);
        expect(http.put).not.toHaveBeenCalled();
        expect(intakeOf(descriptions.get("task_1")!)).toMatchObject({ keep: A, others: [B] });
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
        expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
        expect(comments.get("task_1")).toHaveLength(1);
        expect(comments.get("task_1")![0]).toContain("https://app.clickup.com/t/task_2");
        expect(comments.get("task_1")![0]).toContain("close the ticket you reject and remove merge-keep-conflict from the one you keep");
        expect(comments.get("task_2")![0]).toContain("https://app.clickup.com/t/task_1");
        expect([...comments.values()].flat().some(isFollowUp)).toBe(false);

        const sameKeep = await run(tool, { ...merge, summary: "and C", details: { main_profile_url: B,
          duplicate_profile_urls: [A, C] } }, "c3");
        expect(sameKeep).toMatchObject({ ticket_id: "task_2", updated_existing: true });
        expect(conflictTags(tags, "task_2")).toHaveLength(2);
      });

      it("a failed create rolls back only the hold it added, never an existing one", async () => {
        const { http, tags } = liveClickup({ createOk: (n) => n !== 2 && n !== 3 });
        const tool = createCreateTicketTool(makeDeps({ http }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const failed = await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(failed).toMatchObject({ submitted: false, reason: "queue_busy" });
        expect(conflictTags(tags, "task_1")).toEqual([]);

        const { http: http2, tags: tags2 } = liveClickup({ createOk: (n) => n !== 3 });
        const tool2 = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http: http2 }));
        await run(tool2, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        await run(tool2, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(conflictTags(tags2, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
        const third = await run(tool2, { ...merge, summary: "keep C",
          details: { main_profile_url: C, duplicate_profile_urls: [A] } }, "c3");
        expect(third).toMatchObject({ submitted: false, reason: "queue_busy" });
        expect(conflictTags(tags2, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
        expect(conflictTags(tags2, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
        expect(http2.delete).not.toHaveBeenCalled();
      });

      it("flip-back after a reconcile: a closed same-keep ticket does not hide an open conflicting one", async () => {
        const { http, tags, closed } = liveClickup();
        const tool = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        closed.add("task_1");
        tags.set("task_2", (tags.get("task_2") ?? []).filter((t) => t !== "merge-keep-conflict"));
        const before = vi.mocked(http.post).mock.calls.length;
        const flipped = await run(tool, { ...merge, summary: "keep A after all",
          details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c3");
        expect(flipped).toMatchObject({ submitted: true, ticket_id: "task_3" });
        expect(flipped.updated_existing).toBeUndefined();
        expect(conflictTags(tags, "task_3")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
        expect(conflictTags(tags, "task_2")).toEqual(
          ["merge-keep-conflict", "merge-keep-conflict-with:task_1", "merge-keep-conflict-with:task_3"]);
        expect(vi.mocked(http.post).mock.calls.slice(before).some(([u]) => (u as string).includes("/task/task_1/tag/")))
          .toBe(false);
      });

      it("a conflict ticket whose state cannot be read is still tagged, and left held if the create fails", async () => {
        const { http, tags } = liveClickup({ getOk: (id) => id !== "task_1" });
        const tool = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const swapped = await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(swapped).toMatchObject({ submitted: true, ticket_id: "task_2" });
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);

        const dir = spoolDir();
        const failing = liveClickup({ getOk: (id) => id !== "task_1", createOk: (n) => n !== 2 });
        const tool2 = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http: failing.http,
          keepConflictSpoolDir: dir }));
        await run(tool2, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        expect(await run(tool2, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2"))
          .toMatchObject({ submitted: false, reason: "keep_conflict_unflagged", ticket_ids: ["task_1"] });
        expect(conflictTags(failing.tags, "task_1")).toEqual(["merge-keep-conflict"]);
        expect(failing.http.delete).not.toHaveBeenCalled();
        const files = readdirSync(dir);
        expect(files).toHaveLength(1);
        expect(JSON.parse(readFileSync(join(dir, files[0]), "utf8"))).toMatchObject({ left_held: ["task_1"] });
      });

      it("two-conflict rollback: an unreadable ticket stays held and a stranded readable one is spooled with it", async () => {
        const D = "https://credits.muso.ai/profile/ddd";
        const dir = spoolDir();
        let unreadable = false;
        const { http, tags } = liveClickup({ getOk: (id) => !(unreadable && id === "task_1"), createOk: (n) => n !== 3,
          deleteOk: false });
        const tool = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http, keepConflictSpoolDir: dir }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        await run(tool, { ...merge, summary: "keep C", details: { main_profile_url: C, duplicate_profile_urls: [D] } }, "c2");
        unreadable = true;
        const third = await run(tool, { ...merge, summary: "keep B",
          details: { main_profile_url: B, duplicate_profile_urls: [A, C] } }, "c3");
        expect(third).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged" });
        expect([...third.ticket_ids].sort()).toEqual(["task_1", "task_2"]);
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict"]);
        expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict"]);
        const files = readdirSync(dir);
        expect(files).toHaveLength(1);
        const record = JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
        expect([...record.ticket_ids].sort()).toEqual(["task_1", "task_2"]);
        expect([...record.left_held].sort()).toEqual(["task_1", "task_2"]);
      });

      it("a rollback that cannot land after a failed create is spooled (keep_conflict_unflagged)", async () => {
        const dir = spoolDir();
        const { http, tags } = liveClickup({ createOk: (n) => n !== 2, deleteOk: false });
        const tool = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http, keepConflictSpoolDir: dir }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const swapped = await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(swapped).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged", ticket_ids: ["task_1"] });
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict"]);
        const files = readdirSync(dir);
        expect(files).toHaveLength(1);
        const record = JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
        expect(record).toMatchObject({ ticket_ids: ["task_1"], left_held: ["task_1"] });
      });

      it("an unreadable conflict ticket that cannot be tagged files nothing (keep_conflict_unflagged)", async () => {
        const dir = spoolDir();
        const { http } = liveClickup({ getOk: (id) => id !== "task_1", tagOk: (tag) => tag !== "merge-keep-conflict" });
        const tool = createCreateTicketTool(makeDeps({ http, keepConflictSpoolDir: dir }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const swapped = await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(swapped).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged", ticket_ids: ["task_1"] });
        expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(1);
        expect(readdirSync(dir)).toHaveLength(1);
      });

      it("an appended follow-up whose widened intake conflicts with another open ticket holds both", async () => {
        const track = { actionType: "track-merge", customerEmail: "u@example.com", conversationSummary: "dup tracks" };
        const { http, tags, comments } = liveClickup();
        const tool = createCreateTicketTool(makeDeps({ http }));
        await run(tool, { ...track, summary: "T2 into T1",
          details: { track_merge_pairs: [{ master: "t1", duplicates: ["t2"] }] } }, "c1");
        const k = await run(tool, { ...track, summary: "T4 into T3",
          details: { track_merge_pairs: [{ master: "t3", duplicates: ["t4"] }] } }, "c2");
        expect(k).toMatchObject({ submitted: true, ticket_id: "task_2" });
        expect(conflictTags(tags, "task_2")).toEqual([]);
        const widened = await run(tool, { ...track, summary: "also T3 into T1",
          details: { track_merge_pairs: [{ master: "t1", duplicates: ["t2", "t3"] }] } }, "c3");
        expect(widened).toMatchObject({ submitted: true, ticket_id: "task_1", updated_existing: true });
        expect(widened.merge_keep_conflict_flag_failed).toBeUndefined();
        expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(2);
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
        expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
        expect(comments.get("task_2")!.some((c) => c.includes("https://app.clickup.com/t/task_1"))).toBe(true);
        expect(comments.get("task_1")!.some((c) => c.includes("https://app.clickup.com/t/task_2"))).toBe(true);
      });

      describe("a follow-up whose widened intake conflicts but cannot be held widens nothing", () => {
        const track = { actionType: "track-merge", customerEmail: "u@example.com", conversationSummary: "dup tracks" };
        const T1 = { track_merge_pairs: [{ master: "t1", duplicates: ["t2"] }] };
        const T3 = { track_merge_pairs: [{ master: "t3", duplicates: ["t4"] }] };
        const widen = { track_merge_pairs: [{ master: "t1", duplicates: ["t2", "t3"] }] };

        async function widenWith(opts: Parameters<typeof liveClickup>[0]) {
          const dir = spoolDir();
          let failing = false;
          const live = liveClickup({ ...opts,
            tagOk: (tag, attempt, id) => !failing || !opts?.tagOk || opts.tagOk(tag, attempt, id),
            putOk: undefined });
          const put = vi.mocked(live.http.put).getMockImplementation()!;
          vi.mocked(live.http.put).mockImplementation(async (url: string, o: any) =>
            (failing && opts?.putOk === false ? { ok: false, error: "API error", status: 500 } as any : put(url, o)));
          const tool = createCreateTicketTool(makeDeps({ http: live.http, keepConflictSpoolDir: dir,
            sessionKey: "agent:support:intercom:direct:conv88" }));
          await run(tool, { ...track, summary: "T2 into T1", details: T1 }, "c1");
          await run(tool, { ...track, summary: "T4 into T3", details: T3 }, "c2");
          const before = live.descriptions.get("task_1");
          failing = true;
          const result = await run(tool, { ...track, summary: "also T3 into T1", details: widen }, "c3");
          const files = readdirSync(dir);
          expect(files).toHaveLength(1);
          const record = JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
          expect(result).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged", action_type: "track-merge",
            ticket_ids: ["task_1", "task_2"] });
          expect(result.updated_existing).toBeUndefined();
          // The executor works task_1 from its description: it still names only T2.
          expect(live.descriptions.get("task_1")).toBe(before);
          expect(record).toMatchObject({ ticket_ids: ["task_1", "task_2"], conversation_id: "conv88" });
          expect(record.appended).toBeUndefined();
          return { ...live, record };
        }

        it("no hold lands: spooled with nothing left held", async () => {
          const { tags, comments, record } = await widenWith({ tagOk: (tag) => tag !== "merge-keep-conflict" });
          expect(comments.get("task_1")!.some((c) => c.includes("---ACTION-REQUEST-UPDATE---"))).toBe(true);
          expect(conflictTags(tags, "task_1").includes("merge-keep-conflict")).toBe(false);
          expect(conflictTags(tags, "task_2").includes("merge-keep-conflict")).toBe(false);
          expect(record.left_held).toBeUndefined();
        });

        it("a one-sided hold: the sibling that was tagged is spooled as left held", async () => {
          const { tags, record } = await widenWith({ tagOk: (tag, _attempt, id) => id !== "task_1" });
          expect(conflictTags(tags, "task_1")).toEqual([]);
          expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
          expect(record.left_held).toEqual(["task_2"]);
        });

        it("both held but the intake cannot be written: both are spooled as left held", async () => {
          const { tags, record } = await widenWith({ putOk: false });
          expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
          expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
          expect(record.left_held).toEqual(["task_1", "task_2"]);
        });
      });

      it("a pre-tag whose rollback fails after a later tag fails is spooled as left held", async () => {
        const D = "https://credits.muso.ai/profile/ddd";
        const dir = spoolDir();
        let failing = false;
        let first: string | undefined;
        // The first conflict's pre-tag lands; the second one's never does.
        const { http, tags } = liveClickup({ deleteOk: false, tagOk: (tag, _attempt, id) => {
          if (!failing || tag !== "merge-keep-conflict") return true;
          first ??= id;
          return id === first;
        } });
        const tool = createCreateTicketTool(makeDeps({ rateLimiter: unlimited, http, keepConflictSpoolDir: dir }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        await run(tool, { ...merge, summary: "keep C", details: { main_profile_url: C, duplicate_profile_urls: [D] } }, "c2");
        failing = true;
        const third = await run(tool, { ...merge, summary: "keep B",
          details: { main_profile_url: B, duplicate_profile_urls: [A, C] } }, "c3");
        expect(third).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged" });
        expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(2);
        const other = first === "task_1" ? "task_2" : "task_1";
        expect(conflictTags(tags, first!)).toEqual(["merge-keep-conflict"]);
        expect(conflictTags(tags, other)).toEqual([]);
        const files = readdirSync(dir);
        expect(files).toHaveLength(1);
        const record = JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
        expect([...record.ticket_ids].sort()).toEqual(["task_1", "task_2"]);
        expect(record.left_held).toEqual([first]);
      });

      it("retries a failed tag write once and still holds the pair", async () => {
        const { http, tags } = liveClickup({ tagOk: (_tag, attempt) => attempt > 1 });
        const tool = createCreateTicketTool(makeDeps({ http }));
        await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
        const swapped = await run(tool, { ...merge, summary: "keep B", details: { main_profile_url: B, duplicate_profile_urls: [A] } }, "c2");
        expect(swapped).toMatchObject({ submitted: true, ticket_id: "task_2" });
        expect(swapped.merge_keep_conflict_flag_failed).toBeUndefined();
        expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_2"]);
      });

      it("files nothing when the open ticket cannot be tagged twice, and spools one record for #cs_priority", async () => {
        const dir = spoolDir();
        const errors = vi.spyOn(console, "error").mockImplementation(() => {});
        try {
          const { http, tags } = liveClickup({ tagOk: (tag) => tag !== "merge-keep-conflict" });
          const tool = createCreateTicketTool(makeDeps({ http, keepConflictSpoolDir: dir,
            sessionKey: "agent:support:intercom:direct:conv77" }));
          await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
          const swapped = await run(tool, { ...merge, summary: "keep C",
            details: { main_profile_url: C, duplicate_profile_urls: [A] } }, "c2");
          expect(swapped).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged",
            action_type: "profile-merge", ticket_ids: ["task_1"] });
          expect(vi.mocked(http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string))).toHaveLength(1);
          expect(vi.mocked(http.post).mock.calls.filter(([u]) => (u as string).endsWith("/tag/merge-keep-conflict")))
            .toHaveLength(2);
          expect(conflictTags(tags, "task_1")).toEqual([]);
          const files = readdirSync(dir);
          expect(files).toHaveLength(1);
          const record = JSON.parse(readFileSync(join(dir, files[0]), "utf8"));
          expect(record).toMatchObject({ ticket_ids: ["task_1"], conversation_id: "conv77", action_type: "profile-merge" });
          expect(JSON.stringify(record)).not.toContain("keep C");
          expect(errors).not.toHaveBeenCalled();
        } finally {
          errors.mockRestore();
        }
      });

      it("logs one loud line when the spool cannot be written, and still files nothing", async () => {
        const blocker = join(spoolDir(), "a-file");
        writeFileSync(blocker, "x");
        const errors = vi.spyOn(console, "error").mockImplementation(() => {});
        try {
          const { http } = liveClickup({ tagOk: (tag) => tag !== "merge-keep-conflict" });
          const tool = createCreateTicketTool(makeDeps({ http, keepConflictSpoolDir: join(blocker, "spool") }));
          await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
          const swapped = await run(tool, { ...merge, summary: "keep C",
            details: { main_profile_url: C, duplicate_profile_urls: [A] } }, "c2");
          expect(swapped).toMatchObject({ submitted: false, reason: "keep_conflict_unflagged" });
          expect(errors).toHaveBeenCalledTimes(1);
          expect(String(errors.mock.calls[0][0])).toContain("could NOT be held in ClickUp NOR spooled");
        } finally {
          errors.mockRestore();
        }
      });

      it("reports a sibling-tag failure loudly while both tickets stay held", async () => {
        const errors = vi.spyOn(console, "error").mockImplementation(() => {});
        try {
          const { http, tags } = liveClickup({ tagOk: (tag) => !tag.startsWith("merge-keep-conflict-with:") });
          const tool = createCreateTicketTool(makeDeps({ http }));
          await run(tool, { ...merge, summary: "keep A", details: { main_profile_url: A, duplicate_profile_urls: [B] } }, "c1");
          const swapped = await run(tool, { ...merge, summary: "keep C",
            details: { main_profile_url: C, duplicate_profile_urls: [A] } }, "c2");
          expect(swapped).toMatchObject({ submitted: true, ticket_id: "task_2", merge_keep_conflict_flag_failed: true });
          expect(conflictTags(tags, "task_1")).toEqual(["merge-keep-conflict"]);
          expect(conflictTags(tags, "task_2")).toEqual(["merge-keep-conflict", "merge-keep-conflict-with:task_1"]);
          expect(errors).toHaveBeenCalledTimes(1);
          expect(String(errors.mock.calls[0][0])).toContain("pairing incomplete");
        } finally {
          errors.mockRestore();
        }
      });

      it("track-merge compares every pair: a reversed second pair is held, a consistent new pair is unioned", async () => {
        const track = { actionType: "track-merge", customerEmail: "u@example.com", conversationSummary: "dup tracks" };
        const pairs = (...ps: Array<[string, string]>) => ({ track_merge_pairs: ps.map(([master, dup]) => ({ master, duplicates: [dup] })) });
        const { http, descriptions, tags } = liveClickup();
        const tool = createCreateTicketTool(makeDeps({ http }));
        await run(tool, { ...track, summary: "T1<-T2, T3<-T4", details: pairs(["t1", "t2"], ["t3", "t4"]) }, "c1");
        const reversed = await run(tool, { ...track, summary: "keep T4 instead",
          details: pairs(["t1", "t2"], ["t4", "t3"]) }, "c2");
        expect(reversed).toMatchObject({ submitted: true, ticket_id: "task_2" });
        expect(reversed.updated_existing).toBeUndefined();
        expect(conflictTags(tags, "task_1")).toContain("merge-keep-conflict");
        expect(conflictTags(tags, "task_2")).toContain("merge-keep-conflict");
        expect(intakeOf(descriptions.get("task_1")!).pairs).toEqual([{ keep: "t1", others: ["t2"] }, { keep: "t3", others: ["t4"] }]);

        const consistent = await run(tool, { ...track, summary: "T3<-T5 too", details: pairs(["t3", "t5"]) }, "c3");
        expect(consistent).toMatchObject({ ticket_id: "task_1", updated_existing: true });
        expect(intakeOf(descriptions.get("task_1")!).pairs)
          .toEqual([{ keep: "t1", others: ["t2"] }, { keep: "t3", others: ["t4", "t5"] }]);
      });
    });
  });

  describe("rights_holder cross-conversation dedupe", () => {
    const openLookup = () => vi.fn(async () => ({
      ok: true,
      data: { tasks: [
        { id: "open_rh", status: { status: "to do" }, date_created: String(Date.now() - 1000), custom_fields: [{ id: "ef", value: "u@example.com" }] },
      ] } as any,
    }));
    const taskPosts = (deps: ReturnType<typeof makeDeps>) =>
      vi.mocked(deps.http.post).mock.calls.filter(([u]) => TASK_URL_RE.test(u as string));
    const commentPosts = (deps: ReturnType<typeof makeDeps>) =>
      vi.mocked(deps.http.post).mock.calls.filter(([u]) => COMMENT_URL_RE.test(u as string));

    it("opens its own record instead of appending to another matter's open ticket", async () => {
      const deps = makeDeps({ http: makeHttp({ get: openLookup() }) });
      const tool = createCreateTicketTool(deps);
      const result = await run(tool, { ...CLAIM, details: { escalation_reason: "rights_holder" } });
      expect(result.submitted).toBe(true);
      expect(result.updated_existing).toBeUndefined();
      expect(taskPosts(deps)).toHaveLength(1);
      expect(commentPosts(deps)).toHaveLength(0);
    });

    it("still appends the same shape without rights_holder", async () => {
      const deps = makeDeps({ http: makeHttp({ get: openLookup() }) });
      const tool = createCreateTicketTool(deps);
      const result = await run(tool, { ...CLAIM, details: { escalation_reason: "sla_breach_customer_followup" } });
      expect(result).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "open_rh" });
      expect(taskPosts(deps)).toHaveLength(0);
    });

    it("keeps the in-session repeat append for rights_holder", async () => {
      const deps = makeDeps();
      const tool = createCreateTicketTool(deps);
      const details = { escalation_reason: "rights_holder" };
      await run(tool, { ...CLAIM, details }, "c1");
      const second = await run(tool, { ...CLAIM, details }, "c2");
      expect(second).toMatchObject({ submitted: true, updated_existing: true, ticket_id: "task_1" });
      expect(taskPosts(deps)).toHaveLength(1);
    });
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

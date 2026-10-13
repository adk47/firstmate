import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreditsSearchTool, filterCreditsResults } from "../src/tools/credits-search.js";
import type { MusoAdminClient } from "../src/muso-admin-client.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("filterCreditsResults", () => {
  it("maps admin-shape items (title at item level, no nested track)", () => {
    const raw = {
      totalCount: 100,
      hasMoreToLoad: true,
      items: [
        {
          credits: ["Producer"],
          title: "God's Plan",
          releaseDate: "2018-06-29",
          artists: [{ name: "Drake" }],
        },
      ],
    };
    const filtered = filterCreditsResults(raw);
    expect(filtered).toEqual({
      totalCount: 100,
      hasMore: true,
      credits: [
        {
          creditRoles: ["Producer"],
          trackTitle: "God's Plan",
          albumTitle: "",
          releaseDate: "2018-06-29",
          artists: ["Drake"],
        },
      ],
    });
  });

  it("handles credits as object with child property", () => {
    const raw = {
      totalCount: 1,
      hasMoreToLoad: false,
      items: [
        {
          credits: [{ child: "Songwriter", parent: "Writing" }],
          title: "Test Song",
          releaseDate: "2024-01-01",
          artists: [],
        },
      ],
    };
    const filtered = filterCreditsResults(raw);
    expect(filtered.credits[0].creditRoles).toEqual(["Songwriter"]);
    expect(filtered.credits[0].albumTitle).toBe("");
  });

  it("handles empty items", () => {
    const filtered = filterCreditsResults({ totalCount: 0, hasMoreToLoad: false, items: [] });
    expect(filtered).toEqual({ totalCount: 0, hasMore: false, credits: [] });
  });

  it("falls back to items.length when totalCount is absent (admin endpoint shape)", () => {
    const raw = {
      hasMoreToLoad: false,
      items: [
        { credits: ["Producer"], title: "Track A", releaseDate: "2024-01-01", artists: [{ name: "X" }] },
        { credits: ["Mixing"], title: "Track B", releaseDate: "2024-02-01", artists: [] },
      ],
    };
    const filtered = filterCreditsResults(raw);
    expect(filtered.totalCount).toBe(2);
  });

  it("normalizes total/limit/offset pagination from the admin endpoint", () => {
    const raw = {
      total: 17,
      limit: 1,
      offset: 0,
      items: [
        { credits: ["Producer"], title: "Track A", releaseDate: "2024-01-01", artists: [{ name: "X" }] },
      ],
    };

    const filtered = filterCreditsResults(raw);

    expect(filtered.totalCount).toBe(17);
    expect(filtered.hasMore).toBe(true);
    expect(filterCreditsResults({ ...raw, offset: 16 }).hasMore).toBe(false);
  });
});

describe("createCreditsSearchTool", () => {
  let mockAdminClient: MusoAdminClient;
  let limiter: RateLimiter;

  beforeEach(() => {
    mockAdminClient = { get: vi.fn() };
    limiter = new RateLimiter();
  });

  it("calls admin credits endpoint with profileId", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({
      ok: true,
      status: 200,
      data: {
        data: {
          totalCount: 1,
          hasMoreToLoad: false,
          items: [
            { credits: ["Producer"], title: "Song", releaseDate: "2024-01-01", artists: [{ name: "Artist" }] },
          ],
        },
      },
    });

    const tool = createCreditsSearchTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { profileId: "prof_123", keyword: "Song", limit: 5 });

    const path = vi.mocked(mockAdminClient.get).mock.calls[0][0];
    expect(path).toContain("/api/v3/admin/profile/prof_123/credits");
    expect(path).toContain("keyword=Song");
    expect(path).toContain("limit=5");
  });

  it("returns structured JSON with ok:true and empty credits array for empty results", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({
      ok: true,
      status: 200,
      data: { data: { totalCount: 0, hasMoreToLoad: false, items: [] } },
    });

    const tool = createCreditsSearchTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { profileId: "prof_123" });
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed).toEqual({ ok: true, totalCount: 0, hasMore: false, credits: [] });
  });

  it("returns structured JSON with ok:false reason:lookup_unavailable on admin client failure", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({ ok: false, status: 500, error: "API error" });

    const tool = createCreditsSearchTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { profileId: "prof_123" });
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed).toEqual({ ok: false, reason: "lookup_unavailable" });
  });

  it("returns structured JSON with ok:true and credits on success", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({
      ok: true,
      status: 200,
      data: {
        data: {
          totalCount: 1,
          hasMoreToLoad: false,
          items: [
            { credits: ["Producer"], title: "Song", releaseDate: "2024-01-01", artists: [{ name: "Artist" }] },
          ],
        },
      },
    });

    const tool = createCreditsSearchTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { profileId: "prof_123" });
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed.ok).toBe(true);
    expect(parsed.totalCount).toBe(1);
    expect(parsed.credits).toHaveLength(1);
    expect(parsed.credits[0].trackTitle).toBe("Song");
  });

  it("returns structured JSON with ok:false reason:rate_limited when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 10; i++) {
      strictLimiter.check("session-1", "credits_search", 1, 10);
    }

    const tool = createCreditsSearchTool({
      adminClient: mockAdminClient,
      rateLimiter: strictLimiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { profileId: "prof_123" });
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed).toEqual({ ok: false, reason: "rate_limited" });
    expect(mockAdminClient.get).not.toHaveBeenCalled();
  });
});

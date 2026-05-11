import { describe, it, expect, vi, beforeEach } from "vitest";
import { createProfileLookupTool, filterProfileResults, extractProfileIdFromUrl } from "../src/tools/profile-lookup.js";
import type { MusoAdminClient } from "../src/muso-admin-client.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("extractProfileIdFromUrl", () => {
  it("extracts profile ID from muso.ai profile URL", () => {
    expect(extractProfileIdFromUrl("https://app.muso.ai/profile/abc-123-def")).toBe("abc-123-def");
  });

  it("extracts profile ID from muso.ai URL with trailing slash", () => {
    expect(extractProfileIdFromUrl("https://app.muso.ai/profile/abc-123-def/")).toBe("abc-123-def");
  });

  it("extracts profile ID from muso.ai URL with query params", () => {
    expect(extractProfileIdFromUrl("https://app.muso.ai/profile/abc-123-def?tab=credits")).toBe("abc-123-def");
  });

  it("returns null for non-profile URLs", () => {
    expect(extractProfileIdFromUrl("https://muso.ai/pricing")).toBeNull();
  });

  it("returns null for non-URL strings", () => {
    expect(extractProfileIdFromUrl("Drake")).toBeNull();
  });
});

describe("filterProfileResults", () => {
  it("strips internal fields and keeps only public data (admin shape: isClaimed)", () => {
    const raw = [
      {
        id: "prof_123",
        name: "Drake",
        type: "artist",
        isClaimed: true,
        creditCount: 500,
        spotifyId: "spotify:abc",
        email: "drake@example.com",
        avatarUrl: "https://cdn.muso.ai/avatar.jpg",
        popularity: 95,
        internalId: "internal_xyz",
      },
    ];
    const filtered = filterProfileResults(raw);
    expect(filtered).toEqual([
      {
        profileId: "prof_123",
        name: "Drake",
        type: "artist",
        verified: true,
        creditsCount: 500,
      },
    ]);
  });

  it("falls back to verified field when isClaimed is absent", () => {
    const raw = [{ id: "x", name: "Y", type: "artist", verified: true, creditCount: 1 }];
    const filtered = filterProfileResults(raw);
    expect(filtered[0].verified).toBe(true);
  });

  it("handles empty results", () => {
    expect(filterProfileResults([])).toEqual([]);
  });
});

describe("createProfileLookupTool", () => {
  let mockAdminClient: MusoAdminClient;
  let limiter: RateLimiter;

  beforeEach(() => {
    mockAdminClient = {
      get: vi.fn(),
    };
    limiter = new RateLimiter();
  });

  it("calls admin profile/search endpoint for name queries", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({
      ok: true,
      status: 200,
      data: { data: [{ id: "prof_1", name: "Drake", type: "artist", isClaimed: true, creditCount: 200 }] },
    });

    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });

    expect(mockAdminClient.get).toHaveBeenCalledWith(
      "/api/v3/admin/profile/search?keyword=Drake&limit=5",
    );
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Drake") });
  });

  it("returns structured JSON with ok:false reason:rate_limited when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 10; i++) {
      strictLimiter.check("session-1", "profile_lookup", 1, 10);
    }

    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: strictLimiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });
    const parsed = JSON.parse((result.content[0] as any).text);

    expect(parsed).toEqual({ ok: false, reason: "rate_limited" });
    expect(mockAdminClient.get).not.toHaveBeenCalled();
  });

  it("returns structured JSON with ok:true and empty profiles array when admin search returns no results", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({ ok: true, status: 200, data: { data: [] } });

    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "xyznonexistent" });
    const parsed = JSON.parse((result.content[0] as any).text);

    expect(parsed).toEqual({ ok: true, profiles: [], count: 0 });
  });

  it("returns structured JSON with ok:false reason:lookup_unavailable on admin client failure", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({ ok: false, status: 500, error: "API error" });

    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });
    const parsed = JSON.parse((result.content[0] as any).text);

    expect(parsed).toEqual({ ok: false, reason: "lookup_unavailable" });
  });

  it("extracts profile ID from URL without calling admin client", async () => {
    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "https://app.muso.ai/profile/abc-123" });

    expect(mockAdminClient.get).not.toHaveBeenCalled();
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed.ok).toBe(true);
    expect(parsed.profileId).toBe("abc-123");
  });

  it("output shape has ok:true + profileId/name/type/verified/creditsCount (agent-facing contract)", async () => {
    vi.mocked(mockAdminClient.get).mockResolvedValue({
      ok: true,
      status: 200,
      data: { data: [{ id: "p1", name: "Rihanna", type: "artist", isClaimed: false, creditCount: 99 }] },
    });

    const tool = createProfileLookupTool({
      adminClient: mockAdminClient,
      rateLimiter: limiter,
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Rihanna" });
    const parsed = JSON.parse((result.content[0] as any).text);
    expect(parsed.ok).toBe(true);
    expect(parsed.count).toBe(1);
    expect(parsed.profiles[0]).toEqual({
      profileId: "p1",
      name: "Rihanna",
      type: "artist",
      verified: false,
      creditsCount: 99,
    });
  });
});

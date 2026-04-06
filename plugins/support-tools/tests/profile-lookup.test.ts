import { describe, it, expect, vi, beforeEach } from "vitest";
import { createProfileLookupTool, filterProfileResults, extractProfileIdFromUrl } from "../src/tools/profile-lookup.js";
import type { HttpClient } from "../src/http.js";
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
  it("strips internal fields and keeps only public data", () => {
    const raw = [
      {
        id: "prof_123",
        name: "Drake",
        type: "artist",
        verified: true,
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

  it("handles empty results", () => {
    expect(filterProfileResults([])).toEqual([]);
  });
});

describe("createProfileLookupTool", () => {
  let mockClient: HttpClient;
  let limiter: RateLimiter;

  beforeEach(() => {
    mockClient = {
      get: vi.fn(),
      post: vi.fn(),
    };
    limiter = new RateLimiter();
  });

  it("calls autocomplete endpoint for name queries", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({
      ok: true,
      data: { results: [{ id: "prof_1", name: "Drake", type: "artist", verified: true, creditCount: 200 }] },
    });

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: limiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });

    expect(mockClient.get).toHaveBeenCalledWith(
      "https://api.muso.ai/api/c/v5/search/autocomplete?q=Drake&types=profiles&limit=5",
      { headers: { "x-api-key": "test-key" } },
    );
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Drake") });
  });

  it("falls back to full search when autocomplete returns 0 results", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: true, data: { results: [] } });
    vi.mocked(mockClient.post).mockResolvedValue({
      ok: true,
      data: { results: [{ id: "prof_1", name: "Drakeo The Ruler", type: "artist", verified: false, creditCount: 50 }] },
    });

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: limiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drakeo" });

    expect(mockClient.post).toHaveBeenCalledWith(
      "https://api.muso.ai/api/c/v5/search",
      {
        headers: { "x-api-key": "test-key" },
        body: { keyword: "Drakeo", type: ["profile"], limit: 10 },
      },
    );
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Drakeo The Ruler") });
  });

  it("returns error message when rate limited", async () => {
    const strictLimiter = new RateLimiter();
    for (let i = 0; i < 10; i++) {
      strictLimiter.check("session-1", "profile_lookup", 1, 10);
    }

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: strictLimiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });

    expect(result.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining("Too many profile lookups"),
    });
    expect(mockClient.get).not.toHaveBeenCalled();
  });

  it("returns no-results message when both endpoints return empty", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: true, data: { results: [] } });
    vi.mocked(mockClient.post).mockResolvedValue({ ok: true, data: { results: [] } });

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: limiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "xyznonexistent" });

    expect(result.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining("No profiles found"),
    });
  });

  it("returns error when fallback search also fails", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: true, data: { results: [] } });
    vi.mocked(mockClient.post).mockResolvedValue({ ok: false, error: "API error", status: 500 });

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: limiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drakeo" });

    expect(result.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining("Unable to look up profiles"),
    });
  });

  it("returns error message on API failure", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: false, error: "API error", status: 500 });

    const tool = createProfileLookupTool({
      http: mockClient,
      rateLimiter: limiter,
      musoApiBase: "https://api.muso.ai",
      musoApiKey: "test-key",
      sessionId: "session-1",
    });

    const result = await tool.execute("call_1", { query: "Drake" });

    expect(result.content[0]).toEqual({
      type: "text",
      text: expect.stringContaining("Unable to look up profiles"),
    });
  });
});

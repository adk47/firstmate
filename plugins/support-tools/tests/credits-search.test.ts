import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreditsSearchTool, filterCreditsResults } from "../src/tools/credits-search.js";
import type { HttpClient } from "../src/http.js";
import { RateLimiter } from "../src/rate-limiter.js";

describe("filterCreditsResults", () => {
  it("strips internal fields and keeps only public credit data", () => {
    const raw = {
      totalCount: 100,
      hasMoreToLoad: true,
      items: [
        {
          credits: [{ child: "Producer", parent: "Production" }],
          track: { id: "track_abc", title: "God's Plan", spotifyId: "spotify_123", popularity: 95, previewUrl: "https://preview.url" },
          album: { id: "album_def", title: "Scorpion", albumArt: "https://art.url" },
          releaseDate: "2018-06-29",
          artists: [{ id: "artist_ghi", name: "Drake" }],
        },
      ],
    };
    const filtered = filterCreditsResults(raw);
    expect(filtered).toEqual({
      totalCount: 100, hasMore: true,
      credits: [{ creditRoles: ["Producer"], trackTitle: "God's Plan", albumTitle: "Scorpion", releaseDate: "2018-06-29", artists: ["Drake"] }],
    });
  });

  it("handles credits as plain strings", () => {
    const raw = { totalCount: 1, hasMoreToLoad: false, items: [{ credits: ["Songwriter"], track: { title: "Test Song" }, album: { title: "Test Album" }, releaseDate: "2024-01-01", artists: [] }] };
    const filtered = filterCreditsResults(raw);
    expect(filtered.credits[0].creditRoles).toEqual(["Songwriter"]);
  });

  it("handles empty items", () => {
    const filtered = filterCreditsResults({ totalCount: 0, hasMoreToLoad: false, items: [] });
    expect(filtered).toEqual({ totalCount: 0, hasMore: false, credits: [] });
  });
});

describe("createCreditsSearchTool", () => {
  let mockClient: HttpClient;
  let limiter: RateLimiter;

  beforeEach(() => {
    mockClient = { get: vi.fn(), post: vi.fn() };
    limiter = new RateLimiter();
  });

  it("calls credits endpoint with profileId and optional filters", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({
      ok: true,
      data: { totalCount: 1, hasMoreToLoad: false, items: [{ credits: ["Producer"], track: { title: "Song" }, album: { title: "Album" }, releaseDate: "2024-01-01", artists: [{ name: "Artist" }] }] },
    });
    const tool = createCreditsSearchTool({ http: mockClient, rateLimiter: limiter, musoApiBase: "https://api.muso.ai", musoApiKey: "test-key", sessionId: "session-1" });
    const result = await tool.execute("call_1", { profileId: "prof_123", keyword: "Song", limit: 5 });
    expect(mockClient.get).toHaveBeenCalledWith(expect.stringContaining("api.muso.ai/api/c/v4/profile/prof_123/credits"), { headers: { "x-api-key": "test-key" } });
    const url = vi.mocked(mockClient.get).mock.calls[0][0];
    expect(url).toContain("keyword=Song");
    expect(url).toContain("limit=5");
  });

  it("returns no-credits message for empty results", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: true, data: { totalCount: 0, hasMoreToLoad: false, items: [] } });
    const tool = createCreditsSearchTool({ http: mockClient, rateLimiter: limiter, musoApiBase: "https://api.muso.ai", musoApiKey: "test-key", sessionId: "session-1" });
    const result = await tool.execute("call_1", { profileId: "prof_123" });
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("No credits found") });
  });

  it("returns error message on API failure", async () => {
    vi.mocked(mockClient.get).mockResolvedValue({ ok: false, error: "API error", status: 500 });
    const tool = createCreditsSearchTool({ http: mockClient, rateLimiter: limiter, musoApiBase: "https://api.muso.ai", musoApiKey: "test-key", sessionId: "session-1" });
    const result = await tool.execute("call_1", { profileId: "prof_123" });
    expect(result.content[0]).toEqual({ type: "text", text: expect.stringContaining("Unable to search credits") });
  });
});

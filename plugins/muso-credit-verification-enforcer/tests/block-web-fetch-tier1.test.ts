import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { blockWebFetchTier1 } from "../src/hooks/block-web-fetch-tier1.js";
import { cvSessions } from "../src/state.js";

const buildCtx = (overrides: Partial<{ sessionKey: string; runId: string }> = {}) => ({
  toolName: "web_fetch",
  sessionKey: overrides.sessionKey,
  runId: overrides.runId,
});

describe("blockWebFetchTier1", () => {
  beforeEach(() => {
    cvSessions.clear();
  });
  afterEach(() => {
    cvSessions.clear();
  });

  it("blocks web_fetch to open.spotify.com in CV context", () => {
    cvSessions.add("s-A");
    const r = blockWebFetchTier1(
      { toolName: "web_fetch", params: { url: "https://open.spotify.com/artist/abc" } },
      buildCtx({ sessionKey: "s-A" }),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/Tier 1/);
    expect(r?.blockReason).toMatch(/browser/);
  });

  it("blocks each Tier 1 host", () => {
    cvSessions.add("s-A");
    const hosts = [
      "https://open.spotify.com/artist/a",
      "https://music.apple.com/us/artist/a/123",
      "https://musicbrainz.org/artist/abc",
      "https://discogs.com/artist/abc",
      "https://allmusic.com/artist/abc",
      "https://tidal.com/browse/artist/123",
    ];
    for (const url of hosts) {
      const r = blockWebFetchTier1(
        { toolName: "web_fetch", params: { url } },
        buildCtx({ sessionKey: "s-A" }),
      );
      expect(r?.block, `should block ${url}`).toBe(true);
    }
  });

  it("tolerates a leading www. on Tier 1 hosts", () => {
    cvSessions.add("s-A");
    const r = blockWebFetchTier1(
      { toolName: "web_fetch", params: { url: "https://www.allmusic.com/artist/xyz" } },
      buildCtx({ sessionKey: "s-A" }),
    );
    expect(r?.block).toBe(true);
  });

  it("does NOT block web_fetch to non-Tier-1 hosts in CV context", () => {
    // Artist websites, WHOIS, non-JS blogs etc. are still legitimate fetches.
    cvSessions.add("s-A");
    const nonTier1 = [
      "https://jaxsta.com/profile/xyz",
      "https://arrowsmith.me",
      "https://bandcamp.com/artist/abc",
      "https://linkedin.com/in/abc",
    ];
    for (const url of nonTier1) {
      const r = blockWebFetchTier1(
        { toolName: "web_fetch", params: { url } },
        buildCtx({ sessionKey: "s-A" }),
      );
      expect(r, `should NOT block ${url}`).toBeUndefined();
    }
  });

  it("does not block web_fetch outside CV context (no sessionKey in CV set, no runId)", () => {
    const r = blockWebFetchTier1(
      { toolName: "web_fetch", params: { url: "https://open.spotify.com/artist/abc" } },
      buildCtx({ sessionKey: "s-A" }),
    );
    expect(r).toBeUndefined();
  });

  it("blocks in a run-scoped CV context (runId alone marks a CV session)", () => {
    // Batch mode sessions get runId set; isCreditVerificationSession treats that
    // as CV regardless of whether sessionKey was marked.
    const r = blockWebFetchTier1(
      { toolName: "web_fetch", params: { url: "https://musicbrainz.org/search?query=x" } },
      buildCtx({ runId: "20260422-101649-e8ded0" }),
    );
    expect(r?.block).toBe(true);
  });

  it("does not block other tools (passthrough)", () => {
    cvSessions.add("s-A");
    const r = blockWebFetchTier1(
      { toolName: "browser", params: { url: "https://open.spotify.com/artist/abc" } },
      { toolName: "browser", sessionKey: "s-A" },
    );
    expect(r).toBeUndefined();
  });

  it("does not block web_fetch when URL is missing or malformed", () => {
    cvSessions.add("s-A");
    expect(
      blockWebFetchTier1({ toolName: "web_fetch", params: {} }, buildCtx({ sessionKey: "s-A" })),
    ).toBeUndefined();
    expect(
      blockWebFetchTier1(
        { toolName: "web_fetch", params: { url: "not a url" } },
        buildCtx({ sessionKey: "s-A" }),
      ),
    ).toBeUndefined();
    expect(
      blockWebFetchTier1(
        { toolName: "web_fetch", params: { url: 123 as unknown as string } },
        buildCtx({ sessionKey: "s-A" }),
      ),
    ).toBeUndefined();
  });
});

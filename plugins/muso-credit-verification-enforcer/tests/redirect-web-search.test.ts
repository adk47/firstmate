import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { redirectWebSearch } from "../src/hooks/redirect-web-search.js";
import { cvSessions } from "../src/state.js";

const buildCtx = (overrides: Partial<{ sessionKey: string; runId: string }> = {}) => ({
  toolName: "web_search",
  sessionKey: overrides.sessionKey,
  runId: overrides.runId,
});

describe("redirectWebSearch", () => {
  beforeEach(() => {
    cvSessions.clear();
  });
  afterEach(() => {
    cvSessions.clear();
  });

  it("blocks web_search in CV context with a clear blockReason", () => {
    cvSessions.add("s-A");
    const r = redirectWebSearch(
      { toolName: "web_search", params: { query: "foo" } },
      buildCtx({ sessionKey: "s-A" }),
    );
    expect(r?.block).toBe(true);
    expect(r?.blockReason).toMatch(/web_search is disabled for credit verification/);
    expect(r?.blockReason).toMatch(/duckduckgo\.com\/\?q=/);
    expect(r?.blockReason).toMatch(/Step 3 grounding rule/);
  });

  it("does not block web_search outside CV context", () => {
    const r = redirectWebSearch(
      { toolName: "web_search", params: { query: "foo" } },
      buildCtx({ sessionKey: "s-A" }),
    );
    expect(r).toBeUndefined();
  });

  it("does not block other tools in CV context", () => {
    cvSessions.add("s-A");
    expect(
      redirectWebSearch(
        { toolName: "browser", params: { url: "https://x" } },
        { toolName: "browser", sessionKey: "s-A" },
      ),
    ).toBeUndefined();
    expect(
      redirectWebSearch(
        { toolName: "exec", params: { command: "ls" } },
        { toolName: "exec", sessionKey: "s-A" },
      ),
    ).toBeUndefined();
  });

  it("respects runId on ctx as CV context signal (batch mode)", () => {
    const r = redirectWebSearch(
      { toolName: "web_search", params: { query: "foo" } },
      buildCtx({ runId: "run-1" }),
    );
    expect(r?.block).toBe(true);
  });
});

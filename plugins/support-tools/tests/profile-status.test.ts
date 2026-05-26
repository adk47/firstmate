import { describe, it, expect, vi } from "vitest";
import { createProfileStatusTool } from "../src/tools/profile-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";

function makeAdminClient(overrides: Partial<MusoAdminClient> = {}): MusoAdminClient {
  return {
    get: vi.fn(async () => ({ ok: true, status: 200, data: {} })) as MusoAdminClient["get"],
    ...overrides,
  };
}

function makeDeps(overrides: Partial<Parameters<typeof createProfileStatusTool>[0]> = {}) {
  return {
    adminClient: makeAdminClient(),
    rateLimiter: new RateLimiter(),
    sessionId: "sess-1",
    ...overrides,
  };
}

async function call(tool: ReturnType<typeof createProfileStatusTool>, params: Record<string, unknown>) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as any).text as string);
}

describe("profile_status", () => {
  it("returns found:true with bundled fields on happy path", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/search")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: [
                { id: "p1", name: "Aasis Beats", type: "profile", isClaimed: true, creditCount: 142, commonCredits: ["Producer"] },
              ],
            },
          } as AdminClientResult<unknown>;
        }
        if (path.includes("/profile/p1/credits")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: {
                items: [
                  { credits: ["Producer"], title: "Track A", releaseDate: "2026-05-08", artists: [{ name: "X" }] },
                  { credits: ["Producer"], title: "Track B", releaseDate: "2026-04-30", artists: [{ name: "Y" }] },
                  { credits: ["Producer"], title: "Track C", releaseDate: "2026-05-02", artists: [{ name: "Z" }] },
                ],
                totalCount: 3,
                hasMoreToLoad: false,
              },
            },
          } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });

    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "Aasis Beats" });
    expect(out.found).toBe(true);
    expect(out.profile).toEqual({
      id: "p1",
      name: "Aasis Beats",
      verified: true,
      isClaimed: true,
      primary_role: "Producer",
      credits_count: 142,
      workspaces: [],
      knownAsNames: [],
    });
    // sorted by releaseDate desc: A (May 8), C (May 2), B (Apr 30)
    expect(out.latest_credits.map((c: any) => c.track)).toEqual(["Track A", "Track C", "Track B"]);
    expect(out.latest_credit_date).toBe("2026-05-08");
  });

  it("exposes workspaces[] and knownAsNames for ownership-check (customer-credit-removal)", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/p9/credits")) {
          return {
            ok: true,
            status: 200,
            data: { data: { items: [], totalCount: 0, hasMoreToLoad: false } },
          } as AdminClientResult<unknown>;
        }
        if (path.includes("/profile/p9")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: {
                id: "p9",
                name: "Achille G",
                isClaimed: true,
                commonCredits: ["Producer"],
                creditCount: 17,
                knownAsNames: ["Achille G", "Achille"],
                workspaces: [
                  { isClaimed: true, email: "owner@example.com" },
                  { isClaimed: false, email: "other@example.com" },
                ],
              },
            },
          } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { profile_id: "p9" });
    expect(out.found).toBe(true);
    expect(out.profile.isClaimed).toBe(true);
    expect(out.profile.knownAsNames).toEqual(["Achille G", "Achille"]);
    expect(out.profile.workspaces).toEqual([
      { email: "owner@example.com", isClaimed: true },
      { email: "other@example.com", isClaimed: false },
    ]);
  });

  it("returns no_match when search returns empty data array", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async () => ({ ok: true, status: 200, data: { data: [] } })) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "nobody" });
    expect(out).toEqual({ found: false, reason: "no_match" });
  });

  it("returns multiple_matches with top-3 names", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async () => ({
        ok: true,
        status: 200,
        data: {
          data: [
            { id: "a", name: "John Smith" },
            { id: "b", name: "John Smithson" },
            { id: "c", name: "John A. Smith" },
            { id: "d", name: "John Smyth" },
          ],
        },
      })) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "John Smith" });
    expect(out).toEqual({
      found: false,
      reason: "multiple_matches",
      matches: ["John Smith", "John Smithson", "John A. Smith"],
    });
  });

  it("returns lookup_unavailable on upstream 5xx", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async () => ({ ok: false, status: 500, error: "x" })) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "Aasis" });
    expect(out).toEqual({ found: false, reason: "lookup_unavailable" });
  });

  it("returns missing_input when no identifier provided", async () => {
    const tool = createProfileStatusTool(makeDeps());
    const out = await call(tool, {});
    expect(out).toEqual({ found: false, reason: "missing_input" });
  });

  it("returns rate_limited when session cap exceeded", async () => {
    const deps = makeDeps({
      adminClient: makeAdminClient({
        get: vi.fn(async () => ({ ok: true, status: 200, data: { data: [] } })) as MusoAdminClient["get"],
      }),
    });
    const tool = createProfileStatusTool(deps);
    for (let i = 0; i < 10; i++) await call(tool, { name: "X" });
    const out = await call(tool, { name: "X" });
    expect(out).toEqual({ found: false, reason: "rate_limited" });
  });

  it("never throws — always returns structured JSON", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async () => { throw new Error("network exploded"); }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "Aasis" });
    expect(out.found).toBe(false);
    expect(out.reason).toBe("lookup_unavailable");
  });

  it("accepts profile_url and extracts UUID", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37/credits")) {
          return {
            ok: true,
            status: 200,
            data: { data: { items: [], totalCount: 0, hasMoreToLoad: false } },
          } as AdminClientResult<unknown>;
        }
        if (path.includes("/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: {
                id: "90b6866c-7026-458e-a1af-48b1c1ac1c37",
                name: "Aasis",
                isClaimed: false,
                commonCredits: ["Producer"],
                creditCount: 0,
              },
            },
          } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: { data: [] } } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, {
      profile_url: "https://credits.muso.ai/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37",
    });
    expect(out.found).toBe(true);
    expect(out.profile.id).toBe("90b6866c-7026-458e-a1af-48b1c1ac1c37");
  });

  it("PII filter: never echoes email or phone in output", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/search")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: [
                { id: "p1", name: "User", isClaimed: false, creditCount: 0, email: "u@example.com", phone: "+1234" },
              ],
            },
          } as AdminClientResult<unknown>;
        }
        // credits endpoint
        return {
          ok: true,
          status: 200,
          data: { data: { items: [], totalCount: 0, hasMoreToLoad: false } },
        } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "User" });
    const json = JSON.stringify(out);
    expect(json).not.toMatch(/u@example\.com|\+1234/);
  });

  it("falls back to credits-only when bare profile endpoint fails", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.match(/\/profile\/p1$/) || path.match(/\/profile\/p1\?/)) {
          return { ok: false, status: 404, error: "Not Found" } as AdminClientResult<unknown>;
        }
        if (path.includes("/profile/p1/credits")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: {
                items: [
                  { credits: ["Producer"], title: "T", releaseDate: "2026-05-08", artists: [] },
                ],
                totalCount: 1,
                hasMoreToLoad: false,
              },
            },
          } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { profile_id: "p1" });
    expect(out.found).toBe(true);
    expect(out.profile.id).toBe("p1");
    expect(out.profile.name).toBe(""); // bare endpoint unavailable
    expect(out.latest_credits).toHaveLength(1);
    expect(out.latest_credit_date).toBe("2026-05-08");
  });

  it("input precedence: profile_id > profile_url > email > name", async () => {
    const get = vi.fn(async (path: string) => {
      if (path.includes("/EXPECTED/credits")) {
        return { ok: true, status: 200, data: { data: { items: [], totalCount: 0 } } } as AdminClientResult<unknown>;
      }
      if (path.includes("/EXPECTED")) {
        return {
          ok: true,
          status: 200,
          data: { data: { id: "EXPECTED", name: "Z", isClaimed: false, commonCredits: ["X"], creditCount: 0 } },
        } as AdminClientResult<unknown>;
      }
      return { ok: false, status: 404, error: "x" } as AdminClientResult<unknown>;
    }) as MusoAdminClient["get"];

    const tool = createProfileStatusTool(makeDeps({ adminClient: makeAdminClient({ get }) }));
    const out = await call(tool, {
      profile_id: "EXPECTED",
      profile_url: "https://credits.muso.ai/profile/SHOULD_NOT_USE",
      email: "x@x.com",
      name: "Z",
    });
    expect(out.found).toBe(true);
    expect(out.profile.id).toBe("EXPECTED");
  });

  it("primary_role uses commonCredits[0] from admin endpoint", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/p1/credits")) {
          return {
            ok: true,
            status: 200,
            data: { data: { items: [], totalCount: 0, hasMoreToLoad: false } },
          } as AdminClientResult<unknown>;
        }
        if (path.includes("/profile/p1")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: {
                id: "p1",
                name: "X",
                isClaimed: true,
                commonCredits: ["Mixing Engineer", "Producer"],
                creditCount: 5,
              },
            },
          } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { profile_id: "p1" });
    expect(out.profile.primary_role).toBe("Mixing Engineer");
    expect(out.profile.verified).toBe(true);
  });
});

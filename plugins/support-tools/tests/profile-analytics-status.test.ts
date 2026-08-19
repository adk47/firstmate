import { describe, it, expect, vi } from "vitest";
import { createProfileAnalyticsStatusTool } from "../src/tools/profile-analytics-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";

function makeAdminClient(overrides: Partial<MusoAdminClient> = {}): MusoAdminClient {
  return {
    get: vi.fn(async () => ({ ok: true, status: 200, data: {} })) as MusoAdminClient["get"],
    ...overrides,
  };
}

function makeDeps(overrides: Partial<Parameters<typeof createProfileAnalyticsStatusTool>[0]> = {}) {
  return {
    adminClient: makeAdminClient(),
    rateLimiter: new RateLimiter(),
    sessionId: "sess-1",
    ...overrides,
  };
}

async function call(tool: ReturnType<typeof createProfileAnalyticsStatusTool>, params: Record<string, unknown>) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as any).text as string);
}

function statusPayload(overrides: Record<string, unknown> = {}) {
  return {
    profileId: "90b6866c-7026-458e-a1af-48b1c1ac1c37",
    status: "fresh",
    analyticsInitialized: true,
    analyticsReady: true,
    freshness: {
      latestObservedAt: "2026-07-09T13:30:00.000Z",
      latestObservedAgeHours: 1,
      staleAfterHours: 48,
    },
    latestRun: {
      date: "2026-07-09T00:00:00.000Z",
      inProgressTracksCount: 0,
    },
    lifetime: {
      tracksWithData: 5,
      creditCount: 8,
      totals: {
        streams: 1000,
        shazams: 10,
        views: 500,
        videos: 4,
      },
      platformTotals: {
        spotify_streams: 600,
        youtube_streams: 400,
        youtube_views: 500,
        tiktok_views: 0,
      },
    },
    ...overrides,
  };
}

describe("profile_analytics_status", () => {
  it("returns structured fresh analytics diagnosis for a resolved profile", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/profile/search")) {
          return {
            ok: true,
            status: 200,
            data: {
              data: [
                {
                  id: "90b6866c-7026-458e-a1af-48b1c1ac1c37",
                  name: "Aasis Beats",
                  isClaimed: true,
                  commonCredits: ["Producer"],
                  email: "owner@example.com",
                },
              ],
            },
          } as AdminClientResult<unknown>;
        }
        if (path.includes("/analytics-status")) {
          return { ok: true, status: 200, data: { data: statusPayload() } } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });

    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { name: "Aasis Beats", source_platform: "Spotify", track_title: "Song A" });

    expect(out.found).toBe(true);
    expect(out.profile).toEqual({
      id: "90b6866c-7026-458e-a1af-48b1c1ac1c37",
      name: "Aasis Beats",
      verified: true,
      primary_role: "Producer",
    });
    expect(out.analytics).toMatchObject({
      status: "fresh",
      initialized: true,
      ready: true,
      support_action: "answer_from_status",
      metrics: {
        tracks_with_data: 5,
        credit_count: 8,
        requested_platform: {
          platform: "spotify",
          recognized: true,
          has_data: true,
          total: 600,
        },
      },
    });
    expect(JSON.stringify(out)).not.toContain("owner@example.com");
  });

  it("maps stale status to analytics follow-up action", async () => {
    const adminClient = makeAdminClient({
      get: vi.fn(async (path: string) => {
        if (path.includes("/analytics-status")) {
          return {
            ok: true,
            status: 200,
            data: statusPayload({
              status: "stale",
              analyticsReady: false,
              freshness: { latestObservedAt: "2026-07-05T12:00:00.000Z", latestObservedAgeHours: 98 },
            }),
          } as AdminClientResult<unknown>;
        }
        return {
          ok: true,
          status: 200,
          data: { data: { id: "90b6866c-7026-458e-a1af-48b1c1ac1c37", name: "Aasis" } },
        } as AdminClientResult<unknown>;
      }) as MusoAdminClient["get"],
    });
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { profile_id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" });
    expect(out.analytics.status).toBe("stale");
    expect(out.analytics.support_action).toBe("create_analytics_followup");
  });

  it("maps missing and inconsistent states to analytics follow-up action", async () => {
    for (const status of ["missing", "inconsistent"]) {
      const adminClient = makeAdminClient({
        get: vi.fn(async (path: string) => {
          if (path.includes("/analytics-status")) {
            return { ok: true, status: 200, data: statusPayload({ status, analyticsReady: false }) } as AdminClientResult<unknown>;
          }
          return { ok: true, status: 200, data: { data: { id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" } } } as AdminClientResult<unknown>;
        }) as MusoAdminClient["get"],
      });
      const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, sessionId: `sess-${status}` }));
      const out = await call(tool, { profile_id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" });
      expect(out.analytics.status).toBe(status);
      expect(out.analytics.support_action).toBe("create_analytics_followup");
    }
  });

  it("maps delayed and initializing states to explain-delay action", async () => {
    for (const status of ["delayed", "initializing"]) {
      const adminClient = makeAdminClient({
        get: vi.fn(async (path: string) => {
          if (path.includes("/analytics-status")) {
            return { ok: true, status: 200, data: statusPayload({ status, analyticsReady: false }) } as AdminClientResult<unknown>;
          }
          return { ok: true, status: 200, data: { data: { id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" } } } as AdminClientResult<unknown>;
        }) as MusoAdminClient["get"],
      });
      const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, sessionId: `sess-${status}` }));
      const out = await call(tool, { profile_id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" });
      expect(out.analytics.status).toBe(status);
      expect(out.analytics.support_action).toBe("explain_delay");
    }
  });

  it("returns no_match and multiple_matches during profile resolution", async () => {
    const noMatchClient = makeAdminClient({
      get: vi.fn(async () => ({ ok: true, status: 200, data: { data: [] } })) as MusoAdminClient["get"],
    });
    expect(await call(createProfileAnalyticsStatusTool(makeDeps({ adminClient: noMatchClient })), { name: "none" }))
      .toEqual({ found: false, reason: "no_match" });

    const multiClient = makeAdminClient({
      get: vi.fn(async () => ({
        ok: true,
        status: 200,
        data: { data: [{ id: "a", name: "A" }, { id: "b", name: "B" }, { id: "c", name: "C" }, { id: "d", name: "D" }] },
      })) as MusoAdminClient["get"],
    });
    expect(await call(createProfileAnalyticsStatusTool(makeDeps({ adminClient: multiClient })), { name: "A" }))
      .toEqual({ found: false, reason: "multiple_matches", matches: ["A", "B", "C"] });
  });

  it("returns missing_input, rate_limited, and lookup_unavailable as structured failures", async () => {
    const tool = createProfileAnalyticsStatusTool(makeDeps());
    expect(await call(tool, {})).toEqual({ found: false, reason: "missing_input" });

    const limited = createProfileAnalyticsStatusTool(makeDeps());
    for (let i = 0; i < 10; i++) await call(limited, { profile_id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" });
    expect(await call(limited, { profile_id: "90b6866c-7026-458e-a1af-48b1c1ac1c37" }))
      .toEqual({ found: false, reason: "rate_limited" });

    const adminClient = makeAdminClient({
      get: vi.fn(async () => ({ ok: false, status: 500, error: "x" })) as MusoAdminClient["get"],
    });
    expect(await call(createProfileAnalyticsStatusTool(makeDeps({ adminClient })), { name: "Aasis" }))
      .toEqual({ found: false, reason: "lookup_unavailable" });
  });
});


// ── Cold-cube regression suite (2026-08-18) ───────────────────────────────
// Note the payloads above carry NO `cubeStatus`: they predate it, and they are
// left that way on purpose so the legacy-fallback path stays covered.

const COLD_PROFILE_ID = "8158f1d0-ced1-457c-98ec-442c169783b2";

/** What core-backend really returns on a cold miss: it read nothing and says so. */
const WARMING = {
  profileId: COLD_PROFILE_ID,
  status: "inconsistent", // classified from the history row ALONE — not a verdict about data
  cubeStatus: "warming",
  analyticsInitialized: true,
  analyticsReady: false,
  freshness: { latestObservedAt: "2026-08-18T04:00:00.000Z", latestObservedAgeHours: 6, staleAfterHours: 48 },
  latestRun: { date: "2026-08-18T00:00:00.000Z", inProgressTracksCount: 0 },
  lifetime: null,
};

/** The same profile once the cube has actually been read: healthy. */
const WARM = {
  ...WARMING,
  status: "fresh",
  cubeStatus: "ready",
  analyticsReady: true,
  lifetime: {
    tracksWithData: 278,
    creditCount: 327,
    totals: { streams: 1000000, shazams: 0, views: 0, videos: 0 },
    platformTotals: { spotify_streams: 900000, youtube_streams: 100000 },
  },
};

function makeSequencedTool(analyticsSequence: Record<string, unknown>[]) {
  let calls = 0;
  const get = vi.fn(async (path: string) => {
    if (path.includes("/analytics-status")) {
      const body = analyticsSequence[Math.min(calls, analyticsSequence.length - 1)];
      calls += 1;
      return { ok: true, status: 200, data: { data: body } } as AdminClientResult<unknown>;
    }
    return {
      ok: true,
      status: 200,
      data: { data: { id: COLD_PROFILE_ID, name: "Saga Beats", isClaimed: true } },
    } as AdminClientResult<unknown>;
  });
  const tool = createProfileAnalyticsStatusTool(
    makeDeps({
      adminClient: { get } as unknown as MusoAdminClient,
      sleep: async () => {}, // no real delay in tests
    }),
  );
  return { tool, analyticsCalls: () => calls };
}

describe("profile_analytics_status — a cold cube must never read as zero", () => {
  it("retries a warming cube and answers from the warmed read", async () => {
    const { tool, analyticsCalls } = makeSequencedTool([WARMING, WARM]);
    const out = await call(tool, { profile_id: COLD_PROFILE_ID });

    expect(analyticsCalls()).toBe(2);
    expect(out.analytics.status).toBe("fresh");
    expect(out.analytics.support_action).toBe("answer_from_status");
    expect(out.analytics.metrics.measured).toBe(true);
    expect(out.analytics.metrics.tracks_with_data).toBe(278);
    expect(out.analytics.metrics.credit_count).toBe(327);
  });

  it("never escalates, and never reports zeros, while the cube is still warming", async () => {
    const { tool } = makeSequencedTool([WARMING, WARMING]);
    const out = await call(tool, { profile_id: COLD_PROFILE_ID });

    // This is the exact regression that escalated Saga Beats on 2026-08-18.
    expect(out.analytics.support_action).not.toBe("create_analytics_followup");
    expect(out.analytics.support_action).toBe("retry_after_warm");
    expect(out.analytics.status).toBe("warming");
    expect(out.analytics.cube_status).toBe("warming");

    expect(out.analytics.metrics.measured).toBe(false);
    expect(out.analytics.metrics.tracks_with_data).toBeNull();
    expect(out.analytics.metrics.credit_count).toBeNull();
    expect(out.analytics.metrics.totals).toBeNull();
    expect(out.analytics.metrics.platform_totals).toBeNull();
    // `ready: false` was the literal claim support acted on.
    expect(out.analytics.ready).toBeNull();
  });

  it("does not answer a platform question from an unread cube", async () => {
    const { tool } = makeSequencedTool([WARMING, WARMING]);
    const out = await call(tool, { profile_id: COLD_PROFILE_ID, source_platform: "spotify" });

    expect(out.analytics.metrics.requested_platform).toEqual({
      platform: "spotify",
      recognized: true,
      has_data: null, // NOT false — we did not look
      total: null,
    });
  });

  it("still escalates a genuine inconsistency, where the cube WAS read", async () => {
    const { tool, analyticsCalls } = makeSequencedTool([{ ...WARMING, cubeStatus: "ready" }]);
    const out = await call(tool, { profile_id: COLD_PROFILE_ID });

    expect(analyticsCalls()).toBe(1); // nothing was warming, so no retry
    expect(out.analytics.status).toBe("inconsistent");
    expect(out.analytics.support_action).toBe("create_analytics_followup");
    // A completed read that found nothing: zero is a TRUE statement here.
    expect(out.analytics.metrics.measured).toBe(true);
    expect(out.analytics.metrics.tracks_with_data).toBe(0);
  });

  it("still escalates missing and stale", async () => {
    for (const status of ["missing", "stale"]) {
      const { tool } = makeSequencedTool([{ ...WARM, status }]);
      const out = await call(tool, { profile_id: COLD_PROFILE_ID });
      expect(out.analytics.support_action).toBe("create_analytics_followup");
    }
  });

  it("falls back to lifetime presence when the backend sends no cubeStatus", async () => {
    const { cubeStatus: _warm, ...legacyWarm } = WARM as Record<string, unknown>;
    const warm = makeSequencedTool([legacyWarm]);
    const warmOut = await call(warm.tool, { profile_id: COLD_PROFILE_ID });
    expect(warm.analyticsCalls()).toBe(1); // no cubeStatus means nothing to retry on
    expect(warmOut.analytics.metrics.measured).toBe(true);
    expect(warmOut.analytics.metrics.tracks_with_data).toBe(278);

    const { cubeStatus: _cold, ...legacyCold } = WARMING as Record<string, unknown>;
    const cold = makeSequencedTool([legacyCold]);
    const coldOut = await call(cold.tool, { profile_id: COLD_PROFILE_ID });
    expect(coldOut.analytics.metrics.measured).toBe(false);
    expect(coldOut.analytics.metrics.tracks_with_data).toBeNull();
  });
});

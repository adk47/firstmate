import { describe, it, expect, vi } from "vitest";
import {
  buildDataFreshness,
  createProfileAnalyticsStatusTool,
  DATA_FRESHNESS_SOURCE,
} from "../src/tools/profile-analytics-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";

function makeAdminClient(overrides: Partial<MusoAdminClient> = {}): MusoAdminClient {
  return {
    get: vi.fn(async () => ({ ok: true, status: 200, data: {} })) as MusoAdminClient["get"],
    ...overrides,
  };
}

function makeIntercomReader(email: string | null = VERIFIED_EMAIL, throws = false): IntercomReader {
  return {
    getAuthorEmail: vi.fn(async () => {
      if (throws) throw new Error("intercom unavailable");
      return email;
    }),
    getLatestCustomerPart: vi.fn(async () => null),
  };
}

type ExecImpl = NonNullable<Parameters<typeof createProfileAnalyticsStatusTool>[0]["execFileImpl"]>;

function usersSearchResult(rows: Array<{ id: number; email: string }>): string {
  return JSON.stringify({ items: rows });
}
function teamsListResult(teamIds: string[]): string {
  return JSON.stringify({ items: teamIds.map((id) => ({ id })) });
}
function seatsGetResult(seats: Array<{ id: string; seatStatus: string }>): string {
  return JSON.stringify({ items: seats });
}

// A scripted exec mock: responses are consumed in call order (step 2 users
// search, step 3 teams list, then one step-4 teams seats get per candidate).
function makeExec(responses: Array<{ stdout?: string; rejectWith?: Error }>): { impl: ExecImpl; calls: { file: string; args: readonly string[] }[] } {
  const calls: { file: string; args: readonly string[] }[] = [];
  let i = 0;
  const impl: ExecImpl = (file, args, _options, callback) => {
    calls.push({ file, args });
    const resp = responses[i] ?? responses[responses.length - 1];
    i += 1;
    if (resp.rejectWith) {
      callback(resp.rejectWith, "", (resp.rejectWith as Error & { stderr?: string }).stderr ?? "");
    } else {
      callback(null, resp.stdout ?? "", "");
    }
    return undefined;
  };
  return { impl, calls };
}

// The default entitlement exec: grants an ACTIVE seat for WHATEVER profileId
// is requested, by reading the --seat-id value back out of the `teams list`
// call. Lets every pre-existing test in this file (which doesn't care about
// entitlement) keep passing unmodified once the gate is wired in.
function makeAutoGrantExec(): ExecImpl {
  let seatProfileId = "";
  const impl: ExecImpl = (_file, args, _options, callback) => {
    if (args[0] === "users" && args[1] === "search") {
      callback(null, usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]), "");
      return undefined;
    }
    if (args[0] === "teams" && args[1] === "list") {
      const idx = args.indexOf("--seat-id");
      seatProfileId = idx >= 0 ? String(args[idx + 1]) : "";
      callback(null, teamsListResult(["team-1"]), "");
      return undefined;
    }
    if (args[0] === "teams" && args[1] === "seats") {
      callback(null, seatsGetResult([{ id: seatProfileId, seatStatus: "active" }]), "");
      return undefined;
    }
    callback(new Error(`unexpected muso invocation: ${args.join(" ")}`), "", "");
    return undefined;
  };
  return impl;
}

function makeDeps(overrides: Partial<Parameters<typeof createProfileAnalyticsStatusTool>[0]> = {}) {
  return {
    adminClient: makeAdminClient(),
    rateLimiter: new RateLimiter(),
    sessionId: "sess-1",
    sessionKey: SESSION_KEY,
    intercomReader: makeIntercomReader(),
    intercomToken: "tok",
    execFileImpl: makeAutoGrantExec(),
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
    // Regression guard: the entitlement gate must not eat the warming retry.
    expect(out.analytics.entitled).toBe(true);
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

// ── Entitlement gate (MUS-1469/1475/1476) ─────────────────────────────────
// A stream figure leaves this process only for a verified account holding an
// ACTIVE seat on this exact profile. The 2026-09-30 Tobi Wikström incident:
// an unsubscribed contact was handed another customer's lifetime streams.

const ENTITLED_PROFILE_ID = "90b6866c-7026-458e-a1af-48b1c1ac1c37";

const DENY_FIELD_PATTERN = /platform_totals|tracks_with_data|credit_count|_streams|shazams/;

function makeResolvedProfileAdminClient(getMock?: MusoAdminClient["get"]): MusoAdminClient {
  return makeAdminClient({
    get:
      getMock ??
      ((vi.fn(async (path: string) => {
        if (path.includes("/analytics-status")) {
          return { ok: true, status: 200, data: { data: statusPayload() } } as AdminClientResult<unknown>;
        }
        if (path.includes(`/profile/${ENTITLED_PROFILE_ID}`)) {
          return { ok: true, status: 200, data: { data: { id: ENTITLED_PROFILE_ID, name: "Aasis Beats", isClaimed: true } } } as AdminClientResult<unknown>;
        }
        return { ok: true, status: 200, data: {} } as AdminClientResult<unknown>;
      })) as MusoAdminClient["get"]),
  });
}

function neverCalledAnalyticsStatus(adminClient: MusoAdminClient) {
  const calls = (adminClient.get as ReturnType<typeof vi.fn>).mock.calls as unknown[][];
  return calls.every(([path]) => !String(path).includes("analytics-status"));
}

describe("profile_analytics_status — entitlement gate", () => {
  it("1. entitled: ACTIVE seat, ready cube -> full payload, entitled:true, platform_totals present", async () => {
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.found).toBe(true);
    expect(out.analytics.entitled).toBe(true);
    expect(out.analytics.grant).toBe("active_seat");
    expect(out.analytics.metrics.platform_totals).toEqual({
      spotify_streams: 600,
      youtube_streams: 400,
      youtube_views: 500,
      tiktok_views: 0,
    });
  });

  it("2. not entitled (no active seat) -> no figures anywhere, explain_pro_requirement, /analytics-status never called", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      { stdout: seatsGetResult([{ id: ENTITLED_PROFILE_ID, seatStatus: "paused" }]) },
    ]);
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, execFileImpl: exec.impl }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.found).toBe(true);
    expect(out.analytics.entitled).toBe(false);
    expect(out.analytics.reason).toBe("no_active_seat");
    expect(out.analytics.support_action).toBe("explain_pro_requirement");
    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
    expect(out.analytics).not.toHaveProperty("metrics");
    expect(out.analytics).not.toHaveProperty("cube_status");
    expect(neverCalledAnalyticsStatus(adminClient)).toBe(true);
  });

  it("3. profile outside the workspace -> same omission assertions, reason profile_not_in_workspace", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult([]) },
    ]);
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, execFileImpl: exec.impl }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.analytics.entitled).toBe(false);
    expect(out.analytics.reason).toBe("profile_not_in_workspace");
    // Confirmed negative: the customer was resolved, the profile just has no
    // seat in any of their workspaces.
    expect(out.analytics.support_action).toBe("explain_pro_requirement");
    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
    expect(neverCalledAnalyticsStatus(adminClient)).toBe(true);
  });

  it("4. past_due subscription with a non-ACTIVE seat -> denied, no figures", async () => {
    // past_due tears the roster seat down (verifyUserAnalyticsAccess reads no
    // subscription state at all), so the seat simply never comes back ACTIVE.
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      { stdout: seatsGetResult([{ id: ENTITLED_PROFILE_ID, seatStatus: "pending" }]) },
    ]);
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, execFileImpl: exec.impl }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.analytics.entitled).toBe(false);
    expect(out.analytics.reason).toBe("no_active_seat");
    // Confirmed negative: the seat was found and is not ACTIVE.
    expect(out.analytics.support_action).toBe("explain_pro_requirement");
    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
    expect(neverCalledAnalyticsStatus(adminClient)).toBe(true);
  });

  it("5. missing Intercom token -> denied owner_undetermined, route_to_human:true, human_review (NOT a Pro pitch), no admin analytics call", async () => {
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, intercomToken: "" }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.analytics.entitled).toBe(false);
    expect(out.analytics.reason).toBe("owner_undetermined");
    expect(out.analytics.route_to_human).toBe(true);
    // Undetermined outcome: verification itself did not complete. Must NOT
    // assert the customer lacks a subscription — a missing/expired
    // MUSOAI_INTERCOM_TOKEN would otherwise pitch Pro to every customer,
    // including existing subscribers, permanently (QA finding, round 3).
    expect(out.analytics.support_action).toBe("human_review");
    expect(out.analytics.diagnosis).not.toMatch(/\bpro\b|subscription/i);
    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
    expect(neverCalledAnalyticsStatus(adminClient)).toBe(true);
  });

  it("5b. check_unavailable (a muso CLI read failed) -> denied, human_review, NOT a Pro pitch, no admin analytics call", async () => {
    // The transient failure scenario QA named: an existing Pro subscriber
    // asks about their own analytics while `muso teams list` (or any other
    // CLI hop) is failing. The gate fails closed to check_unavailable, and
    // the customer must be routed to a human, not told to upgrade.
    const exec = makeExec([{ rejectWith: Object.assign(new Error("muso exec failed"), { stderr: "connection refused" }) }]);
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, execFileImpl: exec.impl }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.analytics.entitled).toBe(false);
    expect(out.analytics.reason).toBe("check_unavailable");
    expect(out.analytics.route_to_human).toBe(true);
    expect(out.analytics.support_action).toBe("human_review");
    expect(out.analytics.diagnosis).not.toMatch(/\bpro\b|subscription/i);
    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
    expect(neverCalledAnalyticsStatus(adminClient)).toBe(true);
  });

  it("6. entitled path still returns figures with a valid agent:support:intercom:direct:<convId> session key", async () => {
    // Proves the gate FUNCTION works through a real session-key shape, not
    // just that non-entitled customers get denied — the positive path is the
    // one nobody writes. This does NOT prove index.ts actually hands the
    // gate ctx.sessionKey rather than ctx.sessionId: it constructs the tool
    // directly, bypassing the factory. That wiring is covered separately by
    // "anchors the entitlement gate on ctx.sessionKey" in tests/index.test.ts
    // (QA finding, MUS-1528 round 1).
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(
      makeDeps({ adminClient, sessionKey: "agent:support:intercom:direct:CONV999" }),
    );
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(out.analytics.entitled).toBe(true);
    expect(out.analytics.metrics.platform_totals).toBeTruthy();
  });

  it("7. structural guard: no future analytics field leaks through the deny payload", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult([]) },
    ]);
    const adminClient = makeResolvedProfileAdminClient();
    const tool = createProfileAnalyticsStatusTool(makeDeps({ adminClient, execFileImpl: exec.impl }));
    const out = await call(tool, { profile_id: ENTITLED_PROFILE_ID });

    expect(JSON.stringify(out)).not.toMatch(DENY_FIELD_PATTERN);
  });
});

// intercom-no-human-assignment-k1, Part 4: the data-freshness read. "Is my data current, when was it
// last updated" is answered from a stated source; an unmeasured leg is null, never a healthy default.
describe("data_freshness (the data-freshness read)", () => {
  it("names its source and states is_current against the BACKEND's threshold", () => {
    const f = buildDataFreshness(
      { latestObservedAt: "2026-11-10T04:00:00.000Z", latestObservedAgeHours: 30, staleAfterHours: 48 },
      { date: "2026-11-10T00:00:00.000Z", updatedAt: "2026-11-10T04:00:00.000Z", inProgressTracksCount: 2, numTracksUpdated: 40, tracksCount: 42 },
    );
    expect(f.source).toBe(DATA_FRESHNESS_SOURCE);
    expect(String(f.source)).toContain("/api/v3/admin/profile/{id}/analytics-status");
    expect(f.is_current).toBe(true);
    expect(f.last_updated_at).toBe("2026-11-10T04:00:00.000Z");
    expect(f.age_hours).toBe(30);
    expect(f.stale_after_hours).toBe(48);
    expect(f.last_run).toEqual({
      date: "2026-11-10T00:00:00.000Z",
      updated_at: "2026-11-10T04:00:00.000Z",
      tracks_in_progress: 2,
      tracks_updated: 40,
      tracks_total: 42,
    });
  });

  it("older than the backend's threshold is not current", () => {
    const f = buildDataFreshness({ latestObservedAt: "2026-11-01T00:00:00.000Z", latestObservedAgeHours: 250, staleAfterHours: 48 }, {});
    expect(f.is_current).toBe(false);
    expect(String(f.is_current_basis)).toContain("250h");
  });

  it("no age or no threshold is UNMEASURED (null), never current", () => {
    expect(buildDataFreshness({ latestObservedAt: "2026-11-10T04:00:00.000Z", latestObservedAgeHours: 3 }, {}).is_current).toBeNull();
    expect(buildDataFreshness({ staleAfterHours: 48 }, {}).is_current).toBeNull();
    const empty = buildDataFreshness({}, {});
    expect(empty.is_current).toBeNull();
    expect(String(empty.is_current_basis)).toMatch(/^unmeasured/);
    expect(empty.last_updated_at).toBe("");
    expect((empty.last_run as Record<string, unknown>).tracks_total).toBeNull();
  });

  it("the known-issue leg says it is not measured, so silence is never read as 'no issue'", () => {
    const k = buildDataFreshness({}, {}).known_issue as Record<string, unknown>;
    expect(k.measured).toBe(false);
    expect(String(k.reason)).toMatch(/do not tell the customer there is or is not a known issue/);
  });

  it("carries no stream figure", () => {
    const f = buildDataFreshness(
      { latestObservedAt: "2026-11-10T04:00:00.000Z", latestObservedAgeHours: 30, staleAfterHours: 48, streams: 999 },
      { date: "2026-11-10T00:00:00.000Z", streams: 999 },
    );
    expect(JSON.stringify(f)).not.toContain("999");
  });

  it("is part of the entitled payload of profile_analytics_status", async () => {
    const { tool } = makeSequencedTool([WARM]);
    const res = await tool.execute("t", { profile_id: COLD_PROFILE_ID } as never);
    const out = JSON.parse((res.content[0] as { text: string }).text);
    expect(out.analytics.data_freshness.is_current).toBe(true);
    expect(out.analytics.data_freshness.last_updated_at).toBe("2026-08-18T04:00:00.000Z");
    expect(out.analytics.data_freshness.source).toBe(DATA_FRESHNESS_SOURCE);
  });

  it("an unconfirmed access check promises no person", async () => {
    const src = await import("node:fs").then((fs) =>
      fs.readFileSync(new URL("../src/tools/profile-analytics-status.ts", import.meta.url), "utf8"),
    );
    expect(src).not.toMatch(/team member will follow up/i);
  });
});

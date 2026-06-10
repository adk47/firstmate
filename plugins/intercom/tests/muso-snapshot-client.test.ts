import { describe, it, expect } from "vitest";
import { createSnapshotClient } from "../src/muso-snapshot-client.js";

function jsonResp(status: number, body: unknown) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

// Real envelopes (core-backend wraps handler output in an outer `data`):
//   /admin/claiming  → { data: { items: [{ profileId, userId, status, team: { email } }], total } }
//   /admin/team      → { data: { items: [{ id, email, founder: {active, sinceYear, lapsedAt}, subscription: {plan, period} }], total } }
//   /admin/profile/X → { data: { id, name, isClaimed, creditCount, commonCredits, email, phone } }
//   /admin/profile/X/credits → { data: { items: [{ title, releaseDate, credits }] } }

const CLAIMING = {
  data: {
    items: [
      { profileId: "abc123de", userId: 42, status: "processed", team: { email: "jane@example.com" } },
    ],
    total: 1,
  },
};

const TEAM = {
  data: {
    items: [
      {
        id: "team-1",
        email: "jane@example.com",
        isClaimed: true,
        stripeCustomerId: "cus_SECRET", // PII-ish — must NOT appear in the snapshot
        founder: { active: true, sinceYear: 2023, lapsedAt: null },
        subscription: { plan: "pro", period: "annual", status: null },
      },
    ],
    total: 1,
  },
};

const PROFILE = {
  data: {
    id: "abc123de",
    name: "Jane Doe",
    isClaimed: true,
    creditCount: 42,
    commonCredits: ["Producer"],
    email: "jane@example.com", // PII — must NOT appear in the snapshot
    phone: "+15551234",
  },
};

const CREDITS = {
  data: {
    items: [
      { title: "Old Song", releaseDate: "2024-01-01", credits: ["Producer"] },
      { title: "Midnight", releaseDate: "2026-05-01", credits: ["Producer"] },
    ],
    totalCount: 2,
  },
};

interface FakeOpts {
  claimingStatus?: number;
  claimingBody?: unknown;
  claimingStatusSequence?: number[]; // for 401-then-200 retry tests
  teamStatus?: number;
  teamBody?: unknown;
  profileStatus?: number;
  profileBody?: unknown;
  creditsBody?: unknown;
}

function makeFetch(opts: FakeOpts = {}) {
  const calls: { url: string; init: any }[] = [];
  let claimingCall = 0;
  const fetchImpl = async (url: string, init?: any) => {
    calls.push({ url, init });
    if (url.includes("/admin/user/login")) {
      return jsonResp(200, { data: { authentication: { accessToken: "tok123" } } });
    }
    if (url.includes("/admin/claiming")) {
      const status = opts.claimingStatusSequence
        ? opts.claimingStatusSequence[claimingCall++]
        : (opts.claimingStatus ?? 200);
      return jsonResp(status, opts.claimingBody ?? CLAIMING);
    }
    if (url.includes("/admin/team")) {
      return jsonResp(opts.teamStatus ?? 200, opts.teamBody ?? TEAM);
    }
    if (url.includes("/credits")) {
      return jsonResp(200, opts.creditsBody ?? CREDITS);
    }
    if (url.includes("/admin/profile/")) {
      return jsonResp(opts.profileStatus ?? 200, opts.profileBody ?? PROFILE);
    }
    return jsonResp(404, {});
  };
  return { fetchImpl, calls };
}

function client(opts?: FakeOpts) {
  const { fetchImpl, calls } = makeFetch(opts);
  const c = createSnapshotClient({
    musoApiBase: "https://api.muso.ai",
    adminEmail: "admin@muso.ai",
    adminPassword: "pw",
    fetchImpl,
  });
  return { c, calls };
}

describe("createSnapshotClient.lookupSnapshot — claiming + team chain", () => {
  it("assembles the full snapshot: claimed profile + credits + founder + plan", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap).toEqual({
      profileId: "abc123de",
      name: "Jane Doe",
      profileUrl: "https://muso.ai/profile/abc123de",
      isClaimed: true,
      primaryRole: "Producer",
      creditsCount: 42,
      latestCreditTitle: "Midnight",
      latestCreditDate: "2026-05-01",
      founderSince: 2023,
      plan: "pro (annual)",
    });
  });

  it("resolves the profile via /admin/claiming, NOT /admin/profile/search", async () => {
    const { c, calls } = client();
    await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(calls.some((x) => x.url.includes("/admin/claiming?"))).toBe(true);
    expect(calls.some((x) => x.url.includes("/profile/search"))).toBe(false);
  });

  it("never leaks PII (email/phone/stripeCustomerId) into the snapshot", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(JSON.stringify(snap)).not.toContain("jane@example.com");
    expect(JSON.stringify(snap)).not.toContain("+15551234");
    expect(JSON.stringify(snap)).not.toContain("cus_SECRET");
  });

  it("matches the verified email case-insensitively / with surrounding whitespace", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot(" JANE@example.com ", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
    expect(snap?.plan).toBe("pro (annual)");
  });

  it("ignores claiming rows that are not status=processed", async () => {
    const { c } = client({
      claimingBody: {
        data: {
          items: [
            { profileId: "p-rejected", status: "rejected", team: { email: "jane@example.com" } },
            { profileId: "p-pending", status: "pending", team: { email: "jane@example.com" } },
          ],
          total: 2,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBeUndefined(); // no work fields
    expect(snap?.plan).toBe("pro (annual)"); // team leg still contributes
  });

  it("ignores claiming rows whose team email does not exactly match (iLike fuzzy hit)", async () => {
    const { c } = client({
      claimingBody: {
        data: {
          items: [
            { profileId: "wrong1", status: "processed", team: { email: "jane@example.com.evil.com" } },
          ],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBeUndefined();
  });

  it("treats >1 DISTINCT claimed profileIds as ambiguous — no work fields", async () => {
    const { c } = client({
      claimingBody: {
        data: {
          items: [
            { profileId: "p1", status: "processed", team: { email: "jane@example.com" } },
            { profileId: "p2", status: "processed", team: { email: "jane@example.com" } },
          ],
          total: 2,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBeUndefined();
  });

  it("collapses duplicate rows for the SAME profileId to a single confident match", async () => {
    const { c } = client({
      claimingBody: {
        data: {
          items: [
            { profileId: "abc123de", status: "processed", team: { email: "jane@example.com" } },
            { profileId: "abc123de", status: "processed", team: { email: "jane@example.com" } },
          ],
          total: 2,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
  });

  it("normalizes a raw internal plan id to its tier token", async () => {
    // Live 2026-06-10: subscription.plan arrived as the raw billing id
    // "muso_team_pro_graduated_monthly", not the pro|business|lite|vip enum.
    const { c } = client({
      teamBody: {
        data: {
          items: [{
            id: "t", email: "jane@example.com",
            subscription: { plan: "muso_team_pro_graduated_monthly", period: "monthly" },
          }],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.plan).toBe("pro (monthly)");
  });

  it("omits the plan entirely when the raw id maps to no known tier (never leak internal ids)", async () => {
    const { c } = client({
      teamBody: {
        data: {
          items: [{
            id: "t", email: "jane@example.com",
            subscription: { plan: "muso_internal_grandfathered_x9", period: "monthly" },
          }],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.plan).toBeUndefined();
    expect(JSON.stringify(snap)).not.toContain("grandfathered");
  });

  it("prefers the most specific tier when a raw id contains multiple tier words", async () => {
    // "business" must not match inside a hypothetical "pro_business_legacy" as "pro".
    const { c } = client({
      teamBody: {
        data: {
          items: [{
            id: "t", email: "jane@example.com",
            subscription: { plan: "muso_team_business_pro_rated", period: null },
          }],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    // tie-break: first tier token that appears as a whole word wins, in
    // vip > business > pro > lite order
    expect(snap?.plan).toBe("business");
  });

  it("omits founderSince when the founder is lapsed (active=false) but keeps plan", async () => {
    const { c } = client({
      teamBody: {
        data: {
          items: [{
            id: "t", email: "jane@example.com",
            founder: { active: false, sinceYear: 2022, lapsedAt: "2026-01-01T00:00:00Z" },
            subscription: { plan: "lite", period: null },
          }],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.founderSince).toBeUndefined();
    expect(snap?.plan).toBe("lite");
  });

  it("omits founderSince when an active founder has a null sinceYear (never 'since 0')", async () => {
    const { c } = client({
      teamBody: {
        data: {
          items: [{
            id: "t", email: "jane@example.com",
            founder: { active: true, sinceYear: null, lapsedAt: null },
            subscription: { plan: "pro", period: "annual" },
          }],
          total: 1,
        },
      },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.founderSince).toBeUndefined();
    expect(snap?.plan).toBe("pro (annual)");
  });

  it("omits team fields when no team email exactly matches", async () => {
    const { c } = client({
      teamBody: { data: { items: [{ id: "t", email: "other@x.com", founder: { active: true, sinceYear: 2020 }, subscription: { plan: "vip" } }], total: 1 } },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.plan).toBeUndefined();
    expect(snap?.founderSince).toBeUndefined();
    expect(snap?.profileId).toBe("abc123de"); // claiming leg unaffected
  });

  it("claiming failure does not kill the team leg (failure isolation)", async () => {
    const { c } = client({ claimingStatus: 500 });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBeUndefined();
    expect(snap?.plan).toBe("pro (annual)");
    expect(snap?.founderSince).toBe(2023);
  });

  it("team failure does not kill the claiming leg (failure isolation)", async () => {
    const { c } = client({ teamStatus: 500 });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.plan).toBeUndefined();
    expect(snap?.profileId).toBe("abc123de");
    expect(snap?.latestCreditTitle).toBe("Midnight");
  });

  it("profile-fetch failure degrades to claim-only fields, keeps team fields", async () => {
    const { c } = client({ profileStatus: 500 });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.plan).toBe("pro (annual)");
    // profileId is known from claiming even though the detail fetch failed
    expect(snap?.profileId).toBe("abc123de");
    expect(snap?.name).toBeUndefined();
  });

  it("returns null when nothing is found anywhere", async () => {
    const { c } = client({
      claimingBody: { data: { items: [], total: 0 } },
      teamBody: { data: { items: [], total: 0 } },
    });
    expect(await c.lookupSnapshot("nobody@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("returns null when both legs fail", async () => {
    const { c } = client({ claimingStatus: 500, teamStatus: 500 });
    expect(await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("parses an unwrapped {items: []} envelope too (defensive)", async () => {
    const { c } = client({
      claimingBody: { items: [{ profileId: "abc123de", status: "processed", team: { email: "jane@example.com" } }], total: 1 },
      teamBody: { items: [{ id: "t", email: "jane@example.com", subscription: { plan: "business" } }], total: 1 },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
    expect(snap?.plan).toBe("business");
  });

  it("sends a Bearer token and an abort signal on the claiming request", async () => {
    const { c, calls } = client();
    await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    const claiming = calls.find((x) => x.url.includes("/admin/claiming"));
    expect(claiming?.init?.headers?.Authorization).toBe("Bearer tok123");
    expect(claiming?.init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("re-logs in and retries once on a 401 from the claiming request", async () => {
    const { c, calls } = client({ claimingStatusSequence: [401, 200] });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
    expect(calls.filter((x) => x.url.includes("/admin/user/login")).length).toBe(2);
  });

  it("logs a warning when a resolution leg throws, while the other leg survives", async () => {
    const warns: string[] = [];
    const { fetchImpl } = makeFetch();
    const c = createSnapshotClient({
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "pw",
      fetchImpl: async (url: string, init?: any) => {
        if (url.includes("/admin/claiming")) throw new Error("ECONNRESET");
        return fetchImpl(url, init);
      },
      log: { warn: (m: string) => warns.push(m) },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBeUndefined();
    expect(snap?.plan).toBe("pro (annual)"); // team leg unaffected
    expect(warns.some((m) => m.includes("claiming") && m.includes("ECONNRESET"))).toBe(true);
  });

  it("logs a warning when the credits fetch throws, while profile fields survive", async () => {
    const warns: string[] = [];
    const { fetchImpl } = makeFetch();
    const c = createSnapshotClient({
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "pw",
      fetchImpl: async (url: string, init?: any) => {
        if (url.includes("/credits")) throw new Error("socket hang up");
        return fetchImpl(url, init);
      },
      log: { warn: (m: string) => warns.push(m) },
    });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.name).toBe("Jane Doe"); // profile leg unaffected
    expect(snap?.latestCreditTitle).toBeUndefined();
    expect(warns.some((m) => m.includes("credits") && m.includes("socket hang up"))).toBe(true);
  });
});

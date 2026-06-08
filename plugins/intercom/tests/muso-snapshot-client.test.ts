import { describe, it, expect } from "vitest";
import { createSnapshotClient } from "../src/muso-snapshot-client.js";

function jsonResp(status: number, body: unknown) {
  return { ok: status >= 200 && status < 300, status, json: async () => body };
}

const SINGLE_MATCH = {
  data: [
    {
      id: "abc123de",
      name: "Jane Doe",
      isClaimed: true,
      creditCount: 42,
      commonCredits: ["Producer"],
      email: "jane@example.com", // PII — must NOT appear in the snapshot
      phone: "+15551234",
    },
  ],
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
  loginStatus?: number;
  searchStatus?: number;
  searchBody?: unknown;
  creditsBody?: unknown;
  searchStatusSequence?: number[]; // for 401-then-200 retry tests
}

function makeFetch(opts: FakeOpts = {}) {
  const calls: { url: string; init: any }[] = [];
  let searchCall = 0;
  const fetchImpl = async (url: string, init?: any) => {
    calls.push({ url, init });
    if (url.includes("/admin/user/login")) {
      return jsonResp(opts.loginStatus ?? 200, { data: { authentication: { accessToken: "tok123" } } });
    }
    if (url.includes("/profile/search")) {
      const status = opts.searchStatusSequence ? opts.searchStatusSequence[searchCall++] : (opts.searchStatus ?? 200);
      return jsonResp(status, opts.searchBody ?? SINGLE_MATCH);
    }
    if (url.includes("/credits")) {
      return jsonResp(200, opts.creditsBody ?? CREDITS);
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

describe("createSnapshotClient.lookupSnapshot", () => {
  it("assembles a snapshot for a single match (profile + latest credit)", async () => {
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
    });
  });

  it("never leaks PII (email/phone) into the snapshot", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap).not.toHaveProperty("email");
    expect(snap).not.toHaveProperty("phone");
  });

  it("picks the most recent credit by release date regardless of input order", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.latestCreditTitle).toBe("Midnight");
    expect(snap?.latestCreditDate).toBe("2026-05-01");
  });

  it("returns null when there is no match", async () => {
    const { c } = client({ searchBody: { data: [] } });
    expect(await c.lookupSnapshot("nobody@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("returns null when the match is ambiguous (more than one result)", async () => {
    const { c } = client({ searchBody: { data: [{ id: "abc123de", name: "A" }, { id: "p2", name: "B" }] } });
    expect(await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("returns null when the lone result's email does not match the verified email (fuzzy keyword hit)", async () => {
    // /profile/search is keyword search — a single result can still be a fuzzy
    // non-email match. Attaching it would bind the wrong person's credits.
    const { c } = client({
      searchBody: { data: [{ id: "wrong1", name: "Someone Else", email: "someone@else.com" }] },
    });
    expect(await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("matches the verified email case-insensitively / with surrounding whitespace", async () => {
    const { c } = client();
    const snap = await c.lookupSnapshot(" JANE@example.com ", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
  });

  it("returns null when the lone result has no email field", async () => {
    const { c } = client({ searchBody: { data: [{ id: "noemail", name: "No Email" }] } });
    expect(await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("returns null when the search call fails", async () => {
    const { c } = client({ searchStatus: 500 });
    expect(await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 })).toBeNull();
  });

  it("sends a Bearer token and an abort signal on the search request", async () => {
    const { c, calls } = client();
    await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    const search = calls.find((x) => x.url.includes("/profile/search"));
    expect(search?.init?.headers?.Authorization).toBe("Bearer tok123");
    expect(search?.init?.signal).toBeInstanceOf(AbortSignal);
  });

  it("re-logs in and retries once on a 401 from the search request", async () => {
    const { c, calls } = client({ searchStatusSequence: [401, 200] });
    const snap = await c.lookupSnapshot("jane@example.com", { timeoutMs: 2500 });
    expect(snap?.profileId).toBe("abc123de");
    expect(calls.filter((x) => x.url.includes("/admin/user/login")).length).toBe(2);
  });
});

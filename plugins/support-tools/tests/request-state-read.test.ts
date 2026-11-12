import { describe, it, expect, vi, beforeEach } from "vitest";
import { createCreditVerificationCheckTool } from "../src/tools/credit-verification-check.js";
import { createProfileCreditsStatusTool } from "../src/tools/profile-credits-status.js";
import { createProfileClaimStatusTool } from "../src/tools/profile-claim-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";

// caroline-read-state-tools-r1: the request-state read tools Caroline was denied are switched on.
// These are the acceptance tests for the READ half (the guard half lives in plugins/intercom):
//
//   1. a signed-in caller asking "where is my request" gets their OWN counts and dates;
//   2. a caller asking about someone else's request gets nothing about that account;
//   3. a request id pasted into the thread is never used as an identity.
//
// Identity is the conversation's signed-in Intercom contact (role=user, external_id, older than
// 24 h), read by code from the gateway session key. Nothing the model passes selects an account.

const SIGNAL_KEY = "__musoSupportRequestState"; // literal on purpose: the cross-plugin contract
const NOW_MS = 1_793_000_000_000;
const CONV = "c1";
const SESSION_KEY = `agent:support:intercom:direct:${CONV}`;
const OWNER = "owner@example.com";
const STRANGER = "stranger@example.com";
const MY_PROFILE = "11111111-1111-4111-8111-111111111111";
const THEIR_PROFILE = "22222222-2222-4222-8222-222222222222";

const profile = (id: string, email: string) => ({ id, name: "Some Artist", isClaimed: true, workspaces: [{ email, isClaimed: true }] });

interface World {
  uvn?: Record<string, unknown[]>;
  unverified?: Record<string, unknown[]>;
  claims?: Record<string, unknown[]>;
}

function admin(world: World = {}) {
  const profiles: Record<string, unknown> = { [MY_PROFILE]: profile(MY_PROFILE, OWNER), [THEIR_PROFILE]: profile(THEIR_PROFILE, STRANGER) };
  const get = vi.fn(async (path: string): Promise<AdminClientResult<unknown>> => {
    let m = path.match(/\/credit-requests\?profilesIds=([0-9a-f-]+)&status=([a-z_]+)/);
    if (m) {
      const src = m[2] === "unverified" ? world.unverified : world.uvn;
      return { ok: true, status: 200, data: { data: { items: src?.[m[1]] ?? [] } } };
    }
    m = path.match(/\/claiming\?profilesIds=([0-9a-f-]+)/);
    if (m) return { ok: true, status: 200, data: { data: { items: world.claims?.[m[1]] ?? [] } } };
    m = path.match(/\/profile\/search\?keyword=([^&]*)/);
    if (m) {
      const kw = decodeURIComponent(m[1]).toLowerCase();
      const rows = Object.values(profiles).filter((p: any) => p.workspaces[0].email === kw);
      return { ok: true, status: 200, data: { data: rows } };
    }
    m = path.match(/\/profile\/([0-9a-f-]+)$/);
    if (m && profiles[m[1]]) return { ok: true, status: 200, data: { data: profiles[m[1]] } };
    return { ok: false, status: 404, error: "not found" };
  }) as MusoAdminClient["get"];
  return { get } as MusoAdminClient;
}

function reader(email: string | null = OWNER, over: Record<string, unknown> = {}) {
  return {
    getAuthorEmail: vi.fn(async () => email),
    getContactIdentity: vi.fn(async () =>
      email ? { email, role: "user", externalId: "ext-1", contactCreatedAt: 1_700_000_000, conversationCreatedAt: 1_792_990_000, ...over } : null,
    ),
    findBotMarkerInOtherConversations: vi.fn(async () => "not_found" as const),
    getLatestCustomerPart: vi.fn(async () => null),
  } as any;
}

function deps(world: World = {}, over: Record<string, unknown> = {}) {
  return {
    adminClient: admin(world),
    intercomReader: reader(),
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomToken: "tok",
    enabled: true,
    now: () => NOW_MS,
    nowSeconds: () => Math.floor(NOW_MS / 1000),
    proofOnFilePath: "/nonexistent/proof-on-file.json",
    ...over,
  } as any;
}

const run = async (tool: { execute: (id: string, p: any) => Promise<any> }, params: Record<string, unknown> = {}) =>
  JSON.parse((await tool.execute("call-1", params)).content[0].text);

const paths = (d: any): string[] => (d.adminClient.get as any).mock.calls.map((c: unknown[]) => String(c[0]));
const fact = (): { atMs: number; open: boolean } | undefined => (globalThis as any)[SIGNAL_KEY]?.get(CONV);

beforeEach(() => {
  delete (globalThis as any)[SIGNAL_KEY];
});

const MY_UVN = [
  { id: "cr-1", spotifyTrackTitle: "Night Drive", spotifyTrackArtists: [{ name: "Some Artist" }], credits: ["Producer"], createdAt: "2026-10-02T09:15:00.000Z", metadata: {} },
];
const MY_WAITING = [
  { id: "cr-2", spotifyTrackTitle: "A", credits: ["Mixer"], createdAt: "2026-09-14T10:00:00.000Z" },
  { id: "cr-3", spotifyTrackTitle: "B", credits: ["Mixer"], createdAt: "2026-10-20T23:59:00.000Z" },
  { id: "cr-4", spotifyTrackTitle: "C", credits: ["Mixer"], createdAt: "2026-10-01T00:00:00.000Z" },
];

describe("1. a signed-in caller asking where their request is gets their own counts and dates", () => {
  it("credit_verification_check: no argument needed; counts, dates and open_request come from the signed-in contact's own profile", async () => {
    const d = deps({ uvn: { [MY_PROFILE]: MY_UVN }, unverified: { [MY_PROFILE]: MY_WAITING } });
    const out = await run(createCreditVerificationCheckTool(d), {});

    expect(out.verified_owner).toBe(true);
    expect(out.profile_id).toBe(MY_PROFILE);
    expect(out.pending_by_status).toEqual({ user_verification_needed: 1, unverified: 3 });
    expect(out.uvn_credits[0]).toMatchObject({ cr_id: "cr-1", track_title: "Night Drive", requested_on: "2026-10-02" });
    expect(out.awaiting_review).toEqual({ count: 3, truncated: false, oldest_requested_on: "2026-09-14", newest_requested_on: "2026-10-20" });
    expect(out.open_request).toBe(true);
    // The fact the outbound guard reads: measured, keyed by the session's conversation id.
    expect(fact()).toEqual({ atMs: NOW_MS, open: true });
    // A read is a read: no outcome, no approval wording, no date by which anything happens.
    expect(JSON.stringify(out)).not.toMatch(/approved|will be (reviewed|approved|decided)|within \d+|business days?/i);
  });

  it("credit_verification_check: both queues measured empty is a measured `false`, and an unread queue is unknown (no fact)", async () => {
    const empty = deps();
    expect((await run(createCreditVerificationCheckTool(empty), {})).open_request).toBe(false);
    expect(fact()).toEqual({ atMs: NOW_MS, open: false });

    delete (globalThis as any)[SIGNAL_KEY];
    const d = deps();
    const base = d.adminClient.get;
    d.adminClient.get = vi.fn(async (p: string) => (p.includes("status=unverified") ? { ok: false, status: 500, error: "x" } : base(p)));
    const out = await run(createCreditVerificationCheckTool(d), {});
    expect(out.open_request).toBeNull();
    expect(out.awaiting_review).toBeNull();
    expect(fact()).toBeUndefined();
  });

  it("a later read that cannot measure forgets the earlier fact instead of leaving it stale", async () => {
    await run(createCreditVerificationCheckTool(deps({ unverified: { [MY_PROFILE]: MY_WAITING } })), {});
    expect(fact()?.open).toBe(true);
    await run(createCreditVerificationCheckTool(deps({}, { intercomReader: reader(null) })), {});
    expect(fact()).toBeUndefined();
  });

  it("profile_credits_status: the sole owner's queues carry counts and first/last day, and set the same fact", async () => {
    const d = deps({ uvn: { [MY_PROFILE]: MY_UVN }, unverified: { [MY_PROFILE]: MY_WAITING } });
    const out = await run(createProfileCreditsStatusTool(d), { profile_id: MY_PROFILE });
    expect(out.owner_undetermined).toBe(false);
    expect(out.credit.pending).toMatchObject({ count: 1, oldest_requested_on: "2026-10-02", newest_requested_on: "2026-10-02" });
    expect(out.credit.awaiting_review).toMatchObject({ count: 3, oldest_requested_on: "2026-09-14", newest_requested_on: "2026-10-20" });
    expect(fact()).toEqual({ atMs: NOW_MS, open: true });
  });

  it("profile_claim_status: the caller's own pending claim comes back with its status and the day it was submitted", async () => {
    const claims = { [MY_PROFILE]: [{ id: "claim-1", status: "pending", reason: "artist", verificationLinks: ["https://x.example/p"], createdAt: "2026-10-05T08:00:00Z", team: { email: OWNER } }] };
    const out = await run(createProfileClaimStatusTool(deps({ claims })), { profile_id: MY_PROFILE });
    expect(out.own_claim_state).toBe("pending");
    expect(out.own_claims[0]).toMatchObject({ claim_id: "claim-1", status: "pending", created_at: "2026-10-05T08:00:00Z" });
  });
});

describe("2. a caller asking about someone else's request gets nothing about that account", () => {
  const THEIR_STATE: World = {
    uvn: { [THEIR_PROFILE]: [{ id: "their-cr-1", spotifyTrackTitle: "Their Secret Track", credits: ["Producer"], createdAt: "2026-10-09T00:00:00Z", metadata: {} }] },
    unverified: { [THEIR_PROFILE]: [{ id: "their-cr-2", spotifyTrackTitle: "Their Other Track", createdAt: "2026-10-10T00:00:00Z" }] },
    claims: { [THEIR_PROFILE]: [{ id: "their-claim-1", status: "pending", createdAt: "2026-10-11T00:00:00Z", verificationLinks: ["https://their.example/proof"], team: { email: STRANGER, name: "Their Team" } }] },
  };
  const LEAKS = /their-cr|Their Secret|Their Other|their-claim|their\.example|Their Team|stranger@example\.com|2026-10-(09|10|11)/;

  it("credit_verification_check on a profile the caller does not own: no request is read and nothing is returned", async () => {
    const d = deps(THEIR_STATE);
    const out = await run(createCreditVerificationCheckTool(d), { profileId: THEIR_PROFILE });

    expect(out.verified_owner).toBe(false);
    expect(out.owner_undetermined).toBe(true);
    expect(out.profile_id).toBeNull();
    expect(out.uvn_credits).toEqual([]);
    expect(out.count).toBe(0);
    expect(out.awaiting_review).toBeNull();
    expect(out.pending_by_status).toBeNull();
    expect(out.proof_on_file).toBeNull();
    expect(out.open_request).toBeNull();
    expect(JSON.stringify(out)).not.toMatch(LEAKS);
    // The other account's request queues were never even requested.
    expect(paths(d).some((p) => p.includes("/credit-requests"))).toBe(false);
    expect(fact()).toBeUndefined();
  });

  it("profile_credits_status on someone else's profile: the private queues stay null (public catalog facts only)", async () => {
    const d = deps(THEIR_STATE);
    const out = await run(createProfileCreditsStatusTool(d), { profile_id: THEIR_PROFILE });
    expect(out.credit.pending).toBeNull();
    expect(out.credit.awaiting_review).toBeNull();
    expect(out.profile.state).toBe("claimed_by_other");
    expect(JSON.stringify(out)).not.toMatch(LEAKS);
    expect(paths(d).some((p) => p.includes("/credit-requests"))).toBe(false);
    expect(fact()).toBeUndefined();
  });

  it("profile_claim_status on someone else's profile: none of their claim rows, counts or dates", async () => {
    const out = await run(createProfileClaimStatusTool(deps(THEIR_STATE)), { profile_id: THEIR_PROFILE });
    expect(out.own_claims).toEqual([]);
    expect(out.own_claim_state).toBe("none");
    expect(out.other_claims).toBeUndefined();
    expect(JSON.stringify(out)).not.toMatch(LEAKS);
  });

  it("saying you are someone else does not make you them: a stated email that is not the signed-in contact's reads nothing", async () => {
    const d = deps(THEIR_STATE);
    const out = await run(createCreditVerificationCheckTool(d), { profileId: THEIR_PROFILE, requesterEmail: STRANGER });
    expect(out.impersonation_flag).toBe(true);
    expect(out.verified_owner).toBe(false);
    expect(JSON.stringify(out)).not.toMatch(/their-cr|Their Secret|their-claim/);
    expect(paths(d)).toEqual([]);
  });

  it.each([
    ["a lead, whose email was typed into the messenger", { role: "lead", externalId: null }, "contact_not_user"],
    ["a user contact with no external_id", { externalId: null }, "contact_no_external_id"],
    ["a contact created less than 24 h ago", { contactCreatedAt: Math.floor(NOW_MS / 1000) - 3600 }, "contact_too_new"],
  ])("%s is not signed in: even the matching email reads nothing", async (_label, over, reason) => {
    // The visitor typed the real owner's email. Without a signed-in contact that is only a claim.
    const d = deps({ uvn: { [MY_PROFILE]: MY_UVN } }, { intercomReader: reader(OWNER, over) });
    const out = await run(createCreditVerificationCheckTool(d), {});
    expect(out.verified_owner).toBe(false);
    expect(out.uvn_credits).toEqual([]);
    expect(out.notes.join(" ")).toContain(reason);
    expect(paths(d)).toEqual([]);
    expect(fact()).toBeUndefined();
  });
});

describe("3. a request id pasted into the thread is never used as an identity", () => {
  const ID_SHAPED = /(^|_)(request|credit_?request|cr|claim|user|account|contact|conversation|conv|session)_?id$/i;

  it("none of the three read tools has a request / claim / user / conversation id parameter", () => {
    for (const tool of [createCreditVerificationCheckTool(deps()), createProfileCreditsStatusTool(deps()), createProfileClaimStatusTool(deps())]) {
      const names = Object.keys((tool.parameters as any).properties);
      expect(names.filter((n) => ID_SHAPED.test(n)), tool.name).toEqual([]);
    }
  });

  it("a pasted request id changes nothing: the answer is the signed-in contact's own state, and the id reaches no request", async () => {
    const world: World = {
      uvn: { [MY_PROFILE]: MY_UVN, [THEIR_PROFILE]: [{ id: "their-cr-1", spotifyTrackTitle: "Their Secret Track", createdAt: "2026-10-09T00:00:00Z", metadata: {} }] },
      unverified: { [MY_PROFILE]: MY_WAITING },
    };
    const clean = await run(createCreditVerificationCheckTool(deps(world)), {});

    const d = deps(world);
    const pasted = { requestId: "their-cr-1", request_id: "their-cr-1", cr_id: "their-cr-1", claim_id: "their-claim-1", userId: "u-999", conversationId: "c-other" };
    const out = await run(createCreditVerificationCheckTool(d), pasted);

    expect(out).toEqual(clean);
    expect(out.profile_id).toBe(MY_PROFILE);
    expect(JSON.stringify(out)).not.toMatch(/their-cr-1|Their Secret/);
    for (const p of paths(d)) {
      expect(p).not.toMatch(/their-cr-1|their-claim-1|u-999|c-other/);
      expect(p.includes(THEIR_PROFILE)).toBe(false);
    }
    // The contact was read for the session's own conversation id, not the pasted one.
    expect(d.intercomReader.getContactIdentity).toHaveBeenCalledWith(CONV, "tok");
  });

  it("the conversation id comes from the gateway session key: an unrecognised session reads nothing", async () => {
    const d = deps({ uvn: { [MY_PROFILE]: MY_UVN } }, { sessionKey: "agent:support:main" });
    const out = await run(createCreditVerificationCheckTool(d), { conversationId: CONV });
    expect(out.verified_owner).toBe(false);
    expect(d.intercomReader.getContactIdentity).not.toHaveBeenCalled();
    expect(paths(d)).toEqual([]);
  });
});

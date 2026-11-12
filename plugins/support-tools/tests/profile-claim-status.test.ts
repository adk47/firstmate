import { describe, it, expect, vi } from "vitest";
import { createProfileClaimStatusTool, supportActionFor, diagnosisFor, failClosedVerdict, type ClaimRow } from "../src/tools/profile-claim-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";
import type { IntercomReader } from "../src/intercom-client.js";

// The read tools anchor on the conversation's SIGNED-IN Intercom contact (resolveOwnerAnchor:
// role=user, external_id, contact older than 24 h), so the mock reader answers getContactIdentity.
// getAuthorEmail stays on the mock to prove the tools no longer consult it.
function signedInReader(email: string | null = "owner@example.com", over: Record<string, unknown> = {}) {
  return {
    getAuthorEmail: vi.fn(async () => email),
    getContactIdentity: vi.fn(async () =>
      email
        ? { email, role: "user", externalId: "ext-1", contactCreatedAt: 1_700_000_000, conversationCreatedAt: 1_793_000_000, ...over }
        : null,
    ),
  } as any;
}

const OWNER_EMAIL = "owner@example.com";
const OTHER_EMAIL = "rival@example.com";
const SESSION_KEY = "agent:support:intercom:direct:12345";
const PROFILE_ID = "90b6866c-7026-458e-a1af-48b1c1ac1c37";

interface MockWorld {
  profile?: { id: string; name: string; isClaimed: boolean; workspaces?: Array<{ email?: string; isClaimed?: boolean }> };
  claims?: ClaimRow[];
  // value returned under {data:{claiming: ...}} for GET /claiming/<id>
  claimById?: Record<string, ClaimRow | null>;
  malformedList?: boolean;
  // How the fake list endpoint departs from the real one (which returns `total` for the
  // filtered list and honours `page`, verified read-only against prod 2026-11-12).
  noTotal?: boolean;
  ignorePage?: boolean;
  failListPage?: number;
  listCalls?: string[];
  failPaths?: RegExp[];
}

function makeAdminClient(world: MockWorld): MusoAdminClient {
  const get = vi.fn(async (path: string): Promise<AdminClientResult<unknown>> => {
    if ((world.failPaths ?? []).some((re) => re.test(path))) {
      return { ok: false, status: 500, error: "boom" };
    }
    if (/^\/api\/v3\/admin\/claiming\?profilesIds=/.test(path)) {
      world.listCalls?.push(path);
      if (world.malformedList) return { ok: true, status: 200, data: { data: {} } };
      const q = new URLSearchParams(path.split("?")[1]);
      const limit = Number(q.get("limit") ?? "20");
      const page = world.ignorePage ? 1 : Number(q.get("page") ?? "1");
      if (world.failListPage === Number(q.get("page") ?? "1")) return { ok: false, status: 500, error: "boom" };
      const all = world.claims ?? [];
      const items = all.slice((page - 1) * limit, page * limit);
      return { ok: true, status: 200, data: { data: world.noTotal ? { items } : { items, total: all.length } } };
    }
    let m = path.match(/^\/api\/v3\/admin\/claiming\/([^/?]+)$/);
    if (m) {
      const val = world.claimById?.[m[1]];
      return { ok: true, status: 200, data: { data: { claiming: val === undefined ? null : val } } };
    }
    m = path.match(/^\/api\/v3\/admin\/profile\/([0-9a-fA-F-]+)$/);
    if (m) {
      if (!world.profile || world.profile.id !== m[1]) return { ok: false, status: 404, error: "not found" };
      return { ok: true, status: 200, data: { data: world.profile } };
    }
    if (/^\/api\/v3\/admin\/profile\/search\?/.test(path)) {
      return { ok: true, status: 200, data: { data: world.profile ? [world.profile] : [] } };
    }
    throw new Error(`unexpected path: ${path}`);
  }) as MusoAdminClient["get"];
  return { get };
}

function makeDeps(world: MockWorld, overrides: Record<string, unknown> = {}) {
  return {
    adminClient: makeAdminClient(world),
    intercomReader: signedInReader(OWNER_EMAIL) as IntercomReader,
    rateLimiter: new RateLimiter(),
    sessionKey: SESSION_KEY,
    intercomToken: "tok",
    ...overrides,
  } as Parameters<typeof createProfileClaimStatusTool>[0];
}

async function call(tool: ReturnType<typeof createProfileClaimStatusTool>, params: Record<string, unknown>) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse((result.content[0] as any).text as string);
}

function unclaimedProfile() {
  return { id: PROFILE_ID, name: "Aasis Beats", isClaimed: false };
}

function ownClaim(overrides: Partial<ClaimRow> = {}): ClaimRow {
  return {
    id: "claim-1",
    status: "pending",
    reason: "artist",
    profileId: PROFILE_ID,
    verificationLinks: ["https://instagram.com/aasis/secret-proof"],
    createdAt: "2026-07-01T00:00:00Z",
    team: { email: OWNER_EMAIL, name: "Aasis Team" },
    ...overrides,
  };
}

function otherClaim(overrides: Partial<ClaimRow> = {}): ClaimRow {
  return {
    id: "claim-9",
    status: "pending",
    reason: "artist",
    profileId: PROFILE_ID,
    verificationLinks: ["https://rival.example.com/proof"],
    createdAt: "2026-06-01T00:00:00Z",
    team: { email: OTHER_EMAIL, name: "Rival Team" },
    ...overrides,
  };
}

describe("profile_claim_status — claim states", () => {
  it("single own pending claim, no conflict → a fact Caroline can state (status + the day it was submitted), never a claim write", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.found).toBe(true);
    expect(out.own_claim_state).toBe("pending");
    expect(out.own_claims).toHaveLength(1);
    expect(out.own_claims[0]).toMatchObject({ claim_id: "claim-1", status: "pending", has_verification_links: true });
    expect(out.claim_conflict).toBe("none");
    expect(out.suspicion_flags).toEqual([]);
    expect(out.own_claims[0].created_at).toBe("2026-07-01T00:00:00Z");
    expect(out.support_action).toBe("answer_from_status");
    expect(out.handoff_packet).toBeUndefined();
    // No route to the (denied) claim write survives anywhere in the output.
    expect(JSON.stringify(out)).not.toMatch(/route_selfserve|profiles_claim_self/);
  });

  it("own rejected claim → the state and NO reason: none returned, none to explain, none to guess", async () => {
    const world: MockWorld = {
      profile: unclaimedProfile(),
      claims: [ownClaim({ status: "rejected", reason: "ZEBRA-INTERNAL-NOTE name mismatch" })],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const result = await tool.execute("call-1", { profile_id: PROFILE_ID } as any);
    const text = (result.content[0] as any).text as string;
    const out = JSON.parse(text);

    expect(out.own_claim_state).toBe("rejected");
    expect(out.support_action).toBe("answer_from_status");
    // The admin row's `reason` never leaves the tool, under any key.
    expect(text).not.toContain("ZEBRA-INTERNAL-NOTE");
    expect(text).not.toContain("name mismatch");
    expect(Object.keys(out.own_claims[0]).sort()).toEqual(["claim_id", "created_at", "has_verification_links", "status"]);
    // The guidance tells her there is no reason to give. It never tells her to explain one.
    expect(out.diagnosis).toMatch(/carries NO reason/);
    expect(out.diagnosis).toMatch(/never give, guess or imply one/);
    expect(out.diagnosis).not.toMatch(/explain/i);
    expect(out.diagnosis).not.toMatch(/proof requirements/i);
  });

  it("no claim state tells her to explain or state a reason", () => {
    const base = { claim_conflict: "none" as const, suspicion_flags: [], profile_state: "unclaimed" as const };
    for (const st of ["none", "pending", "processed", "rejected", "reverted", "closed", "multiple", "unknown"] as const) {
      for (const needs_person of [false, true]) {
        const d = diagnosisFor({ ...base, own_claim_state: st, needs_person });
        expect(d, st).not.toMatch(/explain the (rejection )?reason|state the reason|tell them why/i);
      }
    }
    expect(diagnosisFor({ ...base, own_claim_state: "closed" })).toMatch(/never give, guess or imply one/);
  });

  it("own processed claim → answer_from_status (already approved)", async () => {
    const world: MockWorld = {
      profile: { ...unclaimedProfile(), isClaimed: true, workspaces: [{ email: OWNER_EMAIL, isClaimed: true }] },
      claims: [ownClaim({ status: "processed" })],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("processed");
    expect(out.support_action).toBe("answer_from_status");
  });

  it("own reverted claim → handoff (security-sensitive)", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim({ status: "reverted" })] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("reverted");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet.action_type).toBe("profile-claim");
  });

  it("multiple own claims → multiple → handoff", async () => {
    const world: MockWorld = {
      profile: unclaimedProfile(),
      claims: [ownClaim(), ownClaim({ id: "claim-2", status: "rejected" })],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("multiple");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet.own_claim_ids).toEqual(["claim-1", "claim-2"]);
  });

  it("unknown claim status → handoff, never self-serve", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim({ status: "weird_new_state" })] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("unknown");
    expect(out.support_action).toBe("create_handoff_ticket");
  });

  it("no claims + unclaimed profile → answer_from_status (guide the in-app claim flow)", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("none");
    expect(out.claim_conflict).toBe("none");
    expect(out.support_action).toBe("answer_from_status");
  });
});

describe("profile_claim_status — conflicts and suspicion", () => {
  // caroline-read-state-tools-r1: nothing about another account's claims leaves the tool. Not a
  // count, not a conflict value, not a flag, and not a changed route (a hand-off that fires only
  // when a stranger has a pending claim is a one-bit answer about that stranger).
  it("a pending claim by someone else is invisible: the output is byte-identical to a profile with no claims", async () => {
    const withRival = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [otherClaim()] })), { profile_id: PROFILE_ID });
    const empty = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [] })), { profile_id: PROFILE_ID });

    expect(withRival).toEqual(empty);
    expect(withRival.own_claim_state).toBe("none");
    expect(withRival.claim_conflict).toBe("none");
    expect(withRival.other_claims).toBeUndefined();
    expect(withRival.support_action).toBe("answer_from_status");
    const raw = JSON.stringify(withRival);
    expect(raw).not.toContain(OTHER_EMAIL);
    expect(raw).not.toContain("rival.example.com");
    expect(raw).not.toContain("claim-9");
    expect(raw).not.toContain("Rival Team");
    expect(raw).not.toMatch(/pending_claim_by_other|other_pending|multiple_pending_claims/);
  });

  it("own pending claim + someone else's pending or reverted claim → identical to the own claim alone", async () => {
    const alone = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [ownClaim()] })), { profile_id: PROFILE_ID });
    for (const rival of [otherClaim(), otherClaim({ status: "reverted" }), otherClaim({ status: "processed" })]) {
      const out = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [ownClaim(), rival] })), { profile_id: PROFILE_ID });
      expect(out).toEqual(alone);
    }
    expect(alone.own_claim_state).toBe("pending");
    expect(alone.support_action).toBe("answer_from_status");
  });

  it("profile claimed by another workspace, no claims → handoff with profile_claimed_by_other", async () => {
    const world: MockWorld = {
      profile: { id: PROFILE_ID, name: "Aasis Beats", isClaimed: true, workspaces: [{ email: OTHER_EMAIL, isClaimed: true }] },
      claims: [],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.profile.state).toBe("claimed_by_other");
    expect(out.claim_conflict).toBe("profile_claimed_by_other");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(JSON.stringify(out)).not.toContain(OTHER_EMAIL);
  });

  it("own pending claim with no verification links → suspicion flag downgrades to handoff", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim({ verificationLinks: [] })] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.suspicion_flags).toContain("own_claim_missing_verification_links");
    expect(out.support_action).toBe("create_handoff_ticket");
  });

  it("shared profile (co-claimers) with own pending claim → suspicion flag → handoff", async () => {
    const world: MockWorld = {
      profile: {
        id: PROFILE_ID,
        name: "Aasis Beats",
        isClaimed: true,
        workspaces: [
          { email: OWNER_EMAIL, isClaimed: true },
          { email: "bandmate@example.com", isClaimed: true },
        ],
      },
      claims: [ownClaim()],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.suspicion_flags).toContain("shared_profile_ownership");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(JSON.stringify(out)).not.toContain("bandmate@example.com");
  });

  it("verification links contents are NEVER emitted, even for the customer's own claim", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.own_claims[0].has_verification_links).toBe(true);
    expect(JSON.stringify(out)).not.toContain("instagram.com");
  });
});

describe("profile_claim_status — an id or an email from the thread is never an identity", () => {
  it("a pasted claim id is not a parameter: the by-id endpoint is never called and no own/not_own answer exists", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [], claimById: { "claim-9": otherClaim() } };
    const deps = makeDeps(world);
    const tool = createProfileClaimStatusTool(deps);
    expect(Object.keys((tool.parameters as any).properties)).not.toContain("claim_id");

    const out = await call(tool, { profile_id: PROFILE_ID, claim_id: "claim-9" });
    const paths = (deps.adminClient.get as any).mock.calls.map((c: unknown[]) => String(c[0]));
    expect(paths.some((p: string) => /\/claiming\/[^?]/.test(p))).toBe(false);
    expect(out.by_id_lookup).toBeUndefined();
    const raw = JSON.stringify(out);
    expect(raw).not.toContain("claim-9");
    expect(raw).not.toContain(OTHER_EMAIL);
    expect(raw).not.toContain("rival.example.com");
    expect(raw).not.toMatch(/not_own|not_retrievable/);
  });

  it("an email that is not the signed-in contact's never selects a profile (no search is made for it)", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [otherClaim()] };
    const deps = makeDeps(world);
    const out = await call(createProfileClaimStatusTool(deps), { email: OTHER_EMAIL });
    expect(out).toMatchObject({ found: false, reason: "missing_input", support_action: "ask_missing_info" });
    expect((deps.adminClient.get as any).mock.calls.length).toBe(0);
  });

  it("the signed-in contact's own email does select their profile", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const out = await call(createProfileClaimStatusTool(makeDeps(world)), { email: OWNER_EMAIL.toUpperCase() });
    expect(out.found).toBe(true);
    expect(out.own_claim_state).toBe("pending");
  });
});

describe("profile_claim_status — identity gates (fail closed)", () => {
  it.each([
    ["a lead (email typed in the messenger)", { role: "lead", externalId: null }, "contact_not_user"],
    ["a user with no external_id", { externalId: null }, "contact_no_external_id"],
    ["a contact created in the last 24 h", { contactCreatedAt: 1_793_000_000 - 3600 }, "contact_too_new"],
  ])("%s is not a signed-in owner → fail closed, the admin API is never queried", async (_label, over, reason) => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const deps = makeDeps(world, { intercomReader: signedInReader(OWNER_EMAIL, over), nowSeconds: () => 1_793_000_000 });
    const out = await call(createProfileClaimStatusTool(deps), { profile_id: PROFILE_ID });
    expect(out.found).toBe(false);
    expect(out.owner_undetermined).toBe(true);
    expect(out.own_claims).toEqual([]);
    expect(out.notes.join(" ")).toContain(reason);
    expect((deps.adminClient.get as any).mock.calls.length).toBe(0);
  });

  it("unverifiable anchor → fail-closed verdict; the claiming endpoints are NOT queried", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const deps = makeDeps(world, { intercomReader: signedInReader(null) });
    const tool = createProfileClaimStatusTool(deps);
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.found).toBe(false);
    expect(out.owner_undetermined).toBe(true);
    expect(out.own_claims).toEqual([]);
    expect(out.support_action).toBe("human_review");
    expect((deps.adminClient.get as any).mock.calls.length).toBe(0);
  });

  it("non-intercom session key (no convId) fails closed without any network call", async () => {
    const world: MockWorld = { profile: unclaimedProfile() };
    const reader = signedInReader(OWNER_EMAIL) as IntercomReader;
    const deps = makeDeps(world, { intercomReader: reader, sessionKey: "agent:support:main" });
    const tool = createProfileClaimStatusTool(deps);
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.owner_undetermined).toBe(true);
    expect(reader.getContactIdentity).not.toHaveBeenCalled();
    expect((deps.adminClient.get as any).mock.calls.length).toBe(0);
  });

  it("typed email mismatching the verified contact → impersonation_flag, fail closed", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const deps = makeDeps(world);
    const tool = createProfileClaimStatusTool(deps);
    const out = await call(tool, { profile_id: PROFILE_ID, requesterEmail: "attacker@example.com" });

    expect(out.impersonation_flag).toBe(true);
    expect(out.own_claims).toEqual([]);
    expect((deps.adminClient.get as any).mock.calls.length).toBe(0);
  });
});

describe("profile_claim_status — resolution and failure paths", () => {
  it("no identifying input → missing_input with ask_missing_info", async () => {
    const tool = createProfileClaimStatusTool(makeDeps({}));
    const out = await call(tool, {});
    expect(out).toMatchObject({ found: false, reason: "missing_input", support_action: "ask_missing_info", missing_fields: ["profile URL"] });
  });

  it("claim list fetch failure → lookup_unavailable, never a fabricated diagnosis", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), failPaths: [/\/claiming\?/] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out).toMatchObject({ found: false, reason: "lookup_unavailable" });
  });

  it("a 200 without the expected items array is schema drift → lookup_unavailable, not 'zero claims'", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), malformedList: true };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out).toMatchObject({ found: false, reason: "lookup_unavailable" });
  });

  // ---- the list is read whole, or declared unread (QA review of hydra#1902) ----------------
  const others = (n: number) => Array.from({ length: n }, (_, i) => otherClaim({ id: `o-${i}`, status: i % 2 ? "pending" : "rejected" }));

  it("the customer's own claim is found wherever it sits in the list, not only in the first rows", async () => {
    for (const at of [0, 20, 25, 99, 100, 250]) {
      const claims = others(260);
      claims.splice(at, 0, ownClaim({ id: "mine" }));
      const world: MockWorld = { profile: unclaimedProfile(), claims };
      const out = await call(createProfileClaimStatusTool(makeDeps(world)), { profile_id: PROFILE_ID });
      expect(out.own_claim_state, `own row at ${at}`).toBe("pending");
      expect(out.own_claims.map((c: any) => c.claim_id), `own row at ${at}`).toEqual(["mine"]);
      expect(out.support_action, `own row at ${at}`).toBe("answer_from_status");
      expect(out.notes, `own row at ${at}`).toEqual([]);
    }
  });

  it("other accounts' claims change NOTHING in the answer: 0, 1, 21, 100, 101 and 400 of them read the same", async () => {
    const answer = async (claims: ClaimRow[]) => {
      const result = await createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims })).execute("call-1", { profile_id: PROFILE_ID } as any);
      return (result.content[0] as any).text as string;
    };
    const none = await answer([]);
    expect(JSON.parse(none)).toMatchObject({ own_claim_state: "none", support_action: "answer_from_status", notes: [] });
    for (const n of [1, 21, 100, 101, 400]) expect(await answer(others(n)), `${n} other claims`).toBe(none);
    // And the same with an own pending claim in the list.
    const mine = await answer([ownClaim({ id: "mine" })]);
    for (const n of [21, 101, 400]) expect(await answer([...others(n), ownClaim({ id: "mine" })]), `${n} other claims`).toBe(mine);
  });

  const unread: Array<[string, Partial<MockWorld>, number]> = [
    ["more pages than the cap", {}, 501],
    ["paging is not honoured (every page is the first one)", { ignorePage: true }, 150],
    ["a later page fails", { failListPage: 2 }, 150],
    ["a full page with no total", { noTotal: true }, 100],
  ];
  for (const [why, world, n] of unread) {
    it(`a list that could not be read whole is NEVER "you have no claim": ${why}`, async () => {
      const result = await createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: others(n), ...world })).execute("call-1", { profile_id: PROFILE_ID } as any);
      const text = (result.content[0] as any).text as string;
      const out = JSON.parse(text);
      expect(out.own_claim_state).toBe("unknown");
      expect(out.support_action).toBe("create_handoff_ticket");
      expect(out.diagnosis).toMatch(/could not be read/);
      expect(out.diagnosis).toMatch(/Never say they have none/);
      expect(text).not.toMatch(/no claim request of their own/);
      // Neutral: it says the read was partial, never how many claims the profile carries.
      expect(out.notes.join(" ")).toContain("could not be read in full");
      expect(text).not.toContain(String(n));
      expect(out.notes.join(" ")).not.toMatch(/\d/);
      expect(text).not.toContain(OTHER_EMAIL);
    });
  }

  it("a partial list that does show an own pending claim goes to a person, and still marks the open request", async () => {
    const claims = [ownClaim({ id: "mine" }), ...others(600)];
    const out = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims })), { profile_id: PROFILE_ID });
    expect(out.own_claim_state).toBe("pending");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.notes.join(" ")).toContain("could not be read in full");
  });

  it("a short page with no total is the whole list", async () => {
    const out = await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: others(3), noTotal: true })), { profile_id: PROFILE_ID });
    expect(out).toMatchObject({ own_claim_state: "none", support_action: "answer_from_status", notes: [] });
  });

  it("one read for an ordinary profile; further pages only while the total is not reached", async () => {
    const one: string[] = [];
    await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: others(21), listCalls: one })), { profile_id: PROFILE_ID });
    expect(one).toHaveLength(1);
    expect(one[0]).not.toContain("page=");
    const three: string[] = [];
    await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: others(250), listCalls: three })), { profile_id: PROFILE_ID });
    expect(three.map((u) => new URLSearchParams(u.split("?")[1]).get("page"))).toEqual([null, "2", "3"]);
    const capped: string[] = [];
    await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: others(5000), listCalls: capped })), { profile_id: PROFILE_ID });
    expect(capped).toHaveLength(5);
  });

  it("rate limit → rate_limited structured failure", async () => {
    const deps = makeDeps({ profile: unclaimedProfile(), claims: [] });
    const tool = createProfileClaimStatusTool(deps);
    for (let i = 0; i < 10; i++) await call(tool, { profile_id: PROFILE_ID });
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out).toMatchObject({ found: false, reason: "rate_limited" });
  });
});

describe("profile_claim_status — pure helpers", () => {
  const base = {
    claim_conflict: "none" as const,
    suspicion_flags: [] as string[],
    profile_state: "unclaimed" as const,
  };

  it("supportActionFor: a pending own claim is answered from status only when clean, and never routes to a claim write", () => {
    expect(supportActionFor({ ...base, own_claim_state: "pending" })).toBe("answer_from_status");
    expect(supportActionFor({ ...base, own_claim_state: "pending", claim_conflict: "profile_claimed_by_other" })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "pending", suspicion_flags: ["own_claim_missing_verification_links"] })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "pending", needs_person: true })).toBe("create_handoff_ticket");
  });

  it("supportActionFor: terminal states", () => {
    expect(supportActionFor({ ...base, own_claim_state: "rejected" })).toBe("answer_from_status");
    expect(supportActionFor({ ...base, own_claim_state: "processed" })).toBe("answer_from_status");
    expect(supportActionFor({ ...base, own_claim_state: "reverted" })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "multiple" })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "none", claim_conflict: "profile_claimed_by_other" })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "none" })).toBe("answer_from_status");
  });

  it("failClosedVerdict carries no claim data and routes to a human", () => {
    const v = failClosedVerdict(["note"]);
    expect(v).toMatchObject({ found: false, owner_undetermined: true, own_claims: [], support_action: "human_review" });
  });

  // The open_request fact the outbound guard reads (request-state-signal.ts).
  describe("open_request fact", () => {
    const FACT_KEY = "__musoSupportRequestState";
    const fact = () => ((globalThis as any)[FACT_KEY] as Map<string, { open: boolean }> | undefined)?.get("12345");
    const clear = () => ((globalThis as any)[FACT_KEY] as Map<string, unknown> | undefined)?.delete("12345");

    it("an own pending claim is a measured open request", async () => {
      clear();
      await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [ownClaim()] })), { profile_id: PROFILE_ID });
      expect(fact()?.open).toBe(true);
    });

    it("no own pending claim writes NOTHING: it is not a measurement of 'no open request'", async () => {
      clear();
      await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [] })), { profile_id: PROFILE_ID });
      expect(fact()).toBeUndefined();
      await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [ownClaim({ status: "rejected" })] })), { profile_id: PROFILE_ID });
      expect(fact()).toBeUndefined();
    });

    it("someone else's pending claim never writes the fact", async () => {
      clear();
      await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [otherClaim()] })), { profile_id: PROFILE_ID });
      expect(fact()).toBeUndefined();
    });

    it("a contact that fails the signed-in screen writes nothing", async () => {
      clear();
      const reader = signedInReader(null);
      await call(createProfileClaimStatusTool(makeDeps({ profile: unclaimedProfile(), claims: [ownClaim()] }, { intercomReader: reader })), { profile_id: PROFILE_ID });
      expect(fact()).toBeUndefined();
    });
  });
});

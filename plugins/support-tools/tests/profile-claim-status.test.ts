import { describe, it, expect, vi } from "vitest";
import { createProfileClaimStatusTool, supportActionFor, failClosedVerdict, type ClaimRow } from "../src/tools/profile-claim-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient, AdminClientResult } from "../src/muso-admin-client.js";
import type { IntercomReader } from "../src/intercom-client.js";

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
  failPaths?: RegExp[];
}

function makeAdminClient(world: MockWorld): MusoAdminClient {
  const get = vi.fn(async (path: string): Promise<AdminClientResult<unknown>> => {
    if ((world.failPaths ?? []).some((re) => re.test(path))) {
      return { ok: false, status: 500, error: "boom" };
    }
    if (/^\/api\/v3\/admin\/claiming\?profilesIds=/.test(path)) {
      if (world.malformedList) return { ok: true, status: 200, data: { data: {} } };
      return { ok: true, status: 200, data: { data: { items: world.claims ?? [] } } };
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
    intercomReader: { getAuthorEmail: vi.fn(async () => OWNER_EMAIL) } as IntercomReader,
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
  it("single own pending claim, no conflict → route_selfserve_claim with the claim id", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.found).toBe(true);
    expect(out.own_claim_state).toBe("pending");
    expect(out.own_claims).toHaveLength(1);
    expect(out.own_claims[0]).toMatchObject({ claim_id: "claim-1", status: "pending", has_verification_links: true });
    expect(out.claim_conflict).toBe("none");
    expect(out.suspicion_flags).toEqual([]);
    expect(out.support_action).toBe("route_selfserve_claim");
    expect(out.handoff_packet).toBeUndefined();
  });

  it("own rejected claim → answer_from_status with the sanitized reason", async () => {
    const world: MockWorld = {
      profile: unclaimedProfile(),
      claims: [ownClaim({ status: "rejected", reason: "[CUSTOMER_MESSAGE]name mismatch[/CUSTOMER_MESSAGE]" })],
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.own_claim_state).toBe("rejected");
    expect(out.own_claims[0].reason).toBe("name mismatch");
    expect(out.support_action).toBe("answer_from_status");
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
    expect(out.suspicion_flags).toContain("prior_reverted_claim_on_profile");
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
  it("pending claim by someone else → handoff; NO third-party email, link, or claim id in the output", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [otherClaim()] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.own_claim_state).toBe("none");
    expect(out.claim_conflict).toBe("pending_claim_by_other");
    expect(out.other_claims).toEqual({ pending_count: 1, prior_processed_or_reverted: false });
    expect(out.support_action).toBe("create_handoff_ticket");
    const raw = JSON.stringify(out);
    expect(raw).not.toContain(OTHER_EMAIL);
    expect(raw).not.toContain("rival.example.com");
    expect(raw).not.toContain("claim-9");
    expect(raw).not.toContain("Rival Team");
  });

  it("own pending claim + competing pending claim → handoff, not self-serve", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim(), otherClaim()] };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.own_claim_state).toBe("pending");
    expect(out.claim_conflict).toBe("pending_claim_by_other");
    expect(out.suspicion_flags).toContain("multiple_pending_claims_on_profile");
    expect(out.support_action).toBe("create_handoff_ticket");
    expect(out.handoff_packet).toMatchObject({
      action_type: "profile-claim",
      claim_conflict: "pending_claim_by_other",
      evidence: { other_pending_count: 1 },
    });
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

describe("profile_claim_status — by-id lookup", () => {
  it("claim_id given but endpoint answers {claiming:null} → not_retrievable_by_id, list still authoritative", async () => {
    const world: MockWorld = {
      profile: unclaimedProfile(),
      claims: [ownClaim({ status: "rejected" })],
      claimById: { "claim-1": null },
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID, claim_id: "claim-1" });

    expect(out.by_id_lookup).toEqual({ claim_id: "claim-1", result: "not_retrievable_by_id" });
    expect(out.own_claim_state).toBe("rejected");
    expect(out.notes.join(" ")).toContain("not retrievable directly");
  });

  it("claim_id resolving to someone else's claim → not_own, and its details never leak", async () => {
    const world: MockWorld = {
      profile: unclaimedProfile(),
      claims: [],
      claimById: { "claim-9": otherClaim() },
    };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID, claim_id: "claim-9" });

    expect(out.by_id_lookup).toEqual({ claim_id: "claim-9", result: "not_own" });
    const raw = JSON.stringify(out);
    expect(raw).not.toContain(OTHER_EMAIL);
    expect(raw).not.toContain("rival.example.com");
  });
});

describe("profile_claim_status — identity gates (fail closed)", () => {
  it("unverifiable anchor → fail-closed verdict; the claiming endpoints are NOT queried", async () => {
    const world: MockWorld = { profile: unclaimedProfile(), claims: [ownClaim()] };
    const deps = makeDeps(world, { intercomReader: { getAuthorEmail: vi.fn(async () => null) } });
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
    const reader = { getAuthorEmail: vi.fn(async () => OWNER_EMAIL) } as IntercomReader;
    const deps = makeDeps(world, { intercomReader: reader, sessionKey: "agent:support:main" });
    const tool = createProfileClaimStatusTool(deps);
    const out = await call(tool, { profile_id: PROFILE_ID });

    expect(out.owner_undetermined).toBe(true);
    expect(reader.getAuthorEmail).not.toHaveBeenCalled();
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

  it("more than the cap → truncation note", async () => {
    const claims = Array.from({ length: 21 }, (_, i) => otherClaim({ id: `c-${i}`, status: "rejected" }));
    const world: MockWorld = { profile: unclaimedProfile(), claims };
    const tool = createProfileClaimStatusTool(makeDeps(world));
    const out = await call(tool, { profile_id: PROFILE_ID });
    expect(out.notes.join(" ")).toContain("truncated");
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

  it("supportActionFor: pending self-serves only when clean", () => {
    expect(supportActionFor({ ...base, own_claim_state: "pending" })).toBe("route_selfserve_claim");
    expect(supportActionFor({ ...base, own_claim_state: "pending", claim_conflict: "pending_claim_by_other" })).toBe("create_handoff_ticket");
    expect(supportActionFor({ ...base, own_claim_state: "pending", suspicion_flags: ["prior_reverted_claim_on_profile"] })).toBe("create_handoff_ticket");
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
});

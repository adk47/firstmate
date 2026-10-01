import { describe, it, expect, vi } from "vitest";
import { resolveAnalyticsEntitlement, type AnalyticsEntitlementDeps } from "../src/analytics-entitlement.js";
import type { IntercomReader } from "../src/intercom-client.js";

const VERIFIED_EMAIL = "owner@example.com";
const SESSION_KEY = "agent:support:intercom:direct:CONV123";
const PROFILE_ID = "profile-abc";

function makeReader(email: string | null = VERIFIED_EMAIL, throws = false): IntercomReader {
  return {
    getAuthorEmail: vi.fn(async () => {
      if (throws) throw new Error("intercom unavailable");
      return email;
    }),
    getLatestCustomerPart: vi.fn(async () => null),
  };
}

type ExecImpl = NonNullable<AnalyticsEntitlementDeps["execFileImpl"]>;
interface MockExec {
  impl: ExecImpl;
  calls: { file: string; args: readonly string[] }[];
}

// Queue of responses, consumed in call order — step 2 (users search), step 3
// (teams list), then one step-4 (teams seats get) per candidate workspace.
function makeExec(responses: Array<{ stdout?: string; rejectWith?: Error }>): MockExec {
  const calls: MockExec["calls"] = [];
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

function makeDeps(overrides: Partial<AnalyticsEntitlementDeps> = {}): AnalyticsEntitlementDeps {
  return {
    profileId: PROFILE_ID,
    sessionKey: SESSION_KEY,
    intercomReader: makeReader(),
    intercomToken: "tok",
    execFileImpl: makeExec([{ stdout: JSON.stringify({ items: [] }) }]).impl,
    ...overrides,
  };
}

// Shapes below mirror the frozen golden CLI contracts (muso-cli/internal/cli/testdata/golden/),
// not the in-process Sequelize field names — `users search` ids are numeric, and
// `teams seats get` emits id/seatStatus (lowercase status), never seatId/status.
function usersSearchResult(rows: Array<{ id: number; email: string }>) {
  return JSON.stringify({ items: rows });
}

function teamsListResult(teamIds: string[]) {
  return JSON.stringify({ items: teamIds.map((id) => ({ id })) });
}

function seatsGetResult(seats: Array<{ id: string; seatStatus: string }>) {
  return JSON.stringify({ items: seats });
}

describe("resolveAnalyticsEntitlement", () => {
  it("grants active_seat when the verified user holds an ACTIVE seat for the profile", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      { stdout: seatsGetResult([{ id: PROFILE_ID, seatStatus: "active" }]) },
    ]);
    const deps = makeDeps({ execFileImpl: exec.impl, env: "dev" });
    const out = await resolveAnalyticsEntitlement(deps);
    expect(out).toEqual({ entitled: true, grant: "active_seat", workspaceId: "team-1" });
    // Anti-spoof anchoring at its FIRST link: the email must come from the
    // conversation derived off the trusted sessionKey (CONV123), never from
    // a model tool-arg like profileId -- a mock that ignores its inputs and
    // returns a fixed email cannot be trusted to prove this on its own.
    expect(deps.intercomReader.getAuthorEmail).toHaveBeenCalledWith("CONV123", "tok");
    // Anchoring at the muso CLI hop, asserted directly on the argv -- not
    // just on the returned decision. Each call must be scoped to the
    // VERIFIED contact (never profileId), the exact requested profile, and
    // the given env.
    expect(exec.calls).toHaveLength(3);
    expect(exec.calls[0].args).toEqual(["users", "search", VERIFIED_EMAIL, "--env", "dev", "--json"]);
    expect(exec.calls[1].args).toEqual([
      "teams",
      "list",
      "--user-id",
      "5001",
      "--seat-id",
      PROFILE_ID,
      "--env",
      "dev",
      "--json",
    ]);
    expect(exec.calls[2].args).toEqual(["teams", "seats", "get", "team-1", "--env", "dev", "--json"]);
  });

  it("grants active_seat off the SECOND candidate workspace when the first has no ACTIVE seat (per-row scoping)", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1", "team-2"]) },
      { stdout: seatsGetResult([{ id: PROFILE_ID, seatStatus: "paused" }]) },
      { stdout: seatsGetResult([{ id: PROFILE_ID, seatStatus: "active" }]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl, env: "dev" }));
    expect(out).toEqual({ entitled: true, grant: "active_seat", workspaceId: "team-2" });
    // Each candidate workspace must be probed with ITS OWN team id -- a loop
    // that reuses the first row for every iteration would still "work" on a
    // single-candidate suite but silently skip every workspace after the first.
    expect(exec.calls).toHaveLength(4);
    expect(exec.calls[2].args).toEqual(["teams", "seats", "get", "team-1", "--env", "dev", "--json"]);
    expect(exec.calls[3].args).toEqual(["teams", "seats", "get", "team-2", "--env", "dev", "--json"]);
  });

  it("closes the same-owner-two-workspaces case (MUS-1476 AC): a different workspace's own standing never substitutes for THIS profile's seat", async () => {
    // CTO AC on MUS-1476: the Caroline stop-gap's prose rule correlates two
    // SEPARATELY EMAIL-KEYED reads (credit-verification-check's ownership
    // dedupe vs subscription-status's workspace pick) and can land on two
    // different workspaces of the same owner -- plan on workspace A, profile
    // claimed under workspace B -- over-granting off A's plan. This module
    // cannot reproduce that: it never reads plan/subscription state at all
    // (see "never compares plan" below), and step 3's --seat-id argument is
    // a server-side inner join on RosterSeats, so a workspace with no seat
    // for THIS profile is never even returned as a candidate here — there is
    // no separately-keyed read for a plan check to leak through.
    //
    // Modelled as a two-candidate fan-out (defense in depth: still correct
    // even if --seat-id ever regressed and a same-owner workspace with no
    // bearing on this profile leaked into the candidate list): workspace-A
    // has SOME active seat of its own (its good standing), but not for this
    // profile; workspace-B holds the actual ACTIVE seat for this profile.
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["workspace-A", "workspace-B"]) },
      { stdout: seatsGetResult([{ id: "unrelated-profile-in-A", seatStatus: "active" }]) },
      { stdout: seatsGetResult([{ id: PROFILE_ID, seatStatus: "active" }]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: true, grant: "active_seat", workspaceId: "workspace-B" });
    // The mechanism that structurally excludes a same-owner-but-irrelevant
    // workspace in the real system: candidate resolution is scoped to THIS
    // profile, not merely "any workspace this user belongs to".
    const teamsListArgs = exec.calls[1].args;
    expect(teamsListArgs).toContain("--seat-id");
    expect(teamsListArgs[teamsListArgs.indexOf("--seat-id") + 1]).toBe(PROFILE_ID);
  });

  it("denies no_active_seat when the seat exists but is paused", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      { stdout: seatsGetResult([{ id: PROFILE_ID, seatStatus: "paused" }]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "no_active_seat", routeToHuman: false });
  });

  it("denies no_active_seat when the workspace has an ACTIVE seat for a DIFFERENT profile (per-profile gate)", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      {
        stdout: seatsGetResult([
          { id: "other-profile-999", seatStatus: "active" },
          { id: PROFILE_ID, seatStatus: "paused" },
        ]),
      },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "no_active_seat", routeToHuman: false });
  });

  it("denies no_active_seat on a past_due workspace regardless of plan string — never compares plan", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      {
        stdout: JSON.stringify({
          items: [{ id: PROFILE_ID, seatStatus: "paused" }],
          subscription: { plan: "business_annual", status: "past_due" },
        }),
      },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "no_active_seat", routeToHuman: false });
  });

  it("denies profile_not_in_workspace and never calls seats get when step 3 returns no items", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult([]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "profile_not_in_workspace", routeToHuman: false });
    expect(exec.calls).toHaveLength(2);
    expect(exec.calls.some((c) => c.args.includes("get"))).toBe(false);
  });

  it("denies owner_undetermined with no exec calls when no conv id is derivable from the session key", async () => {
    const exec = makeExec([{ stdout: "{}" }]);
    const out = await resolveAnalyticsEntitlement(
      makeDeps({ sessionKey: "not-a-valid-session-key", execFileImpl: exec.impl }),
    );
    expect(out).toEqual({ entitled: false, reason: "owner_undetermined", routeToHuman: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("denies owner_undetermined with no exec calls when the intercom token is empty", async () => {
    const exec = makeExec([{ stdout: "{}" }]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ intercomToken: "", execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "owner_undetermined", routeToHuman: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("denies check_unavailable and routes to human when getAuthorEmail throws", async () => {
    const exec = makeExec([{ stdout: "{}" }]);
    const out = await resolveAnalyticsEntitlement(
      makeDeps({ intercomReader: makeReader(null, true), execFileImpl: exec.impl }),
    );
    expect(out).toEqual({ entitled: false, reason: "check_unavailable", routeToHuman: true });
    expect(exec.calls).toHaveLength(0);
  });

  it("denies account_not_resolved when two rows merely CONTAIN the verified email as a substring", async () => {
    const exec = makeExec([
      {
        stdout: usersSearchResult([
          { id: 5001, email: `prefix-${VERIFIED_EMAIL}` },
          { id: 5002, email: `${VERIFIED_EMAIL}-suffix` },
        ]),
      },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "account_not_resolved", routeToHuman: true });
  });

  it("denies account_not_resolved when the ONLY row merely CONTAINS the verified email (substring iLike)", async () => {
    // The two-row test above proves the re-filter via the >1 count -- it
    // never actually exercises the exact-match filter itself. At exactly one
    // substring-superset row the count check is inert (1 !== 1 is false), so
    // this is the only case that pins the filter as load-bearing rather than
    // decorative: deleting it entirely would still deny via the count check
    // in the two-row case but would silently grant here.
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 9999, email: `${VERIFIED_EMAIL}.bak@acme.example` }]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "account_not_resolved", routeToHuman: true });
    // Must never reach `teams list` with the stranger's id.
    expect(exec.calls).toHaveLength(1);
  });

  it("denies account_not_resolved with a human route when the matched user row has no id (data anomaly, D6)", async () => {
    const exec = makeExec([
      { stdout: JSON.stringify({ items: [{ email: VERIFIED_EMAIL }] }) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "account_not_resolved", routeToHuman: true });
    // Must fail before ever calling `teams list` with a bogus "undefined" --user-id.
    expect(exec.calls).toHaveLength(1);
  });

  it("denies check_unavailable and never returns entitled:true when teams seats get exits non-zero", async () => {
    const err = Object.assign(new Error("exit 1"), { stderr: "boom" });
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["team-1"]) },
      { rejectWith: err },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "check_unavailable", routeToHuman: true });
  });

  it("denies account_not_resolved with zero seats-get calls when there are more than 5 candidate workspaces", async () => {
    const exec = makeExec([
      { stdout: usersSearchResult([{ id: 5001, email: VERIFIED_EMAIL }]) },
      { stdout: teamsListResult(["t1", "t2", "t3", "t4", "t5", "t6"]) },
    ]);
    const out = await resolveAnalyticsEntitlement(makeDeps({ execFileImpl: exec.impl }));
    expect(out).toEqual({ entitled: false, reason: "account_not_resolved", routeToHuman: true });
    expect(exec.calls.filter((c) => c.args.includes("get"))).toHaveLength(0);
  });
});

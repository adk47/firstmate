/**
 * The one assignment policy (intercom-no-human-assignment-k1, captain 2026-11-11: "cut this to zero
 * and have Caroline handle all of them"). Measured before: 485 assignments to one person in 14 days,
 * 478 made by this plugin through `account.defaultInboxId`.
 */
import { describe, it, expect, vi } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import {
  AI_QUEUE_KINDS,
  DEFAULT_HUMAN_HOLD_HOURS,
  EscalationReasonRequired,
  applyHandOff,
  humanHold,
  lastHumanReplyAt,
  oldestCustomerPartAfter,
  escalationGoesToQueue,
  QUEUE_ESCALATION_REASONS,
  DEFAULT_REPLY_GRACE_HOURS,
  resolveHandOffTarget,
  type HandOffKind,
  botPlacedInTeam,
} from "../src/assignment-policy.js";

const account = { botAdminId: "bot", escalationTeamId: "7111842" };
const NOW = Date.parse("2026-11-11T12:00:00Z");
const H = 3600 * 1000;

describe("resolveHandOffTarget", () => {
  it.each(["output_guard", "help_link_drop", "reasoning_leak"] as HandOffKind[])(
    "%s stays in the AI queue: a code gate on Caroline's text is not a reason for a person",
    (kind) => {
      const t = resolveHandOffTarget(account, kind);
      expect(t).toMatchObject({ queue: "ai", human: false });
      expect(AI_QUEUE_KINDS.has(kind)).toBe(true);
      // Even a caller that supplies a reason cannot turn a blocked reply into an escalation.
      expect(resolveHandOffTarget(account, kind, "legal_threat").queue).toBe("ai");
    },
  );
  it.each(["risk_escalation", "restricted_hold", "legacy_escalation"] as HandOffKind[])(
    "%s goes to the escalation TEAM and carries its reason",
    (kind) => {
      expect(resolveHandOffTarget(account, kind, "rule/legal_threat")).toEqual({
        queue: "escalation_team", human: true, reason: "rule/legal_threat", label: "team:7111842",
      });
    },
  );
  it.each([undefined, "", "   "])("an escalation with no reason (%j) is refused", (reason) => {
    expect(() => resolveHandOffTarget(account, "risk_escalation", reason)).toThrow(EscalationReasonRequired);
  });
  it("no escalation team configured -> Intercom's Unassigned, never a person", () => {
    expect(resolveHandOffTarget({ botAdminId: "bot" }, "risk_escalation", "r")).toMatchObject({ queue: "unassigned", label: "Unassigned" });
    expect(resolveHandOffTarget({ botAdminId: "bot", escalationTeamId: "not-a-number" }, "risk_escalation", "r").queue).toBe("unassigned");
  });
  it("a retired defaultInboxId on the account object is not read", () => {
    const t = resolveHandOffTarget({ botAdminId: "bot", defaultInboxId: "5465657" } as never, "risk_escalation", "r");
    expect(t.queue).toBe("unassigned");
    expect(JSON.stringify(t)).not.toContain("5465657");
  });
});

describe("applyHandOff", () => {
  const client = () => ({ assignConversation: vi.fn(async () => ({})) });
  /**
   * A client that behaves like Intercom: an accepted assignment changes who holds the conversation,
   * and the read-back reports it. `afterCall(n, holder)` lets a test change the holder right after
   * the nth accepted assignment (somebody else acting in between).
   */
  const tracking = (start: { admin: string | number | null; team: string | number | null } = { admin: "bot", team: null }) => {
    const holder = { ...start };
    const hooks = new Map<number, Partial<typeof holder>>();
    let n = 0;
    return {
      holder,
      afterCall(call: number, change: Partial<typeof holder>) { hooks.set(call, change); return this; },
      assignConversation: vi.fn(async (params: { assigneeId: string; assigneeType?: "admin" | "team" }) => {
        if (params.assigneeType === "team") holder.team = Number(params.assigneeId);
        else holder.admin = params.assigneeId === "0" ? null : params.assigneeId;
        Object.assign(holder, hooks.get(n++) ?? {});
        return {};
      }),
      getConversation: vi.fn(async () => ({ admin_assignee_id: holder.admin, team_assignee_id: holder.team })),
    };
  };
  it("AI-queue kinds make no Intercom call at all", async () => {
    const c = client();
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "output_guard" });
    expect(r.outcome).toBe("ai_queue");
    expect(c.assignConversation).not.toHaveBeenCalled();
  });
  it("an escalation takes the bot off, then places the team with type team", async () => {
    const c = tracking();
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "rule/legal_threat" });
    expect(r).toMatchObject({ outcome: "escalation_team", human: true, reason: "rule/legal_threat" });
    expect(c.assignConversation.mock.calls.map((x) => x[0])).toEqual([
      { conversationId: "c1", adminId: "bot", assigneeId: "0" },
      { conversationId: "c1", adminId: "bot", assigneeId: "7111842", assigneeType: "team" },
    ]);
    // the outcome came from a read, not from the two accepted requests
    expect(c.getConversation).toHaveBeenCalledWith({ conversationId: "c1" });
  });
  it("never sends an admin-typed assignment to anything but '0'", async () => {
    const c = client();
    for (const kind of ["risk_escalation", "restricted_hold", "legacy_escalation"] as HandOffKind[]) {
      await applyHandOff({ client: c, account, conversationId: "c", kind, reason: "r" });
    }
    for (const [p] of c.assignConversation.mock.calls as unknown as [{ assigneeId: string; assigneeType?: string }][]) {
      if (p.assigneeType !== "team") expect(p.assigneeId).toBe("0");
    }
  });
  it("no team configured: one call, to Unassigned, confirmed by a read", async () => {
    const c = tracking();
    const r = await applyHandOff({ client: c, account: { botAdminId: "bot" }, conversationId: "c1", kind: "restricted_hold", reason: "restricted_account" });
    expect(r.outcome).toBe("unassigned");
    expect(c.assignConversation).toHaveBeenCalledTimes(1);
    expect(c.getConversation).toHaveBeenCalledTimes(1);
  });
  // QA on #1892, round 4: ACCEPTED requests are not proof of who holds the conversation either.
  describe("accepted requests are still settled by a read-back", () => {
    const esc = (c: { assignConversation: ReturnType<typeof vi.fn>; getConversation?: ReturnType<typeof vi.fn> }, acct = account) => {
      const errors: string[] = [];
      return applyHandOff({ client: c, account: acct, conversationId: "c1", kind: "risk_escalation", reason: "r", log: { error: (m) => errors.push(m) } })
        .then((r) => ({ r, errors }));
    };
    // The reviewed path: unassign accepted, an admin takes the thread, the team POST is accepted
    // too (Intercom lets an admin and a team hold a conversation together).
    it("an admin took it between the two calls and the team POST succeeded: failed, naming the admin", async () => {
      const c = tracking().afterCall(0, { admin: 5465657 });
      const { r, errors } = await esc(c);
      expect(c.assignConversation).toHaveBeenCalledTimes(2);
      expect(c.holder).toEqual({ admin: 5465657, team: 7111842 });
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/the team step was accepted and admin 5465657 holds the conversation/);
      expect(errors[0]).toMatch(/\[intercom:ALERT\].*team assign FAILED/);
    });
    it("both requests accepted but the conversation cannot be read: failed, holder unknown", async () => {
      const c = { assignConversation: vi.fn(async () => ({})), getConversation: vi.fn(async () => { throw new Error("timeout"); }) };
      const { r } = await esc(c);
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/could not be read back, so who holds it is unknown/);
    });
    it("a client with no read-back cannot complete an escalation at all", async () => {
      expect((await esc(client())).r.outcome).toBe("failed");
      expect((await esc(client(), { botAdminId: "bot" })).r.outcome).toBe("failed");
    });
    it("the team POST was accepted but the read shows another team: failed, labelled with it", async () => {
      const c = tracking().afterCall(1, { team: 2238258 });
      const { r } = await esc(c);
      expect(r).toMatchObject({ outcome: "failed", label: "team:2238258" });
    });
    it("the team POST was accepted but the read shows no team: Unassigned, with an alert", async () => {
      const c = tracking().afterCall(1, { team: null });
      const { r, errors } = await esc(c);
      expect(r).toMatchObject({ outcome: "unassigned", queue: "unassigned", label: "Unassigned" });
      expect(errors[0]).toMatch(/team assign FAILED.*left in Unassigned/);
    });
    it("the bot still shows as the holder after an accepted unassign: failed, never a queue", async () => {
      const c = tracking().afterCall(0, { admin: "bot" });
      const { r } = await esc(c);
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/the bot holds the conversation/);
    });
    // No escalation team configured: "Unassigned" means no admin AND no team.
    it("no team configured, unassign accepted, but a team holds it: failed, labelled with that team", async () => {
      const c = tracking({ admin: "bot", team: 2238258 });
      const { r, errors } = await esc(c, { botAdminId: "bot" });
      expect(c.assignConversation).toHaveBeenCalledTimes(1);
      expect(r).toMatchObject({ outcome: "failed", label: "team:2238258" });
      expect(r.error).toMatch(/in team 2238258, not Unassigned/);
      expect(errors[0]).toMatch(/\[intercom:ALERT\].*unassign FAILED/);
    });
    it("no team configured and an admin took it after the unassign: failed", async () => {
      const c = tracking().afterCall(0, { admin: 5465657 });
      expect((await esc(c, { botAdminId: "bot" })).r.outcome).toBe("failed");
    });
  });
  it("a failed unassign is reported as failed (the bot still holds it) and the team step is skipped", async () => {
    const c = { assignConversation: vi.fn(async () => { throw new Error("403"); }) };
    const errors: string[] = [];
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r", log: { error: (m) => errors.push(m) } });
    expect(r.outcome).toBe("failed");
    expect(c.assignConversation).toHaveBeenCalledTimes(1);
    expect(errors[0]).toMatch(/\[intercom:ALERT\].*unassign FAILED/);
  });
  // QA on #1892: a team step that does not complete is reported from a read-back, never from
  // "the unassign was accepted a moment ago". An admin can take the thread between the two calls.
  describe("a team step that fails (not a conflict) is settled by a read-back", () => {
    const teamFails = (holder: unknown) => {
      let n = 0;
      return {
        assignConversation: vi.fn(async () => { if (n++ === 1) throw new Error("team not found"); return {}; }),
        getConversation: vi.fn(async () => {
          if (holder instanceof Error) throw holder;
          return holder as { admin_assignee_id?: string | number | null; team_assignee_id?: string | number | null };
        }),
      };
    };
    const go = (c: { assignConversation: ReturnType<typeof vi.fn>; getConversation?: ReturnType<typeof vi.fn> }) =>
      applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r" });

    it("read back shows nobody and no team: Unassigned, which is still nobody's personal inbox", async () => {
      const r = await go(teamFails({ admin_assignee_id: null, team_assignee_id: null }));
      expect(r).toMatchObject({ outcome: "unassigned", queue: "unassigned", label: "Unassigned" });
      expect(r.error).toMatch(/team not found/);
    });
    it("an admin took it between the two calls: failed, naming the admin, never Unassigned", async () => {
      const r = await go(teamFails({ admin_assignee_id: 5465657, team_assignee_id: null }));
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/admin 5465657 holds the conversation/);
    });
    it("the read-back times out: failed (holder unknown), never Unassigned", async () => {
      const r = await go(teamFails(new Error("timeout")));
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/who holds it is unknown/);
    });
    it("a client that cannot read back: failed, never Unassigned", async () => {
      let n = 0;
      const c = { assignConversation: vi.fn(async () => { if (n++ === 1) throw new Error("team not found"); return {}; }) };
      expect((await go(c)).outcome).toBe("failed");
    });
    it("it sits in some other team: failed, and the label says which team", async () => {
      const r = await go(teamFails({ admin_assignee_id: null, team_assignee_id: 2238258 }));
      expect(r).toMatchObject({ outcome: "failed", label: "team:2238258" });
      expect(r.error).toMatch(/in team 2238258, not the escalation team 7111842/);
    });
    it("the read shows the escalation team and no admin: that is where it is", async () => {
      expect((await go(teamFails({ admin_assignee_id: null, team_assignee_id: 7111842 }))).outcome).toBe("escalation_team");
    });
    // QA on #1892: `{admin_assignee_id: null}` with NO team field once read as "no admin and no
    // team", so the hand-off was reported complete while the team was never measured.
    it("a PARTIAL read (no team field) is not a measurement: failed, never Unassigned", async () => {
      const r = await go(teamFails({ admin_assignee_id: null }));
      expect(r.outcome).toBe("failed");
      expect(r.outcome).not.toBe("unassigned");
      expect(r.error).toMatch(/could not be read back, so who holds it is unknown/);
    });
    it("a PARTIAL read (no admin field) is not a measurement either: failed, never the team", async () => {
      const r = await go(teamFails({ team_assignee_id: 7111842 }));
      expect(r.outcome).toBe("failed");
      expect(r.outcome).not.toBe("escalation_team");
    });
    it("an explicit null in BOTH fields is a measurement: Unassigned", async () => {
      expect((await go(teamFails({ admin_assignee_id: null, team_assignee_id: null }))).outcome).toBe("unassigned");
    });
  });
  // A conflict is never a completed step by itself (QA on #1673 and #1889). "0" is Intercom's
  // Unassign and has no "already assigned to" meaning, so only a read-back settles it.
  describe("a conflict is settled by reading the conversation back, never assumed", () => {
    class Conflict extends Error {
      constructor(readonly assigneeId: string) {
        super(`already assigned to ${assigneeId}`);
      }
    }
    const named = (e: unknown, requested: string) => e instanceof Conflict && e.assigneeId === requested;
    /** `throwOn`: which calls (0 = unassign, 1 = team) answer a conflict naming the requested id. */
    const conflicting = (throwOn: number[], holder: unknown, opts: { names?: string } = {}) => {
      let n = 0;
      return {
        assignConversation: vi.fn(async (params: { assigneeId: string }) => {
          if (throwOn.includes(n++)) throw new Conflict(opts.names ?? params.assigneeId);
          return {};
        }),
        getConversation: vi.fn(async () => {
          if (holder instanceof Error) throw holder;
          return holder as { admin_assignee_id?: string | number | null; team_assignee_id?: string | number | null };
        }),
      };
    };
    const run = (c: ReturnType<typeof conflicting>, errors: string[] = []) =>
      applyHandOff({
        client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "rule/legal_threat",
        isConflict: named, log: { error: (m) => errors.push(m) },
      });

    it("unassign conflict while THE BOT still holds it: failed, team step never attempted", async () => {
      const c = conflicting([0], { admin_assignee_id: "bot", team_assignee_id: null });
      const errors: string[] = [];
      const r = await run(c, errors);
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/the bot still holds the conversation/);
      expect(c.assignConversation).toHaveBeenCalledTimes(1);
      expect(errors[0]).toMatch(/\[intercom:ALERT\].*unassign FAILED/);
    });
    it("unassign conflict while A PERSON holds it: failed, and the page names that admin, not Unassigned", async () => {
      const c = conflicting([0], { admin_assignee_id: 5465657, team_assignee_id: null });
      const r = await run(c);
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/admin 5465657 still holds the conversation/);
      expect(c.assignConversation).toHaveBeenCalledTimes(1);
    });
    it("the reviewed failure: unassign conflict with an admin still on it, then a team step that would fail, is never reported Unassigned", async () => {
      const c = conflicting([0], { admin_assignee_id: "bot", team_assignee_id: null });
      const r = await run(c);
      expect(r.outcome).not.toBe("unassigned");
      expect(r.outcome).not.toBe("escalation_team");
    });
    it("unassign conflict and no admin holds it: the step counts, the team is placed, and the result is read", async () => {
      const c = conflicting([0], { admin_assignee_id: null, team_assignee_id: 7111842 });
      const r = await run(c);
      expect(r.outcome).toBe("escalation_team");
      expect(c.assignConversation).toHaveBeenCalledTimes(2);
      expect(c.getConversation).toHaveBeenCalledWith({ conversationId: "c1" });
      expect(c.getConversation).toHaveBeenCalledTimes(2);
    });
    // QA on #1892, round 4: with NO escalation team configured, an unassign conflict whose read
    // shows no admin but ANOTHER TEAM was reported as a completed hand-off to Unassigned.
    it("no team configured, unassign conflict, the read shows another team: failed, labelled with that team", async () => {
      const c = conflicting([0], { admin_assignee_id: null, team_assignee_id: 2238258 });
      const errors: string[] = [];
      const r = await applyHandOff({
        client: c, account: { botAdminId: "bot" }, conversationId: "c1", kind: "restricted_hold", reason: "restricted_account",
        isConflict: named, log: { error: (m) => errors.push(m) },
      });
      expect(r.outcome).toBe("failed");
      expect(r.outcome).not.toBe("unassigned");
      expect(r.label).toBe("team:2238258");
      expect(r.error).toMatch(/in team 2238258, not Unassigned/);
      expect(errors[0]).toMatch(/\[intercom:ALERT\].*unassign FAILED/);
    });
    it("no team configured, unassign conflict, the read shows no admin and no team: Unassigned", async () => {
      const c = conflicting([0], { admin_assignee_id: null, team_assignee_id: null });
      const r = await applyHandOff({
        client: c, account: { botAdminId: "bot" }, conversationId: "c1", kind: "restricted_hold", reason: "restricted_account", isConflict: named,
      });
      expect(r.outcome).toBe("unassigned");
    });
    it("unassign conflict that cannot be read back is failed: unreadable is not Unassigned", async () => {
      expect((await run(conflicting([0], new Error("502")))).outcome).toBe("failed");
      expect((await run(conflicting([0], null))).outcome).toBe("failed");
      // a response with no admin_assignee_id field at all is not a measurement
      expect((await run(conflicting([0], { assignee: null }))).outcome).toBe("failed");
      // and neither is one that carries only one of the two holder fields
      expect((await run(conflicting([0], { admin_assignee_id: null }))).outcome).toBe("failed");
      expect((await run(conflicting([0], { team_assignee_id: null }))).outcome).toBe("failed");
    });
    it("a client that cannot read back never turns a conflict into a completed escalation", async () => {
      const c = { assignConversation: vi.fn(async (params: { assigneeId: string }) => { throw new Conflict(params.assigneeId); }) };
      const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r", isConflict: named });
      expect(r.outcome).toBe("failed");
      expect(c.assignConversation).toHaveBeenCalledTimes(1);
    });
    it("a conflict naming SOMEBODY ELSE is not a conflict for our request: failed", async () => {
      const c = conflicting([0], { admin_assignee_id: null, team_assignee_id: null }, { names: "5465657" });
      const r = await run(c);
      expect(r.outcome).toBe("failed");
      expect(c.getConversation).not.toHaveBeenCalled();
    });
    it("team conflict and the team really holds it with no admin: escalation_team", async () => {
      const c = conflicting([1], { admin_assignee_id: null, team_assignee_id: 7111842 });
      expect((await run(c)).outcome).toBe("escalation_team");
    });
    it("team conflict but the conversation is in ANOTHER team: failed, labelled with the real team", async () => {
      const other = await run(conflicting([1], { admin_assignee_id: null, team_assignee_id: 2238258 }));
      expect(other).toMatchObject({ outcome: "failed", label: "team:2238258" });
      expect(other.error).toMatch(/in team 2238258, not the escalation team 7111842/);
    });
    it("team conflict and the read shows no admin and no team: Unassigned, verified", async () => {
      const none = await run(conflicting([1], { admin_assignee_id: null, team_assignee_id: null }));
      expect(none).toMatchObject({ outcome: "unassigned", queue: "unassigned" });
      expect(none.error).toMatch(/no admin and no team/);
    });
    it("team conflict and a PARTIAL read (no team field): failed, never Unassigned or the team", async () => {
      const r = await run(conflicting([1], { admin_assignee_id: null }));
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/could not be read back/);
    });
    it("team conflict while an admin holds it: failed, naming the admin", async () => {
      const r = await run(conflicting([1], { admin_assignee_id: "5465657", team_assignee_id: 7111842 }));
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/admin 5465657 holds the conversation/);
    });
    // The reviewed path: unassign accepted, an admin takes the thread, the team request conflicts,
    // and the GET times out. Nothing is known, so nothing is claimed.
    it("team conflict that cannot be read back: failed (holder unknown), never Unassigned or the team", async () => {
      const errors: string[] = [];
      const r = await run(conflicting([1], new Error("timeout")), errors);
      expect(r.outcome).toBe("failed");
      expect(r.error).toMatch(/who holds it is unknown/);
      expect(errors[0]).toMatch(/\[intercom:ALERT\].*team assign FAILED/);
    });
    it("no predicate given: a conflict is just a failure", async () => {
      const c = conflicting([0], { admin_assignee_id: null, team_assignee_id: null });
      const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r" });
      expect(r.outcome).toBe("failed");
    });
  });
  it("an escalation with no reason throws before any call", async () => {
    const c = client();
    await expect(applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation" })).rejects.toThrow(EscalationReasonRequired);
    expect(c.assignConversation).not.toHaveBeenCalled();
  });
});

describe("humanHold", () => {
  const base = { botAdminId: "bot", escalationTeamId: "7111842", nowMs: NOW, teamAssigneeId: null as string | null };
  // A part with words the customer can read. `bare` is the same author doing something that answers nobody.
  const part = (hoursAgo: number, id: string, type = "admin") => ({
    created_at: Math.floor((NOW - hoursAgo * H) / 1000), part_type: "comment", body: "<p>words</p>", author: { type, id },
  });
  const bare = (hoursAgo: number, id: string, part_type: string, body: string | null = null) => ({
    created_at: Math.floor((NOW - hoursAgo * H) / 1000), part_type, body, author: { type: "admin", id },
  });

  it("default window is 72 h", () => expect(DEFAULT_HUMAN_HOLD_HOURS).toBe(72));
  it("assigned to the bot: not held, nothing to reclaim", () => {
    expect(humanHold({ ...base, adminAssigneeId: "bot" })).toMatchObject({ held: false, reclaim: false });
    // ...even when the team on the conversation is the escalation team (a human handed it back).
    expect(humanHold({ ...base, adminAssigneeId: "bot", teamAssigneeId: "7111842" })).toMatchObject({ held: false, reclaim: false });
  });
  it("no admin and not the escalation team: this rule holds nothing", () => {
    expect(humanHold({ ...base, adminAssigneeId: null })).toMatchObject({ held: false, reclaim: false });
    expect(humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "2238258" })).toMatchObject({ held: false, reclaim: false });
    expect(humanHold({ ...base, adminAssigneeId: "0" })).toMatchObject({ held: false, reclaim: false });
  });
  const teamPart = (authorId: string, team = "7111842") => ({
    created_at: 1, part_type: "assignment", author: { type: "admin", id: authorId }, assigned_to: { type: "team", id: team },
  });
  it("in the escalation team with no admin, put there by an escalation: held, however old", () => {
    const held = { held: true, reclaim: false, reason: "escalation team 7111842" };
    // session state says this plugin escalated it
    expect(humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "7111842", escalationFiredAt: "2020-01-01T00:00:00Z" })).toEqual(held);
    // or session state is gone and the live parts show the bot placing it in that team
    expect(humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "7111842", parts: [teamPart("bot")] })).toEqual(held);
  });
  it("team membership ALONE is not a hold: a team id carries years of unrelated history", () => {
    // measured 2026-11-11: 12,791 closed conversations sat in the configured team with no admin
    const d = humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "7111842" });
    expect(d).toEqual({ held: false, reclaim: false, reason: "in team 7111842, not by an escalation" });
    // a person's bulk move into the team, or the bot assigning a DIFFERENT team, is not an escalation either
    expect(humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "7111842", parts: [teamPart("5465657")] }).held).toBe(false);
    expect(humanHold({ ...base, adminAssigneeId: null, teamAssigneeId: "7111842", parts: [teamPart("bot", "2238258")] }).held).toBe(false);
  });
  it("botPlacedInTeam reads only team assignments authored by the bot", () => {
    expect(botPlacedInTeam([teamPart("bot")], "bot", "7111842")).toBe(true);
    expect(botPlacedInTeam([{ author: { type: "admin", id: "bot" }, assigned_to: { type: "admin", id: "7111842" } }], "bot", "7111842")).toBe(false);
    expect(botPlacedInTeam(undefined, "bot", "7111842")).toBe(false);
  });
  it("human assignee who never acted: RECLAIM", () => {
    const d = humanHold({ ...base, adminAssigneeId: "5465657", parts: [part(1, "bot"), part(2, "c1", "user")] });
    expect(d).toMatchObject({ held: false, reclaim: true });
    expect(d.reason).toBe("stale human assignee 5465657: no human reply in 72h");
  });
  it.each(["close", "open", "assignment", "snoozed", "note"])(
    "a human's bare %s answers nobody: RECLAIM (the 2026-11-11 bulk close silenced Caroline for 72 h)",
    (kind) => {
      // conv 215476524541332: closed by a person 11-11 16:07Z with no reply, customer wrote 11-13 13:38Z
      const parts = [bare(45.5, "5465657", kind, kind === "note" ? "<p>looking</p>" : null), part(0, "c1", "user")];
      expect(humanHold({ ...base, adminAssigneeId: "5465657", parts })).toMatchObject({ held: false, reclaim: true });
    },
  );
  it("a close that carries words IS a reply (send and close)", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts: [bare(2, "5465657", "close", "<p>All sorted.</p>")] }).held).toBe(true);
  });
  it("a human who replied holds the customer's next message, and a quick second one", () => {
    const parts = [part(3, "5465657"), part(1, "c1", "user"), part(0, "c1", "user")];
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts })).toEqual({ held: true, reclaim: false, reason: "human assignee 5465657" });
  });
  it("a human who replied and then left a customer message unanswered past the grace: RECLAIM", () => {
    expect(DEFAULT_REPLY_GRACE_HOURS).toBe(4);
    const parts = [part(30, "5465657"), part(5, "c1", "user"), part(0, "c1", "user")];
    const d = humanHold({ ...base, adminAssigneeId: "5465657", parts });
    expect(d).toEqual({ held: false, reclaim: true, reason: "human assignee 5465657 has not replied to the customer in 4h" });
    // the same thread one hour inside the grace is still the human's
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts: [part(30, "5465657"), part(3, "c1", "user"), part(0, "c1", "user")] }).held).toBe(true);
    // and the grace is configurable
    expect(humanHold({ ...base, adminAssigneeId: "5465657", replyGraceHours: 6, parts }).held).toBe(true);
  });
  it("an escalated thread on a person is held past the reply grace: a legal/fraud case is not Caroline's", () => {
    const fired = new Date(NOW - 10 * H).toISOString();
    const parts = [part(9, "c1", "user"), part(0, "c1", "user")];
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: fired, parts })).toEqual({
      held: true, reclaim: false, reason: "human assignee 5465657 (escalated)",
    });
    // A person replying after the escalation (moving it out of the queue, or answering it once)
    // does not turn the follow-up into Caroline's either.
    const answered = [part(6, "5465657"), part(5, "c1", "user"), part(0, "c1", "user")];
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: fired, parts: answered }).held).toBe(true);
  });
  it("oldestCustomerPartAfter reads customer parts only, newer than the mark", () => {
    const at = (h: number) => Math.floor((NOW - h * H) / 1000);
    const parts = [part(9, "c1", "user"), part(5, "c1", "lead"), part(4, "5465657"), part(2, "c1", "contact")];
    expect(oldestCustomerPartAfter(parts, at(6))).toBe(at(5));
    expect(oldestCustomerPartAfter(parts, at(1))).toBeNull();
    expect(oldestCustomerPartAfter(undefined, 0)).toBeNull();
  });
  it("human acted inside the window: held (and the journal line keeps its old shape)", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts: [part(71, "5465657")] })).toEqual({
      held: true, reclaim: false, reason: "human assignee 5465657",
    });
  });
  it("human acted outside the window: RECLAIM", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts: [part(73, "5465657")] }).reclaim).toBe(true);
  });
  it("ANY human admin's action holds it, not only the assignee's", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", parts: [part(2, "10206197")] }).held).toBe(true);
  });
  it("the bot's own parts and Operator (author type bot) are not human actions", () => {
    expect(lastHumanReplyAt([part(1, "bot"), part(1, "4359478", "bot"), part(1, "u", "user")], "bot")).toBeNull();
    expect(lastHumanReplyAt([part(5, "5465657"), part(3, "5465657")], "bot")).toBe(Math.floor((NOW - 3 * H) / 1000));
    // a part with no words (or an unmarked one) is not a reply
    expect(lastHumanReplyAt([{ created_at: 5, author: { type: "admin", id: "5465657" } }, bare(1, "5465657", "comment", "<p> </p>")], "bot")).toBeNull();
  });
  it("a reasoned escalation inside the window holds it before any human acts", () => {
    const fired = new Date(NOW - 10 * H).toISOString();
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: fired })).toMatchObject({ held: true, reason: "human assignee 5465657 (escalated)" });
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: new Date(NOW - 80 * H).toISOString() }).reclaim).toBe(true);
    // ...and past the window a human reply still re-holds it under the ordinary rule
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: new Date(NOW - 80 * H).toISOString(), parts: [part(2, "5465657")] })).toMatchObject({ held: true, reason: "human assignee 5465657" });
  });
  it("hours <= 0 is the legacy rule: a human assignee always holds", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: 0 })).toMatchObject({ held: true, reclaim: false });
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: -1 }).held).toBe(true);
  });
  it("a custom window is honoured", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: 24, parts: [part(30, "5465657")] }).reclaim).toBe(true);
  });
});

describe("escalationGoesToQueue", () => {
  it.each([...QUEUE_ESCALATION_REASONS])("rule/%s is outside Caroline's authority: escalation queue", (reason) => {
    expect(escalationGoesToQueue({ source: "rule", reason })).toBe(true);
  });
  it("the list is the content rules and nothing else", () => {
    expect([...QUEUE_ESCALATION_REASONS].sort()).toEqual([
      "abuse_report", "cancel_intent", "fraud_complaint", "legal_threat", "public_shaming_intent", "refund_intent", "security_incident",
    ]);
  });
  it.each([
    { source: "user_request", reason: "user_requested_human" },
    { source: "rule", reason: "turn_count_cap" },
    { source: "rule", reason: "" },
    { source: "rule" },
    { source: "user_request", reason: "legal_threat" },
    {},
  ])("%j stays with Caroline", (assessment) => {
    expect(escalationGoesToQueue(assessment)).toBe(false);
  });
  it("a judge verdict is left to its own switch (jev actions.escalate)", () => {
    expect(escalationGoesToQueue({ source: "judge", reason: "jev:human_required" })).toBe(true);
  });
});

describe("no other code path assigns a conversation to a human", () => {
  const dir = new URL("../src/", import.meta.url);
  const files = readdirSync(dir).filter((f) => f.endsWith(".ts"));
  it("defaultInboxId is read nowhere but config.ts (the retirement warning) and types.ts (the deprecation)", () => {
    const offenders = files.filter(
      (f) => !["config.ts", "types.ts", "assignment-policy.ts"].includes(f) && /defaultInboxId/.test(readFileSync(new URL(f, dir), "utf8")),
    );
    expect(offenders).toEqual([]);
  });
  it("assignConversation is called only by the policy and by the bot's self-assign", () => {
    const callers = files.filter((f) => /\.assignConversation\(/.test(readFileSync(new URL(f, dir), "utf8"))).sort();
    // outbound.ts: the client + its wrapper. channel.ts: the bot assigning ITSELF on dispatch.
    expect(callers).toEqual(["assignment-policy.ts", "channel.ts", "outbound.ts"]);
    const channel = readFileSync(new URL("channel.ts", dir), "utf8");
    const calls = [...channel.matchAll(/\.assignConversation\(\{[\s\S]*?\}\)/g)].map((m) => m[0]);
    expect(calls.length).toBeGreaterThan(0);
    for (const c of calls) expect(c).toMatch(/assigneeId:\s*account\.botAdminId/);
  });
});

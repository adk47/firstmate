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
  lastHumanActionAt,
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
  it("AI-queue kinds make no Intercom call at all", async () => {
    const c = client();
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "output_guard" });
    expect(r.outcome).toBe("ai_queue");
    expect(c.assignConversation).not.toHaveBeenCalled();
  });
  it("an escalation takes the bot off, then places the team with type team", async () => {
    const c = client();
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "rule/legal_threat" });
    expect(r).toMatchObject({ outcome: "escalation_team", human: true, reason: "rule/legal_threat" });
    expect(c.assignConversation.mock.calls.map((x) => x[0])).toEqual([
      { conversationId: "c1", adminId: "bot", assigneeId: "0" },
      { conversationId: "c1", adminId: "bot", assigneeId: "7111842", assigneeType: "team" },
    ]);
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
  it("no team configured: one call, to Unassigned", async () => {
    const c = client();
    const r = await applyHandOff({ client: c, account: { botAdminId: "bot" }, conversationId: "c1", kind: "restricted_hold", reason: "restricted_account" });
    expect(r.outcome).toBe("unassigned");
    expect(c.assignConversation).toHaveBeenCalledTimes(1);
  });
  it("a failed unassign is reported as failed (the bot still holds it) and the team step is skipped", async () => {
    const c = { assignConversation: vi.fn(async () => { throw new Error("403"); }) };
    const errors: string[] = [];
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r", log: { error: (m) => errors.push(m) } });
    expect(r.outcome).toBe("failed");
    expect(c.assignConversation).toHaveBeenCalledTimes(1);
    expect(errors[0]).toMatch(/\[intercom:ALERT\].*unassign FAILED/);
  });
  it("a failed team step leaves it in Unassigned, which is still nobody's personal inbox", async () => {
    let n = 0;
    const c = { assignConversation: vi.fn(async () => { if (n++ === 1) throw new Error("team not found"); return {}; }) };
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r" });
    expect(r).toMatchObject({ outcome: "unassigned", queue: "unassigned" });
    expect(r.error).toMatch(/team not found/);
  });
  it("a conflict on either step is the desired end state", async () => {
    const conflict = new Error("already");
    const c = { assignConversation: vi.fn(async () => { throw conflict; }) };
    const r = await applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation", reason: "r", isConflict: (e) => e === conflict });
    expect(r.outcome).toBe("escalation_team");
    expect(c.assignConversation).toHaveBeenCalledTimes(2);
  });
  it("an escalation with no reason throws before any call", async () => {
    const c = client();
    await expect(applyHandOff({ client: c, account, conversationId: "c1", kind: "risk_escalation" })).rejects.toThrow(EscalationReasonRequired);
    expect(c.assignConversation).not.toHaveBeenCalled();
  });
});

describe("humanHold", () => {
  const base = { botAdminId: "bot", escalationTeamId: "7111842", nowMs: NOW, teamAssigneeId: null as string | null };
  const part = (hoursAgo: number, id: string, type = "admin") => ({ created_at: Math.floor((NOW - hoursAgo * H) / 1000), author: { type, id } });

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
    expect(d.reason).toBe("stale human assignee 5465657: no human action in 72h");
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
    expect(lastHumanActionAt([part(1, "bot"), part(1, "4359478", "bot"), part(1, "u", "user")], "bot")).toBeNull();
    expect(lastHumanActionAt([part(5, "5465657"), part(3, "5465657")], "bot")).toBe(Math.floor((NOW - 3 * H) / 1000));
  });
  it("a reasoned escalation inside the window holds it before any human acts", () => {
    const fired = new Date(NOW - 10 * H).toISOString();
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: fired })).toMatchObject({ held: true, reason: "human assignee 5465657 (escalated)" });
    expect(humanHold({ ...base, adminAssigneeId: "5465657", escalationFiredAt: new Date(NOW - 80 * H).toISOString() }).reclaim).toBe(true);
  });
  it("hours <= 0 is the legacy rule: a human assignee always holds", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: 0 })).toMatchObject({ held: true, reclaim: false });
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: -1 }).held).toBe(true);
  });
  it("a custom window is honoured", () => {
    expect(humanHold({ ...base, adminAssigneeId: "5465657", holdHours: 24, parts: [part(30, "5465657")] }).reclaim).toBe(true);
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

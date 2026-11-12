/**
 * The ONE place that decides who holds an Intercom conversation (intercom-no-human-assignment-k1,
 * captain 2026-11-11: "cut this to zero and have Caroline handle all of them").
 *
 * WHY (measured, data/intercom-no-human-assignment-k1/report.md): six call sites each did
 * `assigneeId: account.defaultInboxId || "0"`, and the live config had `defaultInboxId` set to ONE
 * PERSON's admin id. 478 of the 485 assignments that person received in 14 days were made by this
 * plugin, 404 of them because Caroline's own reply failed the output guard. A code gate tripping
 * on the model's text is not a reason for a person to own the thread.
 *
 * The rules, and nothing else in this plugin may assign a conversation to anything but the bot:
 *
 *   1. AI queue is the default. A blocked, emptied or leaked reply (`output_guard`,
 *      `help_link_drop`, `reasoning_leak`) keeps the conversation with Caroline. No assignment
 *      call is made and the customer is never told a person is coming.
 *   2. A human only on an EXPLICIT ESCALATION, and an escalation carries a REASON
 *      (`risk_escalation`, `restricted_hold`, `legacy_escalation`). No reason, no escalation:
 *      resolveHandOffTarget throws.
 *   3. An escalation goes to a QUEUE, never a person. The target is `escalationTeamId`, sent with
 *      `type: "team"`, so an admin id configured there is refused by Intercom rather than quietly
 *      becoming somebody's personal inbox again. Unset = Intercom's Unassigned inbox.
 *   4. `defaultInboxId` is retired. It is never read for an assignment (config.ts warns when a
 *      host still sets it; scripts/check-intercom-no-personal-assignee.sh fails CI on it).
 *   5. A human assignee only silences Caroline while that human is actually working the thread
 *      (humanHold). A stale assignment is reclaimed on the customer's next message.
 *
 * Pure and import-free: every decision here is unit-tested without a client.
 */

/** Why a conversation would leave Caroline's normal reply path. */
export type HandOffKind =
  | "output_guard"
  | "help_link_drop"
  | "reasoning_leak"
  | "risk_escalation"
  | "restricted_hold"
  | "legacy_escalation";

/** Kinds where a code gate stopped Caroline's own text. They stay in the AI queue. */
export const AI_QUEUE_KINDS: ReadonlySet<HandOffKind> = new Set<HandOffKind>([
  "output_guard",
  "help_link_drop",
  "reasoning_leak",
]);

export interface AssignmentAccount {
  botAdminId: string;
  /** Intercom TEAM id of the escalation queue. Digits only. Never an admin id. */
  escalationTeamId?: string;
}

export type HandOffQueue = "ai" | "escalation_team" | "unassigned";

export interface HandOffTarget {
  queue: HandOffQueue;
  /** True when a human queue now holds it (so a hand-off line to the customer would be true). */
  human: boolean;
  /** The escalation reason. Empty for AI-queue kinds. */
  reason: string;
  /** Short label for logs, ledger rows and pages. */
  label: string;
}

export class EscalationReasonRequired extends Error {
  constructor(kind: HandOffKind) {
    super(`intercom assignment policy: a ${kind} escalation needs a reason and none was given`);
    this.name = "EscalationReasonRequired";
  }
}

function teamId(account: AssignmentAccount): string {
  const t = (account.escalationTeamId ?? "").trim();
  return /^[1-9][0-9]*$/.test(t) ? t : "";
}

/** Where a conversation goes for this kind. Throws when an escalation carries no reason. */
export function resolveHandOffTarget(account: AssignmentAccount, kind: HandOffKind, reason?: string): HandOffTarget {
  if (AI_QUEUE_KINDS.has(kind)) {
    return { queue: "ai", human: false, reason: "", label: `ai-queue (${kind}: stays with Caroline)` };
  }
  const why = (reason ?? "").trim();
  if (!why) throw new EscalationReasonRequired(kind);
  const team = teamId(account);
  return team
    ? { queue: "escalation_team", human: true, reason: why, label: `team:${team}` }
    : { queue: "unassigned", human: true, reason: why, label: "Unassigned" };
}

export interface AssignClient {
  assignConversation(params: {
    conversationId: string;
    adminId: string;
    assigneeId: string;
    assigneeType?: "admin" | "team";
  }): Promise<unknown>;
}

export interface AppliedHandOff extends HandOffTarget {
  /** Where the conversation actually ended up. `failed` = it is still with the bot. */
  outcome: "ai_queue" | "escalation_team" | "unassigned" | "failed";
  error?: string;
}

/**
 * Carry out a hand-off decision. AI-queue kinds make no call at all.
 *
 * An escalation takes the bot off the conversation first (assign to "0", Intercom's Unassign) and
 * then places it in the escalation team with `type: "team"`. Two calls so the end state does not
 * depend on what Intercom does to the admin assignee on a team assignment: after both, no admin
 * holds it and the team does. A failed team step leaves it in Unassigned, which is still a queue
 * no single person owns; only a failed FIRST step is reported as `failed`.
 *
 * `isConflict` is the caller's "already assigned to that target" predicate (Intercom answers a
 * repeat assignment with a conflict, which is the desired end state, not an error).
 */
export async function applyHandOff(p: {
  client: AssignClient;
  account: AssignmentAccount;
  conversationId: string;
  kind: HandOffKind;
  reason?: string;
  isConflict?: (err: unknown) => boolean;
  log?: { info?: (m: string) => void; warn?: (m: string) => void; error?: (m: string) => void };
}): Promise<AppliedHandOff> {
  const target = resolveHandOffTarget(p.account, p.kind, p.reason);
  if (target.queue === "ai") return { ...target, outcome: "ai_queue" };
  const conflict = p.isConflict ?? (() => false);
  try {
    await p.client.assignConversation({ conversationId: p.conversationId, adminId: p.account.botAdminId, assigneeId: "0" });
  } catch (err) {
    if (!conflict(err)) {
      p.log?.error?.(
        `[intercom:ALERT] [intercom:assignment] escalation unassign FAILED conv=${p.conversationId} kind=${p.kind} reason=${target.reason}: ${err}`,
      );
      return { ...target, outcome: "failed", error: String(err) };
    }
  }
  if (target.queue === "unassigned") {
    p.log?.info?.(`[intercom:assignment] escalated conv=${p.conversationId} → Unassigned kind=${p.kind} reason=${target.reason}`);
    return { ...target, outcome: "unassigned" };
  }
  const team = teamId(p.account);
  try {
    await p.client.assignConversation({
      conversationId: p.conversationId,
      adminId: p.account.botAdminId,
      assigneeId: team,
      assigneeType: "team",
    });
  } catch (err) {
    if (!conflict(err)) {
      p.log?.error?.(
        `[intercom:ALERT] [intercom:assignment] escalation team assign FAILED conv=${p.conversationId} team=${team} kind=${p.kind} ` +
          `reason=${target.reason} (left in Unassigned): ${err}`,
      );
      return { ...target, queue: "unassigned", label: "Unassigned", outcome: "unassigned", error: String(err) };
    }
  }
  p.log?.info?.(`[intercom:assignment] escalated conv=${p.conversationId} → team:${team} kind=${p.kind} reason=${target.reason}`);
  return { ...target, outcome: "escalation_team" };
}

// ---------------------------------------------------------------------------------------------
// Human hold: when does a human assignee silence Caroline?

/** A human assignee holds a conversation for this long after their last action in it. */
export const DEFAULT_HUMAN_HOLD_HOURS = 72;

export interface HoldPart {
  created_at?: number;
  part_type?: string;
  author?: { type?: string; id?: string | number };
  assigned_to?: { type?: string; id?: string | number } | null;
}

export interface HumanHoldInput {
  /** `admin_assignee_id` from the live conversation, or null. */
  adminAssigneeId: string | null;
  /** `team_assignee_id` from the live conversation, or null. */
  teamAssigneeId: string | null;
  botAdminId: string;
  escalationTeamId?: string;
  /** Live conversation parts (newest window Intercom returns). */
  parts?: readonly HoldPart[];
  /** Session state: when this plugin last escalated the conversation with a reason (ISO). */
  escalationFiredAt?: string | null;
  nowMs: number;
  /** Hold window. Undefined = DEFAULT_HUMAN_HOLD_HOURS. Zero or negative = a human assignee always holds (legacy). */
  holdHours?: number;
}

export interface HumanHoldDecision {
  /** Caroline stays out. */
  held: boolean;
  /** A human admin is the assignee but is not working it: Caroline takes it back. */
  reclaim: boolean;
  reason: string;
}

/** Epoch SECONDS of the newest part authored by a human admin (not the bot, not Operator), or null. */
export function lastHumanActionAt(parts: readonly HoldPart[] | undefined, botAdminId: string): number | null {
  let last: number | null = null;
  for (const p of parts ?? []) {
    if (p?.author?.type !== "admin") continue;
    if (String(p.author.id ?? "") === botAdminId) continue;
    const at = typeof p.created_at === "number" ? p.created_at : null;
    if (at !== null && (last === null || at > last)) last = at;
  }
  return last;
}

/** Did the bot itself place this conversation in `team`? (An escalation's second step.) */
export function botPlacedInTeam(parts: readonly HoldPart[] | undefined, botAdminId: string, team: string): boolean {
  for (const p of parts ?? []) {
    if (p?.assigned_to?.type !== "team" || String(p.assigned_to.id ?? "") !== team) continue;
    if (String(p.author?.id ?? "") === botAdminId) return true;
  }
  return false;
}

/**
 * Decide whether a human holds this conversation right now.
 *
 *   - In the escalation team with no admin on it, AND put there by an escalation (session state
 *     says this plugin escalated it, or the live parts show the bot assigning it to that team):
 *     held. That is the explicit escalation queue, and it holds until a human moves it or assigns
 *     it back to Caroline. Team membership ALONE is not a hold: a team id is reused history
 *     (measured 2026-11-11: the configured team already carried 12,791 closed conversations with
 *     no admin, none of them escalations, and each would have gone silent on its next message).
 *   - Assigned to a human admin: held while that human is working it, meaning a human admin did
 *     something in the conversation inside the hold window, or this plugin escalated it with a
 *     reason inside the window. Otherwise it is a stale assignment and Caroline reclaims it.
 *     (Measured: 109 of the 581 threads open on one person were assigned more than 15 days
 *     earlier, and 168 customer replies in 24 h were dropped because of a human assignee who had
 *     never answered.)
 *   - No human admin and not in the escalation team: not held by this rule (session state still
 *     applies; see handler.ts).
 *
 * A snoozed or closed conversation never reaches this: the live check filters it first, so a human
 * who snoozes a thread keeps it for as long as the snooze lasts.
 */
export function humanHold(input: HumanHoldInput): HumanHoldDecision {
  const admin = input.adminAssigneeId && input.adminAssigneeId !== "0" ? input.adminAssigneeId : null;
  const escTeam = (input.escalationTeamId ?? "").trim();
  if (!admin) {
    if (escTeam && input.teamAssigneeId === escTeam) {
      if (input.escalationFiredAt || botPlacedInTeam(input.parts, input.botAdminId, escTeam)) {
        return { held: true, reclaim: false, reason: `escalation team ${escTeam}` };
      }
      return { held: false, reclaim: false, reason: `in team ${escTeam}, not by an escalation` };
    }
    return { held: false, reclaim: false, reason: "no human assignee" };
  }
  if (admin === input.botAdminId) return { held: false, reclaim: false, reason: "assigned to the bot" };

  const hours = input.holdHours ?? DEFAULT_HUMAN_HOLD_HOURS;
  if (!(hours > 0)) return { held: true, reclaim: false, reason: `human assignee ${admin}` };
  const windowMs = hours * 3600 * 1000;

  const humanAt = lastHumanActionAt(input.parts, input.botAdminId);
  if (humanAt !== null && input.nowMs - humanAt * 1000 <= windowMs) {
    return { held: true, reclaim: false, reason: `human assignee ${admin}` };
  }
  const firedMs = input.escalationFiredAt ? Date.parse(input.escalationFiredAt) : NaN;
  if (Number.isFinite(firedMs) && input.nowMs - firedMs <= windowMs) {
    return { held: true, reclaim: false, reason: `human assignee ${admin} (escalated)` };
  }
  return {
    held: false,
    reclaim: true,
    reason: `stale human assignee ${admin}: no human action in ${hours}h`,
  };
}

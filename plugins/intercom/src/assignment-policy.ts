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
 *      resolveHandOffTarget throws. A risk escalation leaves Caroline only for a reason outside
 *      her authority (QUEUE_ESCALATION_REASONS); "asked for a person" and a long conversation
 *      are not such reasons (escalationGoesToQueue; captain 2026-11-13).
 *   3. An escalation goes to a QUEUE, never a person. The target is `escalationTeamId`, sent with
 *      `type: "team"`, so an admin id configured there is refused by Intercom rather than quietly
 *      becoming somebody's personal inbox again. Unset = Intercom's Unassigned inbox.
 *   4. `defaultInboxId` is retired. It is never read for an assignment (config.ts warns when a
 *      host still sets it; scripts/check-intercom-no-personal-assignee.sh fails CI on it).
 *   5. A human assignee only silences Caroline while that human is ANSWERING the customer
 *      (humanHold): a reply inside the hold window, and no customer message left without one for
 *      longer than the reply grace. A close, a note or an assignment answers nobody. Anything else
 *      is reclaimed on the customer's next message.
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

/**
 * Thrown by the CLIENT when a caller asks it to assign a conversation to an individual admin.
 * This is the runtime half of the rule; scripts/check-intercom-no-personal-assignee.sh is the
 * review-time half, and a text scan can be dodged by a computed call.
 */
export class PersonalAssignmentRefused extends Error {
  constructor(assigneeId: string) {
    super(
      `intercom assignment policy: refusing to assign a conversation to admin ${assigneeId}. ` +
        `No conversation is assigned to a person; escalate with applyHandOff() (a reason, to the team queue).`,
    );
    this.name = "PersonalAssignmentRefused";
  }
}

/**
 * The only assignments the plugin may send, enforced inside every client implementation so the
 * rule holds however the call was written:
 *   - to a TEAM (the escalation queue): a numeric team id sent as `type: "team"`;
 *   - to nobody: assignee "0" (Intercom's Unassign);
 *   - to the acting admin itself: Caroline taking the conversation (the AI queue).
 * An admin id other than the actor is a person, and is refused before any request is made.
 */
export function assertAssignmentTarget(params: {
  adminId: string;
  assigneeId: string;
  assigneeType?: "admin" | "team";
}): void {
  if (params.assigneeType === "team") {
    if (!/^[1-9][0-9]*$/.test(params.assigneeId)) throw new PersonalAssignmentRefused(params.assigneeId);
    return;
  }
  if (params.assigneeId === "0") return;
  if (params.adminId !== "" && params.assigneeId === params.adminId) return;
  throw new PersonalAssignmentRefused(params.assigneeId);
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
  /**
   * Read-back of who holds the conversation. Every escalation outcome is settled ONLY by this
   * read: a client that cannot read back can never complete an escalation.
   */
  getConversation?(params: { conversationId: string }): Promise<
    | { admin_assignee_id?: string | number | null; team_assignee_id?: string | number | null }
    | null
    | undefined
  >;
}

export interface AppliedHandOff extends HandOffTarget {
  /**
   * Where the conversation actually ended up, as a read-back showed it. What Intercom answered to
   * the assignment requests is never the source: `unassigned` and `escalation_team` are reported
   * only when the read shows exactly that and no admin. `failed` =
   * the escalation is NOT confirmed in a queue it chose: an admin still holds the conversation
   * (the bot, or whoever a read-back names), it sits in some other team (`label` says which), or
   * it could not be read, so who holds it is unknown.
   */
  outcome: "ai_queue" | "escalation_team" | "unassigned" | "failed";
  error?: string;
}

/**
 * Who holds the conversation right now, read from Intercom. `null` = it could not be read, which
 * includes a response that does not carry both holder fields.
 */
async function readHolder(
  client: AssignClient,
  conversationId: string,
): Promise<{ admin: string; team: string } | null> {
  if (!client.getConversation) return null;
  try {
    const conv = await client.getConversation({ conversationId });
    // The v2.11 API always sends BOTH `admin_assignee_id` and `team_assignee_id` (null when
    // nobody holds it). A response missing either field is not a measurement of who holds the
    // conversation, so it is never read as "no admin" or "no team" (QA on #1892: a partial
    // response once read as a confirmed Unassigned while the team was never measured).
    if (!conv || conv.admin_assignee_id === undefined || conv.team_assignee_id === undefined) return null;
    const id = (v: string | number | null | undefined) => (v === null || v === undefined || v === 0 || v === "0" ? "" : String(v));
    return { admin: id(conv.admin_assignee_id), team: id(conv.team_assignee_id) };
  } catch {
    return null;
  }
}

/**
 * Carry out a hand-off decision. AI-queue kinds make no call at all.
 *
 * An escalation takes the bot off the conversation first (assign to "0", Intercom's Unassign) and
 * then, when an escalation team is configured, places it in that team with `type: "team"`. Two
 * calls so the end state does not depend on what Intercom does to the admin assignee on a team
 * assignment.
 *
 * THE OUTCOME IS ALWAYS A READ-BACK, NEVER AN ASSUMPTION. Whatever the two requests answered
 * (accepted, conflict, error), the conversation is read once more at the end and the result is
 * what that read shows:
 *   - no admin and the escalation team            -> `escalation_team`
 *   - no admin and no team                        -> `unassigned`
 *   - an admin holds it (the bot or anybody else) -> `failed`, naming who
 *   - it sits in a team that was not asked for    -> `failed`, `label` says which team
 *   - it cannot be read (or a holder field is missing, or the client has no read-back)
 *                                                 -> `failed`, holder unknown
 * An accepted request is not proof either: an admin can take the conversation between the two
 * calls, and Intercom lets an admin and a team hold a conversation together. Four QA rounds on
 * #1889/#1892 each found one more branch that claimed a queue it had not read, so no branch is
 * left that can.
 *
 * A CONFLICT IS NEVER TAKEN AS SUCCESS ON ITS OWN. `isConflict(err, requested)` only says "Intercom
 * answered a conflict naming the assignee we asked for". "0" is Intercom's Unassign and has no
 * "already assigned to" meaning, and a conflict that names somebody else is not ours at all (QA on
 * #1673: a conflict naming the bot was once reported as a completed hand-off while the bot still
 * owned the thread). After a conflict on the unassign the conversation is read at once, and the
 * escalation stops there when an admin still holds it or it cannot be read.
 */
export async function applyHandOff(p: {
  client: AssignClient;
  account: AssignmentAccount;
  conversationId: string;
  kind: HandOffKind;
  reason?: string;
  isConflict?: (err: unknown, requestedAssigneeId: string) => boolean;
  log?: { info?: (m: string) => void; warn?: (m: string) => void; error?: (m: string) => void };
}): Promise<AppliedHandOff> {
  const target = resolveHandOffTarget(p.account, p.kind, p.reason);
  if (target.queue === "ai") return { ...target, outcome: "ai_queue" };
  const conflict = p.isConflict ?? (() => false);
  const where = `conv=${p.conversationId} kind=${p.kind} reason=${target.reason}`;
  const failed = (step: string, why: string): AppliedHandOff => {
    p.log?.error?.(`[intercom:ALERT] [intercom:assignment] escalation ${step} FAILED ${where}: ${why}`);
    return { ...target, outcome: "failed", error: why };
  };
  const nameOf = (admin: string) => (admin === p.account.botAdminId ? "the bot" : `admin ${admin}`);

  // Step 1: take the bot off the conversation.
  try {
    await p.client.assignConversation({ conversationId: p.conversationId, adminId: p.account.botAdminId, assigneeId: "0" });
  } catch (err) {
    if (!conflict(err, "0")) return failed("unassign", String(err));
    const holder = await readHolder(p.client, p.conversationId);
    if (!holder) return failed("unassign", `conflict on the unassign and the conversation could not be read back (${err})`);
    if (holder.admin) {
      return failed("unassign", `conflict on the unassign and ${nameOf(holder.admin)} still holds the conversation (${err})`);
    }
  }

  // Step 2: place it in the escalation team, when one is configured.
  const team = target.queue === "escalation_team" ? teamId(p.account) : "";
  let what = "the unassign was accepted";
  let tail = "";
  let teamStepErrored = false;
  if (team) {
    what = "the team step was accepted";
    try {
      await p.client.assignConversation({
        conversationId: p.conversationId,
        adminId: p.account.botAdminId,
        assigneeId: team,
        assigneeType: "team",
      });
    } catch (err) {
      teamStepErrored = true;
      what = conflict(err, team) ? "conflict on the team step" : "the team step failed";
      tail = ` (${err})`;
    }
  }

  // Step 3: the outcome is what Intercom shows NOW, for every path that reaches here.
  const step = team ? "team assign" : "unassign";
  const holder = await readHolder(p.client, p.conversationId);
  if (!holder) {
    return failed(step, `${what} and the conversation could not be read back, so who holds it is unknown${tail}`);
  }
  if (holder.admin) return failed(step, `${what} and ${nameOf(holder.admin)} holds the conversation${tail}`);
  if (!team) {
    if (holder.team) {
      // No admin, but not Unassigned either: say where it really is.
      return {
        ...failed(step, `${what} and the conversation is in team ${holder.team}, not Unassigned${tail}`),
        label: `team:${holder.team}`,
      };
    }
    p.log?.info?.(`[intercom:assignment] escalated conv=${p.conversationId} → Unassigned kind=${p.kind} reason=${target.reason}`);
    return { ...target, outcome: "unassigned" };
  }
  if (holder.team && holder.team !== team) {
    return {
      ...failed(step, `${what} and the conversation is in team ${holder.team}, not the escalation team ${team}${tail}`),
      label: `team:${holder.team}`,
    };
  }
  if (!holder.team) {
    const why = `${what}; read back: no admin and no team hold it${tail}`;
    p.log?.error?.(
      `[intercom:ALERT] [intercom:assignment] escalation team assign FAILED conv=${p.conversationId} team=${team} kind=${p.kind} ` +
        `reason=${target.reason} (left in Unassigned): ${why}`,
    );
    return { ...target, queue: "unassigned", label: "Unassigned", outcome: "unassigned", error: why };
  }
  // read back: no admin, and the escalation team holds it
  if (teamStepErrored) p.log?.warn?.(`[intercom:assignment] ${what} but the read-back shows team:${team} and no admin ${where}${tail}`);
  p.log?.info?.(`[intercom:assignment] escalated conv=${p.conversationId} → team:${team} kind=${p.kind} reason=${target.reason}`);
  return { ...target, outcome: "escalation_team" };
}

// ---------------------------------------------------------------------------------------------
// Which risk escalations leave Caroline at all?

/**
 * The reasons a conversation goes to the escalation queue: the customer needs something Caroline
 * has no authority to say or do (a legal statement, a payment dispute, an account deletion, a
 * security, abuse or fraud report). Every one is a content rule in escalation.ts RISK_RULES.
 *
 * NOT on the list, and so answered by Caroline (captain 2026-11-13: "issues like this need
 * responses by caroline"; no humans in the loop, a hand-off is a defect):
 *   - `user_requested_human`: asking for a person does not produce one. Measured on the edge
 *     journal 2026-11-12 12:54Z..11-13 14:00Z, the first day escalations went to the queue: 5 of
 *     the 9 were this reason, and the queue's team has no members, so each customer was told "I'm
 *     pulling in a teammate" and then got silence on every later message.
 *   - `turn_count_cap` (2 of the 9): a long conversation is a reason to answer better, and after
 *     the hand-off nobody answered at all.
 *
 * A `judge` verdict is not decided here: it exists only behind its own switch (jev
 * `actions.escalate`, off in production, where the journal reads `suppressed=escalate`).
 */
export const QUEUE_ESCALATION_REASONS: ReadonlySet<string> = new Set([
  "legal_threat",
  "refund_intent",
  "cancel_intent",
  "fraud_complaint",
  "security_incident",
  "abuse_report",
  "public_shaming_intent",
]);

/** Does this risk assessment move the conversation to the escalation queue? Otherwise Caroline answers it. */
export function escalationGoesToQueue(assessment: { source?: string; reason?: string }): boolean {
  if (assessment.source === "judge") return true;
  return assessment.source === "rule" && QUEUE_ESCALATION_REASONS.has(String(assessment.reason ?? ""));
}

// ---------------------------------------------------------------------------
// Human hold: when does a human assignee silence Caroline?

/** A human assignee holds a conversation for this long after their last action in it. */
export const DEFAULT_HUMAN_HOLD_HOURS = 72;

/**
 * A human who answered holds the thread only while no customer message has waited longer than this
 * for a reply. Four hours is the sentinel's limit for `intercom_customer_last`.
 */
export const DEFAULT_REPLY_GRACE_HOURS = 4;

const CUSTOMER_AUTHOR_TYPES: ReadonlySet<string> = new Set(["user", "lead", "contact"]);

export interface HoldPart {
  created_at?: number;
  part_type?: string;
  body?: string | null;
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
  /** How long a customer message may wait for the human's reply before Caroline takes it. Undefined = DEFAULT_REPLY_GRACE_HOURS. */
  replyGraceHours?: number;
}

export interface HumanHoldDecision {
  /** Caroline stays out. */
  held: boolean;
  /** A human admin is the assignee but is not working it: Caroline takes it back. */
  reclaim: boolean;
  reason: string;
}

/**
 * Epoch SECONDS of the newest REPLY a human admin (not the bot, not Operator) sent the customer,
 * or null. A reply is a part with words the customer can read: not a note, and not a bare close,
 * re-open, snooze or assignment. On 2026-11-11 16:00Z one person bulk-closed their queue; every
 * close counted as "working the thread" and silenced Caroline for 72 h on each customer who wrote
 * back (convs 215476524541332 and 215475055007096 on 11-13, 45 h after a close with no reply).
 */
export function lastHumanReplyAt(parts: readonly HoldPart[] | undefined, botAdminId: string): number | null {
  let last: number | null = null;
  for (const p of parts ?? []) {
    if (p?.author?.type !== "admin") continue;
    if (String(p.author.id ?? "") === botAdminId) continue;
    if (p.part_type === "note") continue;
    if (!String(p.body ?? "").replace(/<[^>]*>/g, "").trim()) continue;
    const at = typeof p.created_at === "number" ? p.created_at : null;
    if (at !== null && (last === null || at > last)) last = at;
  }
  return last;
}

/** Epoch SECONDS of the OLDEST customer part newer than `since` (the message that has waited longest), or null. */
export function oldestCustomerPartAfter(parts: readonly HoldPart[] | undefined, since: number): number | null {
  let oldest: number | null = null;
  for (const p of parts ?? []) {
    if (!CUSTOMER_AUTHOR_TYPES.has(String(p?.author?.type ?? ""))) continue;
    const at = typeof p.created_at === "number" ? p.created_at : null;
    if (at !== null && at > since && (oldest === null || at < oldest)) oldest = at;
  }
  return oldest;
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
 *   - Assigned to a human admin AND this plugin escalated it with a reason (a
 *     QUEUE_ESCALATION_REASONS case, so outside Caroline's authority): held for the whole hold
 *     window, whatever the customer has waited. The reply grace never applies: a legal or fraud
 *     case does not become Caroline's to answer because its follow-up is four hours old.
 *   - Assigned to a human admin otherwise: held while a human is ANSWERING it, meaning a human
 *     admin sent the customer a reply inside the hold window, AND no customer message since has
 *     waited longer than the reply grace. Otherwise Caroline reclaims it: an assignee who is not
 *     answering holds nothing.
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

  const grace = input.replyGraceHours ?? DEFAULT_REPLY_GRACE_HOURS;
  const graceMs = grace * 3600 * 1000;
  // The customer message that has waited longest since `sinceS` and is past the grace, if any.
  const unanswered = (sinceS: number): boolean => {
    const waiting = oldestCustomerPartAfter(input.parts, sinceS);
    return waiting !== null && input.nowMs - waiting * 1000 > graceMs;
  };
  const notAnswering = {
    held: false,
    reclaim: true,
    reason: `human assignee ${admin} has not replied to the customer in ${grace}h`,
  };

  // The escalation gate is checked FIRST and takes no grace: the reason this plugin handed the
  // thread over is one Caroline has no authority to answer, and a person taking it from the queue
  // does not change that. Only the hold window ends it.
  const firedMs = input.escalationFiredAt ? Date.parse(input.escalationFiredAt) : NaN;
  if (Number.isFinite(firedMs) && input.nowMs - firedMs <= windowMs) {
    return { held: true, reclaim: false, reason: `human assignee ${admin} (escalated)` };
  }

  const humanAt = lastHumanReplyAt(input.parts, input.botAdminId);
  if (humanAt !== null && input.nowMs - humanAt * 1000 <= windowMs) {
    if (unanswered(humanAt)) return notAnswering;
    return { held: true, reclaim: false, reason: `human assignee ${admin}` };
  }
  return {
    held: false,
    reclaim: true,
    reason: `stale human assignee ${admin}: no human reply in ${hours}h`,
  };
}

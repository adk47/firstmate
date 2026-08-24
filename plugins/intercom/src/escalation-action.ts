import type {
  IntercomSessionState,
  IntercomAccountConfig,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { IntercomAssignmentConflictError } from "./outbound.js";
import { intercomDeeplink, getTierForAction, TIER_SLAS } from "./ticket-format.js";

export interface TicketResult {
  ok: boolean;
  ticketId?: string;
  sla?: string;
  error?: string;
}

export interface CreateTicketParams {
  actionType: string;
  customerEmail: string;
  customerProfileId?: string;
  summary: string;
  conversationSummary: string;
  conversationId: string;
  workspaceId: string;
}

export interface ExecuteEscalationDeps {
  state: IntercomSessionState;
  conversationId: string;
  assessment: RiskAssessment;
  currentMessage: string;
  account: IntercomAccountConfig;
  client: IntercomClient;
  saveState: () => Promise<void>;
  createTicket: (p: CreateTicketParams) => Promise<TicketResult>;
  postSlack: (payload: unknown) => Promise<void>;
  log: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void };
}

function buildFarewell(assessment: RiskAssessment, ticket: TicketResult): string {
  const isMagic = assessment.source === "user_request";
  const prefix = isMagic ? "Got it — " : "";
  if (ticket.ok && ticket.ticketId && ticket.sla) {
    return `${prefix}I'm pulling in a teammate to take this from here. They'll follow up here within ${ticket.sla}. Reference: ${ticket.ticketId}.`;
  }
  return `${prefix}I'm pulling in a teammate to take this from here. We'll follow up here shortly.`;
}

const SUMMARY_PREFIX_BY_SOURCE: Record<NonNullable<RiskAssessment["source"]>, (reason: string) => string> = {
  user_request: () => "User explicitly requested a human.",
  rule: (reason) => `Rule fired: ${reason}.`,
  judge: (reason) => `Judge flagged: ${reason}.`,
};

function buildSummary(assessment: RiskAssessment, currentMessage: string): string {
  const prefixFn = assessment.source ? SUMMARY_PREFIX_BY_SOURCE[assessment.source] : null;
  const prefix = prefixFn ? prefixFn(assessment.reason ?? "support") : "Escalation triggered.";
  const tail = currentMessage ? ` Last user message: ${currentMessage.slice(0, 400)}` : "";
  return `${prefix}${tail}`;
}

function buildSlackPayload(args: {
  conversationId: string;
  assessment: RiskAssessment;
  ticket: TicketResult;
  email: string;
  workspaceId: string;
  currentMessage: string;
}): unknown {
  const { conversationId, assessment, ticket, email, workspaceId, currentMessage } = args;
  const url = intercomDeeplink(workspaceId, conversationId);
  const ticketField = ticket.ok
    ? `#${ticket.ticketId} (${ticket.sla})`
    : `creation failed: ${ticket.error}`;
  const snippet = currentMessage.length > 200
    ? `${currentMessage.slice(0, 200)}…`
    : currentMessage;
  return {
    text: `🚨 Intercom escalation conv ${conversationId} — <${url}|View>`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text:
            `🚨 *Intercom escalation*\n` +
            `*Source:* ${assessment.source ?? "n/a"} / ${assessment.reason ?? "n/a"}\n` +
            `*Confidence:* ${assessment.confidence ?? "n/a"}\n` +
            `*Customer:* ${email}\n` +
            `*Ticket:* ${ticketField}\n` +
            `*Last message:* ${snippet}`,
        },
      },
      {
        type: "actions",
        elements: [
          { type: "button", text: { type: "plain_text", text: "View in Intercom" }, url },
        ],
      },
    ],
  };
}

export async function executeEscalation(deps: ExecuteEscalationDeps): Promise<void> {
  const {
    state,
    conversationId,
    assessment,
    currentMessage,
    account,
    client,
    saveState,
    createTicket,
    postSlack,
    log,
  } = deps;

  // Step 1 — set dedupe gate, persist before any I/O. If saveState throws, do
  // NOT keep the in-memory mutation: we don't want a process-lifetime "ghost"
  // gate that would suppress all future escalations for this conv until restart.
  const previousFiredAt = state.escalationFiredAt;
  const previousHandoffMode = state.handoffMode;
  const previousUpdatedAt = state.updatedAt;
  const firedAt = new Date().toISOString();
  state.escalationFiredAt = firedAt;
  state.handoffMode = "human_takeover";
  state.updatedAt = firedAt;
  try {
    await saveState();
  } catch (err) {
    state.escalationFiredAt = previousFiredAt;
    state.handoffMode = previousHandoffMode;
    state.updatedAt = previousUpdatedAt;
    log.error(`[intercom:ALERT] [intercom:escalation] saveState failed conv=${conversationId} — aborting escalation: ${err}`);
    throw err;
  }

  const email = state.knownFacts?.accountEmail ?? "unknown (no accountEmail on file)";

  // Step 2 — file ClickUp ticket.
  //
  // A previous attempt may have created the ticket and then rolled the dedupe
  // gate back (farewell AND Slack both failed), which is what lets us be here
  // twice for one conversation. The ticket is not the thing that failed, so
  // re-filing it just produces a duplicate Conversation-link group in ClickUp —
  // and this path deliberately runs no open-ticket dedupe to catch that (see
  // clickup.ts). Reuse the remembered id instead; only the delivery is retried.
  const actionType = assessment.suggestedActionType ?? "support-general";
  let ticket: TicketResult = { ok: false, error: "ticket creation skipped" };
  if (state.escalationTicketId) {
    // Quote the SLA of the ticket we are REUSING, not one recomputed from this
    // retry's assessment. The two can differ — a refund escalation files a Tier 3
    // ticket (5-10 business days), and the next message can reassess as
    // support-general (Tier 1, 2 business days). The ticket's ClickUp due date is
    // fixed at creation, so recomputing would promise a window it does not have.
    const filedActionType = state.escalationTicketActionType ?? actionType;
    ticket = { ok: true, ticketId: state.escalationTicketId, sla: TIER_SLAS[getTierForAction(filedActionType)] };
    log.info(
      `[intercom:escalation] reusing ticket from a rolled-back attempt conv=${conversationId} id=${state.escalationTicketId} — retrying delivery only`,
    );
  } else {
    try {
      ticket = await createTicket({
        actionType,
        customerEmail: state.knownFacts?.accountEmail ?? "unknown@unknown",
        customerProfileId: state.knownFacts?.musoProfileId,
        summary: assessment.reason ?? "support",
        conversationSummary: buildSummary(assessment, currentMessage),
        conversationId,
        workspaceId: account.workspaceId,
      });
      if (ticket.ok) {
        // Remember it BEFORE the delivery steps run: if they fail we roll the
        // dedupe gate back, and that rollback's saveState is what persists this.
        state.escalationTicketId = ticket.ticketId;
        state.escalationTicketActionType = actionType;
        log.info(`[intercom:escalation] ticket created conv=${conversationId} id=${ticket.ticketId}`);
      } else {
        log.warn(`[intercom:escalation] ticket creation failed conv=${conversationId} err=${ticket.error}`);
      }
    } catch (err) {
      ticket = { ok: false, error: String(err) };
      log.warn(`[intercom:escalation] ticket creation threw conv=${conversationId} err=${err}`);
    }
  }

  // Step 3 — post farewell.
  let farewellOk = false;
  const body = buildFarewell(assessment, ticket);
  try {
    await client.replyToConversation({
      conversationId,
      adminId: account.botAdminId,
      body,
    });
    farewellOk = true;
  } catch (err) {
    log.error(`[intercom:escalation] farewell post failed conv=${conversationId}: ${err}`);
  }

  // Step 4 — reassign to default escalation target.
  let assignOk = false;
  try {
    await client.assignConversation({
      conversationId,
      adminId: account.botAdminId,
      assigneeId: account.defaultInboxId || "0",
    });
    assignOk = true;
    log.info(`[intercom:escalation] reassigned conv=${conversationId} → ${account.defaultInboxId || "Unassigned"}`);
  } catch (err) {
    if (err instanceof IntercomAssignmentConflictError) {
      assignOk = true;
      log.info(`[intercom:escalation] reassign conflict (human already on it) conv=${conversationId}`);
    } else {
      log.error(`[intercom:escalation] reassign failed conv=${conversationId}: ${err}`);
    }
  }

  // Step 5 — Slack ping.
  let slackOk = false;
  try {
    await postSlack(
      buildSlackPayload({
        conversationId,
        assessment,
        ticket,
        email,
        workspaceId: account.workspaceId,
        currentMessage,
      }),
    );
    slackOk = true;
  } catch (err) {
    log.error(`[intercom:escalation] Slack ping failed conv=${conversationId}: ${err}`);
  }

  // Rollup: if both customer-facing signal (farewell) AND ops-facing signal
  // (Slack) failed, the user is silently stranded. Roll back the dedupe gate
  // so the next webhook can retry, and emit an ALERT log so ops sees it now.
  if (!farewellOk && !slackOk) {
    state.escalationFiredAt = previousFiredAt;
    state.handoffMode = previousHandoffMode;
    state.updatedAt = previousUpdatedAt;
    try {
      await saveState();
    } catch (err) {
      log.error(`[intercom:ALERT] [intercom:escalation] rollback saveState failed conv=${conversationId}: ${err}`);
    }
    log.error(
      `[intercom:ALERT] [intercom:escalation] full failure conv=${conversationId} ` +
        `ticket=${ticket.ok} farewell=${farewellOk} assign=${assignOk} slack=${slackOk} — rolled back dedupe gate, will retry on next message`,
    );
  }
}

import type {
  IntercomSessionState,
  IntercomAccountConfig,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { IntercomAssignmentConflictError } from "./outbound.js";

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

function buildFarewell(assessment: RiskAssessment, ticket: TicketResult, email: string): string {
  const isMagic = assessment.source === "user_request";
  const prefix = isMagic ? "Got it — " : "";
  if (ticket.ok && ticket.ticketId && ticket.sla) {
    return `${prefix}I'm pulling in a teammate to take this from here. They'll follow up at ${email} within ${ticket.sla}. Reference: ${ticket.ticketId}.`;
  }
  return `${prefix}I'm pulling in a teammate to take this from here. They'll follow up at ${email} shortly.`;
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
  const url = `https://app.intercom.com/a/inbox/${workspaceId}/inbox/conversation/${conversationId}`;
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

  const email = state.knownFacts?.accountEmail ?? "your account email on file";

  // Step 2 — file ClickUp ticket.
  let ticket: TicketResult = { ok: false, error: "ticket creation skipped" };
  try {
    ticket = await createTicket({
      actionType: assessment.suggestedActionType ?? "support-general",
      customerEmail: state.knownFacts?.accountEmail ?? "unknown@unknown",
      customerProfileId: state.knownFacts?.musoProfileId,
      summary: assessment.reason ?? "support",
      conversationSummary: buildSummary(assessment, currentMessage),
    });
    if (ticket.ok) {
      log.info(`[intercom:escalation] ticket created conv=${conversationId} id=${ticket.ticketId}`);
    } else {
      log.warn(`[intercom:escalation] ticket creation failed conv=${conversationId} err=${ticket.error}`);
    }
  } catch (err) {
    ticket = { ok: false, error: String(err) };
    log.warn(`[intercom:escalation] ticket creation threw conv=${conversationId} err=${err}`);
  }

  // Step 3 — post farewell.
  let farewellOk = false;
  const body = buildFarewell(assessment, ticket, email);
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

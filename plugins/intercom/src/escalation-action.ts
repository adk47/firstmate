import type {
  IntercomSessionState,
  IntercomAccountConfig,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { isAssignmentConflict } from "./outbound.js";
import { applyHandOff } from "./assignment-policy.js";
import { HONEST_FALLBACK } from "./answer-bank.js";
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
  // Optional one-line subject for the ticket TITLE. Without it a ticket is
  // titled from `summary`, which reads "[support] Escalation: <ask> — email";
  // with it the title reads "[support] Credits missing on 3 tracks — email".
  // The reason code is not a topic, so the title must not be built from it.
  gistSubject?: string;
  // Machine-readable hand-off facts. Reaches the ---ACTION-REQUEST--- JSON
  // block as `details`, which is what the ops lanes actually read. Before this
  // existed the escalation path passed no details at all, so every hand-off
  // ticket had `details: {}` and `details.escalation_reason` existed nowhere.
  details?: Record<string, unknown>;
}

export interface ExecuteEscalationDeps {
  state: IntercomSessionState;
  conversationId: string;
  assessment: RiskAssessment;
  currentMessage: string;
  // Previous turns, oldest first, EXCLUDING the current message — handler.ts
  // buildRecentPartsFromLiveConversation already pops the trailing duplicate of
  // the triggering webhook. This is what turns a 400-char slice of "ok" into
  // the customer's actual question: by the time a turn cap fires, the message
  // that tripped it is never the one that asked anything.
  recentParts?: { author: "user" | "bot"; body: string }[];
  account: IntercomAccountConfig;
  client: IntercomClient;
  saveState: () => Promise<void>;
  createTicket: (p: CreateTicketParams) => Promise<TicketResult>;
  postSlack: (payload: unknown) => Promise<void>;
  log: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void };
}

/**
 * The escalation farewell. No path names a person (captain 2026-11-14: the escalation team has no
 * members, so "a teammate is taking this" was never true): the approved honesty line, plus the
 * ticket reference when a ticket exists. `outbound.ts` writes the owed-follow-up record that makes
 * "I have recorded this" true before this is posted.
 */
function buildFarewell(assessment: RiskAssessment, ticket: TicketResult): string {
  const prefix = assessment.source === "user_request" ? "Got it — " : "";
  if (ticket.ok && ticket.ticketId) return `${prefix}${HONEST_FALLBACK} Reference: ${ticket.ticketId}.`;
  return `${prefix}${HONEST_FALLBACK}`;
}

// ---------------------------------------------------------------------------
// Hand-off narrative (firstmate driver 2026-11-04, rank 1 of
// data/ops-humans-off-fable-o1/dispatch/support-general-plan.md)
//
// The turn_count_cap hand-off used to write
//   "Rule fired: turn_count_cap. Last user message: <first 400 chars>"
// By the time a cap fires the last user message is "ok", so out of 383 shape-A
// tickets 312 carried a fragment with no question in it (median 37 chars; 97
// under 20; the shortest 🫡 / ok / Why?), and `details` was `{}` on all 360
// parseable ones. A cap is a REASON, not a question — the asking happened
// earlier in the thread, so the thread itself has to be read.
//
// This synthesis is deterministic: the thread is customer-authored text and
// must not become model input on this path. No new fetch — handler.ts already
// built `recentParts` for the risk judge and hands it to us.
// ---------------------------------------------------------------------------

const ASK_MAX_CHARS = 300;
const EXCERPT_MAX_CHARS = 700;
const EXCERPT_TURNS = 3;

// Bare acknowledgements, emoji and punctuation. These are what a thread
// degenerates into by the time a cap fires, and none is a question.
const ACK_RE =
  /^(?:ok(?:ay)?|k|kk|yes|yep|yeah|yup|no|nope|nah|sure|thanks(?:!)?|thank you|thx|ty|great|good|cool|perfect|correct|right|hello|hi|hey|hiya|yo|sup)(?:[\s,.!?]*(?:ok|thanks|thank you|great|sure|👍|🙏))*$/i;

function isEmojiOnly(text: string): boolean {
  return text.length > 0 && !/[\p{L}\p{N}]/u.test(text);
}

function isAck(text: string): boolean {
  return ACK_RE.test(text.trim());
}

type AskKind = "substantive" | "short" | "noise";

// "Substantive" is mechanical, never a judgement call: under 20 chars is short,
// an acknowledgement or emoji is noise, anything else is a real ask.
function classifyAsk(text: string): AskKind {
  const t = text.trim();
  if (!t) return "noise";
  if (isEmojiOnly(t) || isAck(t)) return "noise";
  if (t.length < 20) return "short";
  return "substantive";
}

function oneLine(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

// Shorten at a word boundary so the last word is never a fragment. A window
// with no space at all (a URL, an id, a language without spaces) is cut on the
// character boundary rather than returning nothing.
function clipOneLine(text: string, maxChars: number): string {
  const flat = oneLine(text);
  if (flat.length <= maxChars) return flat;
  const cut = flat.slice(0, maxChars);
  const lastSpace = cut.lastIndexOf(" ");
  if (lastSpace <= 0) return `${cut}…`;
  return `${cut.slice(0, lastSpace).trimEnd()}…`;
}

// The customer's first REAL question, one line. Falls back the way the spec
// says: if every message is short, the longest short message among the first
// five (never an acknowledgement); if there is genuinely nothing, an explicit
// empty value — a misleading fragment is worse than saying nothing was asked.
export function pickOriginalAsk(userMessages: string[]): string {
  const cleaned = userMessages.map(oneLine).filter(Boolean);
  const substantive = cleaned.find((m) => classifyAsk(m) === "substantive") ?? null;
  if (substantive) return clipOneLine(substantive, ASK_MAX_CHARS);
  const longestShort = cleaned
    .slice(0, 5)
    .filter((m) => classifyAsk(m) === "short")
    .sort((a, b) => b.length - a.length)[0];
  if (longestShort) return clipOneLine(longestShort, ASK_MAX_CHARS);
  const n = cleaned.length;
  return `(customer sent no substantive message; ${n} short exchange${n === 1 ? "" : "s"})`;
}

// The last ~3 customer turns, verbatim (whitespace collapsed to keep one line),
// bounded. This is what lets the receiving lane see the "ok / thanks / ok" tail
// that preceded the cap without opening Intercom.
export function buildConversationExcerpt(userMessages: string[]): string {
  const last = userMessages.map(oneLine).filter(Boolean).slice(-EXCERPT_TURNS);
  if (!last.length) return "";
  return clipOneLine(last.join(" / "), EXCERPT_MAX_CHARS);
}

export interface EscalationNarrative {
  originalAsk: string;
  conversationExcerpt: string;
  conversationSummary: string;
  turnCount: number;
}

function exchangeWord(n: number): string {
  return `${n} exchange${n === 1 ? "" : "s"}`;
}

export function buildEscalationNarrative(args: {
  assessment: RiskAssessment;
  currentMessage: string;
  recentParts?: { author: "user" | "bot"; body: string }[];
  turnCount: number;
}): EscalationNarrative {
  const { assessment, currentMessage, recentParts, turnCount } = args;
  const previousUser = (recentParts ?? []).filter((p) => p.author === "user").map((p) => p.body);
  // recentParts excludes the current message (it is the triggering webhook), so
  // append it: the thread the customer actually had ends with it.
  const userMessages = [...previousUser, currentMessage].filter((m) => m && m.trim());
  const originalAsk = pickOriginalAsk(userMessages);
  const conversationExcerpt = buildConversationExcerpt(userMessages);

  const exchanges = exchangeWord(turnCount);
  let lead: string;
  switch (assessment.source) {
    case "user_request":
      lead = `Customer asked for a human after ${exchanges}.`;
      break;
    case "judge":
      // Add the ask, do not replace the reason: "Judge flagged: loop_detected.
      // Last user message: ok" has exactly the same defect as the cap.
      lead = `Judge flagged ${assessment.reason ?? "support"} after ${exchanges}.`;
      break;
    default:
      lead =
        assessment.reason === "turn_count_cap"
          ? `Cap reached after ${exchanges}.`
          : `Rule fired: ${assessment.reason ?? "support"} after ${exchanges}.`;
  }
  return {
    originalAsk,
    conversationExcerpt,
    conversationSummary: `${lead} Ask: ${originalAsk}`,
    turnCount,
  };
}

// The machine-readable hand-off block. EXACTLY these five keys — the drainer
// filters on escalation_reason and the JSON block sits last in a description
// ClickUp truncates, so extra keys are a cost with no reader.
export function buildEscalationDetails(args: {
  assessment: RiskAssessment;
  narrative: EscalationNarrative;
}): Record<string, unknown> {
  return {
    escalation_reason: args.assessment.reason ?? "support",
    original_ask: args.narrative.originalAsk,
    conversation_excerpt: args.narrative.conversationExcerpt,
    turn_count: args.narrative.turnCount,
    summary_source: "code_rule",
  };
}

function buildSlackPayload(args: {
  conversationId: string;
  assessment: RiskAssessment;
  ticket: TicketResult;
  email: string;
  workspaceId: string;
  narrative: EscalationNarrative;
}): unknown {
  const { conversationId, assessment, ticket, email, workspaceId, narrative } = args;
  const url = intercomDeeplink(workspaceId, conversationId);
  const ticketField = ticket.ok
    ? `#${ticket.ticketId} (${ticket.sla})`
    : `creation failed: ${ticket.error}`;
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
            `*Ask:* ${narrative.originalAsk}`,
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

  // One synthesis feeds the ticket's human fields, its machine block and the
  // Slack line, so the three can never disagree about what was handed over.
  const narrative = buildEscalationNarrative({
    assessment,
    currentMessage,
    recentParts: deps.recentParts,
    // Same fallback assessRisk uses for the cap: a session persisted before
    // userExchangeCount existed falls back to the message count.
    turnCount: state.userExchangeCount ?? state.userTurnCount ?? 0,
  });

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
        // Request: is the customer's one-line ASK, never the reason code. The
        // ticket exists so a human can act on the question; "turn_count_cap"
        // tells the reader why the bot gave up, not what the customer needs.
        summary: narrative.originalAsk,
        gistSubject: narrative.originalAsk,
        conversationSummary: narrative.conversationSummary,
        conversationId,
        workspaceId: account.workspaceId,
        // The documented support-general hand-off contract (action-request
        // SKILL.md): escalation_reason, original_ask, conversation_excerpt,
        // turn_count, summary_source. Deterministic, five keys, no model call —
        // the thread is customer-authored text and must not become model input.
        details: buildEscalationDetails({ assessment, narrative }),
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

  // Step 3 — post farewell. The approved honesty line + the ticket reference; never a person.
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

  // Step 4 — move to the escalation QUEUE, carrying the reason (assignment-policy.ts). Never a
  // person: the target is the configured escalation team, or Intercom's Unassigned inbox.
  const escalationReason = `${assessment.source}/${assessment.reason || "unspecified"}`;
  let assignOk = false;
  try {
    const applied = await applyHandOff({
      client,
      account,
      conversationId,
      kind: "risk_escalation",
      reason: escalationReason,
      isConflict: isAssignmentConflict,
      log,
    });
    assignOk = applied.outcome !== "failed";
    if (assignOk) log.info(`[intercom:escalation] reassigned conv=${conversationId} → ${applied.label} reason=${escalationReason}`);
  } catch (err) {
    log.error(`[intercom:escalation] reassign failed conv=${conversationId}: ${err}`);
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
        narrative,
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

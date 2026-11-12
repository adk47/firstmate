import { describe, it, expect, vi } from "vitest";
import {
  executeEscalation,
  buildEscalationDetails,
  buildEscalationNarrative,
  pickOriginalAsk,
  buildConversationExcerpt,
} from "../src/escalation-action.js";
import { buildTicketMarkdown, MAX_TICKET_DESCRIPTION_CHARS, getTierForAction } from "../src/ticket-format.js";
import type { IntercomSessionState, RiskAssessment, IntercomAccountConfig } from "../src/types.js";

function makeState(): IntercomSessionState {
  return {
    conversationId: "conv1",
    workspaceId: "ws1",
    handoffMode: "agent_active",
    lifecycleState: "open",
    currentAssigneeId: "bot",
    currentAssigneeType: "bot",
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: "",
    updatedAt: "",
    userTurnCount: 5,
    escalationFiredAt: null,
    knownFacts: { accountEmail: "support-customer@example.com" },
  };
}

const account = {
  enabled: true,
  workspaceId: "ws1",
  token: "t",
  webhookSecret: "s",
  botAdminId: "bot",
  escalationTeamId: "7111842",
  fallbackSlackSupervisionChannel: "https://hooks.slack.example",
  fallbackAcknowledgement: "We'll get back to you.",
  requireMappedHumanAdmin: true,
  adminMapping: {},
} as IntercomAccountConfig;

const ANY_EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i;

const assessment: RiskAssessment = {
  triggered: true,
  source: "rule",
  reason: "refund_intent",
  matchedPattern: "\\brefund\\b",
  suggestedActionType: "subscription-refund",
  confidence: "high",
};

describe("executeEscalation", () => {
  it("sets dedupe gate BEFORE any I/O", async () => {
    const state = makeState();
    const order: string[] = [];
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async () => { order.push("reply"); return { messageId: "m1" }; },
        assignConversation: async () => { order.push("assign"); },
        getConversation: async () => ({} as any),
      },
      saveState: async () => { order.push("save"); },
      createTicket: async () => { order.push("ticket"); return { ok: true, ticketId: "T1", sla: "5-10 business days" }; },
      postSlack: async () => { order.push("slack"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });

    expect(state.escalationFiredAt).not.toBeNull();
    expect(state.handoffMode).toBe("human_takeover");
    expect(order[0]).toBe("save");           // gate persisted first
    expect(order[1]).toBe("ticket");         // ticket second
    expect(order.indexOf("reply")).toBe(2);  // farewell after ticket
  });

  it("uses the SLA-bearing farewell when ticket succeeds", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "5-10 business days" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    // The ticket's internal SLA never reaches the customer (caroline-instructions-1029 §2.9).
    expect(farewellBody).not.toContain("5-10 business days");
    expect(farewellBody).not.toMatch(/business day|shortly|soon/i);
    expect(farewellBody).toContain("T1");
    expect(farewellBody).toContain("in this conversation and by email");
    expect(farewellBody).not.toMatch(ANY_EMAIL);
  });

  it("uses the degraded farewell when ticket fails", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: false, error: "ClickUp 503" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody).not.toContain("Reference");
    expect(farewellBody).toContain("in this conversation and by email");
    expect(farewellBody).not.toMatch(/shortly|soon|business day/i);
    expect(farewellBody).not.toMatch(ANY_EMAIL);
  });

  it("does not echo internal emails in the degraded farewell", async () => {
    const state = makeState();
    state.knownFacts = { accountEmail: "operations@muso.ai" };
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: false, error: "ClickUp 503" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody).toContain("in this conversation and by email");
    expect(farewellBody).not.toMatch(/shortly|soon|business day/i);
    expect(farewellBody).not.toContain("operations@muso.ai");
    expect(farewellBody).not.toMatch(ANY_EMAIL);
  });

  it("prepends 'Got it — ' for magic-keyword path", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment: { ...assessment, source: "user_request", reason: "user_requested_human" },
      currentMessage: "talk to a human please",
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "48 hours" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody.startsWith("Got it — ")).toBe(true);
  });

  it("tolerates assignment conflict (human already grabbed it)", async () => {
    const state = makeState();
    const { IntercomAssignmentConflictError } = await import("../src/outbound.js");
    await expect(executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => { throw new IntercomAssignmentConflictError("conflict"); },
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    })).resolves.not.toThrow();
  });

  // intercom-no-human-assignment-k1: the ONE remaining path to a human. It goes to the escalation
  // TEAM (never an admin id) and the reason travels with it.
  it("escalates to the escalation team with type team, and logs the reason", async () => {
    const state = makeState();
    const assigns: Record<string, unknown>[] = [];
    const info: string[] = [];
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async (p: Record<string, unknown>) => { assigns.push(p); },
        // the hand-off is only logged as done when a read-back shows the team and no admin
        getConversation: async () => ({ admin_assignee_id: null, team_assignee_id: 7111842 } as any),
      } as never,
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => {},
      log: { info: (m: string) => info.push(m), warn: () => {}, error: () => {} },
    });
    expect(assigns).toEqual([
      { conversationId: "conv1", adminId: "bot", assigneeId: "0" },
      { conversationId: "conv1", adminId: "bot", assigneeId: "7111842", assigneeType: "team" },
    ]);
    const line = info.find((m) => m.includes("[intercom:escalation] reassigned conv=conv1"));
    expect(line).toContain("team:7111842");
    expect(line).toContain(`reason=${assessment.source}/${assessment.reason}`);
  });

  // QA on #1892, round 4: both requests accepted, but an admin took the conversation in between.
  it("does not log a completed hand-off when the read-back shows a person still holds it", async () => {
    const state = makeState();
    const info: string[] = [];
    const errors: string[] = [];
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({ admin_assignee_id: 5465657, team_assignee_id: 7111842 } as any),
      } as never,
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => {},
      log: { info: (m: string) => info.push(m), warn: () => {}, error: (m: string) => errors.push(m) },
    });
    expect(info.some((m) => m.includes("[intercom:escalation] reassigned conv=conv1"))).toBe(false);
    expect(errors.some((m) => /\[intercom:ALERT\].*team assign FAILED.*admin 5465657 holds the conversation/.test(m))).toBe(true);
  });

  it("threads currentMessage into the ticket conversation summary", async () => {
    const state = makeState();
    let captured: { summary: string; conversationSummary: string } | null = null;
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "I'm furious about being charged twice this month",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async (p) => {
        captured = { summary: p.summary, conversationSummary: p.conversationSummary };
        return { ok: true, ticketId: "T1", sla: "5-10 business days" };
      },
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(captured!.conversationSummary).toContain("I'm furious about being charged twice this month");
  });

  it("rolls back the dedupe gate when both farewell AND Slack fail", async () => {
    const state = makeState();
    const errors: string[] = [];
    let saveCount = 0;
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async () => { throw new Error("intercom 503"); },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => { saveCount += 1; },
      createTicket: async () => ({ ok: false, error: "ClickUp 401" }),
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: (m) => errors.push(m) },
    });
    expect(state.escalationFiredAt).toBeNull();
    expect(state.handoffMode).toBe("agent_active");
    expect(saveCount).toBe(2); // initial + rollback
    expect(errors.some((m) => m.includes("[intercom:ALERT]") && m.includes("rolled back"))).toBe(true);
  });

  // WHY: the rollback above re-opens the escalation gate so the next webhook can
  // retry the farewell/Slack delivery. But the ClickUp ticket was already created
  // in Step 2, and its id was thrown away with the local — so the retry filed a
  // SECOND ticket for the same conversation. clickup.ts deliberately skips the
  // open-ticket dedupe on the premise that "escalation fires at most once per
  // conversation (escalationFiredAt gate)", and this rollback is precisely what
  // falsifies that premise. Result: duplicate Conversation-link groups in ClickUp
  // (W34 ops review). Retrying delivery is correct; re-filing the ticket is not.
  it("remembers a created ticket across a rollback so the retry does not file a second", async () => {
    const state = makeState();
    let ticketCalls = 0;
    const deps = () => ({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async () => { throw new Error("intercom 503"); },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => { ticketCalls += 1; return { ok: true as const, ticketId: "T-DUP", sla: "5-10 business days" }; },
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });

    await executeEscalation(deps());
    // The gate is re-opened so delivery can be retried...
    expect(state.escalationFiredAt).toBeNull();
    // ...but the ticket that DID get created must survive the rollback.
    expect(state.escalationTicketId).toBe("T-DUP");

    // Next inbound message re-escalates. It must reuse the ticket, not file another.
    await executeEscalation(deps());
    expect(ticketCalls).toBe(1);
  });

  // WHY: the reused ticket's tier — and therefore its ClickUp due date — was
  // fixed when it was FILED. A retry arrives with a fresh assessment, which can
  // land on a different action type (a later message reassessed as
  // support-general, or an explicit-human request bypassing the gate). Deriving
  // the SLA from that assessment tells the customer "2 business days" about a
  // Tier 3 refund ticket that is actually due in 5-10 — a promise nothing in
  // ClickUp will keep.
  it("reuses the filed ticket on a retry and quotes no SLA in either farewell (was: the reused ticket's own SLA)", async () => {
    const state = makeState();
    const farewells: string[] = [];
    const deps = (a: RiskAssessment) => ({
      state,
      conversationId: "conv1",
      assessment: a,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async (p: { body: string }) => { farewells.push(p.body); throw new Error("intercom 503"); },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true as const, ticketId: "T-REFUND", sla: "5-10 business days" }),
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });

    // First attempt: a refund → Tier 3 ticket, 5-10 business days. Both delivery
    // signals fail, so the gate rolls back and the ticket is remembered.
    await executeEscalation(deps(assessment));
    expect(state.escalationTicketId).toBe("T-REFUND");

    // The retry reassesses as plain support (Tier 1, "2 business days").
    await executeEscalation(deps({ ...assessment, reason: "support", suggestedActionType: "support-general" }));
    expect(farewells).toHaveLength(2);
    expect(farewells[1]).toContain("T-REFUND");
    // No SLA in either farewell, reused or not (caroline-instructions-1029 §2.9).
    expect(farewells[1]).not.toMatch(/business day/);
  });

  it("files a ticket on retry when the first attempt never created one", async () => {
    // The mirror case: a rollback after a FAILED ticket creation must still allow
    // the retry to file one, or a stranded customer gets no ticket at all.
    const state = makeState();
    let ticketCalls = 0;
    const deps = () => ({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async () => { throw new Error("intercom 503"); },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => { ticketCalls += 1; return { ok: false as const, error: "ClickUp 401" }; },
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });

    await executeEscalation(deps());
    expect(state.escalationTicketId).toBeFalsy();
    await executeEscalation(deps());
    expect(ticketCalls).toBe(2);
  });

  it("does NOT roll back when farewell succeeds even if Slack fails", async () => {
    const state = makeState();
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(state.escalationFiredAt).not.toBeNull();
    expect(state.handoffMode).toBe("human_takeover");
  });

  it("rejects and rolls back if initial saveState throws", async () => {
    const state = makeState();
    await expect(executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => { throw new Error("EROFS"); },
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    })).rejects.toThrow("EROFS");
    expect(state.escalationFiredAt).toBeNull();
    expect(state.handoffMode).toBe("agent_active");
  });

  it("continues if Slack ping fails (logs but does not throw)", async () => {
    const state = makeState();
    await expect(executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      currentMessage: "i want a refund please",
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    })).resolves.not.toThrow();
  });
});


// ---------------------------------------------------------------------------
// turn_count_cap hand-off (firstmate driver 2026-11-04, rank 1)
//
// The producer used to write "Rule fired: turn_count_cap. Last user message:
// <first 400 chars>". By the time a cap fires the last message is "ok", so 312
// of 383 cap hand-offs carried a fragment with no question in it and `details`
// was `{}` on every parseable one. These tests pin the documented contract:
// a real ask, the excerpt, the exchange count, five keys, no reason code in the
// human fields, and the machine block last and parseable.
// ---------------------------------------------------------------------------

const capAssessment: RiskAssessment = {
  triggered: true,
  source: "rule",
  reason: "turn_count_cap",
  matchedPattern: "",
  suggestedActionType: "support-general",
  confidence: "medium",
};

// A 30-exchange thread whose LAST message is "ok" — the exact shape that made
// the old summary useless. recentParts excludes the current message, as
// handler.ts builds it.
function longThread(): { recentParts: { author: "user" | "bot"; body: string }[]; current: string } {
  const parts: { author: "user" | "bot"; body: string }[] = [
    { author: "user", body: "I have been charged twice this month and three of my credits are missing from the catalog." },
    { author: "bot", body: "Sorry about that — can you confirm the email on the account?" },
    { author: "user", body: "It is support-customer@example.com, and the missing credits are on three tracks." },
  ];
  // Fill to 26 previous turns with the degenerate tail a cap actually sees,
  // then pin the LAST three customer turns so the excerpt assertion is exact:
  // "why?" / "thanks" / the current "ok".
  const filler = ["ok", "yes", "👍", "hello", "ok", "thanks"];
  for (let i = parts.length; i < 26; i += 1) {
    parts.push({ author: i % 2 === 0 ? "user" : "bot", body: filler[i % filler.length] });
  }
  parts.push({ author: "user", body: "why?" });
  parts.push({ author: "bot", body: "Because the cap counts consecutive customer turns." });
  parts.push({ author: "user", body: "thanks" });
  return { recentParts: parts, current: "ok" };
}

function buildEnclosing(a: RiskAssessment, ask: string, excerpt: string) {
  return {
    originalAsk: ask,
    conversationExcerpt: excerpt,
    conversationSummary: `Cap reached after 30 exchanges. Ask: ${ask}`,
    turnCount: 30,
  };
}

function captureTicket(state: IntercomSessionState) {
  const captured: { summary: string; gistSubject?: string; conversationSummary: string; details?: Record<string, unknown> }[] = [];
  const deps = (assessment: RiskAssessment, currentMessage: string, recentParts?: { author: "user" | "bot"; body: string }[]) => ({
    state,
    conversationId: "conv1",
    assessment,
    currentMessage,
    recentParts,
    account,
    client: {
      replyToConversation: async () => ({ messageId: "m1" }),
      assignConversation: async () => {},
      getConversation: async () => ({} as never),
    },
    saveState: async () => {},
    createTicket: async (p: { summary: string; gistSubject?: string; conversationSummary: string; details?: Record<string, unknown> }) => {
      captured.push(p);
      return { ok: true, ticketId: "T1", sla: "2 business days" };
    },
    postSlack: async () => {},
    log: { info: () => {}, warn: () => {}, error: () => {} },
  });
  return { captured, deps };
}

describe("turn_count_cap hand-off", () => {
  it("carries the earlier substantive question, not the 'ok' that tripped the cap", async () => {
    const state = makeState();
    state.userTurnCount = 30;
    state.userExchangeCount = 30;
    const { recentParts, current } = longThread();
    const { captured, deps } = captureTicket(state);
    await executeEscalation(deps(capAssessment, current, recentParts) as never);
    const details = captured[0].details!;
    expect(details.escalation_reason).toBe("turn_count_cap");
    expect(String(details.original_ask)).toContain("charged twice this month");
    expect(String(details.original_ask)).not.toBe("ok");
    expect(details.turn_count).toBe(30);
    expect(details.summary_source).toBe("code_rule");
    // The last three customer turns are in the excerpt, including the tail.
    expect(String(details.conversation_excerpt)).toContain("why?");
    expect(String(details.conversation_excerpt)).toContain("ok");
  });

  it("puts the ask in Request: and never a reason code", async () => {
    const state = makeState();
    state.userTurnCount = 30;
    const { recentParts, current } = longThread();
    const { captured, deps } = captureTicket(state);
    await executeEscalation(deps(capAssessment, current, recentParts) as never);
    expect(captured[0].summary).toContain("charged twice this month");
    expect(captured[0].summary).not.toContain("turn_count_cap");
    expect(captured[0].summary).not.toContain("Rule fired");
    expect(captured[0].conversationSummary).toContain("Cap reached after 30 exchanges.");
    expect(captured[0].conversationSummary).toContain("Ask:");
  });

  it("emits exactly the five documented keys", async () => {
    const state = makeState();
    const { recentParts, current } = longThread();
    const { captured, deps } = captureTicket(state);
    await executeEscalation(deps(capAssessment, current, recentParts) as never);
    expect(Object.keys(captured[0].details!).sort()).toEqual([
      "conversation_excerpt",
      "escalation_reason",
      "original_ask",
      "summary_source",
      "turn_count",
    ]);
  });

  it("writes an explicit empty ask when every message is an acknowledgement", async () => {
    const state = makeState();
    state.userTurnCount = 6;
    const recentParts = [
      { author: "user" as const, body: "ok" },
      { author: "bot" as const, body: "anything else?" },
      { author: "user" as const, body: "yes" },
      { author: "user" as const, body: "thanks" },
      { author: "user" as const, body: "👍" },
    ];
    const { captured, deps } = captureTicket(state);
    await executeEscalation(deps(capAssessment, "ok", recentParts) as never);
    const ask = String(captured[0].details!.original_ask);
    // 4 previous customer messages + the current "ok".
    expect(ask).toBe("(customer sent no substantive message; 5 short exchanges)");
    expect(captured[0].summary).toBe(ask);
  });

  it("keeps the machine block last and parseable, with the ask before it", async () => {
    const state = makeState();
    state.userTurnCount = 30;
    const { recentParts, current } = longThread();
    const narrative = buildEscalationNarrative({
      assessment: capAssessment,
      currentMessage: current,
      recentParts,
      turnCount: 30,
    });
    const mk = (excerpt: string) =>
      buildTicketMarkdown({
        summary: narrative.originalAsk,
        actionType: "support-general",
        tier: getTierForAction("support-general"),
        customerEmail: "support-customer@example.com",
        details: buildEscalationDetails({
          assessment: capAssessment,
          narrative: { ...narrative, conversationExcerpt: excerpt },
        }),
        conversationSummary: narrative.conversationSummary,
        sessionId: "sess-1",
        gist: `Escalation: ${narrative.originalAsk}`,
        sla: "2 business days",
      });

    const body = mk(narrative.conversationExcerpt);
    const jsonStart = body.indexOf("---ACTION-REQUEST---");
    const jsonEnd = body.indexOf("---END-ACTION-REQUEST---");
    expect(jsonStart).toBeGreaterThan(-1);
    expect(jsonEnd).toBeGreaterThan(jsonStart);
    expect(body.indexOf("**Request:**")).toBeLessThan(jsonStart);
    expect(body.indexOf("conversation_excerpt")).toBeLessThan(jsonStart);
    const json = JSON.parse(body.slice(jsonStart + "---ACTION-REQUEST---".length, jsonEnd));
    expect(json.details.escalation_reason).toBe("turn_count_cap");
    expect(json.details.original_ask).toContain("charged twice this month");
    expect(body.length).toBeLessThanOrEqual(MAX_TICKET_DESCRIPTION_CHARS);
  });

  it("bounds the whole body even at the ask and excerpt caps, keeping the JSON last", () => {
    // Worst case the spec allows: a 300-char ask and a 700-char excerpt, both of
    // which also ride in the JSON block. The body must still be bounded, the
    // excerpt shortened, and the machine block last and parseable.
    const ask = ("a".repeat(40) + " ").repeat(8).trim();
    const excerpt = Array.from({ length: 12 }, (_, i) => `customer turn number ${i} `.repeat(4).trim()).join(" / ");
    const narrative = buildEnclosing(assessment, ask, excerpt);
    const body = buildTicketMarkdown({
      summary: narrative.originalAsk,
      actionType: "support-general",
      tier: getTierForAction("support-general"),
      customerEmail: "support-customer@example.com",
      details: buildEscalationDetails({ assessment: capAssessment, narrative }),
      conversationSummary: narrative.conversationSummary,
      sessionId: "sess-1",
      gist: `Escalation: ${narrative.originalAsk}`,
      sla: "2 business days",
    });
    expect(body.length).toBeLessThanOrEqual(MAX_TICKET_DESCRIPTION_CHARS);
    const jsonStart = body.indexOf("---ACTION-REQUEST---");
    const jsonEnd = body.indexOf("---END-ACTION-REQUEST---");
    expect(jsonEnd).toBeGreaterThan(jsonStart);
    expect(() => JSON.parse(body.slice(jsonStart + "---ACTION-REQUEST---".length, jsonEnd))).not.toThrow();
    expect(body.indexOf("**Request:**")).toBeLessThan(jsonStart);
  });

  it("applies the same ask to the user_request and judge sources", async () => {
    for (const source of ["user_request", "judge"] as const) {
      const narr = buildEscalationNarrative({
        assessment: { ...capAssessment, source, reason: "customer_requested_human" },
        currentMessage: "please just get me a person, my credits are still missing",
        recentParts: [],
        turnCount: 4,
      });
      expect(narr.originalAsk).toContain("please just get me a person");
      expect(narr.conversationSummary).toContain("Ask:");
    }
  });
});

describe("pickOriginalAsk", () => {
  it("skips acknowledgements and emoji to find the first real question", () => {
    expect(pickOriginalAsk(["ok", "👍", "thanks", "where did my three credits go?"])).toBe(
      "where did my three credits go?",
    );
  });

  it("falls back to the longest short message when nothing is substantive", () => {
    expect(pickOriginalAsk(["ok", "no credits", "yes"])).toBe("no credits");
  });

  it("says so explicitly when there is nothing at all", () => {
    expect(pickOriginalAsk(["ok", "yes"])).toBe("(customer sent no substantive message; 2 short exchanges)");
    expect(pickOriginalAsk([])).toBe("(customer sent no substantive message; 0 short exchanges)");
  });

  it("bounds the ask without leaving a partial word", () => {
    const long = "word ".repeat(200).trim();
    const out = pickOriginalAsk([long]);
    expect(out.length).toBeLessThanOrEqual(301);
    expect(out.endsWith("…")).toBe(true);
    expect(out.slice(0, -1).endsWith("word")).toBe(true);
  });
});

describe("buildConversationExcerpt", () => {
  it("keeps the last three customer turns, verbatim and in order", () => {
    const out = buildConversationExcerpt(["first question", "second", "third", "fourth", "fifth"]);
    expect(out).toBe("third / fourth / fifth");
  });

  it("bounds a long tail at a word boundary", () => {
    const out = buildConversationExcerpt(["word ".repeat(400)]);
    expect(out.length).toBeLessThanOrEqual(701);
    expect(out.endsWith("…")).toBe(true);
  });
});

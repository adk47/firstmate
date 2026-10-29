import { describe, it, expect, vi } from "vitest";
import { executeEscalation } from "../src/escalation-action.js";
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
  defaultInboxId: "5465657",
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

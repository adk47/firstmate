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
    expect(farewellBody).toContain("5-10 business days");
    expect(farewellBody).toContain("T1");
    expect(farewellBody).toContain("support-customer@example.com");
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
    expect(farewellBody).toContain("shortly");
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

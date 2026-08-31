import { describe, it, expect, vi } from "vitest";
import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import { MockIntercomClient } from "../src/outbound.js";
import type { IntercomWebhookPayload, IntercomSessionState } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";
import adminReplied from "./fixtures/conversation-admin-replied.json";
import assigned from "./fixtures/conversation-assigned.json";
import closed from "./fixtures/conversation-closed.json";

const BOT_ADMIN_ID = "bot_1";

describe("handleWebhookEvent", () => {
  it("dispatches customer message to agent", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = await handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
    if (result.action === "dispatch_to_agent") {
      expect(result.conversationId).toBe("conv_123");
      expect(result.body).toBe("Hi, I need help with my account");
    }
  });

  it("rejects duplicate events", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.processedEventIds = ["evt_001"];
    const { result } = await handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("duplicate");
  });

  it("escalates on billing keywords", async () => {
    const payload = {
      ...userCreated,
      id: "evt_100",
      data: {
        ...userCreated.data,
        item: {
          ...userCreated.data.item,
          source: {
            // "chargeback" (not "refund" — refund was removed from the
            // billing escalation triggers in 7484ade because plain-English
            // refund requests should flow through the normal agent).
            body: "I'm filing a chargeback with my bank",
            author: { type: "user", id: "user_abc" },
          },
        },
      },
    };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updatedState } = await handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("escalate_legacy");
    if (result.action === "escalate_legacy") {
      expect(result.category).toBe("billing");
    }
    expect(updatedState?.handoffMode).toBe("human_takeover");
  });

  it("filters self-replies from bot", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.outboundMessageIds = ["part_1"];
    const { result } = await handleWebhookEvent(adminReplied as IntercomWebhookPayload, state, "admin_42");
    expect(result.action).toBe("filtered");
  });

  it("filters Operator bot reply without triggering takeover", async () => {
    const operatorReplied = {
      ...adminReplied,
      id: "evt_operator_reply",
      data: {
        ...adminReplied.data,
        item: {
          ...adminReplied.data.item,
          conversation_parts: {
            conversation_parts: [{
              ...adminReplied.data.item.conversation_parts.conversation_parts[0],
              id: "part_operator",
              author: { type: "bot", id: "4359478", name: "Operator" },
            }],
          },
        },
      },
    };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(
      operatorReplied as IntercomWebhookPayload, state, BOT_ADMIN_ID,
    );
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toBe("non-human admin reply");
    }
    expect(updated?.handoffMode).toBe("agent_active");
  });

  it("triggers human_takeover on non-bot admin reply", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(adminReplied as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.handoffMode).toBe("human_takeover");
  });

  it("updates state on human admin assignment", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(assigned as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.handoffMode).toBe("human_takeover");
    expect(updated?.currentAssigneeId).toBe("admin_99");
  });

  it("does NOT trigger takeover when Operator bot is assigned", async () => {
    const operatorAssigned = {
      ...assigned,
      id: "evt_bot_assign",
      data: {
        ...assigned.data,
        item: {
          ...assigned.data.item,
          assignee: { type: "bot", id: "4359478", name: "Operator" },
        },
      },
    };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(
      operatorAssigned as IntercomWebhookPayload, state, BOT_ADMIN_ID,
    );
    expect(result.action).toBe("state_updated");
    expect(updated?.handoffMode).toBe("agent_active");
    expect(updated?.currentAssigneeId).toBe("4359478");
  });

  it("updates lifecycle on close", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(closed as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.lifecycleState).toBe("closed");
  });

  it("implicitly reopens closed conversation on customer reply", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.lifecycleState = "closed";
    const payload = { ...userCreated, id: "evt_200" };
    const { result, state: updated } = await handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
    expect(updated?.lifecycleState).toBe("open");
  });

  it("ignores internal notes", async () => {
    const noted = { ...userCreated, id: "evt_300", topic: "conversation.admin.noted" };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = await handleWebhookEvent(noted as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("ignored");
  });

  it("handles events with no existing session (null state)", async () => {
    const { result } = await handleWebhookEvent(userCreated as IntercomWebhookPayload, null, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("tracks event IDs in state", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    await handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(state.processedEventIds).toContain("evt_001");
  });

  it("suppresses dispatch during human_takeover", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.handoffMode = "human_takeover";
    const payload = { ...userCreated, id: "evt_400" };
    const { result } = await handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("suppressed");
    }
  });

  it("suppresses dispatch when snoozed", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.lifecycleState = "snoozed";
    const payload = { ...userCreated, id: "evt_401" };
    const { result } = await handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("suppressed");
    }
  });

  describe("live check", () => {
    it("filters when live check finds human assignee", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          assignee: { type: "admin" as const, id: "human_admin_1", name: "Jan" },
        };
      };

      const payload = { ...userCreated, id: "evt_500" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("live check");
      }
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(updated?.currentAssigneeId).toBe("human_admin_1");
    });

    it("dispatches when live check finds Operator bot assignee (not our bot)", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          assignee: { type: "bot" as const, id: "4359478", name: "Operator" },
        };
      };

      const payload = { ...userCreated, id: "evt_operator_live" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("dispatch_to_agent");
      expect(updated?.handoffMode).toBe("agent_active");
    });

    it("dispatches when live check finds bot assignee", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          assignee: { type: "bot" as const, id: BOT_ADMIN_ID },
        };
      };

      const payload = { ...userCreated, id: "evt_501" };
      const { result } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("dispatch_to_agent");
    });

    it("preserves human_takeover when live check finds non-human assignee (bot/no human)", async () => {
      // Live check is monotonic: it can ESCALATE to human_takeover when the
      // API reports a human assignee, but it must NOT downgrade back to
      // agent_active when the API reports the bot/no-one is assigned. A
      // human admin can reply (handleAdminReply → human_takeover) without
      // re-assigning, and our bot self-assigns every dispatch so the API
      // ~always reports the bot as assignee. Downgrade is the job of the
      // explicit conversation.admin.assigned and conversation.admin.opened
      // webhooks (handleAssignment / handleImplicitReopen).
      const state = createInitialSessionState("conv_123", "ws_1");
      state.handoffMode = "human_takeover";
      state.currentAssigneeId = "human_admin_1";

      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          assignee: { type: "bot" as const, id: BOT_ADMIN_ID },
        };
      };

      const payload = { ...userCreated, id: "evt_502" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human_takeover");
      }
    });

    it("falls through to cached state when API call fails", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async () => {
        throw new Error("Network error");
      };

      const payload = { ...userCreated, id: "evt_503" };
      const { result } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("dispatch_to_agent");
    });

    it("falls through to cached state when client is not provided", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const payload = { ...userCreated, id: "evt_504" };
      const { result } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID,
      );
      expect(result.action).toBe("dispatch_to_agent");
    });

    it("filters when live check finds closed conversation", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: false,
          state: "closed" as const,
          assignee: null,
        };
      };

      const payload = { ...userCreated, id: "evt_505" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("live check");
      }
      expect(updated?.lifecycleState).toBe("closed");
    });

    // --- Regression tests for Intercom API v2.11 shape ---
    // The real GET /conversations/{id} endpoint returns `admin_assignee_id`
    // (number), not the webhook-shaped `assignee` object. Prior to the fix,
    // the live check read `conversation.assignee?.id` and silently reset
    // handoff state on every customer follow-up.

    it("filters when live API reports admin_assignee_id for a human (v2.11 shape)", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          // Real API v2.11 shape — no `assignee` object.
          admin_assignee_id: 9999,
          team_assignee_id: null,
        };
      };

      const payload = { ...userCreated, id: "evt_v211_human" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human assignee 9999");
      }
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(updated?.currentAssigneeId).toBe("9999");
      expect(updated?.currentAssigneeType).toBe("admin");
    });

    it("dispatches when live API reports admin_assignee_id for the bot (v2.11 shape)", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      // BOT_ADMIN_ID is the string "bot_1" in this test suite; to match the
      // v2.11 numeric shape we use a numeric bot id here via a local const.
      const NUMERIC_BOT_ID = "4359478";
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          admin_assignee_id: 4359478,
          team_assignee_id: null,
        };
      };

      const payload = { ...userCreated, id: "evt_v211_bot" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, NUMERIC_BOT_ID, client,
      );
      expect(result.action).toBe("dispatch_to_agent");
      expect(updated?.handoffMode).toBe("agent_active");
      expect(updated?.currentAssigneeId).toBe("4359478");
      expect(updated?.currentAssigneeType).toBe("admin");
    });

    it("dispatches when live API reports no admin assignee (v2.11 shape, team only)", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          admin_assignee_id: null,
          team_assignee_id: 2238258,
        };
      };

      const payload = { ...userCreated, id: "evt_v211_team" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(result.action).toBe("dispatch_to_agent");
      expect(updated?.handoffMode).toBe("agent_active");
      expect(updated?.currentAssigneeId).toBeNull();
      expect(updated?.currentAssigneeType).toBeNull();
    });

    it("prefers admin_assignee_id over assignee when both are present", async () => {
      // Regression guard: both handler.ts and slack.ts prefer `admin_assignee_id`
      // over the legacy `assignee` object. A future refactor reordering the
      // conditions would silently flip behavior without this test.
      const state = createInitialSessionState("conv_123", "ws_1");
      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          // API says the human 5465657 owns it.
          admin_assignee_id: 5465657,
          // Stale webhook-shape field says the bot owns it — must be ignored.
          assignee: { type: "admin" as const, id: BOT_ADMIN_ID, name: "Bot" },
        };
      };

      const payload = { ...userCreated, id: "evt_v211_both" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      // admin_assignee_id (5465657) is a real human → human_takeover.
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human assignee 5465657");
      }
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(updated?.currentAssigneeId).toBe("5465657");
    });

    it("preserves human_takeover when API response omits assignee fields entirely", async () => {
      // Regression guard: before the fix, an API response with neither
      // `assignee` nor `admin_assignee_id` silently reset handoffMode to
      // agent_active. After the fix, missing signal = preserve existing
      // state, and canAgentReply() filters the customer message because
      // state is still human_takeover.
      const state = createInitialSessionState("conv_123", "ws_1");
      state.handoffMode = "human_takeover";
      state.currentAssigneeId = "5465657";
      state.currentAssigneeType = "admin";

      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        // Deliberately omit `assignee`, `admin_assignee_id`, `team_assignee_id`.
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
        };
      };

      const payload = { ...userCreated, id: "evt_v211_missing" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(updated?.currentAssigneeId).toBe("5465657");
      expect(updated?.currentAssigneeType).toBe("admin");
      // canAgentReply() is false for human_takeover → filtered.
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human_takeover");
      }
    });

    // Regression for conv=215474192304895 (Jan, 2026-05-06): a human admin
    // replied without re-assigning, the bot self-assigns on every dispatch
    // so the API reports admin_assignee_id == bot, and the live check used
    // to unconditionally downgrade handoffMode back to agent_active —
    // wiping the human_takeover that handleAdminReply had just set.
    it("preserves human_takeover when human admin replied without assigning (live API reports bot as assignee)", async () => {
      const NUMERIC_BOT_ID = "4359478";
      const state = createInitialSessionState("conv_123", "ws_1");
      state.handoffMode = "human_takeover";
      state.currentAssigneeId = "5465657";
      state.currentAssigneeType = "admin";

      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          admin_assignee_id: 4359478,
          team_assignee_id: null,
        };
      };

      const payload = { ...userCreated, id: "evt_jan_followup" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, NUMERIC_BOT_ID, client,
      );
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human_takeover");
      }
    });

    it("preserves human_takeover when API reports null admin_assignee_id", async () => {
      const state = createInitialSessionState("conv_123", "ws_1");
      state.handoffMode = "human_takeover";
      state.currentAssigneeId = "5465657";
      state.currentAssigneeType = "admin";

      const client = new MockIntercomClient();
      client.getConversation = async (params) => {
        client.calls.getConversation.push(params);
        return {
          type: "conversation" as const,
          id: params.conversationId,
          title: null,
          created_at: Date.now() / 1000,
          updated_at: Date.now() / 1000,
          open: true,
          state: "open" as const,
          admin_assignee_id: null,
          team_assignee_id: null,
        };
      };

      const payload = { ...userCreated, id: "evt_no_assignee" };
      const { result, state: updated } = await handleWebhookEvent(
        payload as IntercomWebhookPayload, state, BOT_ADMIN_ID, client,
      );
      expect(updated?.handoffMode).toBe("human_takeover");
      expect(result.action).toBe("filtered");
      if (result.action === "filtered") {
        expect(result.reason).toContain("human_takeover");
      }
    });
  });
});

// ---------------------------------------------------------------------------
// Helpers for flag-on / flag-off test suites below
// ---------------------------------------------------------------------------

function makeUserPayload(body: string, eventId = "evt-" + Math.random()): IntercomWebhookPayload {
  return {
    type: "notification_event",
    app_id: "app",
    data: {
      type: "notification_event_data",
      item: {
        type: "conversation",
        id: "conv1",
        title: null,
        created_at: 0,
        updated_at: 0,
        open: true,
        state: "open",
        source: { body, author: { type: "user", id: "u1" } },
      } as any,
    },
    topic: "conversation.user.replied",
    id: eventId,
    created_at: 0,
    delivery_status: "ok",
    delivery_attempts: 1,
  };
}

function makeState(): IntercomSessionState {
  return {
    conversationId: "conv1",
    workspaceId: "ws1",
    handoffMode: "agent_active",
    lifecycleState: "open",
    currentAssigneeId: null,
    currentAssigneeType: null,
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: "",
    updatedAt: "",
    userTurnCount: 0,
    escalationFiredAt: null,
    knownFacts: {},
  };
}

describe("handler — flag off (legacy escalation path)", () => {
  it("does NOT escalate on plain 'refund' (legacy rules unchanged from pre-PR baseline)", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i want a refund"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false } },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("DOES escalate on 'chargeback' via legacy rules", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i'm filing a chargeback"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false } },
    );
    expect(result.action).toBe("escalate_legacy");
    if (result.action === "escalate_legacy") {
      expect(result.category).toBe("billing");
    }
  });

  it("does NOT escalate on 'cancel my subscription' via legacy (would only fire on new path)", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i want to cancel my subscription"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false } },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });
});

describe("handler — flag on (assessRisk path)", () => {
  it("dispatches to agent for benign messages", async () => {
    const state = makeState();
    const { result, state: out } = await handleWebhookEvent(
      makeUserPayload("hi"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(out!.userTurnCount).toBe(1);
  });

  it("dispatches plain 'refund' to the agent (retention flow owns it, not a rule)", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i want a refund"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("returns escalate action when refund intent fires (dispute-grade signal)", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i'm filing a chargeback"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("escalate");
    if (result.action === "escalate") {
      expect(result.assessment.reason).toBe("refund_intent");
    }
  });

  it("short-circuits subsequent customer turns once escalationFiredAt is set", async () => {
    const state = makeState();
    state.escalationFiredAt = "2026-05-04T00:00:00Z";
    state.handoffMode = "human_takeover";
    const { result } = await handleWebhookEvent(
      makeUserPayload("any reply"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("filtered");
  });

  it("magic keyword bypasses escalationFiredAt (user re-requests human)", async () => {
    const state = makeState();
    state.escalationFiredAt = "2026-05-04T00:00:00Z";
    state.handoffMode = "human_takeover";
    const { result } = await handleWebhookEvent(
      makeUserPayload("can i talk to a human"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("escalate");
  });

  it("pinned-fact extractor runs and updates knownFacts", async () => {
    const state = makeState();
    const { state: out } = await handleWebhookEvent(
      makeUserPayload("you can email me at me@example.com"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(out!.knownFacts?.accountEmail).toBe("me@example.com");
  });
});

// ---------------------------------------------------------------------------
// blockedChannelTags — social-channel hard skip (instagram, facebook, etc.)
// ---------------------------------------------------------------------------

function makeUserPayloadWithTags(body: string, tagNames: string[]): IntercomWebhookPayload {
  const p = makeUserPayload(body);
  (p.data.item as any).tags = {
    type: "tag.list",
    tags: tagNames.map((name, i) => ({ id: String(i), name })),
  };
  return p;
}

describe("handler — blockedChannelTags", () => {
  it("filters customer message when conv tag matches blocked list", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayloadWithTags("hello", ["instagram"]),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false }, blockedChannelTags: ["instagram", "facebook"] },
    );
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toBe("blocked-channel: instagram");
    }
  });

  it("matches case-insensitively", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayloadWithTags("hello", ["Instagram"]),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false }, blockedChannelTags: ["instagram"] },
    );
    expect(result.action).toBe("filtered");
  });

  it("dispatches when conv has no matching tag", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayloadWithTags("hello", ["VIP", "Refund"]),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false }, blockedChannelTags: ["instagram"] },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("dispatches when conv has no tags at all", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("hello"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false }, blockedChannelTags: ["instagram"] },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("dispatches when blockedChannelTags is empty (default behavior)", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayloadWithTags("hello", ["instagram"]),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false }, blockedChannelTags: [] },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("dispatches when blockedChannelTags is omitted", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayloadWithTags("hello", ["instagram"]),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false } },
    );
    expect(result.action).toBe("dispatch_to_agent");
  });
});

// ---------------------------------------------------------------------------
// personalization enrichment — verified, logged-in customers only
// ---------------------------------------------------------------------------

function makeVerifiedUserPayload(body: string, opts: { email?: string; name?: string } = {}): IntercomWebhookPayload {
  const p = makeUserPayload(body);
  (p.data.item as any).source.author = {
    type: "user",
    id: "u1",
    ...(opts.email ? { email: opts.email } : {}),
    ...(opts.name ? { name: opts.name } : {}),
  };
  return p;
}

describe("handler — personalization enrichment", () => {
  const enabled = { riskAssessment: { enabled: true }, personalization: { enabled: true } };

  it("calls enrich once on dispatch for a verified user when enabled", async () => {
    const state = makeState();
    const enrich = vi.fn(async () => {});
    const { result } = await handleWebhookEvent(
      makeVerifiedUserPayload("hi", { email: "jane@example.com", name: "Jane" }),
      state, "bot", undefined, { ...enabled, enrich },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(enrich).toHaveBeenCalledTimes(1);
    expect(enrich).toHaveBeenCalledWith(state, { email: "jane@example.com", name: "Jane", contactId: "u1" });
  });

  it("does NOT call enrich when personalization is disabled", async () => {
    const state = makeState();
    const enrich = vi.fn(async () => {});
    await handleWebhookEvent(
      makeVerifiedUserPayload("hi", { email: "jane@example.com", name: "Jane" }),
      state, "bot", undefined,
      { riskAssessment: { enabled: true }, personalization: { enabled: false }, enrich },
    );
    expect(enrich).not.toHaveBeenCalled();
  });

  it("does NOT call enrich when the author has no verified email", async () => {
    const state = makeState();
    const enrich = vi.fn(async () => {});
    await handleWebhookEvent(
      makeVerifiedUserPayload("hi", { name: "Jane" }), // no email
      state, "bot", undefined, { ...enabled, enrich },
    );
    expect(enrich).not.toHaveBeenCalled();
  });

  it("does NOT call enrich when the conversation was already enriched", async () => {
    const state = makeState();
    state.enrichment = { status: "done", enrichedAt: "2026-01-01T00:00:00Z" };
    const enrich = vi.fn(async () => {});
    await handleWebhookEvent(
      makeVerifiedUserPayload("hi", { email: "jane@example.com", name: "Jane" }),
      state, "bot", undefined, { ...enabled, enrich },
    );
    expect(enrich).not.toHaveBeenCalled();
  });

  it("does NOT call enrich on the escalate path", async () => {
    const state = makeState();
    const enrich = vi.fn(async () => {});
    const { result } = await handleWebhookEvent(
      makeVerifiedUserPayload("i'm filing a chargeback", { email: "jane@example.com", name: "Jane" }),
      state, "bot", undefined, { ...enabled, enrich },
    );
    expect(result.action).toBe("escalate");
    expect(enrich).not.toHaveBeenCalled();
  });

  it("still dispatches when enrich rejects (fail-soft)", async () => {
    const state = makeState();
    const enrich = vi.fn(async () => {
      throw new Error("boom");
    });
    const { result } = await handleWebhookEvent(
      makeVerifiedUserPayload("hi", { email: "jane@example.com", name: "Jane" }),
      state, "bot", undefined, { ...enabled, enrich },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(enrich).toHaveBeenCalledTimes(1);
  });
});

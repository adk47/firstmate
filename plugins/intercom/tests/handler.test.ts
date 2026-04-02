import { describe, it, expect } from "vitest";
import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import { MockIntercomClient } from "../src/outbound.js";
import type { IntercomWebhookPayload } from "../src/types.js";
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
            body: "I want a refund for my subscription",
            author: { type: "user", id: "user_abc" },
          },
        },
      },
    };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updatedState } = await handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("escalate");
    if (result.action === "escalate") {
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

    it("restores agent_active when live check finds bot on human_takeover conversation", async () => {
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
      expect(result.action).toBe("dispatch_to_agent");
      expect(updated?.handoffMode).toBe("agent_active");
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
  });
});

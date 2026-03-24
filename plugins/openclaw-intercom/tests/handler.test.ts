import { describe, it, expect } from "vitest";
import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import type { IntercomWebhookPayload } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";
import adminReplied from "./fixtures/conversation-admin-replied.json";
import assigned from "./fixtures/conversation-assigned.json";
import closed from "./fixtures/conversation-closed.json";

const BOT_ADMIN_ID = "bot_1";

describe("handleWebhookEvent", () => {
  it("dispatches customer message to agent", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
    if (result.action === "dispatch_to_agent") {
      expect(result.conversationId).toBe("conv_123");
      expect(result.body).toBe("Hi, I need help with my account");
    }
  });

  it("rejects duplicate events", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.processedEventIds = ["evt_001"];
    const { result } = handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("duplicate");
  });

  it("escalates on billing keywords", () => {
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
    const { result, state: updatedState } = handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("escalate");
    if (result.action === "escalate") {
      expect(result.category).toBe("billing");
    }
    expect(updatedState?.handoffMode).toBe("human_takeover");
  });

  it("filters self-replies from bot", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.outboundMessageIds = ["part_1"];
    const { result } = handleWebhookEvent(adminReplied as IntercomWebhookPayload, state, "admin_42");
    expect(result.action).toBe("filtered");
  });

  it("triggers human_takeover on non-bot admin reply", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = handleWebhookEvent(adminReplied as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.handoffMode).toBe("human_takeover");
  });

  it("updates state on assignment", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = handleWebhookEvent(assigned as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.handoffMode).toBe("human_takeover");
    expect(updated?.currentAssigneeId).toBe("admin_99");
  });

  it("updates lifecycle on close", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = handleWebhookEvent(closed as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("state_updated");
    expect(updated?.lifecycleState).toBe("closed");
  });

  it("implicitly reopens closed conversation on customer reply", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.lifecycleState = "closed";
    const payload = { ...userCreated, id: "evt_200" };
    const { result, state: updated } = handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
    expect(updated?.lifecycleState).toBe("open");
  });

  it("ignores internal notes", () => {
    const noted = { ...userCreated, id: "evt_300", topic: "conversation.admin.noted" };
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = handleWebhookEvent(noted as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("ignored");
  });

  it("handles events with no existing session (null state)", () => {
    const { result } = handleWebhookEvent(userCreated as IntercomWebhookPayload, null, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("tracks event IDs in state", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    handleWebhookEvent(userCreated as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(state.processedEventIds).toContain("evt_001");
  });

  it("suppresses dispatch during human_takeover", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.handoffMode = "human_takeover";
    const payload = { ...userCreated, id: "evt_400" };
    const { result } = handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("suppressed");
    }
  });

  it("suppresses dispatch when snoozed", () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    state.lifecycleState = "snoozed";
    const payload = { ...userCreated, id: "evt_401" };
    const { result } = handleWebhookEvent(payload as IntercomWebhookPayload, state, BOT_ADMIN_ID);
    expect(result.action).toBe("filtered");
    if (result.action === "filtered") {
      expect(result.reason).toContain("suppressed");
    }
  });
});

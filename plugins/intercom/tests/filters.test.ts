import { describe, it, expect } from "vitest";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "../src/filters.js";
import type { IntercomWebhookPayload } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";
import userReplied from "./fixtures/conversation-user-replied.json";
import adminReplied from "./fixtures/conversation-admin-replied.json";
import assigned from "./fixtures/conversation-assigned.json";
import closed from "./fixtures/conversation-closed.json";

describe("classifyEvent", () => {
  it("classifies conversation.user.created as customer_message", () => {
    const result = classifyEvent(userCreated as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.conversationId).toBe("conv_123");
      expect(result.body).toBe("Hi, I need help with my account");
    }
  });

  it("classifies conversation.user.replied as customer_message", () => {
    const result = classifyEvent(userReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
  });

  it("classifies conversation.admin.replied as admin_reply with type", () => {
    const result = classifyEvent(adminReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("admin_reply");
    if (result.kind === "admin_reply") {
      expect(result.adminId).toBe("admin_42");
      expect(result.adminType).toBe("admin");
      expect(result.messageId).toBe("part_1");
    }
  });

  it("classifies conversation.admin.assigned as assigned with type", () => {
    const result = classifyEvent(assigned as IntercomWebhookPayload);
    expect(result.kind).toBe("assigned");
    if (result.kind === "assigned") {
      expect(result.assigneeId).toBe("admin_99");
      expect(result.assigneeType).toBe("admin");
    }
  });

  it("extracts bot assignee type from assignment payload", () => {
    const botAssigned = {
      ...assigned,
      data: {
        ...assigned.data,
        item: {
          ...assigned.data.item,
          assignee: { type: "bot", id: "4359478", name: "Operator" },
        },
      },
    };
    const result = classifyEvent(botAssigned as IntercomWebhookPayload);
    expect(result.kind).toBe("assigned");
    if (result.kind === "assigned") {
      expect(result.assigneeType).toBe("bot");
    }
  });

  it("extracts bot admin type from admin reply payload", () => {
    const botReplied = {
      ...adminReplied,
      data: {
        ...adminReplied.data,
        item: {
          ...adminReplied.data.item,
          conversation_parts: {
            conversation_parts: [{
              ...adminReplied.data.item.conversation_parts.conversation_parts[0],
              author: { type: "bot", id: "4359478", name: "Operator" },
            }],
          },
        },
      },
    };
    const result = classifyEvent(botReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("admin_reply");
    if (result.kind === "admin_reply") {
      expect(result.adminType).toBe("bot");
    }
  });

  it("classifies conversation.admin.closed as lifecycle/closed", () => {
    const result = classifyEvent(closed as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") {
      expect(result.state).toBe("closed");
    }
  });

  it("classifies conversation.admin.snoozed as lifecycle/snoozed", () => {
    const snoozed = { ...userCreated, topic: "conversation.admin.snoozed" };
    const result = classifyEvent(snoozed as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") expect(result.state).toBe("snoozed");
  });

  it("classifies conversation.admin.opened as lifecycle/open", () => {
    const opened = { ...userCreated, topic: "conversation.admin.opened" };
    const result = classifyEvent(opened as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") expect(result.state).toBe("open");
  });

  it("classifies conversation.admin.noted as noted", () => {
    const noted = { ...userCreated, topic: "conversation.admin.noted" };
    const result = classifyEvent(noted as IntercomWebhookPayload);
    expect(result.kind).toBe("noted");
  });

  it("classifies unknown topics as unknown", () => {
    const unknown = { ...userCreated, topic: "conversation.admin.something_new" };
    const result = classifyEvent(unknown as IntercomWebhookPayload);
    expect(result.kind).toBe("unknown");
  });
});

describe("idempotency", () => {
  it("returns false for unseen event ID", () => {
    const set = createEventIdSet([]);
    expect(isEventProcessed("evt_001", set)).toBe(false);
  });

  it("returns true for already-processed event ID", () => {
    const set = createEventIdSet(["evt_001"]);
    expect(isEventProcessed("evt_001", set)).toBe(true);
  });

  it("tracks a new event ID", () => {
    const processed: string[] = [];
    trackEventId("evt_001", processed);
    expect(processed).toContain("evt_001");
  });

  it("evicts oldest ID when exceeding MAX_PROCESSED_EVENT_IDS", () => {
    const processed = Array.from({ length: 1000 }, (_, i) => `evt_${i}`);
    trackEventId("evt_new", processed);
    expect(processed.length).toBe(1000);
    expect(processed).not.toContain("evt_0");
    expect(processed).toContain("evt_new");
  });
});

describe("isSelfReply", () => {
  it("returns true when messageId is in outbound list", () => {
    expect(isSelfReply("msg_1", ["msg_1", "msg_2"])).toBe(true);
  });

  it("returns false for unknown messageId", () => {
    expect(isSelfReply("msg_3", ["msg_1", "msg_2"])).toBe(false);
  });
});

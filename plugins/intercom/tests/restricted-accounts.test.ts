import { describe, it, expect } from "vitest";
import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import {
  isRestrictedContact,
  restrictionFor,
  RESTRICTED_CATEGORY,
  RESTRICTED_NOTE,
  PROOF_REVIEW_CATEGORY,
  PROOF_REVIEW_NOTE,
} from "../src/restricted-accounts.js";
import { MockIntercomClient } from "../src/outbound.js";
import type { IntercomWebhookPayload } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";

const BOT_ADMIN_ID = "bot_1";
// A contact of one of the 3 accounts that stay banned.
const RESTRICTED_ID = "63bf0173c00101f1a4a458ec";
// A contact of one of the 9 restored accounts under proof review.
const PROOF_REVIEW_ID = "651d64867692574a9d4363fc";
// The contact that wrote in on 2026-10-12 17:56Z: its account was cleared by the re-review.
const CLEARED_ID = "6310229dc45a0ca92679342c";

function messageFrom(authorId: string, body: string, eventId = "evt_restricted") {
  return {
    ...userCreated,
    id: eventId,
    data: {
      ...userCreated.data,
      item: {
        ...userCreated.data.item,
        source: { body, author: { type: "user", id: authorId } },
      },
    },
  } as IntercomWebhookPayload;
}

// `stale: true` = the human assignee never acted in the conversation (assignment-policy.ts
// humanHold: a human holds a conversation only while a human is working it).
function clientWithLiveAssignee(assignee: { type: "admin"; id: string; name: string }, opts: { stale?: boolean } = {}) {
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
      assignee,
      conversation_parts: {
        type: "conversation_part.list" as const,
        total_count: opts.stale ? 0 : 1,
        conversation_parts: opts.stale
          ? []
          : [{ type: "conversation_part" as const, id: "p1", part_type: "comment", body: "on it", created_at: Math.floor(Date.now() / 1000) - 60, author: { type: "admin", id: assignee.id } }],
      },
    } as never;
  };
  return client;
}

describe("isRestrictedContact / restrictionFor", () => {
  it("matches a listed contact id", () => {
    expect(isRestrictedContact(RESTRICTED_ID)).toBe(true);
    expect(isRestrictedContact(PROOF_REVIEW_ID)).toBe(true);
  });
  it("gives each tier its own category and note; the proof-review note makes no refund statement", () => {
    expect(restrictionFor(RESTRICTED_ID)).toEqual({ category: RESTRICTED_CATEGORY, note: RESTRICTED_NOTE });
    expect(restrictionFor(PROOF_REVIEW_ID)).toEqual({ category: PROOF_REVIEW_CATEGORY, note: PROOF_REVIEW_NOTE });
    expect(PROOF_REVIEW_NOTE).not.toMatch(/refund|fraud|banned/i);
  });
  it("does not restrict the accounts the re-review cleared", () => {
    for (const id of [CLEARED_ID, "65b3e065580fd1f460c245d4", "6a9e80edd104b6ae5dee7309", "671d131a4dfa16defa68cbd9"]) {
      expect(restrictionFor(id)).toBeNull();
    }
  });
  it("does not match other ids, empty, null or undefined", () => {
    expect(isRestrictedContact("user_abc")).toBe(false);
    expect(isRestrictedContact("")).toBe(false);
    expect(isRestrictedContact(null)).toBe(false);
    expect(isRestrictedContact(undefined)).toBe(false);
  });
});

describe("handleWebhookEvent - restricted accounts", () => {
  it("never dispatches a restricted contact to the agent: restricted hold + human takeover", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(
      messageFrom(RESTRICTED_ID, "I didn't cancel my subscription, please fix it"),
      state,
      BOT_ADMIN_ID,
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") {
      expect(result.category).toBe(RESTRICTED_CATEGORY);
      expect(result.note).toBe(RESTRICTED_NOTE);
      expect(result.reassign).toBe(true);
    }
    expect(updated?.handoffMode).toBe("human_takeover");
  });

  it("wins over keyword escalation (no generic acknowledgement path)", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = await handleWebhookEvent(
      messageFrom(RESTRICTED_ID, "I will file a chargeback with my lawyer"),
      state,
      BOT_ADMIN_ID,
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") {
      expect(result.category).toBe(RESTRICTED_CATEGORY);
    }
  });

  it("re-alerts without reassigning when a human admin already holds the conversation", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = clientWithLiveAssignee({ type: "admin", id: "human_admin_1", name: "Jan" });
    const { result, state: updated } = await handleWebhookEvent(
      messageFrom(RESTRICTED_ID, "Any update on my cancellation?"),
      state,
      BOT_ADMIN_ID,
      client,
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") {
      expect(result.category).toBe(RESTRICTED_CATEGORY);
      expect(result.note).toBe(RESTRICTED_NOTE);
      expect(result.reassign).toBe(false);
    }
    expect(updated?.handoffMode).toBe("human_takeover");
    expect(updated?.currentAssigneeId).toBe("human_admin_1");
    expect(updated?.currentAssigneeType).toBe("admin");
  });

  it("a STALE human assignee does not keep a restricted contact: reassign to the escalation queue", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = clientWithLiveAssignee({ type: "admin", id: "5465657", name: "Jan" }, { stale: true });
    const { result, state: updated } = await handleWebhookEvent(
      messageFrom(RESTRICTED_ID, "Any update on my cancellation?", "evt_stale_r"),
      state,
      BOT_ADMIN_ID,
      client,
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") expect(result.reassign).toBe(true);
    // Caroline still stays out: a restricted contact is never answered by the agent.
    expect(updated?.handoffMode).toBe("human_takeover");
  });

  it("a restricted contact already in the escalation team is not reassigned again", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const, id: params.conversationId, title: null, created_at: 1, updated_at: 1,
        open: true, state: "open" as const, admin_assignee_id: null, team_assignee_id: 7111842,
        conversation_parts: { conversation_parts: [
          { part_type: "assignment", created_at: 1, author: { type: "admin", id: BOT_ADMIN_ID }, assigned_to: { type: "team", id: "7111842" } },
        ] },
      } as never;
    };
    const { result } = await handleWebhookEvent(
      messageFrom(RESTRICTED_ID, "hello?", "evt_team_r"), state, BOT_ADMIN_ID, client,
      { humanHold: { escalationTeamId: "7111842" } },
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") expect(result.reassign).toBe(false);
  });

  it("still filters a non-restricted contact whose conversation a human admin holds", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const client = clientWithLiveAssignee({ type: "admin", id: "human_admin_1", name: "Jan" });
    const { result, state: updated } = await handleWebhookEvent(
      messageFrom("user_abc", "Any update?", "evt_c"),
      state,
      BOT_ADMIN_ID,
      client,
    );
    expect(result.action).toBe("filtered");
    expect(updated?.handoffMode).toBe("human_takeover");
    expect(updated?.currentAssigneeId).toBe("human_admin_1");
  });

  it("routes a proof-review contact to a human silently, with the neutral note", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result, state: updated } = await handleWebhookEvent(
      messageFrom(PROOF_REVIEW_ID, "Why are some of my credits still missing?", "evt_p"),
      state,
      BOT_ADMIN_ID,
    );
    expect(result.action).toBe("restricted_hold");
    if (result.action === "restricted_hold") {
      expect(result.category).toBe(PROOF_REVIEW_CATEGORY);
      expect(result.note).toBe(PROOF_REVIEW_NOTE);
    }
    expect(updated?.handoffMode).toBe("human_takeover");
  });

  it("lets a cleared account reach the agent like anyone else", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = await handleWebhookEvent(messageFrom(CLEARED_ID, "Thanks, I can log in now", "evt_x"), state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");
  });

  it("works without session state", async () => {
    const { result } = await handleWebhookEvent(messageFrom(RESTRICTED_ID, "hello"), null, BOT_ADMIN_ID);
    expect(result.action).toBe("restricted_hold");
  });

  it("leaves everyone else unchanged: normal message dispatches, keyword escalation is a normal escalation", async () => {
    const state = createInitialSessionState("conv_123", "ws_1");
    const { result } = await handleWebhookEvent(messageFrom("user_abc", "Hi, I need help", "evt_a"), state, BOT_ADMIN_ID);
    expect(result.action).toBe("dispatch_to_agent");

    const state2 = createInitialSessionState("conv_123", "ws_1");
    const { result: r2 } = await handleWebhookEvent(
      messageFrom("user_abc", "I'm filing a chargeback", "evt_b"),
      state2,
      BOT_ADMIN_ID,
    );
    expect(["escalate", "escalate_legacy"]).toContain(r2.action);
    expect(r2.action).not.toBe("restricted_hold");
  });
});

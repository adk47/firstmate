import { describe, it, expect, vi } from "vitest";

// Mocked so the direct shadow-log tests below can inspect the exact JSONL row
// jev-shadow-log.ts writes (surface/provider/item_id/state_sha256/
// questions_sha256/actual/rc/http) without touching the real filesystem.
// `stat`/`chmod` are mocked too (not just appendFile/mkdir): jev-shadow-log's
// mode-0600 check calls the real fs otherwise, which is both a prod-path
// touch (JEV_SHADOW_DIR is unset here, so it defaults to
// /var/lib/hydra-jev/shadow) and genuine async disk I/O that raced ahead of
// the fire-and-forget `void appendJevShadowRow(...)` call site in
// handler.ts, so appendFileMock was still unresolved by the time the
// assertions below ran (a real, reproducible regression — see PR history).
const { appendFileMock } = vi.hoisted(() => ({ appendFileMock: vi.fn(async () => undefined) }));
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  const enoent = () => {
    const err = new Error("ENOENT: no such file or directory") as NodeJS.ErrnoException;
    err.code = "ENOENT";
    throw err;
  };
  return {
    ...actual,
    appendFile: appendFileMock,
    mkdir: vi.fn(async () => undefined),
    stat: vi.fn(async () => enoent()),
    chmod: vi.fn(async () => undefined),
  };
});
// jev-shadow-log.ts's append now goes through the `flock` binary
// (execFile), not fs.appendFile, directly -- mocked so this suite never
// shells out to a REAL flock against the real (unset -> prod-default)
// JEV_SHADOW_DIR, and so the row lands on the SAME appendFileMock spy the
// assertions below already read, matching the row's [path, content]
// fs.appendFile-shaped call signature. The fake stdin resolves the write
// SYNCHRONOUSLY on `.end(line)` (no stream event-loop hop) so this stays
// exactly as fast as the fs.appendFile mock it replaces -- a real
// PassThrough's async 'data'/'end' events let earlier tests' fire-and-forget
// shadow writes (many `it()`s above never await appendJevShadowRow) drain
// mid-test instead of before it, inflating a later test's call count.
vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    execFile: (
      _file: string,
      args: string[],
      _options: unknown,
      cb: (err: Error | null) => void,
    ) => {
      const filePath = args[args.length - 1];
      const stdin = {
        end: (line: string) => {
          void appendFileMock(filePath, line).then(() => cb(null), (err: Error) => cb(err));
        },
      };
      return { stdin };
    },
  };
});

import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import { MockIntercomClient } from "../src/outbound.js";
import { createJevBackedJudge, createJevTurnRunner, renderJevBlock, type JevActionsConfig, type JevBands, type JevTurnOutcome, type JevTurnResult } from "../src/jev-router.js";
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

  it("turn count: a customer message continuing their own unanswered burst is the same turn", async () => {
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const, id: "conv1", title: null, created_at: 0, updated_at: 0, open: true, state: "open" as const,
        admin_assignee_id: null,
        source: { body: "Hi", author: { type: "user", id: "u1" } },
        conversation_parts: { conversation_parts: [
          { id: "p1", part_type: "comment", body: "I want to add credits", author: { type: "user", id: "u1" } },
        ] },
      } as any;
    };
    const { state: out } = await handleWebhookEvent(
      makeUserPayload("I want to add credits"), { ...makeState(), userTurnCount: 1, userExchangeCount: 1 }, "bot", client,
      { riskAssessment: { enabled: true } },
    );
    expect(out!.userExchangeCount).toBe(1);
    expect(out!.userTurnCount).toBe(2);
  });

  it("turn count: a customer message after a reply is a new turn; no live data still counts", async () => {
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const, id: "conv1", title: null, created_at: 0, updated_at: 0, open: true, state: "open" as const,
        admin_assignee_id: null,
        source: { body: "Hi", author: { type: "user", id: "u1" } },
        conversation_parts: { conversation_parts: [
          { id: "p1", part_type: "comment", body: "Hey! How can I help?", author: { type: "admin", id: "bot" } },
          { id: "p2", part_type: "comment", body: "I want to add credits", author: { type: "user", id: "u1" } },
        ] },
      } as any;
    };
    const a = await handleWebhookEvent(
      makeUserPayload("I want to add credits"), { ...makeState(), userTurnCount: 1, userExchangeCount: 1 }, "bot", client,
      { riskAssessment: { enabled: true } },
    );
    expect(a.state!.userExchangeCount).toBe(2);
    expect(a.state!.userTurnCount).toBe(2);
    const b = await handleWebhookEvent(
      makeUserPayload("anything"), { ...makeState(), userTurnCount: 1, userExchangeCount: 1 }, "bot", undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(b.state!.userExchangeCount).toBe(2);
    expect(b.state!.userTurnCount).toBe(2);
  });

  it("turn count: a session without userExchangeCount seeds it from the message count", async () => {
    const { state: out } = await handleWebhookEvent(
      makeUserPayload("anything"), { ...makeState(), userTurnCount: 5 }, "bot", undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(out!.userExchangeCount).toBe(6);
    expect(out!.userTurnCount).toBe(6);
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

// ---------------------------------------------------------------------------
// Jev pre-turn router integration (docs/designs/2026-09-22-jev-caroline-router.md §B)
// ---------------------------------------------------------------------------

const JEV_BANDS: JevBands = { bad_faith: 0.85, no_reply: 0.9, human_required: 0.9 };
const JEV_ACTIONS_ALL_ON: JevActionsConfig = { decline: true, silence: true, escalate: true };

function jevResult(answers: JevTurnResult["answers"]): JevTurnResult {
  return {
    ok: true,
    answers,
    latencyMs: 12,
    model: "typesafe/jev-1.13",
    usage: null,
    httpStatus: 200,
    state: { some: "state" },
    questions: { some: "questions" },
  };
}

describe("handler — Jev pre-turn router", () => {
  it("stores a route decision's block onto state.jev for buildAgentRawBody to render, and still dispatches", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
        intent: { type: "choice", choice: "credit_verification", probabilities: { credit_verification: 0.91 } },
      }),
    );
    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(runJev).toHaveBeenCalledTimes(1);
    expect(updatedState?.jev?.action).toBe("route");
    expect(updatedState?.jev?.block).toContain("[ROUTING]");
  });

  // Finding 2 (2026-09-22 PR #999 QA): recentParts must reach runJev (and
  // assessRisk) built from the live-check's already-fetched conversation, in
  // chronological order, customer/Caroline turns only — no second API call.
  //
  // QA re-review (2026-09-22, still PR #999): Intercom stores the OPENING
  // customer message on `conversation.source`, never as a `conversation_part`
  // — the real API shape is a populated `source` PLUS `conversation_parts`
  // for everything after it. This fixture now matches that shape, and
  // asserts the original request (from `source`) reaches runJev first.
  it("passes prior conversation history to runJev in order, built from the live check (no second fetch)", async () => {
    const state = makeState();
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: 0,
        updated_at: 0,
        open: true,
        state: "open" as const,
        assignee: { type: "bot" as const, id: "bot" },
        source: { body: "where's my credit", author: { type: "user", id: "u1" } },
        conversation_parts: {
          conversation_parts: [
            { type: "conversation_part", id: "p2", part_type: "note", created_at: 2, body: "internal note, not a reply", author: { type: "admin", id: "human_1" } },
            { type: "conversation_part", id: "p3", part_type: "comment", created_at: 3, body: "<p>Let me check that for you.</p>", author: { type: "admin", id: "bot" } },
            // Trailing part duplicates the triggering webhook message — must be dropped.
            { type: "conversation_part", id: "p4", part_type: "comment", created_at: 4, body: "it still is not fixed", author: { type: "user", id: "u1" } },
          ],
        },
      } as any;
    };
    const runJev = vi.fn(async () => jevResult({ resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.8 } } }));

    await handleWebhookEvent(
      makeUserPayload("it still is not fixed"), state, "bot", client,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );

    expect(runJev).toHaveBeenCalledTimes(1);
    const call = runJev.mock.calls[0][0];
    // The ORIGINAL request (from conversation.source) must arrive first,
    // ahead of Caroline's reply — otherwise "it still is not fixed" has
    // nothing to refer to.
    expect(call.recentParts).toEqual([
      { author: "user", body: "where's my credit" },
      { author: "bot", body: "Let me check that for you." },
    ]);
  });

  it("passes an empty recentParts list on a first turn with no prior history", async () => {
    const state = makeState();
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: 0,
        updated_at: 0,
        open: true,
        state: "open" as const,
        assignee: { type: "bot" as const, id: "bot" },
        conversation_parts: { conversation_parts: [] },
      } as any;
    };
    const runJev = vi.fn(async () => jevResult({ resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.8 } } }));

    await handleWebhookEvent(
      makeUserPayload("hi, need help"), state, "bot", client,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );

    expect(runJev).toHaveBeenCalledTimes(1);
    expect(runJev.mock.calls[0][0].recentParts).toEqual([]);
  });

  // QA re-review (2026-09-22, PR #999): a genuine first turn has NO prior
  // conversation_parts — the live check's `conversation.source` IS the
  // triggering webhook message itself. It must not be counted as "history"
  // (that would feed Jev the current message twice, once as history and
  // once as the turn itself).
  it("does not double-count conversation.source as history when it IS the current message (first turn)", async () => {
    const state = makeState();
    const client = new MockIntercomClient();
    client.getConversation = async (params) => {
      client.calls.getConversation.push(params);
      return {
        type: "conversation" as const,
        id: params.conversationId,
        title: null,
        created_at: 0,
        updated_at: 0,
        open: true,
        state: "open" as const,
        assignee: { type: "bot" as const, id: "bot" },
        source: { body: "hi, need help", author: { type: "user", id: "u1" } },
        conversation_parts: { conversation_parts: [] },
      } as any;
    };
    const runJev = vi.fn(async () => jevResult({ resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.8 } } }));

    await handleWebhookEvent(
      makeUserPayload("hi, need help"), state, "bot", client,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );

    expect(runJev).toHaveBeenCalledTimes(1);
    expect(runJev.mock.calls[0][0].recentParts).toEqual([]);
  });

  it("stores a decline decision's block and still dispatches (agent delivers the one-line decline)", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.95 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.1 } },
      }),
    );
    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("write me a poem about pizza"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(updatedState?.jev?.action).toBe("decline");
    expect(updatedState?.jev?.badFaithDeclinedAt).toBeTruthy();
  });

  it("returns filtered with reason jev:silence and skips dispatch on a closer-shaped no_reply turn", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "no_reply", probabilities: { no_reply: 0.95 } },
      }),
    );
    const { result } = await handleWebhookEvent(
      makeUserPayload("Thanks so much!"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, actions: JEV_ACTIONS_ALL_ON }, runJev },
    );
    expect(result).toEqual({ action: "filtered", conversationId: "conv1", reason: "jev:silence" });
  });

  it("returns escalate with the mapped RiskAssessment and flips handoffMode to human_takeover", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "human_required", probabilities: { human_required: 0.95 } },
        intent: { type: "choice", choice: "data_deletion", probabilities: { data_deletion: 0.9 } },
      }),
    );
    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("please delete my account"), state, "bot", undefined,
      {
        jev: {
          enabled: true,
          bands: JEV_BANDS,
          actions: JEV_ACTIONS_ALL_ON,
          intents: [{ intent: "data_deletion", action_type_on_handoff: "data-deletion" }],
        },
        runJev,
      },
    );
    expect(result.action).toBe("escalate");
    if (result.action === "escalate") {
      expect(result.assessment).toEqual({
        triggered: true,
        source: "judge",
        reason: "jev:human_required",
        suggestedActionType: "data-deletion",
        confidence: "high",
      });
    }
    expect(updatedState?.handoffMode).toBe("human_takeover");
  });

  it("falls through to the unchanged dispatch path, byte-identical to jev-disabled, when runJev fails (timeout)", async () => {
    const stateA = makeState();
    const stateB = makeState();
    const runJev = vi.fn(async () => ({ ok: false as const, reason: "timeout", httpStatus: null, latencyMs: 5 }));

    const withJev = await handleWebhookEvent(
      makeUserPayload("hi, need help"), stateA, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    const withoutJev = await handleWebhookEvent(makeUserPayload("hi, need help"), stateB, "bot", undefined, {});

    expect(runJev).toHaveBeenCalledTimes(1);
    expect(withJev.result).toEqual(withoutJev.result);
    // The dispatched turn itself is byte-identical (asserted above); the
    // per-turn routing bookkeeping is deliberately reset to "no decision"
    // rather than left undefined — see Finding 3 (2026-09-22 PR #999 QA):
    // a fresh state with no prior route looks the same either way, but a
    // STALE prior-turn route must never survive a failed call, so the reset
    // always runs rather than only conditionally on a prior value.
    expect(withJev.state?.jev).toEqual({ action: "none", block: null, badFaithDeclinedAt: undefined });
  });

  it("does not call runJev when jev.enabled is false", async () => {
    const state = makeState();
    const runJev = vi.fn(async () => ({ ok: false as const, reason: "timeout", httpStatus: null, latencyMs: 5 }));
    await handleWebhookEvent(
      makeUserPayload("hi"), state, "bot", undefined,
      { jev: { enabled: false, bands: JEV_BANDS }, runJev },
    );
    expect(runJev).not.toHaveBeenCalled();
  });

  it("appends a shadow row with the contract shape on a successful turn (surface caroline, actual = the action taken, hashes present)", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    // appendJevShadowRow is deliberately fire-and-forget (`void ...` at the
    // handler.ts call site, never awaited), so its internal await chain —
    // mkdir, a stat-based mode check, then appendFile — can still be
    // in-flight when handleWebhookEvent resolves. waitFor (not a bare
    // assertion) tolerates that without caring how many awaits it takes.
    await vi.waitFor(() => expect(appendFileMock).toHaveBeenCalledTimes(1));
    const [, written] = appendFileMock.mock.calls[0];
    const row = JSON.parse((written as string).trim());
    expect(row.surface).toBe("caroline");
    expect(row.provider).toBe("openrouter");
    expect(row.item_id).toBe("conv1");
    expect(row.actual).toBe("route");
    expect(row.rc).toBe(0);
    expect(row.http).toBe(200);
    // sha256 hex digest: 64 lowercase hex chars.
    expect(row.state_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(row.questions_sha256).toMatch(/^[0-9a-f]{64}$/);
    // The raw state is stored next to the hash by default, so the row is
    // replayable against Jev without needing the original request.
    expect(row.state).toEqual({ some: "state" });
  });

  it("omits the raw state (keeps only state_sha256) when jev.shadow.storeState is false", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, shadow: { storeState: false } }, runJev },
    );
    // appendJevShadowRow is deliberately fire-and-forget (`void ...` at the
    // handler.ts call site, never awaited), so its internal await chain —
    // mkdir, a stat-based mode check, then appendFile — can still be
    // in-flight when handleWebhookEvent resolves. waitFor (not a bare
    // assertion) tolerates that without caring how many awaits it takes.
    await vi.waitFor(() => expect(appendFileMock).toHaveBeenCalledTimes(1));
    const [, written] = appendFileMock.mock.calls[0];
    const row = JSON.parse((written as string).trim());
    expect(row.state).toBeNull();
    expect(row.state_sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  it("appends a failure shadow row (answers null, rc 2, actual none) when runJev fails, and still dispatches unchanged", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const runJev = vi.fn(async () => ({ ok: false as const, reason: "timeout", httpStatus: null, latencyMs: 5 }));
    const { result } = await handleWebhookEvent(
      makeUserPayload("hi, need help"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    // appendJevShadowRow is deliberately fire-and-forget (`void ...` at the
    // handler.ts call site, never awaited), so its internal await chain —
    // mkdir, a stat-based mode check, then appendFile — can still be
    // in-flight when handleWebhookEvent resolves. waitFor (not a bare
    // assertion) tolerates that without caring how many awaits it takes.
    await vi.waitFor(() => expect(appendFileMock).toHaveBeenCalledTimes(1));
    const [, written] = appendFileMock.mock.calls[0];
    const row = JSON.parse((written as string).trim());
    expect(row.surface).toBe("caroline");
    expect(row.answers).toBeNull();
    expect(row.rc).toBe(2);
    expect(row.actual).toBe("none");
    expect(row.http).toBeNull();
    expect(row.state_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(row.questions_sha256).toMatch(/^[0-9a-f]{64}$/);
  });

  // Finding 3 (2026-09-22 PR #999 QA): state.jev persists across turns and
  // renderJevBlock reads it at render time (not decide time) — a stale
  // PRIOR turn's route must not bleed into a turn whose Jev call failed.
  it("a failure row hashes the REAL state/questions (not sha256 of {}), carries the reason token, and honours storeState:false (MUS-3191)", async () => {
    const EMPTY_OBJ_SHA = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
    const rows: Array<Record<string, unknown>> = [];
    for (const [questions, storeState] of [[{ q1: 1 }, true], [{ q2: 2 }, false]] as const) {
      appendFileMock.mockClear();
      const runJev = vi.fn(async () => ({
        ok: false as const, reason: "http_502", httpStatus: 502, latencyMs: 5,
        state: { some: "state" }, questions, model: "jev-x",
      }));
      await handleWebhookEvent(
        makeUserPayload("hi"), makeState(), "bot", undefined,
        { jev: { enabled: true, bands: JEV_BANDS, shadow: { storeState } }, runJev },
      );
      await vi.waitFor(() => expect(appendFileMock).toHaveBeenCalledTimes(1));
      rows.push(JSON.parse((appendFileMock.mock.calls[0][1] as string).trim()));
    }
    expect(rows[0].state_sha256).not.toBe(EMPTY_OBJ_SHA);
    expect(rows[0].questions_sha256).not.toBe(EMPTY_OBJ_SHA);
    expect(rows[0].questions_sha256).not.toBe(rows[1].questions_sha256);
    expect(rows[0].reason).toBe("http_502");
    expect(rows[0].rc).toBe(2);
    expect(rows[0].model).toBe("jev-x");
    expect(rows[0].state).toEqual({ some: "state" });
    expect(rows[1].state).toBeNull();
    expect(rows[1].state_sha256).toBe(rows[0].state_sha256);
  });

  it("clears a stale routing block on Jev failure while preserving cross-turn bad-faith memory", async () => {
    const state = makeState();
    state.jev = {
      action: "route",
      block: "[ROUTING]\npath: caroline_tool (0.85)\nintent: credit_verification (0.91)\n[/ROUTING]",
      badFaithDeclinedAt: "2026-09-01T00:00:00.000Z",
    };
    const runJev = vi.fn(async () => ({ ok: false as const, reason: "timeout", httpStatus: null, latencyMs: 5 }));
    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("do I owe you money for my subscription"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(updatedState?.jev?.action).toBe("none");
    expect(updatedState?.jev?.block).toBeNull();
    // No [ROUTING] block reaches the raw body this turn.
    expect(renderJevBlock(updatedState?.jev)).toBeNull();
    // Once-per-conversation bad-faith memory survives the reset.
    expect(updatedState?.jev?.badFaithDeclinedAt).toBe("2026-09-01T00:00:00.000Z");
  });

  // QA finding 2 (2026-09-22 PR #999): a real malformed 200 (a nested field
  // shaped wrong, not just a missing/non-object `.answers`) used to reach
  // jev-router.ts's render/log path unchecked and THROW there, aborting a
  // real customer's turn. This wires the REAL callJev (via
  // createJevTurnRunner, fetch stubbed) rather than a hand-mocked `runJev`,
  // so it exercises fix (a)'s nested validation end-to-end, not just the
  // handler's existing (pre-existing) reason==="shape" branch.
  it("a malformed 200 (nested confidence is a string) still dispatches normally, injects no [ROUTING] block, and appends a failure shadow row with rc 3", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        answers: {
          resolution_path: { type: "choice", choice: "caroline_tool", confidence: "0.8" },
        },
      }),
    })) as unknown as typeof fetch;
    const runJev = createJevTurnRunner({ apiKey: "k", fetchImpl });

    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS }, runJev },
    );

    expect(result.action).toBe("dispatch_to_agent");
    expect(renderJevBlock(updatedState?.jev)).toBeNull();

    // appendJevShadowRow is deliberately fire-and-forget (`void ...` at the
    // handler.ts call site, never awaited), so its internal await chain —
    // mkdir, a stat-based mode check, then appendFile — can still be
    // in-flight when handleWebhookEvent resolves. waitFor (not a bare
    // assertion) tolerates that without caring how many awaits it takes.
    await vi.waitFor(() => expect(appendFileMock).toHaveBeenCalledTimes(1));
    const [, written] = appendFileMock.mock.calls[0];
    const row = JSON.parse((written as string).trim());
    expect(row.answers).toBeNull();
    expect(row.rc).toBe(3);
    expect(row.actual).toBe("none");
    expect(row.http).toBe(200);
  });

  it("actions.silence off: dispatches instead of filtering, and logs suppressed=silence on the [intercom:jev] line", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "no_reply", probabilities: { no_reply: 0.95 } },
      }),
    );
    const { result } = await handleWebhookEvent(
      makeUserPayload("Thanks so much!"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, actions: { decline: true, silence: false, escalate: false } }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    const jevLine = infoSpy.mock.calls.map((c) => c[0]).find((l) => typeof l === "string" && l.startsWith("[intercom:jev]"));
    expect(jevLine).toContain("action=route");
    expect(jevLine).toContain("suppressed=silence");
    infoSpy.mockRestore();
  });

  it("actions.escalate off: dispatches instead of escalating, and logs suppressed=escalate on the [intercom:jev] line", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "human_required", probabilities: { human_required: 0.95 } },
      }),
    );
    const { result } = await handleWebhookEvent(
      makeUserPayload("please delete my account"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, actions: { decline: true, silence: false, escalate: false } }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    const jevLine = infoSpy.mock.calls.map((c) => c[0]).find((l) => typeof l === "string" && l.startsWith("[intercom:jev]"));
    expect(jevLine).toContain("action=route");
    expect(jevLine).toContain("suppressed=escalate");
    infoSpy.mockRestore();
  });

  // Finding 1 (2026-09-22 PR #999 QA): the Jev-backed judge wired into
  // riskAssessment (buildRiskOptions → createJevBackedJudge, the SAME memoized
  // runner decide() also reads) must honor actions.escalate too, not just
  // decide()'s own escalate branch — otherwise a human_required band hit
  // escalates through assessRisk BEFORE the turn ever reaches decide(), and
  // the shipped actions.escalate:false kill switch never runs.
  it("actions.escalate off: the Jev-backed judge in assessRisk does NOT escalate either — turn dispatches with suppressed=escalate", async () => {
    const infoSpy = vi.spyOn(console, "info").mockImplementation(() => {});
    const state = makeState();
    state.userTurnCount = 3; // handler increments to 4 == DEFAULT_JUDGE_MIN_TURNS before assessRisk runs
    const actions: JevActionsConfig = { decline: true, silence: false, escalate: false };
    const outcome: JevTurnOutcome = jevResult({
      off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
      resolution_path: { type: "choice", choice: "human_required", probabilities: { human_required: 0.95 } },
    });
    const runner = vi.fn(async () => outcome);
    const judge = createJevBackedJudge(runner, JEV_BANDS, () => state.userTurnCount ?? 0, [], actions);

    const { result } = await handleWebhookEvent(
      // Deliberately NOT "delete my account" / other RISK_RULES keyword phrasing —
      // this test isolates the judge path from the deterministic rule layer
      // (which the spec requires stays untouched either way).
      makeUserPayload("my credits are still not showing up"), state, "bot", undefined,
      {
        riskAssessment: { enabled: true },
        riskDeps: { judge, judgeMinTurnCount: 4 },
        jev: { enabled: true, bands: JEV_BANDS, actions },
        runJev: runner,
      },
    );
    expect(result.action).toBe("dispatch_to_agent");
    const jevLine = infoSpy.mock.calls.map((c) => c[0]).find((l) => typeof l === "string" && l.startsWith("[intercom:jev]"));
    expect(jevLine).toContain("suppressed=escalate");
    infoSpy.mockRestore();
  });

  it("actions.escalate ON (mirror case): the Jev-backed judge in assessRisk DOES escalate on a human_required band hit", async () => {
    const state = makeState();
    state.userTurnCount = 3;
    const actions: JevActionsConfig = { decline: true, silence: false, escalate: true };
    const outcome: JevTurnOutcome = jevResult({
      off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
      resolution_path: { type: "choice", choice: "human_required", probabilities: { human_required: 0.95 } },
    });
    const runner = vi.fn(async () => outcome);
    const judge = createJevBackedJudge(runner, JEV_BANDS, () => state.userTurnCount ?? 0, [], actions);

    const { result } = await handleWebhookEvent(
      makeUserPayload("my credits are still not showing up"), state, "bot", undefined,
      {
        riskAssessment: { enabled: true },
        riskDeps: { judge, judgeMinTurnCount: 4 },
        jev: { enabled: true, bands: JEV_BANDS, actions },
        runJev: runner,
      },
    );
    expect(result.action).toBe("escalate");
  });

  it("actions.decline off: dispatches with a route decision instead of declining bad-faith turns", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.95 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.1 } },
      }),
    );
    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("write me a poem about pizza"), state, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, actions: { decline: false, silence: true, escalate: true } }, runJev },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(updatedState?.jev?.action).toBe("route");
  });

  // -------------------------------------------------------------------------
  // Shadow dispatch (jev.shadowVersions) — fire-and-forget, isolated from the
  // live call. "own timeout, errors swallowed to warn" per spec: none of
  // hang/throw/garbage from the shadow call may affect the live turn.
  // -------------------------------------------------------------------------

  function flushMicrotasks(): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, 0));
  }

  it("dual-call isolation: a shadow call that never resolves does not block or change the live turn", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    const runJevShadow = vi.fn(() => new Promise<JevTurnOutcome>(() => {})); // never settles

    const { result, state: updatedState } = await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev,
        runJevShadow,
      },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(updatedState?.jev?.action).toBe("route");
    expect(runJevShadow).toHaveBeenCalledTimes(1);
    expect(runJevShadow.mock.calls[0][0]).toBe("v2");
  });

  it("dual-call isolation: a shadow call that throws/rejects is swallowed (warn only), live turn unaffected", async () => {
    appendFileMock.mockClear();
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    const runJevShadow = vi.fn(async () => {
      throw new Error("boom");
    });

    const { result } = await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev,
        runJevShadow,
      },
    );
    expect(result.action).toBe("dispatch_to_agent");
    await flushMicrotasks();
    expect(warnSpy).toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it("a shadow-version failure row records reason + real hashes and honours storeState:false (MUS-3191 QA)", async () => {
    const EMPTY_OBJ_SHA = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";
    appendFileMock.mockClear();
    const runJev = vi.fn(async () => jevResult({
      off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
      resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
    }));
    const runJevShadow = vi.fn(async () => ({
      ok: false as const, reason: "http_502", httpStatus: 502, latencyMs: 5,
      state: { message: "SECRET-CUSTOMER-TEXT" }, questions: { q: 1 }, model: "jev-shadow",
    }));
    await handleWebhookEvent(
      makeUserPayload("where's my credit"), makeState(), "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"], shadow: { storeState: false } },
        runJev,
        runJevShadow,
      },
    );
    await vi.waitFor(() => expect(appendFileMock.mock.calls.length).toBeGreaterThanOrEqual(1));
    const rows = appendFileMock.mock.calls.map((c) => JSON.parse((c[1] as string).trim()));
    const row = rows.find((r) => r.questions_version === "v2")!;
    expect(row.state).toBeNull();
    expect(row.state_sha256).not.toBe(EMPTY_OBJ_SHA);
    expect(row.reason).toBe("http_502");
    expect(row.model).toBe("jev-shadow");
  });

  it("dual-call isolation: a shadow call resolving with a malformed/garbage outcome never throws out of handleWebhookEvent", async () => {
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    const runJevShadow = vi.fn(async () => ({ ok: true, answers: "not an answers object" }) as unknown as JevTurnOutcome);

    const { result } = await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev,
        runJevShadow,
      },
    );
    expect(result.action).toBe("dispatch_to_agent");
    await flushMicrotasks();
  });

  it("shadow row carries questions_version for the shadow variant, separate from the live row's version", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    const runJevShadow = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.7 } },
      }),
    );

    await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev,
        runJevShadow,
      },
    );
    await flushMicrotasks();

    expect(appendFileMock).toHaveBeenCalledTimes(2);
    const rows = appendFileMock.mock.calls.map(([, written]) => JSON.parse((written as string).trim()));
    const liveRow = rows.find((r) => r.actual === "route" && r.questions_version === "v1");
    const shadowRow = rows.find((r) => r.questions_version === "v2");
    expect(liveRow).toBeTruthy();
    expect(shadowRow).toBeTruthy();
  });

  it("shadow row carries state_variant from the shadow outcome; the live v1 row carries none", async () => {
    appendFileMock.mockClear();
    const state = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
      }),
    );
    const runJevShadow = vi.fn(async () => ({
      ...jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.7 } },
      }),
      stateVariant: "v2-policy-fallback",
    }));

    await handleWebhookEvent(
      makeUserPayload("where's my credit"), state, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev,
        runJevShadow,
      },
    );
    await flushMicrotasks();

    const rows = appendFileMock.mock.calls.map(([, written]) => JSON.parse((written as string).trim()));
    const liveRow = rows.find((r) => r.questions_version === "v1");
    const shadowRow = rows.find((r) => r.questions_version === "v2");
    expect(liveRow.state_variant).toBeNull();
    expect(shadowRow.state_variant).toBe("v2-policy-fallback");
  });

  // Isolation, per spec: a shadow call hanging or throwing must leave the
  // live v1 decision, its timing, and its result completely untouched — not
  // just "no exception escapes", but the SAME action/state.jev/log line as
  // if runJevShadow had never been wired at all.
  it("dual-call isolation: a hanging shadow call leaves the live v1 decision, its state.jev, and its dispatch result byte-identical", async () => {
    const baselineState = makeState();
    const isolatedState = makeState();
    const runJev = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
        intent: { type: "choice", choice: "credit_verification", probabilities: { credit_verification: 0.91 } },
      }),
    );

    const baseline = await handleWebhookEvent(
      makeUserPayload("where's my credit"), baselineState, "bot", undefined,
      { jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1" }, runJev },
    );

    const runJevIsolated = vi.fn(async () =>
      jevResult({
        off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
        resolution_path: { type: "choice", choice: "caroline_tool", probabilities: { caroline_tool: 0.85 } },
        intent: { type: "choice", choice: "credit_verification", probabilities: { credit_verification: 0.91 } },
      }),
    );
    const runJevShadow = vi.fn(() => new Promise<JevTurnOutcome>(() => {})); // never settles

    const isolated = await handleWebhookEvent(
      makeUserPayload("where's my credit"), isolatedState, "bot", undefined,
      {
        jev: { enabled: true, bands: JEV_BANDS, questionsVersion: "v1", shadowVersions: ["v2"] },
        runJev: runJevIsolated,
        runJevShadow,
      },
    );

    expect(isolated.result).toEqual(baseline.result);
    expect(isolated.state?.jev).toEqual(baseline.state?.jev);
    expect(runJevShadow).toHaveBeenCalledTimes(1);
  });
});

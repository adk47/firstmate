import { describe, it, expect, beforeEach } from "vitest";
import {
  parseConversationIdFromTarget,
  getOrCreateSession,
  accountSessions,
  joinDeliveryChunks,
} from "../src/channel.js";
import { canAgentReply } from "../src/handoff.js";

describe("parseConversationIdFromTarget", () => {
  it("extracts conversationId from full session key", () => {
    const target = "agent:support:intercom:ws_abc:conversation:conv_123";
    expect(parseConversationIdFromTarget(target)).toBe("conv_123");
  });

  it("extracts conversationId when conversation: appears multiple times", () => {
    const target = "conversation:nested:conversation:conv_456";
    expect(parseConversationIdFromTarget(target)).toBe("conv_456");
  });

  it("treats plain string as conversationId", () => {
    expect(parseConversationIdFromTarget("conv_789")).toBe("conv_789");
  });

  it("handles numeric conversationId", () => {
    expect(parseConversationIdFromTarget("12345")).toBe("12345");
  });

  it("returns null for empty string", () => {
    expect(parseConversationIdFromTarget("")).toBeNull();
  });

  it("returns null if conversation: prefix has empty value", () => {
    expect(parseConversationIdFromTarget("agent:support:conversation:")).toBeNull();
  });
});

describe("getOrCreateSession", () => {
  beforeEach(() => {
    accountSessions.clear();
  });

  it("creates a new session for a new conversation", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    expect(state.conversationId).toBe("conv_1");
    expect(state.workspaceId).toBe("ws_1");
    expect(state.handoffMode).toBe("agent_active");
    expect(state.lifecycleState).toBe("open");
  });

  it("returns the same session for the same accountId/conversationId", () => {
    const state1 = getOrCreateSession("acct_1", "conv_1", "ws_1");
    const state2 = getOrCreateSession("acct_1", "conv_1", "ws_1");
    expect(state1).toBe(state2);
  });

  it("creates separate sessions for different conversationIds", () => {
    const state1 = getOrCreateSession("acct_1", "conv_1", "ws_1");
    const state2 = getOrCreateSession("acct_1", "conv_2", "ws_1");
    expect(state1).not.toBe(state2);
    expect(state1.conversationId).toBe("conv_1");
    expect(state2.conversationId).toBe("conv_2");
  });

  it("creates separate sessions for different accountIds", () => {
    const state1 = getOrCreateSession("acct_1", "conv_1", "ws_1");
    const state2 = getOrCreateSession("acct_2", "conv_1", "ws_1");
    expect(state1).not.toBe(state2);
  });
});

describe("pre-send validation with session state", () => {
  beforeEach(() => {
    accountSessions.clear();
  });

  it("canAgentReply returns true for fresh session", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    expect(canAgentReply(state)).toBe(true);
  });

  it("canAgentReply returns false after human takeover", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    state.handoffMode = "human_takeover";
    expect(canAgentReply(state)).toBe(false);
  });

  it("canAgentReply returns false when conversation is closed", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    state.lifecycleState = "closed";
    expect(canAgentReply(state)).toBe(false);
  });

  it("canAgentReply returns false when conversation is snoozed", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    state.lifecycleState = "snoozed";
    expect(canAgentReply(state)).toBe(false);
  });

  it("session state persists mutations across lookups", () => {
    const state = getOrCreateSession("acct_1", "conv_1", "ws_1");
    state.handoffMode = "human_takeover";

    const sameLookup = getOrCreateSession("acct_1", "conv_1", "ws_1");
    expect(sameLookup.handoffMode).toBe("human_takeover");
    expect(canAgentReply(sameLookup)).toBe(false);
  });
});

describe("joinDeliveryChunks", () => {
  it("passes a single chunk through unchanged", () => {
    expect(joinDeliveryChunks(["Hello, world!"])).toBe("Hello, world!");
  });

  it("joins multiple chunks with double newlines (markdown paragraph break)", () => {
    expect(joinDeliveryChunks(["Para one.", "Para two.", "Para three."])).toBe(
      "Para one.\n\nPara two.\n\nPara three.",
    );
  });

  it("drops empty and whitespace-only chunks", () => {
    expect(joinDeliveryChunks(["", "Hello", "  ", "\n", "World"])).toBe(
      "Hello\n\nWorld",
    );
  });

  it("trims trailing whitespace on each chunk", () => {
    expect(joinDeliveryChunks(["First line.   ", "Second line.\n"])).toBe(
      "First line.\n\nSecond line.",
    );
  });

  it("returns empty string for empty input", () => {
    expect(joinDeliveryChunks([])).toBe("");
  });

  it("returns empty string when all chunks are blank", () => {
    expect(joinDeliveryChunks(["", "  ", "\n\n"])).toBe("");
  });

  it("does not collapse internal whitespace within a chunk", () => {
    // Preserve markdown structure inside each chunk — only trailing
    // whitespace is stripped, not internal formatting.
    expect(joinDeliveryChunks(["Line 1\n  indented", "Line 2"])).toBe(
      "Line 1\n  indented\n\nLine 2",
    );
  });
});

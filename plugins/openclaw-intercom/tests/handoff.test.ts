import { describe, it, expect } from "vitest";
import {
  createInitialSessionState,
  handleAssignment,
  handleAdminReply,
  handleLifecycleChange,
  handleImplicitReopen,
  canAgentReply,
} from "../src/handoff.js";

const BOT_ADMIN_ID = "bot_admin_1";

describe("createInitialSessionState", () => {
  it("creates state with agent_active and open", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    expect(state.handoffMode).toBe("agent_active");
    expect(state.lifecycleState).toBe("open");
    expect(state.conversationId).toBe("conv_1");
    expect(state.workspaceId).toBe("ws_1");
    expect(state.processedEventIds).toEqual([]);
    expect(state.outboundMessageIds).toEqual([]);
  });
});

describe("handleAssignment", () => {
  it("transitions to human_takeover when assigned to non-bot admin", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleAssignment(state, "human_admin_42", BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("human_takeover");
    expect(state.currentAssigneeId).toBe("human_admin_42");
  });

  it("transitions to agent_active when assigned to bot admin", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.handoffMode = "human_takeover";
    handleAssignment(state, BOT_ADMIN_ID, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("agent_active");
  });

  it("stays agent_active when reassigned to bot admin", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleAssignment(state, BOT_ADMIN_ID, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("agent_active");
  });
});

describe("handleAdminReply", () => {
  it("transitions to human_takeover on non-bot admin reply", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleAdminReply(state, "human_admin_42", BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("human_takeover");
  });

  it("does NOT change state on bot admin reply", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleAdminReply(state, BOT_ADMIN_ID, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("agent_active");
  });
});

describe("handleLifecycleChange", () => {
  it("sets lifecycleState to closed", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleLifecycleChange(state, "closed");
    expect(state.lifecycleState).toBe("closed");
  });

  it("sets lifecycleState to snoozed", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    handleLifecycleChange(state, "snoozed");
    expect(state.lifecycleState).toBe("snoozed");
  });

  it("sets lifecycleState to open on reopen", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "closed";
    handleLifecycleChange(state, "open");
    expect(state.lifecycleState).toBe("open");
  });
});

describe("handleImplicitReopen", () => {
  it("transitions closed to open when customer replies", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "closed";
    handleImplicitReopen(state, BOT_ADMIN_ID);
    expect(state.lifecycleState).toBe("open");
  });

  it("restores agent_active when assigned to bot on reopen", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "closed";
    state.currentAssigneeId = BOT_ADMIN_ID;
    handleImplicitReopen(state, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("agent_active");
  });

  it("keeps human_takeover when assigned to human on reopen", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "closed";
    state.currentAssigneeId = "human_admin_42";
    handleImplicitReopen(state, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("human_takeover");
  });

  it("does nothing if already open", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.handoffMode = "human_takeover";
    handleImplicitReopen(state, BOT_ADMIN_ID);
    expect(state.handoffMode).toBe("human_takeover");
    expect(state.lifecycleState).toBe("open");
  });

  it("does NOT implicitly reopen snoozed conversations", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "snoozed";
    handleImplicitReopen(state, BOT_ADMIN_ID);
    expect(state.lifecycleState).toBe("snoozed");
  });
});

describe("canAgentReply", () => {
  it("returns true when agent_active and open", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    expect(canAgentReply(state)).toBe(true);
  });

  it("returns false when human_takeover", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.handoffMode = "human_takeover";
    expect(canAgentReply(state)).toBe(false);
  });

  it("returns false when closed", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "closed";
    expect(canAgentReply(state)).toBe(false);
  });

  it("returns false when snoozed", () => {
    const state = createInitialSessionState("conv_1", "ws_1");
    state.lifecycleState = "snoozed";
    expect(canAgentReply(state)).toBe(false);
  });
});

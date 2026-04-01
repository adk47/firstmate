import type { IntercomSessionState, LifecycleState } from "./types.js";

export function createInitialSessionState(
  conversationId: string,
  workspaceId: string,
): IntercomSessionState {
  const now = new Date().toISOString();
  return {
    conversationId,
    workspaceId,
    handoffMode: "agent_active",
    lifecycleState: "open",
    currentAssigneeId: null,
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: now,
    updatedAt: now,
  };
}

export function handleAssignment(
  state: IntercomSessionState,
  assigneeId: string,
  botAdminId: string,
): void {
  state.currentAssigneeId = assigneeId;
  state.handoffMode = assigneeId === botAdminId ? "agent_active" : "human_takeover";
  state.updatedAt = new Date().toISOString();
}

export function handleAdminReply(
  state: IntercomSessionState,
  adminId: string,
  botAdminId: string,
): void {
  if (adminId !== botAdminId) {
    state.handoffMode = "human_takeover";
    state.updatedAt = new Date().toISOString();
  }
}

export function handleLifecycleChange(
  state: IntercomSessionState,
  newState: LifecycleState,
): void {
  state.lifecycleState = newState;
  state.updatedAt = new Date().toISOString();
}

export function handleImplicitReopen(
  state: IntercomSessionState,
  botAdminId: string,
): void {
  if (state.lifecycleState !== "closed") return;

  state.lifecycleState = "open";
  state.handoffMode =
    state.currentAssigneeId && state.currentAssigneeId !== botAdminId
      ? "human_takeover"
      : "agent_active";
  state.updatedAt = new Date().toISOString();
}

export function canAgentReply(state: IntercomSessionState): boolean {
  return state.handoffMode === "agent_active" && state.lifecycleState === "open";
}

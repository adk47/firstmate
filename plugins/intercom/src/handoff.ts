import type { IntercomSessionState, LifecycleState, AssigneeType } from "./types.js";

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
    currentAssigneeType: null,
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: now,
    updatedAt: now,
  };
}

const KNOWN_ASSIGNEE_TYPES: ReadonlySet<string> = new Set(["admin", "bot", "nobody_admin"]);

function isHumanAdmin(assigneeType: AssigneeType, assigneeId: string, botAdminId: string): boolean {
  if (assigneeId === botAdminId) return false;
  if (!KNOWN_ASSIGNEE_TYPES.has(assigneeType)) {
    console.warn(`[intercom:handoff] unexpected assignee type="${assigneeType}" for id=${assigneeId}`);
  }
  return assigneeType === "admin";
}

export function handleAssignment(
  state: IntercomSessionState,
  assigneeId: string,
  assigneeType: AssigneeType,
  botAdminId: string,
): void {
  state.currentAssigneeId = assigneeId;
  state.currentAssigneeType = assigneeType;
  state.handoffMode = isHumanAdmin(assigneeType, assigneeId, botAdminId) ? "human_takeover" : "agent_active";
  state.updatedAt = new Date().toISOString();
}

export function handleAdminReply(
  state: IntercomSessionState,
  adminId: string,
  adminType: AssigneeType,
  botAdminId: string,
): void {
  if (isHumanAdmin(adminType, adminId, botAdminId)) {
    state.handoffMode = "human_takeover";
    state.currentAssigneeId = adminId;
    state.currentAssigneeType = adminType;
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
    state.currentAssigneeId && isHumanAdmin(state.currentAssigneeType ?? "bot", state.currentAssigneeId, botAdminId)
      ? "human_takeover"
      : "agent_active";
  state.updatedAt = new Date().toISOString();
}

export function canAgentReply(state: IntercomSessionState): boolean {
  return state.handoffMode === "agent_active" && state.lifecycleState === "open";
}

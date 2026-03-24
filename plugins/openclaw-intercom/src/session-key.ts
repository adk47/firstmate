const MAX_ID_LENGTH = 256;

export function buildSessionKey(workspaceId: string, conversationId: string): string {
  if (!workspaceId) throw new Error("workspaceId is required");
  if (!conversationId) throw new Error("conversationId is required");
  if (conversationId.length > MAX_ID_LENGTH) throw new Error("conversationId exceeds max length");
  if (workspaceId.length > MAX_ID_LENGTH) throw new Error("workspaceId exceeds max length");
  return `agent:support:intercom:${workspaceId}:conversation:${conversationId}`;
}

import { unmarkCvSession } from "../state.js";

/** Local mirrors of openclaw's session hook types — structural compatibility
 *  verified at the `api.on<"session_end">` registration in index.ts. */
type SessionEndEvent = {
  sessionId: string;
  sessionKey?: string;
  messageCount: number;
  durationMs?: number;
  reason?: string;
  sessionFile?: string;
};

type SessionContext = {
  agentId?: string;
  sessionId: string;
  sessionKey?: string;
};

/** Idempotent cleanup: clear the CV mark on session end. Safe for non-CV
 *  sessions (unmark is a no-op on missing keys). */
export function cleanupSessionState(_event: SessionEndEvent, ctx: SessionContext): void {
  if (!ctx.sessionKey) return;
  unmarkCvSession(ctx.sessionKey);
}

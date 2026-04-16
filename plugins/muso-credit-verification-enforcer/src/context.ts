import { cvSessions } from "./state.js";

/** True if this session/run is part of a credit-verification flow.
 *
 *  The real openclaw Plugin SDK does NOT expose `channelId` on tool-call or
 *  session contexts (only on message/inbound contexts). So we can't detect CV
 *  from tool hooks directly. Instead:
 *
 *  - The `inbound_claim` hook marks a sessionKey as CV when it first sees a
 *    message on the CV channel. Tool hooks then check `cvSessions`.
 *  - Batch mode (the heartbeat cron) sets `runId` on the tool context; we
 *    treat any run with `runId` as CV (the batch skill only runs in CV flows).
 */
export function isCreditVerificationSession(
  sessionKey: string | undefined,
  runId: string | undefined,
): boolean {
  if (sessionKey && cvSessions.has(sessionKey)) return true;
  if (runId) return true;
  return false;
}

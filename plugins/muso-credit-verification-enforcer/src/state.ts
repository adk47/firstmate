/** Set of sessionKeys identified as credit-verification sessions.
 *  Populated by the `inbound_claim` hook when a message arrives on the CV
 *  channel; consulted by `before_tool_call` handlers (which don't see
 *  channelId on their context) to decide whether to fire CV-specific logic
 *  (currently just `block-unsanctioned-batch-message`).
 *
 *  The heavier evidence-tracking / gate state that used to live here was
 *  removed when the gate moved into `muso-admin-api.sh` at the bash layer —
 *  openclaw's `before_tool_call` hook doesn't fire reliably on autonomous
 *  exec in YOLO mode, so plugin-level gating was never going to work.
 *
 *  The browser-forcing hooks (redirect-web-search, block-web-fetch-tier1,
 *  block-escalation-without-browse) were removed 2026-05-06 when CV cut over
 *  from browser-only Tier-1 evidence to API helpers. The bash gate enforces
 *  evidence quorum under CV_EVIDENCE_MODE=api (default). */
export const cvSessions = new Set<string>();

export function markCvSession(sessionKey: string): void {
  cvSessions.add(sessionKey);
}

export function unmarkCvSession(sessionKey: string): void {
  cvSessions.delete(sessionKey);
}

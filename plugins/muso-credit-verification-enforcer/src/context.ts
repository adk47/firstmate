import { cvSessions } from "./state.js";

/** Agent IDs whose entire workspace is credit-verification scoped. Any tool
 *  call from these agents is treated as CV context regardless of sessionKey
 *  or runId. Broadened from the old sessionKey/runId-only rule after live
 *  testing (issue #152) showed the narrow scope produced silent misses:
 *  @-mention flows into #credit-verification don't re-trigger inbound_claim
 *  against the in-memory cvSessions Set, and runId only gets set on cron
 *  batch runs — so web_fetch-to-Tier-1 calls from @-mention runs slipped
 *  past the block-web-fetch-tier1 hook entirely. The narrow scope was the
 *  failure mode; workspace-level gating is safer. */
const CV_AGENTS = new Set(["operations", "operations-dev"]);

/** True if this session/run is part of a credit-verification flow.
 *
 *  The real openclaw Plugin SDK does NOT expose `channelId` on tool-call or
 *  session contexts (only on message/inbound contexts). So we can't detect CV
 *  from tool hooks directly. Instead:
 *
 *  - `agentId` is "operations" / "operations-dev" for the credit-verification
 *    workspace — any tool call from those agents is CV context.
 *  - The `inbound_claim` hook marks a sessionKey as CV when it first sees a
 *    message on the CV channel. Tool hooks then check `cvSessions` — useful
 *    when agentId is absent on the context (e.g. legacy paths).
 *  - Batch mode (the heartbeat cron) sets `runId` on the tool context; we
 *    treat any run with `runId` as CV (the batch skill only runs in CV flows).
 */
export function isCreditVerificationSession(
  sessionKey: string | undefined,
  runId: string | undefined,
  agentId?: string | undefined,
): boolean {
  if (agentId && CV_AGENTS.has(agentId)) return true;
  if (sessionKey && cvSessions.has(sessionKey)) return true;
  if (runId) return true;
  return false;
}

import { isCreditVerificationSession } from "../context.js";

/** Local mirror of openclaw's `PluginHookBeforeToolCallEvent`. */
type BeforeToolCallEvent = {
  toolName: string;
  params: Record<string, unknown>;
  runId?: string;
  toolCallId?: string;
};

type ToolContext = {
  agentId?: string;
  sessionKey?: string;
  sessionId?: string;
  runId?: string;
  toolName: string;
  toolCallId?: string;
};

type BeforeToolCallResult = {
  params?: Record<string, unknown>;
  block?: boolean;
  blockReason?: string;
};

/**
 * Block hand-composed batch-summary Slack posts that bypass the sanctioned
 * `post-batch-summary.sh` path.
 *
 * The 2026-04-28 15:13 / 15:26 UTC dry-runs showed gpt-5.5 posting
 * "Queue fetch succeeded — no writes were executed" after only running
 * B0+B1, never reaching B6. SKILL.md prose ("Proceed directly to B2",
 * "do NOT post any Slack summary at this point") did NOT change behavior
 * — the model reused its cached bash template. Per memory
 * feedback_llm_instruction_insufficient, prose is insufficient.
 *
 * This hook is the outer mechanical gate. Combined with post-batch-summary.sh
 * (the sanctioned positive path that bypasses the MCP `message` tool by
 * posting directly via the openclaw CLI), it forces every batch summary
 * post through the truth-floor renderer.
 *
 * The hook fires only in CV context (operations agent, or sessions marked
 * via the inbound_claim hook). It blocks `message` /
 * `slack_message` / `send_message` tool calls to the prod or dry-run CV
 * channel only when the text is summary-shaped: `[HEARTBEAT-BATCH]`,
 * `Credit batch complete`, `[DRY RUN] Credit batch complete`, or known
 * B1 hollow-bail prose such as "Queue fetch succeeded" / "no writes were
 * executed".
 *
 * Legitimate operational CV messages still pass through, including aborts,
 * admin API/envelope drift alerts, runaway batch alerts, error storms, and
 * per-credit escalations. Those are not batch summaries and remain part of
 * the workflow.
 *
 * Fail-OPEN: any error detecting context returns undefined (no block). The
 * lockfile.sh emit_renderer_missing_event_if_needed detector still catches
 * bypasses post-hoc.
 */

/** Slack channel IDs we want to police. The prod default ("C0APB2CMM7C")
 *  is hardcoded as a safety net for hosts where the env var is unset; the
 *  dry-run channel is read from env at hook time. */
const PROD_CV_CHANNEL_DEFAULT = "C0APB2CMM7C";

const SUMMARY_SHAPE_PATTERNS: RegExp[] = [
  /^\s*(?:\[DRY RUN\]\s*)?\[HEARTBEAT-BATCH\]/im,
  /^\s*(?:\[DRY RUN\]\s*)?Credit batch complete\b/im,
  /Queue fetch succeeded/i,
  /no writes were executed/i,
];

/** Allowlisted operational templates. Some abort templates include the
 *  `[HEARTBEAT-BATCH]` marker for human scanning, but they are not batch
 *  summaries and should remain sendable through the MCP message tool. */
const OPERATIONAL_ALLOWLIST: RegExp[] = [
  // B0d preflight abort (per SKILL.md ~line 894-901)
  /Batch aborted at pre-flight/i,
  // B0d.5 Tier-1 contamination abort (per SKILL.md ~line 921-924)
  /Batch aborted at B0d\.5/i,
  // B1 shape-drift / silent-zero escalation (per SKILL.md B1 RC=5/6/11)
  /admin API envelope drift|silent-zero/i,
  // B1 API-error abort (RC=2/3/4)
  /API error fetching unverified queue/i,
  // B2 runaway rail
  /Runaway batch/i,
  // B2 error-storm escalation
  /Error storm/i,
  // Per-credit escalation posts
  /ESCALATION\s+—|ESCALATION\s+-|please review\. Reply "approve" or "reject/i,
];

const BLOCK_REASON =
  "Hand-composed [HEARTBEAT-BATCH] / 'Credit batch complete' messages to\n" +
  "#credit-verification are blocked. The sanctioned path is:\n\n" +
  "  1. Run `bash scripts/compute-run-summary.sh --final \"$RUN_ID\" \"\"` (B6)\n" +
  "  2. Run `bash scripts/post-batch-summary.sh \"$RUN_ID\"` (B3 — posts parent + thread)\n\n" +
  "post-batch-summary.sh reads the runlog truth floor, refuses on\n" +
  "in-flight shapes (queue_depth>0 + action_attempted=0), composes the\n" +
  "message via render-slack-summary.sh, and posts via the openclaw CLI\n" +
  "directly. Hand-composed posts are the failure mode this gate exists\n" +
  "to prevent (2026-04-28 15:13/15:26 UTC dry-runs).\n\n" +
  "If you DO need a non-summary message in this channel (e.g. a preflight\n" +
  "abort, runaway alert, error storm, or escalation), the allowlist already\n" +
  "covers the operational templates. Batch summaries must always go through\n" +
  "post-batch-summary.sh, even after run_finished.";

const MESSAGE_TOOL_NAMES = new Set([
  "message",
  "slack_message",
  "send_message",
]);

/** Extract the target channel id and message text from a tool-call's
 *  params. Different openclaw versions / channels surface these under
 *  slightly different keys; try the most common ones. */
function extractTargetAndText(
  params: Record<string, unknown>,
): { target: string | undefined; text: string | undefined } {
  const target =
    (typeof params.channelId === "string" ? params.channelId : undefined) ??
    (typeof params.target === "string" ? params.target : undefined) ??
    (typeof params.chat_id === "string" ? params.chat_id : undefined) ??
    (typeof params.to === "string" ? params.to : undefined);
  const text =
    (typeof params.text === "string" ? params.text : undefined) ??
    (typeof params.body === "string" ? params.body : undefined) ??
    (typeof params.message === "string" ? params.message : undefined) ??
    (typeof params.markdown === "string" ? params.markdown : undefined);
  return { target, text };
}

/** True if the target channel id matches the credit-verification prod or
 *  dry-run channel. Reads dry-run channel from env at call time so plugin
 *  reload isn't required when env changes. */
function isCvChannel(target: string | undefined): boolean {
  if (!target) return false;
  const prod =
    process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID || PROD_CV_CHANNEL_DEFAULT;
  const dryRun = process.env.OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID || "";
  return target === prod || (dryRun !== "" && target === dryRun);
}

function isOperationalMessage(text: string): boolean {
  for (const re of OPERATIONAL_ALLOWLIST) {
    if (re.test(text)) return true;
  }
  return false;
}

function isSummaryShaped(text: string): boolean {
  return SUMMARY_SHAPE_PATTERNS.some((re) => re.test(text));
}

export function blockUnsanctionedBatchMessage(
  event: BeforeToolCallEvent,
  ctx: ToolContext,
): BeforeToolCallResult | undefined {
  if (!MESSAGE_TOOL_NAMES.has(event.toolName)) return undefined;
  if (!isCreditVerificationSession(ctx.sessionKey, ctx.runId, ctx.agentId)) {
    return undefined;
  }

  const { target, text } = extractTargetAndText(event.params ?? {});

  // No text — nothing to police. Treat as pass-through (e.g. a reaction
  // tool call coming through the same hook bus).
  if (typeof text !== "string" || text.length === 0) return undefined;

  if (isOperationalMessage(text)) return undefined;

  // 2026-04-30 fail-closed widening (run 20260430-081740-585500 leaked):
  // when the agent posts with target="" / undefined, openclaw resolves it
  // downstream to the operations agent's default Slack channel — which IS
  // the CV channel. The hook never sees that resolution. Result: a blank
  // target slipped through because the prior `if (!isCvChannel(target))
  // return undefined` short-circuited.
  //
  // For CV-context summary-shaped posts, target resolution is irrelevant.
  // The operations workspace has zero legitimate paths that hand-compose
  // a `[HEARTBEAT-BATCH]` / `Credit batch complete` message via the MCP
  // message tool — `post-batch-summary.sh` posts via the openclaw CLI,
  // bypassing this hook entirely. So: if the message is summary-shaped
  // and we're in CV context, BLOCK regardless of target. Non-summary
  // messages (operational allowlist, ad-hoc replies) still need a CV
  // channel target to qualify for blocking — those are pass-through.
  const summaryShaped = isSummaryShaped(text);
  if (!summaryShaped && !isCvChannel(target)) return undefined;
  if (!summaryShaped) return undefined;

  console.warn(
    `[credit-verification-enforcer] blocked unsanctioned ${event.toolName} to CV channel target=${target ?? "(empty)"} agent=${ctx.agentId ?? "?"} session=${ctx.sessionKey ?? "?"} runId=${ctx.runId ?? "?"} text="${text.slice(0, 80)}…"`,
  );

  return { block: true, blockReason: BLOCK_REASON };
}

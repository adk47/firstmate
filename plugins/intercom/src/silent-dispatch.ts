import { canAgentReply } from "./handoff.js";
import type {
  IntercomAccountConfig,
  IntercomSessionState,
} from "./types.js";
import type { SlackMessagePayload } from "./slack.js";

export type SilentDispatchReason =
  | "zero_chunks_after_dispatch"
  | "dispatch_threw"
  // The dispatch await never settled within the plugin's timeout. This is the
  // upstream lane-wedge (openclaw #97538 / #92270): rapid-fire inbound spawns
  // overlapping embedded_run dispatches on one lane; one leaks the lane owner
  // lock; later dispatches wedge at embedded_run:started; stuck-session recovery
  // aborts them but logs released=0 (never frees the lane) and DISCARDS the
  // generated reply. Because the await never returns, neither the reply flush
  // nor the zero_chunks silent-dispatch check below is ever reached — so without
  // this bounded timeout the customer waits forever and NOTHING alarms.
  | "dispatch_timed_out";

export interface SilentDispatchDetectionInput {
  bufferedChunks: string[];
  state: IntercomSessionState;
  droppedMidStream: boolean;
}

export type SilentDispatchDetection =
  | { silent: false }
  | { silent: true; reason: SilentDispatchReason };

/**
 * Detect dispatches that returned without producing customer-facing output
 * AND can't be explained by an intentional state flip (human takeover, conv
 * closed) or by the explicit drop-mid-stream branch in channel.ts.
 *
 * These are the silent failures behind hydra issue #280: agent invocation
 * completed, no chunks landed, no error logged. The plugin would otherwise
 * skip the final flush in channel.ts and the customer waits forever.
 */
export function detectSilentDispatch(
  input: SilentDispatchDetectionInput,
): SilentDispatchDetection {
  if (input.bufferedChunks.length > 0) return { silent: false };
  if (input.droppedMidStream) return { silent: false };
  if (!canAgentReply(input.state)) return { silent: false };
  return { silent: true, reason: "zero_chunks_after_dispatch" };
}

export interface SilentDispatchSlackInput {
  conversationId: string;
  reason: SilentDispatchReason;
  errorMessage?: string;
  account: IntercomAccountConfig;
}

function intercomUrl(workspaceId: string, conversationId: string): string {
  return `https://app.intercom.com/a/inbox/${workspaceId}/inbox/conversation/${conversationId}`;
}

// Reason-specific "what happened" line for the Slack context block. The generic
// header/reason code is the same across reasons; this explains the failure and
// what the human should do so #cs-escalations gets an actionable page.
function reasonContext(reason: SilentDispatchReason, workspaceId: string): string {
  const ws = `workspace: \`${workspaceId}\``;
  switch (reason) {
    case "dispatch_timed_out":
      return (
        `Agent dispatch did not return within the timeout — the session lane is likely ` +
        `wedged (upstream openclaw #97538). No reply was posted and none will be; ` +
        `please pick this conversation up. ${ws}`
      );
    case "dispatch_threw":
      return `Agent dispatch threw before producing a reply. ${ws}`;
    case "zero_chunks_after_dispatch":
    default:
      return `Customer wrote, agent invoked, no chunks landed. ${ws}`;
  }
}

export function buildSilentDispatchSlackPayload(
  input: SilentDispatchSlackInput,
): SlackMessagePayload {
  const url = intercomUrl(input.account.workspaceId, input.conversationId);
  const errSnippet = input.errorMessage
    ? input.errorMessage.slice(0, 200)
    : null;

  const fields: { type: "mrkdwn"; text: string }[] = [
    { type: "mrkdwn", text: `*Conversation:*\n<${url}|#${input.conversationId}>` },
    { type: "mrkdwn", text: `*Reason:*\n\`${input.reason}\`` },
  ];
  if (errSnippet) {
    fields.push({ type: "mrkdwn", text: `*Error:*\n\`${errSnippet}\`` });
  }

  return {
    text:
      `:rotating_light: Intercom silent dispatch — conv ${input.conversationId} ` +
      `(${input.reason}) — <${url}|View>`,
    blocks: [
      {
        type: "header",
        text: {
          type: "plain_text",
          text: "🚨 Intercom silent dispatch",
          emoji: true,
        },
      },
      { type: "section", fields },
      {
        type: "actions",
        elements: [
          {
            type: "button",
            text: { type: "plain_text", text: "View in Intercom" },
            url,
          },
        ],
      },
      {
        type: "context",
        elements: [
          {
            type: "mrkdwn",
            text: reasonContext(input.reason, input.account.workspaceId),
          },
        ],
      },
    ],
  };
}

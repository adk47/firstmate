import { canAgentReply } from "./handoff.js";
import type {
  IntercomAccountConfig,
  IntercomSessionState,
} from "./types.js";
import type { SlackMessagePayload } from "./slack.js";

export type SilentDispatchReason =
  | "zero_chunks_after_dispatch"
  | "dispatch_threw";

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
            text:
              `Customer wrote, agent invoked, no chunks landed. ` +
              `workspace: \`${input.account.workspaceId}\``,
          },
        ],
      },
    ],
  };
}

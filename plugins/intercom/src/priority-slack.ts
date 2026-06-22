import { intercomDeeplink } from "./ticket-format.js";

/**
 * Slack payload for the fast priority page (Lane A). Posted to the priority
 * channel via an incoming webhook, @-tagging the boss so a customer data
 * complaint reaches the top of the team in seconds.
 *
 * SECURITY: `reason` and `customerMessage` are UNTRUSTED — `reason` is
 * model-generated and may echo customer text, `customerMessage` is the raw
 * customer body. Both are escaped at the Slack mrkdwn boundary so a customer
 * cannot inject `<!channel>` / `<@U...>` / fake links into the page. The
 * mention string is built from config-supplied user IDs (trusted) and is NOT
 * escaped, so the @-mention still renders and notifies. See memory
 * reference_slack_injection_untrusted_clickup_names.
 */

const SNIPPET_MAX = 280;

/**
 * Escape text for a Slack mrkdwn sink. `&` MUST be replaced first so the `<`
 * and `>` replacements are not double-escaped. After this, Slack control
 * sequences in customer text render as literal characters, never as pings or
 * links.
 */
export function escapeSlackMrkdwn(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function buildMention(mentionUserIds: string[]): string {
  // User IDs come from account config (trusted). Render each as a real mention.
  return mentionUserIds
    .filter((id) => typeof id === "string" && /^[A-Z0-9]+$/i.test(id))
    .map((id) => `<@${id}>`)
    .join(" ");
}

export interface PrioritySlackArgs {
  conversationId: string;
  reason: string | null;
  customerEmail: string | null;
  customerMessage: string;
  workspaceId: string;
  mentionUserIds: string[];
  // When true, label the page as a backstop catch (used only by the Lane B
  // watchdog payload, not the inline path). Inline pages omit it.
  viaBackstop?: boolean;
}

export function buildPrioritySlackPayload(args: PrioritySlackArgs): { text: string; blocks: unknown[] } {
  const { conversationId, reason, customerEmail, customerMessage, workspaceId, mentionUserIds } = args;
  const url = intercomDeeplink(workspaceId, conversationId);
  const mention = buildMention(mentionUserIds);

  const safeReason = reason ? escapeSlackMrkdwn(reason) : "_customer data complaint_";
  const trimmedMsg =
    customerMessage.length > SNIPPET_MAX ? `${customerMessage.slice(0, SNIPPET_MAX)}…` : customerMessage;
  const safeMsg = escapeSlackMrkdwn(trimmedMsg) || "_(no message text)_";
  const safeEmail = customerEmail ? escapeSlackMrkdwn(customerEmail) : "unknown";

  const headerText = "🚨 Priority — customer data complaint";
  const lead = mention ? `${mention} ` : "";

  return {
    // The top-level `text` is the notification preview; lead with the mention
    // so the push notification itself names who is being paged.
    text: `${lead}🚨 Priority data complaint — <${url}|view in Intercom>`,
    blocks: [
      {
        type: "header",
        text: { type: "plain_text", text: headerText, emoji: true },
      },
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text:
            `${lead}a customer is complaining about a data issue — flagging straight to you.\n` +
            `*What:* ${safeReason}\n` +
            `*Customer:* ${safeEmail}\n` +
            `*Their message:* ${safeMsg}`,
        },
      },
      {
        type: "actions",
        elements: [
          { type: "button", text: { type: "plain_text", text: "Open conversation" }, url },
        ],
      },
    ],
  };
}

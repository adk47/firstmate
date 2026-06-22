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
  // Verified customer name, when known (enrichment). Rendered alongside the
  // email so the page names who complained without anyone opening the thread.
  customerName?: string | null;
  customerMessage: string;
  workspaceId: string;
  mentionUserIds: string[];
}

/**
 * Render the customer identity line. Prefer `email (name)` when both are known,
 * fall back to whichever is present, else a nudge to open the thread. Both
 * fields are untrusted (a customer controls their Intercom name/email), so each
 * is escaped at the Slack boundary.
 */
function buildCustomerIdentity(email: string | null, name: string | null | undefined): string {
  const safeEmail = email ? escapeSlackMrkdwn(email) : "";
  const safeName = name ? escapeSlackMrkdwn(name) : "";
  if (safeEmail && safeName) return `${safeEmail} (${safeName})`;
  return safeEmail || safeName || "_unknown — open the conversation_";
}

export function buildPrioritySlackPayload(args: PrioritySlackArgs): { text: string; blocks: unknown[] } {
  const { conversationId, reason, customerEmail, customerName, customerMessage, workspaceId, mentionUserIds } = args;
  const url = intercomDeeplink(workspaceId, conversationId);
  const mention = buildMention(mentionUserIds);

  const safeReason = reason ? escapeSlackMrkdwn(reason) : "_customer data complaint_";
  const trimmedMsg =
    customerMessage.length > SNIPPET_MAX ? `${customerMessage.slice(0, SNIPPET_MAX)}…` : customerMessage;
  const safeMsg = escapeSlackMrkdwn(trimmedMsg) || "_(no message text)_";
  const identity = buildCustomerIdentity(customerEmail, customerName);

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
          // The deeplink is a MARKDOWN LINK, not a Block Kit action button:
          // action buttons require app interactivity and Slack consumes them
          // after one click ("selected by @user"), making the link single-use.
          // A markdown link is pure navigation — every teammate can open it,
          // every time. Mirrors the Lane B watchdog page.
          text:
            `${lead}— flagging straight to you.\n` +
            `*Issue:* ${safeReason}\n` +
            `*Customer:* ${identity}\n` +
            `*They said:* ${safeMsg}\n` +
            `<${url}|Open in Intercom →>`,
        },
      },
      {
        // Lightweight claim convention (replaces the old button's accidental
        // "selected by @user" signal): whoever picks it up reacts ✅.
        type: "context",
        elements: [
          { type: "mrkdwn", text: "✅ react when you've got it" },
        ],
      },
    ],
  };
}

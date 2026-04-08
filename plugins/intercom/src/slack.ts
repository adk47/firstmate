import type {
  IntercomAccountConfig,
  IntercomConversation,
  IntercomSessionState,
} from "./types.js";

export interface EscalationSummary {
  conversationId: string;
  category: string;
  matchedPattern: string;
  body: string;
}

export interface SlackMessagePayload {
  text: string;
  blocks: unknown[];
}

const SNIPPET_MAX = 500;

export function formatRelativeTime(unixSeconds: number, now: number = Date.now()): string {
  if (!unixSeconds || !Number.isFinite(unixSeconds)) return "unknown";
  const deltaSec = Math.max(0, Math.floor(now / 1000 - unixSeconds));
  if (deltaSec < 60) return `${deltaSec}s ago`;
  const mins = Math.floor(deltaSec / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}mo ago`;
  const years = Math.floor(days / 365);
  return `${years}y ago`;
}

function describeAssignee(conversation: IntercomConversation): string {
  // API v2.11 GET /conversations/{id} uses admin_assignee_id; webhook
  // payloads use the `assignee` object. Prefer the API field so
  // escalation cards (built from getConversation responses) don't
  // always show "Unassigned".
  if (conversation.admin_assignee_id != null) {
    return `admin:${conversation.admin_assignee_id}`;
  }
  const assignee = conversation.assignee;
  if (!assignee || assignee.type === "nobody_admin") return "Unassigned";
  if (assignee.type === "bot") return `Bot${assignee.name ? ` (${assignee.name})` : ""}`;
  return assignee.name ? `${assignee.name}` : `admin:${assignee.id}`;
}

function describeUser(conversation: IntercomConversation): string {
  const author = conversation.source?.author;
  if (!author) return "_unknown user_";
  const name = author.name?.trim();
  const email = author.email?.trim();
  if (name && email) return `${name} <${email}>`;
  if (name) return name;
  if (email) return email;
  return `${author.type}:${author.id}`;
}

function countMessages(conversation: IntercomConversation): number {
  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  // +1 for the source message itself
  return (conversation.source ? 1 : 0) + parts.length;
}

function quoteSnippet(body: string): string {
  const trimmed = body.length > SNIPPET_MAX ? `${body.slice(0, SNIPPET_MAX)}…` : body;
  // Prefix each line with "> " so Slack renders it as a quote block.
  return trimmed
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n");
}

function intercomUrl(account: IntercomAccountConfig, conversationId: string): string {
  return `https://app.intercom.com/a/inbox/${account.workspaceId}/inbox/conversation/${conversationId}`;
}

/**
 * Build the minimal fallback Slack payload used when we fail to fetch the
 * full conversation. Intentionally equivalent to the pre-enrichment format
 * so escalation is never blocked on an API hiccup.
 */
export function buildEscalationSlackMessageMinimal(
  escalation: EscalationSummary,
  account: IntercomAccountConfig,
): SlackMessagePayload {
  const url = intercomUrl(account, escalation.conversationId);
  return {
    text: `🚨 Intercom escalation: ${escalation.category} — <${url}|View conversation>`,
    blocks: [
      {
        type: "section",
        text: {
          type: "mrkdwn",
          text:
            `🚨 *Intercom Escalation*\n` +
            `*Category:* ${escalation.category}\n` +
            `*Pattern:* \`${escalation.matchedPattern}\`\n` +
            `*Message:* ${escalation.body.slice(0, 200)}${escalation.body.length > 200 ? "…" : ""}`,
        },
      },
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
    ],
  };
}

/**
 * Build an enriched Slack payload using data from a fetched IntercomConversation.
 * Adds user info, assignee, state, age, and message count to help a human
 * triage the escalation without clicking through to Intercom.
 */
export function buildEscalationSlackMessage(
  escalation: EscalationSummary,
  conversation: IntercomConversation,
  account: IntercomAccountConfig,
  state: IntercomSessionState | null,
  now: number = Date.now(),
): SlackMessagePayload {
  const url = intercomUrl(account, escalation.conversationId);
  const user = describeUser(conversation);
  const assignee = describeAssignee(conversation);
  const convState = conversation.state ?? (conversation.open ? "open" : "unknown");
  const started = formatRelativeTime(conversation.created_at, now);
  const updated = formatRelativeTime(conversation.updated_at, now);
  const messageCount = countMessages(conversation);
  const title = conversation.title?.trim();
  const handoffMode = state?.handoffMode ?? "unknown";

  const blocks: unknown[] = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `🚨 Intercom Escalation — ${escalation.category}`,
        emoji: true,
      },
    },
  ];

  if (title) {
    blocks.push({
      type: "context",
      elements: [{ type: "mrkdwn", text: `*${title}*` }],
    });
  }

  blocks.push({
    type: "section",
    fields: [
      { type: "mrkdwn", text: `*User:*\n${user}` },
      { type: "mrkdwn", text: `*Conversation:*\n<${url}|#${escalation.conversationId}>` },
      { type: "mrkdwn", text: `*State:*\n${convState}` },
      { type: "mrkdwn", text: `*Assignee:*\n${assignee}` },
      { type: "mrkdwn", text: `*Started:*\n${started}` },
      { type: "mrkdwn", text: `*Last activity:*\n${updated}` },
      { type: "mrkdwn", text: `*Messages:*\n${messageCount}` },
      { type: "mrkdwn", text: `*Handoff:*\n${handoffMode}` },
    ],
  });

  blocks.push({
    type: "section",
    text: {
      type: "mrkdwn",
      text: quoteSnippet(escalation.body),
    },
  });

  blocks.push({
    type: "actions",
    elements: [
      {
        type: "button",
        text: { type: "plain_text", text: "View in Intercom" },
        url,
      },
    ],
  });

  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text:
          `workspace: \`${account.workspaceId}\` · ` +
          `pattern: \`${escalation.matchedPattern}\``,
      },
    ],
  });

  return {
    text: `🚨 Intercom escalation: ${escalation.category} from ${user} — <${url}|View conversation>`,
    blocks,
  };
}

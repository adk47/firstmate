import { describe, it, expect } from "vitest";
import {
  buildEscalationSlackMessage,
  buildEscalationSlackMessageMinimal,
  formatRelativeTime,
  type EscalationSummary,
} from "../src/slack.js";
import type {
  IntercomAccountConfig,
  IntercomConversation,
  IntercomSessionState,
} from "../src/types.js";

const account: IntercomAccountConfig = {
  enabled: true,
  workspaceId: "ws_abc",
  token: "tok",
  webhookSecret: "sec",
  botAdminId: "bot_1",
  defaultInboxId: "0",
  fallbackSlackSupervisionChannel: "https://hooks.slack.com/services/FAKE",
  fallbackAcknowledgement: "ack",
  requireMappedHumanAdmin: false,
  adminMapping: {},
};

const escalation: EscalationSummary = {
  conversationId: "conv_123",
  category: "legal",
  matchedPattern: "\\blegal action\\b",
  body: "I'm considering legal action against your company for this issue.",
};

const session: IntercomSessionState = {
  conversationId: "conv_123",
  workspaceId: "ws_abc",
  handoffMode: "human_takeover",
  lifecycleState: "open",
  currentAssigneeId: "bot_1",
  currentAssigneeType: "bot",
  lastEventId: null,
  processedEventIds: [],
  outboundMessageIds: [],
  createdAt: "2026-04-07T09:00:00.000Z",
  updatedAt: "2026-04-07T09:05:00.000Z",
};

// A fixed "now" reference so relative-time assertions are stable.
const NOW = 1_712_485_200_000; // 2024-04-07T09:00:00Z
const HOUR = 3600;

function makeConversation(overrides: Partial<IntercomConversation> = {}): IntercomConversation {
  return {
    type: "conversation",
    id: "conv_123",
    title: "Help with billing",
    created_at: Math.floor(NOW / 1000) - 2 * HOUR,
    updated_at: Math.floor(NOW / 1000) - 5 * 60,
    open: true,
    state: "open",
    assignee: { type: "admin", id: "admin_42", name: "Jane Doe" },
    source: {
      body: escalation.body,
      author: { type: "user", id: "user_7", name: "Alice Smith", email: "alice@example.com" },
    },
    conversation_parts: {
      conversation_parts: [
        {
          type: "conversation_part",
          id: "part_1",
          body: "hi",
          part_type: "comment",
          created_at: Math.floor(NOW / 1000) - 90 * 60,
          author: { type: "admin", id: "bot_1", name: "Bot" },
        },
        {
          type: "conversation_part",
          id: "part_2",
          body: "help",
          part_type: "comment",
          created_at: Math.floor(NOW / 1000) - 10 * 60,
          author: { type: "user", id: "user_7" },
        },
      ],
    },
    ...overrides,
  };
}

describe("formatRelativeTime", () => {
  it("formats seconds", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 30, NOW)).toBe("30s ago");
  });

  it("formats minutes", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 5 * 60, NOW)).toBe("5m ago");
  });

  it("formats hours", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 3 * HOUR, NOW)).toBe("3h ago");
  });

  it("formats days", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 2 * 24 * HOUR, NOW)).toBe("2d ago");
  });

  it("formats months", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 45 * 24 * HOUR, NOW)).toBe("1mo ago");
  });

  it("formats years", () => {
    expect(formatRelativeTime(Math.floor(NOW / 1000) - 400 * 24 * HOUR, NOW)).toBe("1y ago");
  });

  it("returns 'unknown' for zero/NaN", () => {
    expect(formatRelativeTime(0, NOW)).toBe("unknown");
    expect(formatRelativeTime(NaN, NOW)).toBe("unknown");
  });
});

describe("buildEscalationSlackMessage", () => {
  it("includes user, assignee, state, age, and message count in fields", () => {
    const payload = buildEscalationSlackMessage(escalation, makeConversation(), account, session, NOW);

    expect(payload.text).toContain("legal");
    expect(payload.text).toContain("Alice Smith");

    const fieldsBlock = payload.blocks.find(
      (b: any) => b.type === "section" && Array.isArray(b.fields),
    ) as any;
    expect(fieldsBlock).toBeTruthy();
    const fieldTexts = fieldsBlock.fields.map((f: any) => f.text).join("\n");
    expect(fieldTexts).toContain("Alice Smith <alice@example.com>");
    expect(fieldTexts).toContain("Jane Doe");
    expect(fieldTexts).toContain("open");
    expect(fieldTexts).toContain("2h ago"); // created 2 hours ago
    expect(fieldTexts).toContain("5m ago"); // updated 5 min ago
    expect(fieldTexts).toContain("3"); // 1 source + 2 parts
    expect(fieldTexts).toContain("human_takeover");
  });

  it("includes a header, quoted body snippet, button, and context block", () => {
    const payload = buildEscalationSlackMessage(escalation, makeConversation(), account, session, NOW);
    const types = payload.blocks.map((b: any) => b.type);
    expect(types).toContain("header");
    expect(types).toContain("actions");
    expect(types.filter((t) => t === "section").length).toBeGreaterThanOrEqual(2);

    const quoteBlock = (payload.blocks as any[]).find(
      (b) => b.type === "section" && b.text?.text?.startsWith("> "),
    );
    expect(quoteBlock).toBeTruthy();

    const contextBlocks = (payload.blocks as any[]).filter((b) => b.type === "context");
    const footer = contextBlocks[contextBlocks.length - 1];
    expect(footer.elements[0].text).toContain("ws_abc");
    expect(footer.elements[0].text).toContain(escalation.matchedPattern);
  });

  it("falls back gracefully when assignee/author/parts are missing", () => {
    const sparse = makeConversation({
      assignee: null,
      source: { body: "x", author: { type: "user", id: "user_7" } },
      conversation_parts: { conversation_parts: [] },
      title: null,
    });
    const payload = buildEscalationSlackMessage(escalation, sparse, account, null, NOW);

    const fieldsBlock = (payload.blocks as any[]).find((b) => b.fields) as any;
    const fieldTexts = fieldsBlock.fields.map((f: any) => f.text).join("\n");
    expect(fieldTexts).toContain("Unassigned");
    expect(fieldTexts).toContain("user:user_7");
    expect(fieldTexts).toContain("*Messages:*\n1");
    expect(fieldTexts).toContain("unknown"); // handoff mode when state is null
  });

  it("renders assignee from admin_assignee_id when API v2.11 shape is used", () => {
    // Regression: escalation cards are built from the live API response,
    // which uses `admin_assignee_id` (number), not the webhook `assignee`
    // object. Prior to the fix this showed "Unassigned" in every card.
    const apiShape = makeConversation({
      assignee: undefined,
      admin_assignee_id: 5465657,
      team_assignee_id: 2238258,
    });
    const payload = buildEscalationSlackMessage(escalation, apiShape, account, session, NOW);
    const fieldsBlock = (payload.blocks as any[]).find((b) => b.fields) as any;
    const fieldTexts = fieldsBlock.fields.map((f: any) => f.text).join("\n");
    expect(fieldTexts).toContain("admin:5465657");
    expect(fieldTexts).not.toContain("Unassigned");
  });

  it("prefers admin_assignee_id over assignee when both are present", () => {
    // Regression guard: describeAssignee must prefer the v2.11 API field
    // over a stale legacy `assignee` object. A future refactor reordering
    // the checks would silently flip the rendered assignee.
    const mixed = makeConversation({
      admin_assignee_id: 5465657,
      assignee: { type: "admin", id: "stale_bot_id", name: "Stale Bot" },
    });
    const payload = buildEscalationSlackMessage(escalation, mixed, account, session, NOW);
    const fieldsBlock = (payload.blocks as any[]).find((b) => b.fields) as any;
    const fieldTexts = fieldsBlock.fields.map((f: any) => f.text).join("\n");
    expect(fieldTexts).toContain("admin:5465657");
    expect(fieldTexts).not.toContain("Stale Bot");
  });

  it("truncates long bodies to 500 chars with ellipsis", () => {
    const long = "a".repeat(800);
    const payload = buildEscalationSlackMessage(
      { ...escalation, body: long },
      makeConversation(),
      account,
      session,
      NOW,
    );
    const quoteBlock = (payload.blocks as any[]).find(
      (b) => b.type === "section" && b.text?.text?.startsWith("> "),
    ) as any;
    // "> " + 500 chars + "…" = 503
    expect(quoteBlock.text.text.length).toBe(503);
    expect(quoteBlock.text.text.endsWith("…")).toBe(true);
  });
});

describe("buildEscalationSlackMessageMinimal", () => {
  it("matches the pre-enrichment shape (category, pattern, snippet, button)", () => {
    const payload = buildEscalationSlackMessageMinimal(escalation, account);
    expect(payload.text).toContain("legal");
    expect(payload.blocks.length).toBe(2);
    const section = (payload.blocks as any[])[0];
    expect(section.text.text).toContain("*Category:* legal");
    expect(section.text.text).toContain("*Pattern:*");
    expect(section.text.text).toContain("*Message:*");
    const actions = (payload.blocks as any[])[1];
    expect(actions.elements[0].url).toBe(
      "https://app.intercom.com/a/inbox/ws_abc/inbox/conversation/conv_123",
    );
  });
});

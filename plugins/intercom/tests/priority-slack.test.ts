import { describe, it, expect } from "vitest";
import { buildPrioritySlackPayload, escapeSlackMrkdwn } from "../src/priority-slack.js";

function sectionText(payload: { blocks: unknown[] }): string {
  const section = (payload.blocks as any[]).find((b) => b.type === "section");
  return section?.text?.text ?? "";
}

describe("escapeSlackMrkdwn", () => {
  it("escapes & before < and > (no double-escaping)", () => {
    expect(escapeSlackMrkdwn("a & b < c > d")).toBe("a &amp; b &lt; c &gt; d");
  });

  it("neutralizes a channel-ping injection attempt", () => {
    expect(escapeSlackMrkdwn("<!channel>")).toBe("&lt;!channel&gt;");
  });

  it("neutralizes a user-mention injection attempt", () => {
    expect(escapeSlackMrkdwn("<@U0AL36NADEY>")).toBe("&lt;@U0AL36NADEY&gt;");
  });
});

describe("buildPrioritySlackPayload", () => {
  const base = {
    conversationId: "123",
    reason: "missing 40 credits",
    customerEmail: "user@example.com",
    customerMessage: "all my credits are gone!",
    workspaceId: "ws_1",
    mentionUserIds: ["U7RP6HKUZ"],
  };

  it("renders a real @-mention from trusted config ids", () => {
    const p = buildPrioritySlackPayload(base);
    expect(p.text).toContain("<@U7RP6HKUZ>");
    expect(sectionText(p)).toContain("<@U7RP6HKUZ>");
  });

  it("renders the deeplink as a perpetual markdown link, not a single-use button", () => {
    const p = buildPrioritySlackPayload(base);
    expect(p.text).toContain("ws_1");
    expect(p.text).toContain("123");
    // The link MUST be a markdown link in the section, never a Block Kit action
    // button: Slack consumes action buttons after one click ("selected by
    // @user"), so a button would make the conversation link single-use. A
    // markdown link is pure navigation — every teammate can open it, every time.
    const text = sectionText(p);
    expect(text).toMatch(/<https:\/\/app\.intercom\.com\/[^|]*123[^|]*\|/);
    expect((p.blocks as any[]).some((b) => b.type === "actions")).toBe(false);
  });

  it("names the customer as `email (name)` when both are known", () => {
    const p = buildPrioritySlackPayload({ ...base, customerName: "Luis Marrero" });
    expect(sectionText(p)).toContain("user@example.com (Luis Marrero)");
  });

  it("shows the email alone when no name is known", () => {
    const p = buildPrioritySlackPayload({ ...base, customerName: null });
    const text = sectionText(p);
    expect(text).toContain("user@example.com");
    expect(text).not.toContain("user@example.com (");
  });

  it("escapes an injection attempt in the customer message", () => {
    const p = buildPrioritySlackPayload({
      ...base,
      customerMessage: "fix it <!channel> or else",
    });
    const text = sectionText(p);
    expect(text).toContain("&lt;!channel&gt;");
    expect(text).not.toContain("<!channel>");
  });

  it("escapes an injection attempt in the model-supplied reason", () => {
    const p = buildPrioritySlackPayload({
      ...base,
      reason: "<@U0AL36NADEY> spoofed",
    });
    const text = sectionText(p);
    expect(text).toContain("&lt;@U0AL36NADEY&gt;");
    // The only real mention rendered is the trusted one from config.
    expect((text.match(/<@U/g) ?? []).length).toBe(1);
  });

  it("escapes an injection attempt in the customer name", () => {
    // The customer controls their Intercom display name — it's untrusted and
    // must be escaped like the message/reason. (Easy to miss: the old code only
    // escaped the email, so the name is new attack surface.)
    const p = buildPrioritySlackPayload({ ...base, customerName: "<!channel> Ann" });
    const text = sectionText(p);
    expect(text).toContain("&lt;!channel&gt;");
    expect(text).not.toContain("<!channel>");
    // Still the single trusted config mention — the injected name adds no ping.
    expect((text.match(/<@U/g) ?? []).length).toBe(1);
  });

  it("falls back gracefully when reason/email are absent", () => {
    const p = buildPrioritySlackPayload({
      ...base,
      reason: null,
      customerEmail: null,
    });
    const text = sectionText(p);
    expect(text).toContain("unknown");
    expect(text).toContain("customer data complaint");
  });

  it("ignores malformed mention ids (no injection via config)", () => {
    const p = buildPrioritySlackPayload({ ...base, mentionUserIds: ["not a real id <!channel>"] });
    expect(p.text).not.toContain("<!channel>");
    expect(p.text).not.toContain("<@not");
  });
});

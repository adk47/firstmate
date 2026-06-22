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

  it("includes the conversation deeplink and a button", () => {
    const p = buildPrioritySlackPayload(base);
    expect(p.text).toContain("ws_1");
    expect(p.text).toContain("123");
    const actions = (p.blocks as any[]).find((b) => b.type === "actions");
    expect(actions.elements[0].url).toContain("123");
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

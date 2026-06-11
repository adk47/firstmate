import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import {
  buildTicketTitle,
  buildTicketMarkdown,
  buildFollowupComment,
  buildTicketTags,
  slaDueDateMs,
  getTierForAction,
  TIER_SLAS,
} from "../src/tools/ticket-format.js";

// The exact extraction regex used by scripts/dedup/sweeps/close-merged-tickets.sh
// (jq `capture("---ACTION-REQUEST---\\s*(?<j>\\{[\\s\\S]*?\\})\\s*---END-ACTION-REQUEST---")`).
// Ticket bodies MUST stay parseable by it — ops automation depends on it.
const OPS_SWEEP_REGEX = /---ACTION-REQUEST---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST---/;

describe("buildTicketTitle", () => {
  it("formats as [label] gist — email", () => {
    expect(
      buildTicketTitle({
        actionType: "credit-claim",
        gist: "Producer credit missing on Track X",
        customerEmail: "user@example.com",
      }),
    ).toBe("[credit-claim] Producer credit missing on Track X — user@example.com");
  });

  it("shortens subscription-refund to refund and support-general to support", () => {
    expect(
      buildTicketTitle({ actionType: "subscription-refund", gist: "Recurring charges since Jan, no account found", customerEmail: "jen@example.com" }),
    ).toBe("[refund] Recurring charges since Jan, no account found — jen@example.com");
    expect(
      buildTicketTitle({ actionType: "support-general", gist: "Wants human follow-up after 1 week wait", customerEmail: "jura@example.com" }),
    ).toBe("[support] Wants human follow-up after 1 week wait — jura@example.com");
  });

  it("truncates gists longer than 60 chars with an ellipsis", () => {
    const longGist = "A".repeat(80);
    const title = buildTicketTitle({ actionType: "credit-claim", gist: longGist, customerEmail: "u@example.com" });
    expect(title).toBe(`[credit-claim] ${"A".repeat(59)}… — u@example.com`);
  });

  it("collapses internal whitespace/newlines in the gist", () => {
    const title = buildTicketTitle({ actionType: "credit-claim", gist: "  two\n  lines   here ", customerEmail: "u@example.com" });
    expect(title).toBe("[credit-claim] two lines here — u@example.com");
  });
});

describe("buildTicketMarkdown", () => {
  const base = {
    gist: "Producer credit missing on Track X",
    summary: "Customer wants Producer credit on Track X",
    actionType: "credit-claim",
    tier: 1,
    sla: "2 business days",
    customerEmail: "user@example.com",
    conversationSummary: "Customer asked about a missing Producer credit.",
    sessionId: "session_abc",
  };

  it("renders the human section with customer, action and summary", () => {
    const md = buildTicketMarkdown(base);
    expect(md).toContain("## Producer credit missing on Track X");
    expect(md).toContain("**Customer:** user@example.com");
    expect(md).toContain("**Action:** credit-claim · Tier 1 · SLA 2 business days");
    expect(md).toContain("**Request:** Customer wants Producer credit on Track X");
    expect(md).toContain("**Conversation summary:** Customer asked about a missing Producer credit.");
  });

  it("links the Muso profile and Intercom conversation when known", () => {
    const md = buildTicketMarkdown({
      ...base,
      customerProfileId: "54a99ccc-8313",
      intercomUrl: "https://app.intercom.com/a/inbox/w/inbox/conversation/123",
    });
    expect(md).toContain("**Profile:** https://credits.muso.ai/profile/54a99ccc-8313");
    expect(md).toContain("**Conversation:** https://app.intercom.com/a/inbox/w/inbox/conversation/123");
  });

  it("renders customer name next to the email when provided", () => {
    const md = buildTicketMarkdown({ ...base, customerName: "Jura Kez" });
    expect(md).toContain("**Customer:** user@example.com (Jura Kez)");
  });

  it("renders details as bullets, stringifying non-string values", () => {
    const md = buildTicketMarkdown({
      ...base,
      details: { wait_time: "1 week", urls: ["https://a", "https://b"] },
    });
    expect(md).toContain("- wait_time: 1 week");
    expect(md).toContain('- urls: ["https://a","https://b"]');
  });

  it("keeps the machine JSON block parseable by the ops sweep regex", () => {
    const md = buildTicketMarkdown({
      ...base,
      customerProfileId: "prof_123",
      details: { trackName: "Song Title" },
    });
    const m = OPS_SWEEP_REGEX.exec(md);
    expect(m).not.toBeNull();
    const parsed = JSON.parse(m![1]);
    expect(parsed).toEqual({
      action_type: "credit-claim",
      approval_tier: 1,
      customer_email: "user@example.com",
      customer_profile_id: "prof_123",
      details: { trackName: "Song Title" },
      conversation_summary: "Customer asked about a missing Producer credit.",
      cs_session_id: "session_abc",
    });
  });

  it("emits null customer_profile_id and empty details when absent", () => {
    const md = buildTicketMarkdown(base);
    const parsed = JSON.parse(OPS_SWEEP_REGEX.exec(md)![1]);
    expect(parsed.customer_profile_id).toBeNull();
    expect(parsed.details).toEqual({});
  });
});

describe("buildFollowupComment", () => {
  const params = {
    summary: "Customer provided an alternate email for the billing investigation",
    actionType: "subscription-refund",
    tier: 3,
    customerEmail: "jen@example.com",
    details: { alternate_email: "jen@icloud.com" },
    conversationSummary: "Customer added an alternate account email for tracing.",
    sessionId: "session_xyz",
  };

  it("renders a follow-up header with the new info", () => {
    const c = buildFollowupComment(params);
    expect(c).toContain("**Customer follow-up** (subscription-refund): Customer provided an alternate email for the billing investigation");
    expect(c).toContain("- alternate_email: jen@icloud.com");
    expect(c).toContain("**Conversation summary:** Customer added an alternate account email for tracing.");
  });

  it("uses UPDATE markers that do NOT match the ops description regex", () => {
    const c = buildFollowupComment(params);
    expect(c).toContain("---ACTION-REQUEST-UPDATE---");
    expect(c).toContain("---END-ACTION-REQUEST-UPDATE---");
    expect(OPS_SWEEP_REGEX.exec(c)).toBeNull();
  });

  it("embeds a parseable JSON block with the same field shape", () => {
    const c = buildFollowupComment(params);
    const m = /---ACTION-REQUEST-UPDATE---\s*(\{[\s\S]*?\})\s*---END-ACTION-REQUEST-UPDATE---/.exec(c);
    expect(m).not.toBeNull();
    const parsed = JSON.parse(m![1]);
    expect(parsed.action_type).toBe("subscription-refund");
    expect(parsed.customer_email).toBe("jen@example.com");
    expect(parsed.details).toEqual({ alternate_email: "jen@icloud.com" });
    expect(parsed.cs_session_id).toBe("session_xyz");
  });
});

describe("buildTicketTags", () => {
  it("keeps the three base tags and adds the team tag", () => {
    expect(buildTicketTags({ actionType: "credit-claim", tier: 1 })).toEqual([
      "hydra-action-request", "tier-1", "action:credit-claim", "team:catalog",
    ]);
    expect(buildTicketTags({ actionType: "subscription-refund", tier: 3 })).toEqual([
      "hydra-action-request", "tier-3", "action:subscription-refund", "team:growth",
    ]);
  });

  it("adds an escalation tag for known escalation reasons", () => {
    expect(
      buildTicketTags({ actionType: "support-general", tier: 1, details: { escalation_reason: "customer_requested_human" } }),
    ).toContain("escalation:customer-requested-human");
    expect(
      buildTicketTags({ actionType: "support-general", tier: 1, details: { escalation_reason: "frustration_detected" } }),
    ).toContain("escalation:frustration-detected");
    expect(
      buildTicketTags({ actionType: "support-general", tier: 1, details: { escalation_reason: "loop_detected" } }),
    ).toContain("escalation:loop-detected");
  });

  it("ignores unknown escalation reasons (no free-form tag injection)", () => {
    const tags = buildTicketTags({ actionType: "support-general", tier: 1, details: { escalation_reason: "made_up_reason" } });
    expect(tags.find((t) => t.startsWith("escalation:"))).toBeUndefined();
  });

  it("keeps the legacy analytics-followup extra tag", () => {
    expect(buildTicketTags({ actionType: "analytics-followup", tier: 1 })).toContain("analytics-followup");
  });
});

describe("slaDueDateMs", () => {
  // 2026-06-08T12:00:00Z is a Monday.
  const MONDAY = Date.UTC(2026, 5, 8, 12, 0, 0);
  const day = (ms: number) => new Date(ms).toISOString().slice(0, 10);

  it("tier 1 = +2 business days", () => {
    expect(day(slaDueDateMs(1, MONDAY))).toBe("2026-06-10");
  });

  it("tier 2 = +5 business days", () => {
    expect(day(slaDueDateMs(2, MONDAY))).toBe("2026-06-15");
  });

  it("tier 3 = +10 business days", () => {
    expect(day(slaDueDateMs(3, MONDAY))).toBe("2026-06-22");
  });

  it("skips weekends (Friday + 2bd = Tuesday)", () => {
    const friday = Date.UTC(2026, 5, 12, 12, 0, 0);
    expect(day(slaDueDateMs(1, friday))).toBe("2026-06-16");
  });
});

describe("tier helpers", () => {
  it("maps action types to tiers", () => {
    expect(getTierForAction("credit-claim")).toBe(1);
    expect(getTierForAction("profile-merge")).toBe(2);
    expect(getTierForAction("data-deletion")).toBe(3);
    expect(getTierForAction("unknown-action")).toBe(1);
  });

  it("exposes the SLA strings", () => {
    expect(TIER_SLAS[1]).toBe("2 business days");
    expect(TIER_SLAS[2]).toBe("5 business days");
    expect(TIER_SLAS[3]).toBe("5-10 business days");
  });
});

describe("vendored twin parity", () => {
  it("is byte-identical to plugins/intercom/src/ticket-format.ts", () => {
    const ours = readFileSync(new URL("../src/tools/ticket-format.ts", import.meta.url), "utf8");
    const twin = readFileSync(new URL("../../intercom/src/ticket-format.ts", import.meta.url), "utf8");
    expect(twin).toBe(ours);
  });
});

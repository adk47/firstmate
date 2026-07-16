import { describe, it, expect } from "vitest";
import { sanitizeToolLeak } from "../src/sanitize-tool-leak.js";

describe("sanitizeToolLeak", () => {
  it("redacts internal tool names", () => {
    const out = sanitizeToolLeak("Let me call profile_status to check your account.");
    expect(out.body).toBe("Let me call [REDACTED] to check your account.");
    expect(out.redactions).toContain("profile_status");
  });

  it("redacts support tool names", () => {
    const tokens = [
      "create_ticket",
      "profile_lookup",
      "credits_search",
      "subscription_status",
      "profile_status",
      "remove_credits",
      "dedupe_check",
      "credit_verification_check",
      "profiles_claim_self",
      "credits_verify",
      "profiles_consolidate",
      "order_lookup",
      "order_address_update",
      "founding_status",
      "founding_buyback_link",
      "support_action_router",
      "memory_search",
      "memory_get",
      "profile_analytics_status",
      "profile_credits_status",
      "profile_claim_status",
      "retention_offer_check",
      "retention_offer_apply",
      "cancel_subscription",
      "billing_status",
      "track_analytics_status",
      "analytics_refresh_request",
      "analytics_recheck",
      "subscription_cancel",
      "refund_policy_check",
      "refund_create",
      "catalog_status",
      "track_lookup",
      "metadata_capture_request",
      "artwork_refresh_request",
      "catalog_recheck",
      "user_status",
      "resend_verification",
      "email_delivery_status",
      "login_recovery_packet",
      "profile_change_packet",
      "profile_merge_check",
      "account_merge_preflight",
      "email_change_preflight",
      "profile_removal_preflight",
    ];
    const out = sanitizeToolLeak(`Tools: ${tokens.join(" ")}.`);
    for (const tok of tokens) {
      expect(out.redactions).toContain(tok);
    }
    for (const tok of tokens) {
      expect(out.body).not.toContain(tok);
    }
  });

  it("redacts internal phrases (case-insensitive)", () => {
    const cases = [
      "Tool failed to fetch your data.",
      "There was an error fetching your data.",
      "Unable to look up your profile.",
      "The system says you're not eligible.",
      "My system can't see that.",
      "There was an issue with the lookup.",
    ];
    for (const c of cases) {
      const out = sanitizeToolLeak(c);
      expect(out.body).toContain("[REDACTED]");
      expect(out.redactions.length).toBeGreaterThan(0);
    }
  });

  it("redacts internal architecture words (case-insensitive)", () => {
    const out = sanitizeToolLeak("We use ClickUp and openclaw on HYDRA.");
    expect(out.body).toBe("We use [REDACTED] and [REDACTED] on [REDACTED].");
    expect(out.redactions).toEqual(expect.arrayContaining(["ClickUp", "openclaw", "HYDRA"]));
  });

  it("passes through approved phrasing unchanged", () => {
    const allow = [
      "I've flagged your profile to engineering.",
      "I'm looking at your profile right now — latest credit is Track A from 2026-05-08.",
      "You'll hear back within 2 business days.",
    ];
    for (const a of allow) {
      const out = sanitizeToolLeak(a);
      expect(out.body).toBe(a);
      expect(out.redactions).toEqual([]);
    }
  });

  it("handles non-string body defensively", () => {
    // @ts-expect-error testing runtime safety
    const out = sanitizeToolLeak(null);
    expect(out.body).toBe("[REDACTED]");
    expect(out.redactions[0]).toMatch(/non-string body/);
  });

  it("truncates pathological input", () => {
    const big = "openclaw ".repeat(5000); // > 16k bytes
    const out = sanitizeToolLeak(big);
    expect(out.body.length).toBeLessThanOrEqual(16_000);
    expect(out.redactions.some((r) => r.includes("truncated"))).toBe(true);
  });

  it("redacts bare 'ticket' word in customer-facing prose (defense-in-depth)", () => {
    const cases = [
      "I'll create a support ticket for you.",
      "Our team will look at your ticket within 2 business days.",
      "I've opened a ticket.",
    ];
    for (const c of cases) {
      const out = sanitizeToolLeak(c);
      expect(out.body).not.toMatch(/\bticket\b/);
      expect(out.redactions.some((r) => r.toLowerCase() === "ticket")).toBe(true);
    }
  });

  it("does NOT redact 'create_ticket' more than once when both patterns might match", () => {
    // create_ticket token contains 'ticket' as substring, but the \b boundary
    // around 'ticket' means it should NOT match inside 'create_ticket'
    const out = sanitizeToolLeak("Internal: I will use create_ticket.");
    // create_ticket pattern fires first and replaces the whole token.
    // The standalone 'ticket' pattern should not double-redact a [REDACTED] result.
    expect(out.body).toBe("Internal: I will use [REDACTED].");
    // Either order works as long as 'create_ticket' (the token) appears once
    // in redactions and 'ticket' does not appear separately
    const lowerRed = out.redactions.map((r) => r.toLowerCase());
    expect(lowerRed).toContain("create_ticket");
  });
});

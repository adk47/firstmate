import { describe, it, expect } from "vitest";
import { sanitizeHandoffClaim } from "../src/sanitize-handoff-claim.js";

const FALLBACK = "I'll make sure this gets to the team.";

describe("sanitizeHandoffClaim", () => {
  it("rewrites first-person completed-action claims to the honest fallback when no ticket was filed", () => {
    const claims = [
      "I've flagged this for our team.",
      "I raised it with the team.",
      "I've flagged your profile to engineering.",
      "I've sent this to engineering.",
      "I've added these to your existing request and raised it with the team.",
      "We've escalated this to the support team.",
      "I've opened a ticket with the team.",
      "I've created a request for the team.",
      "I've logged this with engineering.",
    ];
    for (const c of claims) {
      const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
      expect(out.body).toBe(FALLBACK);
      expect(out.redactions).toContain(c);
    }
  });

  it("rewrites passive 'request is with the team' claims too", () => {
    for (const c of ["This has been sent to the team.", "Your request is with engineering.", "It's been escalated to the team."]) {
      const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
      expect(out.body).toBe(FALLBACK);
      expect(out.redactions).toContain(c);
    }
  });

  it("catches claims written with a typographic (curly) apostrophe — the model emits these", () => {
    // U+2019 in "I've" / "it's". No upstream pass normalizes it, so the matcher must.
    for (const c of ["I’ve flagged this for our team.", "We’ve escalated this to the team.", "It’s been sent to engineering."]) {
      const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
      expect(out.body).toBe(FALLBACK);
      expect(out.redactions).toContain(c);
    }
  });

  it("does NOT stitch two independent clauses across a semicolon into a false claim", () => {
    // "sent … team" spans a semicolon = two separate statements, not a handoff claim.
    const c = "I've sent you a confirmation email; the team is standing by for your next order.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("is a NO-OP when a ticket was confirmed for the conversation (legitimate post-ticket reply)", () => {
    const c = "I've flagged this for our team. You'll hear back within 5 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: true });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("leaves non-claims untouched even without a ticket", () => {
    const clean = [
      "I've added these tracks to your profile.",
      "I've opened your profile to double-check your credits.", // verb but no handoff target
      "I've created a fresh search for your catalog.", // verb but no handoff target
      "I'm looking at your profile right now, your latest credit is Track A.",
      "Your latest drop is live and looking good.",
      // The sanctioned fallback itself must never be re-matched.
      FALLBACK,
      "I'll flag this for the team.", // future promise, not a completed claim
    ];
    for (const c of clean) {
      const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
      expect(out.body).toBe(c);
      expect(out.redactions).toEqual([]);
    }
  });

  it("strips a co-occurring invented SLA when it rides alongside an unbacked claim", () => {
    const c = "I've flagged this for our team. You'll hear back within 2 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions).toContain("I've flagged this for our team.");
    expect(out.redactions).toContain("You'll hear back within 2 business days.");
  });

  it("keeps a FACTUAL timeframe (not a promise) even while rewriting a co-occurring claim", () => {
    const c = "I've flagged this for our team. Refunds are processed within 5 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(`${FALLBACK} Refunds are processed within 5 business days.`);
    expect(out.redactions).toContain("I've flagged this for our team.");
    expect(out.redactions).not.toContain("Refunds are processed within 5 business days.");
  });

  it("does NOT strip a standalone SLA-shaped sentence when no handoff claim is present", () => {
    // Without a claim this is far more likely to be factual than a false promise.
    const c = "Refunds usually process within 5 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("preserves surrounding clean sentences when rewriting a mid-reply claim", () => {
    const c = "Thanks for the details. I've flagged this for our team. Anything else I can help with?";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(`Thanks for the details. ${FALLBACK} Anything else I can help with?`);
  });

  it("handles non-string body defensively", () => {
    // @ts-expect-error testing runtime safety
    const out = sanitizeHandoffClaim(null, { ticketConfirmed: false });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions[0]).toMatch(/non-string body/);
  });

  it("truncates pathological input and still enforces honesty", () => {
    const big = "I've flagged this for our team. " + "x".repeat(20_000);
    const out = sanitizeHandoffClaim(big, { ticketConfirmed: false });
    expect(out.body.length).toBeLessThanOrEqual(16_000);
    expect(out.body.startsWith(FALLBACK)).toBe(true);
    expect(out.redactions.some((r) => r.includes("truncated"))).toBe(true);
  });
});

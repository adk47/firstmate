import { describe, it, expect } from "vitest";
import { sanitizeHandoffClaim } from "../src/sanitize-handoff-claim.js";
import { musoProfileUrl } from "../src/ticket-format.js";

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

// MUS-1516 — a quoted ClickUp reference number is the STRONGEST possible handoff
// claim, and it was the one shape the guard (keyed on handoff verbs) never checked.
// AC1: the real 27 Sep production shape, verbatim from the MUS-1471 CTO comment —
// proven red against the pre-fix guard by running its own regexes (CLAIM_A=false,
// CLAIM_B=false, INVENTED_SLA=true => passed through untouched).
describe("sanitizeHandoffClaim — unbacked reference numbers (MUS-1516)", () => {
  it("AC1: redacts the verbatim 27 Sep incident shape (bare refs + SLA, no handoff verb)", () => {
    const c =
      "Your reference numbers are 869f7v9v2, 869f7va3b and 869f7vabr.\n" +
      "You'll hear back within 2 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false, filedTicketIds: [] });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions).toContain("Your reference numbers are 869f7v9v2, 869f7va3b and 869f7vabr.");
    expect(out.redactions).toContain("You'll hear back within 2 business days.");
    expect(out.body).not.toContain("869f7v9v2");
  });

  it("AC2: a bare unbacked reference number (no verb, no SLA) is redacted, FALLBACK shown, sentence logged", () => {
    const c = "Your reference number is 869f7v9v2.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false, filedTicketIds: [] });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions).toContain(c);
    expect(out.body).not.toContain("869f7v9v2");
    // The id must never be blanked in place — the whole sentence goes.
    expect(out.body).not.toContain("Your reference number is");
  });

  it("a reference number that IS in this conversation's filed-id set is left untouched", () => {
    const c = "Your reference number is 869f7v9v2. We'll take it from here.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false, filedTicketIds: ["869f7v9v2"] });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("a sentence with one filed id and one unfiled id is redacted (the unfiled id licenses nothing)", () => {
    const c = "Your reference numbers are 869f7v9v2 and 869f7va3b.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false, filedTicketIds: ["869f7v9v2"] });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions).toContain(c);
  });

  // AC7 / design call ② (MUS-1471): a missing or stale id store carries no known
  // ids, so every reference-shaped token is treated as unbacked. This is the
  // deliberate fail-closed direction — a lost signal can only downgrade an honest
  // reply toward the fallback, it can never license a fake or foreign id.
  it("AC7: fails closed when filedTicketIds is omitted entirely (missing/stale id store)", () => {
    const c = "Your reference number is 869f7v9v2.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(FALLBACK);
    expect(out.redactions).toContain(c);
  });
});

// AC3: today INVENTED_SLA only ever fires as a passenger of an existing verb-claim
// (the early-return at :86-90 skips the body entirely when no claim matched). A
// standalone SLA promise with NO handoff verb and NO reference id must now also be
// caught on its own — Caroline's 27 Sep reply had exactly this shape once the refs
// are set aside.
describe("sanitizeHandoffClaim — standalone unbacked SLA promise (MUS-1516 AC3)", () => {
  it("AC3: redacts a standalone SLA promise with no verb-claim and no reference id", () => {
    const c = "Thanks for reaching out! You'll hear back within 2 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe("Thanks for reaching out!");
    expect(out.redactions).toContain("You'll hear back within 2 business days.");
  });

  it("still leaves a FACTUAL timeframe untouched even as a standalone sentence (carve-out, AC4 regression pin)", () => {
    // Already pinned by the existing "does NOT strip a standalone SLA-shaped
    // sentence" test above for the no-claim case; this re-confirms the carve-out
    // holds now that standalone SLA sentences are actively inspected.
    const c = "Thanks for reaching out! Refunds are processed within 5 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });
});

// AC4-6: the `ticketConfirmed` short-circuit (:80) used to return the body
// untouched unconditionally — so a real, confirmed ticket licensed ANY quoted id,
// not just the one actually filed. A confirmed ticket still makes a completed-
// action claim and an SLA promise TRUE (untouched), but the quoted id itself must
// be one this conversation actually filed.
describe("sanitizeHandoffClaim — ticketConfirmed cross-checks the id itself (MUS-1516 AC5/AC6)", () => {
  it("AC5: ticketConfirmed + the id actually filed passes through byte-identical", () => {
    const c = "Your reference number is 869f7v9v2. We'll take it from here.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: true, filedTicketIds: ["869f7v9v2"] });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("AC6: ticketConfirmed + a DIFFERENT id than was filed is redacted", () => {
    const c = "Your reference number is 869f7v9v2. We'll take it from here.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: true, filedTicketIds: ["869dgkzga"] });
    expect(out.body).toBe(`${FALLBACK} We'll take it from here.`);
    expect(out.redactions).toContain("Your reference number is 869f7v9v2.");
  });

  it("ticketConfirmed still licenses a completed-action claim and its SLA promise when no id is quoted", () => {
    // Regression pin: the existing NO-OP test above already covers this without
    // any reference id in the body; this is unchanged by the MUS-1516 fix.
    const c = "I've flagged this for our team. You'll hear back within 5 business days.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: true, filedTicketIds: [] });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });
});

// AC8 / design call ③ (MUS-1471): containment. Enumerated identifiers that
// legitimately reach customer-facing copy (ticket-format.ts's musoProfileUrl,
// order-lookup.ts's order_ref family, core-backend's order-number nanoid) must
// never be mistaken for a ClickUp reference id. A guard that eats real order
// numbers or profile URLs is worse than the bug it fixes.
describe("sanitizeHandoffClaim — containment: real identifiers survive untouched (MUS-1516 AC8)", () => {
  it("a Muso profile UUID (ticket-format.ts musoProfileUrl) never matches the reference-id pattern", () => {
    const c = `Here's your profile: ${musoProfileUrl("6ecb8f39-1a2b-4c3d-8e9f-0123456789ab")}`;
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("an internal order UUID (order-lookup.ts order_ref) never matches — no 9-char segment in a UUID", () => {
    const c = "Your order id is 3f2b9a10-7c44-4e11-9c2d-5a6b7c8d9e0f for tracking.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("an order number (core-backend createOrder.js: customAlphabet(UPPER+digits,10)(5) — 5-char UPPERCASE) never matches", () => {
    const c = "Your order number is K3N9X for tracking.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("a Prodigi numeric order id never matches — all-digit and longer than 9 characters", () => {
    const c = "Your Prodigi order id is 66812882101295104 for tracking.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });

  it("a bare 9-digit all-numeric token (no letters) fails closed toward NOT matching — the safe containment direction", () => {
    const c = "Your confirmation code is 123456789 for tracking.";
    const out = sanitizeHandoffClaim(c, { ticketConfirmed: false });
    expect(out.body).toBe(c);
    expect(out.redactions).toEqual([]);
  });
});

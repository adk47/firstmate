import { describe, it, expect } from "vitest";
import { checkEscalation } from "../src/escalation.js";

describe("checkEscalation", () => {
  // True positives
  // Note: "refund" was removed from the billing triggers in commit
  // 7484ade because plain-English refund requests should go through
  // the normal agent flow, not auto-escalate.
  it("escalates on 'chargeback'", () => {
    const result = checkEscalation("I'm filing a chargeback with my bank");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("billing");
  });

  it("escalates on 'lawyer'", () => {
    const result = checkEscalation("I'm going to get my lawyer involved");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("legal");
  });

  it("escalates on 'hacked'", () => {
    const result = checkEscalation("My account has been hacked");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("security");
  });

  it("escalates on 'harassment'", () => {
    const result = checkEscalation("I want to report harassment by another user");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("abuse");
  });

  it("is case-insensitive", () => {
    const result = checkEscalation("I'm filing a CHARGEBACK with my bank");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("billing");
  });

  it("matches multi-word patterns", () => {
    const result = checkEscalation("There was an unauthorized charge on my card");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("billing");
  });

  // False positives that must NOT trigger
  it("does NOT escalate on 'charged up'", () => {
    const result = checkEscalation("I'm really charged up about this new feature!");
    expect(result.triggered).toBe(false);
  });

  it("does NOT escalate on 'is this legal'", () => {
    const result = checkEscalation("Is this legal to use in Germany for licensing?");
    expect(result.triggered).toBe(false);
  });

  it("does NOT escalate on 'billing address'", () => {
    const result = checkEscalation("Can I update my billing address on the account?");
    expect(result.triggered).toBe(false);
  });

  it("does NOT escalate on 'dispute' in non-billing context", () => {
    const result = checkEscalation("I dispute that characterization of my credits");
    expect(result.triggered).toBe(false);
  });

  it("does NOT escalate on normal support questions", () => {
    const result = checkEscalation("How do I claim credits on a track?");
    expect(result.triggered).toBe(false);
  });

  it("does NOT escalate on empty message", () => {
    const result = checkEscalation("");
    expect(result.triggered).toBe(false);
  });

  it("DOES escalate on 'billing dispute'", () => {
    const result = checkEscalation("I want to file a billing dispute");
    expect(result.triggered).toBe(true);
    expect(result.category).toBe("billing");
  });
});

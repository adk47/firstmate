import { describe, it, expect } from "vitest";
import { sanitizeTypography } from "../src/sanitize-typography.js";

describe("sanitizeTypography", () => {
  it("swaps a spaced em-dash for an en-dash, preserving the surrounding spaces", () => {
    const out = sanitizeTypography("I'll check on that — and get right back to you.");
    expect(out.body).toBe("I'll check on that – and get right back to you.");
    expect(out.redactions.length).toBe(1);
  });

  it("swaps a closed (unspaced) em-dash for an en-dash without merging the words", () => {
    const out = sanitizeTypography("credits—profiles");
    expect(out.body).toBe("credits–profiles");
    expect(out.body).not.toContain("—");
  });

  it("counts every em-dash it swaps", () => {
    const out = sanitizeTypography("a — b — c");
    expect(out.redactions.length).toBe(2);
    expect(out.body).toBe("a – b – c");
  });

  it("covers the whole em-dash family (em, horizontal bar, two-em, three-em)", () => {
    const out = sanitizeTypography("w—x―y⸺z⸻q");
    expect(out.body).toBe("w–x–y–z–q");
    expect(out.body).not.toMatch(/[—―⸺⸻]/);
    expect(out.redactions.length).toBe(4);
  });

  it("never produces an em-dash and reports no change when there is none", () => {
    const clean = "Your plan renews on the 1st. Settings then Billing has the details.";
    const out = sanitizeTypography(clean);
    expect(out.body).toBe(clean);
    expect(out.redactions.length).toBe(0);
  });

  // NEGATIVE intent cases: these carry range/date/compound/CLI/minus semantics and
  // MUST pass through untouched, so a future char-class typo can't eat them.
  it("leaves en-dash, hyphen, double-hyphen, minus, ranges, dates and compounds untouched", () => {
    for (const intact of [
      "tracks 10–15",        // en-dash range
      "2026-06-26",                // ISO date (hyphen)
      "well-known artist",         // hyphenated compound
      "pass --yes to confirm",     // CLI flag
      "balance is 5−3",       // minus sign U+2212
      "first--second",             // double hyphen
    ]) {
      const out = sanitizeTypography(intact);
      expect(out.body).toBe(intact);
      expect(out.redactions.length).toBe(0);
    }
  });

  it("returns a defensive marker for a non-string body (unreachable in the composed pipeline)", () => {
    // @ts-expect-error deliberately passing a non-string
    const out = sanitizeTypography(undefined);
    expect(out.redactions.length).toBeGreaterThan(0);
  });
});

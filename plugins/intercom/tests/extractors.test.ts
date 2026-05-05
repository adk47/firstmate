import { describe, it, expect } from "vitest";
import { updateKnownFacts } from "../src/extractors.js";
import type { KnownFacts } from "../src/types.js";

describe("updateKnownFacts", () => {
  it("extracts an email address and pins accountEmail", () => {
    const out = updateKnownFacts("you can reach me at support-customer@example.com", {});
    expect(out.accountEmail).toBe("support-customer@example.com");
  });

  it("normalizes email to lowercase", () => {
    const out = updateKnownFacts("Support@Example.COM", {});
    expect(out.accountEmail).toBe("support@example.com");
  });

  it("extracts an obfuscated email written with AT and DOT", () => {
    const out = updateKnownFacts("you can reach me at jami AT example DOT com", {});
    expect(out.accountEmail).toBe("jami@example.com");
  });

  it("extracts an obfuscated email written with parens", () => {
    const out = updateKnownFacts("send to user (at) example (dot) net please", {});
    expect(out.accountEmail).toBe("user@example.net");
  });

  it("does not overwrite an existing accountEmail", () => {
    const prev: KnownFacts = { accountEmail: "first@example.com" };
    const out = updateKnownFacts("contact me at second@example.com", prev);
    expect(out.accountEmail).toBe("first@example.com");
  });

  it("extracts a Muso profile URL and derives the profile ID", () => {
    const out = updateKnownFacts(
      "see my profile https://muso.ai/profile/abc123-def456-789",
      {},
    );
    expect(out.musoProfileUrl).toBe("https://muso.ai/profile/abc123-def456-789");
    expect(out.musoProfileId).toBe("abc123-def456-789");
  });

  it("returns the input unchanged when no facts are present in the message", () => {
    const prev: KnownFacts = { accountEmail: "x@y.com" };
    const out = updateKnownFacts("hello there", prev);
    expect(out).toEqual({ ...prev, factsLastUpdated: out.factsLastUpdated });
  });

  it("sets factsLastUpdated when a fact is updated", () => {
    const before = Date.now();
    const out = updateKnownFacts("foo@bar.com", {});
    const ts = Date.parse(out.factsLastUpdated!);
    expect(ts).toBeGreaterThanOrEqual(before);
  });
});

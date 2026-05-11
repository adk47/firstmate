import { describe, it, expect } from "vitest";
import { sanitizeOutboundBody, ALLOWED_OUTBOUND_EMAILS } from "../src/sanitize-email.js";

describe("ALLOWED_OUTBOUND_EMAILS", () => {
  it("contains exactly support@muso.ai (jan@muso.ai removed 2026-05-11)", () => {
    expect(ALLOWED_OUTBOUND_EMAILS).toEqual(new Set(["support@muso.ai"]));
  });
});

describe("sanitizeOutboundBody", () => {
  it("returns body untouched when there are no emails", () => {
    const { body, redactions } = sanitizeOutboundBody("Hey, thanks for reaching out. Try Settings > Billing.");
    expect(body).toBe("Hey, thanks for reaching out. Try Settings > Billing.");
    expect(redactions).toEqual([]);
  });

  it("passes support@muso.ai through unchanged", () => {
    const { body, redactions } = sanitizeOutboundBody("Email support@muso.ai for help.");
    expect(body).toBe("Email support@muso.ai for help.");
    expect(redactions).toEqual([]);
  });

  it("scrubs jan@muso.ai (removed from allowlist 2026-05-11)", () => {
    const { body, redactions } = sanitizeOutboundBody("Escalating to jan@muso.ai.");
    expect(body).toBe("Escalating to support@muso.ai.");
    expect(redactions).toEqual(["jan@muso.ai"]);
  });

  it("swaps a single disallowed email and reports it", () => {
    const { body, redactions } = sanitizeOutboundBody("Please contact nick@muso.ai for help.");
    expect(body).toBe("Please contact support@muso.ai for help.");
    expect(redactions).toEqual(["nick@muso.ai"]);
  });

  it("swaps multiple disallowed emails and reports all", () => {
    const { body, redactions } = sanitizeOutboundBody("Contact nick@muso.ai or aaron@muso.ai.");
    expect(body).toBe("Contact support@muso.ai or support@muso.ai.");
    expect(redactions).toEqual(["nick@muso.ai", "aaron@muso.ai"]);
  });

  it("mixes allowed and disallowed: allowed untouched, disallowed swapped", () => {
    const { body, redactions } = sanitizeOutboundBody(
      "Email support@muso.ai or nick@muso.ai for help.",
    );
    expect(body).toBe("Email support@muso.ai or support@muso.ai for help.");
    expect(redactions).toEqual(["nick@muso.ai"]);
  });

  it("allowlist match is case-insensitive; Support@Muso.AI allowed, JAN@muso.ai now scrubbed (2026-05-11)", () => {
    const { body, redactions } = sanitizeOutboundBody(
      "Email Support@Muso.AI or JAN@muso.ai — only support allowed.",
    );
    expect(body).toBe("Email Support@Muso.AI or support@muso.ai — only support allowed.");
    expect(redactions).toEqual(["JAN@muso.ai"]);
  });

  it("redacts a disallowed email that only differs in casing from allowed ones (e.g. Nick@Muso.AI)", () => {
    const { body, redactions } = sanitizeOutboundBody("Ping Nick@Muso.AI about it.");
    expect(body).toBe("Ping support@muso.ai about it.");
    expect(redactions).toEqual(["Nick@Muso.AI"]);
  });

  it("handles emails at start of string", () => {
    const { body, redactions } = sanitizeOutboundBody("nick@muso.ai is the contact.");
    expect(body).toBe("support@muso.ai is the contact.");
    expect(redactions).toEqual(["nick@muso.ai"]);
  });

  it("handles emails at end of string (no trailing punctuation)", () => {
    const { body, redactions } = sanitizeOutboundBody("Contact: nick@muso.ai");
    expect(body).toBe("Contact: support@muso.ai");
    expect(redactions).toEqual(["nick@muso.ai"]);
  });

  it("trailing-punctuation lock-in: single trailing period is NOT consumed", () => {
    const { body, redactions } = sanitizeOutboundBody("Email nick@example.com.");
    expect(body).toBe("Email support@muso.ai.");
    expect(redactions).toEqual(["nick@example.com"]);
  });

  it("trailing-punctuation lock-in: multiple trailing periods are NOT consumed", () => {
    const { body, redactions } = sanitizeOutboundBody("Email nick@example.com...");
    expect(body).toBe("Email support@muso.ai...");
    expect(redactions).toEqual(["nick@example.com"]);
  });

  it("trailing-punctuation lock-in: multi-level TLD matches fully", () => {
    const { body, redactions } = sanitizeOutboundBody("Email nick@example.co.uk for details.");
    expect(body).toBe("Email support@muso.ai for details.");
    expect(redactions).toEqual(["nick@example.co.uk"]);
  });

  it("handles adjacent emails separated by comma-space", () => {
    const { body, redactions } = sanitizeOutboundBody("Cc: nick@muso.ai, aaron@muso.ai.");
    expect(body).toBe("Cc: support@muso.ai, support@muso.ai.");
    expect(redactions).toEqual(["nick@muso.ai", "aaron@muso.ai"]);
  });

  it("handles adjacent emails separated by slash", () => {
    const { body, redactions } = sanitizeOutboundBody("Route nick@muso.ai/aaron@muso.ai to sales.");
    expect(body).toBe("Route support@muso.ai/support@muso.ai to sales.");
    expect(redactions).toEqual(["nick@muso.ai", "aaron@muso.ai"]);
  });

  // Allowlist-boundary tests: lock in that the allowlist is *exact*, not
  // substring/subdomain/prefix. A future change from Set.has() to
  // body.includes() would pass existing tests; these catch it.
  it("does not allow a local-part that ends with 'support' (xsupport@muso.ai)", () => {
    const { body, redactions } = sanitizeOutboundBody("Email xsupport@muso.ai please.");
    expect(body).toBe("Email support@muso.ai please.");
    expect(redactions).toEqual(["xsupport@muso.ai"]);
  });

  it("does not allow a subdomain of muso.ai (nick@mail.muso.ai)", () => {
    const { body, redactions } = sanitizeOutboundBody("Contact nick@mail.muso.ai for help.");
    expect(body).toBe("Contact support@muso.ai for help.");
    expect(redactions).toEqual(["nick@mail.muso.ai"]);
  });

  it("does not allow a TLD-extension bypass (support@muso.ai.evil.com)", () => {
    const { body, redactions } = sanitizeOutboundBody("Email support@muso.ai.evil.com please.");
    expect(body).toBe("Email support@muso.ai please.");
    expect(redactions).toEqual(["support@muso.ai.evil.com"]);
  });

  it("empty string input returns empty body and no redactions", () => {
    const { body, redactions } = sanitizeOutboundBody("");
    expect(body).toBe("");
    expect(redactions).toEqual([]);
  });

  it("redacts plus-addressed non-allowlist email (nick+tag@muso.ai)", () => {
    const { body, redactions } = sanitizeOutboundBody("Forward to nick+filter@muso.ai thanks.");
    expect(body).toBe("Forward to support@muso.ai thanks.");
    expect(redactions).toEqual(["nick+filter@muso.ai"]);
  });

  it("redacts plus-addressed variants of allowlist entries (support+tag@muso.ai is not 'support@muso.ai')", () => {
    const { body, redactions } = sanitizeOutboundBody("Try support+billing@muso.ai.");
    expect(body).toBe("Try support@muso.ai.");
    expect(redactions).toEqual(["support+billing@muso.ai"]);
  });

  // Non-string input guard: channel.ts's sendText callback receives `text: any`,
  // so a null/undefined/object could reach the sanitizer. Must not throw and
  // must not bypass — returns the safe replacement address with a typed marker
  // in redactions so callers see something surfaceable.
  it("non-string input is coerced to the safe replacement and marked in redactions", () => {
    const { body, redactions } = sanitizeOutboundBody(null as unknown as string);
    expect(body).toBe("support@muso.ai");
    expect(redactions).toEqual(["<non-string body: object>"]);
  });

  it("undefined input is coerced to the safe replacement", () => {
    const { body, redactions } = sanitizeOutboundBody(undefined as unknown as string);
    expect(body).toBe("support@muso.ai");
    expect(redactions).toEqual(["<non-string body: undefined>"]);
  });

  // ReDoS defense: 100 KB pathological input with overlapping-class emails
  // stalls the regex engine for 25 s+ without the length cap. The cap
  // (currently 16 KB) bounds the worst case to ~300 ms on Node 20 — still
  // imperfect, but a world away from hanging the event loop. Assertion is
  // 1 s to give CI margin; if the cap is ever removed outright, the
  // pathological input will blow past that trivially.
  it("caps input length to prevent catastrophic regex backtracking (ReDoS)", () => {
    const pathological = "a".repeat(50_000) + "@" + "b".repeat(50_000);
    const start = Date.now();
    const { body, redactions } = sanitizeOutboundBody(pathological);
    const elapsed = Date.now() - start;
    expect(elapsed).toBeLessThan(1000);
    expect(body.length).toBeLessThanOrEqual(16_000);
    // Truncation is surfaced to the caller so the log line shows data loss.
    expect(redactions.some((r) => r.startsWith("<truncated:"))).toBe(true);
  });

  it("short bodies are not flagged as truncated", () => {
    const { redactions } = sanitizeOutboundBody("Normal reply, no emails.");
    expect(redactions.every((r) => !r.startsWith("<truncated:"))).toBe(true);
    expect(redactions).toEqual([]);
  });

  it("truncation marker appears alongside regular redactions", () => {
    const pathological = "contact nick@muso.ai " + "x".repeat(20_000);
    const { redactions } = sanitizeOutboundBody(pathological);
    expect(redactions).toContain("nick@muso.ai");
    expect(redactions.some((r) => r.startsWith("<truncated:"))).toBe(true);
  });

  it("scrubs jan@muso.ai (removed from allowlist 2026-05-11)", () => {
    const result = sanitizeOutboundBody("Email Jan at jan@muso.ai for help.");
    expect(result.body).toBe("Email Jan at support@muso.ai for help.");
    expect(result.redactions).toEqual(["jan@muso.ai"]);
  });

  it("allows support@muso.ai unchanged", () => {
    const result = sanitizeOutboundBody("Email support@muso.ai.");
    expect(result.body).toBe("Email support@muso.ai.");
    expect(result.redactions).toEqual([]);
  });
});

import { describe, it, expect } from "vitest";
import { sanitizeInternalReference } from "../src/sanitize-internal-reference.js";
import { MockIntercomClient, SanitizingIntercomClient } from "../src/outbound.js";

// Real ClickUp task ids from the support list (MUS-6591). Each must be rewritten.
const REAL_IDS = [
  "869fep919", "869ff2ngc", "869fedfqt", "869fdvuzj", "869fbjr3n",
  "869fbh0vb", "869fbgqac", "869fbg98f", "869fbffx8", "869dggdzj",
];

describe("sanitizeInternalReference", () => {
  it("rewrites each real ClickUp id and never leaves it in the body", () => {
    for (const id of REAL_IDS) {
      const out = sanitizeInternalReference(`Thanks, we have noted it under ${id} for you.`);
      expect(out.body).not.toContain(id);
      expect(out.body).toBe("Thanks, we have noted it under our records for you.");
      expect(out.redactions).toEqual([id]);
    }
  });

  it("rewrites the 9 Oct Sony reply shape (label + backticks) and keeps the sentence readable", () => {
    const out = sanitizeInternalReference("I've added the details to your existing request, reference `869fep919`.");
    expect(out.body).toBe("I've added the details to your existing request, our records.");
    expect(out.redactions).toEqual(["869fep919"]);
  });

  it("rewrites every occurrence and records each", () => {
    const out = sanitizeInternalReference("869fep919 and 869ff2ngc.");
    expect(out.body).toBe("our records and our records.");
    expect(out.redactions).toEqual(["869fep919", "869ff2ngc"]);
  });

  // Adversarial non-ids. Each is a shape a customer or Caroline legitimately writes.
  const SAFE: Array<[string, string]> = [
    ["long number: 869123456789", "a phone/long numeric string starting 86x must not match"],
    ["all-digit 9-char order number 869123456", "order numbers are digit runs; ids always contain a letter"],
    ["order #86912345", "8-char order number, wrong length"],
    ["hex colour #869fep91 / #86a9c1ff", "CSS hex colours begin 86 and are 6/8 chars"],
    ["uuid 86a9c1f0-3b2e-4c11-9d7a-5e8f1a2b3c4d", "a UUID group must not be cut out; hyphen is not a boundary"],
    ["uuid tail 5e8f1a2b3-869fep919-x", "id-like run glued to hyphenated token"],
    ["ISRC USUM71703861", "ISRCs are 12 chars and embed 86x digits"],
    ["spotify 4uLU6hMCjMI75M1A2tKUQC", "22-char base62 ids can contain 86x runs"],
    ["spotify 7ouMYWpwJ422jRcDASZB7P and 869fep91x9fep919", "longer alnum run must not be bitten into"],
    ["track length 86:12 and 3:869", "durations/timestamps"],
    ["it was 1869fep919 and 869fep9190", "id-like run inside a longer token"],
    ["UPPERCASE 869FEP919", "ClickUp ids are lowercase; uppercase is a different token"],
    ["the 86th street, 860 releases, 8,600 streams, 869 plays", "ordinary prose and numbers"],
    ["email a869fep919@x.com", "id embedded in an email local part"],
  ];
  for (const [text, why] of SAFE) {
    it(`leaves untouched: ${why}`, () => {
      const out = sanitizeInternalReference(text);
      expect(out.body).toBe(text);
      expect(out.redactions).toEqual([]);
    });
  }

  it("is idempotent", () => {
    const once = sanitizeInternalReference("see 869fep919 please");
    const twice = sanitizeInternalReference(once.body);
    expect(twice.body).toBe(once.body);
    expect(twice.redactions).toEqual([]);
  });

  it("tolerates a non-string body", () => {
    expect(sanitizeInternalReference(undefined as unknown as string).body).toBe("");
  });
});

describe("internal reference sanitizer on the flush path", () => {
  it("replyToConversation rewrites the id and logs one audit line", async () => {
    // The id was filed in this conversation, so the handoff guard keeps it and this
    // pass is the one that must catch it (an unfiled id gets the honest fallback instead).
    const IDS_KEY = "__musoSupportTicketIds";
    const g = globalThis as unknown as Record<string, unknown>;
    g[IDS_KEY] = new Map([["conv_ir1", { atMs: Date.now(), ids: ["869fep919"] }]]);
    const inner = new MockIntercomClient();
    const logged: string[] = [];
    const client = new SanitizingIntercomClient(inner, { error: (m) => logged.push(m) });
    await client.replyToConversation({
      conversationId: "conv_ir1",
      adminId: "admin_1",
      body: "Your details are under reference 869fep919.",
    });
    const sent = inner.calls.replyToConversation[0].body;
    expect(sent).not.toContain("869fep919");
    expect(sent).toBe("Your details are under our records.");
    const lines = logged.filter((m) => m.includes("[intercom:internal-reference]"));
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("conv=conv_ir1");
    expect(lines[0]).toContain("count=1");
    expect(lines[0]).toContain('rewritten=["869fep919"]');
    delete g[IDS_KEY];
  });

  it("closeConversation note is sanitized too", async () => {
    const inner = new MockIntercomClient();
    const client = new SanitizingIntercomClient(inner);
    await client.closeConversation({ conversationId: "c", adminId: "a", body: "Done, 869fep919." });
    expect(inner.calls.closeConversation[0].body).toBe("Done, our records.");
  });
});

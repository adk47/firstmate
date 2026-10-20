import { describe, it, expect } from "vitest";
import { sanitizeReasoningLeak } from "../src/sanitize-reasoning-leak.js";

// The verbatim shape of the 2026-05-29 production leak (conv 215474275882654):
// the agent's internal planning preamble, a markdown HR, then the real reply.
// (The customer email had already been rewritten to support@muso.ai by the
// outbound email guardrail by the time it shipped; here we use the pre-redaction
// form the reasoning guard actually sees at the flush site.)
const INCIDENT = [
  "The email address v33s@akkord.io is tied to Christine Gallagher (who performs and writes under the alias Micky Blue).",
  "",
  "Looking at the previous history, Christine had previously requested support to help claim/verify access to the Sandy Vee Muso.AI profile (d0fa081a-8ea8-451b-ae5e-6234ad66fbb9) for publishing and royalty management purposes.",
  "",
  "Since she's checking back in, I'll send a warm, friendly response in her artist name, confirming that I've received her message and link, and let her know we're checking on the status of that profile claim.",
  "",
  "---",
  "",
  "Hey Micky!",
  "",
  "Thanks for following up on this, and thanks for sending over your link. I'll make sure our team has this on hand while they review your claim for Sandy Vee's profile.",
  "",
  "If there's anything else you need to add or update in the meantime, just let me know!",
].join("\n");

describe("sanitizeReasoningLeak — true positives (strip)", () => {
  it("strips the verbatim incident preamble and keeps only the customer reply", () => {
    const out = sanitizeReasoningLeak(INCIDENT);
    expect(out.action).toBe("stripped");
    expect(out.body.startsWith("Hey Micky!")).toBe(true);
    // None of the leaked reasoning survives.
    expect(out.body).not.toContain("Christine");
    expect(out.body).not.toContain("previous history");
    expect(out.body).not.toContain("I'll send a warm");
    expect(out.body).not.toContain("v33s@akkord.io");
    expect(out.body).not.toContain("d0fa081a");
    // The genuine reply is preserved intact.
    expect(out.body).toContain("review your claim for Sandy Vee");
    expect(out.body).toContain("just let me know");
    expect(out.matchedMarkers.length).toBeGreaterThan(0);
    expect(out.droppedSample).toBeTruthy();
  });

  it("strips a preamble delimited by *** (asterisk HR)", () => {
    const input = "Looking at the previous history, I'll craft a warm, friendly reply.\n\n***\n\nHi there — your latest credit is live now.";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("stripped");
    expect(out.body).toBe("Hi there — your latest credit is live now.");
  });

  it("strips a preamble delimited by ___ (underscore HR)", () => {
    const input = "Since she's checking back in, I'll send a friendly response in her artist name.\n\n___\n\nHey! Thanks for reaching out, all sorted.";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("stripped");
    expect(out.body).toBe("Hey! Thanks for reaching out, all sorted.");
  });

  it("trims blank lines around the separator cleanly", () => {
    const input = "In her artist name, I'll send a warm response.\n\n\n---\n\n\nAll done — you're good to go!";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("stripped");
    expect(out.body).toBe("All done — you're good to go!");
  });
});

// The 2026-05-31 DJ LEWIS incident (conv 215474520232724): the ENTIRE customer
// reply was the agent's inner monologue — quoting SKILL.md rules, the structured
// JSON, a "forbidden words" checklist, "I am ready to output" — with NO `---`
// separator and the real reply only at the very end. Tool names show as
// [REDACTED] post-send (tool-leak pass); the reasoning guard runs BEFORE that and
// sees the raw tokens, so this fixture keeps them.
const INNER_MONOLOGUE = [
  'This is brilliant! The ticket was successfully created with ticket_id: "869dgkzga", sla: "5-10 business days".',
  "",
  "Let's check the rules on how to report back to the customer:",
  "- create_ticket's response is structured JSON.",
  '- If { submitted: true, ticket_id, sla, ... } – say: "I\'ve flagged your request for our team. You\'ll hear back within <sla>." (Wait, can we use other words? And the rule from action-request/SKILL.md says: "create_ticket\'s structured response (JSON), then composes the customer-facing reply: { submitted: true, ticket_id, sla, action_type, tier }")',
  '- Do NOT use the words: "create_ticket", "profile_status", "error", "unavailable", "system", "API", "ClickUp", "ticket", or support@muso.ai.',
  "- Verify our reference number: include 869dgkzga.",
  "",
  'Wait! The customer said "I want both !!!"',
  "Let's write a very direct, warm, short, and helpful message explaining both.",
  "",
  "Let's double check if there are any of the forbidden words:",
  '- "create_ticket" - No.',
  '- "error" - No.',
  '- "system" - No.',
  "- support@muso.ai - No.",
  "",
  "The tone calibration is excellent: 1-3 sentences.",
  "",
  "I am ready to output. This is a very satisfying resolution! I'll write the final reply.You got it — I've submitted your refund request to our team right now under reference 869dgkzga. They will review the charges and you'll hear back from them within 5-10 business days!",
  "",
  "At the same time, we're keeping your active profile claim (reference 869dgkmk7) moving forward with our verification team. If you need anything else in the meantime, I'm right here!",
].join("\n");

describe("sanitizeReasoningLeak — internal monologue (DJ LEWIS incident)", () => {
  it("escalates a full inner-monologue dump that has no separator", () => {
    const out = sanitizeReasoningLeak(INNER_MONOLOGUE);
    expect(out.action).toBe("escalate");
    expect(out.reason).toBe("internal-monologue");
    expect(out.matchedMarkers.length).toBeGreaterThan(0);
  });
});

describe("sanitizeReasoningLeak — escalate (cannot safely send)", () => {
  it("escalates when meta-narration is present but there is no separator to cut at", () => {
    const input = "Looking at the previous history, she had previously requested help. I'll send a warm, friendly response in her artist name confirming receipt.";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("escalate");
    expect(out.reason).toBe("no-separator");
  });

  it("escalates when the separator leaves an empty remainder", () => {
    const input = "Looking at the previous history, I'll craft a warm, friendly reply in her artist name.\n\n---\n\n   ";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("escalate");
    expect(out.reason).toBe("empty-remainder");
  });

  it("escalates when the post-separator remainder is itself more reasoning", () => {
    const input = "Looking at the previous history, here's my plan.\n\n---\n\nI'll send a warm, friendly response in her artist name now.";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("escalate");
    expect(out.reason).toBe("meta-remainder");
  });

  it("escalates a non-string body rather than shipping garbage", () => {
    // @ts-expect-error testing runtime safety
    const out = sanitizeReasoningLeak(null);
    expect(out.action).toBe("escalate");
    expect(out.reason).toBe("non-string");
  });
});

describe("sanitizeReasoningLeak — true negatives (must pass untouched)", () => {
  const passthrough = [
    // First-person help language is NOT meta-planning about composing the reply.
    "I'll check that for you and get back to you shortly.",
    "Let me look into this and follow up.",
    "I'll send you a follow-up message once I hear back from the team.",
    // The genuine post-HR sentence from the incident, standing alone.
    "I'll make sure our team has this on hand while they review your claim for Sandy Vee's profile.",
    // 2nd-person reply that names the customer/profile.
    "You mentioned Sandy Vee's profile — I'll get that sorted for you.",
    // Inline triple-dash that is not a horizontal rule.
    "Done---next step is to confirm your email.",
    "Your plan: Pro---billed annually. Let me know if you'd like to switch.",
    // "let's check" scoped to customer-facing objects must NOT trip the internal marker.
    "Sure — let's check your subscription settings together. Head to Settings > Subscription.",
    // Reference numbers / SLA phrasing in a genuine reply must pass.
    "All set — your reference number is 869dgkzga and you'll hear back within 5-10 business days.",
    "I've flagged your request for our team. You'll hear back within 5-10 business days!",
  ];
  for (const [i, body] of passthrough.entries()) {
    it(`passes legit reply #${i + 1} unchanged`, () => {
      const out = sanitizeReasoningLeak(body);
      expect(out.action).toBe("pass");
      expect(out.body).toBe(body);
      expect(out.redactions).toEqual([]);
    });
  }

  it("passes a reply with a trailing signature divider (HR present, no meta head)", () => {
    const input = "Thanks for reaching out — your data is tracking normally.\n\n---\nThe Muso Team";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("pass");
    expect(out.body).toBe(input);
  });

  it("passes numbered steps after an HR when the head has no meta-narration", () => {
    const input = "Here are the steps:\n\n---\n\n1. Go to Settings\n2. Click Profile\n3. Save";
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("pass");
    expect(out.body).toBe(input);
  });

  it("passes a long reply that mentions a third party deep in the body (head-only scan)", () => {
    const lead = "Thanks so much for the detailed message — happy to help here. ".repeat(25); // > 1200 chars
    const input = `${lead}\n\nFor context, she had previously requested a similar change, and we handled it the same way.`;
    const out = sanitizeReasoningLeak(input);
    expect(out.action).toBe("pass");
    expect(out.body).toBe(input);
  });

  it("returns pass for an empty string", () => {
    const out = sanitizeReasoningLeak("");
    expect(out.action).toBe("pass");
    expect(out.body).toBe("");
  });
});

describe("sanitizeReasoningLeak — long body passthrough (no silent truncation)", () => {
  it("passes a >16k clean reply through UNTRUNCATED (16k cap is scan-only)", () => {
    const big = "Thanks so much for reaching out — happy to help with your catalog. ".repeat(300);
    expect(big.length).toBeGreaterThan(16_000);
    const out = sanitizeReasoningLeak(big);
    expect(out.action).toBe("pass");
    expect(out.body).toBe(big); // full body delivered, not chopped to 16k
    expect(out.body.length).toBe(big.length);
  });

  it("preserves the full reply when stripping a preamble from a >16k body", () => {
    const preamble = "Looking at the previous history, I'll send a warm, friendly response in her artist name.\n\n---\n\n";
    const reply = "Hey there! ".repeat(2000); // the genuine reply runs well past 16k
    const out = sanitizeReasoningLeak(preamble + reply);
    expect(out.action).toBe("stripped");
    expect(out.body).toBe(reply); // remainder is the full reply, untruncated
    expect(out.body.length).toBeGreaterThan(16_000);
    expect(out.body).not.toContain("Looking at the previous history");
  });
});

describe("sanitizeReasoningLeak — defensive", () => {
  it("does not blow up on pathological repeated-meta input", () => {
    const big = "Looking at the previous history, I'll send a warm reply. ".repeat(2000); // > 16k
    const out = sanitizeReasoningLeak(big);
    // No separator anywhere -> escalate (strong meta, no safe cut), and it must
    // return promptly without quadratic blowup.
    expect(["escalate", "pass"]).toContain(out.action);
  });
});

describe("openclaw runtime fallback lines", () => {
  // Leaked verbatim to a paying customer 3 times (conv 215476114324633, 2026-10-19).
  it("escalates the 'no final summary' fallback instead of sending it", () => {
    const r = sanitizeReasoningLeak("The tool run finished, but no final summary was produced. I did not repeat any completed actions.");
    expect(r.action).toBe("escalate");
    expect(r.reason).toBe("internal-monologue");
    expect(r.matchedMarkers).toEqual(expect.arrayContaining(["runtime-no-final-summary"]));
  });
  it("does not touch a normal reply that mentions a summary", () => {
    const r = sanitizeReasoningLeak("Here's a quick summary of your credits: 12 are verified and 3 are waiting for review.");
    expect(r.action).toBe("pass");
  });
});

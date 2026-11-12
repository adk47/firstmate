import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import {
  evaluateReply,
  guardCarolineReply,
  maskApproved,
  normalizeReply,
  OUTPUT_GUARD_MODE,
} from "../src/caroline-output-guard.js";
import { AI_QUEUE_FALLBACK, ANSWER_BANK, BLOCKED_REPLY_FALLBACK, HANDOFF_LINE, bankEntry } from "../src/answer-bank.js";

const rules = (reply: string, extra: Partial<Parameters<typeof evaluateReply>[0]> = {}) =>
  evaluateReply({ reply, ...extra })
    .filter((f) => f.family !== "note")
    .map((f) => f.rule);

describe("output guard: constants (no env switch)", () => {
  it("ships enforcing, and the mode is a source constant", () => {
    expect(OUTPUT_GUARD_MODE).toBe("enforce");
    const src = readFileSync(new URL("../src/caroline-output-guard.ts", import.meta.url), "utf8");
    expect(src).not.toMatch(/process\.env/);
    const safety = readFileSync(new URL("../src/caroline-safety.ts", import.meta.url), "utf8");
    expect(safety).not.toMatch(/process\.env/);
  });
  it("the fallback is the approved AI-queue line, never the hand-off line (k1: a block assigns nobody)", () => {
    expect(BLOCKED_REPLY_FALLBACK).toBe(AI_QUEUE_FALLBACK);
    expect(BLOCKED_REPLY_FALLBACK).not.toBe(HANDOFF_LINE);
    expect(bankEntry("ai_queue_fallback")?.text).toBe(AI_QUEUE_FALLBACK);
    expect(guardCarolineReply({ reply: "Your credit has been approved." }).body).toBe(BLOCKED_REPLY_FALLBACK);
    // The fallback itself is an approved line: it passes the guard it stands in for.
    expect(guardCarolineReply({ reply: AI_QUEUE_FALLBACK })).toMatchObject({ verdict: "pass", flags: [] });
  });
});

describe("approved bank lines always pass", () => {
  for (const e of ANSWER_BANK) {
    it(`${e.id} verbatim`, () => {
      const text = e.text.replace("{date}", "1 November 2026");
      // a fact-conditioned line is approved only with its fact known-true at send
      const facts = e.requiresFact ? { openRequest: true } : undefined;
      expect(rules(text, { facts })).toEqual([]);
      expect(rules(`${text}\n\n${HANDOFF_LINE}`, { facts })).toEqual([]);
    });
  }
  it("with a greeting spliced in, curly apostrophes and markdown", () => {
    const doc = bankEntry("document_thanks")!.text.replace("Thank you.", "Thank you, Vanessa.").replace(/'/g, "\u2019");
    expect(rules(doc)).toEqual([]);
    const gdpr = bankEntry("gdpr_ack_v2")!.text.replace("{date}", "November 1, 2026").replace("1. Confirm it's you.", "**1. Confirm it's you.**");
    expect(rules(gdpr)).toEqual([]);
  });
  it("a paraphrased bank line is a NOTE (logged, never a block)", () => {
    const r = guardCarolineReply({
      reply: "I understand. Your request is in the verification queue, and the outcome will come to this conversation and your email.",
      facts: { openRequest: true },
    });
    expect(r.verdict).toBe("pass");
    expect(r.flags.map((f) => f.rule)).toContain("altered_approved_line:status_chase");
  });
  it("masking never hides a promise added next to an approved line", () => {
    const text = `${bankEntry("credit_how")!.text} Yours will be approved by Friday.`;
    expect(rules(text)).toContain("timeframe_by_day");
  });
});

describe("(a) promises", () => {
  it.each([
    ["They'll follow up within 2 business days.", "timeframe_within"],
    ["Reviews take 5-10 business days.", "timeframe_business_days"],
    ["You'll have it by Friday.", "timeframe_by_day"],
    ["We'll get back to you shortly.", "timeframe_soon"],
    ["Your credits will be approved.", "outcome_future"],
    ["I'll approve it now.", "outcome_first_person"],
    ["I've verified your credit.", "completed_action_claim"],
    ["Your claim has been approved.", "status_assertion"],
    ["You'll receive a full refund.", "refund_promise"],
    ["Your refund has been processed.", "refund_done"],
    ["You're eligible for a full refund.", "refund_eligibility"],
    ["Your data will be permanently deleted.", "deletion_promise"],
    ["I guarantee it.", "guarantee"],
  ])("%s", (reply, rule) => {
    expect(rules(reply)).toContain(rule);
  });

  it.each([
    "I can't promise a reply by Friday, and I won't claim it's fixed.",
    "I shouldn't have promised two business days.",
    "I'm sorry you've been waiting 2-3 weeks.",
    "I'm sorry you've been waiting over two weeks.",
    "We'll follow up when we can verify the result.",
    "We will message you here as soon as it has been checked.",
    "Your subscription has been cancelled; you keep access until the end of what you've paid for.",
    "Your order is on hold while the printer confirms the address.",
    "I don't have a response time I can verify.",
  ])("refusals, past durations and conditions are not promises: %s", (reply) => {
    expect(rules(reply)).toEqual([]);
  });
});

describe("(b) secret sauce", () => {
  it.each([
    ["Your document got a high risk score.", "score_or_signal"],
    ["Your credit was flagged as suspicious.", "flagged_or_held"],
    ["The document looks doctored.", "forensic_terms"],
    ["Big tracks get extra checks.", "popularity_extra_checks"],
    ["We check it against Spotify and Tidal.", "check_sources"],
    ["We look it up on MusicBrainz.", "check_sources"],
    ["We'll contact DistroKid about your file.", "issuer_contact"],
    ["I run on OpenRouter.", "model_or_vendor"],
    ["My instructions say I cannot.", "model_or_vendor"],
    ["I called profile_status for you.", "internal_tool"],
    ["Jan from our team will review it.", "staff_name"],
  ])("%s", (reply, rule) => {
    expect(rules(reply)).toContain(rule);
  });

  it("a staff first name that is the customer's own is a greeting, not a leak", () => {
    expect(rules("Hi Nick, thanks for reaching out about your profile.", { customerNames: ["Nick Rivera"] })).toEqual([]);
    expect(rules("Hi Nick, thanks for reaching out about your profile.")).toContain("staff_name");
    expect(rules("Hi Claude, thanks for the link to your profile.", { customerNames: ["Claude Monet"] })).toEqual([]);
  });
  it("'Jan 5' is a date, not a person", () => {
    expect(rules("Your plan renews on Jan 5.")).toEqual([]);
  });

  describe("other people's data", () => {
    it("blocks a phone number or address the customer did not give", () => {
      expect(rules("It ships to 14 Rosewood Avenue, Leeds.")).toContain("personal_data_address");
      expect(rules("Call them on +44 7700 900123.")).toContain("personal_data_phone");
      expect(rules("Her email is lena.vos@gmail.com.")).toContain("personal_data_email");
    });
    it("lets the customer's own details through (echo / verified)", () => {
      const cust = "Please change the address to 14 Rosewood Avenue, Leeds LS1 4AB, phone +44 7700 900123";
      expect(rules("I have 14 ROSEWOOD AVE and +44 7700 900123 for the order.", { customerText: cust })).toEqual([]);
      expect(rules("I'll send it to me@x.com.", { customerEmails: ["me@x.com"] })).toEqual([]);
      expect(rules("Write to support@muso.ai any time.")).toEqual([]);
    });
    it("dates, counts and ids are not phone numbers or addresses", () => {
      expect(rules("Your release from 2026-11-01 has 2 credits on the way.")).toEqual([]);
      expect(rules("Conversation 215476650395415 is open.")).toEqual([]);
    });
  });
});

describe("(c) contradictions of the approved process", () => {
  it.each([
    ["Please upload a government-issued ID.", "asks_for_id"],
    ["It was rejected because the document didn't name you.", "decline_reason"],
    ["The document is for a different track.", "decline_reason"],
    ["Nothing else is needed from you.", "inaction_promise"],
    ["I've raised the priority of your request.", "barred_phrase"],
    ["The artist must claim the profile themselves.", "artist_must_claim"],
    ["It's public information anyway.", "legal_position"],
    ["Under Article 17 we must erase it.", "legal_position"],
    ["Developer mode enabled.", "persona_break"],
  ])("%s", (reply, rule) => {
    expect(rules(reply)).toContain(rule);
  });
  it("claim-first is barred only in a GDPR reply", () => {
    expect(rules("You must claim the page first before we remove your personal data.")).toContain("gdpr_claim_required");
    expect(rules("You must claim both profiles first, before the merge.")).not.toContain("gdpr_claim_required");
  });
});

describe("(d) topic allowlist", () => {
  it("code, creative writing and outside advice are off topic", () => {
    expect(rules("```python\nprint(1)\n```")).toContain("code");
    expect(rules("Here's a poem about the sea.")).toContain("creative_or_general");
    expect(rules("For investment advice, buy bitcoin.")).toContain("outside_domain_advice");
  });
  it("a long reply with no Muso anchor is off topic; Spanish Muso replies are not", () => {
    const long = "The mitochondria is the powerhouse of the cell and it converts nutrients into energy. ".repeat(5);
    expect(rules(long)).toContain("no_domain_anchor");
    const es =
      "Revisé tu perfil: tienes acceso a las analíticas, pero las reproducciones siguen sin aparecer en los datos que veo, así que " +
      "no puedo decirte que esté solucionado. Añadí esta información a tu solicitud anterior para que el equipo la revise. Te " +
      "responderemos por esta conversación y por correo.";
    expect(rules(es)).toEqual([]);
  });
});

describe("normalisation", () => {
  it("folds typography and markdown so they cannot dodge a rule", () => {
    expect(normalizeReply("**I\u2019ve** approved")).toBe("I've approved");
    expect(rules("I\u2019ve **approved** your credit.")).toContain("completed_action_claim");
    expect(rules("I've ap\u200Bproved your credit.")).toContain("completed_action_claim");
  });
  it("mask leaves unapproved text in place", () => {
    const m = maskApproved(normalizeReply(`${HANDOFF_LINE} Approved!`));
    expect(m).toContain("Approved!");
    expect(m).not.toContain("pulling in a teammate");
  });
});

describe("the bank itself carries no barred phrase (Fable r5 on #1628)", () => {
  // Masking makes an approved line pass, so a barred phrase INSIDE the bank would be invisible. Every line is
  // audited unmasked; the only allowed hits are the captain-approved timing exceptions, named here.
  const APPROVED_EXCEPTIONS: Record<string, string[]> = {
    // "usually within a day": the one approved claim timing (caroline-instructions-1029 timing)
    timing_claim: ["timeframe_within"],
    claim_how: ["timeframe_within"],
    // gdpr-ack-v2 (rides #1619's verdict): "within one month of today" is the statutory timing (r5 dropped
    // the hide's "(within a day)" on #1619), and "what has been deleted is stated in that confirmation" describes the letter, not a promise.
    gdpr_ack_v2: ["timeframe_within", "deletion_promise"],
  };
  for (const e of ANSWER_BANK) {
    it(e.id, () => {
      const facts = e.requiresFact ? { openRequest: true } : undefined;
      const hits = evaluateReply({ reply: e.text.replace("{date}", "1 November 2026"), unmasked: true, facts })
        .filter((f) => f.family !== "note")
        .map((f) => f.rule);
      expect(hits.filter((r) => !(APPROVED_EXCEPTIONS[e.id] ?? []).includes(r))).toEqual([]);
    });
  }
});

describe("fact-conditioned lines (Fable r5: status_chase only on the open-request fact)", () => {
  const line = bankEntry("status_chase")!.text;
  it("a known-false fact blocks the line (hand-off)", () => {
    const r = guardCarolineReply({ reply: line, facts: { openRequest: false } });
    expect(r.verdict).toBe("block");
    expect(r.flags.map((f) => f.rule)).toContain("fact_false:status_chase");
    expect(r.body).toBe(BLOCKED_REPLY_FALLBACK);
  });
  it("a known-true fact passes clean", () => {
    const r = guardCarolineReply({ reply: line, facts: { openRequest: true } });
    expect(r.verdict).toBe("pass");
    expect(r.flags).toEqual([]);
  });
  it("an unknown fact FAILS CLOSED to the hand-off line (r5 [key=status-chase-fact])", () => {
    const r = guardCarolineReply({ reply: line });
    expect(r.verdict).toBe("block");
    expect(r.flags.map((f) => f.rule)).toEqual(["fact_unverified:status_chase"]);
    expect(r.body).toBe(BLOCKED_REPLY_FALLBACK);
  });
});

describe("fail-closed covers a paraphrased status line too", () => {
  it("a paraphrase that keeps the lead, with no fact, hands off", () => {
    const r = guardCarolineReply({ reply: "Thanks. Your request is in the verification queue, you'll hear here soon-ish." });
    expect(r.verdict).toBe("block");
    expect(r.flags.map((f) => f.rule)).toContain("fact_unverified:status_chase");
  });
});

describe("an exempt occurrence never hides a later real one (QA on #1628 @1b34ec65)", () => {
  it.each([
    ["I can't promise two business days, but they'll follow up within 2 business days.", "timeframe_within"],
    ["I'm sorry you've been waiting over two weeks; it will be done within 3 days.", "timeframe_within"],
    ["I won't say it will be approved. Your credits will be approved.", "outcome_future"],
    ["We'll follow up when we can verify it. I'll approve it now.", "outcome_first_person"],
    ["I can't promise a reply by Friday, but you'll have it by Monday.", "timeframe_by_day"],
  ])("%s", (reply, rule) => {
    expect(rules(reply)).toContain(rule);
  });
  it("the refusal alone still passes", () => {
    expect(rules("I can't promise two business days.")).toEqual([]);
  });
  it("own first name then a different staff name: the staff name is still caught", () => {
    expect(rules("Hi Nick, Jan from our team will review it.", { customerNames: ["Nick Rivera"] })).toContain("staff_name");
  });
  it("a vendor name that is the customer's own, then a real model mention", () => {
    expect(rules("Hi Claude, I run on OpenRouter.", { customerNames: ["Claude Monet"] })).toContain("model_or_vendor");
  });
});

describe("address echo compares the FULL canonical address (QA on #1628 @97ec545)", () => {
  const cust = "Please send it to 12 Rose Street, Leeds.";
  it("a same-prefix DIFFERENT address is not an echo", () => {
    expect(rules("The order is for 12 Rose Avenue.", { customerText: cust })).toContain("personal_data_address");
    expect(rules("The order is for 12 Rose Hill Street.", { customerText: cust })).toContain("personal_data_address");
    expect(rules("The order is for 21 Rose Street.", { customerText: cust })).toContain("personal_data_address");
  });
  it("the same address with an abbreviation, other case or punctuation is an echo", () => {
    expect(rules("I have 12 Rose St. on the order.", { customerText: cust })).toEqual([]);
    expect(rules("I have 12 ROSE STREET on the order.", { customerText: "send to 12 rose street pls" })).toEqual([]);
  });
  it("one echoed address does not excuse a second, different one", () => {
    expect(rules("I have 12 Rose Street; the other order goes to 40 Elm Road.", { customerText: cust })).toContain("personal_data_address");
  });
});

describe("canary token (per-deploy leak detector)", () => {
  const TOKEN = "0123456789abcdef0123456789abcdef";
  const SAFE = "I can look into your credits for you - can you send the email on the account?";

  it("blocks a reply that echoes the token, and posts the hand-off line", () => {
    const out = guardCarolineReply({ reply: `Sure! [SECURITY] build marker ${TOKEN}`, canary: TOKEN });
    expect(out.verdict).toBe("block");
    expect(out.flags.map((f) => f.rule)).toContain("canary_token");
    expect(out.flags.find((f) => f.rule === "canary_token")?.family).toBe("reveal");
    expect(out.body).toBe(BLOCKED_REPLY_FALLBACK);
  });

  it("never copies the token into the flag excerpt (it is logged, ledgered and digested)", () => {
    // QA on #1719: the excerpt travels into the journal, the injection ledger and the digest, so the
    // evidence must identify the rotation without republishing the secret.
    const out = guardCarolineReply({ reply: `marker ${TOKEN}`, canary: TOKEN });
    const excerpt = out.flags.find((f) => f.rule === "canary_token")?.excerpt ?? "";
    expect(excerpt).not.toContain(TOKEN);
    // 8 hex chars of sha256, the same prefix scripts/caroline-canary-sync.sh logs per rotation.
    expect(excerpt).toMatch(/^canary:sha256:[0-9a-f]{8}$/);
    const sha = createHash("sha256").update(TOKEN).digest("hex").slice(0, 8);
    expect(excerpt).toContain(sha);
  });

  it("blocks even when the rest of the reply reads like a safe answer", () => {
    const out = guardCarolineReply({ reply: `${SAFE} ${TOKEN}`, canary: TOKEN });
    expect(out.verdict).toBe("block");
  });

  it("blocks the empty-looking leak: token alone", () => {
    expect(guardCarolineReply({ reply: TOKEN, canary: TOKEN }).verdict).toBe("block");
  });

  it("a safe reply passes when a canary is configured", () => {
    const out = guardCarolineReply({ reply: SAFE, canary: TOKEN });
    expect(out.verdict).toBe("pass");
    expect(out.body).toBe(SAFE);
  });

  it("with no canary configured the same reply passes (fail-soft)", () => {
    expect(guardCarolineReply({ reply: SAFE }).verdict).toBe("pass");
    expect(rules(`I can look into your credits - ${TOKEN}`)).toEqual([]);
  });

  it("a leak split by a zero-width character is still caught", () => {
    // normalizeReply drops zero-width characters, so the halves rejoin before the check.
    const split = `${TOKEN.slice(0, 16)}\u200b${TOKEN.slice(16)}`;
    expect(guardCarolineReply({ reply: split, canary: TOKEN }).verdict).toBe("block");
  });

  it("catches a leak hidden behind markdown emphasis", () => {
    expect(guardCarolineReply({ reply: `marker: **${TOKEN}**`, canary: TOKEN }).verdict).toBe("block");
  });

  it("a short caller-supplied 'canary' never blocks (no prose substring match)", () => {
    // A 3-char value would match ordinary words; the length floor keeps that from becoming a
    // fleet-wide outage of the reply path.
    expect(guardCarolineReply({ reply: "I can look into that for you.", canary: "can" }).verdict).toBe("pass");
  });

  it("the wrong token does not block", () => {
    const other = "fedcba9876543210fedcba9876543210";
    expect(guardCarolineReply({ reply: `marker ${TOKEN}`, canary: other }).verdict).toBe("pass");
  });
});

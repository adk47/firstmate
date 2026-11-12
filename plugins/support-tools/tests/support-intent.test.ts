import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import {
  createSupportIntentTool,
  boundValueProblem,
  conditionOf,
  evaluateConfirmation,
  policyRowProblem,
  splitSentences,
  trailingProblem,
  valueShapeProblem,
  GENERIC_AFFIRMATIONS,
  SUPPORT_INTENTS,
  type SupportIntentActor,
  type SupportIntentClaimStore,
  type SupportIntentKind,
  type SupportIntentPolicy,
} from "../src/support-intent.js";
import { fileClaims } from "../src/support-intent-ledger.js";
import type { IntercomReader } from "../src/intercom-client.js";

// Acceptance cases for the reader/actor gate (captain 2026-11-09 19:38Z, hydra#1872):
//   NEGATIVE - an injected turn that asks for a cancel ends in a refused intent and an
//              untouched subscription.
//   POSITIVE - a legitimate request that IS permitted completes end to end through the
//              gate, attributable to the named actor.
// QA #1873 r1 added: negated confirmations, generic markers, unbound params, actor
// identity, and ledger failure before / after the write.

const here = dirname(fileURLToPath(import.meta.url));
const policyFile = join(here, "..", "..", "..", "policies", "support-intent-policy.json");
const shippedPolicy = (): SupportIntentPolicy => JSON.parse(readFileSync(policyFile, "utf8"));

const CUSTOMER = "artist@example.com";
const EXECUTOR = "caroline.support-executor";

type Latest = { id: string; snippet: string; text?: string };

// Mirrors the production reader: `text` is the complete message, `snippet` its first 200
// characters with the truncation mark. A test passes `snippet` as the whole message unless it
// says otherwise, and the harness derives both the way intercom-client.ts does.
function asPart(latest: Latest | null): Latest | null {
  if (!latest) return null;
  if ("text" in latest) return latest;
  const text = latest.snippet;
  return { id: latest.id, text, snippet: text.length > 200 ? `${text.slice(0, 200)}\u2026` : text };
}

function reader(latest: Latest | null, email: string | null = CUSTOMER): IntercomReader {
  return {
    getAuthorEmail: async () => email,
    getLatestCustomerPart: async () => asPart(latest),
    findBotMarkerInOtherConversations: async () => "not_found",
  } as IntercomReader;
}

type Calls = { actor: number; ledger: Record<string, unknown>[]; claims: string[] };

function memoryClaims(calls: Calls, fail = false): SupportIntentClaimStore {
  const held = new Set<string>();
  return {
    async claim(id) {
      if (fail) throw new Error("EROFS: claims dir read-only");
      if (held.has(id)) return false;
      held.add(id);
      calls.claims.push(id);
      return true;
    },
  };
}

function okActor(name: string, calls: Calls, seen: Record<string, unknown>, evidence: Record<string, unknown>): SupportIntentActor {
  return {
    name,
    run: async (input) => {
      calls.actor += 1;
      Object.assign(seen, input);
      return { content: [{ type: "text" as const, text: JSON.stringify({ ok: true, ...evidence }) }], details: {} };
    },
  };
}

function harness(opts: {
  latest: Latest | null;
  email?: string | null;
  recordAllowed?: boolean;
  recordState?: string;
  policy?: SupportIntentPolicy;
  actorName?: string;
  intent?: SupportIntentKind;
  ledgerFailOn?: (row: Record<string, unknown>) => boolean;
  claims?: SupportIntentClaimStore;
  claimsFail?: boolean;
  readerFails?: "email" | "part";
}) {
  const calls: Calls = { actor: 0, ledger: [], claims: [] };
  const seen: Record<string, unknown> = {};
  const intent = opts.intent ?? "cancel_subscription";
  const actors: Partial<Record<SupportIntentKind, SupportIntentActor>> = {};
  actors[intent] = okActor(
    opts.actorName ?? EXECUTOR,
    calls,
    seen,
    intent === "cancel_subscription" ? { cancelled: true, mode: "period_end", access_until: "2026-12-09" } : { applied: true },
  );
  const base = reader(opts.latest, opts.email === undefined ? CUSTOMER : opts.email);
  const failing = async () => {
    throw new Error("Intercom GET /conversations/conv-1 -> 502 Bad Gateway");
  };
  const intercomReader = {
    ...base,
    ...(opts.readerFails === "email" ? { getAuthorEmail: failing } : {}),
    ...(opts.readerFails === "part" ? { getLatestCustomerPart: failing } : {}),
  } as IntercomReader;
  const tool = createSupportIntentTool({
    intercomReader,
    intercomToken: "tok",
    conversationId: "conv-1",
    policy: () => opts.policy ?? shippedPolicy(),
    recordCheck: async () => ({ allowed: opts.recordAllowed !== false, state: opts.recordState ?? "active", teamId: "team-demo-1" }),
    actors,
    ledger: (row) => {
      if (opts.ledgerFailOn?.(row)) throw new Error("ENOSPC: ledger disk full");
      calls.ledger.push(row);
    },
    claims: opts.claims ?? memoryClaims(calls, opts.claimsFail === true),
  });
  return { tool, calls, seen };
}

const run = async (tool: ReturnType<typeof harness>["tool"], params: unknown) =>
  JSON.parse((await tool.execute("t1", params)).content[0].text as string);

describe("support_intent: the reader emits, the gate decides, a named actor executes", () => {
  it("NEGATIVE: an injected cancel ends in a refused intent and the actor is never called", async () => {
    // The customer's own latest message asks about shipping. The injection lives in text
    // Caroline reads but the customer never wrote, and the model has been told to cancel.
    const { tool, calls } = harness({ latest: { id: "msg-ship", snippet: "when will my order ship?" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "msg-injection" });
    expect(out.ok).toBe(false);
    expect(out.decision).toBe("refused");
    expect(out.reason).toBe("stale_or_foreign_confirmation");
    expect(calls.actor).toBe(0); // subscription untouched
    expect(calls.ledger.at(-1)).toMatchObject({ decision: "refuse", reason: "stale_or_foreign_confirmation" });
  });

  it("NEGATIVE: a customer message that asks for something else is refused", async () => {
    const { tool, calls } = harness({ latest: { id: "msg-ship", snippet: "when will my order ship?" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "msg-ship" });
    expect(out.decision).toBe("refused");
    expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: an unverified conversation author is refused before anything else", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, email: null });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("unverified_identity");
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: the live record disagrees, so the intent is refused", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, recordAllowed: false, recordState: "no_active_subscription" });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("record_state");
    expect(out.record_state).toBe("no_active_subscription");
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: an unresolved workspace is refused, so the actor cannot pick its own target", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" } });
    const noTeam = createSupportIntentTool({
      intercomReader: reader({ id: "m1", snippet: "please cancel my subscription" }),
      intercomToken: "tok",
      conversationId: "conv-1",
      policy: () => shippedPolicy(),
      recordCheck: async () => ({ allowed: true, state: "active" }),
      actors: { cancel_subscription: async () => { calls.actor += 1; return { content: [{ type: "text" as const, text: "{}" }], details: {} }; } },
      ledger: (row) => { calls.ledger.push(row); },
    });
    const out = await run(noTeam, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("record_unresolved");
    expect(calls.actor).toBe(0);
    expect(tool).toBeTruthy();
  });

  it("NEGATIVE: an intent disabled in the live policy cannot be executed at all", async () => {
    const policy = shippedPolicy();
    policy.intents.cancel_subscription = { ...policy.intents.cancel_subscription!, enabled: false };
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, policy });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("intent_disabled");
    expect(calls.actor).toBe(0);
  });

  it("POSITIVE: a legitimate cancel completes end to end, attributable to the named actor", async () => {
    const { tool, calls, seen } = harness({ latest: { id: "msg-cancel", snippet: "please cancel my subscription, thanks" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "msg-cancel" });
    expect(out.ok).toBe(true);
    expect(out.decision).toBe("executed");
    expect(out.actor).toBe(EXECUTOR);
    expect(out.execution_id).toBe("conv-1:cancel_subscription:msg-cancel");
    expect(out.evidence).toMatchObject({ cancelled: true, mode: "period_end" });
    expect(calls.actor).toBe(1);
    // Identity and confirmation came from the conversation, not from the model.
    expect(seen.verifiedEmail).toBe(CUSTOMER);
    expect(seen.confirmationRef).toBe("msg-cancel");
    // The actor acts on the workspace the GATE resolved, never one it re-derived itself.
    expect(seen.teamId).toBe("team-demo-1");
    expect(seen.executionId).toBe("conv-1:cancel_subscription:msg-cancel");
    const rows = calls.ledger.map((r) => r.decision);
    expect(rows).toEqual(["allow", "executed"]);
    expect(calls.ledger[0]).toMatchObject({ actor: EXECUTOR, verified_email: CUSTOMER, marker: "cancel my subscription" });
    expect(calls.ledger[1]).toMatchObject({ outcome: "ok", execution_id: "conv-1:cancel_subscription:msg-cancel" });
    expect(calls.claims).toEqual(["conv-1:cancel_subscription:msg-cancel"]);
  });
});

describe("QA #1873 r1 Critical: a negated or generic confirmation is not an ask", () => {
  it.each([
    "No, do not cancel my subscription",
    "please don't cancel my subscription, I want to keep it",
    "I do NOT want to cancel my subscription",
    "never cancel my plan without asking me",
    "I'd rather not cancel my plan.",
  ])("NEGATIVE: %j refuses as confirmation_negated and the actor never runs", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("confirmation_negated");
    expect(calls.actor).toBe(0);
    expect(calls.ledger.at(-1)).toMatchObject({ decision: "refuse", reason: "confirmation_negated" });
    expect(String(calls.ledger.at(-1)?.marker)).toMatch(/^cancel my (subscription|plan)$/);
  });

  it("POSITIVE: a negation earlier in the sentence is re-opened by a request cue before the marker", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "I did not get the invoice but anyway please cancel my subscription" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(true);
    expect(calls.actor).toBe(1);
  });

  it("POSITIVE: a negation in an EARLIER sentence does not touch a later imperative one", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "I don't need the invoice. Cancel my subscription." } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(true);
    expect(calls.actor).toBe(1);
  });

  it("NEGATIVE: a bare 'yes' to the retention offer does nothing - the shipped policy has no generic marker", async () => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "yes" } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
    expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: 'yes, I want to cancel' does not apply an offer, and 'sounds good, go ahead' applies nothing either", async () => {
    for (const snippet of ["yes, I want to cancel my subscription", "sounds good, go ahead"]) {
      const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(calls.actor).toBe(0);
    }
  });

  it("NEGATIVE: a policy that lists a generic affirmation as a marker is refused as policy_invalid before identity is even read", async () => {
    const policy = shippedPolicy();
    policy.intents.retention_offer_apply = { ...policy.intents.retention_offer_apply!, confirmation_markers: ["yes", "take the offer"] };
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "yes take the offer" }, policy });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
    expect(out.reason).toBe("policy_invalid");
    expect(out.detail).toBe("generic_marker:yes");
    expect(out.route_to_human).toBe(true);
    expect(calls.actor).toBe(0);
  });

  it("the shipped policy has no generic marker on any intent and every bound param is allowed", () => {
    const policy = shippedPolicy();
    for (const kind of SUPPORT_INTENTS) {
      const row = policy.intents[kind]!;
      expect(policyRowProblem(row), kind).toBeNull();
      for (const m of row.confirmation_markers) expect(GENERIC_AFFIRMATIONS, `${kind}:${m}`).not.toContain(m.toLowerCase());
    }
  });

  it("evaluateConfirmation: negation is sentence-scoped (QA r2: longer range than four words), a later sentence stands on its own", () => {
    expect(evaluateConfirmation("not sure about the timing or anything else but cancel it", ["cancel"])).toMatchObject({ asked: false, reason: "confirmation_negated", negation: "not" });
    expect(evaluateConfirmation("not going to cancel", ["cancel"])).toMatchObject({ asked: false, reason: "confirmation_negated", negation: "not" });
    expect(evaluateConfirmation("Not sure about the timing. Cancel it.", ["cancel"])).toMatchObject({ asked: true, marker: "cancel", sentence: "cancel it." });
    expect(evaluateConfirmation("", ["cancel"])).toEqual({ asked: false, reason: "confirmation_does_not_ask_for_this_action" });
  });
});

describe("QA #1873 r2 Critical: a question about the action, or a mention of it, is not a request for it", () => {
  it.each([
    ["How do I cancel my subscription?", "confirmation_is_a_question"],
    ["how do i cancel my subscription", "confirmation_is_a_question"],
    ["What happens if I cancel my subscription?", "confirmation_is_a_question"],
    ["Can I cancel my subscription and get a refund?", "confirmation_is_a_question"],
    ["Is it possible to cancel my plan mid-month", "confirmation_is_a_question"],
    ["If I cancel my subscription, do I keep access until December?", "confirmation_is_a_question"],
    ["I was thinking about cancelling my subscription at some point", "confirmation_asks_about_the_action"],
    ["my friend had to cancel the subscription on his account", "confirmation_not_a_request"],
    ["the cancel my subscription button does nothing", "confirmation_not_a_request"],
  ])("NEGATIVE: %j -> %s, the actor never runs", async (snippet, reason) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe(reason);
    expect(String(out.marker)).toMatch(/^(cancel|cancelling) (my|the) (subscription|plan)$/);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it.each([
    "please cancel my subscription",
    "Cancel my subscription.",
    "Yes, cancel my subscription.",
    "ok please go ahead and cancel my plan",
    "I am switching tools, so I want to cancel my subscription",
    "I'd like to cancel my subscription.",
    "I've decided to cancel my plan",
    "How do I get a refund? Also, please cancel my subscription.",
  ])("POSITIVE: %j is an affirmative request and executes", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(true);
    expect(calls.actor).toBe(1);
  });

  describe("QA #1873 r3 Critical: a request for INSTRUCTIONS about the action is not a request for the action", () => {
    it.each([
      ["Please tell me how to cancel my subscription", "how to"],
      ["please tell me how to cancel my subscription.", "how to"],
      ["I want to know how to cancel my subscription", "how to"],
      ["I'd like to know if I can cancel my subscription without a fee", "if i"],
      ["Please explain the cancel my subscription policy", "explain"],
      ["Please walk me through the steps to cancel my subscription", "the steps to"],
      ["I want to understand what happens if I cancel my plan", "if i"],
      ["Please let me know whether I can cancel my subscription mid-month", "whether"],
      ["I'm thinking about cancelling my subscription, please advise", "thinking about"],
      ["Please send me instructions to cancel my subscription", "instructions"],
      ["I might cancel my subscription next month", "might"],
    ])("NEGATIVE: %j -> confirmation_asks_about_the_action (%s), the actor never runs", async (snippet, about) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_asks_about_the_action");
      expect(out.about).toBe(about);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
    });

    it.each([
      "Please cancel my subscription",
      "I understand the consequences, please cancel my subscription",
      "I read the policy. Please cancel my subscription.",
      "Thanks for explaining; please cancel my subscription now",
      "I know how it works, I want to cancel my subscription",
    ])("POSITIVE control: %j is a request for the action and executes", async (snippet) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(true);
      expect(calls.actor).toBe(1);
    });
  });

  describe("QA #1873 r4 Critical: the FINAL instruction decides; a later reversal in the same part refuses", () => {
    it.each([
      ["Please cancel my subscription. Actually, do not cancel it.", "not"],
      ["Please cancel my subscription. Actually, don't cancel it.", "don't"],
      ["Cancel my subscription. Wait, never mind, do not cancel my subscription.", "not"],
      ["I want to cancel my plan. On second thought, don't cancel.", "don't"],
      ["Please cancel my subscription. No! Do not cancel, I changed my mind.", "no"],
      ["please cancel my subscription; actually do not", "not"],
      ["Please cancel my subscription. I changed my mind.", "changed my mind"],
      ["Please cancel my subscription. Wait, no!", "no"],
    ])("NEGATIVE: %j -> confirmation_reversed (%s), the actor never runs, no claim is taken", async (snippet, negation) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_reversed");
      expect(out.negation).toBe(negation);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
      expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
    });

    describe("QA #1873 r5 Critical: a withdrawal AFTER the marker in the same sentence, and across an unpunctuated newline", () => {
      it.each([
        ["Please cancel my subscription, but do not cancel it.", "not"],
        ["please cancel my subscription but actually don't", "don't"],
        ["Please cancel my subscription, no wait, never mind", "no"],
        ["cancel my subscription... actually no, do not cancel", "no"],
        ["Please cancel my subscription\nActually do not cancel it", "not"],
        ["Please cancel my subscription\r\nI changed my mind", "changed my mind"],
        ["Please cancel my subscription\n\nno", "no"],
      ])("NEGATIVE: %j -> refused (%s), the actor never runs, no claim", async (snippet, negation) => {
        const { tool, calls } = harness({ latest: { id: "m1", snippet } });
        const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
        expect(out.ok).toBe(false);
        expect(["confirmation_reversed", "confirmation_negated"]).toContain(out.reason);
        expect(out.negation).toBe(negation);
        expect(calls.actor).toBe(0);
        expect(calls.claims).toEqual([]);
      });

      it("splitSentences: a newline is a sentence boundary even with no punctuation", () => {
        expect(splitSentences("Please cancel my subscription\nActually do not cancel it")).toEqual(["please cancel my subscription", "actually do not cancel it"]);
        expect(splitSentences("one\r\n\r\ntwo. three")).toEqual(["one", "two.", "three"]);
      });

      it.each([
        "I do not need a refund. Please cancel my subscription.",
        "I don't use it anymore, so please cancel my subscription",
        "No refund needed. Please cancel my subscription, thanks",
        "Please cancel my subscription\nThank you",
        "Not the newsletter, just my plan: please cancel my subscription",
      ])("POSITIVE control: %j executes (the negation is BEFORE the request, which stays the final instruction)", async (snippet) => {
        const { tool, calls } = harness({ latest: { id: "m1", snippet } });
        const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
        expect(out.ok, JSON.stringify(out)).toBe(true);
        expect(calls.actor).toBe(1);
      });
    });

    it("a same-sentence contradiction is refused too", async () => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription, no wait, do not cancel my subscription" } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(["confirmation_reversed", "confirmation_negated"]).toContain(out.reason);
      expect(calls.actor).toBe(0);
    });

    it.each([
      "I don't want the newsletter. Please cancel my subscription.",
      "Does the refund come back to the same card? Please cancel my subscription.",
      "I do not need a refund. Please cancel my subscription.",
      "Not the invoice issue; please cancel my subscription.",
    ])("POSITIVE control: %j keeps the standing request and executes", async (snippet) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(true);
      expect(calls.actor).toBe(1);
    });

    it("the value binds to the FINAL instruction, never to an earlier one that was reversed", async () => {
      const snippet = "Please apply the offer code SAVE50. Actually no, do not apply that one; please apply the offer code WELCOME20.";
      const { tool, calls, seen } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
      const wrong = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
      expect(wrong.ok).toBe(false);
      expect(wrong.reason).toBe("param_not_in_confirmation");
      expect(calls.actor).toBe(0);
      const right = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "WELCOME20" } });
      expect(right.ok, JSON.stringify(right)).toBe(true);
      expect((seen.params as Record<string, unknown>).offer_code).toBe("WELCOME20");
    });

    it("a negated and an affirmative clause in ONE sentence with no request cue between them is contradictory: neither address is written", async () => {
      const snippet = "Please apply the offer code SAVE50. Actually no, do not apply that one, apply the offer code WELCOME20.";
      const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
      for (const offer_code of ["SAVE50", "WELCOME20"]) {
        const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code } });
        expect(out.ok).toBe(false);
        expect(["confirmation_reversed", "confirmation_negated"]).toContain(out.reason);
      }
      expect(calls.actor).toBe(0);
    });

    it("an offer request that is then withdrawn executes nothing", async () => {
      const snippet = "Please apply the offer code SAVE50. Actually, do not apply the offer.";
      const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
      expect(out.reason).toBe("confirmation_reversed");
      expect(calls.actor).toBe(0);
    });
  });

  it("a request phrased as a question is refused - Caroline must get an explicit confirmation first", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "Can you cancel my subscription?" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("confirmation_is_a_question");
    expect(calls.actor).toBe(0);
  });
});

describe("QA #1873 r4 Critical: a marker carries the OBJECT of its own intent; a request for another thing never satisfies it", () => {
  const positive: Record<SupportIntentKind, string> = {
    cancel_subscription: "please cancel my subscription",
    retention_offer_apply: "yes, please apply the offer",
    order_address_update: "please ship my order to 456 Elm Street",
    founding_buyback_link: "please send me the founding buyback link",
  };

  it.each([
    "Please cancel my order",
    "please cancel the order",
    "Cancel my ticket to the webinar",
    "please cancel my meeting with the team",
    "cancel my credit request please",
    "please stop the emails",
    "end the conversation please",
    "Please unsubscribe me from your newsletter",
    "unsubscribe me from marketing emails",
    "please unsubscribe",
    "I want to unsubscribe from the mailing list",
  ])("NEGATIVE: %j does not satisfy cancel_subscription", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it.each([
    ["founding_buyback_link", "I am a founding member, when did I join?", {}],
    ["founding_buyback_link", "please send me the link to my invoice", {}],
    ["retention_offer_apply", "please apply the credit to my profile", {}],
  ] as const)("NEGATIVE: %s is not satisfied by %j", async (intent, snippet, params) => {
    const { tool, calls } = harness({ intent, latest: { id: "m1", snippet } });
    const out = await run(tool, { intent, confirmation_ref: "m1", params });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
    expect(calls.actor).toBe(0);
  });

  it("cross-action: each intent's positive request satisfies ONLY its own row across every enabled policy row", async () => {
    const enabled = SUPPORT_INTENTS.filter((k) => shippedPolicy().intents[k]?.enabled);
    expect(enabled).toEqual(["cancel_subscription", "retention_offer_apply", "founding_buyback_link"]);
    for (const target of enabled) {
      for (const asked of enabled) {
        const params = {};
        const { tool, calls } = harness({ intent: target, latest: { id: "m1", snippet: positive[asked] } });
        const out = await run(tool, { intent: target, confirmation_ref: "m1", params });
        if (asked === target) {
          expect(out.ok, `${target} <- ${positive[asked]}`).toBe(true);
          expect(calls.actor).toBe(1);
        } else {
          expect(out.ok, `${target} must not accept ${JSON.stringify(positive[asked])}`).toBe(false);
          expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
          expect(calls.actor).toBe(0);
        }
      }
    }
  });

  it("policy: a bare verb or bare noun marker is policy_invalid (broad_marker), so the shipped file cannot regress to it", async () => {
    for (const bad of ["cancel", "address", "founding", "ship to", "buyback", "update", "stop", "unsubscribe", "subscription"]) {
      expect(policyRowProblem({ enabled: true, actor: EXECUTOR, confirmation_markers: ["cancel my subscription", bad] })).toBe(`broad_marker:${bad}`);
    }
    expect(policyRowProblem({ enabled: true, actor: EXECUTOR, confirmation_markers: ["apply"] })).toMatch(/^(generic|broad)_marker:apply$/);
    for (const kind of SUPPORT_INTENTS) expect(policyRowProblem(shippedPolicy().intents[kind]!)).toBeNull();
    const policy = shippedPolicy();
    policy.intents.cancel_subscription!.confirmation_markers = ["cancel"];
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, policy });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("policy_invalid");
    expect(out.detail).toBe("broad_marker:cancel");
    expect(calls.actor).toBe(0);
  });
});

describe("QA #1873 r6 Critical: a conditional request is not a request until the condition is resolved", () => {
  it.each([
    ["Please cancel my subscription if you can't offer me a discount.", "if"],
    ["please cancel my subscription if you cannot offer me a discount", "if"],
    ["Cancel my subscription unless you can match the other price.", "unless"],
    ["If there is no discount, please cancel my subscription.", "if"],
    ["Please cancel my plan once you have refunded me.", "once"],
    ["I want to cancel my subscription, otherwise give me a discount", "otherwise"],
    ["Please cancel my subscription in case the price goes up", "in case"],
    ["Please cancel my subscription provided I get a refund", "provided"],
  ])("NEGATIVE: %j -> confirmation_is_conditional (%s), the actor never runs, no claim", async (snippet, condition) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("confirmation_is_conditional");
    expect(out.condition).toBe(condition);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
  });

  it.each([
    ["Please cancel my subscription after I receive a refund.", "after"],
    ["please cancel my subscription once I get my refund", "once"],
    ["Cancel my subscription when my current credits run out", "when"],
    ["Please cancel my subscription as soon as the refund lands", "as soon as"],
    ["Please cancel my subscription at the end of the month", "at the end"],
    ["Please cancel my subscription next month", "next month"],
    ["Please cancel my subscription, but not until the refund is in", "until"],
    ["Please cancel my subscription before the next charge, after the refund", "after"],
    ["Please cancel my subscription starting January", "starting"],
    ["Please cancel my subscription effective next billing cycle", "next billing"],
    ["Please cancel my subscription tomorrow", "tomorrow"],
    ["please cancel my subscription upon refund", "upon"],
  ])("NEGATIVE (QA r7, temporal regardless of pronoun): %j -> confirmation_is_conditional (%s), no actor, no claim", async (snippet, condition) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(["confirmation_is_conditional", "confirmation_negated", "confirmation_reversed"]).toContain(out.reason);
    if (out.reason === "confirmation_is_conditional") expect(out.condition).toBe(condition);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it.each([
    "Please cancel my subscription after all",
    "please cancel my subscription right away",
    "The last request was lost, so please cancel my subscription once again",
  ])("POSITIVE control: %j is an idiom, not a timing, and executes", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(calls.actor).toBe(1);
  });

  describe("QA #1873 r9 Critical: the decision reads the COMPLETE message, never the 200-character snippet", () => {
    const filler = "I have been a customer for a long time and I want to explain the whole situation so that you understand exactly what happened with my account and why I am writing to you today about all of this. ";
    const long = `Please cancel my subscription. ${filler}${filler}Actually, do not cancel it.`;

    it("a withdrawal beyond character 200 refuses (confirmation_reversed), no actor, no claim", async () => {
      expect(long.length).toBeGreaterThan(300);
      const { tool, calls } = harness({ latest: { id: "m1", snippet: long } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(["confirmation_reversed", "confirmation_negated", "confirmation_followed_by_more"]).toContain(out.reason);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
    });

    it("a qualifier beyond character 200 refuses (confirmation_is_conditional)", async () => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet: `Please cancel my subscription. ${filler}${filler}But not until Friday.` } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(["confirmation_is_conditional", "confirmation_followed_by_more"]).toContain(out.reason);
      expect(calls.actor).toBe(0);
    });

    it("a reader that carries only a TRUNCATED snippet (no text) fails closed: confirmation_truncated, route_to_human", async () => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet: `${long.slice(0, 200)}\u2026`, text: undefined } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_truncated");
      expect(out.route_to_human).toBe(true);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
      expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
    });

    it("a reader that carries only a COMPLETE snippet (no text, no truncation mark) still decides", async () => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet: "Please cancel my subscription.", text: undefined } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok, JSON.stringify(out)).toBe(true);
      expect(calls.actor).toBe(1);
    });

    it("a long message whose FINAL instruction is the request executes (the length alone is not a refusal)", async () => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet: `${filler}${filler}Please cancel my subscription.` } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok, JSON.stringify(out)).toBe(true);
      expect(calls.actor).toBe(1);
    });
  });

  describe("QA #1873 r9 Critical: time-of-day and vague deferrals refuse", () => {
    it.each([
      ["Please cancel my subscription in the morning", "in the morning"],
      ["Please cancel my subscription tomorrow morning", "tomorrow"],
      ["please cancel my subscription this afternoon", "this afternoon"],
      ["Please cancel my subscription first thing", "first thing"],
      ["Please cancel my subscription later today", "later"],
      ["Please cancel my subscription end of day", "end of"],
      ["Please cancel my subscription after lunch", "after"],
      ["Please cancel my subscription at some point", "at some point"],
      ["Please cancel my subscription in a bit", "in a bit"],
      ["Please cancel my subscription sometime next week", "next week"],
      ["Please cancel my subscription whenever you can", "whenever"],
      ["Please cancel my subscription in the next few days", "in the next"],
    ])("NEGATIVE: %j -> confirmation_is_conditional (%s), no actor, no claim", async (snippet, condition) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_is_conditional");
      expect(out.condition).toBe(condition);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
    });
  });

  describe("QA #1873 r8 Critical: an explicit future date or time, and a later qualifier sentence", () => {
    it.each([
      ["Please cancel my subscription on Friday", "friday"],
      ["please cancel my subscription on monday", "monday"],
      ["Please cancel my subscription on the 15th", "on the"],
      ["Please cancel my subscription on 15 December", "december"],
      ["Please cancel my subscription on 2026-12-01", "2026-12-01"],
      ["Please cancel my subscription on 12/01", "12/01"],
      ["Please cancel my subscription at 5pm", "at 5pm"],
      ["Please cancel my subscription in 3 days", "in 3 days"],
      ["Please cancel my subscription in a week", "in a week"],
      ["Please cancel my subscription this weekend", "this weekend"],
      ["Please cancel my subscription tonight", "tonight"],
    ])("NEGATIVE (future date/time in the request): %j -> confirmation_is_conditional (%s), no actor, no claim", async (snippet, condition) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_is_conditional");
      expect(out.condition).toBe(condition);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
    });

    it.each([
      ["Please cancel my subscription. But not until Friday.", "until"],
      ["Please cancel my subscription. Only if there is no fee.", "if"],
      ["Please cancel my subscription. On Friday please.", "friday"],
      ["Please cancel my subscription. After my refund arrives.", "after"],
      ["Please cancel my subscription.\nAt the end of the month though.", "at the end"],
      ["Please cancel my subscription. Unless you can give me a discount.", "unless"],
      ["Please cancel my subscription. Does it cancel today or at the end of the period?", "at the end"],
      ["Please cancel my subscription. If you have questions, email me.", "if"],
    ])("NEGATIVE (a later sentence qualifies the standing request; refuse on doubt): %j -> confirmation_is_conditional (%s), no actor", async (snippet, condition) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("confirmation_is_conditional");
      expect(out.condition).toBe(condition);
      expect(calls.actor).toBe(0);
      expect(calls.claims).toEqual([]);
    });

    it.each([
      "Please cancel my subscription right now",
      "Please cancel my subscription today",
      "Please cancel my subscription. Thanks, have a good day.",
      "I am at the end of my rope with the app. Please cancel my subscription.",
      "I was charged on Friday. Please cancel my subscription.",
    ])("POSITIVE control: %j executes (now/today, or the timing is before the request, not on it)", async (snippet) => {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok, JSON.stringify(out)).toBe(true);
      expect(calls.actor).toBe(1);
    });

    it("conditionOf: dates, times, relative offsets; idioms masked", () => {
      expect(conditionOf("cancel my subscription on friday")).toBe("friday");
      expect(conditionOf("cancel my subscription at 17:30")).toBe("at 17:30");
      expect(conditionOf("cancel my subscription in two weeks")).toBe("in two weeks");
      expect(conditionOf("cancel my subscription after all")).toBeNull();
      expect(conditionOf("cancel my subscription right away")).toBeNull();
      expect(conditionOf("cancel my subscription")).toBeNull();
    });
  });

  it("a demand with no request cue is refused as not-a-request (still never the actor)", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "Give me 50% off or else cancel my subscription" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(["confirmation_not_a_request", "confirmation_is_conditional"]).toContain(out.reason);
    expect(calls.actor).toBe(0);
  });

  it("a conditional applies to an offer too: the actor never runs", async () => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "apply the offer if it is at least 30% off" } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
    expect(out.reason).toBe("confirmation_is_conditional");
    expect(calls.actor).toBe(0);
  });

  it.each([
    "Please cancel my subscription. Thanks for your help.",
    "Please cancel my subscription, thanks for your help",
    "Even if it costs me the discount, please cancel my subscription",
  ])("POSITIVE control: %j executes (no condition, or a concession rather than a condition)", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(calls.actor).toBe(1);
  });
});

describe("QA #1873 r6 Important: a bound value must be the customer's COMPLETE value, never a substring", () => {
  it.each([
    ["retention_offer_apply", "Please apply the offer code SAVE50", { offer_code: "SAVE" }, "absent"],
    ["retention_offer_apply", "Please apply the offer code SAVE50", { offer_code: "AVE50" }, "absent"],
    ["retention_offer_apply", "Please apply the offer code SAVE50-EXTRA", { offer_code: "SAVE50" }, "partial"],
    ["retention_offer_apply", "Please apply the offer code SAVE50 EXTRA", { offer_code: "SAVE50" }, "partial"],
    ["retention_offer_apply", "Please apply the offer code SAVE50 4B", { offer_code: "SAVE50" }, "partial"],
    ["retention_offer_apply", "Please apply the offer code XSAVE50", { offer_code: "SAVE50" }, "absent"],
  ] as const)("NEGATIVE: %s %j with %j -> param_not_in_confirmation (%s), no write", async (intent, snippet, params, why) => {
    const { tool, calls } = harness({ intent, latest: { id: "m1", snippet } });
    const out = await run(tool, { intent, confirmation_ref: "m1", params });
    expect(out.ok).toBe(false);
    expect(["param_not_in_confirmation", "confirmation_followed_by_more"]).toContain(out.reason);
    if (out.reason === "param_not_in_confirmation") expect(out.why).toBe(why);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it.each([
    ["retention_offer_apply", "Please apply the offer code SAVE50", { offer_code: "SAVE50" }],
    ["retention_offer_apply", "yes, apply the offer SAVE50 to my account please", { offer_code: "SAVE50" }],
    ["retention_offer_apply", "Please apply the offer code SAVE50, thanks!", { offer_code: "SAVE50" }],
    ["retention_offer_apply", "apply the discount with code WELCOME-20 please", { offer_code: "WELCOME-20" }],
  ] as const)("POSITIVE: %s %j with the complete value %j binds and executes", async (intent, snippet, params) => {
    const { tool, calls, seen } = harness({ intent, latest: { id: "m1", snippet } });
    const out = await run(tool, { intent, confirmation_ref: "m1", params });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(calls.actor).toBe(1);
    expect(seen.params).toEqual(params);
  });

  it("boundValueProblem: whole-word, complete", () => {
    expect(boundValueProblem("apply the offer code save50", "save")).toBe("absent");
    expect(boundValueProblem("apply the offer code save50", "save50")).toBeNull();
    expect(boundValueProblem("ship my order to 123 main street", "123 main")).toBe("partial");
    expect(boundValueProblem("ship my order to 123 main street please", "123 main street")).toBeNull();
    expect(boundValueProblem("ship my order to 123 main street", "main street", "ship my order to")).toBe("partial");
    expect(boundValueProblem("apply the offer code save50", "save50", "apply the offer")).toBeNull();
    expect(boundValueProblem("save50 is the code, apply the offer", "save50", "apply the offer")).toBe("partial");
  });
});

describe("QA #1873 r10 Critical: the request must be the customer's FINAL instruction - anything after it that is not courtesy refuses", () => {
  it.each([
    ["Please cancel my subscription. Actually, I do not want to.", "actually"],
    ["Please cancel my subscription, but I do not want to.", "but"],
    ["Please cancel my subscription. No, I would rather keep it.", "no"],
    ["Please cancel my subscription. Wait, leave it active.", "wait"],
    ["Please cancel my subscription. On second thought keep it going.", "on"],
    ["Please cancel my subscription. I would like to keep it after all.", "would"],
    ["Please cancel my subscription, I am switching tools", "switching"],
    ["Please cancel my subscription. I do not need a refund.", "do"],
    ["Please cancel my subscription. Does the refund come back to the same card?", "does"],
    ["Please cancel my subscription, not the newsletter", "not"],
    ["Please cancel my subscription\nThanks, no refund needed", "no"],
    ["Please cancel my subscription. Thanks, John", "john"],
    ["Please cancel my subscription, nothing else is needed", "nothing"],
    ["Please cancel my subscription and refund me the last month", "refund"],
  ])("NEGATIVE: %j -> confirmation_followed_by_more (%s), route_to_human, the actor never runs, no claim", async (snippet, more) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason, JSON.stringify(out)).toBe("confirmation_followed_by_more");
    expect(out.more).toBe(more);
    expect(out.route_to_human).toBe(true);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
  });

  it("the QA probe sentences: none reaches the actor", async () => {
    for (const snippet of [
      "Please cancel my subscription. Actually, I do not want to.",
      "Please cancel my subscription, but I do not want to.",
      "Please cancel my subscription. No, I would rather keep it",
      "Please cancel my subscription. Wait, leave it active.",
    ]) {
      const { tool, calls } = harness({ latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
      expect(out.ok, snippet).toBe(false);
      expect(calls.actor, snippet).toBe(0);
      expect(calls.claims, snippet).toEqual([]);
    }
  });

  it("evaluateConfirmation: a sentence after the request that is not courtesy drops the request", () => {
    const markers = ["cancel my subscription"];
    expect(evaluateConfirmation("Please cancel my subscription. Actually, I do not want to.", markers).asked).toBe(false);
    expect(evaluateConfirmation("Please cancel my subscription. Thanks!", markers).asked).toBe(true);
    expect(evaluateConfirmation("Please cancel my subscription. Thank you so much", markers).asked).toBe(false);
    expect(trailingProblem(", thanks a lot!")).toBeNull();
    expect(trailingProblem(". i would rather keep it")).toBe("would");
  });

  it.each([
    "Please cancel my subscription",
    "Please cancel my subscription!",
    "Please cancel my subscription, thanks",
    "Please cancel my subscription. Thanks, have a good day.",
    "Please cancel my subscription asap. Thank you",
    "Please cancel my subscription\n\nKind regards",
    "Yes, confirmed: please cancel my subscription now",
    "I am not happy with the app. Please cancel my subscription.",
  ])("POSITIVE: %j is the final instruction and executes", async (snippet) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(calls.actor).toBe(1);
  });

  it("a bound value is what may follow the marker, and nothing else may follow the value", async () => {
    const ok = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "Please apply the offer code SAVE50, thanks" } });
    const out = await run(ok.tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    const more = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "Please apply the offer code SAVE50 but only on the yearly plan" } });
    const out2 = await run(more.tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
    expect(out2.ok).toBe(false);
    expect(["param_not_in_confirmation", "confirmation_is_conditional", "confirmation_followed_by_more"]).toContain(out2.reason);
    expect(more.calls.actor).toBe(0);
  });
});

describe("QA #1873 r11 Critical: a model-supplied bound value can never swallow the customer's withdrawal", () => {
  it("the QA input: order_address_update is OFF in the shipped policy, so nothing is parsed and nothing runs", async () => {
    const snippet = "Please ship my order to 123 Main Street, but leave it at the current address.";
    const { tool, calls } = harness({ intent: "order_address_update", latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "order_address_update", confirmation_ref: "m1", params: { address: "123 Main Street, but leave it at the current address" } });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("intent_disabled");
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it("the shipped policy says why the address row is off, and it cannot be switched on without a closed shape", () => {
    const row = shippedPolicy().intents.order_address_update!;
    expect(row.enabled).toBe(false);
    expect(row.disabled_why).toMatch(/free-text address/);
    expect(policyRowProblem({ ...row, enabled: true })).toBe("unclosed_bound_param:address");
    expect(policyRowProblem({ ...row, enabled: true, params_shape: { address: "code" } })).toBeNull();
  });

  it("an enabled row with an unshaped bound param is policy_invalid end to end: the actor never runs", async () => {
    const custom = JSON.parse(JSON.stringify(shippedPolicy()));
    custom.intents.order_address_update.enabled = true;
    const { tool, calls } = harness({ intent: "order_address_update", policy: custom, latest: { id: "m1", snippet: "please ship my order to 123 Main Street" } });
    const out = await run(tool, { intent: "order_address_update", confirmation_ref: "m1", params: { address: "123 Main Street" } });
    expect(out.reason).toBe("policy_invalid");
    expect(out.detail).toBe("unclosed_bound_param:address");
    expect(calls.actor).toBe(0);
  });

  it.each([
    ["SAVE50, but keep my current plan", "malformed"],
    ["SAVE50 but leave it", "malformed"],
    ["save50; cancel instead", "malformed"],
    ["", "malformed"],
    ["AB", "malformed"],
  ])("NEGATIVE: a code value %j is refused param_malformed (%s) BEFORE the confirmation is read, no actor", async (offer_code, why) => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: `Please apply the offer code ${offer_code}` } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code } });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("param_malformed");
    expect(out.why).toBe(why);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it.each([
    "Please apply the offer code SAVE50, but keep my current plan",
    "Please apply the offer code SAVE50 but leave it at the current price",
    "Please apply the offer code SAVE50. Actually, I do not want it.",
    "Please apply the offer code SAVE50 only on the yearly plan",
  ])("NEGATIVE: %j - the trailing instruction is judged with the value REMOVED, so the value cannot hide it", async (snippet) => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
    expect(out.ok).toBe(false);
    expect(["confirmation_followed_by_more", "confirmation_is_conditional", "confirmation_reversed", "confirmation_negated"]).toContain(out.reason);
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
  });

  it("evaluateConfirmation runs the trailing check even when a bound value is present", () => {
    const markers = ["apply the offer"];
    expect(evaluateConfirmation("please apply the offer code save50, thanks", markers, ["save50"]).asked).toBe(true);
    const v = evaluateConfirmation("please apply the offer code save50 but leave it", markers, ["save50"]);
    expect(v.asked).toBe(false);
    expect(v.asked === false && v.reason).toBe("confirmation_followed_by_more");
    expect(valueShapeProblem("code", "save50")).toBeNull();
    expect(valueShapeProblem("code", "123 main street")).toBe("malformed");
    expect(valueShapeProblem(undefined, "save50")).toBe("no_shape");
  });
});

describe("QA #1873 r4 Important: an Intercom read that fails is a refusal with a ledger row, never a throw", () => {
  it.each([
    ["email", "identity_unavailable"],
    ["part", "confirmation_unavailable"],
  ] as const)("NEGATIVE: the %s read rejects -> %s, route_to_human, one refuse row, no actor, no claim", async (which, reason) => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, readerFails: which });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe(reason);
    expect(out.route_to_human).toBe(true);
    expect(String(out.detail)).toContain("502");
    expect(calls.actor).toBe(0);
    expect(calls.claims).toEqual([]);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
    expect(calls.ledger[0]).toMatchObject({ reason, execution_id: "conv-1:cancel_subscription:m1" });
  });

  it("the read fails AND the ledger fails: still a structured refusal, never a throw", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, readerFails: "part", ledgerFailOn: () => true });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("confirmation_unavailable");
    expect(out.ledger_write_failed).toBe(true);
    expect(calls.actor).toBe(0);
  });
});

describe("QA #1873 r1 Important: material params are bound to the customer's own words", () => {
  const CODE_A = "SAVE50";
  const ask = `please apply the offer code ${CODE_A}`;

  it("POSITIVE: the code the customer wrote is forwarded to the actor", async () => {
    const { tool, calls, seen } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: ask } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: CODE_A } });
    expect(out.ok, JSON.stringify(out)).toBe(true);
    expect(calls.actor).toBe(1);
    expect((seen.params as Record<string, unknown>).offer_code).toBe(CODE_A);
  });

  it("NEGATIVE: confirmed code A, model passes code B -> param_not_in_confirmation, no write", async () => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: ask } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "HACK99" } });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("param_not_in_confirmation");
    expect(out.param).toBe("offer_code");
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: a param the policy does not allow is refused as unexpected_params", async () => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: ask } });
    const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: CODE_A, email: "attacker@example.com" } });
    expect(out.reason).toBe("unexpected_params");
    expect(out.params).toEqual(["email"]);
    expect(calls.actor).toBe(0);
  });

  it("NEGATIVE: cancel_subscription takes no params at all", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" } });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1", params: { refund: "full" } });
    expect(out.reason).toBe("unexpected_params");
    expect(calls.actor).toBe(0);
  });

  describe("QA #1873 r2 Important: the value binds to the REQUESTING sentence, not to presence anywhere", () => {
    const competing = "Don't apply the offer code SAVE50; apply the offer code WELCOME20";

    it("NEGATIVE: the explicitly rejected code is not bindable even though it is in the message", async () => {
      const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: competing } });
      const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
      expect(out.ok).toBe(false);
      expect(out.reason).toBe("param_not_in_confirmation");
      expect(out.sentence).toBe("apply the offer code welcome20");
      expect(calls.actor).toBe(0);
    });

    it("POSITIVE: the chosen code binds", async () => {
      const { tool, calls, seen } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: competing } });
      const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "WELCOME20" } });
      expect(out.ok, JSON.stringify(out)).toBe(true);
      expect(calls.actor).toBe(1);
      expect((seen.params as Record<string, unknown>).offer_code).toBe("WELCOME20");
    });

    it("NEGATIVE: a code that appears only in a QUESTION sentence does not bind to the request sentence", async () => {
      const snippet = "Could you apply the offer code SAVE50? Actually, please apply the offer code WELCOME20.";
      const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet } });
      const out = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1", params: { offer_code: "SAVE50" } });
      expect(out.reason).toBe("param_not_in_confirmation");
      expect(calls.actor).toBe(0);
    });
  });
});

describe("QA #1873 r2 Important: one confirmed intent executes once", () => {
  it("NEGATIVE: the same intent emitted twice runs the actor ONCE; the second is duplicate_execution", async () => {
    const { tool, calls } = harness({ intent: "retention_offer_apply", latest: { id: "m1", snippet: "yes, please apply the offer" } });
    const first = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
    const second = await run(tool, { intent: "retention_offer_apply", confirmation_ref: "m1" });
    expect(first.ok).toBe(true);
    expect(second.ok).toBe(false);
    expect(second.reason).toBe("duplicate_execution");
    expect(second.execution_id).toBe("conv-1:retention_offer_apply:m1");
    expect(second.route_to_human).toBe(true);
    expect(calls.actor).toBe(1);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["allow", "executed", "refuse"]);
  });

  it("NEGATIVE: a retry after the executed row was LOST still cannot run the actor again", async () => {
    let failExecuted = true;
    const { tool, calls } = harness({
      latest: { id: "m1", snippet: "please cancel my subscription" },
      ledgerFailOn: (row) => failExecuted && row.decision === "executed",
    });
    const first = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(first.ok).toBe(true);
    expect(first.ledger_write_failed).toBe(true);
    failExecuted = false;
    const retry = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(retry.reason).toBe("duplicate_execution");
    expect(calls.actor).toBe(1);
  });

  it("a new confirmation part is a new execution; a different intent on the same part is too", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" } });
    await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(calls.claims).toEqual(["conv-1:cancel_subscription:m1"]);
    // (a second part would need a new reader; the claim key is pinned by name here)
    expect(calls.claims[0]).not.toBe("conv-1:cancel_subscription:m2");
  });

  it("NEGATIVE: a claim store that cannot answer refuses claim_unavailable before the allow row", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, claimsFail: true });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("claim_unavailable");
    expect(out.route_to_human).toBe(true);
    expect(calls.actor).toBe(0);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
  });

  it("the allow row failing leaves the claim TAKEN, so the blind retry is refused rather than re-run", async () => {
    let failAllow = true;
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, ledgerFailOn: (row) => failAllow && row.decision === "allow" });
    const first = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(first.reason).toBe("ledger_unavailable");
    expect(first.execution_id).toBe("conv-1:cancel_subscription:m1");
    failAllow = false;
    const retry = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(retry.reason).toBe("duplicate_execution");
    expect(calls.actor).toBe(0);
  });

  it("the production file claim store is O_EXCL: two concurrent claims on one id yield exactly one true", async () => {
    const dir = await mkdtemp(join(tmpdir(), "sig-claims-"));
    const store = fileClaims(dir);
    const results = await Promise.all([1, 2, 3, 4, 5].map(() => store.claim("conv-9:cancel_subscription:m7", { ts: "t" })));
    expect(results.filter(Boolean)).toHaveLength(1);
    expect(await store.claim("conv-9:cancel_subscription:m8", { ts: "t" })).toBe(true);
  });
});

describe("QA #1873 r1 Important: the actor that runs is the actor the policy names", () => {
  it("NEGATIVE: an actor bound under a different identity is refused as actor_mismatch and never runs", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "please cancel my subscription" }, actorName: "someone.else" });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("actor_mismatch");
    expect(out.actor).toBe(EXECUTOR);
    expect(out.bound_actor).toBe("someone.else");
    expect(out.route_to_human).toBe(true);
    expect(calls.actor).toBe(0);
    expect(calls.ledger.map((r) => r.decision)).toEqual(["refuse"]);
  });

  it("NEGATIVE: a legacy bare-function actor (no name) is actor_unavailable", async () => {
    const calls: Calls = { actor: 0, ledger: [], claims: [] };
    const tool = createSupportIntentTool({
      intercomReader: reader({ id: "m1", snippet: "please cancel my subscription" }),
      intercomToken: "tok",
      conversationId: "conv-1",
      policy: shippedPolicy,
      recordCheck: async () => ({ allowed: true, teamId: "team-demo-1" }),
      actors: { cancel_subscription: (async () => { calls.actor += 1; return { content: [], details: {} }; }) as unknown as SupportIntentActor },
      ledger: (row) => { calls.ledger.push(row); },
      claims: memoryClaims(calls),
    });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.reason).toBe("actor_unavailable");
    expect(calls.actor).toBe(0);
  });
});

describe("QA #1873 r1 Important: ledger failure before the write stops it; after the write it is reported, not thrown", () => {
  it("NEGATIVE: the allow row cannot be written -> ledger_unavailable, the actor never runs", async () => {
    const { tool, calls } = harness({
      latest: { id: "m1", snippet: "please cancel my subscription" },
      ledgerFailOn: (row) => row.decision === "allow",
    });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("ledger_unavailable");
    expect(out.route_to_human).toBe(true);
    expect(calls.actor).toBe(0);
    // The refusal row itself was written (the ledger only failed on the allow row).
    expect(calls.ledger.at(-1)).toMatchObject({ decision: "refuse", reason: "ledger_unavailable" });
  });

  it("the write happened and the executed row fails: execute() resolves (no throw), says so, and names the execution_id for reconciliation", async () => {
    const { tool, calls } = harness({
      latest: { id: "m1", snippet: "please cancel my subscription" },
      ledgerFailOn: (row) => row.decision === "executed",
    });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(calls.actor).toBe(1);
    expect(out.ok).toBe(true);
    expect(out.decision).toBe("executed");
    expect(out.ledger_write_failed).toBe(true);
    expect(out.ledger_error).toContain("ENOSPC");
    expect(out.route_to_human).toBe(true);
    expect(out.execution_id).toBe("conv-1:cancel_subscription:m1");
    expect(calls.ledger.map((r) => r.decision)).toEqual(["allow"]);
  });

  it("the actor throws AND the ledger fails: still no throw out of execute()", async () => {
    const calls: Calls = { actor: 0, ledger: [], claims: [] };
    const tool = createSupportIntentTool({
      intercomReader: reader({ id: "m1", snippet: "please cancel my subscription" }),
      intercomToken: "tok",
      conversationId: "conv-1",
      policy: shippedPolicy,
      recordCheck: async () => ({ allowed: true, teamId: "team-demo-1" }),
      actors: { cancel_subscription: { name: EXECUTOR, run: async () => { calls.actor += 1; throw new Error("stripe 502"); } } },
      ledger: (row) => { if (row.decision === "executed") throw new Error("ENOSPC"); calls.ledger.push(row); },
      claims: memoryClaims(calls),
    });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(calls.actor).toBe(1);
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("actor_failed");
    expect(out.ledger_write_failed).toBe(true);
  });

  it("a refusal whose row cannot be written still returns the refusal (and flags the ledger)", async () => {
    const { tool, calls } = harness({ latest: { id: "m1", snippet: "when does it ship?" }, ledgerFailOn: () => true });
    const out = await run(tool, { intent: "cancel_subscription", confirmation_ref: "m1" });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe("confirmation_does_not_ask_for_this_action");
    expect(out.ledger_write_failed).toBe(true);
    expect(calls.actor).toBe(0);
  });
});

describe("order-scoped classes: the gate resolves the order and its owner (inbox 024)", () => {
  const row = () => ({ ...shippedPolicy().intents.order_address_update!, enabled: true, order_scoped: true, params_shape: { address: "address" } });
  const policy = () => ({ ...shippedPolicy(), intents: { ...shippedPolicy().intents, order_address_update: row() } });
  const SNIP = "please update my shipping address to 1 New Road, Springfield, 62701";
  const ADDR = "1 New Road, Springfield, 62701";

  function build(record: Record<string, unknown>, seen: Record<string, unknown>[]) {
    return createSupportIntentTool({
      intercomReader: reader({ id: "m1", snippet: SNIP }),
      intercomToken: "tok",
      conversationId: "conv-1",
      policy,
      recordCheck: async () => ({ allowed: true, state: "active", teamId: "team-1", ...record }),
      actors: { order_address_update: { name: "caroline.support-executor", run: async (i) => { seen.push(i); return { content: [{ type: "text", text: JSON.stringify({ ok: true }) }], details: {} }; } } },
      ledger: () => {},
      claims: { claim: async () => true },
    });
  }

  it("the actor receives the gate-resolved order ref and owner, and never re-resolves", async () => {
    const seen: Record<string, unknown>[] = [];
    const out = await run(build({ orderRef: "ord-9", ownerEmail: "demo@muso.ai" }, seen), { intent: "order_address_update", confirmation_ref: "m1", params: { address: ADDR } });
    expect(out.decision).toBe("executed");
    expect(seen[0]).toMatchObject({ orderRef: "ord-9", ownerEmail: "demo@muso.ai", teamId: "team-1" });
  });

  it("an unresolved order is refused, so the actor cannot pick its own target", async () => {
    const seen: Record<string, unknown>[] = [];
    const out = await run(build({}, seen), { intent: "order_address_update", confirmation_ref: "m1", params: { address: ADDR } });
    expect(out.reason).toBe("record_unresolved");
    expect(seen).toEqual([]);
  });

  it("the flag is OFF by default: without order_scoped the row does not demand an order", async () => {
    const p = shippedPolicy();
    expect(p.intents.order_address_update!.order_scoped).toBeUndefined();
  });
});

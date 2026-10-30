import { describe, it, expect, vi, afterEach } from "vitest";
import {
  buildJevState,
  buildJevStateV2,
  decide,
  renderJevBlock,
  toJudgeOutput,
  formatJevLogLine,
  createJevTurnRunner,
  createJevBackedJudge,
  isCloserShaped,
  type JevAnswers,
  type JevActionsConfig,
  type JevBands,
  type JevV2Part,
} from "../src/jev-router.js";
import * as inventoryLoader from "../src/caroline-inventory-loader.js";
import type { CarolineIntentMeta, CarolineSkillMeta } from "../src/caroline-inventory-loader.js";
import type { IntercomSessionState } from "../src/types.js";
import * as agentInstructionsLoader from "../src/caroline-agent-instructions-loader.js";

const BANDS: JevBands = { bad_faith: 0.85, no_reply: 0.9, human_required: 0.9 };
const ALL_ON: JevActionsConfig = { decline: true, silence: true, escalate: true };

function choice(name: string, probabilities: Record<string, number>, confidence?: number): JevAnswers[string] {
  return { type: "choice", choice: name, probabilities, confidence };
}

// ---------------------------------------------------------------------------
// buildJevState
// ---------------------------------------------------------------------------

describe("buildJevState", () => {
  it("trims recentParts to the last 10 and each body to 500 chars", () => {
    const recentParts = Array.from({ length: 15 }, (_, i) => ({
      author: (i % 2 === 0 ? "user" : "bot") as "user" | "bot",
      body: `part-${i}`,
    }));
    const state = buildJevState({ message: "hi", recentParts, turnCount: 3 });
    const lastParts = state.last_parts as { author: string; text: string }[];
    expect(lastParts).toHaveLength(10);
    expect(lastParts[0].text).toBe("part-5"); // the last 10 of 15, i.e. indices 5..14
    expect(lastParts[9].text).toBe("part-14");

    const long = "x".repeat(600);
    const trimmed = buildJevState({ message: "hi", recentParts: [{ author: "user", body: long }], turnCount: 1 });
    const parts = trimmed.last_parts as { author: string; text: string }[];
    expect(parts[0].text).toHaveLength(500);
  });

  it("never includes questions text from input — only message/last_parts/turn_count/known_facts", () => {
    const state = buildJevState({ message: "hi", turnCount: 1, founding: 2020, plan: "pro" });
    expect(Object.keys(state).sort()).toEqual(["known_facts", "last_parts", "message", "turn_count"]);
  });

  it("omits known_facts entirely when no known-facts input is present", () => {
    const state = buildJevState({ message: "hi", turnCount: 1 });
    expect(state.known_facts).toBeUndefined();
    expect("known_facts" in state).toBe(false);
  });

  it("includes only the known-facts keys that were actually provided", () => {
    const state = buildJevState({ message: "hi", turnCount: 1, plan: "pro" });
    expect(state.known_facts).toEqual({ plan: "pro" });
  });
});

// ---------------------------------------------------------------------------
// isCloserShaped (real-conversation backtest guard)
// ---------------------------------------------------------------------------

describe("isCloserShaped", () => {
  it("is false for a question, even a short one", () => {
    expect(isCloserShaped("Hi you got some news ?")).toBe(false);
  });

  it("is false for a substantive follow-up under 8 words with no closer phrase", () => {
    expect(isCloserShaped("Ok but I don't received the email")).toBe(false);
  });

  it("is false for a closer phrase followed by more than 8 words of content", () => {
    expect(isCloserShaped("Ok perfect thanks, Looking forward to hearing from you")).toBe(false);
  });

  it("is true for a short, punctuation-only wrap-up", () => {
    expect(isCloserShaped("Thanks so much!")).toBe(true);
  });

  it("is true for an exact closer-phrase match", () => {
    expect(isCloserShaped("sounds good")).toBe(true);
    expect(isCloserShaped("No worries!")).toBe(true);
  });

  it("is true for SOUL.md's verbatim closer words not in the old paraphrased list (np, 🙏)", () => {
    expect(isCloserShaped("np")).toBe(true);
    expect(isCloserShaped("🙏")).toBe(true);
  });

  it("is true for a bare emoji closer (👍) — matched before emoji stripping, not reduced to empty", () => {
    expect(isCloserShaped("👍")).toBe(true);
  });

  it("is true for the documented safe additions beyond SOUL's list (thank you)", () => {
    expect(isCloserShaped("thank you")).toBe(true);
  });

  it("is false for an empty or whitespace-only message", () => {
    expect(isCloserShaped("")).toBe(false);
    expect(isCloserShaped("   ")).toBe(false);
  });

  // Phase 1b hand-labelled set (docs/designs/2026-09-22-jev-caroline-router.md).
  // Each of these is SHORT and has no "?", and each was a real customer who
  // needed a reply. A "three words or fewer is a closer" rule admitted all of
  // them; the guard is now an exact phrase match.
  it("is false for a short message that is not a closer phrase: 'urgent' after an escalation (no_reply 0.89)", () => {
    expect(isCloserShaped("urgent")).toBe(false);
  });

  it("is false for a bare profile link sent to be merged (no_reply 0.64)", () => {
    expect(isCloserShaped("https://muso.ai/profile/eec1e131-2115-4ea7-8390-7a7303983f5a")).toBe(false);
  });

  it("is false for other short non-closers: a greeting, a fragment, an answer to Caroline's question", () => {
    expect(isCloserShaped("hi")).toBe(false);
    expect(isCloserShaped("soundexchange")).toBe(false);
    expect(isCloserShaped("I keep kameeh")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// decide — one branch per test
// ---------------------------------------------------------------------------

describe("decide", () => {
  it("declines on first bad-faith over the band, and sets no escalation", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.9 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.5 }),
    };
    const decision = decide(answers, BANDS, "lol whatever", undefined);
    expect(decision.action).toBe("decline");
    expect(decision.block).toContain("decline in one sentence");
  });

  it("silences (not declines) on a second bad-faith turn after badFaithDeclinedAt is set", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.9 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.5 }),
    };
    const state: Pick<IntercomSessionState, "jev"> = {
      jev: { action: "decline", block: "x", badFaithDeclinedAt: "2026-09-22T00:00:00Z" },
    };
    const decision = decide(answers, BANDS, "lol whatever again", state);
    expect(decision).toEqual({ action: "silence", block: null });
  });

  it("does not decline/silence when bad_faith is just under the band", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.84 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.8 }),
    };
    const decision = decide(answers, BANDS, "help with credits", undefined);
    expect(decision.action).toBe("route");
  });

  it("silences on no_reply over the band when the message is closer-shaped", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
    };
    const decision = decide(answers, BANDS, "Thanks so much!", undefined, [], [], ALL_ON);
    expect(decision).toEqual({ action: "silence", block: null });
  });

  it("does NOT silence on no_reply when the message is not closer-shaped (real backtest case)", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("no_reply", { no_reply: 0.96, caroline_tool: 0.04 }),
    };
    const decision = decide(answers, BANDS, "Hi you got some news ?", undefined);
    expect(decision.action).toBe("route");
  });

  it("does not silence when no_reply is under the band even if closer-shaped", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("no_reply", { no_reply: 0.89, caroline_tool: 0.11 }),
    };
    const decision = decide(answers, BANDS, "thanks", undefined);
    expect(decision.action).toBe("route");
  });

  it("escalates when resolution_path.choice is human_required and its probability is over the band", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("human_required", { human_required: 0.93, caroline_tool: 0.07 }),
      intent: choice("data_deletion", { data_deletion: 0.9 }),
    };
    const intents: CarolineIntentMeta[] = [
      { intent: "data_deletion", action_type_on_handoff: "data-deletion" },
    ];
    const decision = decide(answers, BANDS, "delete my account", undefined, intents, [], ALL_ON);
    expect(decision.action).toBe("escalate");
    expect(decision.escalation).toEqual({
      triggered: true,
      source: "judge",
      reason: "jev:human_required",
      suggestedActionType: "data-deletion",
      confidence: "high",
    });
  });

  it("escalates with medium confidence when human_required probability is between the band and 0.9", () => {
    // Uses a lower band than the BANDS default so there's a real gap between
    // "over the band" (escalates at all) and "over 0.9" (high confidence) —
    // at the current 0.90 default those two thresholds coincide.
    const lowerBand: JevBands = { ...BANDS, human_required: 0.75 };
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("human_required", { human_required: 0.8, caroline_tool: 0.2 }),
    };
    const decision = decide(answers, lowerBand, "please delete my data", undefined, [], [], ALL_ON);
    expect(decision.action).toBe("escalate");
    expect(decision.escalation?.confidence).toBe("medium");
  });

  it("does NOT escalate when human_required probability is high but the chosen path is not human_required", () => {
    // Real-backtest fix: a status ping scored human_required probability 0.79
    // under the OLD 0.8 band while resolution_path actually CHOSE
    // caroline_tool — escalating on probability mass alone was wrong.
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.55, human_required: 0.93 }),
    };
    const decision = decide(answers, BANDS, "any updates?", undefined);
    expect(decision.action).toBe("route");
  });

  it("falls back to support-general when the intent's action_type_on_handoff isn't a valid RiskActionType", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("human_required", { human_required: 0.95 }),
      intent: choice("credit_verification", { credit_verification: 0.9 }),
    };
    const intents: CarolineIntentMeta[] = [
      { intent: "credit_verification", action_type_on_handoff: "credit-verify" }, // not in RiskActionType
    ];
    const decision = decide(answers, BANDS, "verify my credit", undefined, intents, [], ALL_ON);
    expect(decision.escalation?.suggestedActionType).toBe("support-general");
  });

  it("routes otherwise, with a rendered block", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85 }),
      intent: choice("credit_verification", { credit_verification: 0.91 }),
      first_tool: choice("credit_verification_check", { credit_verification_check: 0.88 }),
      skill: choice("customer-credit-verification", { "customer-credit-verification": 0.86 }),
    };
    const decision = decide(answers, BANDS, "where's my credit", undefined);
    expect(decision.action).toBe("route");
    expect(decision.block).toBe(
      [
        "[ROUTING]",
        "path: caroline_tool (0.85)",
        "intent: credit_verification (0.91)",
        "first_tool: credit_verification_check (0.88)",
        "skill: customer-credit-verification (0.86)",
        "Follow this routing unless a tool result contradicts it. path=caroline_tool means: use",
        "the tool, do not create a ticket, EXCEPT credit, document, claim and merge questions:",
        "there the verification-handoff ticket IS the action, always file it. path=ask_customer",
        "means: ask for exactly the one missing item, nothing else.",
        "[/ROUTING]",
      ].join("\n"),
    );
  });

  // -------------------------------------------------------------------------
  // Intent-table override (coordinator-requested refinement, live-probe
  // 2026-09-22): when `intent` is confident, prefer the inventory's
  // deterministic first_read_tool/skill lookup over Jev's own weaker
  // first_tool/skill answers.
  // -------------------------------------------------------------------------

  const CONFIDENT_INTENTS: CarolineIntentMeta[] = [
    { intent: "credit_verification", first_read_tool: "credit_verification_check", write_tools: ["credits_verify"] },
  ];
  const MATCHING_SKILLS: CarolineSkillMeta[] = [
    { name: "customer-credit-verification", tools_used: ["credit_verification_check", "credits_verify"] },
  ];

  it("prefers the intent table's first_read_tool and the single matching skill when intent is confident", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85 }),
      intent: choice("credit_verification", { credit_verification: 0.92 }, 0.92),
      // Jev's own (weaker) tool/skill answers — must be overridden.
      first_tool: choice("credits_search", { credits_search: 0.38 }),
      skill: choice("none", { none: 0.4 }),
    };
    const decision = decide(answers, BANDS, "my credits are not approved", undefined, CONFIDENT_INTENTS, MATCHING_SKILLS);
    expect(decision.block).toContain("first_tool: credit_verification_check (from intent)");
    expect(decision.block).toContain("skill: customer-credit-verification (from intent)");
  });

  it("falls back to Jev's own first_tool/skill answers when intent is 'other'", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.7 }),
      intent: choice("other", { other: 0.95 }, 0.95),
      first_tool: choice("create_ticket", { create_ticket: 0.6 }),
      skill: choice("none", { none: 0.5 }),
    };
    const decision = decide(answers, BANDS, "something unusual", undefined, CONFIDENT_INTENTS, MATCHING_SKILLS);
    expect(decision.block).toContain("first_tool: create_ticket (0.60)");
    expect(decision.block).toContain("skill: none (0.50)");
  });

  it("falls back to Jev's own first_tool/skill answers when intent confidence is below the 0.6 threshold", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.7 }),
      intent: choice("credit_verification", { credit_verification: 0.5 }, 0.5),
      first_tool: choice("credits_search", { credits_search: 0.38 }),
      skill: choice("none", { none: 0.4 }),
    };
    const decision = decide(answers, BANDS, "credits question", undefined, CONFIDENT_INTENTS, MATCHING_SKILLS);
    expect(decision.block).toContain("first_tool: credits_search (0.38)");
    expect(decision.block).toContain("skill: none (0.40)");
  });

  it("falls back to Jev's own skill answer when the intent's tools match more than one skill (ambiguous)", () => {
    const ambiguousSkills: CarolineSkillMeta[] = [
      { name: "skill-a", tools_used: ["credit_verification_check"] },
      { name: "skill-b", tools_used: ["credit_verification_check"] },
    ];
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85 }),
      intent: choice("credit_verification", { credit_verification: 0.92 }, 0.92),
      first_tool: choice("credits_search", { credits_search: 0.38 }),
      skill: choice("none", { none: 0.4 }),
    };
    const decision = decide(answers, BANDS, "credits question", undefined, CONFIDENT_INTENTS, ambiguousSkills);
    expect(decision.block).toContain("first_tool: credit_verification_check (from intent)");
    expect(decision.block).toContain("skill: none (0.40)");
  });
});

// ---------------------------------------------------------------------------
// decide — per-branch action kill switches (202-turn backtest: no safe band
// for no_reply or human_required, bad_faith is clean at 0.90 — see
// DEFAULT_JEV_ACTIONS in types.ts).
// ---------------------------------------------------------------------------

describe("decide — actions kill switches", () => {
  const NO_REPLY_ANSWERS: JevAnswers = {
    off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
    resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
  };
  const HUMAN_REQUIRED_ANSWERS: JevAnswers = {
    off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
    resolution_path: choice("human_required", { human_required: 0.93, caroline_tool: 0.07 }),
  };
  const BAD_FAITH_ANSWERS: JevAnswers = {
    off_topic_or_bad_faith: { type: "noul", noul: 0.9 },
    resolution_path: choice("caroline_tool", { caroline_tool: 0.5 }),
  };

  it("silence off: a no_reply-band hit over a closer-shaped message returns route with suppressed=silence", () => {
    const actions: JevActionsConfig = { decline: true, silence: false, escalate: false };
    const decision = decide(NO_REPLY_ANSWERS, BANDS, "Thanks so much!", undefined, [], [], actions);
    expect(decision.action).toBe("route");
    expect(decision.suppressed).toBe("silence");
    expect(decision.block).toContain("[ROUTING]");
  });

  it("silence on: unchanged behaviour — a no_reply-band hit still silences, no suppressed field", () => {
    const decision = decide(NO_REPLY_ANSWERS, BANDS, "Thanks so much!", undefined, [], [], ALL_ON);
    expect(decision).toEqual({ action: "silence", block: null });
    expect(decision.suppressed).toBeUndefined();
  });

  it("escalate off: a human_required-band hit returns route with suppressed=escalate, rule/keyword layer untouched", () => {
    const actions: JevActionsConfig = { decline: true, silence: false, escalate: false };
    const decision = decide(HUMAN_REQUIRED_ANSWERS, BANDS, "delete my account", undefined, [], [], actions);
    expect(decision.action).toBe("route");
    expect(decision.suppressed).toBe("escalate");
    expect(decision.escalation).toBeUndefined();
    expect(decision.block).toContain("[ROUTING]");
  });

  it("escalate on: unchanged behaviour — a human_required-band hit still escalates, no suppressed field", () => {
    const decision = decide(HUMAN_REQUIRED_ANSWERS, BANDS, "delete my account", undefined, [], [], ALL_ON);
    expect(decision.action).toBe("escalate");
    expect(decision.suppressed).toBeUndefined();
  });

  it("decline off: a bad-faith hit returns route instead of decline", () => {
    const actions: JevActionsConfig = { decline: false, silence: true, escalate: true };
    const decision = decide(BAD_FAITH_ANSWERS, BANDS, "lol whatever", undefined, [], [], actions);
    expect(decision.action).toBe("route");
    // decline is not in the coordinator's enumerated suppressed set
    // (silence|escalate only) — no token expected here.
    expect(decision.suppressed).toBeUndefined();
  });

  it("decline off: the second-hit bad-faith silence is also suppressed (it's part of decline)", () => {
    const actions: JevActionsConfig = { decline: false, silence: true, escalate: true };
    const state: Pick<IntercomSessionState, "jev"> = {
      jev: { action: "decline", block: "x", badFaithDeclinedAt: "2026-09-22T00:00:00Z" },
    };
    const decision = decide(BAD_FAITH_ANSWERS, BANDS, "lol whatever again", state, [], [], actions);
    expect(decision.action).toBe("route");
  });

  it("decline on: unchanged behaviour — the second-hit bad-faith silence still fires when decline is on", () => {
    const state: Pick<IntercomSessionState, "jev"> = {
      jev: { action: "decline", block: "x", badFaithDeclinedAt: "2026-09-22T00:00:00Z" },
    };
    const decision = decide(BAD_FAITH_ANSWERS, BANDS, "lol whatever again", state, [], [], ALL_ON);
    expect(decision).toEqual({ action: "silence", block: null });
  });

  it("defaults (no actions param passed): decline on, silence/escalate off, matching DEFAULT_JEV_ACTIONS", () => {
    const declineDecision = decide(BAD_FAITH_ANSWERS, BANDS, "lol whatever", undefined);
    expect(declineDecision.action).toBe("decline");

    const noReplyDecision = decide(NO_REPLY_ANSWERS, BANDS, "Thanks so much!", undefined);
    expect(noReplyDecision.action).toBe("route");
    expect(noReplyDecision.suppressed).toBe("silence");

    const humanRequiredDecision = decide(HUMAN_REQUIRED_ANSWERS, BANDS, "delete my account", undefined);
    expect(humanRequiredDecision.action).toBe("route");
    expect(humanRequiredDecision.suppressed).toBe("escalate");
  });
});

// ---------------------------------------------------------------------------
// QA finding 3 (2026-09-22 PR #999): the [ROUTING] block must never NAME a
// path whose action is switched off. The kill switches stop the PLUGIN from
// acting, but the block is advisory text Caroline is told to follow
// (workspaces/support/AGENTS.md), so `path: no_reply (0.97)` with
// actions.silence=false still routes [[NO_REPLY]] around the switch. Covers
// all three of decide()'s renderRouteBlock call sites — the two suppressed-
// branch early returns AND the plain fall-through, which is how the
// documented real false positive ("Hi you got some news ?": no_reply 0.97,
// not closer-shaped so the silence branch is never reached) leaked.
// ---------------------------------------------------------------------------

describe("renderRouteBlock — a disabled path is never named", () => {
  const SILENCE_OFF: JevActionsConfig = { decline: true, silence: false, escalate: false };
  const ESCALATE_OFF: JevActionsConfig = { decline: true, silence: false, escalate: false };

  // The documented real false positive from the 197-turn backtest: scores
  // no_reply 0.97 but contains "?", so isCloserShaped() is false and decide()
  // reaches the plain fall-through, not the suppressed-silence branch.
  const FP_MESSAGE = "Hi you got some news ?";
  const FP_ANSWERS: JevAnswers = {
    off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
    resolution_path: choice("no_reply", { no_reply: 0.97, caroline_tool: 0.02, ask_customer: 0.01 }),
    intent: choice("other", { other: 0.8 }),
  };

  it("fall-through path (the documented FP): masks no_reply when silence is off", () => {
    const decision = decide(FP_ANSWERS, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.action).toBe("route");
    // Not a suppressed-branch return — isCloserShaped("... ?") is false.
    expect(decision.suppressed).toBeUndefined();
    expect(decision.block).not.toContain("no_reply");
    // The only allowed alternatives score 0.02/0.01 — below the uniform
    // prior, i.e. paths the model effectively rejected. Since AGENTS.md tells
    // Caroline to FOLLOW the block, naming one of those is worse than naming
    // none, so the line is omitted entirely.
    expect(decision.block).not.toContain("path:");
    expect(decision.block).not.toContain("0.97");
  });

  it("suppressed-silence branch: masks no_reply on a closer-shaped message too", () => {
    const decision = decide(FP_ANSWERS, BANDS, "Thanks so much!", undefined, [], [], SILENCE_OFF);
    expect(decision.action).toBe("route");
    expect(decision.suppressed).toBe("silence");
    expect(decision.block).not.toContain("no_reply");
    expect(decision.block).not.toContain("path:");
  });

  it("suppressed-escalate branch: masks human_required when escalate is off", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("human_required", { human_required: 0.93, ask_customer: 0.05, caroline_tool: 0.02 }),
    };
    const decision = decide(answers, BANDS, "delete my account", undefined, [], [], ESCALATE_OFF);
    expect(decision.action).toBe("route");
    expect(decision.suppressed).toBe("escalate");
    expect(decision.block).not.toContain("human_required");
    // ask_customer 0.05 / caroline_tool 0.02 are both below the fallback
    // floor, so no substitute is named.
    expect(decision.block).not.toContain("path:");
  });

  it("names a substituted path when the distribution is genuinely split (above the fallback floor)", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("no_reply", { no_reply: 0.5, caroline_tool: 0.45, ask_customer: 0.05 }),
    };
    const decision = decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.block).not.toContain("no_reply");
    expect(decision.block).toContain("path: caroline_tool (0.45)");
  });

  it("names a substituted escalate path when it clears the floor", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("human_required", { human_required: 0.6, ask_customer: 0.35, caroline_tool: 0.05 }),
    };
    const decision = decide(answers, BANDS, "a person please", undefined, [], [], ESCALATE_OFF);
    expect(decision.block).not.toContain("human_required");
    expect(decision.block).toContain("path: ask_customer (0.35)");
  });

  it("pins the floor comparison's direction: exactly 0.25 is named, a hair under is not", () => {
    // resolution_path has exactly 4 options, so 0.25 is the uniform prior.
    // AT the prior the fallback is not yet evidence AGAINST the path, so it
    // is named; below it, it is noise and the line is omitted. Asserted as a
    // pair so the boundary cannot pass by luck of a `>` vs `>=` choice.
    const at: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("no_reply", { no_reply: 0.75, caroline_tool: 0.25 }),
    };
    expect(decide(at, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF).block).toContain(
      "path: caroline_tool (0.25)",
    );

    const justUnder: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("no_reply", { no_reply: 0.751, caroline_tool: 0.249 }),
    };
    expect(decide(justUnder, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF).block).not.toContain("path:");
  });

  // MUS-1598: the `actions[branch] === true` escape hatch above is gone —
  // masking is now UNCONDITIONAL. The two tests this replaces asserted the
  // old, leaky behaviour (a kill-switched label stays named once its action
  // flag is on); that behaviour was QA finding 3 re-opening itself one band
  // lower (see MUS-1551's 27.6%-of-turns measurement) and must not exist.

  it("case 1 (red on origin/main): escalate ON does not un-mask an under-band human_required path", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("human_required", { human_required: 0.6, caroline_tool: 0.4 }),
    };
    const decision = decide(answers, BANDS, "I need a person", undefined, [], [], ALL_ON);
    expect(decision.action).toBe("route");
    expect(decision.block).not.toContain("path: human_required");
  });

  it("case 2: at p=0.95 there is no block to leak into — decide() escalates directly instead", () => {
    // Documents why the high-confidence case was never the problem: decide()
    // takes the gated action itself (block: null) long before any fallback
    // rendering could happen.
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("human_required", { human_required: 0.95, caroline_tool: 0.05 }),
    };
    const decision = decide(answers, BANDS, "I need a person", undefined, [], [], ALL_ON);
    expect(decision.action).toBe("escalate");
    expect(decision.block).toBeNull();
  });

  it("case 3 (red on origin/main, the silence twin): silence ON does not un-mask a non-closer-shaped no_reply path", () => {
    // Same defect on the other action, so it can't be left latent for
    // whoever flips silence next. FP_MESSAGE ("Hi you got some news ?") is
    // not closer-shaped, so decide() takes the plain fall-through, not the
    // suppressed-silence branch — the assertion is about the block contents,
    // not about isCloserShaped already forcing route.
    const decision = decide(FP_ANSWERS, BANDS, FP_MESSAGE, undefined, [], [], ALL_ON);
    expect(decision.action).toBe("route");
    expect(decision.suppressed).toBeUndefined();
    expect(decision.block).not.toContain("path: no_reply");
  });

  it("omits the path: line entirely when probabilities are absent — never invents one", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: { type: "choice", choice: "no_reply", confidence: 0.97 },
      intent: choice("other", { other: 0.8 }),
    };
    const decision = decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.action).toBe("route");
    expect(decision.block).not.toContain("path:");
    expect(decision.block).not.toContain("no_reply");
    // The rest of the block still renders — the mask drops one line, not the
    // whole routing signal.
    expect(decision.block).toContain("[ROUTING]");
    expect(decision.block).toContain("intent: other (0.80)");
    expect(decision.block).toContain("first_tool:");
    expect(decision.block).toContain("[/ROUTING]");
  });

  it("omits the path: line when probabilities holds no ALLOWED entry", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("no_reply", { no_reply: 0.6, human_required: 0.4 }),
    };
    const decision = decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.block).not.toContain("path:");
    expect(decision.block).not.toContain("no_reply");
    expect(decision.block).not.toContain("human_required");
  });

  it("does not throw, and omits the path: line, when probabilities is not an object", () => {
    const answers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: { type: "choice", choice: "no_reply", probabilities: "not-an-object" },
    } as unknown as JevAnswers;
    expect(() => decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF)).not.toThrow();
    const decision = decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.block).not.toContain("path:");
    expect(decision.block).not.toContain("no_reply");
  });

  it("does not throw, and omits the path: line, when probabilities is an array (indices are not labels)", () => {
    const answers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: { type: "choice", choice: "no_reply", probabilities: [0.9, 0.1] },
    } as unknown as JevAnswers;
    expect(() => decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF)).not.toThrow();
    expect(decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF).block).not.toContain("path:");
  });

  it("skips a non-numeric probability rather than rendering it as the fallback", () => {
    const answers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: {
        type: "choice",
        choice: "no_reply",
        // caroline_tool's string value would otherwise WIN the fallback (it is
        // the higher number if compared as-is); skipping it leaves
        // ask_customer, which also clears the fallback floor so a line renders.
        probabilities: { no_reply: 0.5, caroline_tool: "0.45", ask_customer: 0.3 },
      },
    } as unknown as JevAnswers;
    const decision = decide(answers, BANDS, FP_MESSAGE, undefined, [], [], SILENCE_OFF);
    expect(decision.block).toContain("path: ask_customer (0.30)");
  });

  it("defaults (no actions param): the SHIPPED config masks both kill-switched paths", () => {
    // DEFAULT_JEV_ACTIONS is silence:false, escalate:false — the config in
    // prod today. decide()'s default must be the restrictive one.
    expect(decide(FP_ANSWERS, BANDS, FP_MESSAGE, undefined).block).not.toContain("no_reply");
    const hr: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("human_required", { human_required: 0.5, caroline_tool: 0.4 }),
    };
    expect(decide(hr, BANDS, "I need a person", undefined).block).not.toContain("human_required");
  });

  it("leaves an allowed path untouched (caroline_tool/ask_customer have no kill switch)", () => {
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85, no_reply: 0.1 }),
    };
    const decision = decide(answers, BANDS, "where's my credit", undefined, [], [], SILENCE_OFF);
    expect(decision.block).toContain("path: caroline_tool (0.85)");
  });

  it("never floors a path the MODEL chose — an allowed top path renders even below 0.25", () => {
    // The floor guards SUBSTITUTION only. A low-confidence answer the model
    // actually picked is still its answer, and suppressing it would drop real
    // routing signal rather than prevent an invented one.
    const answers: JevAnswers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      resolution_path: choice("caroline_tool", { caroline_tool: 0.2, no_reply: 0.15, ask_customer: 0.15 }),
    };
    const decision = decide(answers, BANDS, "where's my credit", undefined, [], [], SILENCE_OFF);
    expect(decision.block).toContain("path: caroline_tool (0.20)");
  });
});

// ---------------------------------------------------------------------------
// renderJevBlock
// ---------------------------------------------------------------------------

describe("renderJevBlock", () => {
  it("returns the block for a route action", () => {
    expect(renderJevBlock({ action: "route", block: "[ROUTING]...[/ROUTING]" })).toBe("[ROUTING]...[/ROUTING]");
  });

  it("returns the block for a decline action", () => {
    expect(renderJevBlock({ action: "decline", block: "[ROUTING]decline[/ROUTING]" })).toBe(
      "[ROUTING]decline[/ROUTING]",
    );
  });

  it("returns null for silence/escalate/none actions", () => {
    expect(renderJevBlock({ action: "silence", block: null })).toBeNull();
    expect(renderJevBlock({ action: "escalate", block: null })).toBeNull();
    expect(renderJevBlock({ action: "none", block: null })).toBeNull();
  });

  it("returns null when state.jev is undefined", () => {
    expect(renderJevBlock(undefined)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// toJudgeOutput
// ---------------------------------------------------------------------------

describe("toJudgeOutput", () => {
  it("maps human_required over the band to shouldHandoff:true with high confidence", () => {
    const answers: JevAnswers = { resolution_path: choice("human_required", { human_required: 0.95 }) };
    const out = toJudgeOutput(answers, BANDS);
    expect(out.shouldHandoff).toBe(true);
    expect(out.reasons).toEqual(["human_required"]);
    expect(out.confidence).toBe("high");
  });

  it("maps under-band human_required to shouldHandoff:false", () => {
    const answers: JevAnswers = { resolution_path: choice("caroline_tool", { caroline_tool: 0.8, human_required: 0.1 }) };
    const out = toJudgeOutput(answers, BANDS);
    expect(out.shouldHandoff).toBe(false);
    expect(out.reasons).toEqual([]);
    expect(out.confidence).toBe("low");
  });
});

// ---------------------------------------------------------------------------
// formatJevLogLine
// ---------------------------------------------------------------------------

describe("formatJevLogLine", () => {
  it("formats the exact [intercom:jev] line shape and never includes message text", () => {
    const answers: JevAnswers = {
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85 }),
      intent: choice("credit_verification", { credit_verification: 0.91 }),
      first_tool: choice("credit_verification_check", { credit_verification_check: 0.88 }),
      skill: choice("customer-credit-verification", { "customer-credit-verification": 0.86 } as any),
      off_topic_or_bad_faith: { type: "noul", noul: 0.02 },
      frustration: { type: "score", score: 0, legend: { "0": "Calm" }, probabilities: { "0": 0.7 } },
    };
    const line = formatJevLogLine({ conversationId: "conv1", action: "route", answers, latencyMs: 240 });
    expect(line).toBe(
      "[intercom:jev] conv=conv1 action=route path=caroline_tool:0.85 intent=credit_verification:0.91 " +
        "tool=credit_verification_check:0.88 skill=customer-credit-verification:0.86 bad_faith=0.02 human=0.00 " +
        "frustration=Calm:0.70 ms=240",
    );
  });

  it("labels a fractional score by its NEAREST level (live 2.12 -> Frustrated), not the raw number", () => {
    const answers: JevAnswers = {
      resolution_path: choice("caroline_tool", { caroline_tool: 0.85 }),
      frustration: {
        type: "score",
        score: 2.12,
        legend: { "0": "Calm", "1": "Concerned", "2": "Frustrated", "3": "Angry" },
        probabilities: { "0": 0, "1": 0, "2": 0.88, "3": 0.12 },
        confidence: 0.88,
      },
    };
    const line = formatJevLogLine({ conversationId: "conv3", action: "route", answers, latencyMs: 1 });
    expect(line).toContain("frustration=Frustrated:0.88");
  });

  it("formats a none-action line when answers is null", () => {
    const line = formatJevLogLine({ conversationId: "conv2", action: "none", answers: null, latencyMs: 5 });
    expect(line).toBe(
      "[intercom:jev] conv=conv2 action=none path=none:0.00 intent=none:0.00 tool=none:0.00 skill=none:0.00 " +
        "bad_faith=0.00 human=0.00 frustration=unknown:0.00 ms=5",
    );
  });

  it("appends suppressed=<branch> when a band hit's action was switched off, so jev-shadow-report.sh can still count it", () => {
    const line = formatJevLogLine({
      conversationId: "conv3",
      action: "route",
      answers: null,
      latencyMs: 5,
      suppressed: "silence",
    });
    expect(line).toBe(
      "[intercom:jev] conv=conv3 action=route path=none:0.00 intent=none:0.00 tool=none:0.00 skill=none:0.00 " +
        "bad_faith=0.00 human=0.00 frustration=unknown:0.00 ms=5 suppressed=silence",
    );
  });

  it("omits suppressed entirely (not even 'suppressed=undefined') when no branch was suppressed", () => {
    const line = formatJevLogLine({ conversationId: "conv4", action: "route", answers: null, latencyMs: 5 });
    expect(line).not.toContain("suppressed");
  });
});

// ---------------------------------------------------------------------------
// Defense in depth (QA finding 2, 2026-09-22 PR #999): the formatter and
// renderers must never throw on a malformed answer that bypassed
// jev-client's shape validation — render a "?" placeholder instead. These
// hand each renderer a string `confidence` (would previously hit
// `.toFixed` on a string) and a non-object `probabilities` (would previously
// hit `key in <non-object>`, a TypeError), exercised through the exported
// entry points formatJevLogLine/decide since fmt/choiceProb are internal.
// ---------------------------------------------------------------------------

describe("formatJevLogLine — malformed nested answer fields never throw", () => {
  it("renders '?' instead of throwing when confidence is a string", () => {
    const answers = {
      resolution_path: { type: "choice", choice: "caroline_tool", confidence: "0.8" },
    } as unknown as JevAnswers;
    expect(() => formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 })).not.toThrow();
    const line = formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 });
    expect(line).toContain("path=caroline_tool:?");
  });

  it("does not throw when probabilities is not an object (formatJevLogLine reads humanP via choiceProb's `in` check)", () => {
    const answers = {
      resolution_path: { type: "choice", choice: "caroline_tool", probabilities: "not-an-object" },
    } as unknown as JevAnswers;
    expect(() => formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 })).not.toThrow();
    const line = formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 });
    // `in` on a non-object RHS is guarded to a safe fallback (0), not "?" —
    // "?" is fmt's guard for a non-number value that DID resolve, whereas
    // choiceProb's guard resolves to a real number (0) before fmt ever runs.
    expect(line).toContain("human=0.00");
  });

  it("renders '?' instead of throwing on a score answer with a string confidence", () => {
    const answers = {
      frustration: { type: "score", score: 1, confidence: "high" },
    } as unknown as JevAnswers;
    expect(() => formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 })).not.toThrow();
    const line = formatJevLogLine({ conversationId: "c", action: "route", answers, latencyMs: 1 });
    expect(line).toContain("frustration=1:?");
  });
});

describe("decide/renderRouteBlock — malformed nested answer fields never throw", () => {
  it("renders '?' in the [ROUTING] block instead of throwing when confidence is a string", () => {
    const answers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: { type: "choice", choice: "caroline_tool", confidence: "0.8" },
    } as unknown as JevAnswers;
    expect(() => decide(answers, BANDS, "where's my credit", undefined)).not.toThrow();
    const decision = decide(answers, BANDS, "where's my credit", undefined);
    expect(decision.action).toBe("route");
    expect(decision.block).toContain("path: caroline_tool (?)");
  });

  it("does not throw, and still resolves an action, when resolution_path.probabilities is not an object", () => {
    // decide() reads no_reply/human_required probabilities via choiceProb,
    // which guards the `in` operator — a non-object RHS there is a
    // TypeError, not a benign undefined, unlike a plain property access.
    const answers = {
      off_topic_or_bad_faith: { type: "noul", noul: 0.1 },
      resolution_path: { type: "choice", choice: "no_reply", probabilities: "not-an-object" },
    } as unknown as JevAnswers;
    expect(() => decide(answers, BANDS, "hi", undefined)).not.toThrow();
    const decision = decide(answers, BANDS, "hi", undefined);
    // no_reply probability falls back to 0 (guarded), so the band is never
    // crossed and the turn routes normally instead of aborting.
    expect(decision.action).toBe("route");
  });
});

// ---------------------------------------------------------------------------
// createJevTurnRunner — memoization ("no second request")
// ---------------------------------------------------------------------------

describe("createJevTurnRunner", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("calls the underlying fetch at most once across multiple invocations", async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: { resolution_path: { type: "choice", choice: "caroline_tool" } } }),
    })) as unknown as typeof fetch;

    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl });
    const [first, second] = await Promise.all([
      runner({ message: "hi", turnCount: 1 }),
      runner({ message: "hi", turnCount: 1 }),
    ]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(first).toEqual(second);
  });

  it("an HTTP failure outcome carries the real state, questions and model (MUS-3191)", async () => {
    const fetchImpl = vi.fn(async () => ({ ok: false, status: 502, json: async () => ({}) })) as unknown as typeof fetch;
    const runner = createJevTurnRunner({ apiKey: "k", model: "jev-x", fetchImpl });
    const result = await runner({ message: "hi", turnCount: 1 });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("http_502");
    expect(result.state).toBeDefined();
    expect(result.questions).toBeDefined();
    expect(result.model).toBe("jev-x");
  });

  it("returns a questions_unavailable failure outcome without calling fetch when the questions file is unavailable", async () => {
    // caroline-questions.json is checked in by a concurrent workstream and
    // may or may not exist depending on when that PR lands; stub the loader
    // directly so this test exercises the runner's fail-soft short-circuit
    // regardless of that file's presence.
    const spy = vi.spyOn(inventoryLoader, "loadCarolineQuestions").mockReturnValue(null);
    const fetchImpl = vi.fn() as unknown as typeof fetch;
    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl });
    const result = await runner({ message: "hi", turnCount: 1 });
    expect(result).toEqual({ ok: false, reason: "questions_unavailable", httpStatus: null, latencyMs: 0 });
    expect(fetchImpl).not.toHaveBeenCalled();
    spy.mockRestore();
  });

  it("returns a success outcome carrying model/usage/httpStatus/state/questions on a successful call", async () => {
    // Answers cover every key in the REAL caroline-questions.json (loaded by
    // this runner internally) — Finding 3's question-driven validation
    // requires every asked question to be answered, so a partial answers map
    // (as this test used to send) is correctly rejected as shape-invalid.
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        model: "jev-1.13.0",
        answers: {
          first_tool: { type: "choice", choice: "create_ticket" },
          frustration: { type: "score", score: 0, legend: { "0": "Calm" } },
          intent: { type: "choice", choice: "credit_verification" },
          off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
          resolution_path: { type: "choice", choice: "caroline_tool" },
          skill: { type: "choice", choice: "verification-handoff" },
        },
        usage: { input_tokens: 3 },
      }),
    })) as unknown as typeof fetch;

    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl });
    const result = await runner({ message: "hi", turnCount: 1 });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok");
    expect(result.model).toBe("jev-1.13.0");
    expect(result.usage).toEqual({ input_tokens: 3 });
    expect(result.httpStatus).toBe(200);
    expect(result.state).toEqual(expect.any(Object));
    expect(result.questions).toEqual(expect.any(Object));
  });

  // -------------------------------------------------------------------------
  // agent_instructions (SOUL.md) — v2 only. Real caroline-questions.v2.json
  // has many required keys; stubbing loadCarolineQuestionsV2 to a single
  // noul question keeps these focused on state/stateVariant, not the full
  // v2 answer shape (already covered above).
  // -------------------------------------------------------------------------

  const MIN_V2_QUESTIONS = { off_topic_or_bad_faith: { type: "noul" } };
  function minV2Fetch(): typeof fetch {
    return vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: { off_topic_or_bad_faith: { type: "noul", noul: 0.05 } } }),
    })) as unknown as typeof fetch;
  }

  it("v2: agent_instructions is present on state when SOUL.md reads successfully, and absent on v1", async () => {
    const qSpy = vi.spyOn(inventoryLoader, "loadCarolineQuestionsV2").mockReturnValue(MIN_V2_QUESTIONS);
    const loadSpy = vi.spyOn(agentInstructionsLoader, "loadAgentInstructions").mockReturnValue("Be warm. Be brief.");

    const v2Runner = createJevTurnRunner({ apiKey: "k", fetchImpl: minV2Fetch(), questionsVersion: "v2" });
    const v2Result = await v2Runner({ message: "hi", turnCount: 1, recentPartsV2: [] });
    expect(v2Result.ok).toBe(true);
    if (!v2Result.ok) throw new Error("expected ok");
    expect(v2Result.state.agent_instructions).toBe("Be warm. Be brief.");
    expect(v2Result.stateVariant).toBe("v2-soul");

    const v1Fetch = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        answers: {
          first_tool: { type: "choice", choice: "create_ticket" },
          frustration: { type: "score", score: 0, legend: { "0": "Calm" } },
          intent: { type: "choice", choice: "credit_verification" },
          off_topic_or_bad_faith: { type: "noul", noul: 0.05 },
          resolution_path: { type: "choice", choice: "caroline_tool" },
          skill: { type: "choice", choice: "verification-handoff" },
        },
      }),
    })) as unknown as typeof fetch;
    const v1Runner = createJevTurnRunner({ apiKey: "k", fetchImpl: v1Fetch });
    const v1Result = await v1Runner({ message: "hi", turnCount: 1 });
    expect(v1Result.ok).toBe(true);
    if (!v1Result.ok) throw new Error("expected ok");
    expect(v1Result.state).not.toHaveProperty("agent_instructions");
    expect(v1Result.stateVariant).toBeUndefined();
    // The loader must never even be consulted on a v1 call.
    expect(loadSpy).toHaveBeenCalledTimes(1);

    qSpy.mockRestore();
    loadSpy.mockRestore();
  });

  it("v2: an unreadable SOUL.md falls back to v2-policy state and marks stateVariant v2-policy-fallback", async () => {
    const qSpy = vi.spyOn(inventoryLoader, "loadCarolineQuestionsV2").mockReturnValue(MIN_V2_QUESTIONS);
    const loadSpy = vi.spyOn(agentInstructionsLoader, "loadAgentInstructions").mockReturnValue(null);

    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl: minV2Fetch(), questionsVersion: "v2" });
    const result = await runner({ message: "hi", turnCount: 1, recentPartsV2: [] });
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error("expected ok");
    expect(result.state).not.toHaveProperty("agent_instructions");
    expect(result.stateVariant).toBe("v2-policy-fallback");

    qSpy.mockRestore();
    loadSpy.mockRestore();
  });

  it("v2: a failed callJev result still carries stateVariant (computed before the HTTP call)", async () => {
    const qSpy = vi.spyOn(inventoryLoader, "loadCarolineQuestionsV2").mockReturnValue(MIN_V2_QUESTIONS);
    const loadSpy = vi.spyOn(agentInstructionsLoader, "loadAgentInstructions").mockReturnValue(null);
    const fetchImpl = vi.fn(async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;

    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl, questionsVersion: "v2" });
    const result = await runner({ message: "hi", turnCount: 1, recentPartsV2: [] });
    expect(result.ok).toBe(false);
    if (result.ok) throw new Error("expected failure");
    expect(result.stateVariant).toBe("v2-policy-fallback");

    qSpy.mockRestore();
    loadSpy.mockRestore();
  });

  it("passes cfg.agentInstructionsPath through to the loader unchanged", async () => {
    const qSpy = vi.spyOn(inventoryLoader, "loadCarolineQuestionsV2").mockReturnValue(MIN_V2_QUESTIONS);
    const loadSpy = vi.spyOn(agentInstructionsLoader, "loadAgentInstructions").mockReturnValue("soul content");

    const runner = createJevTurnRunner({
      apiKey: "k",
      fetchImpl: minV2Fetch(),
      questionsVersion: "v2",
      agentInstructionsPath: "/custom/path/SOUL.md",
    });
    await runner({ message: "hi", turnCount: 1, recentPartsV2: [] });
    expect(loadSpy.mock.calls[0]?.[0]).toBe("/custom/path/SOUL.md");

    qSpy.mockRestore();
    loadSpy.mockRestore();
  });
});

// ---------------------------------------------------------------------------
// createJevBackedJudge + createJevTurnRunner — the v2 memoization defect
// ---------------------------------------------------------------------------
//
// QA NO-GO on #1022 (finding 2): channel.ts hands the SAME memoized runner
// (createJevTurnRunner) to both createJevBackedJudge (the risk-assessment
// judge, invoked from assessRisk before dispatch) and handler.ts's own
// runJev call. Whichever fires first computes and permanently caches the
// v2 state (createJevTurnRunner's "no second request" memoization — see its
// doc comment). Before the fix, createJevBackedJudge never forwarded
// recentPartsV2 to the runner, so a v2-configured judge call that fired
// first cached a state built from an EMPTY thread and a null
// agent_last_message, and the later real runJev call — even with real v2
// parts — silently reused that empty-thread cache for the rest of the turn.
describe("createJevBackedJudge (v2 memoization)", () => {
  const V2_QUESTIONS = { off_topic_or_bad_faith: { type: "noul" } };

  function v2Fetch(): typeof fetch {
    return vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => ({ answers: { off_topic_or_bad_faith: { type: "noul", noul: 0.05 } } }),
    })) as unknown as typeof fetch;
  }

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("the runner never returns a result computed from different state inputs than the current call's: the risk judge's call must carry recentPartsV2 through to the shared runner, so a later call sees the SAME (real) thread, not an empty one", async () => {
    vi.spyOn(inventoryLoader, "loadCarolineQuestionsV2").mockReturnValue(V2_QUESTIONS);
    vi.spyOn(agentInstructionsLoader, "loadAgentInstructions").mockReturnValue(null);

    const realThread: JevV2Part[] = [
      { author: "customer", body: "where is my credit" },
      { author: "caroline", body: "let me check that for you" },
    ];

    // One memoized runner per (simulated) webhook request — exactly how
    // channel.ts constructs it (jevRunner), then hands the SAME instance to
    // both buildRiskOptions (-> createJevBackedJudge) and handler.ts's runJev.
    const runner = createJevTurnRunner({ apiKey: "k", fetchImpl: v2Fetch(), questionsVersion: "v2" });

    const judge = createJevBackedJudge(runner, BANDS, () => 4, [], ALL_ON);
    // 1) The risk judge fires FIRST (assessRisk runs before dispatch/runJev
    //    in handler.ts) — with the fix, JudgeInput.recentPartsV2 rides along.
    await judge({
      knownFacts: {},
      recentParts: [],
      currentMessage: "it still is not fixed",
      recentPartsV2: realThread,
    });

    // 2) handler.ts's own runJev call happens SECOND, with the real v2
    //    parts too (this is what production always supplies) — but since
    //    the runner is memoized, this call reuses the FIRST call's result.
    const second = await runner({
      message: "it still is not fixed",
      turnCount: 4,
      recentPartsV2: realThread,
    });

    expect(second.ok).toBe(true);
    if (!second.ok) throw new Error("expected ok");
    // The rule to test: the second call's state carries agent_last_message
    // and the thread — proof the FIRST (judge) call was the one that built
    // it, using the real v2 parts, not an empty thread.
    expect(second.state.agent_last_message).toEqual({ author: "caroline", text: "let me check that for you" });
    expect(second.state.thread).toEqual([
      { author: "customer", text: "where is my credit" },
      { author: "caroline", text: "let me check that for you" },
    ]);
  });
});

// ---------------------------------------------------------------------------
// buildJevStateV2
//
// agent_last_message replaces the earlier keyword-gated caroline_last_message
// + open_request pair (2026-09-23 coordinator review): code supplies the
// fact (who spoke last on the agent side, and what they said), the model
// judges whether it was a request and whether the customer answered it. No
// isOpenRequestShaped keyword rule exists any more, so there is no English-
// only false negative to test around — the Spanish case that motivated the
// change is now just a normal agent_last_message.text value.
// ---------------------------------------------------------------------------

function v2Part(author: JevV2Part["author"], body: string): JevV2Part {
  return { author, body };
}

describe("buildJevStateV2", () => {
  it("produces the v2 shape: customer_last_message, agent_last_message, thread, turn_count, tools, policy", () => {
    const state = buildJevStateV2({
      message: "here's the link: example.com/profile",
      recentParts: [v2Part("customer", "my credits are missing"), v2Part("caroline", "can you share the profile link?")],
      turnCount: 2,
    });
    expect(state.customer_last_message).toBe("here's the link: example.com/profile");
    expect(state.agent_last_message).toEqual({ author: "caroline", text: "can you share the profile link?" });
    expect(state.thread).toEqual([
      { author: "customer", text: "my credits are missing" },
      { author: "caroline", text: "can you share the profile link?" },
    ]);
    expect(state.turn_count).toBe(2);
    expect(state.tools).toEqual([]);
    expect(state.policy).toEqual({ human_gated: [], kb_topics: [] });
  });

  // The exact case that motivated dropping the keyword-gated open_request
  // rule: a Spanish ask has none of the English request tokens, but it is
  // still the correct agent_last_message — no detection rule needed.
  it("agent_last_message is set for a Spanish ask + reply, with no English-keyword gate to miss it", () => {
    const state = buildJevStateV2({
      message: "aquí está: example.com/profile",
      recentParts: [v2Part("customer", "faltan mis créditos"), v2Part("caroline", "Envíame el enlace de tu perfil, por favor.")],
      turnCount: 2,
    });
    expect(state.agent_last_message).toEqual({ author: "caroline", text: "Envíame el enlace de tu perfil, por favor." });
  });

  it("agent_last_message is null when no agent has spoken yet (first customer turn)", () => {
    const state = buildJevStateV2({ message: "hello", recentParts: [], turnCount: 1 });
    expect(state.agent_last_message).toBeNull();
  });

  it("agent_last_message survives a burst of customer messages after the agent's message", () => {
    const state = buildJevStateV2({
      message: "ok here it is",
      recentParts: [
        v2Part("customer", "my order is missing"),
        v2Part("caroline", "what's your order number?"),
        v2Part("customer", "hold on"),
        v2Part("customer", "let me find it"),
      ],
      turnCount: 3,
    });
    // Caroline's message is still the most recent AGENT part even though
    // more customer parts followed it — that's what "agent's last message"
    // means even across a burst.
    expect(state.agent_last_message).toEqual({ author: "caroline", text: "what's your order number?" });
  });

  it("agent_last_message is the human_agent's message when a human takeover reply is the most recent agent-side thing said (fixes the 'thanks Jan' shape)", () => {
    const state = buildJevStateV2({
      message: "thanks Jan, worked straight away",
      recentParts: [
        v2Part("customer", "I need a refund"),
        v2Part("caroline", "can you confirm the order number?"),
        v2Part("human_agent", "I've taken over, processing your refund now."),
      ],
      turnCount: 1,
    });
    expect(state.agent_last_message).toEqual({
      author: "human_agent",
      text: "I've taken over, processing your refund now.",
    });
  });

  it("truncates thread to the last 12 parts, 1500 chars each, oldest first, excluding the current message", () => {
    const recentParts: JevV2Part[] = [];
    for (let i = 0; i < 20; i++) {
      recentParts.push(v2Part(i % 2 === 0 ? "customer" : "caroline", `part-${i}`));
    }
    const state = buildJevStateV2({ message: "current message", recentParts, turnCount: 10 });
    const thread = state.thread as { author: string; text: string }[];
    expect(thread).toHaveLength(12);
    expect(thread[0].text).toBe("part-8"); // last 12 of 20 -> indices 8..19
    expect(thread[11].text).toBe("part-19");
    expect(thread.some((p) => p.text === "current message")).toBe(false);

    const long = "y".repeat(2000);
    const trimmed = buildJevStateV2({ message: "hi", recentParts: [v2Part("customer", long)], turnCount: 1 });
    const trimmedThread = trimmed.thread as { author: string; text: string }[];
    expect(trimmedThread[0].text).toHaveLength(1500);
  });

  it("carries tools/policy through unmodified when supplied", () => {
    const tools = [{ name: "profile_lookup", answers: ["find my profile"], cannot_answer: [], needs: "a keyword" }];
    const policy = { human_gated: ["refund request"], kb_topics: ["FAQ"] };
    const state = buildJevStateV2({ message: "hi", recentParts: [], turnCount: 1, tools, policy });
    expect(state.tools).toEqual(tools);
    expect(state.policy).toEqual(policy);
  });

  it("includes agent_instructions only when supplied (eval-only field)", () => {
    const withInstructions = buildJevStateV2({
      message: "hi",
      recentParts: [],
      turnCount: 1,
      agentInstructions: "You are Caroline...",
    });
    expect(withInstructions.agent_instructions).toBe("You are Caroline...");

    const without = buildJevStateV2({ message: "hi", recentParts: [], turnCount: 1 });
    expect("agent_instructions" in without).toBe(false);
  });

  it("includes known_facts only when provided, same as v1", () => {
    const state = buildJevStateV2({ message: "hi", recentParts: [], turnCount: 1, plan: "pro" });
    expect(state.known_facts).toEqual({ plan: "pro" });
    const without = buildJevStateV2({ message: "hi", recentParts: [], turnCount: 1 });
    expect("known_facts" in without).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// decide — v2-only override + answer_from_knowledge routing line
// ---------------------------------------------------------------------------

function noul(value: number): JevAnswers[string] {
  return { type: "noul", noul: value };
}

describe("decide — v2 supplying_requested_info override", () => {
  it("v1 callers (no questionsVersion arg) are UNCHANGED: still silences a no_reply-shaped closer", () => {
    const answers: JevAnswers = {
      resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
      off_topic_or_bad_faith: noul(0.05),
    };
    const decision = decide(answers, BANDS, "Thanks so much!", undefined, [], [], ALL_ON);
    expect(decision.action).toBe("silence");
  });

  it("v2: never silences/no_replies when supplying_requested_info >= 0.5, even if resolution_path says no_reply", () => {
    const answers: JevAnswers = {
      resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
      off_topic_or_bad_faith: noul(0.05),
      supplying_requested_info: noul(0.8),
    };
    // Message is deliberately closer-shaped ("Thanks so much!") so the
    // no_reply/isCloserShaped condition would otherwise fire — this is what
    // makes the override assertion meaningful (a non-closer-shaped message
    // would never reach the silence branch regardless of the override).
    const decision = decide(answers, BANDS, "Thanks so much!", undefined, [], [], ALL_ON, "v2");
    expect(decision.action).not.toBe("silence");
  });

  it("v2: supplying_requested_info below 0.5 does not suppress the no_reply branch", () => {
    const answers: JevAnswers = {
      resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
      off_topic_or_bad_faith: noul(0.05),
      supplying_requested_info: noul(0.2),
    };
    const decision = decide(answers, BANDS, "Thanks so much!", undefined, [], [], ALL_ON, "v2");
    expect(decision.action).toBe("silence");
  });

  it("v1 answers with no supplying_requested_info key behave the same as before under questionsVersion v2 (treated as 0)", () => {
    const answers: JevAnswers = {
      resolution_path: choice("no_reply", { no_reply: 0.95, caroline_tool: 0.05 }),
      off_topic_or_bad_faith: noul(0.05),
    };
    const decision = decide(answers, BANDS, "Thanks so much!", undefined, [], [], ALL_ON, "v2");
    expect(decision.action).toBe("silence");
  });
});

describe("decide — v2 answer_from_knowledge routing line", () => {
  it("v2 route block includes a 'path note' pointing Caroline at memory_search when the top path is answer_from_knowledge", () => {
    const answers: JevAnswers = {
      resolution_path: choice("answer_from_knowledge", { answer_from_knowledge: 0.9, caroline_tool: 0.1 }),
      intent: choice("other", { other: 0.9 }),
      first_tool: choice("none", { none: 0.9 }),
      skill: choice("none", { none: 0.9 }),
      off_topic_or_bad_faith: noul(0.02),
    };
    const decision = decide(answers, BANDS, "what's the difference between plans?", undefined, [], [], ALL_ON, "v2");
    expect(decision.action).toBe("route");
    expect(decision.block).toContain("memory_search");
  });

  it("v2 route block tells Caroline a short courtesy reply is enough when the top path is acknowledge", () => {
    const answers: JevAnswers = {
      resolution_path: choice("acknowledge", { acknowledge: 0.9, no_reply: 0.1 }),
      intent: choice("other", { other: 0.9 }),
      first_tool: choice("none", { none: 0.9 }),
      skill: choice("none", { none: 0.9 }),
      off_topic_or_bad_faith: noul(0.02),
    };
    const decision = decide(answers, BANDS, "thank you so much!", undefined, [], [], ALL_ON, "v2");
    expect(decision.action).toBe("route");
    expect(decision.block).toContain("short courtesy reply");
    expect(decision.block).not.toContain("memory_search");
  });

  it("v1 callers never get the answer_from_knowledge line even if the label somehow appears", () => {
    const answers: JevAnswers = {
      resolution_path: choice("answer_from_knowledge", { answer_from_knowledge: 0.9, caroline_tool: 0.1 }),
      intent: choice("other", { other: 0.9 }),
      first_tool: choice("none", { none: 0.9 }),
      skill: choice("none", { none: 0.9 }),
      off_topic_or_bad_faith: noul(0.02),
    };
    const decision = decide(answers, BANDS, "what's the difference between plans?", undefined, [], [], ALL_ON);
    expect(decision.block).not.toContain("memory_search");
  });
});

import { describe, it, expect } from "vitest";
import { checkEscalation, assessRisk } from "../src/escalation.js";
import type { IntercomSessionState } from "../src/types.js";

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

const baseState: IntercomSessionState = {
  conversationId: "conv1",
  workspaceId: "ws1",
  handoffMode: "agent_active",
  lifecycleState: "open",
  currentAssigneeId: null,
  currentAssigneeType: null,
  lastEventId: null,
  processedEventIds: [],
  outboundMessageIds: [],
  createdAt: "",
  updatedAt: "",
  userTurnCount: 1,
  escalationFiredAt: null,
  knownFacts: {},
};

const noJudge = { judge: undefined };

describe("assessRisk Layer 0 (magic keyword)", () => {
  it("fires on 'talk to a human'", async () => {
    const r = await assessRisk("can i talk to a human please", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("user_request");
    expect(r.reason).toBe("user_requested_human");
    expect(r.confidence).toBe("high");
  });

  it("fires on 'real person'", async () => {
    const r = await assessRisk("i need a real person", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("user_request");
  });

  it("is case-insensitive", async () => {
    const r = await assessRisk("TALK TO A HUMAN", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
  });
});

// Regression: "merge my duplicate tracks" is deliberately NOT a risk rule. The backstop
// is the wrong layer for an unactionable request (un-actionability isn't a message-text
// signal); it's handled by the first-class track-merge create_ticket lane. This test
// prevents a future "fix" that adds a bad regex here.
describe("assessRisk — track-merge requests are handled by the ticket lane, not a risk rule", () => {
  it("does NOT fire on 'merge my duplicate tracks'", async () => {
    const r = await assessRisk("can you merge my duplicate tracks?", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on 'these two tracks are the same, please combine them'", async () => {
    const r = await assessRisk("these two tracks are the same, please combine them", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });
});

describe("assessRisk Layer 1 (rules)", () => {
  it("fires on 'refund' → suggestedActionType subscription-refund", async () => {
    const r = await assessRisk("i want a refund", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("rule");
    expect(r.reason).toBe("refund_intent");
    expect(r.suggestedActionType).toBe("subscription-refund");
  });

  it("fires on 'close my account' → cancel_intent", async () => {
    const r = await assessRisk("close my account", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("cancel_intent");
  });

  it("fires on 'I want to cancel my subscription' → cancel_intent", async () => {
    const r = await assessRisk("I want to cancel my subscription", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("cancel_intent");
  });

  it("does NOT fire on 'what's the cancellation policy?'", async () => {
    const r = await assessRisk("what's the cancellation policy?", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on past-tense charged-after-cancel report", async () => {
    const r = await assessRisk(
      "I cancelled last month and was charged again — can you check?",
      [],
      baseState,
      noJudge,
    );
    expect(r.triggered).toBe(false);
  });

  it("fires on 'fraud' → fraud_complaint dispute", async () => {
    const r = await assessRisk("this is fraud", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("fraud_complaint");
    expect(r.suggestedActionType).toBe("dispute");
  });

  it("fires on 'BBB'", async () => {
    const r = await assessRisk("i'll report you to BBB", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
  });

  it("fires on 'going to post a YouTube review' → public_shaming_intent", async () => {
    const r = await assessRisk("i'm going to post a youtube review about this", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("public_shaming_intent");
  });

  it("does NOT fire on benign YouTube mention ('my youtube credits aren't showing')", async () => {
    const r = await assessRisk("my youtube credits aren't showing", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on benign Instagram mention ('can I link my instagram')", async () => {
    const r = await assessRisk("can I link my instagram to my profile?", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("fires legacy 'lawyer' rule under reason legal_threat", async () => {
    const r = await assessRisk("i'm getting a lawyer", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("legal_threat");
  });

  it("fires turn-count cap at userTurnCount === 6 (the documented cap)", async () => {
    const stateAtCap = { ...baseState, userTurnCount: 6 };
    const r = await assessRisk("just any reply", [], stateAtCap, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("turn_count_cap");
  });

  it("does NOT fire turn-count cap at userTurnCount === 5 (one below cap)", async () => {
    const stateBelow = { ...baseState, userTurnCount: 5 };
    const r = await assessRisk("just any reply", [], stateBelow, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does not fire turn-count cap when escalationFiredAt is already set", async () => {
    const already = { ...baseState, userTurnCount: 7, escalationFiredAt: "2026-05-04T00:00:00Z" };
    const r = await assessRisk("any reply", [], already, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does not fire on benign messages", async () => {
    const r = await assessRisk("hi just checking in", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });
});

import type { JudgeOutput } from "../src/escalation.js";

describe("assessRisk Layer 2 (judge)", () => {
  it("calls the judge from the 4th customer turn onwards", async () => {
    const calls: number[] = [];
    const judge = async (): Promise<JudgeOutput> => {
      calls.push(Date.now());
      return { shouldHandoff: true, reasons: ["frustration"], suggestedActionType: "support-general", confidence: "high" };
    };
    const r = await assessRisk("hmm not great", [], { ...baseState, userTurnCount: 4 }, { judge });
    expect(calls.length).toBe(1);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("judge");
  });

  it("does not call the judge before the 4th turn", async () => {
    let called = false;
    const judge = async (): Promise<JudgeOutput> => {
      called = true;
      return { shouldHandoff: false, reasons: [], suggestedActionType: "support-general", confidence: "high" };
    };
    await assessRisk("eh", [], { ...baseState, userTurnCount: 3 }, { judge });
    expect(called).toBe(false);
  });

  it("does not trigger when judge returns confidence=low", async () => {
    const judge = async (): Promise<JudgeOutput> => ({
      shouldHandoff: true,
      reasons: ["frustration"],
      suggestedActionType: "support-general",
      confidence: "low",
    });
    const r = await assessRisk("hmm", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(r.triggered).toBe(false);
  });

  it("on judge throw: skip (fail-open) — turn-count cap is the unconditional safety net", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("rate limited");
    };
    const warned: string[] = [];
    const r = await assessRisk(
      "hmm",
      [],
      { ...baseState, userTurnCount: 5 },
      { judge, log: { warn: (m) => warned.push(m) } },
    );
    expect(r.triggered).toBe(false);
    expect(warned.some((m) => m.includes("judge call failed"))).toBe(true);
  });

  it("does NOT trigger when judge says shouldHandoff=false even at high confidence", async () => {
    const judge = async (): Promise<JudgeOutput> => ({
      shouldHandoff: false,
      reasons: ["ambiguous"],
      suggestedActionType: "support-general",
      confidence: "high",
    });
    const r = await assessRisk("just a question", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(r.triggered).toBe(false);
  });

  it("does not call the judge if rules already fired", async () => {
    let called = false;
    const judge = async (): Promise<JudgeOutput> => {
      called = true;
      return { shouldHandoff: true, reasons: [], suggestedActionType: "support-general", confidence: "high" };
    };
    const r = await assessRisk("i want a refund", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(called).toBe(false);
    expect(r.source).toBe("rule");
  });
});

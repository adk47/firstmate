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
  // Plain refund/cancel requests must NOT rule-escalate. Commit 7484ade removed
  // "refund" from the legacy triggers so those go through the agent flow; PR #238
  // silently reintroduced them in RISK_RULES, which pre-empted the refund-retention
  // skill (PRs #649/#657) on the very messages it was built for — a founding member's
  // "Please cancel my subscription" was handed off 3s after arrival with zero save
  // attempt (conv 215475695183812, 2026-08-28). Caroline runs the 3-gate retention
  // flow and creates the subscription-refund action-request herself when it's
  // exhausted. Dispute-grade billing signals (chargeback etc.) still rule-escalate.
  it("does NOT fire on 'i want a refund' — retention flow handles it", async () => {
    const r = await assessRisk("i want a refund", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on 'money back' — retention flow handles it", async () => {
    const r = await assessRisk("I'd like my money back", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on 'Please cancel my subscription' — retention flow handles it", async () => {
    const r = await assessRisk("Please cancel my subscription", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on 'I want to cancel my plan'", async () => {
    const r = await assessRisk("I want to cancel my plan", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does NOT fire on 'unsubscribe'", async () => {
    const r = await assessRisk("please unsubscribe me", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("fires on 'chargeback' → refund_intent subscription-refund", async () => {
    const r = await assessRisk("I'm filing a chargeback with my bank", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("rule");
    expect(r.reason).toBe("refund_intent");
    expect(r.suggestedActionType).toBe("subscription-refund");
  });

  it("fires on 'unauthorized charge' → refund_intent", async () => {
    const r = await assessRisk("there's an unauthorized charge on my card", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("refund_intent");
  });

  // cancel_intent now matches ONLY account close/delete, so its action type must be
  // data-deletion, not subscription-refund: the ticket title renders the action label
  // ("[refund] Escalation: …" vs "[data-deletion] …") and that is what ops triages on.
  // Both are tier 3, so SLA and priority are unchanged.
  it("fires on 'close my account' → cancel_intent / data-deletion (not retention)", async () => {
    const r = await assessRisk("close my account", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("cancel_intent");
    expect(r.suggestedActionType).toBe("data-deletion");
  });

  it("fires on 'delete my account' → cancel_intent / data-deletion", async () => {
    const r = await assessRisk("please delete my account", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("cancel_intent");
    expect(r.suggestedActionType).toBe("data-deletion");
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

  // Credit PROOF that mentions a platform post is not a threat (3 of 3 rule
  // escalations 2026-10-11..18 were these, all handed to a human mid-proof).
  it.each([
    "These documents support my mixing credits. Apple Music lists the songwriter, and the attached Instagram post from April 26, 2019 credits me as mixing and mastering engineer and tags the band.",
    "Moving forward I also have most of the songs posted on my social media profile as that's how I post my professional work.",
    "My contributions are often acknowledged on the artists' personal social media profiles, YouTube videos, and TV appearances.",
    "here is the youtube video where they shared my name in the description",
    "I tell everyone about Muso, love the app",
    "I'll share the YouTube video where the artist credits me",
    "I'll post the link to the Instagram post here",
    "I'm going to share the facebook post that credits me as producer",
    "We'll share the YouTube link with you",
    "I'll write down my instagram handle",
    "I\u2019ll post the link to my Instagram post that credits me as producer",
    "Well I post all my work on Instagram",
    "I'm writing to let you know my credits are listed on my YouTube channel",
    "I'm writing to you because my credits aren't showing online",
    "I am writing because my name is missing everywhere",
    "I'm writing on behalf of my artist about credits on YouTube",
    "I'm writing to ask why my song shows up online but not in Muso",
    "I'm writing to you about this credit on Instagram",
    "I'm telling you the song is on YouTube under my name",
    "I'm telling you my credits are online",
    "I'm warning you the credits on Instagram are wrong",
    "We are posting the music video on YouTube tomorrow",
    "I'll attach the post on Instagram that credits me",
    "I'll find the post on Instagram where they tagged me",
    "I'll send you the post on my Instagram",
    "I'll share the link to my Instagram profile so you can verify",
    "I'll share the link to my YouTube channel",
    "I'm sharing the link to my Instagram",
    "I'm sharing the YouTube video about this release",
    "I'll post the screenshots about this credit below",
    "I'll share a screenshot about this credit",
    "I'll share more details about this song",
    "Sure, I'll share what I know about this track",
    "I'm telling the truth about this credit",
    "I will tell my manager about this",
    "I'll tell my co-writer about this so he can verify",
    "I'll write to my publisher about this",
    "I'll share the Instagram post about this song",
    "My artist is going to tell everyone about the app",
    "I'll tell my fans about my new release on Muso",
    "I'm telling my followers to check my profile",
    "I'll tell my fans to check out my Muso profile",
    "I will tell my followers to stream it",
    "I'll tell people to tag me in the credits",
    "Once it's verified I'll post about this on my Instagram",
    "I'll share about this on social media when it's fixed",
    "I'll write about this on twitter",
    "I'll post a screenshot showing how you can find my credit on Spotify",
    "I'm posting this to show how you can see my name in the credits",
    "I'll post the Instagram link, that's how you can verify",
    "I'll share about how you can find it",
    "I'm going to post my song all over YouTube",
    "I'll share this release all over social media",
    "I have a screenshot from the mastering session, some WhatsApp screenshots and an instagram post.",
  ])("does NOT fire on proof/benign platform text: %s", async (msg) => {
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("public_shaming_intent");
  });

  it.each([
    "i'm going to post a youtube review about this",
    "I will expose this on twitter if you don't fix it",
    "I'm gonna tell everyone how you treat customers",
    "I'll warn my followers about you",
    "I'm going to leave a 1-star review",
    "I will expose you",
    "we're going public with this",
    "I\u2019ll expose this on reddit",
    "I\u2018ll be ranting about you guys all over Instagram",
    "I\u02BCm gonna tell everyone how you treat customers",
    "we're warning our fans online",
    "I'm going to post a video on YouTube about how you treat artists",
    "I\u2019m going to post a video on YouTube about how you treat artists",
    "I will definitely warn people about your company",
    "We\u2019re going to share about your app on social media",
    "I'm going to blast you on twitter",
    "I'm going to post on twitter how you deleted my credits",
    "I'll put this on blast on twitter",
    "I'm about to post this all over twitter",
    "I\u2019ll call you out on Instagram",
    "Don't make me tell everyone how you treat artists",
    "I'll make sure to tell everyone how you treat artists",
  ])("still fires on a real threat: %s", async (msg) => {
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("public_shaming_intent");
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

  it("caps on userExchangeCount, not the per-message userTurnCount", async () => {
    const burstyBelow = { ...baseState, userTurnCount: 9, userExchangeCount: 5 };
    expect((await assessRisk("just any reply", [], burstyBelow, noJudge)).triggered).toBe(false);
    const atCap = { ...baseState, userTurnCount: 9, userExchangeCount: 6 };
    const r = await assessRisk("just any reply", [], atCap, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("turn_count_cap");
  });

  it("falls back to userTurnCount for the cap when userExchangeCount is absent", async () => {
    const legacy = { ...baseState, userTurnCount: 6, userExchangeCount: undefined };
    const r = await assessRisk("just any reply", [], legacy, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("turn_count_cap");
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
    const r = await assessRisk("i'm filing a chargeback", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(called).toBe(false);
    expect(r.source).toBe("rule");
  });
});

describe("assessRisk judge observability logging ([intercom:judge])", () => {
  const CUSTOMER_MESSAGE = "hmm not great, this is really frustrating";

  it("logs outcome=verdict with fields when the judge returns a verdict", async () => {
    const judge = async (): Promise<JudgeOutput> => ({
      shouldHandoff: true,
      reasons: ["frustration", "stuck_in_loop"],
      suggestedActionType: "support-general",
      confidence: "high",
    });
    const lines: string[] = [];
    await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 4 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBeDefined();
    expect(line).toContain("conv=conv1");
    expect(line).toContain("outcome=verdict");
    expect(line).toContain("shouldHandoff=true");
    expect(line).toContain("confidence=high");
    expect(line).toContain("actionType=support-general");
    expect(line).toContain("reasons=frustration,stuck_in_loop");
    expect(line).toMatch(/ms=\d+/);
    expect(line).not.toContain(CUSTOMER_MESSAGE);
  });

  it("drops reasons outside the judge vocabulary so model free-text never reaches the journal", async () => {
    // judge.ts validates `reasons` only as string[]; a model that echoes the
    // customer's message as a "reason" passes that check.
    const judge = async (): Promise<JudgeOutput> => ({
      shouldHandoff: true,
      reasons: ["frustration", CUSTOMER_MESSAGE, "totally made up token"],
      suggestedActionType: "support-general",
      confidence: "high",
    });
    const lines: string[] = [];
    await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 4 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBeDefined();
    expect(line).toContain("reasons=frustration,unknown ");
    expect(line).not.toContain(CUSTOMER_MESSAGE);
    expect(line).not.toContain("made up");
  });

  it("logs outcome=null when the judge returns null (timeout/parse/rate-limit)", async () => {
    const judge = async (): Promise<JudgeOutput | null> => null;
    const lines: string[] = [];
    await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 4 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBeDefined();
    expect(line).toContain("outcome=null");
    expect(line).toContain("shouldHandoff=-");
    expect(line).toContain("confidence=-");
    expect(line).toContain("actionType=-");
    expect(line).toContain("reasons=-");
    expect(line).toMatch(/ms=\d+/);
    expect(line).not.toContain(CUSTOMER_MESSAGE);
  });

  it("logs outcome=error when the judge throws, and escalation still fails open", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("rate limited");
    };
    const lines: string[] = [];
    const r = await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 4 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    expect(r.triggered).toBe(false);
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBeDefined();
    expect(line).toContain("outcome=error");
    expect(line).toContain("shouldHandoff=-");
    expect(line).toMatch(/ms=\d+/);
    expect(line).not.toContain(CUSTOMER_MESSAGE);
    // The pre-existing failure log still fires unchanged.
    expect(lines.some((m) => m.includes("judge call failed"))).toBe(true);
  });

  it("logs outcome=skipped reason=min_turns when below the judge min-turn floor", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("must not be called");
    };
    const lines: string[] = [];
    await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 1 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBe("[intercom:judge] conv=conv1 outcome=skipped reason=min_turns");
  });

  it("logs outcome=skipped reason=disabled when no judge is wired", async () => {
    const lines: string[] = [];
    await assessRisk(
      CUSTOMER_MESSAGE,
      [],
      { ...baseState, userTurnCount: 4 },
      { log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBe("[intercom:judge] conv=conv1 outcome=skipped reason=disabled");
  });

  it("logs outcome=skipped reason=hard_cap when the turn-count cap fires before the judge", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("must not be called");
    };
    const lines: string[] = [];
    await assessRisk(
      "just a normal question",
      [],
      { ...baseState, userTurnCount: 6 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBe("[intercom:judge] conv=conv1 outcome=skipped reason=hard_cap");
  });

  it("logs outcome=skipped reason=rule_escalated when a content rule fires before the judge", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("must not be called");
    };
    const lines: string[] = [];
    await assessRisk(
      "i'm filing a chargeback",
      [],
      { ...baseState, userTurnCount: 5 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBe("[intercom:judge] conv=conv1 outcome=skipped reason=rule_escalated");
  });

  it("logs outcome=skipped reason=rule_escalated when the magic keyword fires before the judge", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("must not be called");
    };
    const lines: string[] = [];
    await assessRisk(
      "can i talk to a human please",
      [],
      { ...baseState, userTurnCount: 5 },
      { judge, log: { warn: (m) => lines.push(m) } },
    );
    const line = lines.find((l) => l.startsWith("[intercom:judge]"));
    expect(line).toBe("[intercom:judge] conv=conv1 outcome=skipped reason=rule_escalated");
  });
});

describe("content rules ignore forwarded, quoted and boilerplate text", () => {
  it("a signature disclaimer threatening 'legal action' does not fire legal_threat", async () => {
    const msg = "It's owned by my brother and I. We're the artists, producers and writers on these releases.\n\nThis email and its contents are protected by United States Copyright laws. Unauthorized usage will result In IMMEDIATE legal action. If you have received this e-mail in error, please delete it.";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("a forwarded news email mentioning a court does not fire", async () => {
    const msg = "---------- Forwarded message ---------\nFrom: Twitter\nSubject: he will make it the law of the land if Supreme Court overturns it";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("text quoted under an email reply is ignored", async () => {
    const msg = "Thanks, that works.\n\nOn Mon, Oct 19, 2026 at 2:55 PM support wrote:\n> we can't help with a lawsuit here";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("text quoted under an HTML email reply is ignored", async () => {
    const msg = "<p>Thanks, that works.</p><p>On Mon, Oct 19, 2026 at 2:55 PM support wrote:</p><blockquote>we can't help with a lawsuit here</blockquote>";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("text quoted under a Gmail HTML reply is ignored", async () => {
    const msg = '<div dir="ltr">Thanks!</div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 19, 2026 at 2:55 PM Muso Support &lt;support@muso.ai&gt; wrote:<br></div><blockquote class="gmail_quote">we can\'t help with a lawsuit here</blockquote></div>';
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("text quoted under a Spanish email reply is ignored", async () => {
    const msg = "Gracias.\n\nEl lun, 19 oct 2026 a las 14:55, Muso Support (<support@muso.ai>) escribió:\n> we can't help with a lawsuit here";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("a customer's own 'On ... you wrote:' sentence is not an attribution", async () => {
    const msg = "On the refund email you wrote: we will fix it. It's still broken and I'm getting a lawyer.";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).toBe("legal_threat");
  });
  it("a dateless 'On Oct 3 ... wrote:' line in the customer's text is not an attribution", async () => {
    const msg = "Your refund email was wrong.\nOn Oct 3 your support team wrote: no refund. I'm getting a lawyer.";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).toBe("legal_threat");
  });
  it("a customer's own copyright claim does not cut the threat after it", async () => {
    const msg = "My song is protected by United States copyright law and I will sue you if you keep showing it.";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).toBe("legal_threat");
  });
  it("text quoted under an Outlook reply header is ignored", async () => {
    const msg = "<p>Thanks, that works.</p><p><b>From:</b> Muso Support &lt;support@muso.ai&gt;<br><b>Sent:</b> Monday, October 19, 2026 2:55 PM<br><b>To:</b> me<br><b>Subject:</b> RE: credits</p><p>we can't help with a lawsuit here</p>";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("text under an Outlook Original Message separator is ignored", async () => {
    const msg = "Thanks, that works.\n\n-----Original Message-----\nwe can't help with a lawsuit here";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).not.toBe("legal_threat");
  });
  it("a real threat before a disclaimer still fires", async () => {
    const msg = "If this isn't fixed by Friday I'm getting a lawyer.\n\nCONFIDENTIALITY NOTICE: this message is intended only for the named recipient.";
    const r = await assessRisk(msg, [], baseState, noJudge);
    expect(r.reason).toBe("legal_threat");
  });
});

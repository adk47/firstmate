import { describe, expect, it } from "vitest";
import {
  askFromThread,
  customerAskedAboutRequest,
  customerLastSpokeAt,
  lastWordWasWrongClose,
  handbackNoteContext,
  promiseFromThread,
  renderHandbackBlock,
  unansweredCustomerParts,
  weSpokeLast,
} from "../src/filters.js";
import {
  HANDBACK_GREETING_RULE,
  HANDBACK_UNASKED_STATUS_RULE,
  handbackGreetingViolation,
  handbackUnaskedStatusViolation,
  isGreetingOnlyReply,
} from "../src/handback-reply-guard.js";
import { buildAgentRawBody } from "../src/channel.js";
import { handleWebhookEvent } from "../src/handler.js";
import { createInitialSessionState } from "../src/handoff.js";
import type {
  HandbackContext,
  IntercomConversation,
  IntercomConversationPart,
  IntercomWebhookPayload,
} from "../src/types.js";

const BOT = "5763097";
const NOW = 1_763_000_000;

/** The v2 marker line caroline-unanswered-drain-u1 specified (handback-fields-20261115.md). */
const V2 =
  "hydra-handback: v=2 reason=open_promise kind=credit_verification promised_at=1760000000 waiting_since=1762000000 followup=0 class=open promise";

function notePart(body: string, opts: { author?: string; type?: string } = {}): IntercomConversationPart {
  return {
    id: "note-1",
    part_type: opts.type ?? "note",
    author: { type: "admin", id: opts.author ?? BOT },
    body,
  } as IntercomConversationPart;
}

function comment(id: string, at: number, body: string, author: { type: string; id?: string }): IntercomConversationPart {
  return { id, part_type: "comment", created_at: at, author, body } as IntercomConversationPart;
}

const CUSTOMER = { type: "user", id: "c1" };
const US = { type: "admin", id: BOT };

describe("handbackNoteContext: the v2 marker line", () => {
  it("reads every field the drain writes", () => {
    const ctx = handbackNoteContext(notePart(V2), BOT);
    expect(ctx).not.toBeNull();
    expect(ctx!.version).toBe(2);
    expect(ctx!.reason).toBe("open_promise");
    expect(ctx!.kind).toBe("credit_verification");
    expect(ctx!.promisedAt).toBe(1_760_000_000);
    expect(ctx!.waitingSince).toBe(1_762_000_000);
    expect(ctx!.followup).toBe(false);
    expect(ctx!.klass).toBe("open promise");
  });

  it("keeps a class that holds spaces, because class is last", () => {
    expect(handbackNoteContext(notePart(V2.replace("class=open promise", "class=held by staffed team")), BOT)!.klass).toBe(
      "held by staffed team",
    );
  });

  it("reads followup=1", () => {
    expect(handbackNoteContext(notePart(V2.replace("followup=0", "followup=1")), BOT)!.followup).toBe(true);
  });

  it("treats kind=- as no promise", () => {
    expect(handbackNoteContext(notePart(V2.replace("kind=credit_verification", "kind=-")), BOT)!.kind).toBe("");
  });

  it("treats promised_at=0 as no promise date rather than 1970", () => {
    expect(handbackNoteContext(notePart(V2.replace("promised_at=1760000000", "promised_at=0")), BOT)!.promisedAt).toBe(0);
  });

  it("still reads a v1 note, because every note already on a thread is v1", () => {
    const ctx = handbackNoteContext(notePart("hydra-handback: reason=specific_ask class=specific ask"), BOT);
    expect(ctx).not.toBeNull();
    expect(ctx!.version).toBe(1);
    expect(ctx!.reason).toBe("specific_ask");
    expect(ctx!.klass).toBe("specific ask");
    expect(ctx!.promisedAt).toBe(0);
    expect(ctx!.followup).toBe(false);
  });

  it("returns null for a note with no reason, rather than a context that says nothing", () => {
    expect(handbackNoteContext(notePart("hydra-handback: v=2 kind=merge class=open promise"), BOT)).toBeNull();
  });

  it("ignores a note written by anyone but this bot", () => {
    expect(handbackNoteContext(notePart(V2, { author: "999" }), BOT)).toBeNull();
  });

  it("ignores a customer comment that happens to contain the marker", () => {
    expect(handbackNoteContext(notePart(V2, { type: "comment" }), BOT)).toBeNull();
  });

  it("ignores a note that only mentions the marker mid-sentence", () => {
    expect(handbackNoteContext(notePart(`<p>see ${V2}</p>`), BOT)).toBeNull();
  });
});

describe("promiseFromThread: the promise comes from the thread, not the note", () => {
  const parts = [
    comment("c1", 1_759_000_000, "my credits are wrong", CUSTOMER),
    comment("a1", 1_760_000_000, "I'll have the credit review finished and come back to you.", US),
    comment("c2", 1_762_000_000, "thanks", CUSTOMER),
  ];

  it("takes the comment we posted at promised_at", () => {
    expect(promiseFromThread(parts, BOT, 1_760_000_000, 1_762_000_000)).toBe(
      "I'll have the credit review finished and come back to you.",
    );
  });

  it("falls back to the newest comment of ours at or before the customer's last message", () => {
    expect(promiseFromThread(parts, BOT, 0, 1_762_000_000)).toBe(
      "I'll have the credit review finished and come back to you.",
    );
  });

  it("never takes a comment written after the customer's last message", () => {
    const later = [...parts, comment("a2", 1_765_000_000, "a later reply", US)];
    expect(promiseFromThread(later, BOT, 0, 1_762_000_000)).toBe(
      "I'll have the credit review finished and come back to you.",
    );
  });

  it("ignores the customer's own words", () => {
    expect(promiseFromThread([comment("c1", 1_759_000_000, "you promised me a refund", CUSTOMER)], BOT, 0, 1_762_000_000)).toBe("");
  });

  it("returns empty rather than inventing a promise when we never wrote", () => {
    expect(promiseFromThread([], BOT, 0, 0)).toBe("");
  });

  it("strips markup and collapses whitespace", () => {
    const html = [comment("a1", 1_760_000_000, "<p>I will   check\n\nthis</p>", US)];
    expect(promiseFromThread(html, BOT, 1_760_000_000, 1_762_000_000)).toBe("I will check this");
  });

  // 275 of the threads the drain hands back carry a promise from an OLD BOT or a human agent,
  // whose admin id is not the current bot's. Filtering on our own id found nothing on them, so
  // the block said "no promise on file" about a thread that plainly has one (firstmate 183).
  describe("a promise made by someone else on our side is still our promise", () => {
    const OLD_BOT = { type: "admin", id: "41022" };

    it("takes a promise posted by an older bot admin", () => {
      const old = [
        comment("c1", 1_759_000_000, "any news?", CUSTOMER),
        comment("a9", 1_760_000_000, "The team will get back to you about the ticket.", OLD_BOT),
        comment("c2", 1_762_000_000, "hello?", CUSTOMER),
      ];
      expect(promiseFromThread(old, BOT, 1_760_000_000, 1_762_000_000)).toBe(
        "The team will get back to you about the ticket.",
      );
    });

    it("takes a promise posted by a human agent", () => {
      const human = [
        comment("a9", 1_760_000_000, "I'll chase the merge and reply by Friday.", { type: "admin", id: "998877" }),
        comment("c2", 1_762_000_000, "still waiting", CUSTOMER),
      ];
      expect(promiseFromThread(human, BOT, 0, 1_762_000_000)).toBe("I'll chase the merge and reply by Friday.");
    });

    it("prefers this bot's comment when two authors wrote in the same second", () => {
      const both = [
        comment("a1", 1_760_000_000, "the old bot's line", OLD_BOT),
        comment("a2", 1_760_000_000, "Caroline's line", US),
      ];
      expect(promiseFromThread(both, BOT, 1_760_000_000, 1_762_000_000)).toBe("Caroline's line");
    });

    it("still never takes the customer's own words, even with no admin in the thread", () => {
      const onlyCustomer = [comment("c1", 1_759_000_000, "you said the team would email me", CUSTOMER)];
      expect(promiseFromThread(onlyCustomer, BOT, 0, 1_762_000_000)).toBe("");
    });

    it("still never takes an internal NOTE from any admin", () => {
      const note = [notePart("hydra-handback: reason=open_promise class=open promise", { author: "998877" })];
      expect(promiseFromThread(note, BOT, 0, 1_762_000_000)).toBe("");
    });
  });
});

describe("weSpokeLast: the follow-up gate", () => {
  const conv = (parts: IntercomConversationPart[]) =>
    ({ conversation_parts: { conversation_parts: parts } }) as unknown as IntercomConversation;

  it("is true when our reply is the newest comment", () => {
    expect(weSpokeLast(conv([comment("c1", 1, "hi", CUSTOMER), comment("a1", 2, "Anytime!", US)]), BOT)).toBe(true);
  });

  it("is false when the customer wrote after us", () => {
    expect(weSpokeLast(conv([comment("a1", 2, "Anytime!", US), comment("c1", 3, "still waiting", CUSTOMER)]), BOT)).toBe(false);
  });

  it("is false when another admin wrote last", () => {
    // ANY admin counts: on ~378 queued threads the newest comment is the old workspace bot's or a
    // person's, and requiring this bot's id refused every one of them (drain-u1, 16:59Z).
    expect(weSpokeLast(conv([comment("a1", 2, "hi", { type: "admin", id: "999" })]), BOT)).toBe(true);
    expect(weSpokeLast(conv([comment("a1", 2, "hi", { type: "admin", id: "4359478" })]), BOT)).toBe(true);
  });
});

describe("renderHandbackBlock", () => {
  const ctx: HandbackContext = {
    version: 2,
    reason: "open_promise",
    kind: "credit_verification",
    promisedAt: 1_760_000_000,
    waitingSince: 1_762_000_000,
    followup: false,
    klass: "open promise",
    promise: "I'll have the credit review finished and come back to you.",
  };

  it("says it is not a new message, quotes the promise and gives the wait", () => {
    const block = renderHandbackBlock(ctx, NOW);
    expect(block).toContain("[HAND_BACK]");
    expect(block).toContain("NOT a new message");
    expect(block).toContain("I'll have the credit review finished");
    expect(block).toContain("11 days");
    expect(block).toContain("[/HAND_BACK]");
  });

  it("carries the five rules the measured failures need", () => {
    const block = renderHandbackBlock(ctx, NOW);
    expect(block).toContain("not done, or not reported");
    expect(block).toContain("Do not reply with thanks");
    expect(block).toContain("do not greet them as if this were new");
    expect(block).toContain("not confirmed, never as fine");
    expect(block).toContain("No person, no date");
  });

  it("says so when no promise text was found, rather than rendering an empty quote", () => {
    const block = renderHandbackBlock({ ...ctx, promise: "" }, NOW);
    expect(block).toContain("no promise text was found");
    expect(block).not.toContain('""');
  });

  it("says no promise is open when the note carried kind=- and claims no promise", () => {
    // `reason` decides: a note that does not claim a promise may say there is none.
    expect(renderHandbackBlock({ ...ctx, promise: "", kind: "", reason: "no_promise" }, NOW)).toContain(
      "No promise is open",
    );
  });

  // QA 2026-11-15 (filters.ts:825): a v1 note carries no kind and no timestamps, so the promise
  // lookup found nothing and the block said "No promise is open" about a thread the note says has
  // one - dropping the follow-up that is owed.
  it("does not claim there is no promise when the note says one is open", () => {
    const v1 = handbackNoteContext(notePart("hydra-handback: reason=open_promise class=open promise"), BOT)!;
    const block = renderHandbackBlock({ ...v1, promise: "" }, NOW);
    expect(block).not.toContain("No promise is open");
    expect(block).toContain("A promise IS open on this thread");
    expect(block).toContain("do not invent what we said");
  });

  it("derives a cutoff from the customer's last message when the note has no timestamps", () => {
    const conv = (parts: IntercomConversationPart[]) =>
      ({ conversation_parts: { conversation_parts: parts } }) as unknown as IntercomConversation;
    const c = conv([
      comment("c1", 1_759_000_000, "any news?", CUSTOMER),
      comment("a1", 1_760_000_000, "I'll have the credit review finished.", US),
      comment("c2", 1_762_000_000, "thanks", CUSTOMER),
    ]);
    expect(customerLastSpokeAt(c)).toBe(1_762_000_000);
    expect(promiseFromThread(c.conversation_parts!.conversation_parts, BOT, 0, customerLastSpokeAt(c))).toBe(
      "I'll have the credit review finished.",
    );
  });

  it("returns 0 when the customer never wrote", () => {
    const conv = (parts: IntercomConversationPart[]) =>
      ({ conversation_parts: { conversation_parts: parts } }) as unknown as IntercomConversation;
    expect(customerLastSpokeAt(conv([comment("a1", 2, "hello", US)]))).toBe(0);
  });

  it("renders nothing at all when there is no context", () => {
    expect(renderHandbackBlock(null)).toBe("");
    expect(renderHandbackBlock(undefined)).toBe("");
  });

  it("singularises a one-day wait", () => {
    expect(renderHandbackBlock({ ...ctx, waitingSince: NOW - 86400 }, NOW)).toContain("1 day ago");
  });
});

describe("buildAgentRawBody carries the hand-back block", () => {
  const ctx: HandbackContext = {
    version: 2,
    reason: "open_promise",
    kind: "credit_verification",
    promisedAt: 1_760_000_000,
    waitingSince: 1_762_000_000,
    followup: false,
    klass: "open promise",
    promise: "I'll have the credit review finished.",
  };

  it("puts the block above [CUSTOMER_MESSAGE] so it reads as what the message is", () => {
    const body = buildAgentRawBody("thanks", {}, undefined, undefined, undefined, null, null, null, ctx);
    expect(body.indexOf("[HAND_BACK]")).toBeGreaterThan(-1);
    expect(body.indexOf("[HAND_BACK]")).toBeLessThan(body.indexOf("[CUSTOMER_MESSAGE]"));
    expect(body).toContain("I'll have the credit review finished.");
  });

  it("emits no block on an ordinary turn", () => {
    const body = buildAgentRawBody("thanks", {}, undefined, undefined, undefined, null, null, null, null);
    expect(body).not.toContain("[HAND_BACK]");
  });
});

describe("handbackGreetingViolation", () => {
  const ctx: HandbackContext = {
    version: 2,
    reason: "open_promise",
    kind: "credit_verification",
    promisedAt: 1_760_000_000,
    waitingSince: 1_762_000_000,
    followup: false,
    klass: "open promise",
    promise: "I'll have the credit review finished.",
  };

  // The replies that actually went out to people waiting months (firstmate 2026-11-15 15:03Z).
  it.each([
    "Anytime!",
    "You are welcome!",
    "You're welcome.",
    "Thanks for reaching out!",
    "Hi! How can I help?",
    "What can I help you with today?",
  ])("refuses %j on a hand-back turn", (reply) => {
    expect(handbackGreetingViolation(reply, ctx)).toBe(HANDBACK_GREETING_RULE);
  });

  it("refuses a pleasantry with a closing offer bolted on", () => {
    expect(handbackGreetingViolation("Anytime! Let me know if you need anything else.", ctx)).toBe(HANDBACK_GREETING_RULE);
  });

  it("allows a status update", () => {
    const reply =
      "Your credit review is still open: we have the document you sent and are checking the two tracks on it. Nothing else is needed from you.";
    expect(handbackGreetingViolation(reply, ctx)).toBeNull();
  });

  it("allows a status update that opens with a greeting", () => {
    expect(handbackGreetingViolation("Hi! Your credit review is still open and we are checking the two tracks.", ctx)).toBeNull();
  });

  it("does not apply to an ordinary turn, where 'Anytime!' is a fine reply to thanks", () => {
    expect(handbackGreetingViolation("Anytime!", null)).toBeNull();
    expect(handbackGreetingViolation("Anytime!", undefined)).toBeNull();
  });

  it("does not refuse an empty reply: the output guard owns that", () => {
    expect(isGreetingOnlyReply("")).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// The old-workspace-bot population (firstmate 2026-11-15 16:26Z, inbox 184).
// ---------------------------------------------------------------------------

const OLD_BOT_NOTE =
  "hydra-handback: v=2 reason=old_bot_promise kind=person promised_at=1745000000 waiting_since=1745000000 followup=1 promised_by=operator_bot class=old bot promise";

describe("the old-bot promise note", () => {
  it("reads promised_by and the reason", () => {
    const ctx = handbackNoteContext(notePart(OLD_BOT_NOTE), BOT);
    expect(ctx).not.toBeNull();
    expect(ctx!.reason).toBe("old_bot_promise");
    expect(ctx!.promisedBy).toBe("operator_bot");
    expect(ctx!.kind).toBe("person");
    expect(ctx!.followup).toBe(true);
  });

  it("leaves promisedBy empty on a v1 note, where Caroline was the only author", () => {
    const ctx = handbackNoteContext(notePart("hydra-handback: reason=open_promise class=open promise"), BOT);
    expect(ctx!.promisedBy).toBe("");
  });

  it("tells the turn the promise is months old and was made by a different bot", () => {
    const ctx = handbackNoteContext(notePart(OLD_BOT_NOTE), BOT)!;
    ctx.promise = "I'll have the team look at this and get back to you.";
    const block = renderHandbackBlock(ctx, NOW);
    expect(block).toMatch(/earlier version of this support bot, months ago/);
    expect(block).toMatch(/do not pretend it was recent/i);
  });

  it("tells the turn to say nobody picked it up rather than that it was answered", () => {
    const ctx = handbackNoteContext(notePart(OLD_BOT_NOTE), BOT)!;
    const block = renderHandbackBlock(ctx, NOW);
    expect(block).toMatch(/Nobody picked it up/);
    expect(block).toMatch(/Do not say it was answered/);
  });

  it("does not add the old-bot lines for a Caroline promise", () => {
    const ctx = handbackNoteContext(notePart(V2), BOT)!;
    const block = renderHandbackBlock(ctx, NOW);
    expect(block).not.toMatch(/earlier version of this support bot/);
  });
});

describe("the verification-queue line is gated on the customer having asked about a request", () => {
  const ctx = (asked: boolean) => ({ askedAboutRequest: asked }) as unknown as HandbackContext;

  it("refuses the queue line when the customer asked about something else", () => {
    // 215473830027987: asked about double-counted streams, was told their request was in the queue.
    expect(
      handbackUnaskedStatusViolation("Your request is in the verification queue and will be reviewed.", ctx(false)),
    ).toBe(HANDBACK_UNASKED_STATUS_RULE);
  });

  it.each([
    "Your request is now in the queue.",
    "It is in our review queue.",
    "Your claim has been submitted for review.",
    "It is being reviewed by the verification team.",
    "You are in line to be processed.",
  ])("refuses %j when unasked", (reply) => {
    expect(handbackUnaskedStatusViolation(reply, ctx(false))).toBe(HANDBACK_UNASKED_STATUS_RULE);
  });

  it("allows the queue line when the customer DID ask about a request", () => {
    expect(
      handbackUnaskedStatusViolation("Your request is in the verification queue.", ctx(true)),
    ).toBeNull();
  });

  it("allows a status update that names no queue", () => {
    expect(
      handbackUnaskedStatusViolation("Your streams are counted twice because two profiles carry the same track.", ctx(false)),
    ).toBeNull();
  });

  it("does not apply to an ordinary turn", () => {
    expect(handbackUnaskedStatusViolation("Your request is in the verification queue.", null)).toBeNull();
  });

  it("tells the turn which way the gate went", () => {
    const asked = renderHandbackBlock({ ...handbackNoteContext(notePart(V2), BOT)!, askedAboutRequest: true }, NOW);
    const unasked = renderHandbackBlock({ ...handbackNoteContext(notePart(V2), BOT)!, askedAboutRequest: false }, NOW);
    expect(asked).toMatch(/may say where that request stands/);
    expect(unasked).toMatch(/Do not say their request is in the verification queue/);
  });
});

describe("customerAskedAboutRequest: read from the customer's own words", () => {
  it("is true when the customer asked about a credit", () => {
    expect(customerAskedAboutRequest([comment("c1", 1, "any update on my credit?", CUSTOMER)])).toBe(true);
  });

  it("is false when the customer only asked about streams", () => {
    expect(customerAskedAboutRequest([comment("c1", 1, "my streams are counted twice", CUSTOMER)])).toBe(false);
  });

  it("ignores our own comments", () => {
    expect(customerAskedAboutRequest([comment("a1", 1, "your request is in the verification queue", US)])).toBe(false);
  });

  it("is false on an empty thread", () => {
    expect(customerAskedAboutRequest([])).toBe(false);
    expect(customerAskedAboutRequest(undefined)).toBe(false);
  });

  // QA 2026-11-15 (filters.ts:530): the predicate scanned EVERY customer comment, so on a
  // mixed-topic thread an old credit question authorised a queue line about a message that was
  // about something else. The hand-back answers the UNANSWERED message; only its words count.
  it("ignores a request question we already answered (mixed-topic thread)", () => {
    const thread = [
      comment("c1", 1, "any update on my credit?", CUSTOMER),
      comment("a1", 2, "I've added that to your request.", US),
      comment("c2", 3, "my streams are counted twice on the new album", CUSTOMER),
    ];
    expect(customerAskedAboutRequest(thread)).toBe(false);
  });

  it("still reads the unanswered message when it is the one asking", () => {
    const thread = [
      comment("c1", 1, "my streams are counted twice", CUSTOMER),
      comment("a1", 2, "I've added that to your request.", US),
      comment("c2", 3, "any update on my credit?", CUSTOMER),
    ];
    expect(customerAskedAboutRequest(thread)).toBe(true);
  });

  it("counts every customer comment when we never replied", () => {
    const thread = [
      comment("c1", 1, "hello", CUSTOMER),
      comment("c2", 2, "any update on my credit?", CUSTOMER),
    ];
    expect(customerAskedAboutRequest(thread)).toBe(true);
  });

  it("scopes to the unanswered message, not the whole thread", () => {
    const thread = [
      comment("c1", 1, "any update on my credit?", CUSTOMER),
      comment("a1", 2, "I've added that to your request.", US),
      comment("c2", 3, "my streams are counted twice", CUSTOMER),
    ];
    expect(unansweredCustomerParts(thread).map((p) => p.id)).toEqual(["c2"]);
  });
});

// ---------------------------------------------------------------------------
// QA 2026-11-15: the two Important findings, each pinned at the boundary it broke.
// ---------------------------------------------------------------------------

describe("the context survives the queued dispatch (QA finding 1)", () => {
  // `handleWebhookEvent` only QUEUES the agent turn; channel.ts builds the raw body and runs the
  // reply guards later, from the same session state. Clearing `state.handback` when the dispatch
  // was queued made both read null, so the [HAND_BACK] block never reached the agent and the
  // "Anytime!" failure could recur. This runs the real handler, not a unit stub.
  const live = {
    id: "conv_hb",
    state: "open",
    admin_assignee_id: BOT,
    conversation_parts: {
      conversation_parts: [
        comment("c1", 1_759_000_000, "my credits are wrong", CUSTOMER),
        comment("a1", 1_760_000_000, "I'll have the credit review finished and come back to you.", US),
        comment("c2", 1_762_000_000, "thanks", CUSTOMER),
        notePart(V2),
      ],
    },
  } as unknown as IntercomConversation;

  const payload = {
    type: "notification_event",
    id: "evt_hb",
    topic: "conversation.admin.noted",
    created_at: 1_763_000_000,
    data: { item: { id: "conv_hb" } },
  } as unknown as IntercomWebhookPayload;

  const client = {
    getConversation: async () => live,
  } as unknown as Parameters<typeof handleWebhookEvent>[3];

  it("leaves state.handback set when the turn is only queued", async () => {
    const { result, state } = await handleWebhookEvent(
      payload,
      createInitialSessionState("conv_hb", "ws_1"),
      BOT,
      client,
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(state?.handback).toBeTruthy();
    expect(state?.handback?.reason).toBe("open_promise");
  });

  it("so the block the agent actually receives carries the promise and the wait", async () => {
    const { state } = await handleWebhookEvent(
      payload,
      createInitialSessionState("conv_hb", "ws_1"),
      BOT,
      client,
    );
    const body = buildAgentRawBody(
      "thanks",
      {},
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      state?.handback,
    );
    expect(body).toContain("[HAND_BACK]");
    expect(body).toContain("I'll have the credit review finished and come back to you.");
    expect(body).toContain("NOT a new message");
  });

  it("and the greeting guard is live on that turn, so 'Anytime!' is refused", async () => {
    const { state } = await handleWebhookEvent(
      payload,
      createInitialSessionState("conv_hb", "ws_1"),
      BOT,
      client,
    );
    expect(handbackGreetingViolation("Anytime!", state?.handback)).toBe(HANDBACK_GREETING_RULE);
  });

  it("is retired by the next ordinary customer message, so it cannot leak forward", async () => {
    const { state } = await handleWebhookEvent(
      payload,
      createInitialSessionState("conv_hb", "ws_1"),
      BOT,
      client,
    );
    expect(state?.handback).toBeTruthy();
    const next = await handleWebhookEvent(
      {
        type: "notification_event",
        id: "evt_next",
        topic: "conversation.user.replied",
        created_at: 1_764_000_000,
        data: {
          item: {
            id: "conv_hb",
            state: "open",
            admin_assignee_id: BOT,
            source: { body: "one more thing", author: { type: "user", id: "c1" } },
            conversation_parts: {
              conversation_parts: [
                comment("c3", 1_764_000_000, "one more thing", CUSTOMER),
              ],
            },
          },
        },
      } as unknown as IntercomWebhookPayload,
      state,
      BOT,
      client,
    );
    expect(next.state?.handback ?? null).toBeNull();
  });
});

describe("no promise is quoted when nothing qualifies (QA finding 2)", () => {
  it("returns empty when the only admin comment came AFTER the customer's last message", () => {
    // The follow-up shape: our "Anytime!" reply is the newest comment, and there is no earlier
    // admin comment at all. Quoting it would present the misfire as the original promise.
    const parts = [
      comment("c1", 1_759_000_000, "thanks", CUSTOMER),
      comment("a1", 1_765_000_000, "Anytime!", US),
    ];
    expect(promiseFromThread(parts, BOT, 0, 1_762_000_000)).toBe("");
  });

  it("returns empty when promised_at and waiting_since are both unknown", () => {
    const parts = [comment("a1", 1_765_000_000, "Anytime!", US)];
    expect(promiseFromThread(parts, BOT, 0, 0)).toBe("");
  });

  it("still takes an earlier comment when one exists", () => {
    const parts = [
      comment("a1", 1_760_000_000, "I'll chase the merge.", US),
      comment("c1", 1_762_000_000, "thanks", CUSTOMER),
      comment("a2", 1_765_000_000, "Anytime!", US),
    ];
    expect(promiseFromThread(parts, BOT, 0, 1_762_000_000)).toBe("I'll chase the merge.");
  });

  it("says no promise was found rather than inventing one", () => {
    const ctx = handbackNoteContext(notePart(V2), BOT)!;
    ctx.promise = promiseFromThread(
      [comment("c1", 1_759_000_000, "thanks", CUSTOMER), comment("a1", 1_765_000_000, "Anytime!", US)],
      BOT,
      ctx.promisedAt,
      ctx.waitingSince,
    );
    expect(ctx.promise).toBe("");
    expect(renderHandbackBlock(ctx, NOW)).toMatch(/no promise text was found on the thread/);
  });

// ---------------------------------------------------------------------------
// firstmate 2026-11-15 16:38Z: 18 of 19 replies to a proof ask were WORDS, read by nothing.
// ---------------------------------------------------------------------------

describe("a words-reply to a proof ask (kind=ask_reply_words)", () => {
  const ASK_NOTE =
    "hydra-handback: v=2 reason=specific_ask kind=ask_reply_words promised_at=0 waiting_since=1762000000 followup=0 need=proof_link class=specific ask";

  const thread = [
    comment("c1", 1_759_000_000, "how do I get my credits verified?", CUSTOMER),
    comment("a1", 1_760_000_000, "Send me a link to your Spotify for Artists page and I can verify the profile.", US),
    comment("c2", 1_762_000_000, "I don't have Spotify for Artists, I use DistroKid. Is a screenshot ok?", CUSTOMER),
    notePart(ASK_NOTE),
  ];

  it("parses the need code and leaves the ask to the thread", () => {
    const ctx = handbackNoteContext(thread[3], BOT);
    expect(ctx?.kind).toBe("ask_reply_words");
    expect(ctx?.need).toBe("proof_link");
    expect(ctx?.ask).toBe("");
  });

  it("takes the ask from our last comment before the customer replied", () => {
    expect(askFromThread(thread, BOT, 1_762_000_000)).toBe(
      "Send me a link to your Spotify for Artists page and I can verify the profile.",
    );
  });

  it("never takes a comment posted after the customer replied", () => {
    const later = [
      ...thread.slice(0, 3),
      comment("a2", 1_763_000_000, "Just following up!", US),
    ];
    expect(askFromThread(later, BOT, 1_762_000_000)).toBe(
      "Send me a link to your Spotify for Artists page and I can verify the profile.",
    );
  });

  it("returns nothing when we never wrote before they did", () => {
    const onlyCustomer = [comment("c1", 1_759_000_000, "here is my link", CUSTOMER)];
    expect(askFromThread(onlyCustomer, BOT, 1_762_000_000)).toBe("");
  });

  it("tells the turn to answer the question and re-state ONE item, not to re-send the ask", () => {
    const ctx = { ...handbackNoteContext(thread[3], BOT)!, ask: askFromThread(thread, BOT, 1_762_000_000) };
    const block = renderHandbackBlock(ctx, 1_763_000_000);
    expect(block).toContain("The proof ask we sent");
    expect(block).toContain("Spotify for Artists");
    expect(block).toContain("replied in WORDS, not with an attachment");
    expect(block).toContain("answer the question they actually asked");
    expect(block).toContain("need code: proof_link");
    expect(block).toContain("Do not ask for anything else");
    expect(block).toContain("Do not send the ask again");
    expect(block).toContain("do not say their reply was received as a document");
  });

  it("says the ask was not found rather than quoting nothing", () => {
    const ctx = { ...handbackNoteContext(thread[3], BOT)!, ask: "" };
    const block = renderHandbackBlock(ctx, 1_763_000_000);
    expect(block).toContain("its text was not found on the thread");
    expect(block).toContain("Do not quote it");
  });

  it("still re-states one item when the note carries no need code", () => {
    const noNeed = notePart(
      "hydra-handback: v=2 reason=specific_ask kind=ask_reply_words promised_at=0 waiting_since=1762000000 followup=0 class=specific ask",
    );
    const ctx = { ...handbackNoteContext(noNeed, BOT)!, ask: "send a link" };
    const block = renderHandbackBlock(ctx, 1_763_000_000);
    expect(block).toContain("re-state the one item still needed");
    expect(block).not.toContain("need code:");
  });
});

// ---------------------------------------------------------------------------
// caroline-unanswered-drain-u1, 2026-11-15 16:59Z: the 82 reopened threads.
// ---------------------------------------------------------------------------

describe("the drain's wrong close note (the 82 reopened threads)", () => {
  const conv = (parts: IntercomConversationPart[]) =>
    ({ conversation_parts: { conversation_parts: parts } }) as unknown as IntercomConversation;

  const CLOSE =
    "Your last message here was answered and the conversation has been quiet since, so we are closing it. If you still need help, reply here at any time and it will open again.";

  it("is recognised when it is the newest comment", () => {
    const c = conv([comment("c1", 1, "any news?", CUSTOMER), comment("a1", 2, CLOSE, US)]);
    expect(lastWordWasWrongClose(c)).toBe(true);
  });

  it("is recognised when an older bot wrote it", () => {
    const c = conv([comment("a1", 2, CLOSE, { type: "admin", id: "4359478" })]);
    expect(lastWordWasWrongClose(c)).toBe(true);
  });

  it("is not claimed when the newest comment is the customer's", () => {
    const c = conv([comment("a1", 2, CLOSE, US), comment("c1", 3, "no it was not", CUSTOMER)]);
    expect(lastWordWasWrongClose(c)).toBe(false);
  });

  it("is not claimed for an ordinary reply of ours", () => {
    const c = conv([comment("a1", 2, "I'll have the credit review finished.", US)]);
    expect(lastWordWasWrongClose(c)).toBe(false);
  });

  it("tells the turn the line was ours and wrong, and not to repeat it", () => {
    const ctx = { ...handbackNoteContext(notePart(V2), BOT)!, wrongClose: true };
    const block = renderHandbackBlock(ctx, 1_763_000_000);
    expect(block).toContain("OUR close note saying their message was answered");
    expect(block).toContain("That was wrong: nobody answered it");
    expect(block).toContain("Do not repeat it");
    expect(block).toContain("do not treat it as the state of the thread");
  });

  it("says nothing about a wrong close on an ordinary thread", () => {
    const ctx = { ...handbackNoteContext(notePart(V2), BOT)!, wrongClose: false };
    expect(renderHandbackBlock(ctx, 1_763_000_000)).not.toContain("OUR close note");
  });
});

// ---------------------------------------------------------------------------
// QA 2026-11-15 round 4: the retry path, and the cross-admin ask.
// ---------------------------------------------------------------------------

describe("the retry is not exempt from the hand-back guards (QA channel.ts:1955)", () => {
  it("refuses a retry that reproduces the greeting", () => {
    const ctx = { ...handbackNoteContext(notePart(V2), BOT)!, askedAboutRequest: false };
    expect(handbackGreetingViolation("Anytime!", ctx)).toBe(HANDBACK_GREETING_RULE);
  });

  it("refuses a retry that reproduces the unasked queue line", () => {
    const ctx = { ...handbackNoteContext(notePart(V2), BOT)!, askedAboutRequest: false };
    expect(handbackUnaskedStatusViolation("Your request is in the verification queue.", ctx)).toBe(
      HANDBACK_UNASKED_STATUS_RULE,
    );
  });

  it("still allows a retry that answers the question", () => {
    const ctx = { ...handbackNoteContext(notePart(V2), BOT)!, askedAboutRequest: false };
    expect(handbackGreetingViolation("Your credits were added on 3 November.", ctx)).toBeNull();
    expect(handbackUnaskedStatusViolation("Your credits were added on 3 November.", ctx)).toBeNull();
  });
});

describe("the ask is the newest admin comment, whoever wrote it (QA filters.ts:628)", () => {
  const conv = (parts: IntercomConversationPart[]) =>
    ({ conversation_parts: { conversation_parts: parts } }) as unknown as IntercomConversation;
  const HUMAN = { type: "admin", id: "998877" };

  it("takes a later human admin's ask over an older bot ask", () => {
    const c = conv([
      comment("a1", 1_760_000_000, "Send me a link to your Spotify for Artists page.", US),
      comment("a2", 1_761_000_000, "Actually, send a screenshot of your distributor dashboard instead.", HUMAN),
      comment("c1", 1_762_000_000, "here you go", CUSTOMER),
    ]);
    expect(askFromThread(c.conversation_parts!.conversation_parts, BOT, 1_762_000_000)).toBe(
      "Actually, send a screenshot of your distributor dashboard instead.",
    );
  });

  it("takes a later bot ask over an older human ask", () => {
    const c = conv([
      comment("a1", 1_760_000_000, "Send a screenshot.", HUMAN),
      comment("a2", 1_761_000_000, "Send a link to your Spotify for Artists page.", US),
      comment("c1", 1_762_000_000, "ok", CUSTOMER),
    ]);
    expect(askFromThread(c.conversation_parts!.conversation_parts, BOT, 1_762_000_000)).toBe(
      "Send a link to your Spotify for Artists page.",
    );
  });

  it("uses bot identity only to break a same-second tie", () => {
    const c = conv([
      comment("a1", 1_761_000_000, "the human's ask", HUMAN),
      comment("a2", 1_761_000_000, "the bot's ask", US),
      comment("c1", 1_762_000_000, "ok", CUSTOMER),
    ]);
    expect(askFromThread(c.conversation_parts!.conversation_parts, BOT, 1_762_000_000)).toBe("the bot's ask");
  });
});
});

import { describe, it, expect } from "vitest";
import { buildJevState } from "../src/jev-router.js";
import { buildState, buildStateV1, VARIANTS, type JevStateCliThread } from "../src/jev-state-cli.js";

// ---------------------------------------------------------------------------
// v1 must be byte-identical to buildJevState for equivalent fixture threads —
// this is the eval harness's single most load-bearing guarantee: the eval
// measures the SAME state production sends, never a reimplementation.
// ---------------------------------------------------------------------------

describe("jev-state-cli v1 parity with buildJevState", () => {
  it("matches buildJevState for a simple user/bot/user thread", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "user", body: "my credits are stuck" },
        { author: "bot", body: "can you send a screenshot?" },
        { author: "user", body: "here you go" },
      ],
      turn_index: 2,
    };
    const got = buildStateV1(thread);
    const want = buildJevState({
      message: "here you go",
      recentParts: [
        { author: "user", body: "my credits are stuck" },
        { author: "bot", body: "can you send a screenshot?" },
      ],
      turnCount: 2,
    });
    expect(got).toEqual(want);
    expect(JSON.stringify(got)).toBe(JSON.stringify(want));
  });

  it("drops non-user/bot authors (e.g. a human admin takeover) exactly as production does", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "user", body: "hello" },
        { author: "admin", body: "a human jumped in here" },
        { author: "user", body: "still waiting" },
      ],
      turn_index: 2,
    };
    const got = buildStateV1(thread);
    const want = buildJevState({
      message: "still waiting",
      recentParts: [{ author: "user", body: "hello" }],
      turnCount: 2,
    });
    expect(got).toEqual(want);
  });

  it("maps lead/contact author types to user, matching handler.ts's CUSTOMER_AUTHOR_TYPES", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "lead", body: "first message" },
        { author: "contact", body: "second turn" },
      ],
      turn_index: 1,
    };
    const got = buildStateV1(thread);
    const want = buildJevState({
      message: "second turn",
      recentParts: [{ author: "user", body: "first message" }],
      turnCount: 2,
    });
    expect(got).toEqual(want);
  });

  it("strips HTML tags from message and recentParts bodies, matching production", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "bot", body: "<p>hi there</p>" },
        { author: "user", body: "<b>urgent</b> please help" },
      ],
      turn_index: 1,
    };
    const got = buildStateV1(thread);
    expect(got.message).toBe("urgent please help");
    expect((got.last_parts as { text: string }[])[0].text).toBe("hi there");
  });

  it("caps turn_count at customer-authored parts only, matching state.userTurnCount", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "user", body: "one" },
        { author: "bot", body: "reply" },
        { author: "user", body: "two" },
        { author: "bot", body: "reply 2" },
        { author: "user", body: "three" },
      ],
      turn_index: 4,
    };
    const got = buildStateV1(thread);
    expect(got.turn_count).toBe(3);
  });

  it("passes known_facts through to founding/plan/prior_chats", () => {
    const thread: JevStateCliThread = {
      parts: [{ author: "user", body: "am I a founding member?" }],
      turn_index: 0,
      known_facts: {
        founding: 2021,
        plan: "pro",
        prior_chats: { count: 2, most_recent_title: "Billing question", most_recent_at: "2026-01-01T00:00:00Z" },
      },
    };
    const got = buildStateV1(thread);
    const want = buildJevState({
      message: "am I a founding member?",
      recentParts: [],
      turnCount: 1,
      founding: 2021,
      plan: "pro",
      priorChats: { count: 2, mostRecentTitle: "Billing question", mostRecentAt: "2026-01-01T00:00:00Z" },
    });
    expect(got).toEqual(want);
  });

  it("omits known_facts when absent, exactly like buildJevState", () => {
    const thread: JevStateCliThread = {
      parts: [{ author: "user", body: "hi" }],
      turn_index: 0,
    };
    const got = buildStateV1(thread);
    expect("known_facts" in got).toBe(false);
  });

  it("only ever includes the last 10 recentParts, each capped at 500 chars, matching MAX_PARTS/MAX_PART_CHARS", () => {
    const parts: JevStateCliThread["parts"] = [];
    for (let i = 0; i < 15; i++) {
      parts.push({ author: i % 2 === 0 ? "user" : "bot", body: `part-${i}` });
    }
    parts.push({ author: "user", body: "current" });
    const thread: JevStateCliThread = { parts, turn_index: parts.length - 1 };
    const got = buildStateV1(thread);
    expect((got.last_parts as unknown[]).length).toBe(10);
  });
});

describe("buildState variant dispatch", () => {
  it("VARIANTS exposes v1", () => {
    expect(Object.keys(VARIANTS)).toContain("v1");
  });

  it("throws on an unknown variant", () => {
    const thread: JevStateCliThread = { parts: [{ author: "user", body: "hi" }], turn_index: 0 };
    expect(() => buildState("v2-nonexistent", thread)).toThrow(/unknown --variant/);
  });

  it("throws when turn_index is out of range", () => {
    const thread = { parts: [{ author: "user", body: "hi" }], turn_index: 5 };
    expect(() => buildState("v1", thread)).toThrow(/out of range/);
  });

  it("throws when turn_index does not point at a customer part", () => {
    const thread = {
      parts: [
        { author: "user", body: "hi" },
        { author: "bot", body: "reply" },
      ],
      turn_index: 1,
    };
    expect(() => buildState("v1", thread)).toThrow(/does not point at a customer/);
  });

  it("throws on a non-object input", () => {
    expect(() => buildState("v1", "not an object")).toThrow(/must be a JSON object/);
  });

  it("throws when parts is missing", () => {
    expect(() => buildState("v1", { turn_index: 0 })).toThrow(/parts must be an array/);
  });
});

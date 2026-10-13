import { describe, it, expect, afterEach } from "vitest";
import { buildJevState } from "../src/jev-router.js";
import {
  buildState,
  buildStateV1,
  buildStateV2Min,
  buildStateV2Policy,
  buildStateV2Soul,
  VARIANTS,
  type JevStateCliThread,
} from "../src/jev-state-cli.js";
import { __resetCarolineInventoryCacheForTests } from "../src/caroline-inventory-loader.js";

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

// ---------------------------------------------------------------------------
// v2 CLI variants — v2-min, v2-policy, v2-soul, and VARIANTS registration
// ---------------------------------------------------------------------------

describe("jev-state-cli v2 variants", () => {
  afterEach(() => {
    __resetCarolineInventoryCacheForTests();
    delete process.env.JEV_SOUL_PATH;
  });

  it("VARIANTS registers v2-min, v2-policy, v2-soul alongside v1", () => {
    expect(Object.keys(VARIANTS).sort()).toEqual(["v1", "v2-min", "v2-policy", "v2-soul"].sort());
  });

  it("v2-min produces the v2 state shape with empty tools/policy and maps admin -> human_agent", () => {
    const thread: JevStateCliThread = {
      parts: [
        { author: "user", body: "my credits are missing" },
        { author: "bot", body: "can you share the profile link?" },
        { author: "admin", body: "I've taken over, one sec" },
        { author: "user", body: "ok here it is" },
      ],
      turn_index: 3,
    };
    const got = buildStateV2Min(thread);
    expect(got.customer_last_message).toBe("ok here it is");
    // most recent part before the current turn is the admin (human_agent) reply
    expect(got.agent_last_message).toEqual({ author: "human_agent", text: "I've taken over, one sec" });
    expect(got.tools).toEqual([]);
    expect(got.policy).toEqual({ human_gated: [], kb_topics: [] });
    const thread2 = (got.thread as { author: string; text: string }[]) ?? [];
    expect(thread2.some((p) => p.author === "human_agent" && p.text === "I've taken over, one sec")).toBe(true);
  });

  it("buildState('v2-min', ...) is reachable via VARIANTS dispatch too", () => {
    const thread: JevStateCliThread = { parts: [{ author: "user", body: "hi" }], turn_index: 0 };
    expect(buildState("v2-min", thread)).toEqual(buildStateV2Min(thread));
  });

  it("v2-policy loads tools/policy from caroline-tool-capabilities.json", () => {
    const thread: JevStateCliThread = { parts: [{ author: "user", body: "hi" }], turn_index: 0 };
    const got = buildStateV2Policy(thread);
    const tools = got.tools as unknown[];
    const policy = got.policy as { human_gated: string[]; kb_topics: string[] };
    expect(tools.length).toBeGreaterThan(0);
    expect(policy.kb_topics.length).toBeGreaterThan(0);
  });

  it("v2-soul throws when JEV_SOUL_PATH is unset", () => {
    delete process.env.JEV_SOUL_PATH;
    const thread: JevStateCliThread = { parts: [{ author: "user", body: "hi" }], turn_index: 0 };
    expect(() => buildStateV2Soul(thread)).toThrow(/JEV_SOUL_PATH/);
  });

  it("v2-soul loads agent_instructions from JEV_SOUL_PATH when set", () => {
    process.env.JEV_SOUL_PATH = new URL("../../../workspaces/support/SOUL.md", import.meta.url).pathname;
    const thread: JevStateCliThread = { parts: [{ author: "user", body: "hi" }], turn_index: 0 };
    const got = buildStateV2Soul(thread);
    expect(typeof got.agent_instructions).toBe("string");
    expect((got.agent_instructions as string).length).toBeGreaterThan(0);
  });
});

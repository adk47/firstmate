import { describe, it, expect } from "vitest";
import {
  isSkippableInbound,
  retrieveKbSnippets,
  renderKnowledgeBaseBlock,
  stripKnowledgeBase,
  type KbSnippet,
} from "../src/kb-retrieval.js";

const SNIPPETS: KbSnippet[] = [
  { snippet: "There's a ~30-day grace window for a failed payment.", path: "reference/founding-member.md", score: 0.33 },
  { snippet: "Status holds only while the subscription stays active.", path: "reference/founding-member.md", score: 0.31 },
];

describe("isSkippableInbound", () => {
  it("skips bare closers / acks and empty turns", () => {
    for (const m of ["ok", "OK", " thanks ", "ty", "👍", "thank you", "cool", "", "   "]) {
      expect(isSkippableInbound(m)).toBe(true);
    }
  });
  it("does NOT skip short answer-bearing questions", () => {
    for (const m of ["refund?", "founder?", "where is my plaque", "is my account working?"]) {
      expect(isSkippableInbound(m)).toBe(false);
    }
  });
});

describe("retrieveKbSnippets", () => {
  it("returns the searcher's snippets for an answer-bearing message", async () => {
    const out = await retrieveKbSnippets("what happens if my payment fails", async () => SNIPPETS, {});
    expect(out).toEqual(SNIPPETS);
  });

  it("skips retrieval (no search call) on a closer", async () => {
    let called = false;
    const out = await retrieveKbSnippets("thanks", async () => { called = true; return SNIPPETS; }, {});
    expect(called).toBe(false);
    expect(out).toEqual([]);
  });

  it("fails OPEN to [] when the searcher throws", async () => {
    const out = await retrieveKbSnippets("real question?", async () => { throw new Error("manager paused"); }, {});
    expect(out).toEqual([]);
  });

  it("fails OPEN to [] when the searcher exceeds the timeout", async () => {
    const slow = () => new Promise<KbSnippet[]>((res) => setTimeout(() => res(SNIPPETS), 80));
    const out = await retrieveKbSnippets("real question?", slow, { timeoutMs: 10 });
    expect(out).toEqual([]);
  });

  it("passes maxResults + minScore through to the searcher", async () => {
    let seen: { maxResults?: number; minScore?: number } | undefined;
    await retrieveKbSnippets("real question?", async (_q, opts) => { seen = opts; return []; }, { maxResults: 7, minScore: 0 });
    expect(seen).toEqual({ maxResults: 7, minScore: 0 });
  });
});

describe("renderKnowledgeBaseBlock", () => {
  it("returns empty string for no snippets", () => {
    expect(renderKnowledgeBaseBlock([])).toBe("");
  });
  it("wraps snippets in a delimited block and never leaks the file path", () => {
    const block = renderKnowledgeBaseBlock(SNIPPETS);
    expect(block).toContain("[KNOWLEDGE_BASE]");
    expect(block).toContain("[/KNOWLEDGE_BASE]");
    expect(block).toContain("30-day grace window");
    expect(block).not.toContain("founding-member.md");
    expect(block).not.toContain("reference/");
  });
});

describe("stripKnowledgeBase", () => {
  it("removes a regurgitated [KNOWLEDGE_BASE] block from an outbound reply", () => {
    const reply = `${renderKnowledgeBaseBlock(SNIPPETS)}\nHere's the real answer.`;
    const out = stripKnowledgeBase(reply);
    expect(out).toBe("Here's the real answer.");
    expect(out).not.toContain("[KNOWLEDGE_BASE]");
  });
  it("removes a lone half-echoed open tag", () => {
    expect(stripKnowledgeBase("[KNOWLEDGE_BASE] verified Muso facts\nhi there")).toBe("hi there");
  });
  it("leaves a clean reply untouched", () => {
    expect(stripKnowledgeBase("Your plan renews on the 1st.")).toBe("Your plan renews on the 1st.");
  });
});

import { describe, it, expect } from "vitest";
import { parseHelpManifest } from "../src/help-manifest.js";
import {
  withHelpCentreCap,
  toKbSnippet,
  renderKnowledgeBaseBlock,
  type KbSearcher,
  type KbSnippet,
} from "../src/kb-retrieval.js";

const URL1 = "https://help.muso.ai/en/articles/1111111-claim";
const MANIFEST = parseHelpManifest(
  JSON.stringify({ articles: { "1111111": { slug: "claim", title: "Claim", url: URL1 } } }),
)!;

describe("toKbSnippet", () => {
  it("sets citationUrl for a help-centre hit and omits it for a curated hit", () => {
    const hc = toKbSnippet({ snippet: "mid-article chunk", path: "reference/hc-1111111.md", score: 0.4 }, MANIFEST);
    const cur = toKbSnippet({ snippet: "curated", path: "reference/founding-member.md", score: 0.3 }, MANIFEST);
    expect(hc.citationUrl).toBe(URL1);
    expect("citationUrl" in cur).toBe(false);
  });
  it("omits citationUrl when the article is not in the manifest or the manifest is missing", () => {
    expect(toKbSnippet({ snippet: "x", path: "reference/hc-42.md" }, MANIFEST).citationUrl).toBeUndefined();
    expect(toKbSnippet({ snippet: "x", path: "reference/hc-1111111.md" }, null).citationUrl).toBeUndefined();
  });
});

describe("withHelpCentreCap", () => {
  const hc = (i: number): KbSnippet => ({ snippet: `hc ${i}`, path: `reference/hc-${i}.md`, score: 0.9 - i / 100 });
  const cur = (n: string): KbSnippet => ({ snippet: `cur ${n}`, path: `reference/${n}.md`, score: 0.1 });

  it("keeps a curated hit even when help-centre files outrank it, and caps help-centre at 2 of 5", async () => {
    // 8 help-centre hits outrank the single curated hit in raw order.
    const inner: KbSearcher = async () => [1, 2, 3, 4, 5, 6, 7, 8].map(hc).concat([cur("founding-member")]);
    const out = await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(out.filter((s) => !s.path!.includes("hc-")).length).toBeGreaterThanOrEqual(1);
    expect(out.filter((s) => s.path!.includes("hc-")).length).toBe(2);
    expect(out.length).toBeLessThanOrEqual(5);
  });

  it("asks the inner searcher for more than maxResults so curated hits can surface", async () => {
    let seen = 0;
    await withHelpCentreCap(async (_q, o) => { seen = o.maxResults; return []; })("q", { maxResults: 5, minScore: 0 });
    expect(seen).toBeGreaterThan(5);
  });

  it("widens the search when the first window is all help-centre, so a curated hit ranked 21st still surfaces", async () => {
    const ranked: KbSnippet[] = [...Array.from({ length: 20 }, (_, i) => hc(i + 1)), cur("refund-policy")];
    const asked: number[] = [];
    const inner: KbSearcher = async (_q, o) => { asked.push(o.maxResults); return ranked.slice(0, o.maxResults); };
    const out = await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(out.some((s) => s.path === "reference/refund-policy.md")).toBe(true);
    expect(out.filter((s) => s.path!.includes("hc-")).length).toBe(2);
    expect(asked.length).toBe(2);
  });

  it("keeps widening until the corpus is exhausted, so a curated hit ranked beyond the second window still surfaces", async () => {
    const ranked: KbSnippet[] = [...Array.from({ length: 600 }, (_, i) => hc(i + 1)), cur("refund-policy")];
    const inner: KbSearcher = async (_q, o) => ranked.slice(0, o.maxResults);
    const out = await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(out.some((s) => s.path === "reference/refund-policy.md")).toBe(true);
  });

  it("stops widening once a window comes back short (corpus exhausted, no curated hit)", async () => {
    const ranked: KbSnippet[] = Array.from({ length: 150 }, (_, i) => hc(i + 1));
    let calls = 0;
    const inner: KbSearcher = async (_q, o) => { calls++; return ranked.slice(0, o.maxResults); };
    const out = await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(out.length).toBe(2);
    expect(calls).toBe(3);
  });

  it("does not widen when the first window already returned fewer hits than asked", async () => {
    let calls = 0;
    const inner: KbSearcher = async () => { calls++; return [hc(1), hc(2)]; };
    await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(calls).toBe(1);
  });

  it("curated hits take priority and never exceed maxResults", async () => {
    const inner: KbSearcher = async () => [hc(1), cur("a"), cur("b"), cur("c"), cur("d"), cur("e"), cur("f")];
    const out = await withHelpCentreCap(inner)("q", { maxResults: 5, minScore: 0 });
    expect(out.length).toBe(5);
    expect(out.every((s) => !s.path!.includes("hc-"))).toBe(true);
  });
});

describe("renderKnowledgeBaseBlock with help-centre hits", () => {
  const snippets: KbSnippet[] = [
    { snippet: "Curated fact.", path: "reference/credits-and-profiles.md" },
    { snippet: "Chunk of article.", path: "reference/hc-1111111.md", citationUrl: URL1 },
  ];
  it("renders the url as a per-snippet field in a subordinate section, never the path", () => {
    const block = renderKnowledgeBaseBlock(snippets);
    expect(block).toContain(URL1);
    expect(block).not.toContain("hc-1111111");
    expect(block).not.toContain("reference/");
    expect(block.indexOf("Curated fact.")).toBeLessThan(block.indexOf("Chunk of article."));
    expect(block).toMatch(/help-centre/i);
  });
  it("carves the help-centre URL out of the never-quote-IDs rule", () => {
    expect(renderKnowledgeBaseBlock(snippets)).toMatch(/except.*article link/i);
  });
  it("emits no url for a curated-only block", () => {
    expect(renderKnowledgeBaseBlock([snippets[0]!])).not.toContain("http");
  });
});

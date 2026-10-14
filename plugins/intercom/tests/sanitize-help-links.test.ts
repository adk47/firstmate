import { describe, it, expect } from "vitest";
import { sanitizeHelpLinks } from "../src/sanitize-help-links.js";
import { parseHelpManifest, loadHelpManifest, HELP_CITATION_LEAD } from "../src/help-manifest.js";

const MANIFEST = parseHelpManifest(
  JSON.stringify({
    generated_at: "2026-10-12T00:00:00Z",
    articles: {
      "1111111": { slug: "how-do-i-claim-my-profile", title: "Claim", url: "https://help.muso.ai/en/articles/1111111-how-do-i-claim-my-profile" },
      "2222222": { slug: "billing-faq", title: "Billing", url: "https://help.muso.ai/en/articles/2222222-billing-faq" },
    },
  }),
)!;
const GOOD = "https://help.muso.ai/en/articles/1111111-how-do-i-claim-my-profile";
const BANNED = /tool|lookup|error|unavailable|system|API|ticket|ClickUp|openclaw|HYDRA/i;

describe("sanitizeHelpLinks", () => {
  it("lets a manifest-valid id+slug citation survive unchanged", () => {
    const body = `You can claim it from your profile page.\n\n${HELP_CITATION_LEAD} ${GOOD}`;
    const out = sanitizeHelpLinks(body, MANIFEST);
    expect(out.body).toBe(body);
    expect(out.redactions).toEqual([]);
  });

  it.each([
    ["invented id", "https://help.muso.ai/en/articles/9999999-invented"],
    ["unknown id", "https://help.muso.ai/en/articles/3333333-billing-faq"],
    ["right id, wrong slug", "https://help.muso.ai/en/articles/1111111-wrong-slug"],
    ["right id, no slug", "https://help.muso.ai/en/articles/1111111"],
  ])("strips %s together with its lead-in line", (_n, url) => {
    const out = sanitizeHelpLinks(`Here is the answer.\n\n${HELP_CITATION_LEAD} ${url}`, MANIFEST);
    expect(out.body).toBe("Here is the answer.");
    expect(out.redactions.length).toBe(1);
  });

  it.each([
    ["explicit https port", "https://help.muso.ai:443/en/articles/9999999-invented"],
    ["empty port", "https://help.muso.ai:/en/articles/9999999-invented"],
    ["trailing-dot host", "https://help.muso.ai./en/articles/9999999-invented"],
    ["valid article with explicit port", "https://help.muso.ai:443/en/articles/1111111-how-do-i-claim-my-profile"],
    ["percent-encoded path segment", "https://help.muso.ai/en/%61rticles/9999999-invented"],
    ["percent-encoded host dot", "https://help%2Emuso.ai/en/articles/9999999-invented"],
    ["double-encoded path segment", "https://help.muso.ai/en/%2561rticles/9999999-invented"],
    ["percent-encoded slash", "https://help.muso.ai/en%2Farticles%2F9999999-invented"],
    ["valid article, percent-encoded", "https://help.muso.ai/en/%61rticles/1111111-how-do-i-claim-my-profile"],
    ["html decimal entity host", "https://help&#46;muso.ai/en/articles/9999999-invented"],
    ["html hex entity host", "https://help&#x2E;muso.ai/en/articles/9999999-invented"],
    ["named entity host", "https://help&period;muso.ai/en/articles/9999999-invented"],
    ["entity slash in path", "https://help.muso.ai/en/articles&#47;9999999-invented"],
    ["leading-zero entity", "https://help&#046;muso.ai/en/articles/9999999-invented"],
    ["entity-encoded percent (double encoding)", "https://help&#37;2Emuso.ai/en/articles/9999999-invented"],
  ])("strips %s variant together with its lead-in line", (_n, url) => {
    const out = sanitizeHelpLinks(`Here is the answer.\n\n${HELP_CITATION_LEAD} ${url}`, MANIFEST);
    expect(out.body).toBe("Here is the answer.");
    expect(out.redactions.length).toBe(1);
  });

  it("a stray % elsewhere in the reply does not switch the decode off", () => {
    const out = sanitizeHelpLinks(`Accuracy is 100%.\n${HELP_CITATION_LEAD} https://help.muso.ai/en/%61rticles/9999999-invented`, MANIFEST);
    expect(out.body).toBe("Accuracy is 100%.");
    expect(out.redactions.length).toBe(1);
  });

  it("a malformed escape inside the URL still strips it", () => {
    const out = sanitizeHelpLinks(`Answer.\n${HELP_CITATION_LEAD} https://help.muso.ai/en/%61rticles/9999999-%E0`, MANIFEST);
    expect(out.body).toBe("Answer.");
  });

  it("fallback strips a URL whose host letter is percent-encoded, keeping the prose", () => {
    const out = sanitizeHelpLinks("See https://%68elp.muso.ai/en/articles/9999999-invented for details", MANIFEST);
    expect(out.body).toBe("See for details");
    expect(out.body).not.toMatch(/muso\.ai/i);
  });

  it("fallback strips an entity-encoded bare token from a single prose line (detection-only fix leaks here)", () => {
    for (const host of ["help&#46;muso.ai", "help&#x2e;muso.ai", "help&period;muso.ai", "&#104;elp.muso.ai",
      "&#72;elp.muso.ai", "help.&#x4D;uso.ai", "help.muso.&#65;i", "help&amp;#46;muso.ai", "help&#37;2Emuso.ai", "help%252emuso.ai"]) {
      const out = sanitizeHelpLinks(`Here you go: https://${host}/en/articles/9999999-invented`, MANIFEST);
      expect(out.redactions.length).toBe(1);
      expect(out.body).toContain("Here you go");
      expect(out.body).not.toContain("9999999");
      expect(out.body).not.toContain("articles");
    }
  });

  it("strips a host written with a Unicode dot equivalent, fullwidth letters or ignorable characters", () => {
    for (const host of ["help\u3002muso.ai", "help\uFF0Emuso.ai", "help\uFF61muso.ai", "help.muso\u3002ai", "help%E3%80%82muso.ai",
      "help&#x3002;muso.ai", "\uFF48elp.muso.ai", "help.muso.a\u00ADi", "he\u200Blp.muso.ai"]) {
      const line = `More detail here: https://${host}/en/articles/9999999-invented`;
      const out = sanitizeHelpLinks(`Answer.\n${line}`, MANIFEST);
      expect(out.body, host).toBe("Answer.");
      expect(out.redactions.length, host).toBe(1);
      const prose = sanitizeHelpLinks(`See https://${host}/en/articles/9999999-invented for details`, MANIFEST);
      expect(prose.body, host).toBe("See for details");
    }
  });

  it("entity-encoded anchor is stripped", () => {
    const out = sanitizeHelpLinks('Hi.\n<p><a href="https://help&#46;muso.ai/en/articles/9999999-x">guide</a></p>', MANIFEST);
    expect(out.redactions.length).toBe(1);
    expect(out.body).not.toContain("9999999");
  });

  it("positive controls stay byte-identical", () => {
    for (const b of [`Answer.\n${HELP_CITATION_LEAD} ${GOOD}`, "Plain, see help.muso.ai.", "Tom &amp; Jerry &lt;3 you"]) {
      expect(sanitizeHelpLinks(b, MANIFEST)).toEqual({ body: b, redactions: [] });
    }
  });

  it("malformed entities never throw", () => {
    for (const b of ["a &#999999999; b", "a &#x; b", "a &#xFFFFFFFFFF; b", `a &#999999999;\n${HELP_CITATION_LEAD} https://help.muso.ai/en/articles/9999999-x`]) {
      expect(() => sanitizeHelpLinks(b, MANIFEST)).not.toThrow();
    }
  });

  it("strips a URL whose host letter is percent-encoded in uppercase code, keeping the prose", () => {
    for (const host of ["%48elp.muso.ai", "help.%4Duso.ai", "help.muso.%41i"]) {
      const out = sanitizeHelpLinks(`See https://${host}/en/articles/9999999-invented for details`, MANIFEST);
      expect(out.body).toBe("See for details");
    }
  });

  it("strips a URL embedded mid-prose (not on a template line)", () => {
    const out = sanitizeHelpLinks(`Answer one.\nSee ${GOOD} for steps.\nAnswer two.`, MANIFEST);
    expect(out.body).toBe("Answer one.\nAnswer two.");
  });

  it("never empties the reply: a single-line prose reply keeps its text, loses only the URL", () => {
    const out = sanitizeHelpLinks(`You can change it under Settings > Plan, see ${GOOD} for steps.`, MANIFEST);
    expect(out.body).toBe("You can change it under Settings > Plan, see for steps.");
    expect(out.body).not.toMatch(/help\.muso\.ai/i);
    expect(out.redactions.length).toBe(1);
  });

  it("never empties the reply: a single-line html anchor is removed, prose kept", () => {
    const out = sanitizeHelpLinks(`<p>Open Settings, then Plan. More detail here: <a href="${GOOD}">${GOOD}</a></p>`, MANIFEST);
    expect(out.body).not.toMatch(/help\.muso\.ai|href/i);
    expect(out.body).toBe("<p>Open Settings, then Plan.</p>");
  });

  it("a reply that was only a citation line stays empty (nothing else to keep)", () => {
    const out = sanitizeHelpLinks(`${HELP_CITATION_LEAD} https://help.muso.ai/en/articles/9999999-x`, MANIFEST);
    expect(out.body).toBe("");
  });

  it("strips a markdown-linked article URL", () => {
    const out = sanitizeHelpLinks(`Answer.\n[read this](${GOOD})`, MANIFEST);
    expect(out.body).toBe("Answer.");
  });

  it("strips a valid URL on a non-template lead-in", () => {
    const out = sanitizeHelpLinks(`Answer.\nCheck this out: ${GOOD}`, MANIFEST);
    expect(out.body).toBe("Answer.");
  });

  it("keeps at most one citation", () => {
    const two = `Answer.\n${HELP_CITATION_LEAD} ${GOOD}\n${HELP_CITATION_LEAD} https://help.muso.ai/en/articles/2222222-billing-faq`;
    const out = sanitizeHelpLinks(two, MANIFEST);
    expect(out.body).toBe(`Answer.\n${HELP_CITATION_LEAD} ${GOOD}`);
  });

  it("leaves a bare help.muso.ai mention alone", () => {
    const body = "You can also browse help.muso.ai or https://help.muso.ai for more.";
    expect(sanitizeHelpLinks(body, MANIFEST).body).toBe(body);
  });

  it("fails closed on a null manifest: strips even a would-be-valid link", () => {
    const out = sanitizeHelpLinks(`Answer.\n${HELP_CITATION_LEAD} ${GOOD}`, null);
    expect(out.body).toBe("Answer.");
  });

  it("returns a body with no article URL untouched without needing a manifest", () => {
    expect(sanitizeHelpLinks("Plain answer.", null).body).toBe("Plain answer.");
  });
});

describe("parseHelpManifest / loadHelpManifest", () => {
  it.each(["", "not json", "[]", '{"articles":[]}', '{"articles":{"1":{"slug":5}}}', '{"articles":{"1":{"slug":"a","url":"http://evil.example/1-a"}}}'])(
    "rejects malformed input %j",
    (raw) => expect(parseHelpManifest(raw)).toBeNull(),
  );
  it("loader returns null (never throws) when the reader throws", () => {
    expect(loadHelpManifest("/nope", () => { throw new Error("ENOENT"); })).toBeNull();
  });
  it("loader parses what the reader returns", () => {
    expect(loadHelpManifest("/x", () => '{"articles":{}}')).not.toBeNull();
  });
});

describe("customer-visible output carries no banned word", () => {
  const warns: string[] = [];
  const cases: Array<[string, string, typeof MANIFEST | null]> = [
    ["valid link", `Answer.\n${HELP_CITATION_LEAD} ${GOOD}`, MANIFEST],
    ["stripped link", `Answer.\n${HELP_CITATION_LEAD} https://help.muso.ai/en/articles/9-x`, MANIFEST],
    ["missing manifest", `Answer.\n${HELP_CITATION_LEAD} ${GOOD}`, null],
    ["malformed URL", `Answer.\n${HELP_CITATION_LEAD} https://help.muso.ai/en/articles/%%%`, MANIFEST],
    ["no hit", "Answer with no citation.", MANIFEST],
  ];
  it.each(cases)("%s", (_n, body, manifest) => {
    const out = sanitizeHelpLinks(body, manifest);
    warns.push(out.body);
    expect(out.body).not.toMatch(BANNED);
  });
  it("the citation template itself is clean", () => {
    expect(HELP_CITATION_LEAD).not.toMatch(BANNED);
  });
});

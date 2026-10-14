import { describe, it, expect } from "vitest";
import { sanitizeHelpLinks, hasArticleUrl } from "../src/sanitize-help-links.js";
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

  it("strips a host carrying ANY default-ignorable code point the URL parser ignores (not a hand-picked list)", () => {
    const ignorable: string[] = [];
    for (let cp = 0x80; cp <= 0x2ffff; cp++) {
      const ch = String.fromCodePoint(cp);
      if (/^\p{Default_Ignorable_Code_Point}$/u.test(ch)) ignorable.push(ch);
    }
    expect(ignorable.length).toBeGreaterThan(70);
    for (const ch of ignorable) {
      for (const host of [`help${ch}.muso.ai`, `he${ch}lp.muso.ai`, `help.muso${ch}.ai`, `help.muso.ai${ch}`]) {
        const out = sanitizeHelpLinks(`Answer.\nMore detail here: https://${host}/en/articles/9999999-invented`, MANIFEST);
        expect(out.body, `U+${ch.codePointAt(0)!.toString(16)} in ${host}`).toBe("Answer.");
        expect(out.redactions.length).toBe(1);
      }
    }
    // the parser-reported cases from the QA round: CGJ, VS16, Mongolian FVS, invisible separator, Hangul filler
    for (const host of ["help\u034F.muso.ai", "help.muso\uFE0F.ai", "he\u180Blp.muso.ai", "help.muso.ai\u2063", "help\u3164.muso.ai"]) {
      const prose = sanitizeHelpLinks(`See https://${host}/en/articles/9999999-invented for details`, MANIFEST);
      expect(prose.body, host).toBe("See for details");
    }
  });

  it("prose fallback strips a host carrying ANY default-ignorable code point, incl. U+FEFF which JS \\s treats as whitespace", () => {
    const ignorable: string[] = [];
    for (let cp = 0x80; cp <= 0x2ffff; cp++) {
      const ch = String.fromCodePoint(cp);
      if (/^\p{Default_Ignorable_Code_Point}$/u.test(ch)) ignorable.push(ch);
    }
    expect(ignorable).toContain("﻿");
    for (const ch of ignorable) {
      for (const host of [`help${ch}.muso.ai`, `he${ch}lp.muso.ai`, `help.muso${ch}.ai`, `help.muso.ai${ch}`]) {
        const prose = sanitizeHelpLinks(`See https://${host}/en/articles/9999999-invented for details`, MANIFEST);
        expect(prose.body, `U+${ch.codePointAt(0)!.toString(16)} in ${host}`).toBe("See for details");
      }
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

describe("URL-parser-ignored ASCII whitespace (tab, LF, CR) inside a link", () => {
  const INVENTED = "9999999-invented";
  const shapes: Array<[string, string]> = [
    ["tab in path, html anchor", `Answer.\n<a href="https://help.muso.ai/en/ar\tticles/${INVENTED}">guide</a>`],
    ["newline in path, html anchor", `Answer.\n<a href="https://help.muso.ai/en/ar\nticles/${INVENTED}">guide</a>`],
    ["CR in host, html anchor", `Answer.\n<a href="https://help.mu\rso.ai/en/articles/${INVENTED}">guide</a>`],
    ["tab in path, template line", `Answer.\n${HELP_CITATION_LEAD} https://help.muso.ai/en/ar\tticles/${INVENTED}`],
    ["entity-encoded tab in path", `Answer.\n<a href="https://help.muso.ai/en/ar&#9;ticles/${INVENTED}">guide</a>`],
    ["tab in markdown link", `Answer.\n[guide](https://help.muso.ai/en/ar\tticles/${INVENTED})`],
  ];
  it.each(shapes)("strips an unlisted article link: %s", (_n, body) => {
    const out = sanitizeHelpLinks(body, MANIFEST);
    expect(out.redactions.length).toBeGreaterThan(0);
    expect(out.body).toBe("Answer.");
  });
});

describe("named HTML entities the parser ignores or maps into a URL", () => {
  const INVENTED = "9999999-invented";
  it.each(["&Tab;", "&NewLine;", "&tab;", "&shy;", "&zwj;", "&NoBreak;"])("strips an unlisted article link with %s in the path", (ent) => {
    const body = `Answer.\n<a href="https://help.muso.ai/en/ar${ent}ticles/${INVENTED}">guide</a>`;
    const out = sanitizeHelpLinks(body, MANIFEST);
    expect(out.body).toBe("Answer.");
    expect(out.redactions.length).toBeGreaterThan(0);
  });
  it("leaves a harmless ampersand phrase alone", () => {
    expect(sanitizeHelpLinks("Tom &amp; Jerry; R&D", MANIFEST).body).toBe("Tom &amp; Jerry; R&D");
  });
});

describe("named entities that decode to a letter or a backslash (parser differential)", () => {
  // name -> [char it decodes to, ASCII char it stands in for after URL host parsing]
  const FOLDS: Array<[string, string, string]> = [
    ["escr", "\u212F", "e"], ["Escr", "\u2130", "E"], ["ell", "\u2113", "l"], ["ee", "\u2147", "e"], ["ExponentialE", "\u2147", "e"],
    ["hopf", "\u{1D559}", "h"], ["Hopf", "\u210D", "H"], ["hfr", "\u{1D525}", "h"], ["Hfr", "\u210C", "H"], ["afr", "\u{1D51E}", "a"],
    ["ascr", "\u{1D4B6}", "a"], ["aopf", "\u{1D552}", "a"], ["efr", "\u{1D522}", "e"], ["eopf", "\u{1D556}", "e"], ["circledS", "\u24C8", "S"],
  ];
  const INVENTED = "9999999-invented";
  it.each(FOLDS)("&%s; standing in for a host letter really resolves to help.muso.ai, and the gate strips it", (name, ch, ascii) => {
    const at = "help.muso.ai".indexOf(ascii.toLowerCase());
    const real = `help.muso.ai`.slice(0, at) + ch + `help.muso.ai`.slice(at + 1);
    // Oracle: the URL parser agrees this is the help-centre host.
    expect(new URL(`https://${real}/en/articles/${INVENTED}`).host).toBe("help.muso.ai");
    const host = `help.muso.ai`.slice(0, at) + `&${name};` + `help.muso.ai`.slice(at + 1);
    const out = sanitizeHelpLinks(`Answer.\n<a href="https://${host}/en/articles/${INVENTED}">guide</a>`, MANIFEST);
    expect(out.body).toBe("Answer.");
    expect(out.redactions.length).toBeGreaterThan(0);
  });
  it("strips &bsol; used as the path separator", () => {
    const out = sanitizeHelpLinks(`Answer.\n<a href="https://help.muso.ai&bsol;en/articles/${INVENTED}">guide</a>`, MANIFEST);
    expect(out.body).toBe("Answer.");
  });
  it("prose fallback strips it too", () => {
    const out = sanitizeHelpLinks(`See https://h&escr;lp.muso.ai/en/articles/${INVENTED} for details`, MANIFEST);
    expect(out.body).not.toContain("articles");
  });
  // Legacy entities decode without a trailing semicolon (HTML5 has 106 such names).
  it.each([
    ["help&shy.muso.ai", "help­.muso.ai"],
    ["help.mus&ordm.ai", "help.musº.ai"],
  ])("semicolon-less legacy entity in an href (%s) resolves to help.muso.ai and is stripped", (written, real) => {
    expect(new URL(`https://${real}/en/articles/${INVENTED}`).host).toBe("help.muso.ai");
    const out = sanitizeHelpLinks(`Answer.\n<a href="https://${written}/en/articles/${INVENTED}">guide</a>`, MANIFEST);
    expect(out.body).toBe("Answer.");
    expect(out.redactions.length).toBeGreaterThan(0);
  });
  it("semicolon-less legacy entity in prose (&ordf) is stripped", () => {
    const out = sanitizeHelpLinks(`See https://help.muso.&ordfi/en/articles/${INVENTED} for details`, MANIFEST);
    expect(out.body).not.toContain("articles");
  });
});

describe("a link split across lines next to a valid citation", () => {
  const SPLIT = '<a href="https://help.muso.ai/en/ar\narticles/9999999-invented">x</a>';
  const VALID = `${HELP_CITATION_LEAD} ${GOOD}`;
  it.each([
    ["split anchor after the valid line", `Answer.\n${VALID}\n${SPLIT}`],
    ["split anchor before the valid line", `Answer.\n${SPLIT}\n${VALID}`],
  ])("strips the split link and keeps the valid citation: %s", (_n, body) => {
    const out = sanitizeHelpLinks(body, MANIFEST);
    expect(out.body).not.toContain("9999999");
    expect(out.body).toContain(VALID);
    expect(out.redactions.length).toBeGreaterThan(0);
  });
  it("strips the split link when the other article line is itself invalid", () => {
    const out = sanitizeHelpLinks(`Answer.\nSee https://help.muso.ai/en/articles/5-x\n${SPLIT}`, MANIFEST);
    expect(out.body).not.toContain("9999999");
    expect(out.body).not.toContain("articles/5-x");
  });
});

describe("a bare plain-text link split across lines", () => {
  const VALID = `${HELP_CITATION_LEAD} ${GOOD}`;
  it.each([
    ["no manifest", "Answer.\nSee https://help.muso.ai/en/ar\nticles/9999999-invented for details", null],
    ["manifest, no other hit", "Answer.\nSee https://help.muso.ai/en/ar\nticles/9999999-invented for details", MANIFEST],
    ["manifest, valid line kept", `Answer.\n${VALID}\nSee https://help.muso.ai/en/ar\nticles/9999999-invented for details`, MANIFEST],
    ["CR split", "Answer.\nSee https://help.muso.ai/en/ar\r\nticles/9999999-invented", MANIFEST],
  ])("strips the invented link: %s", (_n, body, manifest) => {
    const out = sanitizeHelpLinks(body, manifest);
    expect(out.body).not.toContain("9999999");
    expect(out.body).not.toMatch(/en\/ar[\r\n]/);
    expect(out.body).toContain("Answer.");
  });
  it("does not eat the next line when a whole link ends a line", () => {
    const out = sanitizeHelpLinks("Answer.\nSee https://help.muso.ai/en/articles/5-x\nKeep this sentence.", null);
    expect(out.body).toContain("Keep this sentence.");
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

describe("invariant: no variant leaves an article URL in the body (fail closed)", () => {
  const INV = "9999999-invented";
  const variants: [string, string][] = [
    ["scheme-less 2-part LF split", `Answer.\nSee help.muso.ai/en/ar\nticles/${INV} for details`],
    ["3-part LF split", `Answer.\nSee https://help.muso.ai/en/\nar\nticles/${INV} ok`],
    ["CRLF split", `Answer.\nSee https://help.muso.ai/en/ar\r\nticles/${INV}`],
    ["split next to a valid citation", `Answer.\n${HELP_CITATION_LEAD} ${GOOD}\nSee help.muso.ai/en/ar\nticles/${INV}`],
    ["tab", `Answer.\nhttps://help.muso.ai/en/art\ticles/${INV}`],
    ["&Tab; entity", `Answer.\n<a href="https://help.muso.ai/en/ar&Tab;ticles/${INV}">x</a>`],
    ["&NewLine; entity", `Answer.\n<a href="https://help.muso.ai/en/ar&NewLine;ticles/${INV}">x</a>`],
    ["%09", `Answer.\nSee https://help.muso.ai/en/ar%09ticles/${INV}`],
    ["%0a", `Answer.\nSee https://help.muso.ai/en/ar%0aticles/${INV}`],
    ["uppercase entity", `Answer.\n<a href="https://help.muso.ai/en/ar&TAB;ticles/${INV}">x</a>`],
    ["semicolon-less entity", `Answer.\n<a href="https://help&shy.muso.ai/en/articles/${INV}">x</a>`],
  ];
  it.each(variants)("%s: stripped, and no article URL survives", (_n, body) => {
    for (const m of [null, MANIFEST]) {
      const out = sanitizeHelpLinks(body, m);
      const rest = out.body.split(`${HELP_CITATION_LEAD} ${GOOD}`).join("");
      expect(hasArticleUrl(rest)).toBe(false);
      expect(rest).not.toContain(INV);
      expect(out.body).toContain("Answer.");
    }
  });
  it("a claimed redaction never returns the original body", () => {
    for (const [, body] of variants) {
      const out = sanitizeHelpLinks(body, null);
      if (out.redactions.length) expect(out.body).not.toBe(body);
    }
  });
});

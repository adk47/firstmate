/**
 * Mechanical outbound gate for help-centre links (Caroline cites articles).
 *
 * Every help.muso.ai article URL in a reply is validated against the manifest on
 * id AND slug. A URL survives only when it sits alone on a template line
 * ("More detail here: <url>"), is in the manifest, and is the first such line.
 * Anything else containing an article URL is dropped with its whole line: no
 * placeholder, no apology, no trace. A null manifest (missing / unreadable /
 * malformed) fails closed: all article links are dropped. A bare "help.muso.ai"
 * mention is not an article URL and is left alone. Same shape as
 * sanitize-tool-leak.ts: pure function, redactions are for the internal log only.
 */

import { HELP_CITATION_LEAD, type HelpManifest } from "./help-manifest.js";

export interface HelpLinkSanitizeResult {
  body: string;
  redactions: string[];
}

// Any URL (scheme optional; port and trailing-dot host forms count) on help.muso.ai whose path has an /articles/ segment.
const ARTICLE_URL = /(?:https?:\/\/)?help\.muso\.ai\.?(?::\d*)?\/[^\s<>()[\]"']*articles\/[^\s<>()[\]"']*/i;
// An unknown named entity (&escr; -> U+212F, which NFKC folds to "e") cannot be resolved without the HTML5 table, so
// decoding leaves a placeholder and detection fails closed: the placeholder may stand for any one character, or for nothing.
const PH = "\u0001";
const loose = (lit: string) => [...lit].map((c) => `${PH}*(?:${c.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&")}|${PH})`).join("") + `${PH}*`;
const ARTICLE_URL_LOOSE = new RegExp(`(?:https?:\\/\\/)?${loose("help.muso.ai")}\\.?(?::\\d*)?[^\\s<>()[\\]"']*${loose("articles/")}[^\\s<>()[\\]"']*`, "i");
const TEMPLATE_LINE = new RegExp(`^${HELP_CITATION_LEAD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} (\\S+)$`);

// Named HTML entities for characters that can appear in a URL (detection only).
const NAMED_ENTITIES: Record<string, string> = {
  period: ".", sol: "/", colon: ":", num: "#", amp: "&", quest: "?", equals: "=", lowbar: "_", hyphen: "-", bsol: "\\",
};

// Any whitespace/delimiter-bounded token; dropped when its decoded form carries an article URL, whatever the encoding.
// Delimiter is \s minus U+FEFF: JS \s counts it as whitespace but URL parsers ignore it inside a host, so splitting on it would cut a token in two.
const TOKEN_G = /(?:[^\s<>()[\]"']|\uFEFF)+/g;

/** Decode HTML character references (semicolon optional for every named entity: legacy names like &shy decode without one, and we only decide what to strip, so leniency is safe). An out-of-range code point is left alone, never throws. */
function decodeEntities(s: string): string {
  return s.replace(/&(?:(?:#(\d+)|#x([0-9a-f]+)|(period|sol|colon|num|amp|quest|equals|lowbar|hyphen|bsol));?|([a-z][a-z0-9]*)(;?))/gi, (m, dec?: string, hexs?: string, name?: string, other?: string, semi?: string) => {
    if (name) return NAMED_ENTITIES[name.toLowerCase()] ?? m;
    // Any other named entity may decode to anything (ignorable, letter-folding, ...): leave a wildcard placeholder.
    // Without a semicolon the entity may end anywhere inside the run of letters (&ordfi = &ordf + "i"): one wildcard per character.
    if (other) return semi ? PH : PH.repeat(other.length);
    const cp = dec !== undefined ? parseInt(dec, 10) : parseInt(hexs as string, 16);
    return Number.isFinite(cp) && cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
  });
}

/** Percent-escapes: a run is read as UTF-8 when valid (so %E3%80%82 is the ideographic dot), else byte by byte; a malformed % is left alone. */
function decodePercent(s: string): string {
  return s.replace(/(?:%[0-9a-f]{2})+/gi, (run) => {
    try {
      return decodeURIComponent(run);
    } catch {
      return run.replace(/%([0-9a-f]{2})/gi, (_, h: string) => String.fromCharCode(parseInt(h, 16)));
    }
  });
}

/** What a URL parser folds away: ASCII tab/LF/CR anywhere in the URL, NFKC (fullwidth letters), IDNA dot equivalents, and every default-ignorable code point (the full Unicode class, not a list). */
function normalizeHost(s: string): string {
  return s.normalize("NFKC").replace(/[\u3002\uFF0E\uFF61]/g, ".").replace(/\\/g, "/").replace(/[\t\n\r]|\p{Default_Ignorable_Code_Point}/gu, "");
}

/** Undo HTML entities, percent-escapes and host normalisation (repeatedly, so mixed and double encoding resolve too); a malformed % or entity is left alone, never aborts the decode. Detection only: never the outbound body. */
function decodeAll(s: string): string {
  let cur = normalizeHost(s);
  for (let i = 0; i < 4; i++) {
    const next = normalizeHost(decodePercent(decodeEntities(cur)));
    if (next === cur) break;
    cur = next;
  }
  return cur;
}

/** True when the text, once entity- and percent-decoding are undone, carries an article URL. */
function findArticleUrl(s: string): RegExpExecArray | null {
  return ARTICLE_URL.exec(s) ?? ARTICLE_URL_LOOSE.exec(decodeAll(s));
}
export function hasArticleUrl(s: string): boolean {
  return findArticleUrl(s) !== null;
}
const LEAD_RE = new RegExp(`${HELP_CITATION_LEAD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*(?=(?:<\\/\\w+>\\s*)*$)`, "i");

/** Remove anchors / markdown links / bare tokens carrying an article URL, and a trailing lead-in; keep other prose. */
function stripUrlTokensOnly(body: string): string {
  const stripped = body
    .replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, (m) => (hasArticleUrl(m) ? "" : m))
    .replace(/\[[^\]]*\]\([^)]*\)/g, (m) => (hasArticleUrl(m) ? "" : m))
    .replace(TOKEN_G, (m) => (hasArticleUrl(m) ? "" : m))
    // A link broken by LF/CR (any number of breaks, scheme or not) is several tokens that each look harmless:
    // join the chain of break-separated tokens and test it whole. The kept-citation shield (NUL) never joins a chain.
    .replace(/(?:[^\s\u0000<>()[\]"']+[\r\n]+)+[^\s\u0000<>()[\]"']+/g, (m) => (hasArticleUrl(m) ? "" : m));
  return stripped
    .split("\n")
    .map((l) => l.replace(LEAD_RE, "").replace(/[ \t]{2,}/g, " ").replace(/\s+$/, ""))
    .join("\n")
    .replace(/\s+(<\/\w+>)/g, "$1")
    .replace(/<p>\s*<\/p>/gi, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Last resort: drop every line that is part of the shortest run of adjacent lines whose join carries an article URL. */
function dropLinesCarryingUrl(text: string): string {
  const lines = text.split("\n");
  const drop = new Set<number>();
  for (let i = 0; i < lines.length; i++) {
    for (let w = 1; i + w <= lines.length; w++) {
      if (hasArticleUrl(lines.slice(i, i + w).join("\n"))) {
        for (let k = i; k < i + w; k++) drop.add(k);
        break;
      }
    }
  }
  return lines.filter((_, i) => !drop.has(i)).join("\n");
}

export function sanitizeHelpLinks(body: string, manifest: HelpManifest | null): HelpLinkSanitizeResult {
  if (typeof body !== "string" || !hasArticleUrl(body)) return { body, redactions: [] };

  const redactions: string[] = [];
  let kept = false;
  let keptIdx = -1;
  let keptLine = "";
  const out: string[] = [];
  for (const line of body.split("\n")) {
    const hit = findArticleUrl(line);
    if (!hit) {
      out.push(line);
      continue;
    }
    const url = TEMPLATE_LINE.exec(line.trim())?.[1];
    const id = url ? /^https:\/\/help\.muso\.ai\/en\/articles\/(\d+)-/.exec(url)?.[1] : undefined;
    const valid = !!url && !!id && manifest?.articles[id]?.url === url;
    if (valid && !kept) {
      kept = true;
      keptIdx = out.length;
      keptLine = line;
      out.push(line);
    } else {
      redactions.push(hit[0]);
    }
  }
  // A link split across lines (LF/CR inside an href) matches no single line, even when another line
  // is a valid citation; sweep the remainder by token, shielding the kept citation line.
  const SHIELD = "\u0000KEPT\u0000";
  if (keptIdx >= 0) out[keptIdx] = SHIELD;
  const rest = out.join("\n");
  let joined = rest;
  if (hasArticleUrl(rest)) {
    joined = stripUrlTokensOnly(rest);
    redactions.push(rest);
  }
  // Invariant: a claimed redaction never leaves an article URL behind. If a pass mismatch let one through
  // (a span the token sweep cannot locate), drop whole lines, widest spans first, until none is left.
  if (hasArticleUrl(joined)) {
    joined = dropLinesCarryingUrl(joined);
    if (!redactions.length) redactions.push(rest);
  }
  joined = joined.replace(SHIELD, keptLine);
  const cleaned = joined.replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "");
  if (cleaned.trim().length > 0 || !stripUrlTokensOnly(body).trim()) return { body: cleaned, redactions };
  // Dropping whole lines emptied a reply that had prose around the URL (a model that
  // ignored the template). Never post an empty body: keep the prose, lose only the URL.
  const tokenOnly = stripUrlTokensOnly(body);
  return { body: hasArticleUrl(tokenOnly) ? dropLinesCarryingUrl(tokenOnly) : tokenOnly, redactions };
}

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
const TEMPLATE_LINE = new RegExp(`^${HELP_CITATION_LEAD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} (\\S+)$`);

// Any help.muso.ai-looking token, whatever its path; every host char may be percent-encoded. Kept only if it decodes to an article URL.
const hostChar = (c: string) => `(?:${c === "." ? "\\." : c}|%${c.charCodeAt(0).toString(16).padStart(2, "0")})`;
const HELP_TOKEN_G = new RegExp(`(?:https?:\\/\\/)?${[..."help.muso.ai"].map(hostChar).join("")}[^\\s<>()[\\]"']*`, "gi");

/** Percent-decode every well-formed %XX (repeatedly, so double encoding resolves too); a malformed % is left alone, never aborts the decode. */
function decodeAll(s: string): string {
  let cur = s;
  for (let i = 0; i < 4; i++) {
    const next = cur.replace(/%([0-9a-f]{2})/gi, (_, h: string) => String.fromCharCode(parseInt(h, 16)));
    if (next === cur) break;
    cur = next;
  }
  return cur;
}

/** True when the text, once percent-decoding is undone, carries an article URL. */
function hasArticleUrl(s: string): boolean {
  return ARTICLE_URL.test(s) || ARTICLE_URL.test(decodeAll(s));
}
const LEAD_RE = new RegExp(`${HELP_CITATION_LEAD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*(?=(?:<\\/\\w+>\\s*)*$)`, "i");

/** Remove anchors / markdown links / bare tokens carrying an article URL, and a trailing lead-in; keep other prose. */
function stripUrlTokensOnly(body: string): string {
  const stripped = body
    .replace(/<a\b[^>]*>[\s\S]*?<\/a>/gi, (m) => (hasArticleUrl(m) ? "" : m))
    .replace(/\[[^\]]*\]\([^)]*\)/g, (m) => (hasArticleUrl(m) ? "" : m))
    .replace(HELP_TOKEN_G, (m) => (hasArticleUrl(m) ? "" : m));
  return stripped
    .split("\n")
    .map((l) => l.replace(LEAD_RE, "").replace(/[ \t]{2,}/g, " ").replace(/\s+$/, ""))
    .join("\n")
    .replace(/\s+(<\/\w+>)/g, "$1")
    .replace(/<p>\s*<\/p>/gi, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function sanitizeHelpLinks(body: string, manifest: HelpManifest | null): HelpLinkSanitizeResult {
  if (typeof body !== "string" || !hasArticleUrl(body)) return { body, redactions: [] };

  const redactions: string[] = [];
  let kept = false;
  const out: string[] = [];
  for (const line of body.split("\n")) {
    const hit = ARTICLE_URL.exec(line) ?? ARTICLE_URL.exec(decodeAll(line));
    if (!hit) {
      out.push(line);
      continue;
    }
    const url = TEMPLATE_LINE.exec(line.trim())?.[1];
    const id = url ? /^https:\/\/help\.muso\.ai\/en\/articles\/(\d+)-/.exec(url)?.[1] : undefined;
    const valid = !!url && !!id && manifest?.articles[id]?.url === url;
    if (valid && !kept) {
      kept = true;
      out.push(line);
    } else {
      redactions.push(hit[0]);
    }
  }
  const cleaned = out.join("\n").replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "");
  if (cleaned.trim().length > 0 || !stripUrlTokensOnly(body).trim()) return { body: cleaned, redactions };
  // Dropping whole lines emptied a reply that had prose around the URL (a model that
  // ignored the template). Never post an empty body: keep the prose, lose only the URL.
  return { body: stripUrlTokensOnly(body), redactions };
}

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

// Any URL (scheme optional) on help.muso.ai whose path has an /articles/ segment.
const ARTICLE_URL = /(?:https?:\/\/)?help\.muso\.ai\/[^\s<>()[\]"']*articles\/[^\s<>()[\]"']*/i;
const TEMPLATE_LINE = new RegExp(`^${HELP_CITATION_LEAD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")} (\\S+)$`);

export function sanitizeHelpLinks(body: string, manifest: HelpManifest | null): HelpLinkSanitizeResult {
  if (typeof body !== "string" || !ARTICLE_URL.test(body)) return { body, redactions: [] };

  const redactions: string[] = [];
  let kept = false;
  const out: string[] = [];
  for (const line of body.split("\n")) {
    const hit = ARTICLE_URL.exec(line);
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
  return { body: cleaned, redactions };
}

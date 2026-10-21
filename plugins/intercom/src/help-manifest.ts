/**
 * Help-centre citation manifest (written by scripts/sync-help-centre.sh).
 *
 * Contract: { generated_at, articles: { "<id>": { slug, title, url } } }.
 * The loader is separate from the predicate (same pattern as KbSearcher): tests
 * pass a fixture, prod reads the real path. Anything missing, unreadable or
 * malformed loads as null, and every consumer treats null as "no link allowed".
 */

import { readFileSync } from "node:fs";

export interface HelpArticle {
  slug: string;
  title: string;
  url: string;
}
export interface HelpManifest {
  articles: Record<string, HelpArticle>;
}

export const DEFAULT_HELP_MANIFEST_PATH =
  process.env.HELP_CENTRE_MANIFEST ?? "/opt/hydra/workspaces/support/reference/hc-manifest.json";

/** The one fixed closing line Caroline may use. The sanitizer enforces this exact shape. */
export const HELP_CITATION_LEAD = "More detail here:";

const URL_PREFIX = "https://help.muso.ai/en/articles/";

export function parseHelpManifest(raw: string): HelpManifest | null {
  let data: unknown;
  try {
    data = JSON.parse(raw);
  } catch {
    return null;
  }
  const articles = (data as { articles?: unknown } | null)?.articles;
  if (!articles || typeof articles !== "object" || Array.isArray(articles)) return null;
  for (const [id, a] of Object.entries(articles as Record<string, unknown>)) {
    const art = a as Partial<HelpArticle> | null;
    if (
      !/^\d+$/.test(id) ||
      !art ||
      typeof art.slug !== "string" ||
      typeof art.url !== "string" ||
      art.url !== `${URL_PREFIX}${id}-${art.slug}`
    ) {
      return null;
    }
  }
  return { articles: articles as Record<string, HelpArticle> };
}

export function loadHelpManifest(
  path: string = DEFAULT_HELP_MANIFEST_PATH,
  read: (p: string) => string = (p) => readFileSync(p, "utf8"),
): HelpManifest | null {
  try {
    return parseHelpManifest(read(path));
  } catch {
    return null;
  }
}

/** Article URL for a memory-search path like `reference/hc-1234567.md`, else undefined. */
export function citationUrlForPath(path: string | undefined, manifest: HelpManifest | null): string | undefined {
  const id = path ? /(?:^|\/)hc-(\d+)\.md$/.exec(path)?.[1] : undefined;
  return id && manifest ? manifest.articles[id]?.url : undefined;
}

export function isHelpCentrePath(path: string | undefined): boolean {
  return !!path && /(?:^|\/)hc-\d+\.md$/.test(path);
}

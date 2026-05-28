import path from "node:path";
import fs from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ImageAttachmentRef, DocumentAttachmentRef } from "./types.js";
import { IMAGE_MIME_ALLOWLIST } from "./filters.js";

const execFileAsync = promisify(execFile);

// Pipeline: fetch each Intercom CDN URL (~30 min TTL — must happen
// synchronously at webhook-receive time), persist bytes under
// <stateDir>/media/intercom/<convId>/<n>.<ext>, and return the persisted
// paths + MIMEs in the order they came in. We pass the paths to the agent
// runtime via the openclaw SDK's MsgContext (MediaPaths/MediaTypes), which
// the runtime base64-encodes and forwards as `{type: "image", ...}` content
// blocks to vision-capable models. The path-based route is preferred over
// the URL route because Intercom CDN signed URLs may have expired by the
// time the runtime fetches them (especially on retries / queued dispatch).
// We also surface the original URLs as MediaUrls so the SDK has a fallback
// if path resolution fails for any reason.

// Cap per message. Most uploads are 1; this is a generous-but-bounded
// budget to avoid runaway disk usage / dispatch latency if a customer
// pastes 30 images at once. The first N (in order) are forwarded.
export const MAX_IMAGE_ATTACHMENTS_PER_TURN = 8;

// Per-image timeout for the CDN fetch. Webhooks should respond fast — the
// reply handshake already returned 200 before this runs, so this only
// gates how long we wait before giving up on a given image. 12s is
// comfortably above Intercom CDN p99 (~1-3s observed) but well below
// the gateway turn timeout.
export const ATTACHMENT_FETCH_TIMEOUT_MS = 12_000;

// Per-image size cap. The downstream SDK's
// AGENT_TURN_ATTACHMENT_MAX_BYTES is 10MB; we cap at the same number so
// we don't persist bytes that the SDK will reject. Larger uploads are
// dropped with a warn log. Applies to BOTH the original PDF file and each
// rasterized page PNG (the vision path enforces the same 10MB per attachment).
export const ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024;

// Cap on how many PDF pages we rasterize to PNG for the vision path. openclaw's
// document-extract caps around 4 pages / 5MB for the TEXT path, but vision
// benefits from seeing more (scanned multi-page docs), so 8 is a sane upper
// bound that also matches MAX_IMAGE_ATTACHMENTS_PER_TURN's order of magnitude
// without blowing the dispatch budget.
export const MAX_PDF_PAGES = 8;

// Hard ceiling on the TOTAL number of media entries forwarded to the agent in
// one turn, across images AND documents combined. The per-type count caps above
// are not enough on their own: a single PDF fans out to up to MAX_PDF_PAGES PNG
// pages + 1 original, so 8 PDFs could otherwise produce ~72 entries and blow up
// dispatch latency / request size / cost. The combined list is truncated to this
// budget (see channel.ts) with a warn log. Restores the original "bounded media
// per turn" safety intent that the image-only cap used to provide.
export const MAX_MEDIA_ENTRIES_PER_TURN = 12;

// Hard ceiling on how many PDF refs we will ATTEMPT to download in one turn,
// independent of the success budget above. The output budget only decreases on
// SUCCESSFUL entries, so without this a message carrying many failing/oversized/
// expired PDF refs would still trigger one sequential CDN fetch per ref (the
// budget never drops, the loop never breaks). This bounds total download work
// regardless of success. Mirrors the image pipeline's slice cap.
export const MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN = MAX_IMAGE_ATTACHMENTS_PER_TURN;

// Size ceiling for forwarding the ORIGINAL PDF on the text-extract path. openclaw's
// document-extract silently skips PDFs larger than its own limit (default ~5MB,
// `config?.maxBytes ?? 5242880` in input-files), so forwarding a 5-10MB PDF as
// application/pdf just produces a no-op skip. We mirror that default here and only
// forward the original PDF for text when it is within range; rasterized page PNGs
// (vision) still go up to ATTACHMENT_MAX_BYTES, so large PDFs are still SEEN, just
// not text-extracted. To enable text for larger PDFs, raise BOTH this constant and
// the edge `tools.files.maxBytes` config together (verify the gateway accepts it).
export const PDF_TEXT_EXTRACT_MAX_BYTES = 5 * 1024 * 1024;

// DPI for PDF→PNG rasterization. 110 keeps text legible to a vision model while
// staying well under the 10MB per-page cap for typical A4/Letter pages.
export const PDF_RASTER_DPI = 110;

// Host binary used to rasterize PDF pages to PNG. We shell out rather than
// bundling a JS PDF renderer because:
//   - deploy.sh rsyncs the plugin dir with `--exclude=node_modules`, so any
//     added npm dep (pdfjs-dist, @napi-rs/canvas, pdf-to-img) would NOT be
//     present at runtime in the extension dir — the gateway only resolves
//     `openclaw` + its own deps, and `tsc` does no bundling.
//   - native/prebuilt-binary deps are explicitly flagged as fragile for the
//     openclaw 2026.5.x single-file packaging contract.
// `pdftoppm` (poppler-utils) has zero node_modules footprint. REQUIREMENT:
// node-8 must have poppler-utils installed (`apt-get install -y poppler-utils`).
// If the binary is missing, rasterization is skipped (warn) and we still
// forward the original PDF for text extraction — degraded, not broken.
//
// Resolved at CALL time (not module load) so the env var can be set after
// import — required for tests, and harmless in prod (the env is stable).
export function resolvePdftoppmBin(): string {
  return process.env.INTERCOM_PDFTOPPM_BIN?.trim() || "pdftoppm";
}

// Persistence layout: ensureConvDir() appends "intercom/<conv>/<msg>/" under
// whatever `mediaRoot` the caller passes. The PREFERRED root is the support
// agent's workspaceDir so (a) the path passes openclaw's inbound media
// allowlist — resolveMediaAttachmentLocalRoots merges the agent workspaceDir
// into the allowed roots — and (b) Caroline can browse the raw files herself.
// This is UNVERIFIED end-to-end for the Intercom channel as of this change; if
// the gateway rejects the workspace-rooted path at dispatch time, the original
// CDN URL still rides along in MediaUrls as the fallback, and the caller can
// switch to the <stateDir>/media fallback (see channel.ts resolveMediaRoot).

// Fallback persistence root segment under <stateDir>/media (the pre-existing,
// known-allowed location). Used when the agent workspace dir can't be resolved.
export const STATEDIR_MEDIA_FALLBACK = "media";

export interface PersistedAttachment {
  /** Absolute path on disk, under an openclaw-allowed media root. */
  path: string;
  /** MIME the file was persisted with — passed verbatim as MediaType. */
  contentType: string;
  /** Original source URL — surfaced as MediaUrl for SDK fallback. */
  url: string;
  /** Bytes actually persisted (post-download, for logging). */
  size: number;
}

export interface DownloadDeps {
  // Injectable for tests; defaults to global fetch.
  fetchImpl?: typeof fetch;
  // Logging hook — error path is intentionally non-throwing so a single
  // bad attachment doesn't kill the whole turn.
  log?: { warn?: (msg: string) => void; info?: (msg: string) => void };
}

function extensionForMime(mime: string): string {
  switch (mime.toLowerCase()) {
    case "image/png": return ".png";
    case "image/jpeg":
    case "image/jpg": return ".jpg";
    case "image/gif": return ".gif";
    case "image/webp": return ".webp";
    case "application/pdf": return ".pdf";
    default: return ".bin";
  }
}

function sanitizeSegment(value: string): string {
  // Allow alphanumerics, dash, underscore, dot. Replace anything else
  // with `_`. Defense against Intercom ever sending unexpected conv-id
  // characters that escape into the filesystem.
  return value.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 64) || "anon";
}

/**
 * Fetch and persist a single image attachment. Returns `null` (with a
 * warn log) on any failure — the caller filters nulls before passing
 * the list to the dispatcher. We never throw from here; one bad image
 * shouldn't sink the message.
 *
 * Intercom CDN URLs are public-signed: NO auth header required. We use
 * a vanilla fetch with no headers besides the implicit `Accept`. If
 * Intercom ever changes that contract, surface here.
 */
async function fetchAndPersistOne(
  ref: ImageAttachmentRef,
  destDir: string,
  index: number,
  deps: DownloadDeps,
): Promise<PersistedAttachment | null> {
  const fetchImpl = deps.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    deps.log?.warn?.(`[intercom:attachments] no fetch available — cannot persist image url=${ref.url}`);
    return null;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ATTACHMENT_FETCH_TIMEOUT_MS);
  try {
    const res = await fetchImpl(ref.url, { signal: controller.signal });
    if (!res.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] CDN fetch failed status=${res.status} url=${ref.url}`,
      );
      return null;
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > ATTACHMENT_MAX_BYTES) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized image bytes=${buf.length} cap=${ATTACHMENT_MAX_BYTES} url=${ref.url}`,
      );
      return null;
    }
    // Prefer the server's reported Content-Type when present; fall back
    // to the URL-inferred MIME we extracted at classify time. Lowercase
    // and strip parameters (`; charset=...` etc.) defensively. Constrain
    // the override to the same IMAGE_MIME_ALLOWLIST classify uses, so a
    // server emitting `image/svg+xml` or other unsupported image types
    // can't slip past the upstream MIME check. (Clio review of PR #360.)
    const serverType = (res.headers.get("content-type") ?? "")
      .split(";")[0]
      ?.trim()
      .toLowerCase();
    const contentType =
      serverType && IMAGE_MIME_ALLOWLIST.has(serverType)
        ? serverType
        : ref.contentType;
    const filename = `${index}${extensionForMime(contentType)}`;
    const fullPath = path.join(destDir, filename);
    await fs.writeFile(fullPath, buf);
    return { path: fullPath, contentType, url: ref.url, size: buf.length };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] fetch/persist threw url=${ref.url} reason=${reason}`,
    );
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Download every image in `refs` (up to MAX_IMAGE_ATTACHMENTS_PER_TURN)
 * into `<mediaRoot>/intercom/<convId>/`, in parallel. Returns only the
 * successful persists. Caller is responsible for cleanup — current
 * policy is don't bother (small files, openclaw also persists to the
 * session JSONL anyway, and the directory is per-conv so it gets
 * naturally bounded by traffic).
 *
 * `mediaRoot` must be one of openclaw's allowed inbound roots — typically
 * `<stateDir>/media/`. The caller resolves this via `resolveStateDir()`.
 */
export async function downloadImageAttachments(params: {
  refs: ImageAttachmentRef[];
  conversationId: string;
  mediaRoot: string;
  messageId?: string;
  deps?: DownloadDeps;
}): Promise<PersistedAttachment[]> {
  const deps = params.deps ?? {};
  const limited = params.refs.slice(0, MAX_IMAGE_ATTACHMENTS_PER_TURN);
  if (params.refs.length > MAX_IMAGE_ATTACHMENTS_PER_TURN) {
    deps.log?.warn?.(
      `[intercom:attachments] truncated attachments count=${params.refs.length} cap=${MAX_IMAGE_ATTACHMENTS_PER_TURN} conv=${params.conversationId}`,
    );
  }
  if (limited.length === 0) return [];
  const convDir = await ensureConvDir(params.mediaRoot, params.conversationId, params.messageId);
  const results = await Promise.all(
    limited.map((ref, idx) => fetchAndPersistOne(ref, convDir, idx, deps)),
  );
  return results.filter((r): r is PersistedAttachment => r !== null);
}

/**
 * Resolve and create the per-message directory:
 *   <mediaRoot>/intercom/<convId>/<msgId>/
 *
 * Note: callers pass `mediaRoot` already pointing at the persistence root
 * (workspace-rooted or stateDir fallback) WITHOUT the trailing "intercom"
 * segment — we append it here so the on-disk layout matches
 * `workspaces/support/intercom/<conv>/<msg>/...` exactly.
 *
 * Each message gets its own directory keyed by messageId where possible so
 * concurrent webhooks on the same conv don't clobber each other's files.
 * Falls back to a timestamp-only path if no messageId.
 */
async function ensureConvDir(
  mediaRoot: string,
  conversationId: string,
  messageId?: string,
): Promise<string> {
  const subdir = sanitizeSegment(messageId ?? `${Date.now()}`);
  const convDir = path.join(
    mediaRoot,
    "intercom",
    sanitizeSegment(conversationId),
    subdir,
  );
  await fs.mkdir(convDir, { recursive: true });
  return convDir;
}

/**
 * Rasterize up to MAX_PDF_PAGES pages of a PDF on disk to PNG files in the
 * same directory, named `<index>-p-NN.png` (NN = 1-based page number, as
 * emitted by pdftoppm). Returns the list of written PNG paths in page order,
 * or [] on any failure (missing pdftoppm, malformed PDF, timeout). NEVER
 * throws — a bad PDF must not sink the turn; the original PDF still rides along
 * for text extraction.
 *
 * `index` is the document's slot in the overall attachment ordering, used as a
 * filename prefix so multiple PDFs in one message don't collide.
 */
async function rasterizePdfPages(
  pdfPath: string,
  destDir: string,
  index: number,
  maxPages: number,
  deps: DownloadDeps,
): Promise<string[]> {
  // Never render more than the caller's remaining budget allows (and never more
  // than MAX_PDF_PAGES). `-l` makes pdftoppm stop at that page, so we don't burn
  // CPU/disk rendering pages we'd only discard downstream.
  const pageLimit = Math.max(0, Math.min(MAX_PDF_PAGES, maxPages));
  if (pageLimit === 0) return [];
  const prefix = path.join(destDir, `${index}-p`);
  try {
    // pdftoppm emits <prefix>-N.png for each page (N is NOT zero-padded for
    // single-digit page counts, and it only writes pages that actually exist —
    // asking for -l 8 on a 2-page doc yields just 2 files). We therefore read
    // the dir back and sort numerically rather than predicting names.
    await execFileAsync(
      resolvePdftoppmBin(),
      ["-png", "-r", String(PDF_RASTER_DPI), "-f", "1", "-l", String(pageLimit), pdfPath, prefix],
      { timeout: ATTACHMENT_FETCH_TIMEOUT_MS, maxBuffer: ATTACHMENT_MAX_BYTES },
    );
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] pdftoppm rasterization failed (forwarding original PDF only) path=${pdfPath} reason=${reason}`,
    );
    return [];
  }
  // pdftoppm appends "-<page>.png" to our "<index>-p" prefix, so the on-disk
  // names are "<index>-p-<page>.png" (page NOT zero-padded for <10 pages).
  // Read the dir back and sort numerically rather than predicting names.
  const wantBase = `${index}-p`;
  const pageRe = new RegExp(`^${index}-p-(\\d+)\\.png$`);
  let entries: string[];
  try {
    entries = await fs.readdir(destDir);
  } catch {
    return [];
  }
  const pages = entries
    .map((name) => {
      if (!name.startsWith(wantBase)) return null;
      const m = pageRe.exec(name);
      if (!m) return null;
      return { name, page: Number(m[1]) };
    })
    .filter((e): e is { name: string; page: number } => e !== null)
    .sort((a, b) => a.page - b.page)
    .slice(0, pageLimit)
    .map((e) => path.join(destDir, e.name));
  return pages;
}

/**
 * Fetch and persist a single PDF, then rasterize its pages. Returns ordered
 * PersistedAttachment entries: the rasterized PNG pages FIRST (so vision sees
 * the document) followed by the original PDF entry (consumed by openclaw's
 * document-extract for text). Returns [] on download failure. Never throws.
 *
 * The PNG entries carry the ORIGINAL pdf URL as their `url` (there's no
 * per-page CDN URL) — harmless, because the path is canonical and only used as
 * SDK fallback; the page PNGs only exist on disk.
 */
async function fetchPersistAndRasterizePdf(
  ref: DocumentAttachmentRef,
  destDir: string,
  index: number,
  budget: number,
  deps: DownloadDeps,
): Promise<PersistedAttachment[]> {
  if (budget <= 0) return [];
  const fetchImpl = deps.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    deps.log?.warn?.(`[intercom:attachments] no fetch available — cannot persist pdf url=${ref.url}`);
    return [];
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ATTACHMENT_FETCH_TIMEOUT_MS);
  let pdfPath: string;
  let pdfSize: number;
  try {
    const res = await fetchImpl(ref.url, { signal: controller.signal });
    if (!res.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] CDN fetch failed status=${res.status} url=${ref.url}`,
      );
      return [];
    }
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > ATTACHMENT_MAX_BYTES) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized pdf bytes=${buf.length} cap=${ATTACHMENT_MAX_BYTES} url=${ref.url}`,
      );
      return [];
    }
    pdfPath = path.join(destDir, `${index}${extensionForMime("application/pdf")}`);
    pdfSize = buf.length;
    await fs.writeFile(pdfPath, buf);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] pdf fetch/persist threw url=${ref.url} reason=${reason}`,
    );
    return [];
  } finally {
    clearTimeout(timer);
  }

  const out: PersistedAttachment[] = [];
  // Rasterized pages first (vision), each capped at ATTACHMENT_MAX_BYTES. Pages
  // get priority for the budget (seeing the doc matters more than its text), so
  // we render at most `budget` of them; pdftoppm's -l avoids rendering the rest.
  const pagePaths = await rasterizePdfPages(pdfPath, destDir, index, budget, deps);
  for (const pagePath of pagePaths) {
    let size: number;
    try {
      const stat = await fs.stat(pagePath);
      size = stat.size;
    } catch {
      continue;
    }
    if (size > ATTACHMENT_MAX_BYTES) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized rasterized page bytes=${size} cap=${ATTACHMENT_MAX_BYTES} path=${pagePath}`,
      );
      continue;
    }
    out.push({ path: pagePath, contentType: "image/png", url: ref.url, size });
  }
  // Original PDF last (document-extract text path) — only when (a) there's still
  // budget after the pages and (b) it is within openclaw's text-extract size
  // limit. Beyond the size limit, extraction silently skips it, so forwarding the
  // application/pdf entry is pointless; the rasterized pages above still give the
  // agent vision on the document.
  if (out.length >= budget) {
    return out;
  }
  if (pdfSize <= PDF_TEXT_EXTRACT_MAX_BYTES) {
    out.push({ path: pdfPath, contentType: "application/pdf", url: ref.url, size: pdfSize });
  } else {
    deps.log?.info?.(
      `[intercom:attachments] pdf too large for text extraction, forwarding rasterized pages only bytes=${pdfSize} cap=${PDF_TEXT_EXTRACT_MAX_BYTES} url=${ref.url}`,
    );
  }
  return out;
}

/**
 * Download PDFs in `refs` into the per-message dir, persisting the original +
 * rasterized PNG pages for each, until the entry `budget` is exhausted. Returns
 * the flattened, ordered list of PersistedAttachment entries (pages then
 * original, per document). Non-throwing per attachment.
 *
 * The budget is threaded all the way into rasterization (via pdftoppm `-l`) and
 * download: we process PDFs sequentially and STOP downloading/rasterizing once
 * the budget is full, so an 8-PDF flood never does ~64 rasterizations only to
 * have most discarded downstream. `budget` defaults to MAX_MEDIA_ENTRIES_PER_TURN
 * (the channel passes the slots remaining after images).
 */
export async function downloadDocumentAttachments(params: {
  refs: DocumentAttachmentRef[];
  conversationId: string;
  mediaRoot: string;
  messageId?: string;
  budget?: number;
  deps?: DownloadDeps;
}): Promise<PersistedAttachment[]> {
  const deps = params.deps ?? {};
  const budget = params.budget ?? MAX_MEDIA_ENTRIES_PER_TURN;
  if (budget <= 0 || params.refs.length === 0) return [];
  // Attempt cap is independent of the success budget: a flood of failing/oversized
  // refs must not drive unbounded sequential CDN fetches (failures don't consume
  // the budget, so the budget break alone wouldn't stop them).
  const attempts = params.refs.slice(0, MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN);
  if (params.refs.length > MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN) {
    deps.log?.warn?.(
      `[intercom:attachments] truncated documents count=${params.refs.length} cap=${MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN} conv=${params.conversationId}`,
    );
  }
  const convDir = await ensureConvDir(params.mediaRoot, params.conversationId, params.messageId);
  const out: PersistedAttachment[] = [];
  let remaining = budget;
  // Sequential so we can stop early: each PDF consumes from `remaining`, and the
  // moment it hits 0 we don't download/rasterize any further PDFs.
  for (let idx = 0; idx < attempts.length; idx++) {
    if (remaining <= 0) {
      deps.log?.warn?.(
        `[intercom:attachments] media budget exhausted, skipping ${attempts.length - idx} remaining document(s) conv=${params.conversationId}`,
      );
      break;
    }
    // Index offset by MAX_IMAGE_ATTACHMENTS_PER_TURN so PDF filenames can't
    // collide with image filenames (0..N images, then N.. for documents).
    const entries = await fetchPersistAndRasterizePdf(
      attempts[idx],
      convDir,
      MAX_IMAGE_ATTACHMENTS_PER_TURN + idx,
      remaining,
      deps,
    );
    out.push(...entries);
    remaining -= entries.length;
  }
  return out;
}

/**
 * Build the `extraContext` keys consumed by openclaw's MsgContext to
 * surface inbound media to vision-capable models. Keys mirror
 * `ChannelInboundMediaPayload` from the SDK
 * (`@openclaw/plugin-sdk → channels/inbound-event/media`):
 *
 *   - `MediaPaths[i]` is canonical (path-based, durable past CDN expiry).
 *   - `MediaUrls[i]` is the original CDN URL, surfaced as SDK fallback.
 *   - `MediaTypes[i]` carries the resolved MIME.
 *
 * The three arrays are index-aligned — openclaw's `normalizeAttachments`
 * (verified 2026.5.19, runner.normalizeAttachments) pairs path[i]/url[i]/
 * type[i] by position. So callers MUST pass `attachments` in the exact order
 * they want the agent to receive them, with each entry's path/url/contentType
 * consistent. Mixed image + PDF lists are supported: pass image entries and
 * the document pipeline's (rasterized-PNG-then-original-PDF) entries in one
 * flat array; image/* entries flow to the vision path, application/pdf entries
 * flow to document-extract, and the PNG pages flow to vision too.
 *
 * Returns `{}` when there are no attachments — callers can spread the
 * result unconditionally.
 */
export function buildMediaExtraContext(
  attachments: PersistedAttachment[],
): Record<string, unknown> {
  if (attachments.length === 0) return {};
  return {
    MediaPaths: attachments.map((a) => a.path),
    MediaUrls: attachments.map((a) => a.url),
    MediaTypes: attachments.map((a) => a.contentType),
  };
}

/**
 * Cap the combined per-turn media list (images + document/page entries) at
 * MAX_MEDIA_ENTRIES_PER_TURN. Images keep priority (kept first), then document
 * entries fill the remainder. Returns the capped list plus enough info for the
 * caller to emit a single warn log. Pure + side-effect-free for testability.
 */
export function capMediaEntries(
  images: PersistedAttachment[],
  documents: PersistedAttachment[],
): { entries: PersistedAttachment[]; total: number; truncated: boolean } {
  const combined = [...images, ...documents];
  return {
    entries: combined.slice(0, MAX_MEDIA_ENTRIES_PER_TURN),
    total: combined.length,
    truncated: combined.length > MAX_MEDIA_ENTRIES_PER_TURN,
  };
}

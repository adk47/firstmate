import path from "node:path";
import fs from "node:fs/promises";
import crypto from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ImageAttachmentRef, DocumentAttachmentRef } from "./types.js";
import { INTERCOM_CDN_HOST_RE } from "./filters.js";

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

// Host binary used to transcode HEIC/HEIF to JPEG, same rationale as pdftoppm
// above (zero node_modules footprint, survives the rsync --exclude=node_modules
// packaging contract). `heif-convert` ships in Debian's `libheif-examples`
// package. REQUIREMENT: node-8 must have it installed
// (`apt-get install -y libheif-examples`). scripts/deploy.sh warns (does not
// halt) when either binary is absent.
//
// If the binary is missing/broken, the attachment resolves to an explicit
// `unreadable` result rather than silence — degraded, not invisible.
export function resolveHeifConvertBin(): string {
  return process.env.INTERCOM_HEIF_CONVERT_BIN?.trim() || "heif-convert";
}

// JPEG quality for the HEIC→JPEG transcode. 90 keeps screenshot text crisp for
// OCR/vision while staying far below the 10MB per-attachment cap.
export const HEIF_CONVERT_JPEG_QUALITY = 90;

// Cap on how many images we take out of ONE HEIC container. Apple HEICs are
// routinely multi-item (tiled grids, depth/alpha auxiliary images, embedded
// previews), and libheif's heif-convert writes one JPEG per top-level image as
// `<out>-1.jpg`, `<out>-2.jpg`, … instead of the `<out>.jpg` you asked for.
// We forward the primary (lowest-numbered) image only; the rest are auxiliary
// data (depth maps, alpha) that carry no support-relevant content.
export const MAX_HEIF_OUTPUT_IMAGES = 1;

// Maximum HTTP redirect hops we will follow while re-checking the CDN host
// allowlist at EVERY hop. Bounded so a redirect loop can't spin the webhook.
export const MAX_ATTACHMENT_REDIRECT_HOPS = 5;

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
  /** SHA-256 of the SOURCE bytes — the dedupe key. Absent for derived files
   *  (rasterized PDF pages) where the source hash is not meaningful. */
  sha256?: string;
}

/**
 * Why an attachment could not be handed to the agent. Every value is a
 * DELIBERATE, evidenced refusal — never a silent drop. Ops doctrine (see
 * workspaces/operations/skills/muso-clickup-ticket-sweeper/SKILL.md) forbids
 * calling evidence "corrupt" or a decoder "failed" without one of these.
 */
export type UnreadableReason =
  /** Genuine HEIC/HEIF bytes, but `heif-convert` failed / is missing / timed out. */
  | "heic_decode_failed"
  /** Bytes match no image container we recognize (truncated / corrupt / not an image). */
  | "corrupt_or_unrecognized"
  /** SVG/XML/HTML wearing an image content-type. Refused, never sanitized. */
  | "markup_refused"
  /** A redirect hop left the Intercom CDN host allowlist. */
  | "redirect_off_allowlist"
  /** Body exceeded ATTACHMENT_MAX_BYTES (declared or while streaming). */
  | "oversize"
  /** Non-2xx, network error, or timeout fetching the CDN URL. */
  | "fetch_failed"
  /** Our pipeline could not even try: no state dir, no writable media root, no
   *  fetch implementation, a failed rename. Nothing about the customer's file
   *  is known to be wrong — this is a host/provisioning fault. */
  | "pipeline_failed"
  /** The attachment was fine but did not fit the per-turn media budget, so it
   *  was not forwarded. The agent is seeing a PARTIAL set. */
  | "truncated"
  /** Intercom delivered a content-type we have no forwarding path for (TIFF,
   *  BMP, video, …). Refused at extraction time — never downloaded. */
  | "unsupported_type"
  /** The attachment URL was not on the Intercom CDN host allowlist, so it was
   *  never fetched. Refused at extraction time, before any request. */
  | "host_not_allowed";

/**
 * An attachment that EXISTED and could not be forwarded. Distinct from "no
 * attachment": the agent-facing consequence is the same (no image), but the
 * operational one is not — this is the artifact that lets a human say "the
 * decoder failed" and be believed.
 */
export interface UnreadableAttachment {
  kind: "unreadable";
  url: string;
  reason: UnreadableReason;
  /** The content-type Intercom declared, for the header-vs-bytes record. */
  declaredContentType: string;
  /** What the magic bytes actually said, when we got far enough to look. */
  detectedFormat?: DetectedFormat;
  /** Where the raw bytes were preserved, when we got them. */
  path?: string;
  /** Free-text detail (subprocess stderr, HTTP status, …). OPERATOR-facing:
   *  it reaches the logs, NOT the prompt. Anything the agent must act on has to
   *  be a structured field — `detail` was briefly used to mark partial
   *  delivery and the renderer silently ignored it. */
  detail?: string;
  /** For `oversize`: WHICH limit was exceeded, in bytes. There is more than one
   *  (the 10MB attachment cap and the 5MB PDF text-extract cap), and the
   *  guidance named the wrong one for a 6MB PDF. Rendered, so the agent asks
   *  for something that will actually fit. */
  limitBytes?: number;
  /** The attachment was PARTLY delivered: the agent can see some of it. Only
   *  meaningful with `truncated`. Rendered as its own sentence, because
   *  "did NOT reach you" is a false statement about a document the model is
   *  looking at three pages of. */
  partial?: boolean;
}

/**
 * Mint an `unreadable` record for an attachment we never got far enough to
 * judge. Used for the paths that USED to drop a real attachment with no
 * agent-visible trace at all — the ones that made "no [ATTACHMENT_STATUS]
 * block means every attachment was fine" a false promise.
 */
export function unreadableFromRef(
  ref: { url: string; contentType: string },
  reason: UnreadableReason,
  detail?: string,
): UnreadableAttachment {
  return {
    kind: "unreadable",
    url: ref.url,
    reason,
    declaredContentType: ref.contentType,
    ...(detail ? { detail } : {}),
  };
}

export interface DownloadDeps {
  // Injectable for tests; defaults to global fetch.
  fetchImpl?: typeof fetch;
  // Logging hook — error path is intentionally non-throwing so a single
  // bad attachment doesn't kill the whole turn.
  log?: { warn?: (msg: string) => void; info?: (msg: string) => void };
}

/**
 * What one message's attachment download produced: the entries the agent can
 * actually see, AND every attachment that existed but could not be forwarded.
 *
 * `unreadable` is a RETURN VALUE, deliberately, not an optional callback. It
 * used to be `DownloadDeps.onUnreadable?` — which the unit tests injected and
 * the production caller (channel.ts) never did, so every `heic_decode_failed`
 * was discarded in prod while the suite stayed green. A field on the result
 * cannot be forgotten by a caller: to ignore it you have to destructure it away
 * on purpose, in a diff a reviewer can see.
 */
export interface AttachmentDownloadResult {
  attachments: PersistedAttachment[];
  unreadable: UnreadableAttachment[];
}

// ---------------------------------------------------------------------------
// Magic-byte detection. BYTES BEAT THE HEADER.
//
// Intercom forwards whatever content_type the uploading client declared, and
// clients lie constantly: iOS "share sheet" uploads label re-encoded JPEGs as
// image/heic, browsers label everything image/jpeg, and a hostile client can
// declare image/png over an SVG. Trusting the declared type is what made a
// perfectly readable JPEG invisible to Caroline (the "En Alta" report,
// 2026-08). So we sniff the persisted bytes and let them decide.
// ---------------------------------------------------------------------------

export type DetectedFormat =
  | "png"
  | "jpeg"
  | "gif"
  | "webp"
  | "pdf"
  | "heic"
  | "markup"
  | "unknown";

/**
 * How far into an ISO-BMFF `ftyp` box we scan for compatible brands.
 *
 * The box's declared size is CUSTOMER-CONTROLLED, and the scan walks it four
 * bytes at a time. A 10MB payload declaring a 10MB `ftyp` box with a generic
 * major brand and no accepted compatible brand ran 2.6M subarray/toString
 * iterations — measured at 186ms per attachment, ~1.5s for a full eight — all
 * of it SYNCHRONOUS on the single-threaded gateway, so it stalls unrelated
 * webhook work and repeats on every message.
 *
 * A real `ftyp` box is a few dozen bytes; nothing legitimate needs more. 256
 * matches the shell helper's DETECT_SNIFF_BYTES so the two detectors agree on
 * the same window.
 */
export const MAX_FTYP_SCAN_BYTES = 256;

/** ISO-BMFF `ftyp` brands that mean "this is a HEIF-family still image". */
const HEIF_BRANDS = new Set(["heic", "heix", "heim", "heis", "hevc", "hevx", "heif", "mif1", "msf1"]);

/** Leading markup signatures we REFUSE outright (never sanitize-and-forward). */
const MARKUP_SIGNATURES = ["<?xml", "<svg", "<!doctype html", "<html"];

function startsWithBytes(buf: Buffer, hex: string): boolean {
  const want = Buffer.from(hex, "hex");
  return buf.length >= want.length && buf.subarray(0, want.length).equals(want);
}

/**
 * Classify a downloaded buffer by its magic numbers. Pure, allocation-light,
 * never throws. `unknown` means "no container we recognize" — the caller turns
 * that into an explicit `unreadable` result rather than persisting mystery
 * bytes under a MIME the vision path will choke on.
 */
export function detectImageFormatFromBytes(buf: Buffer): DetectedFormat {
  if (buf.length < 4) return "unknown";
  if (startsWithBytes(buf, "89504e47")) return "png";
  if (startsWithBytes(buf, "ffd8ff")) return "jpeg";
  if (startsWithBytes(buf, "47494638")) return "gif";
  if (startsWithBytes(buf, "25504446")) return "pdf";
  // RIFF....WEBP — the "WEBP" fourCC sits at offset 8, after the RIFF size.
  if (
    buf.length >= 12 &&
    buf.subarray(0, 4).toString("latin1") === "RIFF" &&
    buf.subarray(8, 12).toString("latin1") === "WEBP"
  ) {
    return "webp";
  }
  // ISO-BMFF: [4-byte box size][`ftyp`][4-byte major brand][4-byte minor
  // version][compatible brands…]. Apple writes major brand `heic`, but plenty
  // of encoders write `mif1` major with `heic` in the compatible list — check
  // BOTH or we'd miss half the real-world files.
  if (buf.length >= 12 && buf.subarray(4, 8).toString("latin1") === "ftyp") {
    const declaredBoxSize = buf.readUInt32BE(0);
    // Bounded by the declared size, the buffer, AND a fixed ceiling — the first
    // two are both attacker-influenced, so neither can bound the work.
    const boxEnd = Math.min(
      buf.length,
      declaredBoxSize >= 16 ? declaredBoxSize : buf.length,
      MAX_FTYP_SCAN_BYTES,
    );
    if (HEIF_BRANDS.has(buf.subarray(8, 12).toString("latin1"))) return "heic";
    for (let off = 16; off + 4 <= boxEnd; off += 4) {
      if (HEIF_BRANDS.has(buf.subarray(off, off + 4).toString("latin1"))) return "heic";
    }
  }
  // Markup last: an image container never starts with `<`, and checking it
  // last means a real image can't be misread as markup by coincidence.
  const head = buf.subarray(0, 512).toString("latin1").trimStart().toLowerCase();
  if (MARKUP_SIGNATURES.some((sig) => head.startsWith(sig))) return "markup";
  return "unknown";
}

/** MIME we persist/forward for each format we can hand to the vision path. */
const MIME_FOR_FORMAT: Partial<Record<DetectedFormat, string>> = {
  png: "image/png",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  pdf: "application/pdf",
  heic: "image/heic",
};

function sha256Hex(buf: Buffer): string {
  return crypto.createHash("sha256").update(buf).digest("hex");
}

function extensionForMime(mime: string): string {
  switch (mime.toLowerCase()) {
    case "image/png": return ".png";
    case "image/jpeg":
    case "image/jpg": return ".jpg";
    case "image/gif": return ".gif";
    case "image/webp": return ".webp";
    case "image/heic": return ".heic";
    case "image/heif": return ".heif";
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
 * Fetch `url`, following redirects MANUALLY and re-checking the Intercom CDN
 * host allowlist at every hop.
 *
 * Why manual: `fetch()` follows redirects transparently by default, so the
 * host allowlist enforced at classify time only ever gated the FIRST URL. An
 * allowlisted CDN URL answering `302 Location: http://169.254.169.254/…` (or
 * any attacker-chosen host) was followed without a second look — the allowlist
 * was decorative against anything that could influence a redirect. Every hop
 * now has to be a host we would have accepted in the first place.
 *
 * Returns the final Response, or an UnreadableReason describing the refusal.
 * Never throws for redirect handling; transport errors still reject and are
 * caught by the caller.
 */
async function fetchAllowlisted(
  url: string,
  fetchImpl: typeof fetch,
  signal: AbortSignal,
): Promise<{ ok: true; res: Response } | { ok: false; reason: UnreadableReason; detail: string }> {
  let current = url;
  for (let hop = 0; hop <= MAX_ATTACHMENT_REDIRECT_HOPS; hop++) {
    if (!INTERCOM_CDN_HOST_RE.test(current)) {
      return { ok: false, reason: "redirect_off_allowlist", detail: `hop=${hop} url=${current}` };
    }
    const res = await fetchImpl(current, { signal, redirect: "manual" });
    if (res.status < 300 || res.status > 399) {
      return { ok: true, res };
    }
    const location = res.headers.get("location");
    if (!location) {
      return { ok: false, reason: "fetch_failed", detail: `status=${res.status} with no Location header` };
    }
    let next: string;
    try {
      // Relative Locations are legal; resolve against the CURRENT url so the
      // allowlist check on the next iteration sees a real absolute URL.
      next = new URL(location, current).toString();
    } catch {
      return { ok: false, reason: "redirect_off_allowlist", detail: `unparseable Location=${location}` };
    }
    current = next;
  }
  return {
    ok: false,
    reason: "fetch_failed",
    detail: `exceeded ${MAX_ATTACHMENT_REDIRECT_HOPS} redirect hops`,
  };
}

/**
 * Read a response body into a Buffer, enforcing `cap` WHILE STREAMING.
 *
 * The old code did `Buffer.from(await res.arrayBuffer())` and checked the
 * length afterwards — i.e. it happily buffered a 4GB body into the gateway's
 * heap before deciding it was too big. The cap only ever protected the
 * downstream SDK, never us. We now abort the read the moment the running total
 * crosses the cap, and short-circuit entirely on a `Content-Length` that
 * already declares itself over.
 *
 * Returns `null` when the body exceeds the cap.
 */
async function readBodyCapped(res: Response, cap: number): Promise<Buffer | null> {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > cap) return null;
  const body = res.body;
  if (!body) {
    // No stream (some polyfills / HEAD-like responses). Fall back to the
    // buffered read; the declared-length check above is the only guard we get.
    const buf = Buffer.from(await res.arrayBuffer());
    return buf.length > cap ? null : buf;
  }
  const reader = body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > cap) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    try { reader.releaseLock(); } catch { /* already released by cancel() */ }
  }
  return Buffer.concat(chunks);
}

/**
 * Remove every output the HEIC pipeline is allowed to write for `index` in the
 * persistent per-message dir: the canonical `<index>.jpg` plus any
 * `<index>-N.jpg` auxiliary siblings an EARLIER run left behind. Called before
 * each conversion so a failed (or differently-shaped) run can never leave a
 * previous run's JPEG sitting at a name this pipeline claims.
 */
async function purgeStaleHeicOutputs(destDir: string, index: number): Promise<void> {
  const staleRe = new RegExp(`^${index}(?:-\\d+)?\\.jpg$`);
  let entries: string[];
  try {
    entries = await fs.readdir(destDir);
  } catch {
    return;
  }
  await Promise.all(
    entries
      .filter((name) => staleRe.test(name))
      .map((name) => fs.rm(path.join(destDir, name), { force: true }).catch(() => {})),
  );
}

/**
 * Transcode a HEIC/HEIF file on disk to JPEG via a bounded `heif-convert`
 * subprocess. Returns the JPEG path on success, or `null` on ANY failure
 * (missing binary, malformed input, timeout, empty output). NEVER throws —
 * same contract as rasterizePdfPages.
 *
 * heif-convert's output naming is the trap: for a single-image file it writes
 * exactly the path you asked for, but for a MULTI-image file (every tiled Apple
 * HEIC, and anything carrying depth/alpha auxiliary images) it ignores that and
 * writes `<base>-1.jpg`, `<base>-2.jpg`, … So we cannot predict the name and
 * have to read the output back.
 *
 * WHERE we read it back from is the second trap, and the one that matters for
 * evidence integrity. The per-message media dir is PERSISTENT and DETERMINISTIC
 * (`<root>/intercom/<conv>/<msg>/`), so scanning it after the run mixes this
 * invocation's outputs with every earlier one's: run 1 converts a single-image
 * HEIC and leaves `0.jpg`; run 2 converts a DIFFERENT, multi-image HEIC and
 * produces only `0-1.jpg`/`0-2.jpg` — and a dir scan that prefers the exact
 * `0.jpg` forwards RUN 1's image as run 2's evidence. In a credit-verification
 * evidence path that is cross-customer contamination, not a stale cache.
 *
 * So: purge the names this pipeline owns, convert into a FRESH private
 * directory, consider ONLY what that invocation wrote, move the chosen primary
 * to its canonical place, and drop the rest with the work dir.
 */
type HeicConversion =
  | { ok: true; path: string; size: number }
  | {
      ok: false;
      reason: Extract<UnreadableReason, "heic_decode_failed" | "oversize" | "pipeline_failed">;
      detail?: string;
      limitBytes?: number;
    };

async function convertHeicToJpeg(
  heicPath: string,
  destDir: string,
  index: number,
  deps: DownloadDeps,
): Promise<HeicConversion> {
  await purgeStaleHeicOutputs(destDir, index);
  let workDir: string;
  try {
    // Inside destDir so the later rename is a same-filesystem move, and prefixed
    // with a dot so it can't collide with (or be mistaken for) an output name.
    workDir = await fs.mkdtemp(path.join(destDir, `.heic-${index}-`));
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] could not create heic work dir path=${heicPath} reason=${reason}`,
    );
    return { ok: false, reason: "pipeline_failed", detail: reason };
  }
  try {
    const outBase = "out";
    const outPath = path.join(workDir, `${outBase}.jpg`);
    try {
      await execFileAsync(
        resolveHeifConvertBin(),
        ["-q", String(HEIF_CONVERT_JPEG_QUALITY), heicPath, outPath],
        { timeout: ATTACHMENT_FETCH_TIMEOUT_MS, maxBuffer: 1024 * 1024 },
      );
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      deps.log?.warn?.(
        `[intercom:attachments] heif-convert failed path=${heicPath} reason=${reason}`,
      );
      // Do not flatten these. Two of the three cases are provably OUR fault and
      // one is genuinely ambiguous, and the agent says different things to the
      // customer for each:
      //   ENOENT  — the binary is not installed. Nothing touched the file.
      //   killed  — we hit our own timeout budget. Still nothing about the file.
      //   nonzero — libheif looked at the payload and refused it. That can be a
      //             truncated/corrupt upload OR a codec we cannot handle, and
      //             the code CANNOT tell which, so the guidance must not claim
      //             either. A valid `ftyp` header proves the container, never
      //             the payload.
      const e = err as NodeJS.ErrnoException & { killed?: boolean };
      // Discriminate on WHETHER THE CHILD RAN, not on a list of errnos — an
      // enumeration is a blocklist and this one already missed EACCES (a
      // non-executable binary), ENOEXEC, EPERM, EMFILE… Node makes the
      // distinction exactly: a spawn failure sets `code` to a STRING errno,
      // while a process that actually ran and exited non-zero sets it to the
      // NUMERIC exit status. Only the numeric case means libheif looked at the
      // customer's bytes and refused them.
      if (e?.killed) {
        return { ok: false, reason: "pipeline_failed", detail: `heif-convert timed out (${reason})` };
      }
      if (typeof e?.code === "string") {
        return {
          ok: false,
          reason: "pipeline_failed",
          detail: e.code === "ENOENT"
            ? `heif-convert not installed (${reason})`
            : `heif-convert could not be started: ${e.code} (${reason})`,
        };
      }
      return { ok: false, reason: "heic_decode_failed", detail: reason };
    }
    // Only files THIS invocation wrote are eligible: the work dir was empty a
    // moment ago. Take the exact name we asked for, else the lowest-numbered
    // multi-image sibling.
    let entries: string[];
    try {
      entries = await fs.readdir(workDir);
    } catch (err) {
      return { ok: false, reason: "pipeline_failed", detail: err instanceof Error ? err.message : String(err) };
    }
    const multiRe = new RegExp(`^${outBase}-(\\d+)\\.jpg$`);
    const candidates = entries
      .map((name) => {
        if (name === `${outBase}.jpg`) return { name, order: 0 };
        const m = multiRe.exec(name);
        return m ? { name, order: Number(m[1]) } : null;
      })
      .filter((e): e is { name: string; order: number } => e !== null)
      .sort((a, b) => a.order - b.order);
    if (candidates.length === 0) {
      deps.log?.warn?.(
        `[intercom:attachments] heif-convert produced no output path=${heicPath}`,
      );
      return { ok: false, reason: "heic_decode_failed", detail: "heif-convert produced no output" };
    }
    if (candidates.length > MAX_HEIF_OUTPUT_IMAGES) {
      deps.log?.info?.(
        `[intercom:attachments] heic carried ${candidates.length} images (auxiliary/tiled) — forwarding the primary only path=${heicPath}`,
      );
    }
    const primary = path.join(workDir, candidates[0].name);
    let size: number;
    try {
      size = (await fs.stat(primary)).size;
    } catch (err) {
      return { ok: false, reason: "pipeline_failed", detail: err instanceof Error ? err.message : String(err) };
    }
    // An empty output file is a decoder failure wearing a success exit code.
    if (size === 0) {
      deps.log?.warn?.(
        `[intercom:attachments] heif-convert wrote an empty JPEG path=${primary}`,
      );
      return { ok: false, reason: "heic_decode_failed", detail: "heif-convert wrote an empty JPEG" };
    }
    // NOT a decode failure: heif-convert succeeded and handed us a valid JPEG
    // that is simply too big to forward (a high-resolution iPhone photo can
    // expand past 10MB at quality 90). Reporting this as `heic_decode_failed`
    // sends the agent down the wrong remediation path — it would apologise for
    // a broken transcoder and ask for a JPEG, which can be just as oversized.
    if (size > ATTACHMENT_MAX_BYTES) {
      deps.log?.warn?.(
        `[intercom:attachments] transcoded heic exceeds cap bytes=${size} cap=${ATTACHMENT_MAX_BYTES} path=${primary}`,
      );
      return { ok: false, reason: "oversize", detail: `transcoded bytes=${size} cap=${ATTACHMENT_MAX_BYTES}`, limitBytes: ATTACHMENT_MAX_BYTES };
    }
    // Promote the chosen output to the canonical, predictable name. The
    // auxiliary siblings die with the work dir in the finally below.
    const finalPath = path.join(destDir, `${index}.jpg`);
    try {
      await fs.rename(primary, finalPath);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      deps.log?.warn?.(
        `[intercom:attachments] could not place transcoded jpeg path=${finalPath} reason=${reason}`,
      );
      return { ok: false, reason: "pipeline_failed", detail: reason };
    }
    return { ok: true, path: finalPath, size };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

/**
 * Fetch, sniff, and persist a single image attachment. Returns the persisted
 * entry, an explicit `unreadable` record, or `null` when there was nothing
 * fetchable at all. We NEVER throw from here; one bad image must not sink the
 * message.
 *
 * The declared content-type is evidence, not truth: the persisted MIME comes
 * from the magic bytes. A JPEG declared `image/heic` is persisted and
 * forwarded as a JPEG (no transcode, no loss); genuine HEIC bytes go through
 * `heif-convert`; markup and unrecognized bytes are REFUSED with a reason.
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
): Promise<PersistedAttachment | UnreadableAttachment | null> {
  const declared = ref.contentType;
  const unreadable = (
    reason: UnreadableReason,
    extra?: Partial<UnreadableAttachment>,
  ): UnreadableAttachment => ({
    kind: "unreadable",
    url: ref.url,
    reason,
    declaredContentType: declared,
    ...extra,
  });

  const fetchImpl = deps.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    deps.log?.warn?.(`[intercom:attachments] no fetch available — cannot persist image url=${ref.url}`);
    return unreadable("pipeline_failed", { detail: "no fetch implementation available" });
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ATTACHMENT_FETCH_TIMEOUT_MS);
  let buf: Buffer;
  try {
    const attempt = await fetchAllowlisted(ref.url, fetchImpl, controller.signal);
    if (!attempt.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] refused image reason=${attempt.reason} detail=${attempt.detail} url=${ref.url}`,
      );
      return unreadable(attempt.reason, { detail: attempt.detail });
    }
    const res = attempt.res;
    if (!res.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] CDN fetch failed status=${res.status} url=${ref.url}`,
      );
      return unreadable("fetch_failed", { detail: `status=${res.status}` });
    }
    const capped = await readBodyCapped(res, ATTACHMENT_MAX_BYTES);
    if (capped === null) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized image cap=${ATTACHMENT_MAX_BYTES} url=${ref.url}`,
      );
      return unreadable("oversize");
    }
    buf = capped;
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] fetch/persist threw url=${ref.url} reason=${reason}`,
    );
    return unreadable("fetch_failed", { detail: reason });
  } finally {
    clearTimeout(timer);
  }

  const detected = detectImageFormatFromBytes(buf);

  // SVG/XML/HTML wearing an image content-type. REFUSE — do not sanitize and
  // forward. An SVG is a script-bearing document, not a picture, and the only
  // safe handling of "this claimed to be a PNG and isn't" is to say so.
  if (detected === "markup") {
    deps.log?.warn?.(
      `[intercom:attachments] refused markup masquerading as ${declared} url=${ref.url}`,
    );
    return unreadable("markup_refused", { detectedFormat: detected });
  }
  // Nothing we recognize: truncated upload, corrupt bytes, or a container we
  // have no decoder for. Explicitly unreadable — never persisted under a MIME
  // the vision path would choke on.
  if (detected === "unknown") {
    deps.log?.warn?.(
      `[intercom:attachments] unreadable image bytes declared=${declared} detected=${detected} url=${ref.url}`,
    );
    return unreadable("corrupt_or_unrecognized", { detectedFormat: detected });
  }
  // A PDF that Intercom declared as an image. Bytes beat the header, and we
  // SUPPORT PDFs — calling this corrupt discarded a perfectly good document and
  // told the customer their upload was damaged. It is persisted and forwarded as
  // application/pdf for document-extract. (No rasterized pages: this ref never
  // entered the document pipeline's budget accounting. Text beats nothing.)
  if (detected === "pdf" && buf.length > PDF_TEXT_EXTRACT_MAX_BYTES) {
    // Beyond the extract limit the entry would be silently skipped downstream,
    // which is the vanishing-attachment bug again.
    deps.log?.warn?.(
      `[intercom:attachments] pdf-on-image-route too large for text extraction bytes=${buf.length} cap=${PDF_TEXT_EXTRACT_MAX_BYTES} url=${ref.url}`,
    );
    return unreadable("oversize", { detectedFormat: detected, limitBytes: PDF_TEXT_EXTRACT_MAX_BYTES });
  }

  const sha256 = sha256Hex(buf);
  const bytesMime = MIME_FOR_FORMAT[detected]!;
  if (bytesMime !== declared && !(declared === "image/jpg" && bytesMime === "image/jpeg")) {
    deps.log?.info?.(
      `[intercom:attachments] content-type overridden by bytes declared=${declared} detected=${bytesMime} url=${ref.url}`,
    );
  }

  return persistSniffedImage({ buf, detected, bytesMime, sha256, destDir, index, ref, deps });
}

/**
 * Persist an already-sniffed IMAGE buffer (transcoding HEIC), returning the
 * entry or a typed refusal.
 *
 * Shared by both routes on purpose. `filters` routes on the DECLARED type, so
 * a JPEG can arrive on the document route just as a PDF arrives on the image
 * route — and when this logic lived only in the image path, the document path
 * called those perfectly readable bytes `corrupt_or_unrecognized`. Two copies
 * of "bytes beat the header" is how you end up honouring it in one direction
 * only.
 */
async function persistSniffedImage(params: {
  buf: Buffer;
  detected: DetectedFormat;
  bytesMime: string;
  sha256: string;
  destDir: string;
  index: number;
  ref: { url: string; contentType: string };
  deps: DownloadDeps;
}): Promise<PersistedAttachment | UnreadableAttachment> {
  const { buf, detected, bytesMime, sha256, destDir, index, ref, deps } = params;
  const unreadable = (
    reason: UnreadableReason,
    extra?: Partial<UnreadableAttachment>,
  ): UnreadableAttachment => ({
    kind: "unreadable",
    url: ref.url,
    reason,
    declaredContentType: ref.contentType,
    ...extra,
  });
  const rawPath = path.join(destDir, `${index}${extensionForMime(bytesMime)}`);
  try {
    await fs.writeFile(rawPath, buf);
  } catch (err) {
    // `pipeline_failed`, NOT `fetch_failed`: the download already succeeded —
    // `buf` is in hand and its bytes were sniffed. Only the local write failed
    // (disk full, read-only mount, EISDIR). The distinction is not cosmetic:
    // SOUL.md maps `fetch_failed` to "ask the customer to re-send it" and
    // `pipeline_failed` to "ours, apologize, and flag it for the team", so
    // conflating them makes Caroline blame a customer whose upload was fine for
    // a host problem that re-sending cannot fix.
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(`[intercom:attachments] persist failed url=${ref.url} reason=${reason}`);
    return unreadable("pipeline_failed", { detectedFormat: detected, detail: reason });
  }

  if (detected !== "heic") {
    return { path: rawPath, contentType: bytesMime, url: ref.url, size: buf.length, sha256 };
  }

  // Genuine HEIC/HEIF. No vision model reads it, so transcode or say why not.
  // The original .heic stays on disk either way so a human can inspect it.
  const converted = await convertHeicToJpeg(rawPath, destDir, index, deps);
  if (!converted.ok) {
    // The conversion says WHY it failed; do not flatten every failure into
    // "the decoder failed". `oversize` and `pipeline_failed` need different
    // things from the agent than a genuinely undecodable file does.
    return unreadable(converted.reason, {
      detectedFormat: detected,
      path: rawPath,
      ...(converted.detail ? { detail: converted.detail } : {}),
      ...(converted.limitBytes ? { limitBytes: converted.limitBytes } : {}),
    });
  }
  return {
    path: converted.path,
    contentType: "image/jpeg",
    url: ref.url,
    size: converted.size,
    sha256,
  };
}

/**
 * Download every image in `refs` (up to MAX_IMAGE_ATTACHMENTS_PER_TURN)
 * into `<mediaRoot>/intercom/<convId>/`, in parallel. Returns BOTH the
 * successful persists and the explicit `unreadable` records — see
 * AttachmentDownloadResult for why the latter is a return value and not a
 * callback. Caller is responsible for cleanup — current
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
}): Promise<AttachmentDownloadResult> {
  const deps = params.deps ?? {};
  const limited = params.refs.slice(0, MAX_IMAGE_ATTACHMENTS_PER_TURN);
  // Refs past the cap are not forwarded. They get a `truncated` record rather
  // than only a log line: the agent must not read a partial set as the whole
  // evidence set just because nothing told it otherwise.
  const overflow = params.refs
    .slice(MAX_IMAGE_ATTACHMENTS_PER_TURN)
    .map((ref) => unreadableFromRef(ref, "truncated", `image cap=${MAX_IMAGE_ATTACHMENTS_PER_TURN}`));
  if (overflow.length > 0) {
    deps.log?.warn?.(
      `[intercom:attachments] truncated attachments count=${params.refs.length} cap=${MAX_IMAGE_ATTACHMENTS_PER_TURN} conv=${params.conversationId}`,
    );
  }
  if (limited.length === 0) return { attachments: [], unreadable: overflow };
  const convDir = await ensureConvDir(params.mediaRoot, params.conversationId, params.messageId);
  const results = await Promise.all(
    limited.map((ref, idx) => fetchAndPersistOne(ref, convDir, idx, deps)),
  );

  // Dedupe by SHA-256 of the SOURCE bytes. filters.ts already dedupes by URL,
  // which does not help: the same screenshot pasted twice (or delivered on both
  // the structured and inline branch after a CDN re-sign) arrives under two
  // distinct signed URLs. Forwarding it twice burns a media slot and doubles
  // the vision cost for zero information. Downloads run in parallel, so the
  // dedupe is post-hoc: first occurrence (lowest index) wins, later copies are
  // unlinked so they don't linger on disk.
  const seenHashes = new Set<string>();
  const out: PersistedAttachment[] = [];
  const unreadable: UnreadableAttachment[] = [...overflow];
  for (const entry of results) {
    if (entry === null) continue;
    if ("kind" in entry) {
      unreadable.push(entry);
      continue;
    }
    if (entry.sha256) {
      if (seenHashes.has(entry.sha256)) {
        deps.log?.info?.(
          `[intercom:attachments] deduped identical attachment sha256=${entry.sha256.slice(0, 12)} url=${entry.url}`,
        );
        await fs.rm(entry.path, { force: true }).catch(() => {});
        continue;
      }
      seenHashes.add(entry.sha256);
    }
    out.push(entry);
  }
  return { attachments: out, unreadable };
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
 * Remove the page PNGs this pipeline owns for `index` (`<index>-p-N.png`) in
 * the persistent per-message dir. Same reason as purgeStaleHeicOutputs: the dir
 * survives across runs for the same conversation/message, so a 5-page render
 * followed by a 2-page one would otherwise leave pages 3-5 of the FIRST
 * document sitting in the second document's page list.
 */
async function purgeStalePdfPages(destDir: string, index: number): Promise<void> {
  const staleRe = new RegExp(`^${index}-p-\\d+\\.png$`);
  let entries: string[];
  try {
    entries = await fs.readdir(destDir);
  } catch {
    return;
  }
  await Promise.all(
    entries
      .filter((name) => staleRe.test(name))
      .map((name) => fs.rm(path.join(destDir, name), { force: true }).catch(() => {})),
  );
}

/**
 * Rasterize up to MAX_PDF_PAGES pages of a PDF on disk to PNG files in the
 * per-message directory, named `<index>-p-NN.png` (NN = 1-based page number, as
 * emitted by pdftoppm). Returns the list of written PNG paths in page order,
 * or [] on any failure (missing pdftoppm, malformed PDF, timeout). NEVER
 * throws — a bad PDF must not sink the turn; the original PDF still rides along
 * for text extraction.
 *
 * `index` is the document's slot in the overall attachment ordering, used as a
 * filename prefix so multiple PDFs in one message don't collide.
 *
 * Rendering happens in a FRESH private directory and only that invocation's
 * output is considered — see convertHeicToJpeg for why reading back a
 * persistent, deterministic dir forwards a previous run's bytes as this run's
 * evidence.
 */
async function rasterizePdfPages(
  pdfPath: string,
  destDir: string,
  index: number,
  maxPages: number,
  deps: DownloadDeps,
): Promise<{ pages: string[]; morePages: boolean; lostPages: number }> {
  // Never render more than the caller's remaining budget allows (and never more
  // than MAX_PDF_PAGES). `-l` makes pdftoppm stop at that page, so we don't burn
  // CPU/disk rendering pages we'd only discard downstream.
  const pageLimit = Math.max(0, Math.min(MAX_PDF_PAGES, maxPages));
  if (pageLimit === 0) return { pages: [], morePages: false, lostPages: 0 };
  await purgeStalePdfPages(destDir, index);
  let workDir: string;
  try {
    workDir = await fs.mkdtemp(path.join(destDir, `.pdf-${index}-`));
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] could not create pdf work dir path=${pdfPath} reason=${reason}`,
    );
    return { pages: [], morePages: false, lostPages: 0 };
  }
  try {
    const prefix = path.join(workDir, "p");
    try {
      // pdftoppm emits <prefix>-N.png for each page (N is NOT zero-padded for
      // single-digit page counts, and it only writes pages that actually exist —
      // asking for -l 8 on a 2-page doc yields just 2 files). We therefore read
      // the dir back and sort numerically rather than predicting names.
      await execFileAsync(
        resolvePdftoppmBin(),
        // `-l pageLimit + 1` renders ONE page past what we will keep. If that
        // sentinel comes back, the document continues beyond our cap and the
        // agent must be told it is holding a partial document — pdftoppm only
        // writes pages that exist, so its presence IS the page-count probe. One
        // extra page is cheaper than shelling out to `pdfinfo` for a count, and
        // adds no binary we do not already require. The sentinel is discarded
        // with the work dir.
        ["-png", "-r", String(PDF_RASTER_DPI), "-f", "1", "-l", String(pageLimit + 1), pdfPath, prefix],
        { timeout: ATTACHMENT_FETCH_TIMEOUT_MS, maxBuffer: ATTACHMENT_MAX_BYTES },
      );
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      deps.log?.warn?.(
        `[intercom:attachments] pdftoppm rasterization failed (forwarding original PDF only) path=${pdfPath} reason=${reason}`,
      );
      return { pages: [], morePages: false, lostPages: 0 };
    }
    let entries: string[];
    try {
      entries = await fs.readdir(workDir);
    } catch {
      return { pages: [], morePages: false, lostPages: 0 };
    }
    const pageRe = /^p-(\d+)\.png$/;
    const rendered = entries
      .map((name) => {
        const m = pageRe.exec(name);
        return m ? { name, page: Number(m[1]) } : null;
      })
      .filter((e): e is { name: string; page: number } => e !== null)
      .sort((a, b) => a.page - b.page);
    // The sentinel exists => there is at least one more page than we keep.
    const morePages = rendered.length > pageLimit;
    const keep = rendered.slice(0, pageLimit);
    // Promote each kept page to its canonical name in the persistent dir. A
    // page that can't be moved is dropped rather than reported at a path whose
    // bytes we don't own.
    const pages: string[] = [];
    // Pages we rendered and then could not place. Counted, not swallowed: a
    // dropped page is a hole in the document, and the caller needs it to decide
    // whether what it forwards is the whole thing.
    let lostPages = 0;
    for (const page of keep) {
      const finalPath = path.join(destDir, `${index}-p-${page.page}.png`);
      try {
        await fs.rename(path.join(workDir, page.name), finalPath);
      } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        deps.log?.warn?.(
          `[intercom:attachments] could not place rasterized page path=${finalPath} reason=${reason}`,
        );
        lostPages++;
        continue;
      }
      pages.push(finalPath);
    }
    return { pages, morePages, lostPages };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
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
): Promise<AttachmentDownloadResult> {
  const refused = (
    reason: UnreadableReason,
    detail?: string,
    limitBytes?: number,
  ): AttachmentDownloadResult => ({
    attachments: [],
    unreadable: [{
      kind: "unreadable",
      url: ref.url,
      reason,
      declaredContentType: ref.contentType,
      ...(detail ? { detail } : {}),
      ...(limitBytes ? { limitBytes } : {}),
    }],
  });
  if (budget <= 0) return { attachments: [], unreadable: [] };
  const fetchImpl = deps.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    deps.log?.warn?.(`[intercom:attachments] no fetch available — cannot persist pdf url=${ref.url}`);
    return refused("pipeline_failed", "no fetch implementation available");
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ATTACHMENT_FETCH_TIMEOUT_MS);
  let pdfPath: string;
  let pdfSize: number;
  let persistBuf: Buffer;
  try {
    // Same manual-redirect + streaming-cap hardening as the image path: the
    // CDN host allowlist has to hold at EVERY hop, and the 10MB cap has to bite
    // before the body is in our heap, not after.
    const attempt = await fetchAllowlisted(ref.url, fetchImpl, controller.signal);
    if (!attempt.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] refused pdf reason=${attempt.reason} detail=${attempt.detail} url=${ref.url}`,
      );
      return refused(attempt.reason, attempt.detail);
    }
    const res = attempt.res;
    if (!res.ok) {
      deps.log?.warn?.(
        `[intercom:attachments] CDN fetch failed status=${res.status} url=${ref.url}`,
      );
      return refused("fetch_failed", `status=${res.status}`);
    }
    const buf = await readBodyCapped(res, ATTACHMENT_MAX_BYTES);
    if (buf === null) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized pdf cap=${ATTACHMENT_MAX_BYTES} url=${ref.url}`,
      );
      return refused("oversize", `bytes over cap=${ATTACHMENT_MAX_BYTES}`, ATTACHMENT_MAX_BYTES);
    }
    // BYTES BEAT THE HEADER here too. The image path has sniffed since the
    // "En Alta" report; the document path trusted `application/pdf` and
    // persisted whatever arrived. A 200 carrying an HTML error page or JSON
    // then rode through AS a PDF: pdftoppm refuses it (logged, no record) and
    // the original entry is still appended for document-extract, which silently
    // skips it. Net effect: no pages, no text, and no [ATTACHMENT_STATUS] —
    // which the doctrine reads as "every attachment came through".
    const pdfFormat = detectImageFormatFromBytes(buf);
    // The REVERSE of the PDF-declared-as-image case: `filters` routes on the
    // declared type, so an upload labelled application/pdf can carry perfectly
    // good JPEG/PNG/GIF/WEBP/HEIC bytes. Calling those `corrupt_or_unrecognized`
    // discards readable evidence and tells the customer their file is damaged —
    // the same contradiction of "bytes beat the header", pointed the other way.
    // Persisted through the SHARED image path, so HEIC still transcodes.
    const asImageMime = MIME_FOR_FORMAT[pdfFormat];
    if (pdfFormat !== "pdf" && pdfFormat !== "markup" && pdfFormat !== "unknown" && asImageMime) {
      deps.log?.info?.(
        `[intercom:attachments] document declared=${ref.contentType} is really ${pdfFormat} — forwarding as an image url=${ref.url}`,
      );
      const persisted = await persistSniffedImage({
        buf,
        detected: pdfFormat,
        bytesMime: asImageMime,
        sha256: sha256Hex(buf),
        destDir,
        index,
        ref,
        deps,
      });
      return "kind" in persisted
        ? { attachments: [], unreadable: [persisted] }
        : { attachments: [persisted], unreadable: [] };
    }
    if (pdfFormat !== "pdf") {
      deps.log?.warn?.(
        `[intercom:attachments] refused non-pdf bytes declared=${ref.contentType} detected=${pdfFormat} url=${ref.url}`,
      );
      return {
        attachments: [],
        unreadable: [{
          kind: "unreadable",
          url: ref.url,
          // Markup gets its own reason for the same reason the image path
          // gives it one: an SVG/HTML document is refused, never sanitized.
          reason: pdfFormat === "markup" ? "markup_refused" : "corrupt_or_unrecognized",
          declaredContentType: ref.contentType,
          detectedFormat: pdfFormat,
        }],
      };
    }
    pdfPath = path.join(destDir, `${index}${extensionForMime("application/pdf")}`);
    pdfSize = buf.length;
    persistBuf = buf;
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] pdf fetch threw url=${ref.url} reason=${reason}`,
    );
    return refused("fetch_failed", reason);
  } finally {
    clearTimeout(timer);
  }

  // The write is deliberately OUTSIDE the fetch try. Sharing one catch made a
  // full disk indistinguishable from a dead CDN link, and the two reasons tell
  // the agent opposite things about whose problem it is — see the image path's
  // persist catch for the same split.
  try {
    await fs.writeFile(pdfPath, persistBuf);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    deps.log?.warn?.(
      `[intercom:attachments] pdf persist failed url=${ref.url} reason=${reason}`,
    );
    return refused("pipeline_failed", reason);
  }

  const out: PersistedAttachment[] = [];
  // Rasterized pages first (vision), each capped at ATTACHMENT_MAX_BYTES. Pages
  // get priority for the budget (seeing the doc matters more than its text), so
  // we render at most `budget` of them; pdftoppm's -l avoids rendering the rest.
  const { pages: pagePaths, morePages, lostPages } = await rasterizePdfPages(pdfPath, destDir, index, budget, deps);
  // Pages rendered but not forwarded, for any reason. A hole is a hole whether
  // the page could not be placed on disk or blew the per-attachment size cap;
  // both leave the agent with a document that has pages missing from the middle.
  let droppedPages = lostPages;
  for (const pagePath of pagePaths) {
    let size: number;
    try {
      const stat = await fs.stat(pagePath);
      size = stat.size;
    } catch {
      droppedPages++;
      continue;
    }
    if (size > ATTACHMENT_MAX_BYTES) {
      deps.log?.warn?.(
        `[intercom:attachments] dropped oversized rasterized page bytes=${size} cap=${ATTACHMENT_MAX_BYTES} path=${pagePath}`,
      );
      droppedPages++;
      continue;
    }
    out.push({ path: pagePath, contentType: "image/png", url: ref.url, size });
  }
  // Original PDF last (document-extract text path) — only when (a) there's still
  // budget after the pages and (b) it is within openclaw's text-extract size
  // limit. Beyond the size limit, extraction silently skips it, so forwarding the
  // application/pdf entry is pointless; the rasterized pages above still give the
  // agent vision on the document.
  // Is anything actually MISSING? Filling the budget is not itself a loss: a
  // one-page PDF that exactly consumes `budget = 1` has every page forwarded,
  // `morePages` false and no drops — the agent can see the whole document, and
  // only the (redundant) text route was skipped. Calling that partial would have
  // Caroline asking for a document she is already looking at in full.
  const incomplete = morePages || droppedPages > 0;
  if (out.length >= budget && !incomplete) {
    return { attachments: out, unreadable: [] };
  }
  if (out.length >= budget) {
    // The budget stopped us mid-document: the agent gets the first `budget`
    // pages and NOT the original, so the text route is gone and pages are
    // genuinely absent. Silence here means the model reads 3 pages of a 20-page
    // contract believing it has the whole thing.
    deps.log?.info?.(
      `[intercom:attachments] pdf partially forwarded pages=${out.length} budget=${budget} url=${ref.url}`,
    );
    return {
      attachments: out,
      unreadable: [{
        kind: "unreadable",
        url: ref.url,
        reason: "truncated",
        declaredContentType: ref.contentType,
        detectedFormat: "pdf",
        partial: true,
        detail: `only the first ${out.length} page(s) fit the per-turn media budget; the rest of the document and its text were not forwarded`,
      }],
    };
  }
  // The RASTER cap (MAX_PDF_PAGES) can cut a document short even when the
  // per-turn budget did not: a 20-page PDF renders 8 pages. That is fine while
  // the original still rides along for text — the agent can read the rest — but
  // when the original is withheld for size, the pages ARE the whole delivery and
  // the agent is holding 40% of the document with nothing saying so.
  // `morePages` OR a hole: either way the pages we forward are not the whole
  // document, and with the original withheld for size they are the ONLY
  // delivery — so silence here hands the agent an incomplete document that
  // looks complete.
  if (incomplete && pdfSize > PDF_TEXT_EXTRACT_MAX_BYTES && out.length > 0) {
    deps.log?.info?.(
      `[intercom:attachments] pdf incomplete and too large for text pages=${out.length} dropped=${droppedPages} more=${morePages} cap=${MAX_PDF_PAGES} bytes=${pdfSize} url=${ref.url}`,
    );
    return {
      attachments: out,
      unreadable: [{
        kind: "unreadable",
        url: ref.url,
        reason: "truncated",
        declaredContentType: ref.contentType,
        detectedFormat: "pdf",
        partial: true,
        detail: `${out.length} page(s) forwarded${droppedPages > 0 ? `, ${droppedPages} dropped` : ""}${morePages ? `, more pages exist beyond the ${MAX_PDF_PAGES}-page render cap` : ""}; the document is too large (${pdfSize}b) to forward for text, so the rest is absent`,
      }],
    };
  }
  if (pdfSize <= PDF_TEXT_EXTRACT_MAX_BYTES) {
    out.push({ path: pdfPath, contentType: "application/pdf", url: ref.url, size: pdfSize });
    return { attachments: out, unreadable: [] };
  }
  deps.log?.info?.(
    `[intercom:attachments] pdf too large for text extraction, forwarding rasterized pages only bytes=${pdfSize} cap=${PDF_TEXT_EXTRACT_MAX_BYTES} url=${ref.url}`,
  );
  if (out.length > 0) {
    // Pages carry the document to the vision path; only the text route is lost.
    return { attachments: out, unreadable: [] };
  }
  // Nothing rasterized AND the original is withheld for size: this PDF produced
  // no media at all and, without a record, vanishes. The message-level
  // all-empty fallback does not save it either — a sibling PDF that succeeded
  // keeps the message non-empty, so only THIS attachment disappears.
  //
  // Reported as `oversize` because that is both true and the actionable half:
  // the file is over the text-extract limit, so the right ask is a smaller
  // version or a screenshot. Re-sending the same PDF cannot help, which is what
  // a generic failure reason would have prompted.
  deps.log?.warn?.(
    `[intercom:attachments] pdf produced no usable media (rasterization failed and original withheld for size) bytes=${pdfSize} url=${ref.url}`,
  );
  return {
    attachments: [],
    unreadable: [{
      kind: "unreadable",
      url: ref.url,
      reason: "oversize",
      declaredContentType: ref.contentType,
      detectedFormat: "pdf",
      limitBytes: PDF_TEXT_EXTRACT_MAX_BYTES,
      detail: `bytes=${pdfSize} over text-extract cap=${PDF_TEXT_EXTRACT_MAX_BYTES} and no page could be rasterized`,
    }],
  };
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
}): Promise<AttachmentDownloadResult> {
  const deps = params.deps ?? {};
  const budget = params.budget ?? MAX_MEDIA_ENTRIES_PER_TURN;
  if (params.refs.length === 0) return { attachments: [], unreadable: [] };
  if (budget <= 0) {
    // Images already consumed the whole per-turn budget, so none of these
    // documents are forwarded. Say so instead of returning a silent empty.
    deps.log?.warn?.(
      `[intercom:attachments] no media budget left for ${params.refs.length} document(s) conv=${params.conversationId}`,
    );
    return {
      attachments: [],
      unreadable: params.refs.map((ref) => unreadableFromRef(ref, "truncated", "no media budget left after images")),
    };
  }
  // Attempt cap is independent of the success budget: a flood of failing/oversized
  // refs must not drive unbounded sequential CDN fetches (failures don't consume
  // the budget, so the budget break alone wouldn't stop them).
  const attempts = params.refs.slice(0, MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN);
  const overflow = params.refs
    .slice(MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN)
    .map((ref) => unreadableFromRef(ref, "truncated", `document attempt cap=${MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN}`));
  if (overflow.length > 0) {
    deps.log?.warn?.(
      `[intercom:attachments] truncated documents count=${params.refs.length} cap=${MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN} conv=${params.conversationId}`,
    );
  }
  const convDir = await ensureConvDir(params.mediaRoot, params.conversationId, params.messageId);
  const out: PersistedAttachment[] = [];
  const unreadable: UnreadableAttachment[] = [...overflow];
  let remaining = budget;
  // Sequential so we can stop early: each PDF consumes from `remaining`, and the
  // moment it hits 0 we don't download/rasterize any further PDFs.
  for (let idx = 0; idx < attempts.length; idx++) {
    if (remaining <= 0) {
      deps.log?.warn?.(
        `[intercom:attachments] media budget exhausted, skipping ${attempts.length - idx} remaining document(s) conv=${params.conversationId}`,
      );
      for (const skipped of attempts.slice(idx)) {
        unreadable.push(unreadableFromRef(skipped, "truncated", `media budget=${budget} exhausted`));
      }
      break;
    }
    // Index offset by MAX_IMAGE_ATTACHMENTS_PER_TURN so PDF filenames can't
    // collide with image filenames (0..N images, then N.. for documents).
    const result = await fetchPersistAndRasterizePdf(
      attempts[idx],
      convDir,
      MAX_IMAGE_ATTACHMENTS_PER_TURN + idx,
      remaining,
      deps,
    );
    out.push(...result.attachments);
    unreadable.push(...result.unreadable);
    remaining -= result.attachments.length;
  }
  return { attachments: out, unreadable };
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
): {
  entries: PersistedAttachment[];
  total: number;
  truncated: boolean;
  /** One `truncated` record per CUSTOMER ATTACHMENT the cap withheld — never
   *  one per media entry. They were downloaded fine; the agent simply is not
   *  being shown them, and must be told so rather than left to assume it sees
   *  everything. */
  dropped: UnreadableAttachment[];
} {
  const combined = [...images, ...documents];
  const kept = combined.slice(0, MAX_MEDIA_ENTRIES_PER_TURN);
  const cut = combined.slice(MAX_MEDIA_ENTRIES_PER_TURN);
  // Collapse per SOURCE attachment. One PDF fans out to several
  // PersistedAttachments (a rasterized page each, plus the original), and they
  // all carry the same source `url`. Mapping one record per dropped ENTRY made
  // the block say "6 attachment(s) did NOT reach you" for two PDFs — six lines,
  // several repeating the same URL — so Caroline would ask the customer to
  // re-send four files that never existed. The block promises a count of the
  // customer's ATTACHMENTS; derived entries are our implementation detail.
  const keptUrls = new Set(kept.map((e) => e.url));
  const cutByUrl = new Map<string, PersistedAttachment[]>();
  for (const e of cut) {
    const existing = cutByUrl.get(e.url);
    if (existing) existing.push(e);
    else cutByUrl.set(e.url, [e]);
  }
  const dropped = [...cutByUrl.entries()].map(([url, entries]) => {
    // A document can be PARTIALLY withheld: some pages fit, the rest did not.
    // Say which, so "you are not seeing it" is not overstated for a doc the
    // agent can partly see.
    const partial = keptUrls.has(url);
    const record = unreadableFromRef(
      { url, contentType: entries[0]!.contentType },
      "truncated",
      partial
        ? `per-turn media cap=${MAX_MEDIA_ENTRIES_PER_TURN}; ${entries.length} of this attachment's parts withheld, the rest are shown`
        : `per-turn media cap=${MAX_MEDIA_ENTRIES_PER_TURN}`,
    );
    return partial ? { ...record, partial: true } : record;
  });
  return {
    entries: kept,
    total: combined.length,
    truncated: combined.length > MAX_MEDIA_ENTRIES_PER_TURN,
    dropped,
  };
}

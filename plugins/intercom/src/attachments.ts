import path from "node:path";
import fs from "node:fs/promises";
import type { ImageAttachmentRef } from "./types.js";
import { IMAGE_MIME_ALLOWLIST } from "./filters.js";

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
// dropped with a warn log.
export const ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024;

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
  // Each message gets its own directory keyed by messageId where possible
  // so concurrent webhooks on the same conv don't clobber each other's
  // files. Falls back to a timestamp-only path if no messageId.
  const subdir = sanitizeSegment(params.messageId ?? `${Date.now()}`);
  const convDir = path.join(
    params.mediaRoot,
    "intercom",
    sanitizeSegment(params.conversationId),
    subdir,
  );
  await fs.mkdir(convDir, { recursive: true });
  const results = await Promise.all(
    limited.map((ref, idx) => fetchAndPersistOne(ref, convDir, idx, deps)),
  );
  return results.filter((r): r is PersistedAttachment => r !== null);
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

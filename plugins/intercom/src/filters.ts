import type {
  IntercomWebhookPayload,
  IntercomPartAttachment,
  ClassifiedEvent,
  AssigneeType,
  ImageAttachmentRef,
  DocumentAttachmentRef,
} from "./types.js";
import { MAX_PROCESSED_EVENT_IDS } from "./types.js";

// MIME allowlist for vision forwarding. Audio/video still excluded — they
// need separate handling (transcription for audio) that doesn't fit a single
// content-block path. PDFs are handled via DOCUMENT_MIME_ALLOWLIST below:
// they're page-rasterized to image/png (so vision sees them) AND forwarded as
// the original application/pdf (so openclaw's document-extract reads the text).
export const IMAGE_MIME_ALLOWLIST = new Set<string>([
  "image/png",
  "image/jpeg",
  "image/jpg", // some clients emit jpg, normalize on the way out
  "image/webp",
  "image/gif",
]);

// MIME allowlist for document forwarding. PDF only today. Documents take a
// two-pronged path in attachments.ts: the original bytes are persisted and
// forwarded as application/pdf (consumed by openclaw's bundled document-extract
// plugin, which is keyed on that exact MIME), AND up to MAX_PDF_PAGES pages are
// rasterized to image/png so vision-capable models can visually "see" the PDF
// (incl. scanned docs). The inbound vision path silently drops non-image/* MIMEs
// — verified in openclaw 2026.5.19 (isImageAgentTurnAttachment) — so the
// rasterization is mandatory, not a nicety.
export const DOCUMENT_MIME_ALLOWLIST = new Set<string>([
  "application/pdf",
]);

// Intercom delivers attachments via two paths:
//   1. Structured `attachments[]` on the conversation_part (preferred,
//      carries content_type + signed CDN URL).
//   2. Embedded `<img src="https://downloads.intercomcdn.com/i/o/...">`
//      tags inside the HTML `body` (older clients, some Messenger
//      uploads). Discovered via Intercom community posts — undocumented
//      in the official schema but reliably present.
// We extract from both and dedupe by URL. Either branch may yield zero
// (typical text-only message), one, or many.
// Host allowlist is enforced on BOTH branches (structured and inline) to
// keep the plugin from being coerced into fetching arbitrary URLs if the
// upstream payload is ever malformed or forged. (Clio review of PR #360.)
//
// Intercom serves attachments from TWO host families, BOTH must be allowed:
//   - `*.intercomcdn.{com,io}` — the inline `<img>` body URLs (downloads.intercomcdn.com).
//   - `<workspace>.intercom-attachments-<N>.com` — the STRUCTURED `attachments[].url`
//     host the Messenger widget actually uploads to (e.g. musoai.intercom-attachments-3.com).
//     Confirmed live 2026-06-01 via the Intercom conversations API: a widget image upload's
//     structured attachment is served from this host, NOT intercomcdn. The pre-2026-06-01
//     regex only matched intercomcdn, so every widget upload was silently dropped at the
//     structured branch — the bare `intercom-attachments` family was missing.
export const INTERCOM_CDN_HOST_RE =
  /^https:\/\/(?:[a-z0-9-]+\.)*(?:intercomcdn\.(?:com|io)|intercom-attachments(?:-[0-9]+)?\.com)\//i;
const HTML_IMG_SRC_RE = /<img\b[^>]*\bsrc=(?:"([^"]+)"|'([^']+)')[^>]*>/gi;

function inferContentTypeFromUrl(url: string): string | undefined {
  // Intercom CDN URLs typically end in `.png`, `.jpg`, `.jpeg`, `.gif`,
  // `.webp` (sometimes with query string). Strip query, lowercase ext.
  const pathOnly = url.split("?")[0] ?? "";
  const match = /\.([a-z0-9]+)$/i.exec(pathOnly);
  if (!match) return undefined;
  const ext = match[1].toLowerCase();
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "gif") return "image/gif";
  if (ext === "webp") return "image/webp";
  return undefined;
}

function extractInlineHtmlImageUrls(body: string | undefined): string[] {
  if (!body) return [];
  const urls: string[] = [];
  // Reset lastIndex defensively — module-scope regex with /g state.
  HTML_IMG_SRC_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = HTML_IMG_SRC_RE.exec(body)) !== null) {
    const url = m[1] ?? m[2];
    if (url && INTERCOM_CDN_HOST_RE.test(url)) {
      urls.push(url);
    }
  }
  return urls;
}

export function extractImageAttachments(
  structured: IntercomPartAttachment[] | undefined,
  body: string | undefined,
): ImageAttachmentRef[] {
  const seen = new Set<string>();
  const out: ImageAttachmentRef[] = [];

  for (const att of structured ?? []) {
    if (!att?.url || seen.has(att.url)) continue;
    // CDN host allowlist — parity with the inline `<img>` branch below.
    // Refuses arbitrary URLs even if Intercom's payload claims an
    // allowlisted image content_type.
    if (!INTERCOM_CDN_HOST_RE.test(att.url)) continue;
    const ct = (att.content_type ?? "").toLowerCase();
    if (!IMAGE_MIME_ALLOWLIST.has(ct)) continue;
    seen.add(att.url);
    out.push({
      url: att.url,
      contentType: ct === "image/jpg" ? "image/jpeg" : ct,
      name: att.name,
    });
  }

  for (const url of extractInlineHtmlImageUrls(body)) {
    if (seen.has(url)) continue;
    const inferred = inferContentTypeFromUrl(url);
    if (!inferred || !IMAGE_MIME_ALLOWLIST.has(inferred)) continue;
    seen.add(url);
    out.push({ url, contentType: inferred });
  }

  return out;
}

// Extract document (PDF) attachments from the structured `attachments[]` only.
// Deliberately NO inline-HTML scraping path: Intercom embeds PDFs as a download
// link/attachment, not an `<img>` tag, and we don't want to fetch arbitrary
// hrefs from the body. CDN host allowlist enforced — parity with the image
// branch — so a forged/malformed payload can't coerce us into fetching an
// out-of-band URL even if it claims application/pdf.
export function extractDocumentAttachments(
  structured: IntercomPartAttachment[] | undefined,
): DocumentAttachmentRef[] {
  const seen = new Set<string>();
  const out: DocumentAttachmentRef[] = [];

  for (const att of structured ?? []) {
    if (!att?.url || seen.has(att.url)) continue;
    if (!INTERCOM_CDN_HOST_RE.test(att.url)) continue;
    const ct = (att.content_type ?? "").toLowerCase();
    if (!DOCUMENT_MIME_ALLOWLIST.has(ct)) continue;
    seen.add(att.url);
    out.push({ url: att.url, contentType: ct, name: att.name });
  }

  return out;
}

export function classifyEvent(payload: IntercomWebhookPayload): ClassifiedEvent {
  const { topic, data } = payload;
  const conversation = data.item;
  const conversationId = conversation.id;

  switch (topic) {
    case "conversation.user.created":
    case "conversation.user.replied": {
      const lastPart = conversation.conversation_parts?.conversation_parts?.at(-1);
      const body = lastPart?.body ?? conversation.source?.body ?? "";
      // Structured attachments live on the conversation_part when one exists,
      // OR on `conversation.source` for an image-only new conversation
      // (`user.created` with no caption — no part has been split out yet).
      // Mirror the body fallback chain so we don't drop the very class of
      // message this PR is meant to forward. (Clio review of PR #360.)
      const structuredAttachments =
        lastPart?.attachments ?? conversation.source?.attachments;
      const attachments = extractImageAttachments(structuredAttachments, body);
      const documents = extractDocumentAttachments(structuredAttachments);
      // Allow empty body if at least one image OR document attachment was
      // extracted — a customer can drag-drop an image/PDF with no caption and
      // we still want to forward it. Otherwise treat empty as a malformed event.
      if (!body && attachments.length === 0 && documents.length === 0) {
        return { kind: "unknown", topic: `${topic}:empty_body` };
      }
      const authorId = lastPart?.author?.id ?? conversation.source?.author?.id ?? "";
      const base = { kind: "customer_message" as const, conversationId, body, authorId };
      return {
        ...base,
        ...(attachments.length > 0 ? { attachments } : {}),
        ...(documents.length > 0 ? { documents } : {}),
      };
    }

    case "conversation.admin.replied": {
      const part = conversation.conversation_parts?.conversation_parts?.at(-1);
      return {
        kind: "admin_reply",
        conversationId,
        adminId: part?.author?.id ?? conversation.assignee?.id ?? "",
        adminType: (part?.author?.type ?? conversation.assignee?.type ?? "bot") as AssigneeType,
        messageId: part?.id ?? "",
      };
    }

    case "conversation.admin.assigned":
      return {
        kind: "assigned",
        conversationId,
        assigneeId: conversation.assignee?.id ?? "",
        assigneeType: conversation.assignee?.type ?? "bot",
      };

    case "conversation.admin.closed":
      return { kind: "lifecycle", conversationId, state: "closed" };

    case "conversation.admin.snoozed":
      return { kind: "lifecycle", conversationId, state: "snoozed" };

    case "conversation.admin.opened":
      return { kind: "lifecycle", conversationId, state: "open" };

    case "conversation.admin.noted":
      return { kind: "noted", conversationId };

    default:
      return { kind: "unknown", topic };
  }
}

export function createEventIdSet(processedIds: string[]): Set<string> {
  return new Set(processedIds);
}

export function isEventProcessed(eventId: string, eventIdSet: Set<string>): boolean {
  return eventIdSet.has(eventId);
}

export function trackEventId(eventId: string, processedIds: string[]): void {
  if (processedIds.length >= MAX_PROCESSED_EVENT_IDS) {
    processedIds.shift();
  }
  processedIds.push(eventId);
}

export function isSelfReply(messageId: string, outboundIds: string[]): boolean {
  return outboundIds.includes(messageId);
}

import type {
  IntercomWebhookPayload,
  IntercomPartAttachment,
  ClassifiedEvent,
  AssigneeType,
  ImageAttachmentRef,
  DocumentAttachmentRef,
  UnsupportedAttachmentRef,
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

// MIMEs that are IMAGES but that no vision model can read as-is. They are
// admitted as CANDIDATES here and transcoded to JPEG in attachments.ts
// (bounded `heif-convert` subprocess). Keeping them OUT of
// IMAGE_MIME_ALLOWLIST is deliberate: that set is the "safe to forward
// verbatim" set, and attachments.ts uses it to constrain the server
// Content-Type override. A HEIC must never be forwarded un-transcoded.
//
// Why this exists: every iPhone screenshot/photo shared from an Apple device
// with "High Efficiency" capture arrives as image/heic. Before 2026-08-18 it
// missed the positive allowlist above and hit a SILENT `continue` below — no
// log, nothing surfaced to the agent, so Caroline answered as if the customer
// had sent no image at all.
export const HEIF_MIME_ALLOWLIST = new Set<string>([
  "image/heic",
  "image/heif",
]);

// The set `extractImageAttachments` admits as candidates. Forwardable MIMEs
// plus the transcode-required HEIF family. NOT the set attachments.ts trusts
// for the Content-Type override — bytes decide that (see
// detectImageFormatFromBytes).
export const CANDIDATE_IMAGE_MIME_ALLOWLIST = new Set<string>([
  ...IMAGE_MIME_ALLOWLIST,
  ...HEIF_MIME_ALLOWLIST,
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
  // `.webp`, `.heic`/`.heif` (sometimes with query string). Strip query,
  // lowercase ext.
  const pathOnly = url.split("?")[0] ?? "";
  const match = /\.([a-z0-9]+)$/i.exec(pathOnly);
  if (!match) return undefined;
  const ext = match[1].toLowerCase();
  if (ext === "png") return "image/png";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "gif") return "image/gif";
  if (ext === "webp") return "image/webp";
  if (ext === "heic") return "image/heic";
  if (ext === "heif") return "image/heif";
  // Extensions that name a REAL image we simply cannot forward. They are not in
  // CANDIDATE_IMAGE_MIME_ALLOWLIST, so returning them still refuses the ref —
  // the point is to distinguish "an image arrived and we refuse its type" from
  // "we have no idea what this URL is". Only the first may be reported to the
  // agent as a missing attachment; see extractImageAttachments.
  if (ext === "tif" || ext === "tiff") return "image/tiff";
  if (ext === "bmp") return "image/bmp";
  if (ext === "svg") return "image/svg+xml";
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

/**
 * Logging seam for attachment candidates we refuse. Defaults to
 * `console.warn` (the plugin's established logging route — see config.ts /
 * handoff.ts), overridable for tests.
 */
export interface FilterLog {
  warn?: (msg: string) => void;
}

const defaultFilterLog: FilterLog = { warn: (msg) => console.warn(msg) };

/**
 * What one message's image extraction produced: the refs the download pipeline
 * will fetch, AND every attachment it refused on content-type.
 *
 * `unsupported` is a RETURN VALUE, not a log line, deliberately. The refusal
 * used to be counted-and-`continue`d, which is indistinguishable downstream
 * from "the customer attached nothing", leaving the agent no trace to ask
 * about. A caller can only ignore this half by destructuring it away on
 * purpose, in a diff a reviewer can see.
 */
export interface ExtractedImageAttachments {
  refs: ImageAttachmentRef[];
  /** Delivered, recognised as an attachment, and NOT forwardable. */
  unsupported: UnsupportedAttachmentRef[];
}

export function extractImageAttachments(
  structured: IntercomPartAttachment[] | undefined,
  body: string | undefined,
  log: FilterLog = defaultFilterLog,
): ExtractedImageAttachments {
  const seen = new Set<string>();
  const out: ImageAttachmentRef[] = [];
  const unsupported: UnsupportedAttachmentRef[] = [];
  // Counted, not silent. An unsupported content_type used to hit a bare
  // `continue` here: the customer saw their image upload succeed, Intercom
  // delivered it, and the plugin dropped it leaving ZERO trace anywhere — so
  // the next unsupported type (heic was one for a year) is invisible until a
  // human notices Caroline answering around a screenshot. One aggregated line
  // per message keeps it cheap.
  //
  // Counting alone is not enough: an `image/tiff` that dies here leaves the
  // agent answering from an evidence set it cannot even know is incomplete.
  // So a drop we can attribute to a real customer file is also RETURNED — see
  // `reportable` below for where that line is drawn and why it is not simply
  // "every drop".
  const dropped = new Map<string, number>();
  // `reportable` = we KNOW a customer file arrived here. Every drop is counted
  // for the log (diagnostics); only a reportable one becomes an agent-visible
  // record, because the [ATTACHMENT_STATUS] block is a factual claim that the
  // customer sent something.
  const countDrop = (
    url: string,
    ct: string,
    reportable: boolean,
    reason: UnsupportedAttachmentRef["reason"] = "unsupported_type",
  ) => {
    const key = ct || "(none)";
    dropped.set(key, (dropped.get(key) ?? 0) + 1);
    if (reportable) unsupported.push({ url, contentType: ct, reason });
  };

  for (const att of structured ?? []) {
    if (!att?.url || seen.has(att.url)) continue;
    const ct = (att.content_type ?? "").toLowerCase();
    // CDN host allowlist — parity with the inline `<img>` branch below.
    // Refuses arbitrary URLs even if Intercom's payload claims an
    // allowlisted image content_type.
    //
    // REPORTED, not silently skipped, and checked BEFORE the document split so
    // this one branch covers PDFs too (extractDocumentAttachments skips the same
    // refs silently, so exactly one record is produced). A structured
    // `attachments[]` entry is unambiguously a file the customer sent; dropping
    // it without a record is the doctrine failure again — an HMAC-valid event
    // carrying an upload on a newly introduced CDN host would reach the agent
    // as "nothing was attached".
    if (!INTERCOM_CDN_HOST_RE.test(att.url)) {
      countDrop(att.url, ct, true, "host_not_allowed");
      continue;
    }
    // Documents have their own extractor; don't count them as image drops.
    if (DOCUMENT_MIME_ALLOWLIST.has(ct)) continue;
    if (!CANDIDATE_IMAGE_MIME_ALLOWLIST.has(ct)) {
      // `attachments[]` with a declared content_type is unambiguously a file the
      // customer sent, whatever the type says. Always reported.
      countDrop(att.url, ct, true);
      continue;
    }
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
    if (!inferred || !CANDIDATE_IMAGE_MIME_ALLOWLIST.has(inferred)) {
      // An inline <img> is only reportable when the extension NAMES an image we
      // recognize and refuse (`.tiff`, `.bmp`, `.svg`). With no inferable type
      // we do not know a customer file is involved at all — an extensionless
      // Intercom-hosted <img> can be a signature graphic or a tracking pixel,
      // and telling the agent "1 attachment did NOT reach you" about one would
      // have it apologizing for a file nobody sent. That is the same doctrine
      // failing, pointed the other way. Still counted for the log either way.
      countDrop(url, inferred ?? "", inferred !== undefined);
      continue;
    }
    seen.add(url);
    out.push({ url, contentType: inferred });
  }

  if (dropped.size > 0) {
    const total = [...dropped.values()].reduce((a, b) => a + b, 0);
    const breakdown = [...dropped.entries()]
      .sort((a, b) => (a[0] < b[0] ? -1 : 1))
      .map(([ct, n]) => `${ct}:${n}`)
      .join(",");
    log.warn?.(
      `[intercom:filters] dropped ${total} unsupported image attachment(s) types=${breakdown}`,
    );
  }

  // One record per ATTACHMENT, not per drop site. The same URL can be refused
  // twice — once from `attachments[]` on its declared content_type, once from
  // the inline <img> scrape on its inferred one — and the [ATTACHMENT_STATUS]
  // block is a count the agent reads out loud ("2 attachment(s) did NOT reach
  // you"), so a double entry is a false statement about what the customer sent.
  // A URL that any path DID accept is not reported at all: it reached the agent.
  const reported = new Set<string>();
  const dedupedUnsupported = unsupported.filter((ref) => {
    if (seen.has(ref.url) || reported.has(ref.url)) return false;
    reported.add(ref.url);
    return true;
  });

  return { refs: out, unsupported: dedupedUnsupported };
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

// Intercom author types that are the customer (identified user, anonymous
// lead, or the generic `contact`). Everything else (admin, bot, team) is us.
function isCustomerAuthored(type: string | undefined): boolean {
  return type === "user" || type === "lead" || type === "contact";
}

/**
 * Rewrite every http(s) anchor so its TARGET is visible text.
 *
 * Intercom renders a pasted URL as a preview card:
 *   <a class="intercom-h2b-button" href="https://muso.ai/profile/…">muso.ai</a>
 *   <a class="intercom-content-link" href="https://muso.ai/profile/…"></a>
 * Everything downstream keeps only anchor text, so Caroline read "muso.ai" and
 * asked for the link the customer had just sent — twice in one thread
 * (conv 215476479847680, 2026-10-20). Measured in the edge support sessions:
 * customer messages reduced to a bare "muso.ai" in 29 sessions 10-16..10-20.
 *
 * - text is the URL, or a shortened form of it (host, host/path…) → the URL
 * - empty anchor → the URL
 * - descriptive text ("my profile") → "my profile (URL)"
 * - the same URL again in one message → not repeated
 * - mailto:, tel:, relative links → text unchanged
 *
 * Applied only where the agent's text is built (channel.ts buildAgentRawBody).
 * classifyEvent keeps `body` exactly as Intercom sent it: handler.ts matches the
 * current message against live conversation parts by tag-stripped body, and
 * attachment extraction reads the raw HTML.
 */
export function surfaceLinkTargets(html: string): string {
  if (!html || !/<a\b/i.test(html)) return html;
  const seen = new Set<string>();
  const bare = (u: string) => u.replace(/^https?:\/\//i, "").replace(/^www\./i, "").replace(/[\s/…\.]+$/u, "");
  return html.replace(
    /<a\b[^>]*?\bhref\s*=\s*(["'])(.*?)\1[^>]*>([\s\S]*?)<\/a>/gi,
    (_m: string, _q: string, href: string, inner: string) => {
      const url = href.replace(/&amp;/g, "&").trim();
      const text = inner.replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").trim();
      if (!/^https?:\/\//i.test(url)) return inner;
      const shortened = text.length === 0 || bare(url).toLowerCase().startsWith(bare(text).toLowerCase());
      if (seen.has(url)) return shortened ? "" : text;
      seen.add(url);
      return shortened ? ` ${url} ` : `${text} (${url})`;
    },
  );
}

export function classifyEvent(
  payload: IntercomWebhookPayload,
  log: FilterLog = defaultFilterLog,
): ClassifiedEvent {
  const { topic, data } = payload;
  const conversation = data.item;
  const conversationId = conversation.id;

  switch (topic) {
    case "conversation.user.created":
    case "conversation.user.replied": {
      // The message is the latest CUSTOMER-authored part, never a system/bot
      // part. By the time Intercom fires `user.created`, it has usually
      // already appended bot parts to the payload (conversation_attribute_
      // updated_by_admin, default_assignment, language_detection_details,
      // company_updated), each with `attachments: []` and no body. Taking
      // `.at(-1)` blindly made that empty array win over
      // `source.attachments`, so EVERY opening-message image was dropped
      // and Caroline answered "I can't see the image" (measured 2026-10-17:
      // 4 of 4 customer openers with an image, 2 of them paying). With no
      // customer part yet, the opening message (`source`) is the message.
      const parts = conversation.conversation_parts?.conversation_parts ?? [];
      const customerPart = [...parts].reverse().find((p) => isCustomerAuthored(p?.author?.type));
      const lastPart =
        customerPart ?? (topic === "conversation.user.created" ? undefined : parts.at(-1));
      const body = lastPart?.body ?? conversation.source?.body ?? "";
      // Structured attachments live on the conversation_part when one exists,
      // OR on `conversation.source` for an image-only new conversation
      // (`user.created` with no caption — no part has been split out yet).
      // Mirror the body fallback chain so we don't drop the very class of
      // message this PR is meant to forward. (Clio review of PR #360.)
      const structuredAttachments =
        lastPart?.attachments ?? conversation.source?.attachments;
      const { refs: attachments, unsupported: unsupportedAttachments } =
        extractImageAttachments(structuredAttachments, body, log);
      const documents = extractDocumentAttachments(structuredAttachments);
      // Allow empty body if at least one image OR document attachment was
      // extracted — a customer can drag-drop an image/PDF with no caption and
      // we still want to forward it. Otherwise treat empty as a malformed event.
      // An unsupported attachment still counts as "the customer sent
      // something": treating it as an empty body would drop the whole message
      // and the agent would never learn anything arrived.
      if (
        !body &&
        attachments.length === 0 &&
        documents.length === 0 &&
        unsupportedAttachments.length === 0
      ) {
        return { kind: "unknown", topic: `${topic}:empty_body` };
      }
      const partAuthor = lastPart?.author;
      const sourceAuthor = conversation.source?.author;
      const msgAuthor = partAuthor ?? sourceAuthor;
      const authorId = msgAuthor?.id ?? "";
      // Verified contact identity for personalization: trust ONLY a
      // `type: "user"` author (an Intercom identity-verified contact). Prefer
      // the canonical conversation creator (`source.author`); fall back to the
      // replying part's author. Never derive identity from the message body.
      const userAuthor =
        (sourceAuthor?.type === "user" ? sourceAuthor : undefined) ??
        (partAuthor?.type === "user" ? partAuthor : undefined);
      const verifiedEmail = userAuthor?.email?.trim().toLowerCase() || undefined;
      const verifiedName = userAuthor?.name?.trim() || undefined;
      const base = { kind: "customer_message" as const, conversationId, body, authorId };
      return {
        ...base,
        ...(msgAuthor?.type ? { authorType: msgAuthor.type } : {}),
        ...(verifiedEmail ? { verifiedEmail } : {}),
        ...(verifiedName ? { verifiedName } : {}),
        ...(attachments.length > 0 ? { attachments } : {}),
        ...(documents.length > 0 ? { documents } : {}),
        ...(unsupportedAttachments.length > 0 ? { unsupportedAttachments } : {}),
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

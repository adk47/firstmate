import type {
  IntercomWebhookPayload,
  IntercomConversation,
  IntercomConversationPart,
  IntercomPartAttachment,
  ClassifiedEvent,
  AssigneeType,
  ImageAttachmentRef,
  DocumentAttachmentRef,
  UnsupportedAttachmentRef,
  HandbackContext,
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
 * Whether the newest message a reader can see is the customer's, i.e. their message is the one
 * nobody has answered yet. Used when a conversation is handed back to Caroline: a thread the
 * customer spoke last in needs a reply now, not on their next message.
 *
 * Only a customer-visible `comment` part is a message. A close, a note, an assignment or a
 * snooze answers nobody, so the drain's own assignment + note parts do not count as our reply.
 */
export function customerSpokeLast(conversation: IntercomConversation): boolean {
  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  const lastAuthored = [...parts]
    .reverse()
    .find(
      (p) =>
        p?.part_type === "comment" &&
        Boolean(p?.author?.type) &&
        (isCustomerAuthored(p.author?.type) || Boolean(String(p.body ?? "").replace(/<[^>]*>/g, "").trim())),
    );
  return isCustomerAuthored((lastAuthored?.author ?? conversation.source?.author)?.type);
}

/**
 * True when the newest comment on the thread is by ANY admin on our side.
 *
 * Only used for a `followup=1` hand-back: those threads are the ones where our reply is the last
 * comment, so `customerSpokeLast` is false by construction and the ordinary gate would refuse the
 * one follow-up that is owed (caroline-unanswered-drain-u1, handback-fields-20261115.md).
 *
 * ANY admin, not only this bot. On about 378 of the queued threads the newest comment is the OLD
 * WORKSPACE BOT's (admin 4359478) or a person's, because we never wrote on them today; requiring
 * `botAdminId` refused every one of them and would have blocked most of the queue
 * (caroline-unanswered-drain-u1, 2026-11-15 16:59Z). This matches `promiseFromThread`, which
 * already reads any admin's comment for the same reason: a promise WE made is a promise the
 * account made, whoever on this side typed it.
 */
export function weSpokeLast(conversation: IntercomConversation, _botAdminId?: string): boolean {
  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  const last = [...parts]
    .reverse()
    .find(
      (p) =>
        p?.part_type === "comment" &&
        Boolean(p?.author?.type) &&
        (isCustomerAuthored(p.author?.type) || Boolean(String(p.body ?? "").replace(/<[^>]*>/g, "").trim())),
    );
  return last?.author?.type === "admin";
}

/**
 * The drain's stale-close line, which on the reopened threads is the newest comment and is WRONG.
 *
 * The drain closed these threads saying "your last message here was answered", when the truth is
 * that nobody answered it. It reopened them at 16:17Z with no message, so the wrong line is still
 * the last thing on the thread. The turn has to know that line was ours and that it was wrong,
 * otherwise it reads its own bad close as the state of the world
 * (caroline-unanswered-drain-u1, 2026-11-15 16:59Z).
 *
 * Matched on the drain's own fixed copy (`scripts/intercom-backlog/drain.py`, `stale-close`), not
 * on a paraphrase: if that copy changes, this stops matching and the block simply omits the line
 * rather than asserting something it cannot see.
 */
const STALE_CLOSE_LINE =
  /your last message here was answered and the conversation has been quiet since, so we are closing it/i;

/** True when the newest admin comment is the drain's stale-close line. */
export function lastWordWasWrongClose(conversation: IntercomConversation): boolean {
  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  const last = [...parts]
    .reverse()
    .find(
      (p) =>
        p?.part_type === "comment" &&
        Boolean(p?.author?.type) &&
        (isCustomerAuthored(p.author?.type) || Boolean(String(p.body ?? "").replace(/<[^>]*>/g, "").trim())),
    );
  if (last?.author?.type !== "admin") return false;
  return STALE_CLOSE_LINE.test(String(last?.body ?? "").replace(/<[^>]*>/g, " "));
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

/**
 * The drain's hand-back marker (scripts/intercom-backlog/drain.py HANDBACK_MARKER). One string in each
 * language, and no test compares the two copies: change both, or a hand-back note stops being read.
 */
export const HANDBACK_MARKER = "hydra-handback:";

/**
 * Prefix of the synthetic webhook id the hand-back dispatch re-enters `handleWebhookEvent`
 * with. It marks the turn as the hand-back turn, so the context is not retired on it.
 */
export const HANDBACK_DISPATCH_PREFIX = "handback:";

/**
 * The reason code a hand-back note carries, or "" when this part is not one.
 *
 * The note must be authored by this workspace's bot admin: a note a person writes that happens to quote
 * the marker never hands the thread back. `scripts/intercom-ops-write.sh note` puts its own
 * "Note to <audience> ..." header line above the body it is given, so the marker starts a LINE of the
 * stored body rather than the body itself.
 */
export function handbackNoteReason(part: IntercomConversationPart | undefined, botAdminId: string): string {
  if (!part || part.part_type !== "note") return "";
  if (part.author?.type !== "admin" || String(part.author?.id ?? "") !== botAdminId) return "";
  const lines = String(part.body ?? "")
    .replace(/<[^>]*>/g, "\n")
    .split("\n")
    .map((line) => line.trim());
  const marker = lines.find((line) => line.startsWith(HANDBACK_MARKER));
  if (!marker) return "";
  const reason = /reason=([A-Za-z0-9_.-]+)/.exec(marker);
  return reason ? reason[1] : "";
}


/**
 * The context a hand-back note carries, or null when this part is not one (or carries none).
 *
 * The marker line is ONE rule in two languages: `scripts/intercom-backlog/drain.py handback_note`
 * writes it and this reads it, and both copies change together. Two versions exist:
 *
 *   v1  hydra-handback: reason=<code> class=<words>
 *   v2  hydra-handback: v=2 reason=<code> kind=<kind> promised_at=<epoch> waiting_since=<epoch> followup=<0|1> class=<words>
 *
 * `class` is last and may hold spaces; every other value is `[A-Za-z0-9_.-]+`. A note with no `v=`
 * field is v1 and must keep working, because every note already on a thread is v1.
 *
 * The promise itself is NOT in the note: it is on the thread, in the comment we posted at
 * `promised_at`, and `promiseFromThread` takes it from there. Carrying a copy in the note would let
 * the two drift, and the thread is the thing the customer can see.
 */
export function handbackNoteContext(
  part: IntercomConversationPart | undefined,
  botAdminId: string,
): HandbackContext | null {
  if (!part || part.part_type !== "note") return null;
  if (part.author?.type !== "admin" || String(part.author?.id ?? "") !== botAdminId) return null;
  const lines = String(part.body ?? "")
    .replace(/<[^>]*>/g, "\n")
    .split("\n")
    .map((line) => line.trim());
  const marker = lines.find((line) => line.startsWith(HANDBACK_MARKER));
  if (!marker) return null;
  const rest = marker.slice(HANDBACK_MARKER.length).trim();
  // `class=` is last and may hold spaces, so it is split off before the token scan.
  const classAt = rest.search(/(?:^|\s)class=/);
  const head = classAt >= 0 ? rest.slice(0, classAt) : rest;
  const klass = classAt >= 0 ? rest.slice(classAt).replace(/^\s*class=/, "").trim() : "";
  const fields: Record<string, string> = {};
  for (const token of head.split(/\s+/)) {
    const eq = token.indexOf("=");
    if (eq > 0) fields[token.slice(0, eq)] = token.slice(eq + 1);
  }
  const reason = fields.reason ?? "";
  if (!reason) return null;
  const epoch = (raw: string | undefined): number => {
    const n = Number(raw);
    return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
  };
  return {
    version: fields.v === "2" ? 2 : 1,
    reason,
    kind: fields.kind && fields.kind !== "-" ? fields.kind : "",
    promisedAt: epoch(fields.promised_at),
    waitingSince: epoch(fields.waiting_since),
    followup: fields.followup === "1",
    klass,
    promisedBy: fields.promised_by ?? "",
    askedAboutRequest: false,
    promise: "",
    ask: "",
    need: fields.need && fields.need !== "-" ? fields.need : "",
    wrongClose: false,
  };
}

/** The words a customer uses when they are asking about one of their own requests. */
const REQUEST_ASK = /\b(request|requests|credit|credits|claim|claimed|merge|merged|ticket|tickets|verify|verified|verification|document|documents|proof|review|status|application|appeal|export|deletion|delete my account|gdpr)\b/i;

/**
 * The customer comments the hand-back is actually answering: everything after our last reply.
 *
 * A thread can carry several topics over months. Reading every customer comment ever written lets
 * an old credit question authorise a queue line about a message that is about something else
 * entirely (QA 2026-11-15, filters.ts:530). The hand-back answers the UNANSWERED message, so only
 * that message's words may authorise anything.
 *
 * When we never replied, every customer comment is unanswered and all of them count.
 */
export function unansweredCustomerParts(
  parts: readonly IntercomConversationPart[] | undefined,
): IntercomConversationPart[] {
  const all = parts ?? [];
  let lastAdmin = -1;
  for (let i = 0; i < all.length; i += 1) {
    const p = all[i];
    if (p?.part_type === "comment" && p?.author?.type === "admin") lastAdmin = i;
  }
  return all
    .slice(lastAdmin + 1)
    .filter((p) => p?.part_type === "comment" && isCustomerAuthored(p?.author?.type));
}

/**
 * True when the customer asked about one of their own requests in the message we are answering.
 *
 * Used for ONE thing: the verification-queue status line is only truthful when the customer asked
 * about a request. It is read from the customer's own words, never from the promise kind, because
 * "we promised a merge" does not mean the customer asked about the merge today.
 *
 * Scoped to the unanswered message(s) — see `unansweredCustomerParts`. A broad word in a message we
 * already answered is not a question we are being asked now.
 */
export function customerAskedAboutRequest(
  parts: readonly IntercomConversationPart[] | undefined,
): boolean {
  for (const p of unansweredCustomerParts(parts)) {
    const text = String(p?.body ?? "").replace(/<[^>]*>/g, " ");
    if (REQUEST_ASK.test(text)) return true;
  }
  return false;
}

/**
 * The promise in our own words, taken from the thread rather than from the note.
 *
 * The monitor derives `promised_at` from the thread's own parts, so the comment we posted at that
 * time IS the promise. When no part has exactly that time, the newest comment of ours at or before
 * the customer's last message is the best available answer, and when there is none the block says
 * so rather than inventing one.
 */
export function promiseFromThread(
  parts: readonly IntercomConversationPart[] | undefined,
  botAdminId: string,
  promisedAt: number,
  waitingSince: number,
): string {
  // ANY admin's comment counts, not only this bot's. 275 of the threads the drain is about to
  // hand back carry a promise from an OLD BOT (or from a human agent) whose admin id is not
  // `botAdminId`; filtering on our own id found nothing on them and the block would have said
  // "no promise on file" about a thread that plainly has one. A promise WE made is a promise
  // the account made, whoever on this side typed it.
  //
  // Caroline's own comment still wins when there is a choice, because the monitor derives
  // `promised_at` from the thread and a same-second tie should resolve to the bot.
  const ours = (parts ?? [])
    .filter(
      (p) =>
        p?.part_type === "comment" &&
        p?.author?.type === "admin" &&
        String(p?.body ?? "").replace(/<[^>]*>/g, "").trim().length > 0,
    )
    .map((p) => ({
      at: Number(p.created_at ?? 0),
      isBot: String(p.author?.id ?? "") === botAdminId,
      text: String(p.body ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim(),
    }))
    .sort((a, b) => a.at - b.at);
  type Our = (typeof ours)[number];
  const atOrBefore = (limit: number): Our | undefined => {
    if (!limit) return undefined;
    let found: Our | undefined;
    for (const part of ours) if (part.at <= limit) found = part;
    return found;
  };
  // An exact `promised_at` hit is the promise itself, so prefer it to a later one from a
  // different author; `botAdminId` breaks ties within the same second.
  const exact = (limit: number): Our | undefined => {
    if (!limit) return undefined;
    const hits = ours.filter((p) => p.at === limit);
    return hits.find((p) => p.isBot) ?? hits[0];
  };
  // NO last-resort fallback to the newest comment. On a follow-up thread the newest admin comment
  // is the hand-back reply that did not answer ("Anytime!"), and quoting it as the promise we made
  // presents the misfire as the original commitment (QA 2026-11-15, filters.ts:511). When nothing
  // qualifies at or before the customer's last message there is no promise to quote, and the block
  // says so rather than inventing one.
  const chosen = exact(promisedAt) ?? atOrBefore(promisedAt) ?? exact(waitingSince) ?? atOrBefore(waitingSince);
  if (!chosen) return "";
  return chosen.text.length > 400 ? chosen.text.slice(0, 397) + "..." : chosen.text;
}

/**
 * The time of the customer's newest comment, or 0 when they never wrote.
 *
 * A v1 hand-back note carries no `waiting_since`, so `promiseFromThread` had no cutoff and
 * returned nothing - and the block then said "No promise is open" about a thread the note says
 * has one (QA 2026-11-15, filters.ts:825). The customer's own last message is the safe cutoff:
 * anything we said before it is a candidate promise, anything after it is our reply to them.
 */
export function customerLastSpokeAt(conversation: IntercomConversation): number {
  const parts = conversation.conversation_parts?.conversation_parts ?? [];
  let newest = 0;
  for (const p of parts) {
    if (p?.part_type !== "comment" || !isCustomerAuthored(p?.author?.type)) continue;
    const at = Number(p.created_at ?? 0);
    if (at > newest) newest = at;
  }
  return newest;
}

/**
 * The proof-ask we sent, taken from the thread rather than from the note.
 *
 * 18 of 19 replies to a proof ask were WORDS: the customer wrote back instead of attaching
 * anything, and nothing read what they said (firstmate 2026-11-15 16:38Z). The ask is our last
 * comment before the customer's reply, so the turn can answer their question and re-state the one
 * item still needed instead of asking again from scratch.
 *
 * Returns "" when we never wrote before they did, so the block says so rather than inventing an ask.
 */
export function askFromThread(
  parts: readonly IntercomConversationPart[] | undefined,
  botAdminId: string,
  waitingSince: number,
): string {
  const all = (parts ?? [])
    .filter((p) => p?.part_type === "comment")
    .map((p) => ({
      at: Number(p.created_at ?? 0),
      isAdmin: p?.author?.type === "admin",
      isBot: String(p?.author?.id ?? "") === botAdminId,
      text: String(p?.body ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim(),
    }))
    .filter((p) => p.text.length > 0)
    .sort((a, b) => a.at - b.at);
  // The customer's last word is the reply we are answering; the ask is the newest admin comment
  // before it. `waitingSince` is that reply's time, so "before" is the whole predicate.
  const limit = waitingSince > 0 ? waitingSince : Number.POSITIVE_INFINITY;
  const before = all.filter((p) => p.isAdmin && p.at < limit);
  if (before.length === 0) return "";
  // The NEWEST admin comment wins, whoever wrote it. Preferring the bot's older ask over a later
  // human admin's ask quoted the wrong proof request: if Caroline asked for document A and a human
  // then asked for link B, the block told the turn to chase A (QA 2026-11-15, filters.ts:628).
  // Bot identity only breaks a same-second tie, where "newest" cannot decide.
  const newestAt = before[before.length - 1].at;
  const tied = before.filter((p) => p.at === newestAt);
  const chosen = tied.find((p) => p.isBot) ?? tied[tied.length - 1];
  return chosen.text.length > 400 ? chosen.text.slice(0, 397) + "..." : chosen.text;
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

/**
 * The [HAND_BACK] block: what Caroline is actually being asked to do.
 *
 * firstmate 2026-11-15 15:03Z: the drain's first ten live hand-backs reached her as a fresh
 * customer message, and she answered "Anytime!" / "You are welcome" to people who had been waiting
 * months on an open promise. The note carried a reason code and nothing else, so the only thing in
 * her turn was the customer's last word — which, on a thread we went quiet on, is usually "thanks".
 *
 * Code-authored from the note the drain posted, never from customer text, and it sits directly
 * above [CUSTOMER_MESSAGE] so it reads as "…and here is what this message actually is".
 */
/**
 * The hand-back reasons that mean a promise is open, whatever the note could tell us about it.
 *
 * `owner_recent` is included: the drain posts it when the owner is recent, which is still an open
 * item on our side. `specific_ask` is an ask we sent, which is also owed an answer.
 */
const PROMISE_BEARING_REASONS = new Set(["open_promise", "specific_ask", "owner_recent", "old_bot_promise"]);

export function renderHandbackBlock(ctx: HandbackContext | null | undefined, nowSeconds?: number): string {
  if (!ctx) return "";
  const now = nowSeconds ?? Math.floor(Date.now() / 1000);
  const waitedDays = ctx.waitingSince > 0 ? Math.max(0, Math.floor((now - ctx.waitingSince) / 86400)) : 0;
  const waited = waitedDays > 0 ? `${waitedDays} day${waitedDays === 1 ? "" : "s"}` : "some time";
  const made = ctx.promisedAt > 0 ? new Date(ctx.promisedAt * 1000).toISOString().slice(0, 10) : "";
  const lines = [
    "[HAND_BACK]",
    "This conversation was handed back to you by the backlog drain. It is NOT a new message: the customer last wrote " +
      waited +
      " ago and nobody came back to them.",
  ];
  if (ctx.wrongClose) {
    // The drain closed these threads saying the customer's message had been answered. It had not.
    // The wrong line is still the newest comment, so the turn must be told it was ours and wrong.
    lines.push(
      "The last message on this thread is OUR close note saying their message was answered. That was wrong: nobody answered it. Do not repeat it, and do not treat it as the state of the thread.",
    );
  }
  if (ctx.promisedBy === "operator_bot") {
    // The old workspace bot made these promises in April to June. The customer may not
    // remember the thread at all, and saying "we" as though it were yesterday is a lie about
    // how long this has been open.
    lines.push(
      "This promise was made by an earlier version of this support bot, months ago. Say what was promised and when, in one sentence, and do not pretend it was recent.",
    );
    lines.push(
      "Nobody picked it up. If that is still true, say so plainly. Do not say it was answered.",
    );
  }
  if (ctx.kind === "ask_reply_words") {
    // 18 of 19 replies to a proof ask were words, not an attachment, and nothing read them
    // (firstmate 2026-11-15 16:38Z). The customer answered the ask in prose; the turn has to
    // answer what they asked and re-state the ONE item still needed, not send the ask again.
    if (ctx.ask) {
      lines.push(`The proof ask we sent${made ? ` (on ${made})` : ""}: "${ctx.ask}"`);
    } else {
      lines.push("We sent a proof ask and its text was not found on the thread. Do not quote it.");
    }
    lines.push(
      "The customer replied in WORDS, not with an attachment. Read what they wrote and answer the question they actually asked.",
      ctx.need
        ? `Then re-state the one item still needed (need code: ${ctx.need}) in the approved status-template wording. Do not ask for anything else.`
        : "Then re-state the one item still needed in the approved status-template wording. Do not ask for anything else.",
      "Do not send the ask again as though they had not replied, and do not say their reply was received as a document.",
    );
  } else if (ctx.promise) {
    lines.push(`What we said we would do${made ? ` (on ${made})` : ""}: "${ctx.promise}"`);
    lines.push("It was not done, or not reported. Say where it stands now.");
  } else if (ctx.kind) {
    lines.push(`We owe them a ${ctx.kind} answer and no promise text was found on the thread. Say where it stands now.`);
  } else if (PROMISE_BEARING_REASONS.has(ctx.reason)) {
    // The note says a promise is open but its text could not be found - a v1 note carries no
    // timestamps, so there was nothing to look it up by. Saying "no promise is open" here would
    // contradict the note and drop the follow-up that is owed (QA 2026-11-15, filters.ts:825).
    lines.push(
      "A promise IS open on this thread, but its text could not be found. Do not say there is no open promise, and do not invent what we said. Say where the thing stands now.",
    );
  } else {
    lines.push("No promise is open on this thread. Answer what they actually asked.");
  }
  lines.push(
    "Do not reply with thanks, do not greet them as if this were new, and do not ask what they need when the thread already says it.",
    "State where the thing stands from a read you make in this turn. What you could not read is said as not confirmed, never as fine. Say what, if anything, is needed from them.",
    ctx.askedAboutRequest
      ? "The customer asked about one of their own requests, so you may say where that request stands."
      : "The customer did NOT ask about a request. Do not say their request is in the verification queue, or that anything is in a queue.",
    "No person, no date, no follow-up you cannot keep. One message.",
    "[/HAND_BACK]",
  );
  return lines.join("\n");
}

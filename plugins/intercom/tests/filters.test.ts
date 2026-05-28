import { describe, it, expect } from "vitest";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply, extractImageAttachments, extractDocumentAttachments } from "../src/filters.js";
import type { IntercomWebhookPayload, IntercomPartAttachment } from "../src/types.js";
import userCreated from "./fixtures/conversation-user-created.json";
import userReplied from "./fixtures/conversation-user-replied.json";
import adminReplied from "./fixtures/conversation-admin-replied.json";
import assigned from "./fixtures/conversation-assigned.json";
import closed from "./fixtures/conversation-closed.json";

describe("classifyEvent", () => {
  it("classifies conversation.user.created as customer_message", () => {
    const result = classifyEvent(userCreated as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.conversationId).toBe("conv_123");
      expect(result.body).toBe("Hi, I need help with my account");
    }
  });

  it("classifies conversation.user.replied as customer_message", () => {
    const result = classifyEvent(userReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
  });

  it("classifies conversation.admin.replied as admin_reply with type", () => {
    const result = classifyEvent(adminReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("admin_reply");
    if (result.kind === "admin_reply") {
      expect(result.adminId).toBe("admin_42");
      expect(result.adminType).toBe("admin");
      expect(result.messageId).toBe("part_1");
    }
  });

  it("classifies conversation.admin.assigned as assigned with type", () => {
    const result = classifyEvent(assigned as IntercomWebhookPayload);
    expect(result.kind).toBe("assigned");
    if (result.kind === "assigned") {
      expect(result.assigneeId).toBe("admin_99");
      expect(result.assigneeType).toBe("admin");
    }
  });

  it("extracts bot assignee type from assignment payload", () => {
    const botAssigned = {
      ...assigned,
      data: {
        ...assigned.data,
        item: {
          ...assigned.data.item,
          assignee: { type: "bot", id: "4359478", name: "Operator" },
        },
      },
    };
    const result = classifyEvent(botAssigned as IntercomWebhookPayload);
    expect(result.kind).toBe("assigned");
    if (result.kind === "assigned") {
      expect(result.assigneeType).toBe("bot");
    }
  });

  it("extracts bot admin type from admin reply payload", () => {
    const botReplied = {
      ...adminReplied,
      data: {
        ...adminReplied.data,
        item: {
          ...adminReplied.data.item,
          conversation_parts: {
            conversation_parts: [{
              ...adminReplied.data.item.conversation_parts.conversation_parts[0],
              author: { type: "bot", id: "4359478", name: "Operator" },
            }],
          },
        },
      },
    };
    const result = classifyEvent(botReplied as IntercomWebhookPayload);
    expect(result.kind).toBe("admin_reply");
    if (result.kind === "admin_reply") {
      expect(result.adminType).toBe("bot");
    }
  });

  it("classifies conversation.admin.closed as lifecycle/closed", () => {
    const result = classifyEvent(closed as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") {
      expect(result.state).toBe("closed");
    }
  });

  it("classifies conversation.admin.snoozed as lifecycle/snoozed", () => {
    const snoozed = { ...userCreated, topic: "conversation.admin.snoozed" };
    const result = classifyEvent(snoozed as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") expect(result.state).toBe("snoozed");
  });

  it("classifies conversation.admin.opened as lifecycle/open", () => {
    const opened = { ...userCreated, topic: "conversation.admin.opened" };
    const result = classifyEvent(opened as IntercomWebhookPayload);
    expect(result.kind).toBe("lifecycle");
    if (result.kind === "lifecycle") expect(result.state).toBe("open");
  });

  it("classifies conversation.admin.noted as noted", () => {
    const noted = { ...userCreated, topic: "conversation.admin.noted" };
    const result = classifyEvent(noted as IntercomWebhookPayload);
    expect(result.kind).toBe("noted");
  });

  it("classifies unknown topics as unknown", () => {
    const unknown = { ...userCreated, topic: "conversation.admin.something_new" };
    const result = classifyEvent(unknown as IntercomWebhookPayload);
    expect(result.kind).toBe("unknown");
  });
});

describe("idempotency", () => {
  it("returns false for unseen event ID", () => {
    const set = createEventIdSet([]);
    expect(isEventProcessed("evt_001", set)).toBe(false);
  });

  it("returns true for already-processed event ID", () => {
    const set = createEventIdSet(["evt_001"]);
    expect(isEventProcessed("evt_001", set)).toBe(true);
  });

  it("tracks a new event ID", () => {
    const processed: string[] = [];
    trackEventId("evt_001", processed);
    expect(processed).toContain("evt_001");
  });

  it("evicts oldest ID when exceeding MAX_PROCESSED_EVENT_IDS", () => {
    const processed = Array.from({ length: 1000 }, (_, i) => `evt_${i}`);
    trackEventId("evt_new", processed);
    expect(processed.length).toBe(1000);
    expect(processed).not.toContain("evt_0");
    expect(processed).toContain("evt_new");
  });
});

describe("isSelfReply", () => {
  it("returns true when messageId is in outbound list", () => {
    expect(isSelfReply("msg_1", ["msg_1", "msg_2"])).toBe(true);
  });

  it("returns false for unknown messageId", () => {
    expect(isSelfReply("msg_3", ["msg_1", "msg_2"])).toBe(false);
  });
});

describe("extractImageAttachments", () => {
  // WHY: the gateway can't forward image bytes if classify drops them.
  // These tests pin every accept/reject branch so a future "just trust
  // the structured field" refactor doesn't silently regress the HTML
  // fallback path (which we need because older Intercom Messenger
  // clients embed images via <img> only, no `attachments[]`).

  const img = (over: Partial<IntercomPartAttachment>): IntercomPartAttachment => ({
    type: "upload",
    name: "screenshot.png",
    url: "https://downloads.intercomcdn.com/i/o/abc/screenshot.png",
    content_type: "image/png",
    ...over,
  });

  it("keeps a structured PNG attachment with its content_type", () => {
    const result = extractImageAttachments([img({})], "");
    expect(result).toEqual([{
      url: "https://downloads.intercomcdn.com/i/o/abc/screenshot.png",
      contentType: "image/png",
      name: "screenshot.png",
    }]);
  });

  it("normalizes image/jpg to image/jpeg", () => {
    const result = extractImageAttachments(
      [img({ url: "https://downloads.intercomcdn.com/i/o/x.jpg", content_type: "image/jpg" })],
      "",
    );
    expect(result[0].contentType).toBe("image/jpeg");
  });

  it("drops non-image MIMEs from the IMAGE extractor (PDF goes via extractDocumentAttachments; audio/video unsupported)", () => {
    // PDFs are intentionally NOT image refs — they take the document path
    // (persist original + rasterize). The image extractor must still reject
    // them so a PDF can't be persisted with an image extension / fed straight
    // to vision unrasterized.
    const result = extractImageAttachments(
      [
        img({ content_type: "application/pdf", name: "doc.pdf" }),
        img({ content_type: "audio/mpeg", name: "voice.mp3" }),
        img({ content_type: "video/mp4", name: "clip.mp4" }),
      ],
      "",
    );
    expect(result).toEqual([]);
  });

  it("extracts inline <img> from HTML body when no structured attachments present", () => {
    // WHY: older Intercom Messenger flows embed images via <img> only,
    // with no `attachments[]` array. Without this fallback, classify
    // would see "no attachments" and we'd silently re-introduce the
    // hallucination class of bugs PR #358 mitigated.
    const html = '<p>look at this</p><img src="https://downloads.intercomcdn.com/i/o/inline/foo.png" alt="x">';
    const result = extractImageAttachments(undefined, html);
    expect(result).toEqual([{
      url: "https://downloads.intercomcdn.com/i/o/inline/foo.png",
      contentType: "image/png",
    }]);
  });

  it("supports single-quoted src attributes in HTML", () => {
    const html = "<img src='https://downloads.intercomcdn.com/i/o/inline/bar.jpg'>";
    const result = extractImageAttachments(undefined, html);
    expect(result[0]?.url).toBe("https://downloads.intercomcdn.com/i/o/inline/bar.jpg");
    expect(result[0]?.contentType).toBe("image/jpeg");
  });

  it("ignores non-Intercom CDN <img> hosts (defense against XSS-style leakage)", () => {
    // WHY: A customer could paste a forged <img src="https://evil.com/...">
    // hoping we'd fetch+forward an attacker-controlled URL. The CDN host
    // allowlist refuses anything not on intercomcdn.{com,io}.
    const html = '<img src="https://evil.example.com/payload.png">';
    expect(extractImageAttachments(undefined, html)).toEqual([]);
  });

  it("merges structured + inline HTML, deduping by URL", () => {
    const sharedUrl = "https://downloads.intercomcdn.com/i/o/shared.png";
    const html = `<img src="${sharedUrl}"><img src="https://downloads.intercomcdn.com/i/o/extra.jpg">`;
    const result = extractImageAttachments([img({ url: sharedUrl })], html);
    expect(result.map((r) => r.url)).toEqual([
      sharedUrl,
      "https://downloads.intercomcdn.com/i/o/extra.jpg",
    ]);
  });

  it("drops inline <img> with no recognizable image extension", () => {
    // We can't tell what an extensionless CDN URL contains without
    // fetching, and we never want to fetch URLs of unknown type — could
    // be HTML, a tracking pixel, or anything. Drop is the right call.
    const html = '<img src="https://downloads.intercomcdn.com/i/o/unknown">';
    expect(extractImageAttachments(undefined, html)).toEqual([]);
  });

  it("handles undefined inputs gracefully", () => {
    expect(extractImageAttachments(undefined, undefined)).toEqual([]);
    expect(extractImageAttachments([], "")).toEqual([]);
  });
});

describe("extractDocumentAttachments", () => {
  // WHY: PDFs need a distinct extractor — they are rasterized for vision AND
  // forwarded verbatim for document-extract. These tests pin the accept/reject
  // branches so a future change can't (a) let an image slip into the doc path,
  // or (b) coerce us into fetching a non-CDN URL claiming application/pdf.

  const doc = (over: Partial<IntercomPartAttachment>): IntercomPartAttachment => ({
    type: "upload",
    name: "invoice.pdf",
    url: "https://downloads.intercomcdn.com/i/o/abc/invoice.pdf",
    content_type: "application/pdf",
    ...over,
  });

  it("keeps a structured PDF attachment with content_type + name", () => {
    expect(extractDocumentAttachments([doc({})])).toEqual([{
      url: "https://downloads.intercomcdn.com/i/o/abc/invoice.pdf",
      contentType: "application/pdf",
      name: "invoice.pdf",
    }]);
  });

  it("drops image MIMEs (those belong to extractImageAttachments)", () => {
    expect(extractDocumentAttachments([doc({ content_type: "image/png", name: "a.png" })])).toEqual([]);
  });

  it("ignores non-Intercom CDN hosts even if content_type claims application/pdf", () => {
    // Defense against a forged/malformed payload coercing an out-of-band fetch.
    expect(extractDocumentAttachments([doc({ url: "https://evil.example.com/x.pdf" })])).toEqual([]);
  });

  it("dedupes by URL", () => {
    const sharedUrl = "https://downloads.intercomcdn.com/i/o/abc/dup.pdf";
    const result = extractDocumentAttachments([doc({ url: sharedUrl }), doc({ url: sharedUrl })]);
    expect(result).toHaveLength(1);
  });

  it("does NOT scrape inline HTML (PDFs are never <img> tags)", () => {
    // extractDocumentAttachments has no body param — only structured refs.
    expect(extractDocumentAttachments(undefined)).toEqual([]);
    expect(extractDocumentAttachments([])).toEqual([]);
  });
});

describe("classifyEvent — attachments", () => {
  // WHY: it's not enough that extractImageAttachments works in isolation —
  // we need to verify the classify layer plumbs them through onto the
  // `customer_message` variant, which is the only path downstream consumers
  // read. Pre-#358 the field didn't exist.

  const baseUserCreated = (over: Partial<IntercomWebhookPayload["data"]["item"]>): IntercomWebhookPayload => ({
    type: "notification_event",
    app_id: "app_test",
    data: {
      type: "notification_event_data",
      item: {
        type: "conversation",
        id: "conv_attach",
        title: null,
        created_at: 1711234567,
        updated_at: 1711234567,
        open: true,
        state: "open",
        ...over,
      } as IntercomWebhookPayload["data"]["item"],
    },
    topic: "conversation.user.created",
    id: "evt_attach",
    created_at: 1711234567,
    delivery_status: "pending",
    delivery_attempts: 1,
  });

  it("attaches images extracted from the last conversation_part", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "look at this",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
          attachments: [{
            type: "upload",
            name: "shot.png",
            url: "https://downloads.intercomcdn.com/i/o/x/shot.png",
            content_type: "image/png",
          }],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.attachments).toHaveLength(1);
      expect(result.attachments?.[0].contentType).toBe("image/png");
    }
  });

  it("classifies as customer_message even when body is empty IF an image is attached", () => {
    // WHY: drag-drop-an-image-with-no-caption is a common case. Pre-fix,
    // empty body returned `unknown:empty_body` and the image was dropped.
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
          attachments: [{
            type: "upload",
            name: "shot.png",
            url: "https://downloads.intercomcdn.com/i/o/x/shot.png",
            content_type: "image/png",
          }],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.body).toBe("");
      expect(result.attachments).toHaveLength(1);
    }
  });

  it("still returns unknown:empty_body when body AND attachments are empty", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("unknown");
    if (result.kind === "unknown") expect(result.topic).toContain("empty_body");
  });

  it("omits the `attachments` key entirely on plain text messages (preserves prior shape)", () => {
    // WHY: HandlerAction matches on attachments?: ... — undefined means
    // "text-only, no extraContext needed at dispatch." Keeping the field
    // omitted (vs `attachments: []`) avoids any chance of an empty-array
    // false positive in downstream consumers that loosely check
    // `if (action.attachments) …`.
    const payload = baseUserCreated({
      source: {
        body: "hi",
        author: { type: "user", id: "u1", email: "u@example.com" },
      } as IntercomWebhookPayload["data"]["item"]["source"],
    });
    const result = classifyEvent(payload);
    if (result.kind === "customer_message") {
      expect("attachments" in result).toBe(false);
    }
  });

  it("forwards image-only new conversations whose attachments live on source.attachments (no conversation_part yet)", () => {
    // WHY: Clio review of PR #360 caught this. A fresh
    // `conversation.user.created` for an image-only message may carry the
    // attachment on `conversation.source.attachments` rather than on a
    // `conversation_part`, because no part has been split out yet. Pre-fix,
    // structured-attachment extraction only inspected `lastPart?.attachments`,
    // so the very class of message this PR is meant to forward was being
    // silently dropped as `unknown:empty_body`. Locks the source-fallback in.
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
      source: {
        body: "",
        author: { type: "user", id: "u_initial", email: "i@example.com" },
        attachments: [{
          type: "upload",
          name: "screenshot.png",
          url: "https://downloads.intercomcdn.com/i/o/x/screenshot.png",
          content_type: "image/png",
        }],
      } as IntercomWebhookPayload["data"]["item"]["source"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.body).toBe("");
      expect(result.attachments).toHaveLength(1);
      expect(result.attachments?.[0].contentType).toBe("image/png");
      expect(result.attachments?.[0].url).toContain("intercomcdn.com");
    }
  });

  it("prefers lastPart.attachments over source.attachments when both are present (matches body fallback chain)", () => {
    // WHY: defends against accidental shape drift. If a future change ever
    // swaps the precedence, the part-level attachments (the customer's most
    // recent action) would be replaced by stale source attachments (the
    // conversation's initial message). Lock the same precedence the body
    // fallback uses so the two stay coherent.
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_recent",
          body: "newer caption",
          part_type: "comment",
          created_at: 1711234999,
          author: { type: "user", id: "u_recent" },
          attachments: [{
            type: "upload",
            name: "new.png",
            url: "https://downloads.intercomcdn.com/i/o/x/new.png",
            content_type: "image/png",
          }],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
      source: {
        body: "old initial body",
        author: { type: "user", id: "u_initial" },
        attachments: [{
          type: "upload",
          name: "old.jpg",
          url: "https://downloads.intercomcdn.com/i/o/x/old.jpg",
          content_type: "image/jpeg",
        }],
      } as IntercomWebhookPayload["data"]["item"]["source"],
    });
    const result = classifyEvent(payload);
    if (result.kind === "customer_message") {
      expect(result.attachments).toHaveLength(1);
      expect(result.attachments?.[0].url).toContain("/new.png");
    }
  });

  it("plumbs PDF documents onto customer_message.documents (separate key from attachments)", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "here's my receipt",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
          attachments: [{
            type: "upload",
            name: "receipt.pdf",
            url: "https://downloads.intercomcdn.com/i/o/x/receipt.pdf",
            content_type: "application/pdf",
          }],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.documents).toHaveLength(1);
      expect(result.documents?.[0].contentType).toBe("application/pdf");
      // image attachments key stays omitted when there are none
      expect("attachments" in result).toBe(false);
    }
  });

  it("classifies as customer_message even when body is empty IF only a PDF is attached", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
          attachments: [{
            type: "upload",
            name: "doc.pdf",
            url: "https://downloads.intercomcdn.com/i/o/x/doc.pdf",
            content_type: "application/pdf",
          }],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.body).toBe("");
      expect(result.documents).toHaveLength(1);
    }
  });

  it("carries BOTH images and documents when a message mixes them", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [{
          type: "conversation_part",
          id: "part_1",
          body: "screenshot + the pdf",
          part_type: "comment",
          created_at: 1711234567,
          author: { type: "user", id: "user_xyz" },
          attachments: [
            {
              type: "upload",
              name: "shot.png",
              url: "https://downloads.intercomcdn.com/i/o/x/shot.png",
              content_type: "image/png",
            },
            {
              type: "upload",
              name: "report.pdf",
              url: "https://downloads.intercomcdn.com/i/o/x/report.pdf",
              content_type: "application/pdf",
            },
          ],
        }],
      } as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent(payload);
    if (result.kind === "customer_message") {
      expect(result.attachments).toHaveLength(1);
      expect(result.attachments?.[0].contentType).toBe("image/png");
      expect(result.documents).toHaveLength(1);
      expect(result.documents?.[0].contentType).toBe("application/pdf");
    }
  });

  it("omits the `documents` key entirely on messages with no PDFs", () => {
    const payload = baseUserCreated({
      source: {
        body: "just text",
        author: { type: "user", id: "u1", email: "u@example.com" },
      } as IntercomWebhookPayload["data"]["item"]["source"],
    });
    const result = classifyEvent(payload);
    if (result.kind === "customer_message") {
      expect("documents" in result).toBe(false);
    }
  });
});

describe("extractImageAttachments — structured CDN host allowlist", () => {
  // WHY: Clio review of PR #360 noticed the inline-<img> branch enforces
  // INTERCOM_CDN_HOST_RE but the structured branch didn't. Without the
  // allowlist, a payload that claims `content_type: image/png` paired with
  // an arbitrary host could coerce the plugin into fetching from anywhere.
  // These tests lock the structured branch into the same posture as the
  // inline one. Defense-in-depth — the webhook HMAC is the first line.

  it("drops a structured attachment whose URL is off the Intercom CDN, even with an allowlisted MIME", () => {
    const result = extractImageAttachments(
      [{
        type: "upload",
        name: "evil.png",
        url: "https://attacker.example.com/evil.png",
        content_type: "image/png",
      }],
      "",
    );
    expect(result).toEqual([]);
  });

  it("accepts structured attachments hosted on the Intercom CDN (sanity counter-test)", () => {
    const result = extractImageAttachments(
      [{
        type: "upload",
        name: "ok.png",
        url: "https://downloads.intercomcdn.com/i/o/x/ok.png",
        content_type: "image/png",
      }],
      "",
    );
    expect(result).toHaveLength(1);
    expect(result[0].url).toContain("intercomcdn.com");
  });
});

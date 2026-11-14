import { describe, it, expect } from "vitest";
import { classifyEvent, customerSpokeLast, surfaceLinkTargets, createEventIdSet, isEventProcessed, trackEventId, isSelfReply, extractImageAttachments, extractDocumentAttachments, handbackNoteReason, HANDBACK_MARKER, IMAGE_MIME_ALLOWLIST, CANDIDATE_IMAGE_MIME_ALLOWLIST } from "../src/filters.js";
import type { IntercomConversationPart, IntercomWebhookPayload, IntercomPartAttachment } from "../src/types.js";
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

  it("captures verified identity (type/email/name) from source.author on user.created", () => {
    const withName = {
      ...userCreated,
      data: {
        ...userCreated.data,
        item: {
          ...userCreated.data.item,
          source: {
            ...userCreated.data.item.source,
            author: { type: "user", id: "user_abc", email: "User@Example.com", name: "Jane Doe" },
          },
        },
      },
    };
    const result = classifyEvent(withName as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.authorType).toBe("user");
      expect(result.verifiedEmail).toBe("user@example.com"); // lowercased
      expect(result.verifiedName).toBe("Jane Doe");
    }
  });

  it("falls back to the conversation_part author when source.author is not a user (admin-initiated convo)", () => {
    // Admin opened the conversation, the user replied. source.author is the
    // admin, so verified identity must come from the replying part's user author.
    const adminInitiated = {
      ...userReplied,
      data: {
        ...userReplied.data,
        item: {
          ...userReplied.data.item,
          source: {
            ...userReplied.data.item.source,
            author: { type: "admin", id: "admin_7", email: "agent@muso.ai", name: "Caroline" },
          },
          conversation_parts: {
            conversation_parts: [
              {
                type: "conversation_part",
                id: "part_9",
                body: "any update?",
                part_type: "comment",
                created_at: 1711234999,
                author: { type: "user", id: "user_abc", email: "  USER@Example.com ", name: "Jane Doe" },
              },
            ],
          },
        },
      },
    };
    const result = classifyEvent(adminInitiated as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.authorType).toBe("user");
      expect(result.verifiedEmail).toBe("user@example.com"); // trimmed + lowercased, from the user part
      expect(result.verifiedName).toBe("Jane Doe");
    }
  });

  it("does NOT capture email/name when the author type is not user", () => {
    const adminAuthored = {
      ...userCreated,
      data: {
        ...userCreated.data,
        item: {
          ...userCreated.data.item,
          source: {
            ...userCreated.data.item.source,
            author: { type: "admin", id: "admin_7", email: "agent@muso.ai", name: "Caroline" },
          },
        },
      },
    };
    const result = classifyEvent(adminAuthored as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.authorType).toBe("admin");
      expect(result.verifiedEmail).toBeUndefined();
      expect(result.verifiedName).toBeUndefined();
    }
  });

  it("leaves verified identity undefined when the user author has no email/name", () => {
    const noEmail = {
      ...userCreated,
      data: {
        ...userCreated.data,
        item: {
          ...userCreated.data.item,
          source: {
            ...userCreated.data.item.source,
            author: { type: "user", id: "user_abc" },
          },
        },
      },
    };
    const result = classifyEvent(noEmail as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.authorType).toBe("user");
      expect(result.verifiedEmail).toBeUndefined();
      expect(result.verifiedName).toBeUndefined();
    }
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
    expect(result.refs).toEqual([{
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
    expect(result.refs[0].contentType).toBe("image/jpeg");
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
    expect(result.refs).toEqual([]);
  });

  it("extracts inline <img> from HTML body when no structured attachments present", () => {
    // WHY: older Intercom Messenger flows embed images via <img> only,
    // with no `attachments[]` array. Without this fallback, classify
    // would see "no attachments" and we'd silently re-introduce the
    // hallucination class of bugs PR #358 mitigated.
    const html = '<p>look at this</p><img src="https://downloads.intercomcdn.com/i/o/inline/foo.png" alt="x">';
    const result = extractImageAttachments(undefined, html);
    expect(result.refs).toEqual([{
      url: "https://downloads.intercomcdn.com/i/o/inline/foo.png",
      contentType: "image/png",
    }]);
  });

  it("supports single-quoted src attributes in HTML", () => {
    const html = "<img src='https://downloads.intercomcdn.com/i/o/inline/bar.jpg'>";
    const result = extractImageAttachments(undefined, html);
    expect(result.refs[0]?.url).toBe("https://downloads.intercomcdn.com/i/o/inline/bar.jpg");
    expect(result.refs[0]?.contentType).toBe("image/jpeg");
  });

  it("ignores non-Intercom CDN <img> hosts (defense against XSS-style leakage)", () => {
    // WHY: A customer could paste a forged <img src="https://evil.com/...">
    // hoping we'd fetch+forward an attacker-controlled URL. The CDN host
    // allowlist refuses anything not on intercomcdn.{com,io}.
    const html = '<img src="https://evil.example.com/payload.png">';
    expect(extractImageAttachments(undefined, html).refs).toEqual([]);
  });

  it("merges structured + inline HTML, deduping by URL", () => {
    const sharedUrl = "https://downloads.intercomcdn.com/i/o/shared.png";
    const html = `<img src="${sharedUrl}"><img src="https://downloads.intercomcdn.com/i/o/extra.jpg">`;
    const result = extractImageAttachments([img({ url: sharedUrl })], html);
    expect(result.refs.map((r) => r.url)).toEqual([
      sharedUrl,
      "https://downloads.intercomcdn.com/i/o/extra.jpg",
    ]);
  });

  it("drops inline <img> with no recognizable image extension", () => {
    // We can't tell what an extensionless CDN URL contains without
    // fetching, and we never want to fetch URLs of unknown type — could
    // be HTML, a tracking pixel, or anything. Drop is the right call.
    const html = '<img src="https://downloads.intercomcdn.com/i/o/unknown">';
    expect(extractImageAttachments(undefined, html).refs).toEqual([]);
  });

  it("keeps a structured upload on the intercom-attachments-<N> host (the real Messenger-widget host)", () => {
    // REGRESSION (2026-06-01): a customer widget upload's STRUCTURED attachment
    // is served from `<workspace>.intercom-attachments-<N>.com`, NOT intercomcdn.
    // The pre-fix host regex only matched intercomcdn → every widget image was
    // silently dropped at the structured branch (Caroline "can't see the image").
    // Confirmed live via the Intercom conversations API. This is the exact URL
    // shape from that incident (conv 215474527942736).
    const url =
      "https://musoai.intercom-attachments-3.com/i/o/dwjzhcge/2446934281/abc/image.png?expires=1&signature=x";
    const result = extractImageAttachments([img({ url, content_type: "image/png" })], "");
    expect(result.refs).toEqual([{ url, contentType: "image/png", name: "screenshot.png" }]);
  });

  it("keeps the bare intercom-attachments.com host (no numeric suffix)", () => {
    const url = "https://musoai.intercom-attachments.com/i/o/x/image.jpg";
    const result = extractImageAttachments([img({ url, content_type: "image/jpeg" })], "");
    expect(result.refs[0]?.url).toBe(url);
  });

  it("still rejects look-alike hosts (allowlist not loosened into a substring match)", () => {
    // Defense: the widened regex must not accept an attacker host that merely
    // CONTAINS the allowlisted token (e.g. intercom-attachments.evil.com or
    // intercomcdn.com.evil.com). Anchored ^https:// + host-segment boundary.
    expect(
      extractImageAttachments(
        [img({ url: "https://intercom-attachments-3.com.evil.com/x.png" })],
        "",
      ).refs,
    ).toEqual([]);
    expect(
      extractImageAttachments(undefined, '<img src="https://evil.com/intercomcdn.com/x.png">').refs,
    ).toEqual([]);
  });

  it("handles undefined inputs gracefully", () => {
    expect(extractImageAttachments(undefined, undefined).refs).toEqual([]);
    expect(extractImageAttachments([], "").refs).toEqual([]);
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

  it("forwards the opening message's image when Intercom has already appended bot/system parts (live shape, 2026-10-17)", () => {
    // WHY: production `user.created` payloads arrive with bot parts already
    // appended (attribute update, default assignment, ...), each with
    // `attachments: []` and no body. Taking `.at(-1)` made that empty array
    // win over `source.attachments`: 4 of 4 customer openers with an image
    // on 2026-10-17 reached Caroline with no image ("I can't see the image").
    const sysPart = (id: string, part_type: string, authorType: string) => ({
      type: "conversation_part", id, part_type, body: null, created_at: 1711234001,
      author: { type: authorType, id: "5763097" }, attachments: [],
    });
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [
          sysPart("p1", "conversation_attribute_updated_by_admin", "bot"),
          sysPart("p2", "default_assignment", "bot"),
          sysPart("p3", "assignment", "admin"),
        ],
      } as unknown as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
      source: {
        body: "<p>hi here's my additional evidence</p>",
        author: { type: "user", id: "u_initial", email: "i@example.com" },
        attachments: [{
          type: "upload",
          name: "IMG_3118.png",
          url: "https://downloads.intercomcdn.com/i/o/x/IMG_3118.png",
          content_type: "image/png",
        }],
      } as IntercomWebhookPayload["data"]["item"]["source"],
    });
    const result = classifyEvent(payload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.body).toContain("additional evidence");
      expect(result.attachments).toHaveLength(1);
      expect(result.attachments?.[0].url).toContain("/IMG_3118.png");
      expect(result.authorId).toBe("u_initial");
      expect(result.authorType).toBe("user");
    }
  });

  it("on user.replied, reads the latest CUSTOMER part even when a bot part follows it", () => {
    const payload = baseUserCreated({
      conversation_parts: {
        conversation_parts: [
          {
            type: "conversation_part", id: "c1", part_type: "comment", body: "<p>here it is</p>", created_at: 1711234100,
            author: { type: "lead", id: "lead_1" },
            attachments: [{ type: "upload", name: "proof.png", url: "https://downloads.intercomcdn.com/i/o/x/proof.png", content_type: "image/png" }],
          },
          {
            type: "conversation_part", id: "b1", part_type: "language_detection_details", body: null, created_at: 1711234101,
            author: { type: "bot", id: "5763097" }, attachments: [],
          },
        ],
      } as unknown as IntercomWebhookPayload["data"]["item"]["conversation_parts"],
    });
    const result = classifyEvent({ ...payload, topic: "conversation.user.replied" } as IntercomWebhookPayload);
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.body).toContain("here it is");
      expect(result.attachments?.[0].url).toContain("/proof.png");
      expect(result.authorId).toBe("lead_1");
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
    expect(result.refs).toEqual([]);
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
    expect(result.refs).toHaveLength(1);
    expect(result.refs[0].url).toContain("intercomcdn.com");
  });
});

describe("extractImageAttachments — HEIC/HEIF candidates and counted drops", () => {
  const heicAtt = (url: string, ct: string): IntercomPartAttachment =>
    ({ url, content_type: ct, name: "IMG_0042" }) as IntercomPartAttachment;
  const CDN = "https://musoai.intercom-attachments-3.com";

  it("admits image/heic and image/heif as candidates", () => {
    // WHY: these missed the positive allowlist and hit a bare `continue`, so
    // every iPhone "High Efficiency" photo was invisible to Caroline with no
    // trace anywhere. They are CANDIDATES only — attachments.ts transcodes
    // them before anything reaches a model.
    const drops: string[] = [];
    const result = extractImageAttachments(
      [heicAtt(`${CDN}/a.heic`, "image/heic"), heicAtt(`${CDN}/b.heif`, "image/heif")],
      "",
      { warn: (m) => drops.push(m) },
    );
    expect(result.refs.map((r) => r.contentType)).toEqual(["image/heic", "image/heif"]);
    expect(result.unsupported).toEqual([]);
    expect(drops).toEqual([]);
  });

  it("keeps HEIF out of the forwardable IMAGE_MIME_ALLOWLIST", () => {
    // The two sets are deliberately different: IMAGE_MIME_ALLOWLIST is
    // "safe to forward verbatim". A HEIC forwarded verbatim is an image no
    // model can read.
    expect(IMAGE_MIME_ALLOWLIST.has("image/heic")).toBe(false);
    expect(CANDIDATE_IMAGE_MIME_ALLOWLIST.has("image/heic")).toBe(true);
    expect(CANDIDATE_IMAGE_MIME_ALLOWLIST.has("image/png")).toBe(true);
  });

  it("infers image/heic and image/heif from inline <img> URL extensions", () => {
    const html = `<img src="${CDN}/inline.heic"><img src="${CDN}/inline.HEIF">`;
    const result = extractImageAttachments(undefined, html, { warn: () => {} });
    expect(result.refs.map((r) => r.contentType)).toEqual(["image/heic", "image/heif"]);
  });

  it("COUNTS and LOGS unsupported types instead of dropping them silently", () => {
    // WHY: the silent `continue` is the actual root cause here. HEIC was
    // invisible for as long as it was because nothing anywhere recorded a
    // refusal — the next unsupported type must be visible on day one.
    const drops: string[] = [];
    const result = extractImageAttachments(
      [
        heicAtt(`${CDN}/a.tiff`, "image/tiff"),
        heicAtt(`${CDN}/b.tiff`, "image/tiff"),
        heicAtt(`${CDN}/c.svg`, "image/svg+xml"),
        heicAtt(`${CDN}/d.png`, "image/png"),
      ],
      "",
      { warn: (m) => drops.push(m) },
    );
    expect(result.refs).toHaveLength(1);
    expect(drops).toHaveLength(1);
    expect(drops[0]).toContain("dropped 3 unsupported image attachment(s)");
    expect(drops[0]).toContain("image/tiff:2");
    expect(drops[0]).toContain("image/svg+xml:1");
  });

  it("does not count PDFs as image drops (they have their own extractor)", () => {
    const drops: string[] = [];
    extractImageAttachments([heicAtt(`${CDN}/a.pdf`, "application/pdf")], "", {
      warn: (m) => drops.push(m),
    });
    expect(drops).toEqual([]);
  });

  it("emits no log line when nothing was dropped", () => {
    const drops: string[] = [];
    extractImageAttachments([heicAtt(`${CDN}/a.png`, "image/png")], "", { warn: (m) => drops.push(m) });
    expect(drops).toEqual([]);
  });

  it("classifyEvent threads the log through and surfaces HEIC attachments", () => {
    const drops: string[] = [];
    const payload = {
      topic: "conversation.user.created",
      id: "evt_heic",
      data: {
        item: {
          id: "conv_heic",
          source: {
            body: "see screenshot",
            author: { type: "user", id: "u1", email: "a@b.com" },
            attachments: [
              { url: `${CDN}/shot.heic`, content_type: "image/heic", name: "IMG_1.heic" },
              { url: `${CDN}/nope.tiff`, content_type: "image/tiff", name: "scan.tiff" },
            ],
          },
        },
      },
    } as unknown as IntercomWebhookPayload;
    const result = classifyEvent(payload, { warn: (m) => drops.push(m) });
    expect(result.kind).toBe("customer_message");
    if (result.kind === "customer_message") {
      expect(result.attachments?.map((a) => a.contentType)).toEqual(["image/heic"]);
    }
    expect(drops[0]).toContain("image/tiff:1");
  });
});

describe("surfaceLinkTargets", () => {
  const card = (u: string) =>
    `<div class="intercom-container"><a class="intercom-h2b-button" target="_blank" href="${u}">muso.ai  </a><a href="${u}" target="_blank" class="intercom-content-link"></a></div>`;
  const strip = (h: string) => h.replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();

  it("a pasted-link preview card shows its URL once (measured 2026-10-20)", () => {
    const u = "https://muso.ai/profile/155931ce-2ada-4b43-90da-64acb35f4b7b";
    const out = strip(surfaceLinkTargets(`<p>Hello Caroline,</p>${card(u)}<p>That's my main artist link.</p>`));
    expect(out).toContain(u);
    expect(out.split(u).length - 1).toBe(1);
    expect(out).not.toMatch(/muso\.ai\s+That/);
  });
  it("descriptive link text keeps the text and adds the URL", () => {
    const u = "https://open.spotify.com/track/abc";
    expect(strip(surfaceLinkTargets(`<a href="${u}">my song</a>`))).toBe(`my song (${u})`);
  });
  it("text that already is the URL is not duplicated", () => {
    const u = "https://muso.ai/profile/x";
    expect(strip(surfaceLinkTargets(`<a href="${u}">${u}</a>`))).toBe(u);
  });
  it("mailto and relative links keep only their text", () => {
    expect(strip(surfaceLinkTargets(`<a href="mailto:a@b.co">email me</a> <a href="/x">here</a>`))).toBe("email me here");
  });
  it("decodes &amp; in hrefs", () => {
    expect(strip(surfaceLinkTargets(`<a href="https://x.co/?a=1&amp;b=2"></a>`))).toBe("https://x.co/?a=1&b=2");
  });
  it("classifyEvent keeps the body exactly as Intercom sent it", () => {
    const u = "https://muso.ai/profile/b8ea4676-da77-45fe-ba43-e1a828648f40";
    const payload = JSON.parse(JSON.stringify(userReplied)) as IntercomWebhookPayload;
    const body = `<p></p>${card(u)}<p>The data was split by the label.</p>`;
    const item = payload.data.item;
    item.conversation_parts = { conversation_parts: [{ id: "p1", part_type: "comment", body, author: { id: "u1", type: "user" }, attachments: [] } as never] } as never;
    const r = classifyEvent(payload);
    expect(r.kind).toBe("customer_message");
    if (r.kind === "customer_message") expect(r.body).toBe(body);
  });
});


describe("customerSpokeLast", () => {
  const conversation = (parts: unknown[], sourceAuthor = { type: "user", id: "u1" }) =>
    ({
      type: "conversation",
      id: "conv_123",
      title: null,
      created_at: 1711234567,
      updated_at: 1711234567,
      open: true,
      state: "open",
      source: { body: "the opening message", author: sourceAuthor },
      conversation_parts: { conversation_parts: parts },
    }) as never;

  const partOf = (authorType: string) => ({ type: "conversation_part", id: "p", body: "x", part_type: "comment", created_at: 1, author: { type: authorType, id: "a" } });

  it("is true when the customer's message is the newest one", () => {
    expect(customerSpokeLast(conversation([partOf("admin"), partOf("user")]))).toBe(true);
    expect(customerSpokeLast(conversation([partOf("lead")]))).toBe(true);
  });

  it("is false when we replied after them", () => {
    expect(customerSpokeLast(conversation([partOf("user"), partOf("admin")]))).toBe(false);
    expect(customerSpokeLast(conversation([partOf("user"), partOf("bot")]))).toBe(false);
  });

  it("ignores parts that answer nobody, such as the drain's assignment and its internal note", () => {
    const drainParts = [
      { ...partOf("user"), id: "p1" },
      { ...partOf("admin"), id: "p2", body: null, part_type: "assignment" },
      { ...partOf("admin"), id: "p3", body: "Internal note", part_type: "note" },
    ];
    expect(customerSpokeLast(conversation(drainParts))).toBe(true);
    expect(customerSpokeLast(conversation([...drainParts, { ...partOf("admin"), id: "p4", body: "", part_type: "comment" }]))).toBe(true);
    expect(customerSpokeLast(conversation([...drainParts, { ...partOf("admin"), id: "p4", body: "<p>An update</p>", part_type: "comment" }]))).toBe(false);
  });

  it("counts a customer message that carries no words", () => {
    expect(customerSpokeLast(conversation([partOf("admin"), { ...partOf("user"), body: "" }]))).toBe(true);
  });

  it("falls back to who wrote the opening message when there are no parts", () => {
    expect(customerSpokeLast(conversation([]))).toBe(true);
    expect(customerSpokeLast(conversation([], { type: "admin", id: "5465657" }))).toBe(false);
  });
});

describe("handbackNoteReason", () => {
  const BOT = "bot_1";
  const note = (over: Partial<IntercomConversationPart> = {}): IntercomConversationPart => ({
    type: "conversation_part",
    id: "p_note",
    part_type: "note",
    created_at: 1711234800,
    author: { type: "admin", id: BOT },
    body: `<p>Note to team (internal Ops note, not visible to the customer).</p><p>${HANDBACK_MARKER} reason=specific_ask class=specific ask</p>`,
    ...over,
  });

  it("reads the marker and its reason code from the bot's own note, under the wrapper header", () => {
    expect(handbackNoteReason(note(), BOT)).toBe("specific_ask");
  });

  it("reads an owner campaign as the class", () => {
    const body = `<p>${HANDBACK_MARKER} reason=owner_recent class=proof-need-ask</p>`;
    expect(handbackNoteReason(note({ body }), BOT)).toBe("owner_recent");
  });

  it("is never a note by another admin, a comment, or a body without the marker", () => {
    expect(handbackNoteReason(note({ author: { type: "admin", id: "admin_99" } }), BOT)).toBe("");
    expect(handbackNoteReason(note({ part_type: "comment" }), BOT)).toBe("");
    expect(handbackNoteReason(note({ body: "<p>Please look at this tomorrow</p>" }), BOT)).toBe("");
    expect(handbackNoteReason(undefined, BOT)).toBe("");
  });

  it("requires the marker to start a line of the note, not merely appear inside one", () => {
    expect(handbackNoteReason(note({ body: `<p>see ${HANDBACK_MARKER} reason=specific_ask</p>` }), BOT)).toBe("");
  });

  it("refuses a marker with no reason code", () => {
    expect(handbackNoteReason(note({ body: `<p>${HANDBACK_MARKER}</p>` }), BOT)).toBe("");
  });
});

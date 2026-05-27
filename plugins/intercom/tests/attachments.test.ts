import { describe, it, expect, beforeEach, afterEach } from "vitest";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import {
  downloadImageAttachments,
  buildMediaExtraContext,
  MAX_IMAGE_ATTACHMENTS_PER_TURN,
  ATTACHMENT_MAX_BYTES,
  type PersistedAttachment,
} from "../src/attachments.js";
import type { ImageAttachmentRef } from "../src/types.js";

// WHY this whole file: this is the only seam between Intercom's CDN
// (lives outside our network) and the openclaw runtime's vision path.
// A regression here means images are silently dropped and Caroline
// goes back to hallucinating — same class of bug as PR #358. Lock
// every branch.

let tempRoot: string;

beforeEach(async () => {
  tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "intercom-attach-test-"));
});

afterEach(async () => {
  await fs.rm(tempRoot, { recursive: true, force: true });
});

const PNG_HEADER = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function makeFetchStub(responses: Record<string, { status: number; body: Buffer; contentType?: string }>) {
  return async (url: string | URL | Request, _init?: RequestInit): Promise<Response> => {
    const key = typeof url === "string" ? url : url.toString();
    const r = responses[key];
    if (!r) throw new Error(`test stub: unmapped url ${key}`);
    return new Response(r.body, {
      status: r.status,
      headers: r.contentType ? { "content-type": r.contentType } : undefined,
    });
  };
}

describe("downloadImageAttachments", () => {
  it("returns empty array when refs is empty", async () => {
    const result = await downloadImageAttachments({
      refs: [],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
    });
    expect(result).toEqual([]);
  });

  it("persists a single image and returns path + size + contentType", async () => {
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/a.png",
      contentType: "image/png",
    }];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      messageId: "msg_42",
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/a.png": {
            status: 200,
            body: PNG_HEADER,
            contentType: "image/png",
          },
        }),
      },
    });
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("image/png");
    expect(result[0].size).toBe(PNG_HEADER.length);
    // Disk side-effect: file exists at the returned path with the same bytes.
    const onDisk = await fs.readFile(result[0].path);
    expect(onDisk.equals(PNG_HEADER)).toBe(true);
    // Path is scoped under conversation + messageId (collision isolation).
    expect(result[0].path).toContain("conv_1");
    expect(result[0].path).toContain("msg_42");
  });

  it("prefers the server's Content-Type over the ref-supplied contentType", async () => {
    // WHY: classify-time MIME inference (from URL extension) can be wrong;
    // the CDN's Content-Type response header is authoritative.
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/img",
      contentType: "image/png", // stale guess
    }];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/img": {
            status: 200,
            body: PNG_HEADER,
            contentType: "image/jpeg; charset=binary",
          },
        }),
      },
    });
    expect(result[0].contentType).toBe("image/jpeg");
  });

  it("falls back to the ref-supplied contentType if the server returns a non-image type", async () => {
    // E.g. CDN omits Content-Type or returns octet-stream — trust classify-time.
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/img",
      contentType: "image/png",
    }];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/img": {
            status: 200,
            body: PNG_HEADER,
            contentType: "application/octet-stream",
          },
        }),
      },
    });
    expect(result[0].contentType).toBe("image/png");
  });

  it("falls back to ref contentType when server returns an image/* type that's NOT in the allowlist (e.g. image/svg+xml)", async () => {
    // WHY: Clio review of PR #360 noticed the original override accepted
    // anything that startsWith("image/"), which would silently promote a
    // CDN response of `image/svg+xml` (text-based, can carry JS, not in our
    // vision MIME allowlist) past the upstream MIME check. Constrain the
    // override to IMAGE_MIME_ALLOWLIST membership so the classify-time
    // allowlist remains authoritative downstream.
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/img",
      contentType: "image/png",
    }];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/img": {
            status: 200,
            body: PNG_HEADER,
            contentType: "image/svg+xml",
          },
        }),
      },
    });
    expect(result[0].contentType).toBe("image/png");
  });

  it("skips an attachment that fetches with a non-200 status", async () => {
    // WHY: Intercom CDN signed URLs return 403 after their TTL elapses
    // (~30 min). A single expired URL shouldn't drop the whole turn.
    const warns: string[] = [];
    const refs: ImageAttachmentRef[] = [
      { url: "https://downloads.intercomcdn.com/i/o/x/good.png", contentType: "image/png" },
      { url: "https://downloads.intercomcdn.com/i/o/x/expired.png", contentType: "image/png" },
    ];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/good.png": { status: 200, body: PNG_HEADER, contentType: "image/png" },
          "https://downloads.intercomcdn.com/i/o/x/expired.png": { status: 403, body: Buffer.alloc(0) },
        }),
      },
    });
    expect(result).toHaveLength(1);
    expect(warns.some((w) => w.includes("status=403"))).toBe(true);
  });

  it("drops images that exceed ATTACHMENT_MAX_BYTES", async () => {
    // Cap mirrors the SDK's AGENT_TURN_ATTACHMENT_MAX_BYTES so we don't
    // persist bytes the runtime will reject. Verify locally.
    const warns: string[] = [];
    const oversized = Buffer.alloc(ATTACHMENT_MAX_BYTES + 1, 0xff);
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/huge.png",
      contentType: "image/png",
    }];
    const result = await downloadImageAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/huge.png": { status: 200, body: oversized, contentType: "image/png" },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(warns.some((w) => w.includes("oversized"))).toBe(true);
  });

  it("truncates refs to MAX_IMAGE_ATTACHMENTS_PER_TURN with a warn", async () => {
    // WHY: defensive against a customer pasting 30 images. Keep a bounded
    // worst-case for download latency + disk usage.
    const warns: string[] = [];
    const tooMany = Array.from({ length: MAX_IMAGE_ATTACHMENTS_PER_TURN + 3 }, (_, i) => ({
      url: `https://downloads.intercomcdn.com/i/o/x/img${i}.png`,
      contentType: "image/png",
    }));
    const stubResponses: Record<string, { status: number; body: Buffer; contentType: string }> = {};
    for (const r of tooMany) {
      stubResponses[r.url] = { status: 200, body: PNG_HEADER, contentType: "image/png" };
    }
    const result = await downloadImageAttachments({
      refs: tooMany,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub(stubResponses),
      },
    });
    expect(result).toHaveLength(MAX_IMAGE_ATTACHMENTS_PER_TURN);
    expect(warns.some((w) => w.includes("truncated attachments"))).toBe(true);
  });

  it("sanitizes conversationId / messageId path segments (no traversal)", async () => {
    // WHY: defense-in-depth. If Intercom ever sent a conv-id like
    // "../../etc" we must not let it escape the media root. Note: in
    // practice IDs are numeric strings, but never trust the wire.
    const result = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/a.png", contentType: "image/png" }],
      conversationId: "../../../etc",
      mediaRoot: tempRoot,
      messageId: "/../../passwd",
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/a.png": { status: 200, body: PNG_HEADER, contentType: "image/png" },
        }),
      },
    });
    expect(result).toHaveLength(1);
    // The persisted path must remain under tempRoot — sanitization replaced
    // the traversal characters with `_`.
    expect(result[0].path.startsWith(tempRoot)).toBe(true);
    expect(result[0].path).not.toContain("/etc/");
    expect(result[0].path).not.toContain("/passwd");
  });
});

describe("buildMediaExtraContext", () => {
  it("returns an empty object when no attachments persisted", () => {
    // WHY: callers spread this unconditionally. Empty object means no
    // MsgContext mutation — text-only path behaves exactly as before.
    expect(buildMediaExtraContext([])).toEqual({});
  });

  it("produces aligned MediaPaths / MediaUrls / MediaTypes arrays", () => {
    // WHY: openclaw's normalizeAttachments() (runner-*.js) zips these
    // by index. Misaligned arrays = wrong MIME on the wrong image. Lock
    // the ordering invariant.
    const persisted: PersistedAttachment[] = [
      { path: "/state/media/intercom/c/m/0.png", contentType: "image/png", url: "https://cdn/0.png", size: 10 },
      { path: "/state/media/intercom/c/m/1.jpg", contentType: "image/jpeg", url: "https://cdn/1.jpg", size: 20 },
    ];
    expect(buildMediaExtraContext(persisted)).toEqual({
      MediaPaths: ["/state/media/intercom/c/m/0.png", "/state/media/intercom/c/m/1.jpg"],
      MediaUrls: ["https://cdn/0.png", "https://cdn/1.jpg"],
      MediaTypes: ["image/png", "image/jpeg"],
    });
  });
});

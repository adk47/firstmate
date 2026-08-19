import { describe, it, expect, beforeEach, afterEach } from "vitest";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import {
  downloadImageAttachments,
  downloadDocumentAttachments,
  buildMediaExtraContext,
  capMediaEntries,
  detectImageFormatFromBytes,
  MAX_FTYP_SCAN_BYTES,
  type UnreadableAttachment,
  MAX_IMAGE_ATTACHMENTS_PER_TURN,
  MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN,
  MAX_MEDIA_ENTRIES_PER_TURN,
  MAX_PDF_PAGES,
  ATTACHMENT_MAX_BYTES,
  PDF_TEXT_EXTRACT_MAX_BYTES,
  type PersistedAttachment,
} from "../src/attachments.js";
import type { ImageAttachmentRef, DocumentAttachmentRef } from "../src/types.js";

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

function makeFetchStub(
  responses: Record<string, { status: number; body: Buffer; contentType?: string; location?: string }>,
  seenUrls?: string[],
) {
  return async (url: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const key = typeof url === "string" ? url : url.toString();
    seenUrls?.push(key);
    // STUB FIDELITY: real fetch() follows redirects transparently unless the
    // caller opts out. A stub that silently accepts either mode would let the
    // `redirect: "manual"` hardening be deleted with every test still green —
    // so refuse anything else, loudly.
    if (init?.redirect !== "manual") {
      throw new Error(`test stub: fetch must pass redirect:"manual" (got ${String(init?.redirect)}) for ${key}`);
    }
    const r = responses[key];
    if (!r) throw new Error(`test stub: unmapped url ${key}`);
    const headers: Record<string, string> = {};
    if (r.contentType) headers["content-type"] = r.contentType;
    if (r.location) headers["location"] = r.location;
    return new Response(r.body, { status: r.status, headers });
  };
}

/** A valid-but-unique PNG buffer, so hash-dedupe doesn't collapse fixtures. */
function distinctPng(seed: number): Buffer {
  return Buffer.concat([PNG_HEADER, Buffer.from([seed & 0xff, (seed >> 8) & 0xff])]);
}

describe("downloadImageAttachments", () => {
  it("returns empty array when refs is empty", async () => {
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    const { attachments: result, unreadable } = await downloadImageAttachments({
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

  it("lets the BYTES decide the contentType, not the declared or server header", async () => {
    // WHY (changed 2026-08-18): this used to assert the server's Content-Type
    // header won. It doesn't any more — the header is one more claim from an
    // uploader, and uploaders lie. Both the classify-time guess AND the CDN
    // header say jpeg here; the bytes say PNG, so PNG is what we persist and
    // forward. This is the same rule that makes the mislabeled-JPEG-as-HEIC
    // case work, stated on the simplest possible input.
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/img",
      contentType: "image/jpeg", // stale guess
    }];
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    expect(result[0].contentType).toBe("image/png");
    expect(result[0].path).toMatch(/\.png$/);
  });

  it("falls back to the ref-supplied contentType if the server returns a non-image type", async () => {
    // E.g. CDN omits Content-Type or returns octet-stream — trust classify-time.
    const refs: ImageAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/img",
      contentType: "image/png",
    }];
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    tooMany.forEach((r, i) => {
      // DISTINCT bytes per ref: identical bytes are now deduped by SHA-256, so
      // reusing one buffer would collapse all 11 into a single entry and this
      // test would silently stop covering truncation.
      stubResponses[r.url] = { status: 200, body: distinctPng(i), contentType: "image/png" };
    });
    const { attachments: result, unreadable } = await downloadImageAttachments({
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
    const { attachments: result, unreadable } = await downloadImageAttachments({
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

// ---------------------------------------------------------------------------
// PDF document pipeline
//
// Rasterization shells out to a host `pdftoppm` (poppler-utils) via the
// INTERCOM_PDFTOPPM_BIN env var. To keep these tests hermetic and independent
// of whether poppler is installed on the CI runner, we point that var at a
// FAKE pdftoppm: a tiny shell script that parses `-l <last>` + the prefix and
// writes `<prefix>-N.png` for each page, emitting min(last, FAKE_PAGE_COUNT)
// files — mirroring real pdftoppm's "only write pages that exist" behavior.
// The missing-binary degraded path is tested by pointing the var at a
// nonexistent binary.
// ---------------------------------------------------------------------------

const PDF_HEADER = Buffer.from("%PDF-1.4\n%\xff\xff\xff\xff\n", "latin1");
const FAKE_PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);

let fakeBinPath: string | undefined;
let savedBinEnv: string | undefined;
let savedPageCountEnv: string | undefined;

/** Install a fake pdftoppm that writes `pageCount` PNG files (capped by -l). */
async function installFakePdftoppm(pageCount: number): Promise<void> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "fake-pdftoppm-"));
  fakeBinPath = path.join(dir, "pdftoppm");
  // Args we pass: -png -r DPI -f 1 -l LAST <pdf> <prefix>
  // pdftoppm naming: <prefix>-<page>.png
  const script = `#!/usr/bin/env bash
set -e
last=0
prefix=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-l" ]; then last="$a"; fi
  prev="$a"
done
# last positional arg is the prefix
for a in "$@"; do prefix="$a"; done
pages=${pageCount}
if [ "$last" -lt "$pages" ]; then pages="$last"; fi
i=1
while [ "$i" -le "$pages" ]; do
  printf '\\x89PNG\\r\\n\\x1a\\n\\x00' > "\${prefix}-\${i}.png"
  i=$((i+1))
done
`;
  await fs.writeFile(fakeBinPath, script, { mode: 0o755 });
}

beforeEach(() => {
  savedBinEnv = process.env.INTERCOM_PDFTOPPM_BIN;
  savedPageCountEnv = process.env.FAKE_PAGE_COUNT;
});

afterEach(async () => {
  if (savedBinEnv === undefined) delete process.env.INTERCOM_PDFTOPPM_BIN;
  else process.env.INTERCOM_PDFTOPPM_BIN = savedBinEnv;
  if (savedPageCountEnv === undefined) delete process.env.FAKE_PAGE_COUNT;
  else process.env.FAKE_PAGE_COUNT = savedPageCountEnv;
  if (fakeBinPath) {
    await fs.rm(path.dirname(fakeBinPath), { recursive: true, force: true }).catch(() => {});
    fakeBinPath = undefined;
  }
});

describe("downloadDocumentAttachments", () => {
  it("returns empty array when refs is empty", async () => {
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
    });
    expect(result).toEqual([]);
  });

  it("persists the original PDF and rasterizes pages: PNG pages first, original PDF last", async () => {
    await installFakePdftoppm(2);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const refs: DocumentAttachmentRef[] = [{
      url: "https://downloads.intercomcdn.com/i/o/x/doc.pdf",
      contentType: "application/pdf",
    }];
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs,
      conversationId: "conv_pdf",
      mediaRoot: tempRoot,
      messageId: "msg_99",
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/doc.pdf": {
            status: 200,
            body: PDF_HEADER,
            contentType: "application/pdf",
          },
        }),
      },
    });
    // 2 rasterized pages + 1 original PDF = 3 entries.
    expect(result).toHaveLength(3);
    // Ordering: image/png pages first, application/pdf last.
    expect(result.map((r) => r.contentType)).toEqual(["image/png", "image/png", "application/pdf"]);
    // Pages are PNGs on disk under conv + msg dir.
    expect(result[0].path).toContain("conv_pdf");
    expect(result[0].path).toContain("msg_99");
    expect(result[0].path.endsWith(".png")).toBe(true);
    // Original PDF persisted with .pdf extension and the real bytes.
    const pdfEntry = result[2];
    expect(pdfEntry.path.endsWith(".pdf")).toBe(true);
    const onDisk = await fs.readFile(pdfEntry.path);
    expect(onDisk.equals(PDF_HEADER)).toBe(true);
    // Every entry carries the original CDN url as its MediaUrl fallback.
    for (const r of result) {
      expect(r.url).toBe("https://downloads.intercomcdn.com/i/o/x/doc.pdf");
    }
  });

  it("caps rasterization at MAX_PDF_PAGES but still forwards the full original PDF", async () => {
    // Fake doc has more pages than the cap; we should rasterize exactly
    // MAX_PDF_PAGES (because we pass -l MAX_PDF_PAGES) + 1 original = cap+1.
    await installFakePdftoppm(MAX_PDF_PAGES + 5);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/big.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/big.pdf": { status: 200, body: PDF_HEADER, contentType: "application/pdf" },
        }),
      },
    });
    const pngCount = result.filter((r) => r.contentType === "image/png").length;
    const pdfCount = result.filter((r) => r.contentType === "application/pdf").length;
    expect(pngCount).toBe(MAX_PDF_PAGES);
    expect(pdfCount).toBe(1);
  });

  it("rasterized pages come back in page order (1,2,3 not lexical 1,10,2)", async () => {
    // Real concern: readdir order is arbitrary; we sort numerically. With a
    // page count >= 10 a lexical sort would interleave wrong. MAX_PDF_PAGES is
    // 8 today so we can't hit 10 via the cap — but lock the numeric-sort intent
    // for any future cap bump by checking the page suffix order directly.
    await installFakePdftoppm(MAX_PDF_PAGES);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/ordered.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/ordered.pdf": { status: 200, body: PDF_HEADER, contentType: "application/pdf" },
        }),
      },
    });
    const pngPages = result
      .filter((r) => r.contentType === "image/png")
      .map((r) => Number(/-p-(\d+)\.png$/.exec(r.path)?.[1]));
    const sorted = [...pngPages].sort((a, b) => a - b);
    expect(pngPages).toEqual(sorted);
  });

  it("still forwards the original PDF (text path) when rasterization fails (missing pdftoppm)", async () => {
    // Degraded mode: if poppler isn't on node-8, Caroline can't SEE the PDF
    // but document-extract can still READ it. One missing binary must not sink
    // the turn — and the original must still be present for text extraction.
    process.env.INTERCOM_PDFTOPPM_BIN = "/nonexistent/definitely-not-pdftoppm";
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/doc.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/doc.pdf": { status: 200, body: PDF_HEADER, contentType: "application/pdf" },
        }),
      },
    });
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("application/pdf");
    expect(warns.some((w) => w.includes("rasterization failed"))).toBe(true);
  });

  it("returns [] (no entries) when the PDF download itself fails — nothing to forward", async () => {
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/expired.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/expired.pdf": { status: 403, body: Buffer.alloc(0) },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(warns.some((w) => w.includes("status=403"))).toBe(true);
  });

  it("drops an oversized PDF before rasterizing", async () => {
    await installFakePdftoppm(2);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const warns: string[] = [];
    const oversized = Buffer.alloc(ATTACHMENT_MAX_BYTES + 1, 0x25);
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/huge.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/huge.pdf": { status: 200, body: oversized, contentType: "application/pdf" },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(warns.some((w) => w.includes("oversized pdf"))).toBe(true);
  });

  it("PDF over the text-extract limit: forwards rasterized pages (vision) but withholds the original PDF", async () => {
    // WHY: openclaw's document-extract silently skips PDFs over its ~5MB limit,
    // so forwarding a 5-10MB application/pdf entry is a no-op. We still rasterize
    // pages so the agent SEES the doc, but drop the original-PDF text entry.
    await installFakePdftoppm(2);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const infos: string[] = [];
    // Between the text-extract cap (5MB) and the download cap (10MB).
    const big = Buffer.concat([PDF_HEADER, Buffer.alloc(PDF_TEXT_EXTRACT_MAX_BYTES, 0x20)]);
    expect(big.length).toBeGreaterThan(PDF_TEXT_EXTRACT_MAX_BYTES);
    expect(big.length).toBeLessThan(ATTACHMENT_MAX_BYTES);
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/scan.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { info: (m) => infos.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/scan.pdf": { status: 200, body: big, contentType: "application/pdf" },
        }),
      },
    });
    expect(result.filter((r) => r.contentType === "image/png").length).toBe(2);
    expect(result.filter((r) => r.contentType === "application/pdf").length).toBe(0);
    expect(infos.some((m) => m.includes("too large for text extraction"))).toBe(true);
  });

  it("budget limits how many pages a single PDF rasterizes (no wasted render past budget)", async () => {
    // A 20-page PDF with a budget of 3 should rasterize only 3 pages (pdftoppm -l 3)
    // and, since the budget is consumed by pages, forward no original PDF entry.
    await installFakePdftoppm(20);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/long.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      budget: 3,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/long.pdf": { status: 200, body: PDF_HEADER, contentType: "application/pdf" },
        }),
      },
    });
    expect(result.length).toBe(3);
    expect(result.every((r) => r.contentType === "image/png")).toBe(true);
    // Pages 4..20 and the original were NOT forwarded, so the agent is holding
    // 15% of the document. Returning success with no record let it read three
    // pages of a twenty-page contract believing it had the whole thing.
    expect(unreadable).toHaveLength(1);
    expect(unreadable[0].reason).toBe("truncated");
    expect(unreadable[0].partial).toBe(true);
  });

  it("stops downloading further PDFs once the budget is exhausted (no discarded work)", async () => {
    // budget=2, three 8-page PDFs. The first consumes the budget; PDFs 2 and 3
    // must never be fetched or rasterized.
    await installFakePdftoppm(8);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const fetched: string[] = [];
    const urls = [0, 1, 2].map((i) => `https://downloads.intercomcdn.com/i/o/x/d${i}.pdf`);
    const stub = makeFetchStub(Object.fromEntries(urls.map((u) => [u, { status: 200, body: PDF_HEADER, contentType: "application/pdf" }])));
    const tracking = async (url: string | URL | Request, init?: RequestInit) => {
      fetched.push(typeof url === "string" ? url : url.toString());
      return stub(url, init);
    };
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: urls.map((u) => ({ url: u, contentType: "application/pdf" as const })),
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      budget: 2,
      deps: { fetchImpl: tracking, log: { warn: (m) => warns.push(m) } },
    });
    expect(result.length).toBe(2);
    expect(fetched).toEqual([urls[0]]); // only the first PDF was downloaded
    expect(warns.some((w) => w.includes("budget exhausted"))).toBe(true);
  });

  it("downloads nothing on a zero budget but REPORTS the documents it withheld", async () => {
    const fetched: string[] = [];
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/d.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      budget: 0,
      deps: { fetchImpl: async (u) => { fetched.push(String(u)); return new Response(PDF_HEADER); } },
    });
    expect(result).toEqual([]);
    expect(fetched).toEqual([]);
    // Not downloading is fine; staying SILENT about it is not — the agent would
    // otherwise be told (by SOUL.md's "no status block means all good") that
    // the customer sent no document.
    expect(unreadable).toHaveLength(1);
    expect(unreadable[0].reason).toBe("truncated");
  });

  it("caps total download ATTEMPTS even when every PDF fails (no unbounded CDN fetches)", async () => {
    // 20 refs that all 404. Failures don't consume the success budget, so without
    // a separate attempt cap this would fetch all 20 sequentially. We must stop at
    // MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN.
    const fetched: string[] = [];
    const tracking = async (url: string | URL | Request): Promise<Response> => {
      fetched.push(typeof url === "string" ? url : url.toString());
      return new Response("nope", { status: 404 });
    };
    const warns: string[] = [];
    const refs: DocumentAttachmentRef[] = Array.from({ length: 20 }, (_, i) => ({
      url: `https://downloads.intercomcdn.com/i/o/x/bad${i}.pdf`,
      contentType: "application/pdf" as const,
    }));
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs,
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: { fetchImpl: tracking, log: { warn: (m) => warns.push(m) } },
    });
    expect(result).toEqual([]);
    expect(fetched.length).toBe(MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN);
    expect(warns.some((w) => w.includes(`cap=${MAX_DOCUMENT_DOWNLOAD_ATTEMPTS_PER_TURN}`))).toBe(true);
  });

  it("sanitizes path segments so a malicious conv/msg id can't escape the media root", async () => {
    await installFakePdftoppm(1);
    process.env.INTERCOM_PDFTOPPM_BIN = fakeBinPath!;
    const { attachments: result, unreadable } = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/doc.pdf", contentType: "application/pdf" }],
      conversationId: "../../../etc",
      messageId: "/../../passwd",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/doc.pdf": { status: 200, body: PDF_HEADER, contentType: "application/pdf" },
        }),
      },
    });
    expect(result.length).toBeGreaterThan(0);
    for (const r of result) {
      expect(r.path.startsWith(tempRoot)).toBe(true);
      expect(r.path).not.toContain("/etc/");
      expect(r.path).not.toContain("/passwd");
    }
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

  it("preserves a mixed image + rasterized-PDF + original-PDF ordering with aligned arrays", () => {
    // WHY: a customer can send a screenshot AND a PDF in one message. The
    // agent must receive image first, then the PDF's rasterized pages, then
    // the original application/pdf — index-aligned across all three arrays so
    // openclaw's normalizeAttachments() routes each entry to the right path
    // (image/png → vision, application/pdf → document-extract).
    const persisted: PersistedAttachment[] = [
      { path: "/ws/intercom/c/m/0.png", contentType: "image/png", url: "https://cdn/shot.png", size: 10 },
      { path: "/ws/intercom/c/m/8-p-1.png", contentType: "image/png", url: "https://cdn/doc.pdf", size: 20 },
      { path: "/ws/intercom/c/m/8-p-2.png", contentType: "image/png", url: "https://cdn/doc.pdf", size: 21 },
      { path: "/ws/intercom/c/m/8.pdf", contentType: "application/pdf", url: "https://cdn/doc.pdf", size: 99 },
    ];
    expect(buildMediaExtraContext(persisted)).toEqual({
      MediaPaths: [
        "/ws/intercom/c/m/0.png",
        "/ws/intercom/c/m/8-p-1.png",
        "/ws/intercom/c/m/8-p-2.png",
        "/ws/intercom/c/m/8.pdf",
      ],
      MediaUrls: ["https://cdn/shot.png", "https://cdn/doc.pdf", "https://cdn/doc.pdf", "https://cdn/doc.pdf"],
      MediaTypes: ["image/png", "image/png", "image/png", "application/pdf"],
    });
  });
});

describe("capMediaEntries", () => {
  const mk = (n: number, type = "image/png"): PersistedAttachment[] =>
    Array.from({ length: n }, (_, i) => ({ path: `/p/${i}`, contentType: type, url: `https://cdn/${i}`, size: 1 }));

  it("passes through when combined count is within the cap", () => {
    const r = capMediaEntries(mk(2), mk(3));
    expect(r.truncated).toBe(false);
    expect(r.total).toBe(5);
    expect(r.entries.length).toBe(5);
  });

  it("truncates the combined list to MAX_MEDIA_ENTRIES_PER_TURN and reports it", () => {
    // WHY: a single PDF fans out to up to MAX_PDF_PAGES PNGs + 1 original, so a
    // handful of PDFs could otherwise produce dozens of vision attachments. This
    // bounds the per-turn dispatch cost regardless of per-type counts.
    const r = capMediaEntries([], mk(MAX_MEDIA_ENTRIES_PER_TURN + 20, "application/pdf"));
    expect(r.truncated).toBe(true);
    expect(r.total).toBe(MAX_MEDIA_ENTRIES_PER_TURN + 20);
    expect(r.entries.length).toBe(MAX_MEDIA_ENTRIES_PER_TURN);
  });

  it("keeps images first when truncating (vision on the customer's screenshots is prioritized)", () => {
    const images = mk(MAX_MEDIA_ENTRIES_PER_TURN, "image/png");
    const docs = mk(5, "application/pdf");
    const r = capMediaEntries(images, docs);
    expect(r.entries.length).toBe(MAX_MEDIA_ENTRIES_PER_TURN);
    expect(r.entries.every((e) => e.contentType === "image/png")).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// HEIC / HEIF ingestion + byte-sniffing hardening (2026-08-18)
//
// Two independent real-world failures motivated this block:
//   1. A customer's screenshot declared `image/heic` but carrying JPEG bytes
//      was dropped by a positive MIME allowlist, silently, with no log —
//      Caroline answered as if no image had been sent.
//   2. A genuine 18-file Apple HEIC evidence set produced empty OCR for Ops,
//      because nothing in this repo could decode HEIC at all.
//
// Transcoding shells out to `heif-convert` (Debian `libheif-examples`) via
// INTERCOM_HEIF_CONVERT_BIN. Same hermetic pattern as the pdftoppm tests
// above: install a FAKE binary so CI never depends on libheif being present,
// and cover the missing-binary degraded path by pointing the var at a
// nonexistent file.
//
// The HEIC fixture is REAL: `tests/fixtures/apple-multi-image.heic` was
// produced by macOS `sips -s format heic` and is a genuine Apple-encoded
// ISO-BMFF file with 5 items (a `grid` derived image plus its 4 tiles and an
// `iref`) — i.e. exactly the multi-image shape that makes heif-convert write
// `<base>-1.jpg` instead of the output path it was handed.
// ---------------------------------------------------------------------------

const HEIC_FIXTURE = await fs.readFile(
  new URL("./fixtures/apple-multi-image.heic", import.meta.url),
);
const JPEG_BYTES = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
const SVG_BYTES = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>', "utf8");
const HTML_BYTES = Buffer.from("<!DOCTYPE html>\n<html><body>nope</body></html>", "utf8");

type HeifFakeMode = "single" | "multi" | "fail" | "empty";

describe("HEIC ingestion", () => {
  let fakeHeifDir: string | undefined;
  let savedHeifEnv: string | undefined;

  beforeEach(() => {
    savedHeifEnv = process.env.INTERCOM_HEIF_CONVERT_BIN;
  });

  afterEach(async () => {
    if (savedHeifEnv === undefined) delete process.env.INTERCOM_HEIF_CONVERT_BIN;
    else process.env.INTERCOM_HEIF_CONVERT_BIN = savedHeifEnv;
    if (fakeHeifDir) {
      await fs.rm(fakeHeifDir, { recursive: true, force: true }).catch(() => {});
      fakeHeifDir = undefined;
    }
  });

  /**
   * Install a fake heif-convert. The mode is baked into the script (not passed
   * via env) so the stub can't be affected by env leakage between tests.
   *
   *   single — writes exactly the requested <out>.jpg (single-image HEIC)
   *   multi  — ignores <out> and writes <base>-1.jpg + <base>-2.jpg, which is
   *            what real libheif does for a multi-image file
   *   fail   — exits non-zero (corrupt input)
   *   empty  — exits 0 having written a zero-byte file (decoder failure
   *            wearing a success exit code)
   */
  async function installFakeHeifConvert(mode: HeifFakeMode): Promise<void> {
    fakeHeifDir = await fs.mkdtemp(path.join(os.tmpdir(), "fake-heif-convert-"));
    const bin = path.join(fakeHeifDir, "heif-convert");
    const script = `#!/usr/bin/env bash
set -e
out=""
for a in "$@"; do out="$a"; done
base="\${out%.jpg}"
case "${mode}" in
  single) printf '\\xff\\xd8\\xff\\xe0JPEGBODY' > "$out" ;;
  multi)
    printf '\\xff\\xd8\\xff\\xe0PRIMARY' > "\${base}-1.jpg"
    printf '\\xff\\xd8\\xff\\xe0AUXILIARY' > "\${base}-2.jpg"
    ;;
  empty) : > "$out" ;;
  fail) echo "heif-convert: unsupported feature" >&2; exit 1 ;;
esac
`;
    await fs.writeFile(bin, script, { mode: 0o755 });
    process.env.INTERCOM_HEIF_CONVERT_BIN = bin;
  }

  // ---- (i) the "En Alta" case: mislabeled JPEG on the live plugin path ----
  it("handles JPEG bytes declared as image/heic as a JPEG (bytes beat the header)", async () => {
    // WHY: this is the reported production failure. iOS share-sheet uploads
    // routinely re-encode to JPEG while keeping the heic content-type. The
    // decoder must never run here — if it did, a missing/broken libheif would
    // turn a perfectly readable screenshot into an unreadable one. We point
    // the binary at a nonexistent path precisely so that an attempted
    // transcode would fail the assertion below.
    process.env.INTERCOM_HEIF_CONVERT_BIN = "/nonexistent/definitely-not-heif-convert";
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/photo.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/photo.heic": {
            status: 200,
            body: JPEG_BYTES,
            contentType: "image/heic",
          },
        }),
      },
    });
    expect(unreadable).toEqual([]);
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("image/jpeg");
    expect(result[0].path).toMatch(/\.jpg$/);
    expect(result[0].size).toBe(JPEG_BYTES.length);
  });

  // ---- (ii) genuine Apple HEIC with auxiliary/tiled images ----------------
  it("transcodes a genuine multi-image Apple HEIC and forwards the primary JPEG", async () => {
    // WHY: real Apple HEICs are multi-item, and libheif then writes
    // `<base>-1.jpg` / `<base>-2.jpg` INSTEAD of the output path we asked for.
    // Predicting the filename would yield "no output" on every real iPhone
    // photo — the same lesson pdftoppm taught this file. We read the CONVERSION
    // DIRECTORY back (a private, single-use one — see the rerun-isolation tests
    // below), take the primary (lowest-numbered) image, and promote it to the
    // canonical `<index>.jpg`, so callers never see libheif's naming at all.
    await installFakeHeifConvert("multi");
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/IMG_0042.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      messageId: "msg_heic",
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/IMG_0042.heic": {
            status: 200,
            body: HEIC_FIXTURE,
            contentType: "image/heic",
          },
        }),
      },
    });
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("image/jpeg");
    expect(result[0].path).toMatch(/\/0\.jpg$/);
    expect(result[0].size).toBeGreaterThan(0);
    // The auxiliary sibling libheif also wrote (`-2.jpg`) is NOT left behind in
    // the persistent per-message dir — it dies with the private work dir.
    expect(await fs.readdir(path.dirname(result[0].path))).toEqual(
      expect.arrayContaining(["0.heic", "0.jpg"]),
    );
    expect(await fs.readdir(path.dirname(result[0].path))).toHaveLength(2);
    // The transcoded file is really on disk with the bytes we reported.
    const stat = await fs.stat(result[0].path);
    expect(stat.size).toBe(result[0].size);
    // The original .heic is preserved next to it so a human can re-inspect.
    const origDir = path.dirname(result[0].path);
    expect(await fs.readdir(origDir)).toContain("0.heic");
  });

  it("bounds the ftyp compatible-brand scan (a crafted box cannot stall the gateway)", () => {
    // The box size is CUSTOMER-CONTROLLED and the scan walked it 4 bytes at a
    // time, so a 10MB payload declaring a 10MB ftyp box with a generic major
    // brand and no accepted compatible brand ran ~2.6M subarray/toString
    // iterations -- measured at ~186ms per attachment, ~1.5s for a full eight,
    // all SYNCHRONOUS on the single-threaded gateway. Neither bound was ours.
    const buf = Buffer.alloc(10 * 1024 * 1024);
    buf.writeUInt32BE(10 * 1024 * 1024, 0);
    buf.write("ftyp", 4, "latin1");
    buf.write("isom", 8, "latin1");
    const started = Date.now();
    expect(detectImageFormatFromBytes(buf)).toBe("unknown");
    // Generous next to the ~186ms it took unbounded, tight enough that removing
    // the cap cannot pass. The brand test below is the deterministic half.
    expect(Date.now() - started).toBeLessThan(50);
  });

  it("a HEIF brand beyond the scan window is NOT detected (the cap is real, not incidental)", () => {
    // The honest cost of the bound: a brand parked past 256 bytes is missed.
    // Pinned deliberately so the tradeoff is visible and cannot regress silently
    // in either direction, and it matches the shell helper's 256-byte window.
    const far = Buffer.alloc(1024);
    far.writeUInt32BE(1024, 0);
    far.write("ftyp", 4, "latin1");
    far.write("isom", 8, "latin1");
    far.write("heic", MAX_FTYP_SCAN_BYTES + 8, "latin1");
    expect(detectImageFormatFromBytes(far)).toBe("unknown");
    // ...while the same brand INSIDE the window is still found.
    const near = Buffer.alloc(1024);
    near.writeUInt32BE(1024, 0);
    near.write("ftyp", 4, "latin1");
    near.write("isom", 8, "latin1");
    near.write("heic", MAX_FTYP_SCAN_BYTES - 8, "latin1");
    expect(detectImageFormatFromBytes(near)).toBe("heic");
  });

  it("detects the genuine Apple HEIC fixture from its magic bytes", async () => {
    // Guards the sniffer against the fixture itself, not a hand-written header:
    // major brand `heic`, compatible brands `mif1 MiPr miaf MiHB heic`.
    expect(detectImageFormatFromBytes(HEIC_FIXTURE)).toBe("heic");
    expect(HEIC_FIXTURE.subarray(4, 8).toString("latin1")).toBe("ftyp");
  });

  it("still handles a single-image HEIC that writes the exact requested name", async () => {
    await installFakeHeifConvert("single");
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/one.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/one.heic": { status: 200, body: HEIC_FIXTURE, contentType: "image/heic" },
        }),
      },
    });
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("image/jpeg");
    expect(result[0].path).toMatch(/0\.jpg$/);
  });

  // ---- (iii) markup masquerade -------------------------------------------
  it.each([
    ["svg", SVG_BYTES],
    ["html", HTML_BYTES],
  ])("refuses %s markup masquerading as an image (no sanitize-and-forward)", async (_label, body) => {
    // WHY: an SVG is a script-bearing document, not a picture. The only safe
    // handling of "this claimed to be a PNG and isn't" is refusal WITH a
    // reason — sanitizing and forwarding would put attacker-authored markup
    // on the agent's media path.
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/logo.png", contentType: "image/png" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      messageId: "msg_markup",
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/logo.png": { status: 200, body, contentType: "image/png" },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(unreadable).toHaveLength(1);
    expect(unreadable[0].reason).toBe("markup_refused");
    expect(unreadable[0].detectedFormat).toBe("markup");
    expect(warns.some((w) => w.includes("refused markup"))).toBe(true);
    // Refused means NOT persisted — the bytes never land on the media root.
    const convDir = path.join(tempRoot, "intercom", "conv_1", "msg_markup");
    expect(await fs.readdir(convDir)).toEqual([]);
  });

  // ---- (iv) corrupt / truncated ------------------------------------------
  it("reports corrupt/truncated bytes as unreadable without throwing", async () => {
    // WHY: this is the artifact the Ops doctrine requires. "The decoder
    // failed" is only sayable when the pipeline emitted an `unreadable`
    // result; a bare absence of images is NOT evidence of corrupt evidence.
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/truncated.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          // First 6 bytes only: long enough to look like a file, too short to
          // carry a complete `ftyp` box.
          "https://downloads.intercomcdn.com/i/o/x/truncated.heic": {
            status: 200,
            body: HEIC_FIXTURE.subarray(0, 6),
            contentType: "image/heic",
          },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(unreadable).toHaveLength(1);
    expect(unreadable[0].reason).toBe("corrupt_or_unrecognized");
    expect(unreadable[0].declaredContentType).toBe("image/heic");
  });

  it("treats an empty heif-convert output as a decode failure, not a success", async () => {
    // A zero-byte JPEG with exit code 0 is the decoder lying. Forwarding it
    // would give the agent a blank image and no reason to doubt it.
    await installFakeHeifConvert("empty");
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/blank.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/blank.heic": { status: 200, body: HEIC_FIXTURE, contentType: "image/heic" },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(unreadable[0].reason).toBe("heic_decode_failed");
  });

  // ---- (v) missing heif-convert -------------------------------------------
  it("degrades to an explicit unreadable result when heif-convert is missing", async () => {
    // Mirrors the pdftoppm degraded-mode test: a package we forgot to install
    // on node-8 must never throw, never sink the turn, and never be silent.
    // The raw .heic is preserved so a human can still transcode it by hand.
    process.env.INTERCOM_HEIF_CONVERT_BIN = "/nonexistent/definitely-not-heif-convert";
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/IMG_1.heic", contentType: "image/heic" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      messageId: "msg_nobin",
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/IMG_1.heic": { status: 200, body: HEIC_FIXTURE, contentType: "image/heic" },
        }),
      },
    });
    expect(result).toEqual([]);
    expect(unreadable).toHaveLength(1);
    // A MISSING BINARY is a provisioning fault, not a verdict on the file:
    // nothing ever looked at the payload. Reporting it as `heic_decode_failed`
    // made the agent tell the customer we had inspected their photo when we had
    // not installed the decoder.
    expect(unreadable[0].reason).toBe("pipeline_failed");
    expect(unreadable[0].detail).toMatch(/not installed/);
    expect(unreadable[0].path).toMatch(/\.heic$/);
    expect(warns.some((w) => w.includes("heif-convert failed"))).toBe(true);
    // Original bytes really are still on disk.
    const stat = await fs.stat(unreadable[0].path!);
    expect(stat.size).toBe(HEIC_FIXTURE.length);
  });
});

describe("CDN host allowlist across redirects", () => {
  // ---- (vi) redirect off the allowlist ------------------------------------
  it("refuses a redirect that leaves the Intercom CDN host allowlist", async () => {
    // WHY: fetch() follows redirects transparently, so the allowlist enforced
    // at classify time only ever gated the FIRST url. A 302 to any host was
    // followed without a second look — the allowlist was decorative. Every hop
    // is re-checked now, and the off-allowlist host must never be requested.
    const seen: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/redirect.png", contentType: "image/png" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub(
          {
            "https://downloads.intercomcdn.com/i/o/x/redirect.png": {
              status: 302,
              body: Buffer.alloc(0),
              location: "https://evil.example.com/payload.png",
            },
            "https://evil.example.com/payload.png": { status: 200, body: PNG_HEADER, contentType: "image/png" },
          },
          seen,
        ),
      },
    });
    expect(result).toEqual([]);
    expect(unreadable).toHaveLength(1);
    expect(unreadable[0].reason).toBe("redirect_off_allowlist");
    expect(seen).toEqual(["https://downloads.intercomcdn.com/i/o/x/redirect.png"]);
    expect(seen.some((u) => u.includes("evil.example.com"))).toBe(false);
  });

  it("follows a redirect that STAYS on the allowlist", async () => {
    // The allowlist must not become a blanket no-redirects rule: Intercom's
    // own CDN re-signs and redirects within its host family.
    const seen: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://musoai.intercom-attachments-3.com/a.png", contentType: "image/png" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        fetchImpl: makeFetchStub(
          {
            "https://musoai.intercom-attachments-3.com/a.png": {
              status: 302,
              body: Buffer.alloc(0),
              location: "https://downloads.intercomcdn.com/i/o/x/a.png",
            },
            "https://downloads.intercomcdn.com/i/o/x/a.png": { status: 200, body: PNG_HEADER, contentType: "image/png" },
          },
          seen,
        ),
      },
    });
    expect(result).toHaveLength(1);
    expect(result[0].contentType).toBe("image/png");
    expect(seen).toHaveLength(2);
  });
});

describe("attachment dedupe by content hash", () => {
  // ---- (vii) duplicates ----------------------------------------------------
  it("dedupes identical attachments delivered under different URLs", async () => {
    // WHY: filters.ts dedupes by URL, which does not help — the same
    // screenshot delivered on both the structured and the inline branch (or
    // pasted twice) arrives under two distinct signed URLs. Forwarding it
    // twice burns a media slot and doubles vision cost for zero information.
    const infos: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [
        { url: "https://downloads.intercomcdn.com/i/o/x/copy-a.png", contentType: "image/png" },
        { url: "https://downloads.intercomcdn.com/i/o/x/copy-b.png", contentType: "image/png" },
        { url: "https://downloads.intercomcdn.com/i/o/x/other.png", contentType: "image/png" },
      ],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      messageId: "msg_dupe",
      deps: {
        log: { info: (m) => infos.push(m) },
        fetchImpl: makeFetchStub({
          "https://downloads.intercomcdn.com/i/o/x/copy-a.png": { status: 200, body: distinctPng(1), contentType: "image/png" },
          "https://downloads.intercomcdn.com/i/o/x/copy-b.png": { status: 200, body: distinctPng(1), contentType: "image/png" },
          "https://downloads.intercomcdn.com/i/o/x/other.png": { status: 200, body: distinctPng(2), contentType: "image/png" },
        }),
      },
    });
    expect(result).toHaveLength(2);
    // First occurrence wins, in ref order.
    expect(result[0].url).toContain("copy-a.png");
    expect(result[1].url).toContain("other.png");
    expect(infos.some((m) => m.includes("deduped identical attachment"))).toBe(true);
    // The duplicate's file is removed, not left orphaned on disk.
    const convDir = path.join(tempRoot, "intercom", "conv_1", "msg_dupe");
    expect((await fs.readdir(convDir)).sort()).toEqual(["0.png", "2.png"]);
  });
});

describe("size cap is enforced while streaming", () => {
  it("aborts a body that exceeds the cap when no Content-Length is declared", async () => {
    // WHY: the cap used to be checked AFTER `await res.arrayBuffer()`, i.e.
    // the whole body was already in the gateway's heap before we decided it
    // was too big. A chunked response with no Content-Length was completely
    // unbounded. This streams the body in chunks with no declared length and
    // asserts we stop reading past the cap instead of buffering it all.
    const chunk = Buffer.alloc(1024 * 1024, 0x41); // 1MB
    let chunksRead = 0;
    const streamingFetch = async (): Promise<Response> => {
      const body = new ReadableStream<Uint8Array>({
        pull(controller) {
          chunksRead++;
          if (chunksRead > 64) {
            controller.close();
            return;
          }
          controller.enqueue(new Uint8Array(chunk));
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "image/png" } });
    };
    const warns: string[] = [];
    const { attachments: result, unreadable } = await downloadImageAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/chunked.png", contentType: "image/png" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      deps: {
        log: { warn: (m) => warns.push(m) },
        fetchImpl: streamingFetch as unknown as typeof fetch,
      },
    });
    expect(result).toEqual([]);
    expect(unreadable[0].reason).toBe("oversize");
    expect(warns.some((w) => w.includes("oversized image"))).toBe(true);
    // We stopped at the cap (10MB / 1MB chunks = 11 reads), not at the
    // stream's natural end (64 chunks). This is the whole point of the fix.
    expect(chunksRead).toBeLessThanOrEqual(12);
  });
});

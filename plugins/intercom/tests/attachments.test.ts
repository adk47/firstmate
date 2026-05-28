import { describe, it, expect, beforeEach, afterEach } from "vitest";
import os from "node:os";
import fs from "node:fs/promises";
import path from "node:path";
import {
  downloadImageAttachments,
  downloadDocumentAttachments,
  buildMediaExtraContext,
  capMediaEntries,
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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

  it("returns [] when given a zero budget (nothing downloaded)", async () => {
    const fetched: string[] = [];
    const result = await downloadDocumentAttachments({
      refs: [{ url: "https://downloads.intercomcdn.com/i/o/x/d.pdf", contentType: "application/pdf" }],
      conversationId: "conv_1",
      mediaRoot: tempRoot,
      budget: 0,
      deps: { fetchImpl: async (u) => { fetched.push(String(u)); return new Response(PDF_HEADER); } },
    });
    expect(result).toEqual([]);
    expect(fetched).toEqual([]);
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
    const result = await downloadDocumentAttachments({
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
    const result = await downloadDocumentAttachments({
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

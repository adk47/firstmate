import { describe, it, expect, vi } from "vitest";
import { DispatchQueue } from "../src/dispatch-queue.js";

// Deferred promise helper: lets a test hold a batch "in flight" and release it
// on demand — models the real dispatch await (10s-90s) without timers.
function deferred() {
  let resolve!: () => void;
  let reject!: (err: unknown) => void;
  const promise = new Promise<void>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function settle() {
  // Drain the microtask queue a few times so the drain loop advances.
  for (let i = 0; i < 5; i++) await Promise.resolve();
}

// Robust flush for chains with awaits INSIDE runBatch (media resolution): a
// setTimeout(0) hop clears the whole microtask queue between macrotasks, so it
// doesn't matter how deep the promise chain is.
async function flush() {
  for (let i = 0; i < 4; i++) await new Promise((r) => setTimeout(r, 0));
}

describe("DispatchQueue", () => {
  it("starts a 1-item batch immediately when the key is idle", async () => {
    const batches: string[][] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
      },
    });
    expect(q.enqueue("conv-1", "hello")).toBe("started");
    await settle();
    expect(batches).toEqual([["hello"]]);
    expect(q.inFlight("conv-1")).toBe(false);
  });

  it("coalesces items enqueued while a batch is in flight into ONE follow-up batch (FIFO)", async () => {
    const gate = deferred();
    const batches: string[][] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
        if (batches.length === 1) await gate.promise;
      },
    });
    expect(q.enqueue("conv-1", "m1")).toBe("started");
    await settle();
    expect(q.enqueue("conv-1", "m2")).toBe("queued");
    expect(q.enqueue("conv-1", "m3")).toBe("queued");
    expect(q.enqueue("conv-1", "m4")).toBe("queued");
    expect(q.pendingCount("conv-1")).toBe(3);
    gate.resolve();
    await settle();
    expect(batches).toEqual([["m1"], ["m2", "m3", "m4"]]);
  });

  it("never runs two batches concurrently for one key", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const gates: Array<() => void> = [];
    const q = new DispatchQueue<string>({
      runBatch: async () => {
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise<void>((res) => gates.push(res));
        inFlight--;
      },
    });
    q.enqueue("conv-1", "a");
    await settle();
    q.enqueue("conv-1", "b");
    q.enqueue("conv-1", "c");
    await settle();
    while (gates.length > 0) {
      gates.shift()!();
      await settle();
    }
    expect(maxInFlight).toBe(1);
  });

  it("drains independent keys concurrently", async () => {
    const gate = deferred();
    const started: string[] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (key) => {
        started.push(key);
        if (key === "conv-slow") await gate.promise;
      },
    });
    q.enqueue("conv-slow", "s1");
    await settle();
    q.enqueue("conv-fast", "f1");
    await settle();
    // conv-fast ran to completion while conv-slow was still in flight.
    expect(started).toEqual(["conv-slow", "conv-fast"]);
    expect(q.inFlight("conv-slow")).toBe(true);
    expect(q.inFlight("conv-fast")).toBe(false);
    gate.resolve();
    await settle();
  });

  it("a runBatch rejection reaches onError and does NOT wedge the key", async () => {
    const onError = vi.fn();
    const batches: string[][] = [];
    let shouldThrow = true;
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        if (shouldThrow) {
          shouldThrow = false;
          throw new Error("boom");
        }
        batches.push([...batch]);
      },
      onError,
    });
    q.enqueue("conv-1", "dies");
    await settle();
    expect(onError).toHaveBeenCalledTimes(1);
    expect(onError.mock.calls[0][0]).toBe("conv-1");
    // The key is free again: the next message dispatches normally.
    expect(q.enqueue("conv-1", "lives")).toBe("started");
    await settle();
    expect(batches).toEqual([["lives"]]);
  });

  it("cleans up the key entry after a drain (no unbounded map growth)", async () => {
    const q = new DispatchQueue<string>({ runBatch: async () => {} });
    q.enqueue("conv-1", "a");
    await settle();
    expect(q.inFlight("conv-1")).toBe(false);
    expect(q.pendingCount("conv-1")).toBe(0);
    expect(q.size()).toBe(0);
  });

  it("re-entrant enqueue from inside runBatch lands in the NEXT batch (no recursion)", async () => {
    const batches: string[][] = [];
    let reentered = false;
    const q: DispatchQueue<string> = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
        if (!reentered) {
          reentered = true;
          q.enqueue("conv-1", "from-inside");
        }
      },
    });
    q.enqueue("conv-1", "outer");
    await settle();
    expect(batches).toEqual([["outer"], ["from-inside"]]);
  });

  it("clear() empties every queue (account stop)", async () => {
    const gate = deferred();
    const batches: string[][] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
        await gate.promise;
      },
    });
    q.enqueue("conv-1", "a");
    await settle();
    q.enqueue("conv-1", "queued-then-cleared");
    expect(q.clear()).toBe(1); // reports the drop so the caller can log it
    expect(q.pendingCount("conv-1")).toBe(0);
    gate.resolve();
    await settle();
    // The cleared pending item never dispatched.
    expect(batches).toEqual([["a"]]);
  });

  it("runs runBatch's synchronous prefix before the enqueue caller yields", () => {
    // Underpins the channel.ts stop-race fix: runDispatchBatch captures the
    // session reference SYNCHRONOUSLY at the top of runBatch, before its first
    // await (the media resolution). This proves that prefix runs within the
    // synchronous enqueue call — so a concurrent account stop() cannot delete
    // the session map before the capture. If the capture were moved past an
    // await, a stop() during that window would force a fabricated blank session.
    let prefixRan = false;
    const q = new DispatchQueue<string>({
      runBatch: async () => {
        prefixRan = true; // synchronous prefix (stands in for getOrCreateSession)
        await new Promise<void>(() => {}); // never resolves — stands in for the media await
      },
    });
    q.enqueue("conv-1", "x");
    // No await: the synchronous prefix must already have executed.
    expect(prefixRan).toBe(true);
  });

  it("clear() CLOSES the queue: a late enqueue (webhook already in flight at stop) is dropped, never dispatched", async () => {
    // Race found by QA on PR #668: a webhook accepted before stop() can still
    // finish its media download and enqueue AFTER clear() ran — without a
    // closed flag that starts a fresh drain against a fabricated blank
    // session (accountSessions was already deleted) and can reply into a
    // human_takeover conversation.
    const batches: string[][] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
      },
    });
    q.clear();
    expect(q.enqueue("conv-1", "late-webhook")).toBe("dropped");
    await settle();
    expect(batches).toEqual([]);
    expect(q.size()).toBe(0);
  });
});

// Integration-style burst: the queue + batch helpers + media-resolution
// composed exactly the way channel.ts runDispatchBatch wires them (order by
// send time, await each message's mediaReady, then combine). A hanging first
// dispatch, a 3-message burst behind it, then assert the SECOND dispatch
// carries every queued body, the merged media in send order, and the LATEST
// messageId (what the flush log and silent_dispatch page reference).
import {
  combineBatchBodies,
  mergeBatchMedia,
  orderBatch,
  type QueuedInboundMessage,
  type ResolvedInboundMessage,
} from "../src/channel.js";

// Mirror channel.ts runDispatchBatch: order by timestamp, await mediaReady.
async function resolveBatch(unordered: QueuedInboundMessage[]): Promise<ResolvedInboundMessage[]> {
  return Promise.all(
    orderBatch(unordered).map(async ({ mediaReady, ...rest }) => ({ ...rest, media: await mediaReady })),
  );
}

describe("burst coalescing through the channel helpers", () => {
  const att = (p: string) => ({ path: p, url: "u", contentType: "image/png", size: 1 }) as any;
  const qm = (body: string, id: string, ts: number, media: any[] = []): QueuedInboundMessage => ({
    body,
    authorId: "user-1",
    messageId: id,
    timestamp: ts,
    mediaReady: Promise.resolve(media),
    imageRefCount: media.length,
    documentRefCount: 0,
  });

  it("combines a burst behind a hanging dispatch into one follow-up payload", async () => {
    const dispatched: Array<{ body: string; media: string[]; messageId: string; batch: number }> = [];
    const gate = { resolve: () => {} };
    const q = new DispatchQueue<QueuedInboundMessage>({
      runBatch: async (_conv, unordered) => {
        const batch = await resolveBatch(unordered);
        const latest = batch[batch.length - 1];
        dispatched.push({
          body: combineBatchBodies(batch),
          media: mergeBatchMedia(batch).entries.map((e: any) => e.path),
          messageId: latest.messageId,
          batch: batch.length,
        });
        if (dispatched.length === 1) await new Promise<void>((res) => (gate.resolve = res));
      },
    });

    q.enqueue("conv-1", qm("first", "part-1", 1));
    await flush(); // let batch 1 reach its gate await (it now awaits media resolution first)
    q.enqueue("conv-1", qm("second", "part-2", 2, [att("/a.png")]));
    q.enqueue("conv-1", qm("", "part-3", 3, [att("/b.png")]));
    q.enqueue("conv-1", qm("fourth", "part-4", 4));
    gate.resolve();
    await flush();

    expect(dispatched).toHaveLength(2);
    expect(dispatched[1].batch).toBe(3);
    expect(dispatched[1].body).toBe("second\n\n(Customer sent an image with no caption.)\n\nfourth");
    expect(dispatched[1].media).toEqual(["/a.png", "/b.png"]);
    expect(dispatched[1].messageId).toBe("part-4");
  });

  it("an earlier message with a SLOW media download still dispatches before a later text message (QA #668: admission ahead of media prep)", async () => {
    // The bug: media download used to run BEFORE enqueue, so an image message
    // A (created_at=10) could sit downloading while a later text message B
    // (created_at=20) reached an idle queue and dispatched first — reversing
    // send order across dispatches. Now the download is a pending promise and
    // the message is enqueued FIRST, so A holds the queue during its own media
    // await and B is forced to queue behind it.
    const order: string[] = [];
    const q = new DispatchQueue<QueuedInboundMessage>({
      runBatch: async (_conv, unordered) => {
        const batch = await resolveBatch(unordered);
        for (const m of batch) order.push(m.messageId);
      },
    });

    // A enqueued first with a media download that resolves LATER than B arrives.
    let resolveAMedia!: (v: any[]) => void;
    const aMedia = new Promise<any[]>((res) => (resolveAMedia = res));
    const a: QueuedInboundMessage = {
      body: "", authorId: "u", messageId: "A-image", timestamp: 10,
      mediaReady: aMedia, imageRefCount: 1, documentRefCount: 0,
    };
    expect(q.enqueue("conv-1", a)).toBe("started"); // admitted immediately, before media resolves
    await flush(); // batch A reaches its `await aMedia` (still pending)

    // B (later text) arrives while A's media is still downloading → must queue.
    expect(q.enqueue("conv-1", qm("later text", "B-text", 20))).toBe("queued");

    resolveAMedia([att("/a.png")]);
    await flush();

    expect(order).toEqual(["A-image", "B-text"]); // send order preserved, not reversed
  });
});

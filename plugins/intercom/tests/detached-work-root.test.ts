import { describe, it, expect } from "vitest";
import { loadDetachedWebhookWork } from "../src/channel.js";
import { DispatchQueue } from "../src/dispatch-queue.js";

// CONTRACT test against the REAL installed openclaw SDK — no fake `detach`.
//
// The unit tests in dispatch-queue.test.ts inject a stub wrapper, so they
// would keep passing even if `openclaw/plugin-sdk/webhook-request-guards`
// were renamed, removed, or stopped exporting runDetachedWebhookWork. That is
// exactly the scenario that silently restores the 2026-09-10 outage, so it
// needs a test that exercises the real dynamic import.
describe("detached work root: real SDK contract", () => {
  it("resolves runDetachedWebhookWork from the installed openclaw plugin SDK", async () => {
    const resolution = await loadDetachedWebhookWork();

    // If this goes red on a 2026.8+ runtime, the SDK moved the helper and the
    // channel will fall back to inline dispatch (announced, never silent).
    expect(resolution.ok).toBe(true);
    if (!resolution.ok) return; // narrow for TS; the assertion above already failed
    expect(typeof resolution.detach).toBe("function");
  });

  it("the resolved helper actually runs the wrapped work and returns its value", async () => {
    const resolution = await loadDetachedWebhookWork();
    if (!resolution.ok) {
      throw new Error(`detached work root unavailable: ${resolution.detail}`);
    }

    let ran = false;
    const out = await resolution.detach(async () => {
      ran = true;
      return "done";
    });

    expect(ran).toBe(true);
    expect(out).toBe("done");
  });

  it("drives a real DispatchQueue drain through the real helper", async () => {
    // Proves the two halves fit: the SDK's wrapper satisfies the queue's
    // `detach` contract and the batch still runs exactly once inside it.
    const resolution = await loadDetachedWebhookWork();
    if (!resolution.ok) {
      throw new Error(`detached work root unavailable: ${resolution.detail}`);
    }

    const batches: string[][] = [];
    const q = new DispatchQueue<string>({
      runBatch: async (_key, batch) => {
        batches.push([...batch]);
      },
      detach: resolution.detach,
    });

    expect(q.enqueue("conv-1", "a")).toBe("started");
    for (let i = 0; i < 6; i++) await new Promise((r) => setTimeout(r, 0));

    expect(batches).toEqual([["a"]]);
    expect(q.inFlight("conv-1")).toBe(false);
  });
});

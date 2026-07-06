import { describe, it, expect, beforeEach } from "vitest";
import { markTicketFiled } from "../src/ticket-success-signal.js";

// Must match the reader in plugins/intercom/src/ticket-success-signal.ts. Asserting the
// literal key here locks the cross-plugin contract from the writer side.
const SIGNAL_KEY = "__musoSupportTicketSignal";

function readStore(): Map<string, number> | undefined {
  const s = (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
  return s instanceof Map ? (s as Map<string, number>) : undefined;
}

describe("markTicketFiled (writer)", () => {
  beforeEach(() => {
    (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY] = new Map<string, number>();
  });

  it("records the timestamp under the shared globalThis key", () => {
    markTicketFiled("conv_a", 1_000_000);
    expect(readStore()?.get("conv_a")).toBe(1_000_000);
  });

  it("no-ops on an empty/null convId (non-intercom sessions)", () => {
    markTicketFiled(null, 1_000_000);
    markTicketFiled("", 1_000_000);
    expect(readStore()?.size).toBe(0);
  });

  it("opportunistically sweeps entries older than the TTL", () => {
    markTicketFiled("old", 0);
    // 31 min later — past the 30-min TTL, so the sweep on the next write evicts "old".
    markTicketFiled("fresh", 31 * 60_000);
    const store = readStore()!;
    expect(store.has("old")).toBe(false);
    expect(store.get("fresh")).toBe(31 * 60_000);
  });
});

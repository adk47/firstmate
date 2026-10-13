import { describe, it, expect, beforeEach } from "vitest";
import { markTicketFiled, markTicketId } from "../src/ticket-success-signal.js";

// Must match the reader in plugins/intercom/src/ticket-success-signal.ts. Asserting the
// literal key here locks the cross-plugin contract from the writer side.
const SIGNAL_KEY = "__musoSupportTicketSignal";
// Additive twin (MUS-1516 / design call ① on MUS-1471): a NEW key, so SIGNAL_KEY's
// value shape (Map<convId, number>) never has to change.
const IDS_KEY = "__musoSupportTicketIds";

function readStore(): Map<string, number> | undefined {
  const s = (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
  return s instanceof Map ? (s as Map<string, number>) : undefined;
}

function readIdsStore(): Map<string, { atMs: number; ids: string[] }> | undefined {
  const s = (globalThis as unknown as Record<string, unknown>)[IDS_KEY];
  return s instanceof Map ? (s as Map<string, { atMs: number; ids: string[] }>) : undefined;
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

  // AC10 (MUS-1516): the shipped Map<convId, number> value shape must stay untouched —
  // a repointed value shape would open a deploy-skew window where the working guard
  // misreads a live object as a lost signal (design call ① on MUS-1471). Pin it: after
  // markTicketId also runs, the ORIGINAL signal is still a bare number.
  it("markTicketId (the new sibling store) never changes the shape of THIS store", () => {
    markTicketFiled("conv_shape", 1_000_000);
    markTicketId("conv_shape", "869f7v9v2", 1_000_000);
    expect(readStore()?.get("conv_shape")).toBe(1_000_000);
    expect(typeof readStore()?.get("conv_shape")).toBe("number");
  });
});

describe("markTicketId (writer, MUS-1516 additive store)", () => {
  beforeEach(() => {
    (globalThis as unknown as Record<string, unknown>)[IDS_KEY] = new Map();
  });

  it("records the ticket id under a NEW globalThis key, separate from the signal store", () => {
    markTicketId("conv_a", "869f7v9v2", 1_000_000);
    const entry = readIdsStore()?.get("conv_a");
    expect(entry).toEqual({ atMs: 1_000_000, ids: ["869f7v9v2"] });
  });

  it("accumulates multiple ids filed for the same conversation without duplicates", () => {
    markTicketId("conv_a", "869f7v9v2", 1_000_000);
    markTicketId("conv_a", "869f7va3b", 1_000_100);
    markTicketId("conv_a", "869f7v9v2", 1_000_200); // repeat — must not duplicate
    const entry = readIdsStore()?.get("conv_a");
    expect(entry?.ids).toEqual(["869f7v9v2", "869f7va3b"]);
    expect(entry?.atMs).toBe(1_000_200); // refreshed on the latest write
  });

  it("no-ops on an empty/null convId or ticketId", () => {
    markTicketId(null, "869f7v9v2", 1_000_000);
    markTicketId("conv_a", null, 1_000_000);
    markTicketId("conv_a", "", 1_000_000);
    expect(readIdsStore()?.size).toBe(0);
  });

  it("opportunistically sweeps entries older than the TTL (same pattern as markTicketFiled)", () => {
    markTicketId("old", "869f7v9v2", 0);
    markTicketId("fresh", "869f7va3b", 31 * 60_000);
    const store = readIdsStore()!;
    expect(store.has("old")).toBe(false);
    expect(store.get("fresh")?.ids).toEqual(["869f7va3b"]);
  });
});

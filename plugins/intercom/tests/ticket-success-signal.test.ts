import { describe, it, expect, beforeEach } from "vitest";
import { wasTicketFiledRecently, getFiledTicketIds } from "../src/ticket-success-signal.js";

// The contract between this reader and the support-tools writer is the globalThis key
// name + value shape (Map<convId, lastSuccessMs>). Assert the literal key here so a
// rename on either side is caught.
const SIGNAL_KEY = "__musoSupportTicketSignal";
// Additive twin (MUS-1516 / design call ① on MUS-1471): a NEW key + shape
// (Map<convId, {atMs, ids:string[]}>), so SIGNAL_KEY above is untouched.
const IDS_KEY = "__musoSupportTicketIds";

function setSignal(convId: string, ms: number): void {
  const g = globalThis as unknown as Record<string, unknown>;
  const s = (g[SIGNAL_KEY] instanceof Map ? g[SIGNAL_KEY] : new Map()) as Map<string, number>;
  s.set(convId, ms);
  g[SIGNAL_KEY] = s;
}

function setIds(convId: string, ids: string[], atMs: number): void {
  const g = globalThis as unknown as Record<string, unknown>;
  const s = (g[IDS_KEY] instanceof Map ? g[IDS_KEY] : new Map()) as Map<string, { atMs: number; ids: string[] }>;
  s.set(convId, { atMs, ids });
  g[IDS_KEY] = s;
}

describe("wasTicketFiledRecently (reader)", () => {
  beforeEach(() => {
    (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY] = new Map<string, number>();
  });

  it("returns true when a ticket was filed within the window", () => {
    const now = 1_000_000;
    setSignal("conv_a", now - 60_000); // 1 min ago
    expect(wasTicketFiledRecently("conv_a", now)).toBe(true);
  });

  it("returns false once the signal is older than the window", () => {
    const now = 1_000_000;
    setSignal("conv_a", now - 3 * 60_000); // 3 min ago, default window is 2 min
    expect(wasTicketFiledRecently("conv_a", now)).toBe(false);
  });

  it("returns false for an unknown conversation", () => {
    expect(wasTicketFiledRecently("conv_never", 1_000_000)).toBe(false);
  });

  it("returns false (fail-safe) on an empty convId or missing store", () => {
    expect(wasTicketFiledRecently(null, 1_000_000)).toBe(false);
    expect(wasTicketFiledRecently("", 1_000_000)).toBe(false);
    delete (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
    expect(wasTicketFiledRecently("conv_a", 1_000_000)).toBe(false);
  });
});

describe("getFiledTicketIds (reader, MUS-1516 additive store)", () => {
  beforeEach(() => {
    (globalThis as unknown as Record<string, unknown>)[IDS_KEY] = new Map();
  });

  it("returns the filed ids for a conversation within the window", () => {
    const now = 1_000_000;
    setIds("conv_a", ["869f7v9v2", "869f7va3b"], now - 60_000); // 1 min ago
    expect(getFiledTicketIds("conv_a", now)).toEqual(["869f7v9v2", "869f7va3b"]);
  });

  it("returns [] once the entry is older than the window (same window as wasTicketFiledRecently)", () => {
    const now = 1_000_000;
    setIds("conv_a", ["869f7v9v2"], now - 3 * 60_000); // 3 min ago, default window is 2 min
    expect(getFiledTicketIds("conv_a", now)).toEqual([]);
  });

  it("returns [] for an unknown conversation", () => {
    expect(getFiledTicketIds("conv_never", 1_000_000)).toEqual([]);
  });

  // Design call ② (MUS-1471): a missing/stale store must fail closed — the outbound
  // guard treats [] as "no id is backed", never as "skip the check".
  it("returns [] (fail-safe) on an empty convId or missing store", () => {
    expect(getFiledTicketIds(null, 1_000_000)).toEqual([]);
    expect(getFiledTicketIds("", 1_000_000)).toEqual([]);
    delete (globalThis as unknown as Record<string, unknown>)[IDS_KEY];
    expect(getFiledTicketIds("conv_a", 1_000_000)).toEqual([]);
  });
});

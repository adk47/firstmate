import { describe, it, expect, beforeEach } from "vitest";
import { wasTicketFiledRecently } from "../src/ticket-success-signal.js";

// The contract between this reader and the support-tools writer is the globalThis key
// name + value shape (Map<convId, lastSuccessMs>). Assert the literal key here so a
// rename on either side is caught.
const SIGNAL_KEY = "__musoSupportTicketSignal";

function setSignal(convId: string, ms: number): void {
  const g = globalThis as unknown as Record<string, unknown>;
  const s = (g[SIGNAL_KEY] instanceof Map ? g[SIGNAL_KEY] : new Map()) as Map<string, number>;
  s.set(convId, ms);
  g[SIGNAL_KEY] = s;
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

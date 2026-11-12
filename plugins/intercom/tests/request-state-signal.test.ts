import { beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { readOpenRequestFact, resetOpenRequestFact } from "../src/request-state-signal.js";

// The contract with the support-tools writer is the globalThis key name and the value shape
// (Map<convId, {atMs, open}>). The literal is asserted here AND read out of the writer's source,
// so a rename on either side fails this file.
const SIGNAL_KEY = "__musoSupportRequestState";
const g = globalThis as unknown as Record<string, unknown>;
const NOW = 1_800_000_000_000;
const set = (convId: string, v: unknown) => {
  if (!(g[SIGNAL_KEY] instanceof Map)) g[SIGNAL_KEY] = new Map();
  (g[SIGNAL_KEY] as Map<string, unknown>).set(convId, v);
};

describe("readOpenRequestFact (reader)", () => {
  beforeEach(() => {
    delete g[SIGNAL_KEY];
  });

  it("the writer in support-tools uses the same key and a TTL no shorter than this reader's window", () => {
    const writer = readFileSync(new URL("../../support-tools/src/request-state-signal.ts", import.meta.url), "utf8");
    const reader = readFileSync(new URL("../src/request-state-signal.ts", import.meta.url), "utf8");
    expect(writer).toContain(`const SIGNAL_KEY = "${SIGNAL_KEY}";`);
    expect(reader).toContain(`const SIGNAL_KEY = "${SIGNAL_KEY}";`);
    const ms = (src: string, name: string) => {
      const m = src.match(new RegExp(`const ${name} = (\\d+) \\* 60_000;`));
      expect(m, name).not.toBeNull();
      return Number(m![1]);
    };
    expect(ms(reader, "WINDOW_MS")).toBeLessThanOrEqual(ms(writer, "TTL_MS"));
  });

  it("three answers: measured open, measured none, not measured", () => {
    set("c1", { atMs: NOW - 1000, open: true });
    set("c2", { atMs: NOW - 1000, open: false });
    expect(readOpenRequestFact("c1", NOW)).toBe(true);
    expect(readOpenRequestFact("c2", NOW)).toBe(false);
    expect(readOpenRequestFact("c3", NOW)).toBeUndefined();
  });

  it("not measured is undefined, never false: no store, no conversation, another conversation's row", () => {
    expect(readOpenRequestFact("c1", NOW)).toBeUndefined();
    expect(readOpenRequestFact("", NOW)).toBeUndefined();
    expect(readOpenRequestFact(null, NOW)).toBeUndefined();
    set("other", { atMs: NOW, open: true });
    expect(readOpenRequestFact("c1", NOW)).toBeUndefined();
  });

  it("a stale measurement, or one stamped in the future, is not a measurement", () => {
    set("c1", { atMs: NOW - 10 * 60_000 - 1, open: true });
    set("c2", { atMs: NOW + 1, open: true });
    set("c3", { atMs: NOW - 10 * 60_000, open: true });
    expect(readOpenRequestFact("c1", NOW)).toBeUndefined();
    expect(readOpenRequestFact("c2", NOW)).toBeUndefined();
    expect(readOpenRequestFact("c3", NOW)).toBe(true);
  });

  it("a foreign shape never licenses the status line", () => {
    for (const v of [true, 1, "true", null, {}, { atMs: NOW }, { open: true }, { atMs: "x", open: true }, { atMs: NOW, open: "true" }, { atMs: NOW, open: 1 }]) {
      set("c1", v);
      expect(readOpenRequestFact("c1", NOW), JSON.stringify(v)).toBeUndefined();
    }
    g[SIGNAL_KEY] = { c1: { atMs: NOW, open: true } };
    expect(readOpenRequestFact("c1", NOW)).toBeUndefined();
  });

  it("reset forgets this conversation only, and is safe with no store", () => {
    resetOpenRequestFact("c1");
    set("c1", { atMs: NOW, open: true });
    set("c2", { atMs: NOW, open: true });
    resetOpenRequestFact("c1");
    resetOpenRequestFact(null);
    expect(readOpenRequestFact("c1", NOW)).toBeUndefined();
    expect(readOpenRequestFact("c2", NOW)).toBe(true);
  });
});

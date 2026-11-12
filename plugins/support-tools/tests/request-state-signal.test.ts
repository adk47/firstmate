import { describe, it, expect, beforeEach } from "vitest";
import { markOpenRequestFact, clearOpenRequestFact } from "../src/request-state-signal.js";

// Writer half of the `open_request` fact. The reader lives in another bundle
// (plugins/intercom/src/request-state-signal.ts) and the two agree ONLY on this globalThis key
// and value shape, so the key is a literal here: a rename on either side fails a test.
const SIGNAL_KEY = "__musoSupportRequestState";
const store = () => (globalThis as any)[SIGNAL_KEY] as Map<string, { atMs: number; open: boolean }> | undefined;

beforeEach(() => {
  delete (globalThis as any)[SIGNAL_KEY];
});

describe("request-state-signal (writer)", () => {
  it("records the measured boolean under the conversation id, in the shape the reader expects", () => {
    markOpenRequestFact("c1", true, 1000);
    markOpenRequestFact("c2", false, 2000);
    expect(store()).toBeInstanceOf(Map);
    expect(store()!.get("c1")).toEqual({ atMs: 1000, open: true });
    expect(store()!.get("c2")).toEqual({ atMs: 2000, open: false });
  });

  it("never coerces 'could not measure' into a fact: empty conv id and non-boolean values write nothing", () => {
    markOpenRequestFact("", true, 1000);
    markOpenRequestFact(null, true, 1000);
    markOpenRequestFact("c1", undefined as unknown as boolean, 1000);
    markOpenRequestFact("c1", null as unknown as boolean, 1000);
    markOpenRequestFact("c1", "true" as unknown as boolean, 1000);
    expect(store()?.size ?? 0).toBe(0);
  });

  it("clear forgets one conversation only", () => {
    markOpenRequestFact("c1", true, 1000);
    markOpenRequestFact("c2", true, 1000);
    clearOpenRequestFact("c1");
    expect(store()!.has("c1")).toBe(false);
    expect(store()!.has("c2")).toBe(true);
  });

  it("prunes entries older than the 10 minute TTL on the next write", () => {
    markOpenRequestFact("old", true, 0);
    markOpenRequestFact("new", true, 10 * 60_000 + 1);
    expect(store()!.has("old")).toBe(false);
    expect(store()!.has("new")).toBe(true);
  });
});

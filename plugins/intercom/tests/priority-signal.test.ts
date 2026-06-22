import { describe, it, expect } from "vitest";
import {
  PRIORITY_SENTINEL,
  PRIORITY_PAGED_TAG,
  detectPrioritySignal,
  stripPrioritySentinel,
} from "../src/priority-signal.js";

describe("detectPrioritySignal", () => {
  it("fires on the bare token with a null reason", () => {
    expect(detectPrioritySignal(`Help is on the way. ${PRIORITY_SENTINEL}`)).toEqual({
      fired: true,
      reason: null,
    });
  });

  it("captures the reason after the colon", () => {
    expect(
      detectPrioritySignal("I've raised this. [[PRIORITY: missing 40 credits]]"),
    ).toEqual({ fired: true, reason: "missing 40 credits" });
  });

  it("is case-insensitive and tolerates inner whitespace", () => {
    expect(detectPrioritySignal("[[ priority :  stream counts wrong ]]")).toEqual({
      fired: true,
      reason: "stream counts wrong",
    });
  });

  it("fires with a null reason when the reason is whitespace-only", () => {
    // The token is present, so it fires; an empty/whitespace reason normalizes
    // to null (the Slack page falls back to a generic gist).
    expect(detectPrioritySignal("[[PRIORITY: ]]")).toEqual({ fired: true, reason: null });
  });

  it("does not fire on a normal reply", () => {
    expect(detectPrioritySignal("Your credits look correct from what I can see.")).toEqual({
      fired: false,
      reason: null,
    });
  });

  it("does not confuse the NO_REPLY sentinel for a priority signal", () => {
    expect(detectPrioritySignal("[[NO_REPLY]]")).toEqual({ fired: false, reason: null });
  });

  it("returns the first token's reason when several are present (defensive)", () => {
    expect(
      detectPrioritySignal("[[PRIORITY: first]] and [[PRIORITY: second]]"),
    ).toEqual({ fired: true, reason: "first" });
  });

  it("does not leak regex lastIndex across calls", () => {
    const s = "x [[PRIORITY: r]]";
    expect(detectPrioritySignal(s).fired).toBe(true);
    expect(detectPrioritySignal(s).fired).toBe(true);
  });
});

describe("stripPrioritySentinel", () => {
  it("removes the bare token and trims", () => {
    expect(stripPrioritySentinel(`Sure thing! ${PRIORITY_SENTINEL}`)).toBe("Sure thing!");
  });

  it("removes a token with a reason payload", () => {
    expect(
      stripPrioritySentinel("I've raised this straight to the top. [[PRIORITY: wrong credits]]"),
    ).toBe("I've raised this straight to the top.");
  });

  it("removes every occurrence", () => {
    expect(stripPrioritySentinel("[[PRIORITY: a]]x[[PRIORITY]]y")).toBe("xy");
  });

  it("leaves normal text untouched", () => {
    expect(stripPrioritySentinel("No token here")).toBe("No token here");
  });

  it("empties a reply that is only the token (so the caller can skip posting)", () => {
    expect(stripPrioritySentinel(PRIORITY_SENTINEL)).toBe("");
    expect(stripPrioritySentinel("[[PRIORITY: only]]")).toBe("");
  });

  it("never strips the NO_REPLY sentinel", () => {
    expect(stripPrioritySentinel("[[NO_REPLY]]")).toBe("[[NO_REPLY]]");
  });
});

describe("PRIORITY_PAGED_TAG", () => {
  it("is the cross-lane dedup key the Lane B watchdog also hardcodes", () => {
    // If this string changes, scripts/intercom-data-complaint-watchdog.py must
    // change in lockstep — they are the two ends of the dedup contract.
    expect(PRIORITY_PAGED_TAG).toBe("ai:priority-paged");
  });
});

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { isCreditVerificationSession } from "../src/context.js";
import { cvSessions } from "../src/state.js";

describe("isCreditVerificationSession", () => {
  beforeEach(() => {
    cvSessions.clear();
  });
  afterEach(() => {
    cvSessions.clear();
  });

  it("returns true when sessionKey is in cvSessions", () => {
    cvSessions.add("session-A");
    expect(isCreditVerificationSession("session-A", undefined)).toBe(true);
  });

  it("returns true when runId is set (batch mode)", () => {
    expect(isCreditVerificationSession(undefined, "20260415-091447-c6c924")).toBe(true);
    expect(isCreditVerificationSession("unknown-session", "run-1")).toBe(true);
  });

  it("returns false when sessionKey not marked and no runId", () => {
    expect(isCreditVerificationSession("session-unknown", undefined)).toBe(false);
    expect(isCreditVerificationSession(undefined, undefined)).toBe(false);
  });

  it("returns false when sessionKey is undefined and no runId (defensive)", () => {
    expect(isCreditVerificationSession(undefined, undefined)).toBe(false);
  });
});

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

  it("returns true for the operations agent regardless of sessionKey/runId (issue #152)", () => {
    // @-mention flows in #credit-verification don't re-trigger inbound_claim
    // against the in-memory cvSessions Set (cleared on gateway restart), and
    // runId only gets set on cron-triggered batch runs. The operations agent
    // is CV-scoped as a whole — any tool call from it is in-context.
    expect(isCreditVerificationSession(undefined, undefined, "operations")).toBe(true);
    expect(isCreditVerificationSession("unknown", undefined, "operations")).toBe(true);
  });

  it("returns false for non-operations agents with no other CV signal", () => {
    expect(isCreditVerificationSession(undefined, undefined, "ceo")).toBe(false);
    expect(isCreditVerificationSession(undefined, undefined, "support")).toBe(false);
    // operations-dev was retired with the dev profile — it's no longer
    // a CV agent and should not get free passage.
    expect(isCreditVerificationSession(undefined, undefined, "operations-dev")).toBe(false);
  });

  it("returns false when sessionKey not marked and no runId", () => {
    expect(isCreditVerificationSession("session-unknown", undefined)).toBe(false);
    expect(isCreditVerificationSession(undefined, undefined)).toBe(false);
  });

  it("returns false when sessionKey is undefined and no runId (defensive)", () => {
    expect(isCreditVerificationSession(undefined, undefined)).toBe(false);
  });
});

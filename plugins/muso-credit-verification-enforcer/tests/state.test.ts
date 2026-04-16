import { describe, it, expect, beforeEach } from "vitest";
import { cvSessions, markCvSession, unmarkCvSession } from "../src/state.js";

describe("cvSessions", () => {
  beforeEach(() => cvSessions.clear());

  it("markCvSession adds a sessionKey to the set", () => {
    markCvSession("session-A");
    expect(cvSessions.has("session-A")).toBe(true);
  });

  it("markCvSession is idempotent", () => {
    markCvSession("session-A");
    markCvSession("session-A");
    expect(cvSessions.size).toBe(1);
  });

  it("unmarkCvSession removes a sessionKey", () => {
    markCvSession("session-A");
    unmarkCvSession("session-A");
    expect(cvSessions.has("session-A")).toBe(false);
  });

  it("unmarkCvSession on unknown key is a no-op", () => {
    expect(() => unmarkCvSession("nope")).not.toThrow();
    expect(cvSessions.size).toBe(0);
  });
});

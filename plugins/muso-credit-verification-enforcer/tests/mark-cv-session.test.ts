import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { markCvSessionHook } from "../src/hooks/mark-cv-session.js";
import { cvSessions } from "../src/state.js";

const CV_CHANNEL = "C0APB2CMM7C";

const buildEvent = () => ({
  content: "hi",
  channel: "slack",
  isGroup: false,
});

describe("markCvSessionHook", () => {
  beforeEach(() => {
    cvSessions.clear();
    delete process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID;
  });
  afterEach(() => {
    cvSessions.clear();
    delete process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID;
  });

  it("marks sessionKey as CV when channelId matches the default CV channel", () => {
    markCvSessionHook(buildEvent(), { channelId: CV_CHANNEL, sessionKey: "session-A" });
    expect(cvSessions.has("session-A")).toBe(true);
  });

  it("respects OPS_CREDIT_VERIFICATION_CHANNEL_ID env override", () => {
    process.env.OPS_CREDIT_VERIFICATION_CHANNEL_ID = "C-OVERRIDE";
    markCvSessionHook(buildEvent(), { channelId: "C-OVERRIDE", sessionKey: "session-B" });
    expect(cvSessions.has("session-B")).toBe(true);
    markCvSessionHook(buildEvent(), { channelId: CV_CHANNEL, sessionKey: "session-C" });
    expect(cvSessions.has("session-C")).toBe(false);
  });

  it("does NOT mark sessionKey when channelId is a different channel", () => {
    markCvSessionHook(buildEvent(), { channelId: "C-OTHER", sessionKey: "session-X" });
    expect(cvSessions.has("session-X")).toBe(false);
  });

  it("does NOT mark when sessionKey is undefined", () => {
    markCvSessionHook(buildEvent(), { channelId: CV_CHANNEL });
    expect(cvSessions.size).toBe(0);
  });

  it("returns undefined (observe only, does not claim)", () => {
    const r = markCvSessionHook(buildEvent(), { channelId: CV_CHANNEL, sessionKey: "session-A" });
    expect(r).toBeUndefined();
  });
});

import { describe, it, expect } from "vitest";
import {
  detectSilentDispatch,
  buildSilentDispatchSlackPayload,
} from "../src/silent-dispatch.js";
import { createInitialSessionState } from "../src/handoff.js";
import type { IntercomAccountConfig, IntercomSessionState } from "../src/types.js";

function makeActiveState(): IntercomSessionState {
  const s = createInitialSessionState("conv_42", "ws_1");
  s.handoffMode = "agent_active";
  s.lifecycleState = "open";
  return s;
}

const account: IntercomAccountConfig = {
  enabled: true,
  workspaceId: "wkspc",
  token: "",
  webhookSecret: "",
  botAdminId: "5763097",
  defaultInboxId: "0",
  fallbackSlackSupervisionChannel: "https://hooks.slack.example/x",
  fallbackAcknowledgement: "",
  requireMappedHumanAdmin: false,
  adminMapping: {},
};

describe("detectSilentDispatch", () => {
  it("flags silent when no chunks produced and conv was still replyable", () => {
    const r = detectSilentDispatch({
      bufferedChunks: [],
      state: makeActiveState(),
      droppedMidStream: false,
    });
    expect(r).toEqual({ silent: true, reason: "zero_chunks_after_dispatch" });
  });

  it("does not flag when chunks were produced", () => {
    expect(
      detectSilentDispatch({
        bufferedChunks: ["hi"],
        state: makeActiveState(),
        droppedMidStream: false,
      }),
    ).toEqual({ silent: false });
  });

  it("does not flag when chunks were dropped mid-stream (already logged)", () => {
    expect(
      detectSilentDispatch({
        bufferedChunks: [],
        state: makeActiveState(),
        droppedMidStream: true,
      }),
    ).toEqual({ silent: false });
  });

  it("does not flag when human took over before dispatch completed", () => {
    const s = makeActiveState();
    s.handoffMode = "human_takeover";
    expect(
      detectSilentDispatch({
        bufferedChunks: [],
        state: s,
        droppedMidStream: false,
      }),
    ).toEqual({ silent: false });
  });

  it("does not flag when conversation closed before dispatch completed", () => {
    const s = makeActiveState();
    s.lifecycleState = "closed";
    expect(
      detectSilentDispatch({
        bufferedChunks: [],
        state: s,
        droppedMidStream: false,
      }),
    ).toEqual({ silent: false });
  });
});

describe("buildSilentDispatchSlackPayload", () => {
  it("includes conv link, reason, and conv id with ALERT marker", () => {
    const payload = buildSilentDispatchSlackPayload({
      conversationId: "215474272769722",
      reason: "zero_chunks_after_dispatch",
      account,
    });
    expect(payload.text).toContain("Intercom silent dispatch");
    expect(payload.text).toContain("215474272769722");
    expect(JSON.stringify(payload)).toContain(
      "https://app.intercom.com/a/inbox/wkspc/inbox/conversation/215474272769722",
    );
    expect(JSON.stringify(payload)).toContain("zero_chunks_after_dispatch");
  });

  it("includes the thrown-error reason variant with the message snippet", () => {
    const payload = buildSilentDispatchSlackPayload({
      conversationId: "c1",
      reason: "dispatch_threw",
      errorMessage: "ECONNRESET on gateway WS",
      account,
    });
    expect(JSON.stringify(payload)).toContain("dispatch_threw");
    expect(JSON.stringify(payload)).toContain("ECONNRESET");
  });
});

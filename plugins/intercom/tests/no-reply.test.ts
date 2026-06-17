import { describe, it, expect } from "vitest";
import {
  NO_REPLY_SENTINEL,
  isIntentionalNoReply,
  stripNoReplySentinel,
} from "../src/no-reply.js";
import { detectSilentDispatch } from "../src/silent-dispatch.js";
import { createInitialSessionState } from "../src/handoff.js";
import type { IntercomSessionState } from "../src/types.js";

function makeActiveState(): IntercomSessionState {
  const s = createInitialSessionState("conv_99", "ws_1");
  s.handoffMode = "agent_active";
  s.lifecycleState = "open";
  return s;
}

describe("isIntentionalNoReply", () => {
  it("is true when the whole reply is exactly the sentinel", () => {
    expect(isIntentionalNoReply(NO_REPLY_SENTINEL)).toBe(true);
  });

  it("tolerates surrounding whitespace/newlines", () => {
    expect(isIntentionalNoReply("  [[NO_REPLY]]  ")).toBe(true);
    expect(isIntentionalNoReply("\n[[NO_REPLY]]\n")).toBe(true);
  });

  it("is case-insensitive and tolerates inner spacing", () => {
    expect(isIntentionalNoReply("[[ no_reply ]]")).toBe(true);
  });

  it("is false for a normal reply", () => {
    expect(isIntentionalNoReply("Got it")).toBe(false);
  });

  it("is false when the sentinel is mixed with real text (we still post the text)", () => {
    expect(isIntentionalNoReply("Sure thing! [[NO_REPLY]]")).toBe(false);
  });

  it("is false for an empty/blank reply (that is a genuine zero-output, not a choice)", () => {
    expect(isIntentionalNoReply("")).toBe(false);
    expect(isIntentionalNoReply("   ")).toBe(false);
  });
});

describe("stripNoReplySentinel", () => {
  it("drops a stray sentinel from mixed content and trims", () => {
    expect(stripNoReplySentinel("Sure thing! [[NO_REPLY]]")).toBe("Sure thing!");
  });

  it("removes every occurrence", () => {
    expect(stripNoReplySentinel("[[NO_REPLY]]a[[NO_REPLY]]b")).toBe("ab");
  });

  it("leaves normal text untouched", () => {
    expect(stripNoReplySentinel("Hello there")).toBe("Hello there");
  });
});

describe("no-reply turn does not trip the silent_dispatch alarm", () => {
  it("stays silent:false because the sentinel was a produced (buffered) chunk", () => {
    // A deliberate no-reply turn DID produce output (the sentinel), so the
    // #280 zero-output alarm must not fire even though channel.ts posts nothing.
    // This is what keeps "Caroline chose silence" distinct from "Caroline broke".
    expect(
      detectSilentDispatch({
        bufferedChunks: [NO_REPLY_SENTINEL],
        state: makeActiveState(),
        droppedMidStream: false,
      }),
    ).toEqual({ silent: false });
  });
});

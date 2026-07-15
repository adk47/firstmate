import { describe, it, expect } from "vitest";
import {
  MODEL_FALLBACK_NOTICE_RE,
  stripModelFallbackNotice,
  findModelFallbackNotices,
  isOnlyModelFallbackNotice,
} from "../src/sanitize-model-fallback.js";
import { isIntentionalNoReply, stripNoReplySentinel } from "../src/no-reply.js";
import { detectSilentDispatch } from "../src/silent-dispatch.js";
import { createInitialSessionState } from "../src/handoff.js";
import type { IntercomSessionState } from "../src/types.js";

function makeActiveState(): IntercomSessionState {
  const s = createInitialSessionState("conv_mf", "ws_1");
  s.handoffMode = "agent_active";
  s.lifecycleState = "open";
  return s;
}

// The exact notice that leaked to a customer (incident 2026-06-19), as OpenClaw
// emits it: single line, leading ↪️, prepended ahead of the real reply.
const LEAKED_NOTICE =
  "↪️ Model Fallback: openrouter/openai/gpt-5.4-mini (selected openai/gpt-5.5; auth)";
const REAL_REPLY =
  "Hi Nitin – I've flagged this for review, and it's now on the team's radar. You should hear back within 2 business days.";

describe("stripModelFallbackNotice", () => {
  it("strips the exact leaked notice prepended to a real reply", () => {
    const body = `${LEAKED_NOTICE}\n\n${REAL_REPLY}`;
    expect(stripModelFallbackNotice(body)).toBe(REAL_REPLY);
  });

  it("strips the notice even after an earlier pass removed the ↪️ emoji", () => {
    const body = `Model Fallback: openrouter/openai/gpt-5.4-mini (selected openai/gpt-5.5; auth)\n\n${REAL_REPLY}`;
    expect(stripModelFallbackNotice(body)).toBe(REAL_REPLY);
  });

  it("matches any failover reason, not a fixed enum", () => {
    for (const reason of [
      "auth",
      "auth permanent",
      "rate limit",
      "timeout",
      "overloaded",
      "429 too many requests",
      "model not found",
    ]) {
      const body = `↪️ Model Fallback: openrouter/anthropic/claude-haiku-4.5 (selected openai/gpt-5.5; ${reason})\n\n${REAL_REPLY}`;
      expect(stripModelFallbackNotice(body)).toBe(REAL_REPLY);
    }
  });

  it("strips the 'cleared' recovery variant (was …)", () => {
    const body = `↪️ Model Fallback cleared: openai/gpt-5.5 (was openrouter/openai/gpt-5.4-mini)\n\n${REAL_REPLY}`;
    expect(stripModelFallbackNotice(body)).toBe(REAL_REPLY);
  });

  it("removes multiple notices in one turn", () => {
    const body = `${LEAKED_NOTICE}\n\n↪️ Model Fallback cleared: openai/gpt-5.5 (was openrouter/openai/gpt-5.4-mini)\n\n${REAL_REPLY}`;
    expect(stripModelFallbackNotice(body)).toBe(REAL_REPLY);
  });

  it("leaves an ordinary reply untouched (no parenthetical, no header)", () => {
    expect(stripModelFallbackNotice(REAL_REPLY)).toBe(REAL_REPLY);
  });

  it("does not over-match a reply that merely contains a parenthetical", () => {
    const reply =
      "Your Pro plan (billed annually) is active — you have unlimited Connect & Chat.";
    expect(stripModelFallbackNotice(reply)).toBe(reply);
  });

  it("does not strip a malformed notice that lacks the parenthetical (fail-safe)", () => {
    // Without the terminating (selected …) / (was …) we don't recognize it, so
    // we leave it rather than risk eating real reply text.
    const body = "Model Fallback: something\n\nactual reply text here";
    expect(stripModelFallbackNotice(body)).toBe(body.trim());
  });

  it("returns non-string input unchanged", () => {
    // @ts-expect-error exercising the defensive runtime guard
    expect(stripModelFallbackNotice(undefined)).toBe(undefined);
  });
});

describe("findModelFallbackNotices", () => {
  it("returns the matched notice for audit logging", () => {
    const body = `${LEAKED_NOTICE}\n\n${REAL_REPLY}`;
    const found = findModelFallbackNotices(body);
    expect(found).not.toBeNull();
    expect(found?.[0]).toContain("Model Fallback:");
    expect(found?.[0]).toContain("auth");
  });

  it("returns null when there is no notice", () => {
    expect(findModelFallbackNotices(REAL_REPLY)).toBeNull();
  });
});

describe("a fallback notice must not corrupt no-reply detection", () => {
  it("a notice prepended to a [[NO_REPLY]] turn is still recognized as silence after stripping", () => {
    // Real failure mode: the customer says "thanks", Caroline emits only the
    // no-reply sentinel, but the gateway prepends a fallback notice as chunk[0].
    // Without the strip, isIntentionalNoReply sees leftover notice text and
    // returns false -> Caroline would post the gateway notice as a reply to
    // "thanks". Stripping first restores the intended silence.
    const joined = `${LEAKED_NOTICE}\n\n[[NO_REPLY]]`;
    expect(isIntentionalNoReply(joined)).toBe(false); // the bug, before stripping
    const cleaned = stripModelFallbackNotice(joined);
    expect(isIntentionalNoReply(cleaned)).toBe(true); // fixed, after stripping
    expect(stripNoReplySentinel(cleaned)).toBe("");
  });
});

describe("isOnlyModelFallbackNotice", () => {
  it("is true for a standalone notice chunk (the deliver-callback drop case)", () => {
    expect(isOnlyModelFallbackNotice(LEAKED_NOTICE)).toBe(true);
  });

  it("is true when the chunk is a notice followed by only whitespace", () => {
    expect(isOnlyModelFallbackNotice(`${LEAKED_NOTICE}\n\n   `)).toBe(true);
  });

  it("is FALSE when a real reply follows the notice (chunk must be kept, flush strips it)", () => {
    // If the gateway merged the notice into the same chunk as a real reply,
    // dropping the whole chunk would lose the reply. isOnlyModelFallbackNotice
    // must be false so the chunk is buffered and the flush-time strip handles it.
    expect(isOnlyModelFallbackNotice(`${LEAKED_NOTICE}\n\n${REAL_REPLY}`)).toBe(false);
  });

  it("is false for an ordinary reply and for blank input", () => {
    expect(isOnlyModelFallbackNotice(REAL_REPLY)).toBe(false);
    expect(isOnlyModelFallbackNotice("   ")).toBe(false);
    expect(isOnlyModelFallbackNotice("")).toBe(false);
  });

  it("is false for non-string input", () => {
    // @ts-expect-error exercising the defensive runtime guard
    expect(isOnlyModelFallbackNotice(undefined)).toBe(false);
  });
});

describe("dropping a notice-only chunk keeps silent-dispatch symmetric", () => {
  it("a notice-only turn reads as zero output, so it pages instead of being swallowed", () => {
    // The fix's core invariant: a standalone fallback notice is dropped before
    // buffering (it is notice-only), so a turn whose ONLY output was the notice
    // leaves bufferedChunks empty and trips the #280 silent_dispatch alarm —
    // the customer genuinely got no reply. This must hold whether the runtime
    // preserved the isFallbackNotice flag (layer 1) or not (content check), so
    // the two layers never disagree on whether ops gets paged.
    expect(isOnlyModelFallbackNotice(LEAKED_NOTICE)).toBe(true);
    const bufferedAfterDrop: string[] = []; // the notice-only chunk was dropped
    expect(
      detectSilentDispatch({
        bufferedChunks: bufferedAfterDrop,
        state: makeActiveState(),
        droppedMidStream: false,
      }),
    ).toEqual({ silent: true, reason: "zero_chunks_after_dispatch" });
  });

  it("a notice + real reply turn keeps the chunk, so it does NOT page", () => {
    const merged = `${LEAKED_NOTICE}\n\n${REAL_REPLY}`;
    expect(isOnlyModelFallbackNotice(merged)).toBe(false); // chunk is kept
    expect(
      detectSilentDispatch({
        bufferedChunks: [merged],
        state: makeActiveState(),
        droppedMidStream: false,
      }),
    ).toEqual({ silent: false });
  });
});

describe("MODEL_FALLBACK_NOTICE_RE", () => {
  it("is exported for the channel.ts audit-log/strip wiring", () => {
    expect(MODEL_FALLBACK_NOTICE_RE).toBeInstanceOf(RegExp);
    expect(MODEL_FALLBACK_NOTICE_RE.flags).toContain("g");
  });
});

// ── openclaw 2026.7.x "fallback produced no visible reply" notice ────────────
// The exact isError payload text that leaked to a customer (incident
// 2026-07-15 ~02:37Z, during the codex 401 window). It carries isError, NOT
// isFallbackNotice, and different wording — both 6.x layers missed it.
const LEAKED_71_NOTICE =
  "⚠️ I couldn't reach the configured model backend openai/gpt-5.5. Fallback used openrouter/openai/gpt-5.4-mini, but it produced no visible reply.";

describe("2026.7.x fallback-failure notice", () => {
  it("strips the exact leaked 7.1 notice", () => {
    expect(stripModelFallbackNotice(LEAKED_71_NOTICE)).toBe("");
  });

  it("strips it when prepended to a real reply, keeping the reply", () => {
    expect(stripModelFallbackNotice(`${LEAKED_71_NOTICE}\n\n${REAL_REPLY}`)).toBe(REAL_REPLY);
  });

  it("survives a stripped emoji and a curly apostrophe (typography passes)", () => {
    const wobbled =
      "I couldn’t reach the configured model backend openai/gpt-5.5. Fallback used openrouter/openai/gpt-5.4-mini, but it produced no visible reply.";
    expect(stripModelFallbackNotice(wobbled)).toBe("");
  });

  it("is notice-only, so a standalone chunk is dropped and the turn pages as silent", () => {
    expect(isOnlyModelFallbackNotice(LEAKED_71_NOTICE)).toBe(true);
    expect(
      detectSilentDispatch({
        bufferedChunks: [],
        state: makeActiveState(),
        droppedMidStream: false,
      }),
    ).toEqual({ silent: true, reason: "zero_chunks_after_dispatch" });
  });

  it("is reported by findModelFallbackNotices for the audit log", () => {
    const found = findModelFallbackNotices(`${LEAKED_71_NOTICE}\n\n${REAL_REPLY}`);
    expect(found).toHaveLength(1);
    expect(found?.[0]).toContain("couldn't reach the configured model backend");
  });

  it("never matches an innocent customer sentence about reachability", () => {
    const innocent = "I couldn't reach the support team yesterday, can you help?";
    expect(stripModelFallbackNotice(innocent)).toBe(innocent);
    expect(isOnlyModelFallbackNotice(innocent)).toBe(false);
  });
});

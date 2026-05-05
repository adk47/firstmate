import { describe, it, expect } from "vitest";
import { createOpenRouterJudge } from "../src/judge.js";

describe("createOpenRouterJudge", () => {
  it("parses a valid JSON response into JudgeOutput", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              content: JSON.stringify({
                shouldHandoff: true,
                reasons: ["frustration"],
                suggestedActionType: "support-general",
                confidence: "high",
              }),
            },
          },
        ],
      }),
    })) as unknown as typeof fetch;

    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "anthropic/claude-haiku-4-5-20251001",
      fetchImpl,
    });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "hi" });
    expect(out?.shouldHandoff).toBe(true);
    expect(out?.confidence).toBe("high");
  });

  it("returns null and warns on malformed JSON content (no throw)", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: "not json at all" } }],
      }),
    })) as unknown as typeof fetch;
    const warned: string[] = [];
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
      log: { warn: (m) => warned.push(m) },
    });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "" });
    expect(out).toBeNull();
    expect(warned.some((m) => m.includes("JSON.parse"))).toBe(true);
  });

  it("returns null and warns when shape doesn't match schema", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({ shouldHandoff: "yes" }) } }],
      }),
    })) as unknown as typeof fetch;
    const warned: string[] = [];
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
      log: { warn: (m) => warned.push(m) },
    });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "" });
    expect(out).toBeNull();
    expect(warned.some((m) => m.includes("shape rejected"))).toBe(true);
  });

  it("returns null when suggestedActionType is not in the allowed enum", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({
          shouldHandoff: true,
          reasons: ["frustration"],
          suggestedActionType: "profile-merge",
          confidence: "high",
        }) } }],
      }),
    })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({ openrouterApiKey: "k", model: "x", fetchImpl });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "" });
    expect(out).toBeNull();
  });

  it("returns null when reasons array contains non-string entries", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({
          shouldHandoff: true,
          reasons: [42, null],
          suggestedActionType: "support-general",
          confidence: "high",
        }) } }],
      }),
    })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({ openrouterApiKey: "k", model: "x", fetchImpl });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "" });
    expect(out).toBeNull();
  });

  it("throws on non-2xx response (handler treats this at the assess layer)", async () => {
    const fetchImpl = (async () => ({ ok: false, status: 503, json: async () => ({}) })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
    });
    await expect(judge!({ knownFacts: {}, recentParts: [], currentMessage: "" })).rejects.toThrow(/503/);
  });

  it("throws AbortError on timeout", async () => {
    const fetchImpl = ((url: string, init: RequestInit) =>
      new Promise((_resolve, reject) => {
        const sig = init.signal!;
        const onAbort = () => {
          const err: Error & { name: string } = new Error("aborted") as any;
          err.name = "AbortError";
          reject(err);
        };
        if (sig.aborted) onAbort();
        else sig.addEventListener("abort", onAbort, { once: true });
      })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
      timeoutMs: 5,
    });
    await expect(judge!({ knownFacts: {}, recentParts: [], currentMessage: "" })).rejects.toThrow();
  });

  it("caps recentParts and trims long bodies before stringify", async () => {
    let capturedBody: string | null = null;
    const fetchImpl = ((_url: string, init: RequestInit) => {
      capturedBody = String(init.body);
      return Promise.resolve({
        ok: true,
        json: async () => ({
          choices: [{ message: { content: JSON.stringify({
            shouldHandoff: false,
            reasons: ["ambiguous"],
            suggestedActionType: "support-general",
            confidence: "low",
          }) } }],
        }),
      });
    }) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({ openrouterApiKey: "k", model: "x", fetchImpl });
    const big = "x".repeat(5000);
    const recent = Array.from({ length: 30 }, (_, i) => ({ author: "user" as const, body: `${i}-${big}` }));
    await judge!({ knownFacts: {}, recentParts: recent, currentMessage: big });
    // 30 parts should be capped to 10; each part body capped to 500 chars.
    const parsedBody = JSON.parse(capturedBody!);
    const userMsgPayload = JSON.parse(parsedBody.messages[1].content);
    expect(userMsgPayload.recentParts.length).toBe(10);
    for (const p of userMsgPayload.recentParts) {
      expect(p.body.length).toBeLessThanOrEqual(500);
    }
    expect(userMsgPayload.currentMessage.length).toBeLessThanOrEqual(2_000);
  });
});

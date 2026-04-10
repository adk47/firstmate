import { describe, it, expect } from "vitest";
import { joinDeliveryChunks } from "../src/channel.js";

describe("joinDeliveryChunks", () => {
  it("returns empty string for empty array", () => {
    expect(joinDeliveryChunks([])).toBe("");
  });

  it("returns single chunk unchanged", () => {
    expect(joinDeliveryChunks(["Hello world"])).toBe("Hello world");
  });

  it("joins multiple chunks with double newlines", () => {
    expect(joinDeliveryChunks(["Hello", "World"])).toBe("Hello\n\nWorld");
  });

  it("drops empty chunks", () => {
    expect(joinDeliveryChunks(["Hello", "", "World"])).toBe("Hello\n\nWorld");
  });

  it("drops whitespace-only chunks", () => {
    expect(joinDeliveryChunks(["Hello", "   ", "World"])).toBe("Hello\n\nWorld");
  });

  it("trims trailing whitespace per chunk", () => {
    expect(joinDeliveryChunks(["Hello   ", "World  "])).toBe("Hello\n\nWorld");
  });

  it("preserves internal whitespace", () => {
    expect(joinDeliveryChunks(["Hello   World"])).toBe("Hello   World");
  });

  it("handles all-empty input", () => {
    expect(joinDeliveryChunks(["", "  ", "\n  "])).toBe("");
  });

  it("joins many chunks from a realistic agent turn", () => {
    const chunks = [
      "Let me look into that.",
      "Based on the thread context, here's my response:",
      "Hi Daniel,\n\nThanks for getting back to us.",
    ];
    const result = joinDeliveryChunks(chunks);
    expect(result).toBe(
      "Let me look into that.\n\n" +
      "Based on the thread context, here's my response:\n\n" +
      "Hi Daniel,\n\nThanks for getting back to us."
    );
  });
});

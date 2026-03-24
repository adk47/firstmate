import { describe, it, expect } from "vitest";
import { buildSessionKey } from "../src/session-key.js";

describe("buildSessionKey", () => {
  it("builds deterministic key from workspace and conversation ID", () => {
    const key = buildSessionKey("ws_123", "conv_456");
    expect(key).toBe("agent:support:intercom:ws_123:conversation:conv_456");
  });

  it("produces different keys for different conversations", () => {
    const key1 = buildSessionKey("ws_123", "conv_1");
    const key2 = buildSessionKey("ws_123", "conv_2");
    expect(key1).not.toBe(key2);
  });

  it("produces different keys for different workspaces", () => {
    const key1 = buildSessionKey("ws_prod", "conv_1");
    const key2 = buildSessionKey("ws_staging", "conv_1");
    expect(key1).not.toBe(key2);
  });

  it("is idempotent — same inputs always produce same key", () => {
    const a = buildSessionKey("ws_123", "conv_456");
    const b = buildSessionKey("ws_123", "conv_456");
    expect(a).toBe(b);
  });

  it("throws on empty workspace ID", () => {
    expect(() => buildSessionKey("", "conv_1")).toThrow();
  });

  it("throws on empty conversation ID", () => {
    expect(() => buildSessionKey("ws_1", "")).toThrow();
  });
});

import { describe, it, expect } from "vitest";
import { createHmac } from "node:crypto";
import { validateHmacSignature } from "../src/webhook.js";

const TEST_SECRET = "test_webhook_secret_123";

function sign(body: string, secret: string, algorithm: "sha256" | "sha1" = "sha256"): string {
  return `${algorithm}=` + createHmac(algorithm, secret).update(body).digest("hex");
}

describe("validateHmacSignature", () => {
  it("returns true for valid signature", () => {
    const body = '{"type":"notification_event"}';
    const signature = sign(body, TEST_SECRET);
    expect(validateHmacSignature(body, signature, TEST_SECRET)).toBe(true);
  });

  it("returns false for invalid signature", () => {
    const body = '{"type":"notification_event"}';
    expect(validateHmacSignature(body, "sha256=invalid", TEST_SECRET)).toBe(false);
  });

  it("returns false for missing signature", () => {
    const body = '{"type":"notification_event"}';
    expect(validateHmacSignature(body, "", TEST_SECRET)).toBe(false);
  });

  it("returns false for tampered body", () => {
    const body = '{"type":"notification_event"}';
    const signature = sign(body, TEST_SECRET);
    const tampered = '{"type":"notification_event","injected":true}';
    expect(validateHmacSignature(tampered, signature, TEST_SECRET)).toBe(false);
  });

  it("returns false for wrong secret", () => {
    const body = '{"type":"notification_event"}';
    const signature = sign(body, "wrong_secret");
    expect(validateHmacSignature(body, signature, TEST_SECRET)).toBe(false);
  });

  it("returns true for valid SHA-1 signature", () => {
    const body = '{"type":"notification_event"}';
    const signature = sign(body, TEST_SECRET, "sha1");
    expect(validateHmacSignature(body, signature, TEST_SECRET)).toBe(true);
  });

  it("returns false for invalid SHA-1 signature", () => {
    const body = '{"type":"notification_event"}';
    expect(validateHmacSignature(body, "sha1=invalid", TEST_SECRET)).toBe(false);
  });

  it("returns false for unsupported algorithm prefix", () => {
    const body = '{"type":"notification_event"}';
    expect(validateHmacSignature(body, "md5=abc123", TEST_SECRET)).toBe(false);
  });

  it("throws on empty secret", () => {
    const body = '{"type":"notification_event"}';
    expect(() => validateHmacSignature(body, "sha256=abc", "")).toThrow("Webhook secret is not configured");
  });
});

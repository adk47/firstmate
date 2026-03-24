import { describe, it, expect } from "vitest";
import { createHmac } from "node:crypto";
import { validateHmacSignature } from "../src/webhook.js";

const TEST_SECRET = "test_webhook_secret_123";

function sign(body: string, secret: string): string {
  return "sha256=" + createHmac("sha256", secret).update(body).digest("hex");
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

  it("throws on empty secret", () => {
    const body = '{"type":"notification_event"}';
    expect(() => validateHmacSignature(body, "sha256=abc", "")).toThrow("Webhook secret is not configured");
  });
});

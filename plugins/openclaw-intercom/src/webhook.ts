import { createHmac, timingSafeEqual } from "node:crypto";

export function validateHmacSignature(
  body: string,
  signature: string,
  secret: string,
): boolean {
  if (!secret) throw new Error("Webhook secret is not configured");
  if (!signature || !signature.startsWith("sha256=")) return false;

  const expected = "sha256=" + createHmac("sha256", secret).update(body).digest("hex");

  if (expected.length !== signature.length) return false;

  return timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
}

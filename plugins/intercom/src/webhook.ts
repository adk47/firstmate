import { createHmac, timingSafeEqual } from "node:crypto";

export function validateHmacSignature(
  body: string,
  signature: string,
  secret: string,
): boolean {
  if (!secret) throw new Error("Webhook secret is not configured");
  if (!signature) return false;

  let algorithm: string;
  if (signature.startsWith("sha256=")) {
    algorithm = "sha256";
  } else if (signature.startsWith("sha1=")) {
    algorithm = "sha1";
  } else {
    return false;
  }

  const prefix = `${algorithm}=`;
  const expected = prefix + createHmac(algorithm, secret).update(body).digest("hex");

  if (expected.length !== signature.length) return false;

  return timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
}

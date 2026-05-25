import { createHmac, timingSafeEqual } from "node:crypto";

// Identifies a webhook-health-monitor probe so the handler can short-circuit
// after HMAC validation — skipping the async payload-parse path that would
// otherwise log "malformed payload — no conversationId" every 5 min and
// pollute the session store with a fake conv-id. The monitor sends `{}` as
// body; any non-empty body is treated as real Intercom traffic.
export function isMonitorProbe(userAgent: string, rawBody: string): boolean {
  return userAgent.startsWith("muso-webhook-monitor/") && rawBody === "{}";
}

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

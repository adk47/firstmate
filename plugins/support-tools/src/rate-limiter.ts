interface BucketEntry {
  count: number;
  windowStart: number;
}

/**
 * A refusal always carries the reopen time: a refusal that cannot say when to
 * come back leaves the caller with nothing to do but escalate. Modelled as a
 * union so callers get that guarantee from the type, not from a runtime check.
 */
export type RateLimitVerdict =
  | { allowed: true }
  | { allowed: false; retryAfterSeconds: number };

export class RateLimiter {
  private buckets = new Map<string, BucketEntry>();

  check(sessionId: string, toolName: string, windowMinutes: number, maxCalls: number): RateLimitVerdict {
    const key = `${sessionId}:${toolName}`;
    const now = Date.now();
    const windowMs = windowMinutes * 60_000;

    const entry = this.buckets.get(key);

    if (!entry || now - entry.windowStart > windowMs) {
      this.buckets.set(key, { count: 1, windowStart: now });
      return { allowed: true };
    }

    if (entry.count >= maxCalls) {
      const remainingMs = entry.windowStart + windowMs - now;
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(remainingMs / 1000)) };
    }

    entry.count++;
    return { allowed: true };
  }
}

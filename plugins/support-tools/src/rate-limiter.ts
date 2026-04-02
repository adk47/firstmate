interface BucketEntry {
  count: number;
  windowStart: number;
}

export class RateLimiter {
  private buckets = new Map<string, BucketEntry>();

  check(sessionId: string, toolName: string, windowMinutes: number, maxCalls: number): { allowed: boolean } {
    const key = `${sessionId}:${toolName}`;
    const now = Date.now();
    const windowMs = windowMinutes * 60_000;

    const entry = this.buckets.get(key);

    if (!entry || now - entry.windowStart > windowMs) {
      this.buckets.set(key, { count: 1, windowStart: now });
      return { allowed: true };
    }

    if (entry.count >= maxCalls) {
      return { allowed: false };
    }

    entry.count++;
    return { allowed: true };
  }
}

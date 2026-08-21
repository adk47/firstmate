import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { RateLimiter } from "../src/rate-limiter.js";

describe("RateLimiter", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("allows calls within the limit", () => {
    const limiter = new RateLimiter();
    expect(limiter.check("session-1", "profile_lookup", 1, 10)).toEqual({ allowed: true });
    expect(limiter.check("session-1", "profile_lookup", 1, 10)).toEqual({ allowed: true });
  });

  it("blocks calls exceeding the limit", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 60, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toMatchObject({ allowed: false });
  });

  it("resets after the window expires", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 1, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 1, 2)).toMatchObject({ allowed: false });

    vi.advanceTimersByTime(60_001); // 1 minute + 1ms

    expect(limiter.check("session-1", "create_ticket", 1, 2)).toEqual({ allowed: true });
  });

  it("isolates sessions from each other", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 60, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toMatchObject({ allowed: false });
    expect(limiter.check("session-2", "create_ticket", 60, 2)).toEqual({ allowed: true });
  });

  it("isolates tool names from each other", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 60, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toMatchObject({ allowed: false });
    expect(limiter.check("session-1", "profile_lookup", 1, 10)).toEqual({ allowed: true });
  });

  it("tells a blocked caller when the window reopens", () => {
    const limiter = new RateLimiter();
    limiter.check("session-1", "company_finder_prep", 15, 1);

    const blocked = limiter.check("session-1", "company_finder_prep", 15, 1);

    // A refusal with no reopen time leaves the caller nothing to do but escalate.
    // Narrowed via the discriminant rather than read off the union, so this
    // assertion also proves the type carries the guarantee the union promises.
    if (blocked.allowed) throw new Error("expected the second call to be refused");
    expect(blocked.retryAfterSeconds).toBeGreaterThan(0);
    expect(blocked.retryAfterSeconds).toBeLessThanOrEqual(15 * 60);
  });
});

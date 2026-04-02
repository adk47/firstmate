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
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toEqual({ allowed: false });
  });

  it("resets after the window expires", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 1, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 1, 2)).toEqual({ allowed: false });

    vi.advanceTimersByTime(60_001); // 1 minute + 1ms

    expect(limiter.check("session-1", "create_ticket", 1, 2)).toEqual({ allowed: true });
  });

  it("isolates sessions from each other", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 60, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toEqual({ allowed: false });
    expect(limiter.check("session-2", "create_ticket", 60, 2)).toEqual({ allowed: true });
  });

  it("isolates tool names from each other", () => {
    const limiter = new RateLimiter();
    for (let i = 0; i < 2; i++) {
      limiter.check("session-1", "create_ticket", 60, 2);
    }
    expect(limiter.check("session-1", "create_ticket", 60, 2)).toEqual({ allowed: false });
    expect(limiter.check("session-1", "profile_lookup", 1, 10)).toEqual({ allowed: true });
  });
});

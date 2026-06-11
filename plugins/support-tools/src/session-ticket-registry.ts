const TTL_MS = 24 * 60 * 60_000;

interface Entry {
  ticketId: string;
  recordedAtMs: number;
}

// Remembers which ClickUp ticket a (session, action type, customer email)
// triple already filed, so repeat create_ticket calls in the same conversation
// append a comment instead of opening a duplicate. The email is part of the
// key because sessions without a real ctx.sessionId collapse onto "unknown" —
// without it, customer B's follow-up could land in customer A's ticket.
// In-memory like RateLimiter — a gateway restart forgets it, which is why
// create-ticket also falls back to a ClickUp lookup before creating.
export class SessionTicketRegistry {
  private entries = new Map<string, Entry>();

  private key(sessionId: string, actionType: string, customerEmail: string): string {
    return `${sessionId}|${actionType}|${customerEmail.toLowerCase()}`;
  }

  record(sessionId: string, actionType: string, customerEmail: string, ticketId: string, nowMs: number = Date.now()): void {
    // Opportunistic sweep — get() only evicts the key it reads, so without
    // this, every conversation that ever filed a ticket would leak an entry
    // for the gateway's lifetime.
    for (const [key, entry] of this.entries) {
      if (nowMs - entry.recordedAtMs > TTL_MS) this.entries.delete(key);
    }
    this.entries.set(this.key(sessionId, actionType, customerEmail), { ticketId, recordedAtMs: nowMs });
  }

  get(sessionId: string, actionType: string, customerEmail: string, nowMs: number = Date.now()): string | null {
    const key = this.key(sessionId, actionType, customerEmail);
    const entry = this.entries.get(key);
    if (!entry) return null;
    if (nowMs - entry.recordedAtMs > TTL_MS) {
      this.entries.delete(key);
      return null;
    }
    return entry.ticketId;
  }

  // Drop an entry that turned out to point at a closed/stale ticket.
  invalidate(sessionId: string, actionType: string, customerEmail: string): void {
    this.entries.delete(this.key(sessionId, actionType, customerEmail));
  }
}

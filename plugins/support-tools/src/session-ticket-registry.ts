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
// Merge-kind tickets (profile-merge / unmerge-request / track-merge) are kept per
// ticket, not per action type: one conversation can hold several DIFFERENT merge
// requests, and a follow-up must land on the ticket whose targets it names. Each
// entry carries the caller's payload (the ticket's current merge intake).
export interface MergeTicketEntry<T> {
  ticketId: string;
  payload: T;
}

export class SessionTicketRegistry {
  private entries = new Map<string, Entry>();
  private mergeEntries = new Map<string, Array<Entry & { payload: unknown }>>();

  private key(sessionId: string, actionType: string, customerEmail: string): string {
    return `${sessionId}|${actionType}|${customerEmail.toLowerCase()}`;
  }

  record(sessionId: string, actionType: string, customerEmail: string, ticketId: string, nowMs: number = Date.now()): void {
    // Opportunistic sweep — get() only evicts the key it reads, so without
    // this, every conversation that ever filed a ticket would leak an entry
    // for the gateway's lifetime.
    this.sweep(nowMs);
    this.entries.set(this.key(sessionId, actionType, customerEmail), { ticketId, recordedAtMs: nowMs });
  }

  private sweep(nowMs: number): void {
    for (const [key, entry] of this.entries) {
      if (nowMs - entry.recordedAtMs > TTL_MS) this.entries.delete(key);
    }
    for (const [key, list] of this.mergeEntries) {
      const live = list.filter((e) => nowMs - e.recordedAtMs <= TTL_MS);
      if (live.length) this.mergeEntries.set(key, live);
      else this.mergeEntries.delete(key);
    }
  }

  /** Record (or replace) one merge-kind ticket of this session + kind + email. */
  recordMerge<T>(sessionId: string, actionType: string, customerEmail: string, ticketId: string, payload: T,
                 nowMs: number = Date.now()): void {
    this.sweep(nowMs);
    const key = this.key(sessionId, actionType, customerEmail);
    const list = (this.mergeEntries.get(key) ?? []).filter((e) => e.ticketId !== ticketId);
    list.push({ ticketId, payload, recordedAtMs: nowMs });
    this.mergeEntries.set(key, list);
  }

  /** This session's live merge-kind tickets of that kind + email, newest first. */
  merges<T>(sessionId: string, actionType: string, customerEmail: string,
            nowMs: number = Date.now()): Array<MergeTicketEntry<T>> {
    const list = this.mergeEntries.get(this.key(sessionId, actionType, customerEmail)) ?? [];
    return list.filter((e) => nowMs - e.recordedAtMs <= TTL_MS).reverse()
      .map((e) => ({ ticketId: e.ticketId, payload: e.payload as T }));
  }

  invalidateMerge(sessionId: string, actionType: string, customerEmail: string, ticketId: string): void {
    const key = this.key(sessionId, actionType, customerEmail);
    const list = (this.mergeEntries.get(key) ?? []).filter((e) => e.ticketId !== ticketId);
    if (list.length) this.mergeEntries.set(key, list);
    else this.mergeEntries.delete(key);
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

/**
 * Per-key serial batch queue for agent dispatches.
 *
 * WHY: rapid-fire inbound messages on one Intercom conversation used to spawn
 * OVERLAPPING embedded_run dispatches on that conversation's session lane —
 * the exact trigger for the upstream openclaw lane wedge (#97538: one run
 * leaks the lane owner lock, later dispatches wedge at embedded_run:started,
 * stuck-session recovery aborts them with released=0 and DISCARDS the
 * generated reply; ~30 wedges/day before this). Serializing dispatch per
 * conversation removes the overlap: at most ONE runBatch is in flight per
 * key, and items arriving meanwhile are spliced into the NEXT single batch.
 *
 * Deliberately timer-free (nothing to clean up on account stop) and
 * memory-only (a restart drops queued-not-yet-dispatched items; messages
 * persist in Intercom and the next customer ping re-triggers a webhook —
 * the dispatch-timeout page and stuck-lane watchdog cover true silence).
 */

export interface DispatchQueueDeps<T> {
  /**
   * Runs ONE coalesced batch. Never invoked concurrently for the same key
   * (within one queue instance; an account restart creates a new queue that
   * cannot serialize against the old one, and a runBatch that gives up on a
   * still-running dispatch — e.g. raceDispatchWithTimeout firing — releases
   * the key while that abandoned run may still hold the lane). A rejection
   * is routed to onError and never wedges the key's queue.
   */
  runBatch: (key: string, batch: T[]) => Promise<void>;
  onError?: (key: string, err: unknown) => void;
}

interface KeyState<T> {
  pending: T[];
  running: boolean;
}

export class DispatchQueue<T> {
  private readonly deps: DispatchQueueDeps<T>;
  private readonly keys = new Map<string, KeyState<T>>();
  private closed = false;

  constructor(deps: DispatchQueueDeps<T>) {
    this.deps = deps;
  }

  /**
   * Enqueue an item. If no batch is in flight for `key`, starts a drain
   * (async — NOT awaited by the caller) and returns "started"; otherwise the
   * item rides the next batch and this returns "queued". After clear() the
   * queue is CLOSED and every enqueue returns "dropped" without dispatching —
   * a webhook handler already in flight at account stop (e.g. awaiting media
   * download) would otherwise restart a drain against a session map that
   * stop() just deleted, fabricating a blank agent_active session.
   */
  enqueue(key: string, item: T): "started" | "queued" | "dropped" {
    if (this.closed) return "dropped";
    let state = this.keys.get(key);
    if (!state) {
      state = { pending: [], running: false };
      this.keys.set(key, state);
    }
    state.pending.push(item);
    if (state.running) return "queued";
    state.running = true;
    void this.drain(key, state);
    return "started";
  }

  inFlight(key: string): boolean {
    return this.keys.get(key)?.running ?? false;
  }

  pendingCount(key: string): number {
    return this.keys.get(key)?.pending.length ?? 0;
  }

  /** Number of keys currently tracked (tests: proves entries are reclaimed). */
  size(): number {
    return this.keys.size;
  }

  /** Drop every queued item, forget all keys, and CLOSE the queue (account
   * stop — a new account start builds a new instance). In-flight batches
   * finish on their own, but their drain loop sees an emptied pending array
   * (cleared IN PLACE — the loop holds a reference to it) and stops without
   * dispatching anything further; later enqueues return "dropped". Returns
   * how many queued items were dropped so the caller can log the loss (no
   * silent drops). */
  clear(): number {
    this.closed = true;
    let dropped = 0;
    for (const state of this.keys.values()) {
      dropped += state.pending.length;
      state.pending.length = 0;
    }
    this.keys.clear();
    return dropped;
  }

  private async drain(key: string, state: KeyState<T>): Promise<void> {
    while (state.pending.length > 0) {
      const batch = state.pending.splice(0, state.pending.length);
      try {
        await this.deps.runBatch(key, batch);
      } catch (err) {
        this.deps.onError?.(key, err);
      }
    }
    state.running = false;
    // Reclaim the entry unless clear() swapped the map or a re-entrant
    // enqueue raced in between the loop check and here (pending stays empty
    // only when nothing arrived).
    if (this.keys.get(key) === state && state.pending.length === 0) {
      this.keys.delete(key);
    }
  }
}

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
 *
 * The drain is launched fire-and-forget, so on openclaw >= 2026.8 it MUST be
 * started on its own admitted gateway work root — see `deps.detach`. Without
 * that, the drain inherits the webhook request's root-work admission, outlives
 * it, and every dispatch is refused as if the gateway were draining.
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
  /**
   * Runs the detached drain on its OWN admitted gateway work root.
   *
   * openclaw >= 2026.8 refuses queue work whose async context carries an
   * already-RELEASED root-work admission: `isGatewaySubordinateWorkAdmissionClosed()`
   * returns `current.released`, surfacing as `GatewayDrainingError: Gateway is
   * draining; new tasks are not accepted` while nothing is actually draining.
   * The drain below is fire-and-forget, so it inherits — and outlives — the
   * webhook request's admission; without this wrapper EVERY coalesced dispatch
   * fails (incident 2026-09-10: Caroline silent ~6h45m, 41 dropped messages).
   *
   * MUST be invoked synchronously from `enqueue()`, while the request still
   * holds its admission. Omitted on runtimes with no admission model
   * (<= 2026.7.x), where calling `drain` directly is correct.
   */
  detach?: <R>(run: () => Promise<R>) => Promise<R>;
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
    // Synchronous by construction: `detach` is CALLED here, inside enqueue,
    // while the webhook request still holds its admission. Awaiting anything
    // before this point would release it and reintroduce the drain error.
    const detach = this.deps.detach;
    const started = detach
      ? detach(() => this.drain(key, state))
      : this.drain(key, state);
    // drain() never rejects (it routes runBatch failures to onError), but
    // `detach` CAN: it reserves an admission and throws when the gateway really
    // is draining/restarting. Without this catch that rejection is unhandled
    // AND `running` stays true forever — wedging this conversation's queue for
    // the life of the process, which is the exact silent-stall shape the
    // dispatch-timeout page exists to avoid. Release the key instead and report.
    void started.catch((err) => {
      state.running = false;
      if (this.keys.get(key) === state && state.pending.length === 0) {
        this.keys.delete(key);
      }
      this.deps.onError?.(key, err);
    });
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

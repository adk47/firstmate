/**
 * Cross-plugin fact: "does the SIGNED-IN contact on this Intercom conversation have an open
 * credit request right now?" (the `open_request` fact, caroline-read-state-tools-r1).
 *
 * The output guard's status line ("Your request is in the verification queue ...") may only be
 * sent when that fact is MEASURED true (plugins/intercom/src/caroline-output-guard.ts, FACT_LINES).
 * Until this file existed nothing ever set the fact, so the line failed closed to the hand-off
 * line on every status ask. The fact is produced HERE, by the request-state read tools, and
 * consumed by the intercom plugin on the outbound reply (plugins/intercom/src/request-state-signal.ts).
 *
 * Who it is about is decided by code and by nothing else:
 *   - the conversation id comes from the gateway session key (deriveConvId), never a model argument;
 *   - the owner comes from the conversation's authenticated Intercom contact (resolveOwnerAnchor);
 *   - the counts come from the admin API for a profile that contact solely owns.
 * A request id, an email or a name typed into the thread can never reach this store: the only
 * writers are the two read tools, after their ownership gates passed, and they pass a boolean.
 *
 * Same transport as ticket-success-signal.ts: the two plugins share one Node process but ship as
 * separate bundles, so the contract is the globalThis key name and the value shape below, and a
 * gateway restart forgets it. Forgetting errs honest: an unknown fact refuses the status line.
 * "Could not read" is never written as `false`; the tools write only what they measured.
 */

const SIGNAL_KEY = "__musoSupportRequestState";
// Long enough for the reply that follows the read in the same turn, short enough that a stale
// "open" can never license the status line in a much later turn.
const TTL_MS = 10 * 60_000;

export interface RequestStateFact {
  atMs: number;
  /** true = at least one open request measured for the verified owner; false = measured none. */
  open: boolean;
}

type SignalStore = Map<string, RequestStateFact>;

function store(): SignalStore {
  const g = globalThis as unknown as Record<string, unknown>;
  const existing = g[SIGNAL_KEY];
  if (existing instanceof Map) return existing as SignalStore;
  const created: SignalStore = new Map<string, RequestStateFact>();
  g[SIGNAL_KEY] = created;
  return created;
}

/**
 * Record the measured fact for `convId`. No-op on an empty convId or a non-boolean `open`
 * (a caller that could not measure must not call this, and a stray `undefined` must never be
 * coerced to "no open request").
 */
export function markOpenRequestFact(
  convId: string | null | undefined,
  open: boolean,
  nowMs: number = Date.now(),
): void {
  if (!convId || typeof open !== "boolean") return;
  const s = store();
  for (const [key, v] of s) {
    if (nowMs - v.atMs > TTL_MS) s.delete(key);
  }
  s.set(convId, { atMs: nowMs, open });
}

/** Forget the fact for `convId` (a later read in the same turn could not measure it). */
export function clearOpenRequestFact(convId: string | null | undefined): void {
  if (!convId) return;
  store().delete(convId);
}

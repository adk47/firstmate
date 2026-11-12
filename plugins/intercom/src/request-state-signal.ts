/**
 * Reader half of the cross-plugin `open_request` fact. The writer is
 * plugins/support-tools/src/request-state-signal.ts (see it for who the fact is about and why a
 * request id, an email or a name typed in the thread can never reach it). The two files agree
 * ONLY on the globalThis key name and the value shape; each ships in its own bundle.
 *
 * Used by the output guard: the approved status line ("Your request is in the verification
 * queue ...") may be sent only when a read tool MEASURED an open request for the signed-in
 * contact on this conversation in this turn (caroline-output-guard.ts, FACT_LINES).
 *
 * Three answers, never two: true (measured open), false (measured none) and undefined (nothing
 * measured, or the measurement is older than the window). undefined keeps the guard's fail-closed
 * behaviour: an absent, stale or foreign-shaped store never licenses the status line.
 */

const SIGNAL_KEY = "__musoSupportRequestState";
// Must not exceed the writer's TTL (10 min). A read and the reply that states it happen in the
// same turn; the window only has to cover that turn plus one guard retry.
const WINDOW_MS = 10 * 60_000;

export function readOpenRequestFact(
  convId: string | null | undefined,
  nowMs: number = Date.now(),
  windowMs: number = WINDOW_MS,
): boolean | undefined {
  if (!convId) return undefined;
  const s = (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
  if (!(s instanceof Map)) return undefined;
  const v = s.get(convId) as { atMs?: unknown; open?: unknown } | undefined;
  if (!v || typeof v.atMs !== "number" || typeof v.open !== "boolean") return undefined;
  if (nowMs - v.atMs > windowMs || nowMs < v.atMs) return undefined;
  return v.open;
}

/**
 * Forget the fact for a conversation. Called once per customer turn, before the agent runs, so
 * "measured" means measured IN THIS TURN: a read from an earlier message never licenses the
 * status line on a later one.
 */
export function resetOpenRequestFact(convId: string | null | undefined): void {
  if (!convId) return;
  const s = (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
  if (s instanceof Map) s.delete(convId);
}

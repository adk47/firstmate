/**
 * Reader half of the cross-plugin "ticket filed this conversation" signal. The writer is
 * plugins/support-tools/src/ticket-success-signal.ts (see it for the full contract and
 * the same-process caveat). The two files agree ONLY on the globalThis key name and value
 * shape (Map<convId, lastSuccessMs>); each ships in its own bundle.
 *
 * Used by the outbound false-handoff-claim guard: a completed-action handoff claim is
 * honest iff create_ticket succeeded for this conversation recently.
 */

const SIGNAL_KEY = "__musoSupportTicketSignal";
// A create_ticket call and the reply that references it happen SECONDS apart in the same
// turn, so a 2-min window comfortably captures the same-turn case.
//
// Known limitation (semantics = per-conversation-within-window, NOT per-claim): the signal
// answers "did ANY create_ticket succeed in this conversation in the last 2 min", so in a
// multi-topic conversation a ticket filed for request A can license an UNBACKED handoff
// claim about request B if B's reply lands inside the window. The window is deliberately
// SHORT because the failure directions are asymmetric: too-short only downgrades a legit
// same-turn claim to the honest fallback (safe), while too-long can license a false claim
// (unsafe) — so we bias short. The complete fix is turn-precise (clear/rescope the signal
// per inbound dispatch); it needs channel.ts plumbing across every reply path and is a
// documented follow-up. Even as-is this is strictly better than the prior state (no
// enforcement) and fully covers the motivating single-unbacked-claim incident.
const DEFAULT_WINDOW_MS = 2 * 60_000;

/**
 * True iff a create_ticket succeeded for `convId` within `windowMs`. Reads the same
 * globalThis Map the support-tools writer populates. Fail-safe: an empty convId or a
 * missing/foreign store shape returns false, so the guard defaults to rewriting toward
 * the honest fallback (it never licenses a false claim on a lost/absent signal).
 */
export function wasTicketFiledRecently(
  convId: string | null | undefined,
  nowMs: number = Date.now(),
  windowMs: number = DEFAULT_WINDOW_MS,
): boolean {
  if (!convId) return false;
  const s = (globalThis as unknown as Record<string, unknown>)[SIGNAL_KEY];
  if (!(s instanceof Map)) return false;
  const ts = s.get(convId);
  return typeof ts === "number" && nowMs - ts <= windowMs;
}

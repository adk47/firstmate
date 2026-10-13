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

// MUS-1516: which ticket ids were filed, additive to the signal above (design
// call ① on MUS-1471 — see the writer, plugins/support-tools/src/ticket-success-
// signal.ts, for the full contract). Same globalThis-key-only contract as the
// signal above: a rename on either side is caught by the literal key assertion
// in this file's test.
const IDS_KEY = "__musoSupportTicketIds";

/**
 * The reference ids (ClickUp task ids) filed for `convId` within `windowMs` —
 * read the same window as wasTicketFiledRecently by default, since both answer
 * the same underlying question ("did create_ticket succeed for this conversation
 * recently"); see that function's docstring for the window rationale and the
 * multi-topic-conversation caveat, which applies here too.
 *
 * Fail-safe (design call ② on MUS-1471): an empty convId, a missing store, or a
 * stale entry all return []. The outbound guard (sanitize-handoff-claim.ts)
 * treats [] as "no id is backed" — every reference-shaped token in the reply is
 * then unbacked and gets redacted. A lost/absent signal can only downgrade an
 * otherwise-true claim toward the honest fallback, it can never license a
 * fake or foreign id.
 */
export function getFiledTicketIds(
  convId: string | null | undefined,
  nowMs: number = Date.now(),
  windowMs: number = DEFAULT_WINDOW_MS,
): string[] {
  if (!convId) return [];
  const s = (globalThis as unknown as Record<string, unknown>)[IDS_KEY];
  if (!(s instanceof Map)) return [];
  const entry = (s as Map<string, { atMs: number; ids: string[] }>).get(convId);
  if (!entry || typeof entry.atMs !== "number" || nowMs - entry.atMs > windowMs) return [];
  return Array.isArray(entry.ids) ? entry.ids : [];
}

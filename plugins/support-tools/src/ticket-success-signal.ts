/**
 * Cross-plugin signal: "a create_ticket succeeded for this Intercom conversation."
 *
 * The intercom plugin's outbound false-handoff-claim guard (sanitize-handoff-claim.ts)
 * needs to know whether Caroline actually filed a ticket THIS conversation before it
 * decides whether a "raised it with the team" reply is honest or a confabulation. That
 * fact is produced HERE (support-tools, when create_ticket succeeds) and consumed THERE
 * (intercom, on the outbound reply). The two plugins load into the SAME edge gateway
 * process but are separate bundles with no shared module, so the contract is a well-known
 * globalThis key rather than an import. This mirrors the already-in-memory RateLimiter /
 * SessionTicketRegistry — a gateway restart forgets it, which is an acceptable,
 * honesty-erring failure direction (a lost signal makes the guard rewrite an otherwise-
 * true claim down to the honest fallback, never the reverse).
 *
 * The reader half is plugins/intercom/src/ticket-success-signal.ts. The two files agree
 * ONLY on the globalThis key name and value shape (Map<convId, lastSuccessMs>); each
 * ships in its own bundle, so there is nothing to keep byte-identical beyond those two.
 *
 * NOTE (verify on node-8): this assumes intercom + support-tools share one Node process.
 * openclaw-edge.json loads both into the edge gateway, which strongly implies it, but if
 * openclaw ever sandboxes plugins into isolated contexts the shared global breaks — the
 * fallback is a file-backed signal under the gateway state dir keyed by convId.
 */

const SIGNAL_KEY = "__musoSupportTicketSignal";
// 30 min: comfortably longer than any single conversation turn, short enough that a
// stale success can't license a false claim in a much later, unrelated turn.
const TTL_MS = 30 * 60_000;

type SignalStore = Map<string, number>;

function store(): SignalStore {
  const g = globalThis as unknown as Record<string, unknown>;
  const existing = g[SIGNAL_KEY];
  if (existing instanceof Map) return existing as SignalStore;
  const created: SignalStore = new Map<string, number>();
  g[SIGNAL_KEY] = created;
  return created;
}

/**
 * Record that a ticket was successfully filed for `convId` at `nowMs`. No-ops on an
 * empty/unparseable convId (deriveConvId returns null for non-intercom sessions), so a
 * missing key simply leaves the guard erring toward the honest fallback. Sweeps expired
 * entries opportunistically (mirrors SessionTicketRegistry.record — get()-style eviction
 * alone would leak an entry per conversation for the gateway's lifetime).
 */
export function markTicketFiled(convId: string | null | undefined, nowMs: number = Date.now()): void {
  if (!convId) return;
  const s = store();
  for (const [key, ts] of s) {
    if (nowMs - ts > TTL_MS) s.delete(key);
  }
  s.set(convId, nowMs);
}

// --- MUS-1516: which ticket ids were filed, additive to the signal above ---
//
// The reader half (plugins/intercom/src/ticket-success-signal.ts) needs to know
// not just THAT a ticket was filed this conversation, but WHICH id(s) — so a
// quoted reference number can be checked against ids this conversation actually
// filed, instead of licensing any 9-character token once a ticket exists at all.
//
// Design call ① (MUS-1471 CTO comment): a NEW globalThis key, value shape
// Map<convId, {atMs, ids:string[]}> — NOT a repointed value on SIGNAL_KEY above.
// The two guards (handoff-claim verb check, reference-id check) are independently
// bundled across two plugins sharing one process; widening the existing Map's
// value would open a deploy-skew window where the working guard misreads a live
// object as a lost signal. An additive key leaves the shipped guard behaviorally
// byte-identical and lets the new check no-op until both halves have deployed.
const IDS_KEY = "__musoSupportTicketIds";

type IdsStore = Map<string, { atMs: number; ids: string[] }>;

function idsStore(): IdsStore {
  const g = globalThis as unknown as Record<string, unknown>;
  const existing = g[IDS_KEY];
  if (existing instanceof Map) return existing as IdsStore;
  const created: IdsStore = new Map();
  g[IDS_KEY] = created;
  return created;
}

/**
 * Record that `ticketId` was filed for `convId` at `nowMs`. Called from BOTH
 * create-ticket.ts call sites — the fresh-create path and the append-to-existing
 * (follow-up comment) path — so either one backs the id for the reference-id
 * guard. No-ops on an empty convId/ticketId (mirrors markTicketFiled). Ids
 * accumulate per conversation (a conversation can file more than one ticket) and
 * de-dupe on repeat writes of the same id. Sweeps expired entries opportunistically
 * (same TTL/pattern as markTicketFiled above).
 */
export function markTicketId(
  convId: string | null | undefined,
  ticketId: string | null | undefined,
  nowMs: number = Date.now(),
): void {
  if (!convId || !ticketId) return;
  const s = idsStore();
  for (const [key, entry] of s) {
    if (nowMs - entry.atMs > TTL_MS) s.delete(key);
  }
  const existing = s.get(convId);
  if (existing) {
    if (!existing.ids.includes(ticketId)) existing.ids.push(ticketId);
    existing.atMs = nowMs;
  } else {
    s.set(convId, { atMs: nowMs, ids: [ticketId] });
  }
}

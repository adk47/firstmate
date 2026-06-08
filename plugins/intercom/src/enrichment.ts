import type { AccountSnapshot, ClassifiedEvent, EnrichmentState, IntercomSessionState } from "./types.js";

export const DEFAULT_ENRICH_TIMEOUT_MS = 2500;

// Intercom-verified identity for a logged-in customer, lifted straight from the
// webhook author object (never from message text). `email` is required (the
// lookup key); `name`/`contactId` ride along for greeting + history.
export interface VerifiedIdentity {
  email: string;
  name?: string;
  contactId?: string;
}

// Gate: decide whether to run personalization enrichment for this turn. Pure +
// side-effect-free so it can be unit-tested as a truth table. Enrichment is
// expensive (live API calls) and identity-sensitive, so we only proceed when
// ALL hold:
//   - the feature flag is on for this account,
//   - we have a session to cache into,
//   - this is a customer message from a verified `type: "user"` author,
//   - that author carries a verified email,
//   - we haven't already successfully enriched this conversation.
// A prior FAILED enrichment is retried; a prior DONE one is not.
export function shouldEnrich(params: {
  enabled: boolean;
  classified: ClassifiedEvent;
  state: IntercomSessionState | null;
}): boolean {
  const { enabled, classified, state } = params;
  if (!enabled || !state) return false;
  if (classified.kind !== "customer_message") return false;
  if (classified.authorType !== "user") return false;
  if (!classified.verifiedEmail) return false;
  // Re-run only if we never succeeded — a prior "failed" is retried, a "done"
  // is cached for the life of the conversation.
  if (state.enrichment?.status === "done") return false;
  return true;
}

// Look up a customer's read-only account snapshot by verified email. Returns
// the snapshot, or null when there's no single confident match (no result,
// ambiguous, or lookup unavailable). `timeoutMs` bounds the call.
export type SnapshotLookup = (
  email: string,
  opts: { timeoutMs: number },
) => Promise<AccountSnapshot | null>;

export interface EnrichDeps {
  lookupSnapshot: SnapshotLookup;
  timeoutMs?: number;
  log?: { warn?: (msg: string) => void };
}

// Populate `state.enrichment` for one conversation. Best-effort by contract:
// it records the (free) Intercom-verified identity FIRST so a by-name greeting
// works even when the profile lookup fails, then attempts the snapshot lookup.
// Never throws — a failed lookup is recorded as `status: "failed"` so a later
// turn retries it (see shouldEnrich).
export async function enrichSession(
  state: IntercomSessionState,
  identity: VerifiedIdentity,
  deps: EnrichDeps,
): Promise<void> {
  const timeoutMs = deps.timeoutMs ?? DEFAULT_ENRICH_TIMEOUT_MS;
  // Record the verified identity FIRST — it's free (already in the webhook) and
  // lets Caroline greet by name even if the snapshot lookup below fails.
  const base: EnrichmentState = {
    status: "done",
    enrichedAt: new Date().toISOString(),
    verifiedEmail: identity.email,
    verifiedName: identity.name,
    contactId: identity.contactId,
  };
  try {
    const snapshot = await deps.lookupSnapshot(identity.email, { timeoutMs });
    state.enrichment = { ...base, ...(snapshot ? { snapshot } : {}) };
  } catch (err) {
    // Best-effort: keep the identity (greeting works), mark failed so the next
    // turn retries the lookup. Never propagate to the dispatch path.
    deps.log?.warn?.(`[intercom] enrichment lookup failed: ${err}`);
    state.enrichment = { ...base, status: "failed" };
  }
}

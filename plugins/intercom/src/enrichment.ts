import type { AccountSnapshot, ClassifiedEvent, ContactConversationsPage, EnrichmentState, IntercomSessionState } from "./types.js";

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
  // Prior-chat recall: one page of this verified contact's conversations from
  // Intercom (most recent first) plus the total match count. Optional — when
  // absent, enrichment is snapshot-only (Phase 1 behavior). `timeoutMs` bounds
  // the call to the same enrichment budget as the snapshot lookup.
  listPriorConversations?: (
    contactId: string,
    opts: { timeoutMs: number },
  ) => Promise<ContactConversationsPage>;
  timeoutMs?: number;
  log?: { warn?: (msg: string) => void };
}

// Reduce a contact's conversation page to the context-block pointer: count of
// PRIOR conversations + a most-recent reference (title, falling back to the
// message snippet). The count comes from totalCount — the fetched window may
// be smaller than the contact's history. The client already excludes the
// current conversation server-side; the filter here is belt-and-braces for
// callers that don't (and adjusts the count when it catches one).
// Pure for unit-testing.
function summarizePriorChats(
  page: ContactConversationsPage,
  currentConversationId: string,
): NonNullable<EnrichmentState["priorChats"]> {
  const prior = page.conversations.filter((c) => c.id !== currentConversationId);
  const excluded = page.conversations.length - prior.length;
  const count = Math.max(page.totalCount - excluded, prior.length);
  if (count === 0) return { count: 0 };
  const mostRecent = prior[0]; // client returns most-recent-first
  const ref = mostRecent?.title ?? mostRecent?.snippet;
  return {
    count,
    ...(ref ? { mostRecentTitle: ref } : {}),
    ...(mostRecent?.updatedAt ? { mostRecentAt: mostRecent.updatedAt } : {}),
  };
}

// Populate `state.enrichment` for one conversation. Best-effort by contract:
// it records the (free) Intercom-verified identity FIRST so a by-name greeting
// works even when the lookups fail, then attempts the account snapshot and
// prior-chat lookups in PARALLEL — the legs are independent, so one failing
// never costs the other's facts. Never throws — any leg failure is recorded as
// `status: "failed"` so a later turn retries the missing half (see shouldEnrich).
export async function enrichSession(
  state: IntercomSessionState,
  identity: VerifiedIdentity,
  deps: EnrichDeps,
): Promise<void> {
  const timeoutMs = deps.timeoutMs ?? DEFAULT_ENRICH_TIMEOUT_MS;
  // Record the verified identity FIRST — it's free (already in the webhook) and
  // lets Caroline greet by name even if the lookups below fail.
  const base: EnrichmentState = {
    status: "done",
    enrichedAt: new Date().toISOString(),
    verifiedEmail: identity.email,
    verifiedName: identity.name,
    contactId: identity.contactId,
  };

  const [snapRes, priorRes] = await Promise.allSettled([
    deps.lookupSnapshot(identity.email, { timeoutMs }),
    deps.listPriorConversations && identity.contactId
      ? deps.listPriorConversations(identity.contactId, { timeoutMs })
      : Promise.resolve(null),
  ]);

  const snapshot = snapRes.status === "fulfilled" ? snapRes.value : null;
  const priorChats =
    priorRes.status === "fulfilled" && priorRes.value
      ? summarizePriorChats(priorRes.value, state.conversationId)
      : undefined;

  const anyFailed = snapRes.status === "rejected" || priorRes.status === "rejected";
  if (anyFailed) {
    const err = snapRes.status === "rejected" ? snapRes.reason : (priorRes as PromiseRejectedResult).reason;
    deps.log?.warn?.(`[intercom] enrichment lookup failed: ${err}`);
  }

  state.enrichment = {
    ...base,
    ...(anyFailed ? { status: "failed" as const } : {}),
    ...(snapshot ? { snapshot } : {}),
    ...(priorChats ? { priorChats } : {}),
  };
}

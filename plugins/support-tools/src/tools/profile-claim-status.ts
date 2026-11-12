import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";
import { deriveConvId } from "./dedupe-check.js";
import { sanitizeStr, classifyOwnership, type ProfileBody } from "./credit-verification-check.js";
import { resolveOwnerAnchor } from "../owner-anchor.js";
import { markOpenRequestFact } from "../request-state-signal.js";

// profile_claim_status — READ-ONLY: the signed-in customer's OWN claim requests on one
// profile ("is my claim pending / rejected / already processed", and when it was submitted).
//
// It reads GET /admin/claiming (list, filtered by profilesIds) on the structurally GET-only
// MusoAdminClient — the verify/reject/revert writes share the prefix but are unreachable
// (regex excludes them AND only get() exists).
//
// Claim rows are PRIVATE (they carry the claiming team's email and the submitted proof
// links), so this tool FAILS CLOSED: no signed-in Intercom contact (resolveOwnerAnchor:
// role=user, external_id, contact older than 24 h) or a typed-email mismatch means NO claim
// rows at all. For a signed-in contact, only their OWN claim rows (claim team email == the
// contact's email) are returned — and even then never the proof-link contents.
//
// Nothing about ANY OTHER account's claims leaves this tool (caroline-read-state-tools-r1):
// no counts, no "someone else has a pending claim", no flags and no routing derived from other
// people's rows (a hand-off that fires only when a stranger has a pending claim is a one-bit
// answer about that stranger). The one public fact kept is whether the profile is claimed. And
// an `email` argument only selects a profile when it IS the signed-in contact's email: an
// address typed into the thread never picks whose profile is looked up. And there is
// NO claim-id parameter: the earlier `claim_id` argument fetched GET /admin/claiming/:id for
// whatever id was pasted into the thread and answered own / not_own / not_retrievable, which made
// a pasted id an oracle about someone else's claim. The caller's own rows already carry their ids.

// Own rows surfaced at most. More than one own row is already "multiple" (a person reconciles).
const MAX_CLAIMS = 20;
// The claim list for one profile is read WHOLE or declared unread. The API returns `total`
// for the filtered list and honours `page` (verified read-only against prod 2026-11-12; `offset`
// is NOT honoured). A capped first page used to be filtered for the customer's own rows, which
// was wrong twice: an own claim past the cap read as "you have no claim", and the cap fired on
// OTHER accounts' rows, so a stranger's claim count changed what this customer was told.
const CLAIMS_PAGE = 100;
const MAX_CLAIM_PAGES = 5;
const KNOWN_STATUSES = new Set(["pending", "processed", "rejected", "reverted", "closed"]);

const Parameters = Type.Object({
  profile_id: Type.Optional(Type.String({ description: "Bare Muso profile UUID" })),
  profile_url: Type.Optional(Type.String({ description: "Full https://muso.ai/profile/<uuid> URL" })),
  email: Type.Optional(Type.String({ description: "Used to find the profile ONLY when it equals the signed-in contact's email; any other address is ignored. Never echoed back." })),
  name: Type.Optional(Type.String({ description: "Profile display name to resolve via search" })),
  requesterEmail: Type.Optional(
    Type.String({ description: "Customer's email as stated in the conversation. UNTRUSTED — only compared against the Intercom contact email; never the source of truth." }),
  ),
});

type Params = Static<typeof Parameters>;

export interface ProfileClaimStatusDeps {
  adminClient: MusoAdminClient;
  intercomReader: IntercomReader;
  rateLimiter: RateLimiter;
  sessionKey: string;
  intercomToken: string;
  /** Injected clock for the signed-in-contact age screen (tests). */
  nowSeconds?: () => number;
}

type OwnClaimState = "none" | "pending" | "processed" | "rejected" | "reverted" | "closed" | "multiple" | "unknown";
// `profile_claimed_by_other` is the public catalog fact (the profile page shows it is claimed).
// Pending claims by other accounts are private and are never a value here.
type ClaimConflict = "none" | "profile_claimed_by_other";
type SupportAction = "answer_from_status" | "ask_missing_info" | "create_handoff_ticket" | "human_review";

// Raw claim row as the admin list/get endpoints return it (shape verified
// against muso-cli internal/cli/claiming.go claimingItem).
export interface ClaimRow {
  id?: string | number;
  status?: string;
  reason?: string;
  profileId?: string;
  verificationLinks?: unknown;
  createdAt?: string;
  team?: { email?: string; name?: string };
}

// No `reason`: the admin row's `reason` is the claim TYPE, not why anything was decided, and a
// decline carries no reason. A field by that name next to "rejected" invites one to be stated.
export interface OwnClaim {
  claim_id: string;
  status: string;
  created_at: string;
  has_verification_links: boolean;
}

function lc(s: string | null | undefined): string {
  return (s ?? "").toLowerCase();
}

function hasVerificationLinks(raw: unknown): boolean {
  if (raw === null || raw === undefined) return false;
  if (Array.isArray(raw)) return raw.length > 0;
  if (typeof raw === "string") return raw.trim().length > 0 && raw.trim() !== "[]" && raw.trim() !== "null";
  if (typeof raw === "object") return Object.keys(raw as object).length > 0;
  return false;
}

function toOwnClaim(row: ClaimRow): OwnClaim {
  const status = lc(String(row.status ?? ""));
  return {
    claim_id: sanitizeStr(String(row.id ?? "")),
    status: KNOWN_STATUSES.has(status) ? status : "unknown",
    created_at: sanitizeStr(row.createdAt ?? ""),
    has_verification_links: hasVerificationLinks(row.verificationLinks),
  };
}

export type ClaimListRead = { ok: false } | { ok: true; rows: ClaimRow[]; complete: boolean };

// Reads every claim row of one profile. `complete` is PROVEN, never assumed: the distinct ids
// collected must reach the API's own `total`. Anything short of that (no total on a full page, a
// later page that fails or brings nothing new, a row without an id, more pages than the cap) is
// an incomplete read, and the caller must not conclude anything from the rows it did not see.
export async function readClaimList(adminClient: MusoAdminClient, profileId: string): Promise<ClaimListRead> {
  const base = `/api/v3/admin/claiming?profilesIds=${encodeURIComponent(profileId)}&limit=${CLAIMS_PAGE}`;
  const seen = new Map<string, ClaimRow>();
  let total = -1; // set from page 1, never negative after it
  for (let page = 1; page <= MAX_CLAIM_PAGES; page++) {
    const resp = await adminClient.get<{ data?: { items?: ClaimRow[]; total?: number } }>(page === 1 ? base : `${base}&page=${page}`);
    if (!resp.ok) {
      if (page === 1) return { ok: false };
      break;
    }
    const inner = (resp.data as any)?.data ?? resp.data ?? {};
    // A 200 without the expected items array is schema drift, NOT "zero claims": never tell a
    // customer nothing is pending off a malformed response (same rule as credit_verification_check).
    if (!Array.isArray(inner.items)) {
      if (page === 1) return { ok: false };
      break;
    }
    const items = inner.items as ClaimRow[];
    if (page === 1) {
      const t = inner.total;
      // No total: only a short first page is provably the whole list.
      if (typeof t !== "number" || !Number.isFinite(t) || t < 0) return { ok: true, rows: items, complete: items.length < CLAIMS_PAGE };
      total = t;
    }
    // Without an id a repeated page cannot be told from a new one, so only a first page that
    // already holds the whole list is complete.
    if (items.some((r) => r.id === undefined || r.id === null || String(r.id) === "")) {
      return { ok: true, rows: [...seen.values(), ...items], complete: page === 1 && items.length >= total };
    }
    let added = 0;
    for (const row of items) {
      const id = String(row.id);
      if (!seen.has(id)) {
        seen.set(id, row);
        added++;
      }
    }
    if (seen.size >= total || added === 0) break;
  }
  return { ok: true, rows: [...seen.values()], complete: total >= 0 && seen.size >= total };
}

function structuredFailure(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ found: false, reason, ...extra }));
}

// Fail-closed verdict — mirrors credit_verification_check: no claim data of
// any kind leaves the tool on an unverifiable identity.
export function failClosedVerdict(notes: string[] = []): Record<string, unknown> {
  return {
    found: false,
    owner_undetermined: true,
    impersonation_flag: false,
    own_claim_state: "none",
    own_claims: [],
    claim_conflict: "none",
    suspicion_flags: [],
    support_action: "human_review",
    notes: notes.map((n) => sanitizeStr(n)),
  };
}

export interface ClaimDiagnosisInput {
  own_claim_state: OwnClaimState;
  claim_conflict: ClaimConflict;
  suspicion_flags: string[];
  profile_state: "claimed_by_customer" | "claimed_by_other" | "unclaimed";
  // Internal only, never serialised: the claim list could not be read in full, so "you have no
  // claim here" is not a measured fact (own_claim_state is "unknown", never "none") and a person
  // reviews it. An incomplete read is about the READ, not about how many rows anyone has.
  needs_person?: boolean;
}

export function supportActionFor(input: ClaimDiagnosisInput): SupportAction {
  switch (input.own_claim_state) {
    case "pending":
      // The clean case (single own pending claim, nothing contested, nothing
      // ownership-sensitive) is a fact Caroline can state. Anything else goes to a person.
      // This tool never routes to a claim write: claims are decided by the claims team.
      return input.claim_conflict === "none" && input.suspicion_flags.length === 0 && !input.needs_person
        ? "answer_from_status"
        : "create_handoff_ticket";
    case "rejected":
    case "processed":
    case "closed":
      return "answer_from_status";
    case "reverted":
    case "multiple":
    case "unknown":
      return "create_handoff_ticket";
    default: // none: only ever reached on a list that was read whole
      if (input.claim_conflict !== "none") return "create_handoff_ticket";
      return "answer_from_status";
  }
}

export function diagnosisFor(input: ClaimDiagnosisInput): string {
  switch (input.own_claim_state) {
    case "pending":
      return input.claim_conflict === "none" && input.suspicion_flags.length === 0 && !input.needs_person
        ? "The customer has one pending claim of their own on this profile (own_claims carries the day it was submitted). State that it is open and when they submitted it; never an outcome, a reason or a date by which it will be decided."
        : "The customer has a pending claim of their own on this profile, and a person needs to review it — hand off with a profile-claim ticket.";
    case "rejected":
      return "The customer's own claim on this profile was closed without being approved. This tool carries NO reason and you never give, guess or imply one. If they ask why, use the approved answer-bank paragraph for a declined request and nothing else. If they want to claim again, the in-app claim flow.";
    case "processed":
      return "The customer's claim was already approved — the profile should be in their workspace; if they cannot see it, that is an access question, not a claim question.";
    case "closed":
      return "The customer's own claim on this profile is closed and is not open. This tool carries NO reason and you never give, guess or imply one. If they want to claim again, the in-app claim flow.";
    case "reverted":
      return "The customer's claim was approved and later REVERTED — a human must review before anything else happens.";
    case "multiple":
      return "The customer has multiple claim requests on this profile — a human should reconcile them.";
    case "unknown":
      if (input.needs_person)
        return "Whether the customer has a claim of their own on this profile could not be read. Never say they have none and never say they have one. Hand off with a profile-claim ticket.";
      return "The claim is in a state this tool does not recognize — route to a human.";
    default:
      if (input.claim_conflict === "profile_claimed_by_other")
        return "This profile is already claimed by a different workspace — contested ownership goes to a human with a profile-claim packet.";
      if (input.profile_state === "claimed_by_customer")
        return "The customer already owns this profile and has no open claim — nothing to claim.";
      return "The customer has no claim request of their own on this profile and it is unclaimed — guide the customer through the in-app claim flow.";
  }
}

export function createProfileClaimStatusTool(deps: ProfileClaimStatusDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, intercomReader, rateLimiter, sessionKey, intercomToken } = deps;

  async function fetchProfile(profileId: string): Promise<(ProfileBody & { name?: string }) | null> {
    const resp = await adminClient.get<{ data?: ProfileBody }>(`/api/v3/admin/profile/${encodeURIComponent(profileId)}`);
    if (!resp.ok) return null;
    return ((resp.data as any)?.data ?? resp.data ?? {}) as ProfileBody & { name?: string };
  }

  return {
    name: "profile_claim_status",
    label: "Profile Claim Status",
    description:
      "Read-only: the signed-in customer's OWN claim requests on one profile (status and the day each was submitted). Whose claims are read is decided by the conversation's signed-in Intercom contact and by nothing else: an email, a name or a claim id written in the thread never selects an account, and there is no claim-id parameter. " +
      "FAILS CLOSED (no claim data) when the contact is not signed in — claim rows are private. Returns only the customer's OWN claim rows (never proof-link contents) and NOTHING about any other account's claims on the profile. " +
      "It NEVER writes and decides nothing: state the status and date it returns, never an outcome, a reason or a date by which something will happen. Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionKey, "profile_claim_status", 60, 10).allowed) {
          return structuredFailure("rate_limited");
        }

        // Fail-closed gates, cheapest first — never touch the claiming
        // endpoints until the anti-spoof anchor is in hand.
        const convId = deriveConvId(sessionKey);
        if (!convId) return textResult(JSON.stringify(failClosedVerdict(["conversation id unavailable; cannot verify identity"])));
        if (!intercomToken) return textResult(JSON.stringify(failClosedVerdict(["intercom token unavailable; cannot verify identity"])));

        // The signed-in contact (role=user, external_id, older than 24 h), never the messenger
        // author email alone: a lead's email is typed in the browser.
        const anchor = await resolveOwnerAnchor({ sessionKey, intercomReader, intercomToken, nowSeconds: deps.nowSeconds });
        if (!anchor.ok) {
          return textResult(JSON.stringify(failClosedVerdict([
            `could not confirm a signed-in account on this conversation (${anchor.reason}); no claim state was read, routed for human verification`,
          ])));
        }
        const trustedEmail = anchor.email;

        const requester = params.requesterEmail?.trim() ? lc(params.requesterEmail.trim()) : null;
        if (requester && requester !== lc(trustedEmail)) {
          const v = failClosedVerdict(["the stated email does not match the verified contact email; routed for identity verification"]);
          v.impersonation_flag = true;
          return textResult(JSON.stringify(v));
        }

        // ---- resolve the profile ------------------------------------------
        let profileId: string | null = null;
        if (params.profile_id) profileId = params.profile_id.trim();
        else if (params.profile_url) profileId = extractProfileIdFromUrl(params.profile_url);

        // An email only selects a profile when it is the signed-in contact's own. Any other
        // address was typed by someone and must not decide whose profile is read.
        const typedEmail = params.email?.trim() ? lc(params.email.trim()) : null;
        const searchEmail = typedEmail && typedEmail === lc(trustedEmail) ? trustedEmail : null;
        const searchName = params.name?.trim() ? params.name.trim() : null;

        if (!profileId && !searchEmail && !searchName) {
          return structuredFailure("missing_input", {
            support_action: "ask_missing_info",
            missing_fields: ["profile URL"],
          });
        }

        let profileRow: (ProfileBody & { name?: string }) | null = null;
        if (profileId) {
          profileRow = await fetchProfile(profileId);
          if (!profileRow) return structuredFailure("lookup_unavailable");
        } else {
          const query = searchEmail ?? searchName ?? "";
          const searchResp = await adminClient.get<{ data?: Array<{ id?: string; name?: string }> }>(
            `/api/v3/admin/profile/search?keyword=${encodeURIComponent(query)}&limit=5`,
          );
          if (!searchResp.ok) return structuredFailure("lookup_unavailable");
          const results = ((searchResp.data as any)?.data ?? []) as Array<{ id?: string; name?: string }>;
          if (results.length === 0) return structuredFailure("no_match");
          if (results.length > 1) {
            return structuredFailure("multiple_matches", {
              matches: results.slice(0, 3).map((r) => sanitizeStr(r.name)),
              support_action: "ask_missing_info",
              missing_fields: ["profile URL"],
            });
          }
          profileId = String(results[0].id ?? "");
          if (!profileId) return structuredFailure("no_match");
          profileRow = await fetchProfile(profileId);
          if (!profileRow) return structuredFailure("lookup_unavailable");
        }

        const ownership = classifyOwnership(profileRow, trustedEmail);
        const notes: string[] = [];
        if (ownership === "shared") notes.push("the profile has multiple claimed workspaces (shared); ownership-sensitive actions need a human");
        let profile_state: ClaimDiagnosisInput["profile_state"];
        if (profileRow.isClaimed !== true) profile_state = "unclaimed";
        else profile_state = ownership === "not_owned" ? "claimed_by_other" : "claimed_by_customer";

        // ---- claim rows for this profile ----------------------------------
        const list = await readClaimList(adminClient, profileId);
        if (!list.ok) return structuredFailure("lookup_unavailable");
        const partial = !list.complete;
        // Neutral on purpose: how many claims a profile carries is other accounts' state.
        if (partial) notes.push("the claim list for this profile could not be read in full; a person needs to review it");

        // ---- partition own vs other ----------------------------------------
        const own = list.rows.filter((r) => lc(r.team?.email) === lc(trustedEmail));
        const own_claims = own.slice(0, MAX_CLAIMS).map(toOwnClaim);
        // Every other row is dropped here: not counted, not described, not flagged, and not
        // used to route. The only thing that sends this to a person is an unreadable list.
        const needs_person = partial;

        let own_claim_state: OwnClaimState;
        // "None" is a statement about the WHOLE list. On a partial read it is not known.
        if (own_claims.length === 0) own_claim_state = partial ? "unknown" : "none";
        else if (own_claims.length > 1) own_claim_state = "multiple";
        else own_claim_state = own_claims[0].status as OwnClaimState;

        // The `open_request` fact for the outbound guard (request-state-signal.ts). One-way on
        // purpose: an own PENDING claim is a measured open request, but "no pending claim" is not
        // "no open request" (a credit request may be open), so this tool never writes false.
        if (own.some((r) => toOwnClaim(r).status === "pending")) markOpenRequestFact(convId, true);

        const claim_conflict: ClaimConflict = profile_state === "claimed_by_other" ? "profile_claimed_by_other" : "none";

        // Flags come from the caller's OWN rows and the public ownership class only.
        const suspicion_flags: string[] = [];
        if (own_claim_state === "pending" && !own_claims[0].has_verification_links) suspicion_flags.push("own_claim_missing_verification_links");
        // A shared (multi-claimed-workspace) profile is ownership-sensitive
        // even for a co-claimer — never self-serve on it.
        if (ownership === "shared" && own_claim_state === "pending") suspicion_flags.push("shared_profile_ownership");

        const diagInput: ClaimDiagnosisInput = { own_claim_state, claim_conflict, suspicion_flags, profile_state, needs_person };
        const support_action = supportActionFor(diagInput);
        const diagnosis = diagnosisFor(diagInput);

        const handoff_packet =
          support_action === "create_handoff_ticket"
            ? {
                action_type: "profile-claim",
                customer_profile_id: profileId,
                own_claim_state,
                own_claim_ids: own_claims.map((c) => c.claim_id),
                claim_conflict,
                suspicion_flags,
                evidence: { profile_state },
              }
            : null;

        const output = {
          found: true,
          owner_undetermined: false,
          impersonation_flag: false,
          profile: {
            id: profileId,
            name: sanitizeStr(profileRow.name),
            is_claimed: profileRow.isClaimed === true,
            state: profile_state,
          },
          own_claim_state,
          own_claims,
          claim_conflict,
          suspicion_flags,
          diagnosis,
          support_action,
          notes,
          ...(handoff_packet ? { handoff_packet } : {}),
        };
        return textResult(JSON.stringify(output));
      } catch {
        // Any unexpected failure must fail CLOSED — never throw, never leak.
        return textResult(JSON.stringify(failClosedVerdict(["unexpected error during claim lookup; routed for human review"])));
      }
    },
  };
}

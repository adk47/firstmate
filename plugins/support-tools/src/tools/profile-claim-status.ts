import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";
import { deriveConvId } from "./dedupe-check.js";
import { sanitizeStr, classifyOwnership, type ProfileBody } from "./credit-verification-check.js";

// profile_claim_status — READ-ONLY claiming/identity resolver for "is my claim
// pending / rejected / already processed", "why can't I claim this profile",
// and claim-id discovery for the gated profiles_claim_self write (which needs
// a claimId it cannot find on its own).
//
// It reads GET /admin/claiming (list, filtered by profilesIds) and, when the
// customer supplies a claim id, GET /admin/claiming/:id. Both are newly
// allowlisted READ paths on the structurally GET-only MusoAdminClient — the
// verify/reject/revert writes share the prefix but are unreachable (regex
// excludes them AND only get() exists).
//
// Claim rows are PRIVATE (they carry the claiming team's email and the
// submitted proof links), so unlike profile_credits_status this tool FAILS
// CLOSED like credit_verification_check: no verified Intercom anchor or a
// typed-email mismatch means NO claim rows at all. For a verified contact,
// only their OWN claim rows (claim team email == verified contact email) are
// returned in detail — and even then never the proof-link contents. Claims by
// anyone else collapse to aggregate counters with no ids, emails, or links.

const MAX_CLAIMS = 20;
const KNOWN_STATUSES = new Set(["pending", "processed", "rejected", "reverted", "closed"]);

const Parameters = Type.Object({
  profile_id: Type.Optional(Type.String({ description: "Bare Muso profile UUID" })),
  profile_url: Type.Optional(Type.String({ description: "Full https://muso.ai/profile/<uuid> URL" })),
  email: Type.Optional(Type.String({ description: "Customer account email — used for lookup, never echoed back" })),
  name: Type.Optional(Type.String({ description: "Profile display name to resolve via search" })),
  claim_id: Type.Optional(Type.String({ description: "Claim request id the customer already has (e.g. from a claim-status email)" })),
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
}

type OwnClaimState = "none" | "pending" | "processed" | "rejected" | "reverted" | "closed" | "multiple" | "unknown";
type ClaimConflict = "none" | "pending_claim_by_other" | "profile_claimed_by_other";
type SupportAction = "answer_from_status" | "ask_missing_info" | "route_selfserve_claim" | "create_handoff_ticket" | "human_review";

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

export interface OwnClaim {
  claim_id: string;
  status: string;
  reason: string;
  created_at: string;
  has_verification_links: boolean;
}

interface OtherClaims {
  pending_count: number;
  prior_processed_or_reverted: boolean;
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
    reason: sanitizeStr(row.reason ?? ""),
    created_at: sanitizeStr(row.createdAt ?? ""),
    has_verification_links: hasVerificationLinks(row.verificationLinks),
  };
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
    other_claims: null,
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
}

export function supportActionFor(input: ClaimDiagnosisInput): SupportAction {
  switch (input.own_claim_state) {
    case "pending":
      // Self-serve only for the clean case: single own pending claim, no
      // competing claim, nothing suspicious. Security-sensitive states always
      // hand off (roadmap acceptance) — a suspicion flag or conflict
      // downgrades even the customer's own claim to a human packet.
      return input.claim_conflict === "none" && input.suspicion_flags.length === 0
        ? "route_selfserve_claim"
        : "create_handoff_ticket";
    case "rejected":
    case "processed":
    case "closed":
      return "answer_from_status";
    case "reverted":
    case "multiple":
    case "unknown":
      return "create_handoff_ticket";
    default: // none
      if (input.claim_conflict !== "none") return "create_handoff_ticket";
      return "answer_from_status";
  }
}

export function diagnosisFor(input: ClaimDiagnosisInput): string {
  switch (input.own_claim_state) {
    case "pending":
      return input.claim_conflict === "none" && input.suspicion_flags.length === 0
        ? "The customer has one pending claim on this profile and nothing conflicts — the self-serve claim flow can verify it (profiles_claim_self re-checks ownership server-side)."
        : "The customer has a pending claim, but a conflicting claim or a review-worthy signal exists — route a profile-claim packet for human review.";
    case "rejected":
      return "The customer's claim was rejected — explain the rejection reason and the resubmission path (proof requirements) per doctrine.";
    case "processed":
      return "The customer's claim was already approved — the profile should be in their workspace; if they cannot see it, that is an access question, not a claim question.";
    case "closed":
      return "The customer's claim was closed — explain the state and, if they want to claim again, the in-app claim flow.";
    case "reverted":
      return "The customer's claim was approved and later REVERTED — a human must review before anything else happens.";
    case "multiple":
      return "The customer has multiple claim requests on this profile — a human should reconcile them.";
    case "unknown":
      return "The claim is in a state this tool does not recognize — route to a human.";
    default:
      if (input.claim_conflict === "pending_claim_by_other")
        return "Someone else has a pending claim on this profile and the customer has none — a human must review contested ownership.";
      if (input.claim_conflict === "profile_claimed_by_other")
        return "This profile is already claimed by a different workspace — contested ownership goes to a human with a profile-claim packet.";
      if (input.profile_state === "claimed_by_customer")
        return "The customer already owns this profile and has no open claim — nothing to claim.";
      return "No claim requests exist for this profile and it is unclaimed — guide the customer through the in-app claim flow.";
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
      "Read-only claiming/identity diagnosis: is the customer's profile claim pending, rejected, already processed, or reverted; is there a competing claim; and what claim_id the self-serve claim flow should use. " +
      "Anchors to the verified Intercom contact email and FAILS CLOSED when identity cannot be verified — claim rows are private. Returns only the customer's OWN claim details (never proof-link contents); claims by others are aggregate counters only. " +
      "It NEVER writes — claim verification stays behind the gated profiles_claim_self / human paths. Rate limit: 10 calls / 60 min per session.",
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

        const trustedEmail = await intercomReader.getAuthorEmail(convId, intercomToken);
        if (!trustedEmail) return textResult(JSON.stringify(failClosedVerdict(["could not read the verified contact email; routed for human verification"])));

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

        if (!profileId && !params.email && !params.name) {
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
          const query = params.email ?? params.name ?? "";
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
        // Fetch one more than surfaced so a >MAX_CLAIMS profile is detectable
        // instead of a capped page silently reading as the complete set.
        const listResp = await adminClient.get<{ data?: { items?: ClaimRow[] } }>(
          `/api/v3/admin/claiming?profilesIds=${encodeURIComponent(profileId)}&limit=${MAX_CLAIMS + 1}`,
        );
        if (!listResp.ok) return structuredFailure("lookup_unavailable");
        const inner = (listResp.data as any)?.data ?? listResp.data ?? {};
        const rawItems = inner.items;
        // A 200 without the expected items array is schema drift, NOT "zero
        // claims" — never tell a customer nothing is pending off a malformed
        // response (same rule as credit_verification_check).
        if (!Array.isArray(rawItems)) return structuredFailure("lookup_unavailable");
        const truncated = rawItems.length > MAX_CLAIMS;
        if (truncated) notes.push(`more than ${MAX_CLAIMS} claim requests exist on this profile; this diagnosis is based on a truncated list`);
        const rows = (rawItems as ClaimRow[]).slice(0, MAX_CLAIMS);

        // ---- optional by-id lookup ----------------------------------------
        // GET /admin/claiming/:id answers ONLY pending or reverted claims;
        // processed/rejected/closed return {claiming:null} inside an HTTP 200
        // — that means "not retrievable by id", NOT "does not exist". The
        // list rows above remain the source of truth either way.
        let by_id_lookup: { claim_id: string; result: "own" | "not_own" | "not_retrievable_by_id" } | null = null;
        const claimIdParam = params.claim_id?.trim();
        if (claimIdParam) {
          const byId = await adminClient.get<{ data?: { claiming?: ClaimRow | null } }>(
            `/api/v3/admin/claiming/${encodeURIComponent(claimIdParam)}`,
          );
          const echoedId = sanitizeStr(claimIdParam);
          if (byId.ok) {
            const claiming = ((byId.data as any)?.data ?? byId.data ?? {}).claiming;
            if (claiming === null || claiming === undefined) {
              by_id_lookup = { claim_id: echoedId, result: "not_retrievable_by_id" };
              notes.push("the supplied claim id is not retrievable directly (already processed/rejected/closed, or wrong id); diagnosis uses the profile's claim list instead");
            } else {
              const row = claiming as ClaimRow;
              by_id_lookup = {
                claim_id: echoedId,
                result: lc(row.team?.email) === lc(trustedEmail) ? "own" : "not_own",
              };
            }
          }
          // by-id lookup failure is non-fatal — the list already answered.
        }

        // ---- partition own vs other ----------------------------------------
        const own = rows.filter((r) => lc(r.team?.email) === lc(trustedEmail));
        const others = rows.filter((r) => lc(r.team?.email) !== lc(trustedEmail));
        const own_claims = own.map(toOwnClaim);
        const other_claims: OtherClaims = {
          pending_count: others.filter((r) => lc(String(r.status ?? "")) === "pending").length,
          prior_processed_or_reverted: others.some((r) => ["processed", "reverted"].includes(lc(String(r.status ?? "")))),
        };

        let own_claim_state: OwnClaimState;
        if (own_claims.length === 0) own_claim_state = "none";
        else if (own_claims.length > 1) own_claim_state = "multiple";
        else own_claim_state = own_claims[0].status as OwnClaimState;

        const claim_conflict: ClaimConflict =
          other_claims.pending_count > 0
            ? "pending_claim_by_other"
            : profile_state === "claimed_by_other"
              ? "profile_claimed_by_other"
              : "none";

        const pendingTotal = rows.filter((r) => lc(String(r.status ?? "")) === "pending").length;
        const suspicion_flags: string[] = [];
        if (pendingTotal > 1) suspicion_flags.push("multiple_pending_claims_on_profile");
        if (rows.some((r) => lc(String(r.status ?? "")) === "reverted")) suspicion_flags.push("prior_reverted_claim_on_profile");
        if (own_claim_state === "pending" && !own_claims[0].has_verification_links) suspicion_flags.push("own_claim_missing_verification_links");
        // A shared (multi-claimed-workspace) profile is ownership-sensitive
        // even for a co-claimer — never self-serve on it.
        if (ownership === "shared" && own_claim_state === "pending") suspicion_flags.push("shared_profile_ownership");

        const diagInput: ClaimDiagnosisInput = { own_claim_state, claim_conflict, suspicion_flags, profile_state };
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
                evidence: {
                  profile_state,
                  other_pending_count: other_claims.pending_count,
                  prior_processed_or_reverted: other_claims.prior_processed_or_reverted,
                  truncated,
                },
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
          other_claims,
          claim_conflict,
          suspicion_flags,
          by_id_lookup,
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

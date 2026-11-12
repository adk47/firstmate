import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";
import { filterCreditsResults } from "./credits-search.js";
import { deriveConvId } from "./dedupe-check.js";
import {
  sanitizeStr,
  classifyOwnership,
  creditRequestRoles,
  requestedOn,
  type CreditRequestItem,
  type ProfileBody,
} from "./credit-verification-check.js";
import { resolveOwnerAnchor } from "../owner-anchor.js";
import { markOpenRequestFact } from "../request-state-signal.js";

// profile_credits_status — READ-ONLY diagnosis of a customer's credit/profile
// state for "my credit is missing / on the wrong profile / is there a
// duplicate / did my credit sync" tickets. It resolves the profile, scans for
// same-name duplicate CANDIDATES, checks whether a referenced credit exists on
// the resolved profile (and, when absent, on the candidates / a stated target
// profile), and reads the pending user-verification queue — then returns a
// structured diagnosis + the support action the router doctrine expects.
//
// It NEVER writes: this tool's MusoAdminClient is structurally GET-only. The
// self-serve WRITE paths it may point at (profiles_claim_self,
// profiles_consolidate) and the credit-correction/profile-merge handoffs stay
// behind their own gates.
//
// Ownership is anchored to the conversation's SIGNED-IN Intercom contact
// (deriveConvId → resolveOwnerAnchor: role=user, external_id, contact older
// than 24 h; a lead's email is typed in the browser and anchors nothing) but —
// unlike credit_verification_check, which lists private pending data — an
// unverifiable anchor DEGRADES this tool instead of failing it closed:
// claim/duplicate/credit-existence facts are exactly what public
// muso.ai shows, so they are returned with the ownership-derived
// fields marked owner_undetermined. Ownership-dependent self-serve routing is
// only ever suggested when the anchor verified.
//
// An `email` argument only selects a profile when it IS the signed-in
// contact's email: an address typed into the thread never decides whose
// profile is looked up (caroline-read-state-tools-r1).

const MAX_DUPLICATE_CANDIDATES = 5;
const MAX_MATCHED_TRACKS = 3;
const MAX_UVN_CREDITS = 100;

const Parameters = Type.Object({
  profile_id: Type.Optional(Type.String({ description: "Bare Muso profile UUID" })),
  profile_url: Type.Optional(Type.String({ description: "Full https://muso.ai/profile/<uuid> URL" })),
  email: Type.Optional(Type.String({ description: "Used to find the profile ONLY when it equals the signed-in contact's email; any other address is ignored. Never echoed back." })),
  name: Type.Optional(Type.String({ description: "Profile display name to resolve via search" })),
  target_profile_url: Type.Optional(
    Type.String({ description: "Profile URL the customer says the credit SHOULD be on (or wrongly is on), when different from their own" }),
  ),
  track_title: Type.Optional(Type.String({ description: "Track title of the credit in question" })),
  release_title: Type.Optional(Type.String({ description: "Release/album title named by the customer; echoed only as support context" })),
  credit_role: Type.Optional(Type.String({ description: "Credit role in question, e.g. Producer, Songwriter" })),
  requesterEmail: Type.Optional(
    Type.String({ description: "Customer's email as stated in the conversation. UNTRUSTED — only compared against the Intercom contact email; never the source of truth." }),
  ),
});

type Params = Static<typeof Parameters>;

export interface ProfileCreditsStatusDeps {
  adminClient: MusoAdminClient;
  intercomReader: IntercomReader;
  rateLimiter: RateLimiter;
  sessionKey: string;
  intercomToken: string;
  /** Injected clock (ms) for the signed-in-contact age screen and the open_request fact (tests). */
  now?: () => number;
}

/** One private queue for the verified sole owner: how many, and the first and last day requested. */
interface QueueDates {
  oldest_requested_on: string | null;
  newest_requested_on: string | null;
}

function queueDates(items: CreditRequestItem[]): QueueDates {
  const days = items.map(requestedOn).filter((d): d is string => !!d).sort();
  return { oldest_requested_on: days[0] ?? null, newest_requested_on: days[days.length - 1] ?? null };
}

type ProfileState =
  | "claimed_by_customer"
  | "claimed_by_other"
  | "unclaimed"
  | "owner_undetermined";
type CreditState =
  | "on_this_profile"
  | "on_other_profile"
  | "pending_verification"
  | "awaiting_review"
  | "not_found"
  | "not_checked";
type ClaimState = "unclaimed" | "claimed_same_owner" | "claimed_different_user" | "unresolved";
type AskClassification =
  | "credit_add"
  | "credit_move"
  | "duplicate_cleanup"
  | "profile_claim"
  | "credit_verification"
  | "credit_awaiting_review"
  | "unclear";
type SupportAction =
  | "answer_from_status"
  | "ask_missing_info"
  | "route_selfserve_claim"
  | "route_selfserve_consolidate"
  | "create_handoff_ticket"
  | "human_review";

interface MatchedTrack {
  title: string;
  roles: string[];
  release_date: string;
}

interface DuplicateCandidate {
  profile_id: string;
  name: string;
  is_claimed: boolean;
  claim_state: ClaimState;
  credit_count: number;
  credit_found: boolean | null; // null = not checked (no track query, or credit already found on the resolved profile)
}

function structuredFailure(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ found: false, reason, ...extra }));
}

function lc(s: string | null | undefined): string {
  return (s ?? "").toLowerCase();
}

interface ProfileRow extends ProfileBody {
  name?: string;
  creditCount?: number;
}

// claim_state relative to the verified contact email — same vocabulary as
// dedupe_check's per-duplicate verdict so tickets read consistently.
export function claimStateFor(body: ProfileRow | null, trustedEmail: string | null): ClaimState {
  if (!body) return "unresolved";
  if (body.isClaimed !== true) return "unclaimed";
  if (!trustedEmail) return "unresolved";
  const claimedEmails = (Array.isArray(body.workspaces) ? body.workspaces : [])
    .filter((w) => w?.isClaimed === true)
    .map((w) => lc(w.email));
  return claimedEmails.includes(lc(trustedEmail)) ? "claimed_same_owner" : "claimed_different_user";
}

export interface DiagnosisInput {
  profile_state: ProfileState;
  credit_state: CreditState;
  credit_queried: boolean;
  duplicate_candidates: DuplicateCandidate[];
  target_profile_present: boolean;
  impersonation_flag: boolean;
  // Sole-claimed-workspace ownership (credit_verification_check's rule): only
  // a sole owner may be routed to self-serve consolidation — a co-claimer on a
  // shared band/manager profile must not fold profiles on their own.
  sole_owner: boolean;
  // The Intercom identity anchor resolved to a verified contact email. ALL
  // self-serve routing (claim included) requires it — an owner-undetermined
  // session gets a handoff, never a self-serve suggestion.
  anchor_verified: boolean;
  // Credits on the resolved profile in status `unverified` (waiting for OUR
  // review; nothing for the customer to do). undefined/null = not assessed.
  awaiting_review_count?: number | null;
  // The awaiting-review read hit its cap: the count is a floor, not exact.
  awaiting_review_truncated?: boolean;
}

// Evidence → what the customer is actually asking for. Priority order matters:
// a pending credit explains "missing" better than a blind add request, and a
// concrete wrong-profile finding beats a generic duplicate observation.
export function classifyAsk(input: DiagnosisInput): AskClassification {
  if (input.credit_state === "pending_verification") return "credit_verification";
  if (input.credit_state === "awaiting_review") return "credit_awaiting_review";
  if (input.credit_state === "on_other_profile") return "credit_move";
  if (input.credit_queried && input.credit_state === "not_found") return "credit_add";
  if (input.duplicate_candidates.length > 0) return "duplicate_cleanup";
  if (input.profile_state === "unclaimed") return "profile_claim";
  return "unclear";
}

export function supportActionFor(input: DiagnosisInput, ask: AskClassification): SupportAction {
  // A typed-vs-verified email mismatch taints every ownership-derived routing
  // decision — a human checks identity before anything self-serve or filed.
  if (input.impersonation_flag) return "human_review";
  switch (ask) {
    case "credit_verification":
    case "credit_awaiting_review":
      return "answer_from_status";
    case "credit_move":
    case "credit_add":
      return "create_handoff_ticket";
    case "duplicate_cleanup": {
      // Self-serve consolidation is only for a VERIFIED owner folding
      // unclaimed candidates into the profile they own; anything claimed or
      // owner-undetermined goes to the human-gated merge packet.
      const allUnclaimed = input.duplicate_candidates.every((d) => d.claim_state === "unclaimed");
      return input.sole_owner && input.profile_state === "claimed_by_customer" && allUnclaimed
        ? "route_selfserve_consolidate"
        : "create_handoff_ticket";
    }
    case "profile_claim":
      // profiles_claim_self re-anchors downstream, but the router contract is
      // that an owner-undetermined session is never POINTED at self-serve.
      return input.anchor_verified ? "route_selfserve_claim" : "create_handoff_ticket";
    default:
      return "answer_from_status";
  }
}

export function diagnosisFor(input: DiagnosisInput, ask: AskClassification): string {
  return baseDiagnosis(input, ask) + awaitingReviewNote(input);
}

function awaitingReviewNote(input: DiagnosisInput): string {
  const n = input.awaiting_review_count;
  if (typeof n !== "number" || n <= 0) return "";
  const shown = input.awaiting_review_truncated ? `More than ${n}` : `${n}`;
  return ` ${shown} credit(s) on this profile are awaiting our team's review: they are not missing and the customer does not need to do anything for them right now.`;
}

function baseDiagnosis(input: DiagnosisInput, ask: AskClassification): string {
  const dupNote =
    input.duplicate_candidates.length > 0
      ? ` ${input.duplicate_candidates.length} same-name profile(s) exist — duplicate CANDIDATES only, never confirmed duplicates (same-name distinct artists are common).`
      : "";
  switch (input.credit_state) {
    case "awaiting_review":
      return `The referenced credit was submitted and is waiting for our team to review: it is not missing, and the customer does not need to do anything right now. Do not ask for proof and do not promise a date.${dupNote}`;
    case "pending_verification":
      return `The referenced credit is in the pending verification queue, not missing — it is waiting on review/proof, so route the credit-verification flow.${dupNote}`;
    case "on_other_profile":
      return `The referenced credit exists but is attached to a different profile than the customer's — a credit move needs a human-executed correction.${dupNote}`;
    case "on_this_profile":
      return `The referenced credit is already visible on the resolved profile.${dupNote}`;
    case "not_checked":
      if (input.credit_queried) {
        return `Whether the referenced credit exists or is queued could not be fully assessed (see notes) — do not tell the customer it is missing.${dupNote}`;
      }
      break;
    case "not_found":
      return `The referenced credit was not found on the resolved profile${input.duplicate_candidates.length > 0 ? " or the same-name candidates checked" : ""} — likely a credit-add request for a human to review.${dupNote}`;
    default:
      break;
  }
  if (ask === "duplicate_cleanup") return `No specific credit was queried.${dupNote}`;
  if (ask === "profile_claim") return "The resolved profile is unclaimed — the customer can claim it via the self-serve claim flow.";
  return `Profile resolved; no specific credit was queried.${dupNote}`;
}

export function createProfileCreditsStatusTool(deps: ProfileCreditsStatusDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, intercomReader, rateLimiter, sessionKey, intercomToken } = deps;

  async function fetchProfile(profileId: string): Promise<ProfileRow | null> {
    const resp = await adminClient.get<{ data?: ProfileRow }>(`/api/v3/admin/profile/${encodeURIComponent(profileId)}`);
    if (!resp.ok) return null;
    return ((resp.data as any)?.data ?? resp.data ?? {}) as ProfileRow;
  }

  // Credit presence on ONE profile. null = the lookup itself failed (degrade,
  // never conflate with "not found").
  async function findCredit(profileId: string, trackTitle: string, creditRole?: string): Promise<MatchedTrack[] | null> {
    const qp = new URLSearchParams();
    qp.set("keyword", trackTitle);
    if (creditRole) qp.append("filter[]", creditRole);
    qp.set("limit", "100");
    qp.set("offset", "0");
    const resp = await adminClient.get<{ data?: Record<string, unknown> }>(
      `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?${qp}`,
    );
    if (!resp.ok) return null;
    const filtered = filterCreditsResults(((resp.data as any)?.data ?? resp.data ?? {}) as Record<string, unknown>);
    return filtered.credits.map((c) => ({
      title: sanitizeStr(c.trackTitle),
      roles: c.creditRoles.map((r) => sanitizeStr(r)),
      release_date: sanitizeStr(c.releaseDate),
    }));
  }

  return {
    name: "profile_credits_status",
    label: "Profile Credits Status",
    description:
      "Read-only diagnosis for missing-credit, wrong-profile, duplicate-profile, and did-my-credit-sync questions. Resolves the profile, scans same-name duplicate candidates, checks whether a referenced credit exists (here, on a candidate, or on a stated target profile), and — for the signed-in sole owner ONLY — reads the pending-verification queue and the queue of credits awaiting our team's review, with how many and the first and last day requested (private data; suppressed for anyone else; a failed read is null, never 0). Who the owner is comes from the conversation's signed-in Intercom contact and nothing else: an email, a name or an id written in the thread never selects an account. " +
      "Returns a structured diagnosis with the suggested support action (answer, ask for one missing fact, route self-serve claim/consolidate, or a ticket-ready handoff packet). " +
      "It NEVER writes — credit corrections and merges stay on their gated paths. Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionKey, "profile_credits_status", 60, 10).allowed) {
          return structuredFailure("rate_limited");
        }

        // Best-effort ownership anchor — degrades to owner_undetermined
        // instead of failing closed (public catalog facts only). The anchor is
        // the SIGNED-IN contact, never the messenger author email alone.
        const notes: string[] = [];
        const nowFn = deps.now ?? Date.now;
        let trustedEmail: string | null = null;
        const convId = deriveConvId(sessionKey);
        if (convId && intercomToken) {
          const anchor = await resolveOwnerAnchor({
            sessionKey,
            intercomReader,
            intercomToken,
            nowSeconds: () => Math.floor(nowFn() / 1000),
          });
          if (anchor.ok) trustedEmail = anchor.email;
        }
        if (!trustedEmail) notes.push("ownership could not be verified; claim ownership fields are undetermined");

        const requester = params.requesterEmail?.trim() ? lc(params.requesterEmail.trim()) : null;
        const impersonation_flag = !!trustedEmail && !!requester && requester !== lc(trustedEmail);
        if (impersonation_flag) {
          // Identity is tainted: keep the catalog facts but never ownership
          // claims or self-serve routing on a flagged identity.
          trustedEmail = null;
          notes.push("the stated email does not match the verified contact email; routed for identity verification");
        }

        // ---- resolve the profile ------------------------------------------
        let profileId: string | null = null;
        if (params.profile_id) profileId = params.profile_id.trim();
        else if (params.profile_url) profileId = extractProfileIdFromUrl(params.profile_url);

        // An email only selects a profile when it is the signed-in contact's
        // own; any other address was typed by someone and is ignored.
        const typedEmail = params.email?.trim() ? lc(params.email.trim()) : null;
        const searchEmail = trustedEmail && typedEmail === lc(trustedEmail) ? trustedEmail : null;
        const searchName = params.name?.trim() ? params.name.trim() : null;

        if (!profileId && !searchEmail && !searchName) {
          return structuredFailure("missing_input", {
            support_action: "ask_missing_info",
            missing_fields: ["profile URL"],
          });
        }

        let profile: ProfileRow | null = null;
        if (profileId) {
          profile = await fetchProfile(profileId);
          if (!profile) return structuredFailure("lookup_unavailable");
        } else {
          const query = searchEmail ?? searchName ?? "";
          const searchResp = await adminClient.get<{ data?: ProfileRow[] }>(
            `/api/v3/admin/profile/search?keyword=${encodeURIComponent(query)}&limit=${MAX_DUPLICATE_CANDIDATES}`,
          );
          if (!searchResp.ok) return structuredFailure("lookup_unavailable");
          const results = ((searchResp.data as any)?.data ?? []) as ProfileRow[];
          if (results.length === 0) return structuredFailure("no_match");
          if (results.length > 1) {
            // Ambiguity is a first-class outcome here: one missing public
            // identifier (the profile URL) unblocks the whole diagnosis.
            return structuredFailure("multiple_matches", {
              matches: results.slice(0, 3).map((r) => sanitizeStr(r.name)),
              support_action: "ask_missing_info",
              missing_fields: ["profile URL"],
            });
          }
          profileId = String(results[0].id ?? "");
          if (!profileId) return structuredFailure("no_match");
          profile = await fetchProfile(profileId);
          if (!profile) return structuredFailure("lookup_unavailable");
        }

        const profileName = sanitizeStr(profile.name);
        const ownership = classifyOwnership(profile, trustedEmail);
        let profile_state: ProfileState;
        if (profile.isClaimed !== true) profile_state = "unclaimed";
        else if (!trustedEmail) profile_state = "owner_undetermined";
        else profile_state = ownership === "not_owned" ? "claimed_by_other" : "claimed_by_customer";

        // ---- duplicate candidate scan -------------------------------------
        const duplicate_candidates: DuplicateCandidate[] = [];
        if (profileName) {
          const dupResp = await adminClient.get<{ data?: ProfileRow[] }>(
            `/api/v3/admin/profile/search?keyword=${encodeURIComponent(profileName)}&limit=${MAX_DUPLICATE_CANDIDATES}`,
          );
          if (dupResp.ok) {
            const seen = new Set<string>([profileId]);
            for (const row of (((dupResp.data as any)?.data ?? []) as ProfileRow[])) {
              const cid = String(row.id ?? "").trim();
              if (!cid || seen.has(cid)) continue;
              seen.add(cid);
              // Candidates only when the display name actually matches — the
              // search is a keyword match and can return unrelated profiles.
              if (lc(String(row.name ?? "")).trim() !== lc(profileName).trim()) continue;
              const body = await fetchProfile(cid);
              duplicate_candidates.push({
                profile_id: cid,
                name: sanitizeStr(row.name),
                is_claimed: body?.isClaimed === true,
                claim_state: claimStateFor(body, trustedEmail),
                credit_count: Number(body?.creditCount ?? 0),
                credit_found: null,
              });
              if (duplicate_candidates.length >= MAX_DUPLICATE_CANDIDATES) break;
            }
          } else {
            notes.push("duplicate-candidate scan unavailable; duplicates were not assessed");
          }
        }

        // ---- credit existence ---------------------------------------------
        const trackTitle = params.track_title?.trim() ?? "";
        const credit_queried = trackTitle.length > 0;
        let credit_state: CreditState = "not_checked";
        let matched_tracks: MatchedTrack[] = [];
        let credit_located_on: string | null = null;

        // Target profile the customer pointed at (where the credit should be,
        // or wrongly is) — resolved independently of the duplicate scan.
        const targetId = params.target_profile_url ? extractProfileIdFromUrl(params.target_profile_url) : null;
        let target_profile: { profile_id: string; is_claimed: boolean; claim_state: ClaimState; credit_found: boolean | null } | null = null;
        if (targetId && targetId !== profileId) {
          const targetBody = await fetchProfile(targetId);
          target_profile = {
            profile_id: targetId,
            is_claimed: targetBody?.isClaimed === true,
            claim_state: claimStateFor(targetBody, trustedEmail),
            credit_found: null,
          };
          if (!targetBody) notes.push("the stated target profile could not be loaded");
        }

        if (credit_queried) {
          const onPrimary = await findCredit(profileId, trackTitle, params.credit_role);
          if (onPrimary === null) {
            credit_state = "not_checked";
            notes.push("credit lookup unavailable on the resolved profile; credit presence was not assessed");
          } else if (onPrimary.length > 0) {
            credit_state = "on_this_profile";
            matched_tracks = onPrimary.slice(0, MAX_MATCHED_TRACKS);
          } else {
            credit_state = "not_found";
            // Not on the customer's profile — check the stated target, then
            // the same-name candidates, to catch the wrong-profile case.
            if (target_profile) {
              const onTarget = await findCredit(targetId!, trackTitle, params.credit_role);
              target_profile.credit_found = onTarget === null ? null : onTarget.length > 0;
              if (onTarget && onTarget.length > 0) {
                credit_state = "on_other_profile";
                credit_located_on = targetId;
                matched_tracks = onTarget.slice(0, MAX_MATCHED_TRACKS);
              }
            }
            if (credit_state === "not_found") {
              for (const cand of duplicate_candidates) {
                const onCand = await findCredit(cand.profile_id, trackTitle, params.credit_role);
                cand.credit_found = onCand === null ? null : onCand.length > 0;
                if (onCand && onCand.length > 0 && credit_state === "not_found") {
                  credit_state = "on_other_profile";
                  credit_located_on = cand.profile_id;
                  matched_tracks = onCand.slice(0, MAX_MATCHED_TRACKS);
                }
              }
            }
          }
        }

        // ---- pending verification queue ------------------------------------
        // UVN queue state is PRIVATE (credit_verification_check fails closed
        // before exposing it), so it is read ONLY for the verified sole owner
        // of the resolved profile — unlike the public catalog facts above,
        // which degrade. A non-owner must not learn whether/what is pending.
        let pending: ({ count: number; truncated: boolean; referenced_track_pending: boolean } & QueueDates) | null = null;
        let awaiting_review: ({ count: number; truncated: boolean; referenced_track_awaiting_review: boolean } & QueueDates) | null = null;
        if (ownership === "owned") {
          // Fetch one more than surfaced so >MAX profiles are detectable
          // (same truncation guard as credit_verification_check).
          const uvnResp = await adminClient.get<{ data?: { items?: Array<{ spotifyTrackTitle?: string }> } }>(
            `/api/v3/admin/credit-requests?profilesIds=${encodeURIComponent(profileId)}&status=user_verification_needed&limit=${MAX_UVN_CREDITS + 1}`,
          );
          if (uvnResp.ok) {
            const items = (uvnResp.data as any)?.data?.items;
            if (Array.isArray(items)) {
              const truncated = items.length > MAX_UVN_CREDITS;
              const surfaced = items.slice(0, MAX_UVN_CREDITS) as CreditRequestItem[];
              const referenced_track_pending =
                credit_queried && surfaced.some((it) => lc(String(it.spotifyTrackTitle ?? "")).includes(lc(trackTitle)));
              pending = { count: surfaced.length, truncated, referenced_track_pending, ...queueDates(surfaced) };
              if (credit_state === "not_found" && referenced_track_pending) {
                credit_state = "pending_verification";
              }
            }
          }
          if (!pending) notes.push("pending-verification queue unavailable; sync state was not assessed");
          // Credits waiting for OUR review (status `unverified`). Read for the
          // same verified sole owner only, independent of the UVN read. A
          // failed read stays null: it must never become "nothing is pending"
          // to the customer.
          const arResp = await adminClient.get<{ data?: { items?: CreditRequestItem[] } }>(
            `/api/v3/admin/credit-requests?profilesIds=${encodeURIComponent(profileId)}&status=unverified&limit=${MAX_UVN_CREDITS + 1}`,
          );
          const arItems = arResp.ok ? (arResp.data as any)?.data?.items : undefined;
          if (Array.isArray(arItems)) {
            const arSurfaced = arItems.slice(0, MAX_UVN_CREDITS) as CreditRequestItem[];
            const wantedRole = params.credit_role?.trim() ? lc(params.credit_role.trim()) : null;
            awaiting_review = {
              count: arSurfaced.length,
              truncated: arItems.length > MAX_UVN_CREDITS,
              // Exact title match: a substring would let "Ghost Songs" stand in
              // for "Ghost Song" and tell the customer the wrong credit is queued.
              referenced_track_awaiting_review:
                credit_queried &&
                arSurfaced.some(
                  (it) =>
                    lc(String(it.spotifyTrackTitle ?? "").trim()) === lc(trackTitle) &&
                    (wantedRole === null || creditRequestRoles(it).some((r) => lc(r) === wantedRole)),
                ),
              ...queueDates(arSurfaced),
            };
            if (credit_state === "not_found" && awaiting_review.referenced_track_awaiting_review) {
              credit_state = "awaiting_review";
            } else if (credit_state === "not_found" && awaiting_review.truncated) {
              // Only the first MAX_UVN_CREDITS queued credits were searched, so
              // "not in the queue" is unproven: never file a credit-add for it.
              credit_state = "not_checked";
              notes.push(
                `more than ${MAX_UVN_CREDITS} credits are awaiting review and only the first ${MAX_UVN_CREDITS} were searched; whether the referenced credit is among them was not assessed, so do NOT tell the customer it is missing`,
              );
            }
          } else {
            // The referenced credit may be in the unread queue: never route it
            // as missing (no credit-add handoff) on a failed read.
            if (credit_state === "not_found") credit_state = "not_checked";
            notes.push("awaiting-review queue unavailable; do NOT tell the customer nothing is pending");
          }
          // The `open_request` fact for the outbound guard: written only from
          // what was MEASURED for the signed-in sole owner. Any open request is
          // true; false needs BOTH queues read and empty; an unread queue with
          // nothing found elsewhere writes nothing (unknown is not "none").
          const anyOpen = (pending?.count ?? 0) > 0 || (awaiting_review?.count ?? 0) > 0;
          if (anyOpen) markOpenRequestFact(convId, true, nowFn());
          else if (pending && awaiting_review) markOpenRequestFact(convId, false, nowFn());
        } else {
          notes.push("pending-verification state requires verified profile ownership; not assessed");
        }

        // ---- diagnosis ------------------------------------------------------
        const diagInput: DiagnosisInput = {
          profile_state,
          credit_state,
          credit_queried,
          duplicate_candidates,
          target_profile_present: !!target_profile,
          impersonation_flag,
          sole_owner: ownership === "owned",
          anchor_verified: !!trustedEmail,
          awaiting_review_count: awaiting_review?.count ?? null,
          awaiting_review_truncated: awaiting_review?.truncated ?? false,
        };
        const ask_classification = classifyAsk(diagInput);
        const support_action = supportActionFor(diagInput, ask_classification);
        const diagnosis = diagnosisFor(diagInput, ask_classification);

        const handoff_packet =
          support_action === "create_handoff_ticket"
            ? {
                action_type:
                  ask_classification === "duplicate_cleanup"
                    ? "profile-merge"
                    : ask_classification === "profile_claim"
                      ? "profile-claim"
                      : "credit-correction",
                customer_profile_id: profileId,
                credit_located_on,
                target_profile_id: target_profile?.profile_id ?? null,
                duplicate_profile_ids: duplicate_candidates.map((d) => d.profile_id),
                credit: credit_queried
                  ? {
                      track_title: sanitizeStr(trackTitle),
                      credit_role: sanitizeStr(params.credit_role ?? ""),
                      release_title: sanitizeStr(params.release_title ?? ""),
                    }
                  : null,
                evidence: {
                  profile_state,
                  credit_state,
                  pending_verification_count: pending?.count ?? null,
                  awaiting_review_count: awaiting_review?.count ?? null,
                },
              }
            : null;

        const output = {
          found: true,
          owner_undetermined: !trustedEmail,
          impersonation_flag,
          profile: {
            id: profileId,
            name: profileName,
            is_claimed: profile.isClaimed === true,
            state: profile_state,
            credit_count: Number(profile.creditCount ?? 0),
          },
          credit: {
            state: credit_state,
            queried: credit_queried,
            matched_tracks,
            located_on_profile_id: credit_located_on,
            pending,
            awaiting_review,
          },
          target_profile,
          duplicate_candidates,
          diagnosis,
          ask_classification,
          support_action,
          notes,
          customer_provided_context: {
            track_title: sanitizeStr(params.track_title ?? ""),
            release_title: sanitizeStr(params.release_title ?? ""),
            credit_role: sanitizeStr(params.credit_role ?? ""),
          },
          ...(handoff_packet ? { handoff_packet } : {}),
        };
        return textResult(JSON.stringify(output));
      } catch {
        // Any unexpected failure must degrade to a structured failure — never
        // throw and never fabricate a diagnosis.
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

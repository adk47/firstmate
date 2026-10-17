import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";
import { deriveConvId } from "./dedupe-check.js";

// credit_verification_check — READ-ONLY lookup for a customer's credits that are
// stuck in `user_verification_needed` (UVN). It anchors ownership to the
// Intercom contact's REAL email (anti-spoof), confirms the requester owns the
// profile, and returns a PII-safe structured list of that profile's pending
// credits (claimed role / track / artist / ISRC) for the
// `customer-credit-verification` skill to work from.
//
// It NEVER approves, never rejects, never writes, never reaches a credit-request
// mutation endpoint (this tool's MusoAdminClient is structurally GET-only). The only
// state change Caroline ever makes is filing a recommend-approve ticket via
// create_ticket; the irreversible PUT status=approved stays behind
// enforce_credit_approve_gate in muso-admin-api.sh, executed by a human/ops.
// Mirrors the dedupe_check pattern (plugins/support-tools/src/tools/dedupe-check.ts).

const MAX_PROFILE_CANDIDATES = 5; // bound the owner-resolution search
const MAX_UVN_CREDITS = 100;
const MAX_STR_LEN = 300;
const UUID_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";

// ---- pure helpers -----------------------------------------------------------

// conv-id is derived in-plugin from the session key (deriveConvId, imported
// from dedupe-check above so the anti-spoof anchor has exactly one definition
// in this plugin), NEVER taken as an agent parameter — otherwise a customer
// could point the anti-spoof at someone else's conversation.

// Strip the markers the gateway uses to fence trusted context so customer- or
// catalog-derived text (track/artist names can contain attacker-controlled
// strings) can't smuggle a fake [CONVERSATION_CONTEXT] block into the ticket the
// ops agent later reads (mirrors intercom/channel.ts INJECTION_MARKER_REGEX).
const INJECTION_MARKER_REGEX = /\[\/?(?:CONVERSATION_CONTEXT|CUSTOMER_MESSAGE)\]/gi;
export function stripInjectionMarkers(s: string): string {
  // Loop until stable: a single pass turns the nested
  // "[CUSTOMER_MESSAGE[CUSTOMER_MESSAGE]]" into a reconstructed live
  // "[CUSTOMER_MESSAGE]" marker.
  let out = s;
  let prev: string;
  do {
    prev = out;
    out = out.replace(INJECTION_MARKER_REGEX, "");
  } while (out !== prev);
  return out.trim();
}
export function sanitizeStr(s: unknown): string {
  // Coarse pre-bound: the strip loop is O(n²) on pathological marker-bombs.
  // No legitimate admin-API field approaches 100KB; a tight pre-slice (e.g.
  // MAX_STR_LEN) would NOT be behavior-identical (it can bisect a marker at
  // the cut and stripping can shrink a prefix arbitrarily), so bound coarsely.
  const bounded = String(s ?? "").slice(0, 100_000);
  return stripInjectionMarkers(bounded).slice(0, MAX_STR_LEN);
}

function lc(s: string | null | undefined): string {
  return (s ?? "").toLowerCase();
}

// ---- types ------------------------------------------------------------------

interface Workspace {
  email?: string;
  isClaimed?: boolean;
}
export interface ProfileBody {
  id?: string;
  isClaimed?: boolean;
  workspaces?: Workspace[];
}

// Raw credit-request item shape, confirmed against the live
// `GET /admin/credit-requests?profilesIds=<id>&status=user_verification_needed`
// endpoint by the pre-enable smoke (2026-06-15, 200/200 live UVN items):
// cr_id=.id, track TITLE=.spotifyTrackTitle, track ARTISTS=.spotifyTrackArtists[].name,
// role=.credits[] (string array), isrc=.metadata.isrc.
//
// The same smoke confirmed the three invariants the flag-gated flow relies on
// (re-confirm the first before each flag flip — it is server-side, and the tool
// keeps no per-item owner field to re-check it against):
//  1. the GET honors BOTH `profilesIds` AND `status=user_verification_needed`
//     server-side — a bogus profileId fails closed to an empty list rather than
//     leaking the global pool — so trusting the upstream filter is sound.
//  2. `limit=MAX_UVN_CREDITS+1` (101) is NOT clamped, so the truncation check
//     below (items.length > MAX_UVN_CREDITS) fires for >100-credit profiles.
//  3. `profile/search?keyword=<email>` does not surface workspace-claimed
//     profiles, so the no-URL owner-resolution path is safe-but-dead (each
//     candidate is re-ownership-checked regardless; the skill always asks for a
//     profile URL).
//
// The earlier `.spotifyTrackName`/`.title`/`.artist`/`.artists` guesses were
// absent on every live item and have been removed — hedges, not API surface.
export interface CreditRequestItem {
  id?: string;
  spotifyTrackTitle?: string;
  spotifyTrackArtists?: Array<string | { name?: string }>;
  credits?: Array<string | { child?: string }>;
  metadata?: { isrc?: string | null };
}

export interface UvnCredit {
  cr_id: string;
  role: string;
  track_title: string;
  artist: string;
  isrc: string | null;
}

export interface Verdict {
  // true only when the requester provably owns the profile via the Intercom
  // anti-spoof anchor. NOT an approval signal — it gates whether we may even
  // show this customer their own pending credits.
  verified_owner: boolean;
  // fail-closed sentinel: any unverifiable path (no token / convId / author
  // email / ownership) lands here, and uvn_credits is always empty.
  owner_undetermined: boolean;
  // typed email != Intercom contact email. When true the verdict is ALWAYS
  // fail-closed (no uvn_credits) — identity goes to human verification.
  impersonation_flag: boolean;
  profile_id: string | null;
  uvn_credits: UvnCredit[];
  count: number;
  // Credits in status `unverified`: submitted and waiting for OUR team's review.
  // Different from UVN above (where the customer must send proof): the customer
  // has nothing to do. null = not assessed (fail-closed verdict, or the lookup
  // failed); never read null as zero. Since 2026-10-11 this queue holds
  // thousands of credits, and reading only UVN told those customers "nothing
  // is pending".
  awaiting_review: { count: number; truncated: boolean } | null;
  // Per-status counts for the verified owner's profile; a status whose lookup
  // failed is null, not 0.
  pending_by_status: { user_verification_needed: number; unverified: number | null } | null;
  notes: string[];
}

export function failClosedVerdict(notes: string[] = []): Verdict {
  return {
    verified_owner: false,
    owner_undetermined: true,
    impersonation_flag: false,
    profile_id: null,
    uvn_credits: [],
    count: 0,
    awaiting_review: null,
    pending_by_status: null,
    notes: notes.map(sanitizeStr),
  };
}

function claimedWorkspaces(body: ProfileBody): Workspace[] {
  return (Array.isArray(body.workspaces) ? body.workspaces : []).filter((w) => w?.isClaimed === true);
}

// Ownership rule — the SAME sole-claimed-workspace rule as the dedupe template
// (dedupe-check.ts buildVerdict: claimed AND exactly ONE claimed workspace AND
// its email matches the server-verified Intercom contact email,
// case-insensitive). "shared" = a claimed workspace matches but OTHER claimed
// workspaces exist (band/manager profiles): one co-claimer must not unlock the
// profile's full pending list (it includes the other claimers' submissions),
// so shared profiles fail closed to a human.
type OwnershipClass = "owned" | "shared" | "not_owned";
export function classifyOwnership(body: ProfileBody | null, trustedEmail: string | null): OwnershipClass {
  if (!body || !trustedEmail) return "not_owned";
  if (body.isClaimed !== true) return "not_owned";
  // De-dupe claimed workspaces by email: duplicate rows carrying the OWNER'S
  // own email are still a sole owner, not a shared profile (the search path
  // de-dupes the analogous duplicate-candidate case).
  const claimedEmails = new Set(claimedWorkspaces(body).map((w) => lc(w.email)));
  if (!claimedEmails.has(lc(trustedEmail))) return "not_owned";
  return claimedEmails.size === 1 ? "owned" : "shared";
}
export function ownsProfile(body: ProfileBody | null, trustedEmail: string | null): boolean {
  return classifyOwnership(body, trustedEmail) === "owned";
}

function namesFrom(arr: unknown): string[] {
  return (Array.isArray(arr) ? arr : [])
    .map((a) => (typeof a === "string" ? a : String((a as { name?: string })?.name ?? "")))
    .filter(Boolean);
}

function extractArtist(item: CreditRequestItem): string {
  // Live shape: `.spotifyTrackArtists[].name` (confirmed populated 200/200 in
  // the pre-enable smoke).
  return namesFrom(item.spotifyTrackArtists).join(", ");
}

function extractTrackTitle(item: CreditRequestItem): string {
  // Live field is `.spotifyTrackTitle` (confirmed populated 200/200 in the
  // pre-enable smoke; the earlier `.spotifyTrackName`/`.title` guesses were
  // absent on every live item).
  return String(item.spotifyTrackTitle ?? "");
}

export function creditRequestRoles(item: CreditRequestItem): string[] {
  const arr = Array.isArray(item.credits) ? item.credits : [];
  return arr
    .map((c) => (typeof c === "string" ? c : String((c as { child?: string })?.child ?? "")))
    .filter(Boolean);
}

function extractRole(item: CreditRequestItem): string {
  return creditRequestRoles(item).join(", ");
}

export function toUvnCredit(item: CreditRequestItem): UvnCredit {
  const isrcRaw = item.metadata?.isrc;
  return {
    cr_id: sanitizeStr(item.id ?? ""),
    role: sanitizeStr(extractRole(item)),
    track_title: sanitizeStr(extractTrackTitle(item)),
    artist: sanitizeStr(extractArtist(item)),
    isrc: isrcRaw ? sanitizeStr(isrcRaw) : null,
  };
}

// ---- the tool ---------------------------------------------------------------

const Parameters = Type.Object({
  profileId: Type.Optional(
    Type.String({ pattern: UUID_PATTERN, description: "UUID of the profile whose pending credits to check. Optional — if omitted, the owned profile is resolved from the verified contact email. Ownership is ALWAYS re-verified server-side regardless." }),
  ),
  profileUrl: Type.Optional(
    Type.String({ description: "Full https://credits.muso.ai/profile/<uuid> URL of the profile to check (alternative to profileId)." }),
  ),
  requesterEmail: Type.Optional(
    Type.String({ description: "Customer's email as stated in the conversation. UNTRUSTED — only compared against the Intercom contact email; never the source of truth." }),
  ),
});

type Params = Static<typeof Parameters>;

export interface CreditVerificationCheckDeps {
  adminClient: MusoAdminClient;
  intercomReader: IntercomReader;
  rateLimiter: RateLimiter;
  sessionKey: string;
  intercomToken: string;
  // Phase-1 dark-ship gate (default OFF). When false the tool is registered but
  // returns a disabled sentinel before doing ANY work — a real mechanical flag,
  // not a doctrine line, so the flow cannot run until explicitly enabled per the
  // rollout. Mirrors the personalization flag-off pattern (PR #416).
  enabled: boolean;
}

function resolveId(id: string | undefined, url: string | undefined): string | null {
  if (id && id.trim()) return id.trim();
  if (url && url.trim()) return extractProfileIdFromUrl(url.trim());
  return null;
}

export function createCreditVerificationCheckTool(
  deps: CreditVerificationCheckDeps,
): AgentTool<typeof Parameters, unknown> {
  const { adminClient, intercomReader, rateLimiter, sessionKey, intercomToken, enabled } = deps;

  async function fetchProfileBody(profileId: string): Promise<ProfileBody | null> {
    const resp = await adminClient.get<{ data?: ProfileBody }>(
      `/api/v3/admin/profile/${encodeURIComponent(profileId)}`,
    );
    if (!resp.ok) return null;
    return ((resp.data as any)?.data ?? resp.data ?? {}) as ProfileBody;
  }

  // Resolve the profile the verified owner is asking about. If they named one,
  // we verify THEY own it. If not, search by their trusted email and pick the
  // single profile they own. On failure, profileId is null and failNote carries
  // the fail-closed note for the verdict (chosen at the point each case is
  // detected — every branch is fail-closed).
  async function resolveOwnedProfileId(
    explicitId: string | null,
    trustedEmail: string,
  ): Promise<{ profileId: string | null; failNote?: string }> {
    if (explicitId) {
      const body = await fetchProfileBody(explicitId);
      if (body === null) return { profileId: null, failNote: "could not load the requested profile; routed for human verification" };
      const cls = classifyOwnership(body, trustedEmail);
      if (cls === "owned") return { profileId: explicitId };
      return {
        profileId: null,
        failNote: cls === "shared"
          ? "shared profile (multiple claimed workspaces); routed for human verification"
          : "the verified contact does not own the requested profile; routed for human verification",
      };
    }
    const noOwnedNote = "could not resolve a profile owned by the verified contact; ask the customer for their profile URL";
    const searchResp = await adminClient.get<{ data?: Array<{ id?: string }> }>(
      `/api/v3/admin/profile/search?keyword=${encodeURIComponent(trustedEmail)}&limit=${MAX_PROFILE_CANDIDATES}`,
    );
    if (!searchResp.ok) return { profileId: null, failNote: noOwnedNote };
    const candidates = ((searchResp.data as any)?.data ?? []) as Array<{ id?: string }>;
    // De-dupe candidate ids: a search index that returns the same owned profile
    // twice must NOT count as two owned profiles and trip the multiple-owned
    // fail-closed below (which would wrongly block a legitimate sole owner).
    const seen = new Set<string>();
    const owned: string[] = [];
    for (const c of candidates.slice(0, MAX_PROFILE_CANDIDATES)) {
      const cid = String(c?.id ?? "").trim();
      if (!cid || seen.has(cid)) continue;
      seen.add(cid);
      const body = await fetchProfileBody(cid);
      if (ownsProfile(body, trustedEmail)) owned.push(cid);
    }
    if (owned.length === 1) return { profileId: owned[0] };
    if (owned.length > 1) return { profileId: null, failNote: "multiple owned profiles matched; ask the customer for the specific profile URL" };
    return { profileId: null, failNote: noOwnedNote };
  }

  async function fetchUvnCredits(profileId: string): Promise<CreditRequestItem[] | null> {
    // Fetch one MORE than we will surface so a profile with > MAX_UVN_CREDITS
    // pending credits is detectable (items.length > MAX_UVN_CREDITS) instead of
    // silently presenting a capped page as the complete set.
    const resp = await adminClient.get<{ data?: { items?: CreditRequestItem[] } }>(
      `/api/v3/admin/credit-requests?profilesIds=${encodeURIComponent(profileId)}&status=user_verification_needed&limit=${MAX_UVN_CREDITS + 1}`,
    );
    if (!resp.ok) return null;
    // A 200 whose body doesn't carry the expected `.data.items` array is schema
    // drift, NOT "zero pending credits" — treat it like a failed fetch so
    // Caroline never affirmatively tells a customer nothing is pending off a
    // malformed response.
    const items = (resp.data as any)?.data?.items;
    return Array.isArray(items) ? (items as CreditRequestItem[]) : null;
  }

  // Credits waiting for OUR review (status `unverified`). Count only: the
  // customer has nothing to act on, so no per-item list is surfaced. null on
  // any failure or schema drift, so the caller never reports a failed lookup
  // as "nothing pending".
  async function fetchAwaitingReview(profileId: string): Promise<{ count: number; truncated: boolean } | null> {
    const resp = await adminClient.get<{ data?: { items?: unknown[] } }>(
      `/api/v3/admin/credit-requests?profilesIds=${encodeURIComponent(profileId)}&status=unverified&limit=${MAX_UVN_CREDITS + 1}`,
    );
    if (!resp.ok) return null;
    const items = (resp.data as any)?.data?.items;
    if (!Array.isArray(items)) return null;
    return { count: Math.min(items.length, MAX_UVN_CREDITS), truncated: items.length > MAX_UVN_CREDITS };
  }

  return {
    name: "credit_verification_check",
    label: "Look up a customer's pending credits: needs-proof and awaiting-review (read-only)",
    description:
      "Read-only lookup of the credits a customer has stuck in 'user verification needed'. Anchors ownership to the Intercom contact's real email (anti-spoof), confirms the requester owns the profile, and returns a PII-safe structured list of pending credits (claimed role, track, artist, ISRC) for the credit-verification flow, plus awaiting_review (credits waiting for OUR review, where the customer has nothing to do) and pending_by_status counts. Never tell a customer nothing is pending unless BOTH counts are 0. " +
      "It NEVER approves, rejects, or writes anything — after verifying, ask the customer for proof and (when warranted) file a recommend-approve ticket via create_ticket for a human to execute the gated approval. " +
      "Fails closed (owner_undetermined) when ownership cannot be verified. Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Dark-ship gate (cheapest first): when the feature flag is off the tool
      // does nothing and surfaces a disabled sentinel so the agent falls back to
      // a normal ticket. No network, no Intercom, no admin call.
      if (!enabled) {
        return textResult(JSON.stringify({ disabled: true, note: "credit verification flow is not enabled" }));
      }
      if (!rateLimiter.check(sessionKey, "credit_verification_check", 60, 10).allowed) {
        return textResult(JSON.stringify({ error: "rate_limited" }));
      }

      try {
        // Fail-closed gates, cheapest first — never touch the network until the
        // anti-spoof anchor is in hand.
        const convId = deriveConvId(sessionKey);
        if (!convId) return textResult(JSON.stringify(failClosedVerdict(["conversation id unavailable; cannot verify ownership"])));
        if (!intercomToken) return textResult(JSON.stringify(failClosedVerdict(["intercom token unavailable; cannot verify ownership"])));

        const trustedAuthorEmail = await intercomReader.getAuthorEmail(convId, intercomToken);
        if (!trustedAuthorEmail) return textResult(JSON.stringify(failClosedVerdict(["could not read the verified contact email; routed for human verification"])));

        // Trim before comparing: stray whitespace in a relayed email must not
        // hard-stop a matching customer with a security-flavored refusal.
        const requester = params.requesterEmail?.trim() ? lc(params.requesterEmail.trim()) : null;
        const impersonation_flag = !!requester && requester !== lc(trustedAuthorEmail);
        // Mirrors the dedupe template: a typed-vs-Intercom email mismatch means
        // NO data is surfaced (dedupe's `verified` requires !impersonation_flag)
        // — the pending list must never sit in context on a flagged identity.
        if (impersonation_flag) {
          const v = failClosedVerdict(["the stated email does not match the verified contact email; routed for identity verification"]);
          v.impersonation_flag = true;
          return textResult(JSON.stringify(v));
        }

        const explicitId = resolveId(params.profileId, params.profileUrl);
        const { profileId, failNote } = await resolveOwnedProfileId(explicitId, trustedAuthorEmail);

        if (!profileId) {
          return textResult(JSON.stringify(failClosedVerdict([failNote ?? "could not verify ownership; routed for human verification"])));
        }

        const items = await fetchUvnCredits(profileId);
        if (items === null) {
          return textResult(JSON.stringify(failClosedVerdict(["could not load pending credits (ownership itself was verified); routed for human verification"])));
        }

        const truncated = items.length > MAX_UVN_CREDITS;
        const uvn_credits = items.slice(0, MAX_UVN_CREDITS).map(toUvnCredit);
        const notes: string[] = [];
        if (truncated) notes.push(`more than ${MAX_UVN_CREDITS} pending credits exist; this list is truncated and is NOT the full set`);
        // impersonation_flag:false must not read as "identity cross-check
        // passed" when no requesterEmail was supplied to compare.
        if (!requester) notes.push("requester email not provided; no impersonation cross-check performed");
        const awaiting_review = await fetchAwaitingReview(profileId);
        if (awaiting_review === null) {
          notes.push("the awaiting-review queue could not be read; do NOT tell the customer nothing is pending");
        } else if (awaiting_review.count > 0) {
          notes.push(
            `${awaiting_review.truncated ? `more than ${awaiting_review.count}` : awaiting_review.count} credit(s) are awaiting our team's review: not missing, and the customer does not need to do anything for those right now`,
          );
        }
        const verdict: Verdict = {
          verified_owner: true,
          owner_undetermined: false,
          impersonation_flag: false,
          profile_id: profileId,
          uvn_credits,
          count: uvn_credits.length,
          awaiting_review,
          pending_by_status: {
            user_verification_needed: uvn_credits.length,
            unverified: awaiting_review === null ? null : awaiting_review.count,
          },
          notes,
        };
        return textResult(JSON.stringify(verdict));
      } catch {
        // Any unexpected failure must fail CLOSED, never throw and never pass.
        return textResult(JSON.stringify(failClosedVerdict(["unexpected error during verification; routed for human review"])));
      }
    },
  };
}

import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";
import { deriveConvId } from "./dedupe-check.js";
import { checkProofOnFile, DEFAULT_PROOF_ON_FILE_PATH, type ProofOnFileResult } from "./proof-on-file.js";
import { resolveOwnerAnchor } from "../owner-anchor.js";
import { clearOpenRequestFact, markOpenRequestFact } from "../request-state-signal.js";

// credit_verification_check — READ-ONLY lookup of the signed-in customer's OWN open credit
// requests: the ones that need a document from them (`user_verification_needed`, UVN) and the
// ones waiting for our review (`unverified`), as counts and request dates, plus whether a
// document is already on file and the one boolean `open_request`.
//
// Whose requests: the conversation's SIGNED-IN Intercom contact (resolveOwnerAnchor: role=user,
// external_id, contact older than 24 h), and only for a profile that contact solely owns. There is
// no request-id parameter, and an email, a name or an id typed into the thread never selects whose
// data is read (caroline-read-state-tools-r1; a lead's messenger email is browser-typed, so the
// earlier `getAuthorEmail` anchor was not enough for a private read).
//
// It NEVER approves, never rejects, never writes, never reaches a credit-request
// mutation endpoint (this tool's MusoAdminClient is structurally GET-only). The irreversible
// PUT status=approved stays behind enforce_credit_approve_gate in muso-admin-api.sh, executed by
// a human/ops.

const MAX_PROFILE_CANDIDATES = 5; // bound the owner-resolution search
const MAX_UVN_CREDITS = 100;
const MAX_STR_LEN = 300;
// Step 2's proof ask carries this sentence verbatim (customer-credit-verification SKILL), so
// an earlier ask in another conversation is detectable: "none = ask ONCE" must hold across
// conversations, and an unanswered ask writes nothing to proof-on-file.
export const PROOF_ASK_MARKER = "Any one of these works (a link, photo or PDF is fine):";
// The sentence every ask carried until 2026-10-29 (message-book-1029 B1 changed it, captain 03:2xZ "just go"). An
// earlier ask is still an ask: both sentences always count, or a user asked before the change would be asked again.
export const LEGACY_PROOF_ASK_MARKER = "Any one of these works (a screenshot is fine):";
export const PRIOR_ASK_WINDOW_MS = 60 * 24 * 60 * 60 * 1000;
export const PRIOR_ASK_MAX_CONVERSATIONS = 10;
// Asks sent before the marker existed carry no fixed sentence (firstmate 039). Until this
// date (deploy + 60 days), a bot comment that names one of the customer's needs-proof track
// titles, or carries the old Step 2 phrase, also counts as an earlier ask. After it, only
// PROOF_ASK_MARKER counts.
export const PRE_MARKER_WINDOW_END_MS = Date.parse("2026-12-17T00:00:00Z");
export const PRE_MARKER_ASK_PHRASE = "screenshots are accepted for all of these";
const MIN_TITLE_MARKER_LEN = 3;

export function priorAskMarkers(uvnCredits: UvnCredit[], now: number): string[] {
  const markers = [PROOF_ASK_MARKER, LEGACY_PROOF_ASK_MARKER];
  if (now < PRE_MARKER_WINDOW_END_MS) {
    markers.push(PRE_MARKER_ASK_PHRASE);
    for (const c of uvnCredits) {
      const title = c.track_title.replace(/\s+/g, " ").trim();
      if (title.length >= MIN_TITLE_MARKER_LEN && !markers.includes(title)) markers.push(title);
    }
  }
  return markers;
}
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
  // When the request was submitted (same field scripts/credit_review/evidence.py reads off these
  // rows). Surfaced as a calendar date only; an absent or unparseable value is null, never guessed.
  createdAt?: string | null;
  // The submitting user (full row from GET /admin/credit-requests; `user` is its include).
  // Used only to look the submitter up in proof-on-file, never surfaced.
  userId?: number | string | null;
  user?: { id?: number | string | null } | null;
}

export interface UvnCredit {
  cr_id: string;
  role: string;
  track_title: string;
  artist: string;
  isrc: string | null;
  // The day the request was submitted (YYYY-MM-DD, UTC), or null when the row carries no readable date.
  requested_on: string | null;
}

/** A row's submission day as YYYY-MM-DD (UTC), or null. Never a guess, never "today". */
export function requestedOn(item: CreditRequestItem): string | null {
  const raw = item?.createdAt;
  if (typeof raw !== "string" || !raw.trim()) return null;
  const ms = Date.parse(raw);
  if (!Number.isFinite(ms)) return null;
  return new Date(ms).toISOString().slice(0, 10);
}

export interface AwaitingReview {
  count: number;
  truncated: boolean;
  // Oldest / newest submission day among the rows read (YYYY-MM-DD). null = no row carried a
  // readable date; when `truncated`, these cover only the rows read.
  oldest_requested_on: string | null;
  newest_requested_on: string | null;
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
  awaiting_review: AwaitingReview | null;
  // Per-status counts for the verified owner's profile; a status whose lookup
  // failed is null, not 0.
  pending_by_status: { user_verification_needed: number; unverified: number | null } | null;
  // Step 2's ask gate (firstmate 761): is proof already on file for this customer's
  // needs-proof credits? on_file = never ask; none = ask ONCE; asked_before = already asked
  // in another conversation, do NOT ask again; unknown = do NOT ask, route to a human. null = not assessed (no needs-proof credits, or a fail-closed verdict).
  proof_on_file: ProofOnFileResult | null;
  // The one boolean: does the signed-in owner have an open credit request right now?
  // true = at least one measured; false = BOTH queues measured empty; null = not measured
  // (fail-closed verdict, or a queue could not be read). null is never "no".
  open_request: boolean | null;
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
    proof_on_file: null,
    open_request: null,
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
    requested_on: requestedOn(item),
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
  // credit-trust's merged proof-on-file export (default: the same file the take-back gate
  // reads). Injected for tests.
  proofOnFilePath?: string;
  now?: () => number;
  // The Intercom admin Caroline replies as; its earlier Step 2 asks are looked up by it.
  // Empty = the lookup cannot run, so a "none" becomes "unknown" (no ask).
  botAdminId?: string;
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
  const proofOnFilePath = deps.proofOnFilePath ?? process.env.CREDIT_TRUST_PROOF_ON_FILE ?? DEFAULT_PROOF_ON_FILE_PATH;
  const nowFn = deps.now ?? Date.now;
  const botAdminId = deps.botAdminId ?? "";

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
  async function fetchAwaitingReview(profileId: string): Promise<AwaitingReview | null> {
    const resp = await adminClient.get<{ data?: { items?: CreditRequestItem[] } }>(
      `/api/v3/admin/credit-requests?profilesIds=${encodeURIComponent(profileId)}&status=unverified&limit=${MAX_UVN_CREDITS + 1}`,
    );
    if (!resp.ok) return null;
    const items = (resp.data as any)?.data?.items;
    if (!Array.isArray(items)) return null;
    const days = (items.slice(0, MAX_UVN_CREDITS) as CreditRequestItem[])
      .map(requestedOn)
      .filter((d): d is string => d !== null)
      .sort();
    return {
      count: Math.min(items.length, MAX_UVN_CREDITS),
      truncated: items.length > MAX_UVN_CREDITS,
      oldest_requested_on: days.length > 0 ? days[0] : null,
      newest_requested_on: days.length > 0 ? days[days.length - 1] : null,
    };
  }

  return {
    name: "credit_verification_check",
    label: "The signed-in customer's own open credit requests: counts, dates, document on file (read-only)",
    description:
      "Read-only lookup of the signed-in customer's OWN open credit requests. Whose requests are read is decided by the conversation's signed-in Intercom contact and by nothing else: an email, a name or a request id written in the thread never selects an account, and there is no request-id parameter. Returns the credits that need a document from them (uvn_credits: role, track, artist, requested_on), awaiting_review (credits waiting for OUR review: count, oldest_requested_on, newest_requested_on; the customer has nothing to do), pending_by_status counts, proof_on_file (is a document already on file for them) and open_request (true / false / null). Never tell a customer nothing is pending unless BOTH counts are 0, and never read null or 'unknown' as zero. " +
      "It NEVER approves, rejects or writes anything, and it decides nothing: state the counts and dates it returns, never an outcome, a reason or a date by which something will happen. " +
      "Fails closed (owner_undetermined, no data) when the contact is not signed in or does not solely own the profile. Rate limit: 10 calls / 60 min per session.",
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
        // A fresh read replaces whatever an earlier read in this conversation measured: every
        // path below that cannot measure leaves the open_request fact UNKNOWN, never stale.
        clearOpenRequestFact(convId);
        if (!intercomToken) return textResult(JSON.stringify(failClosedVerdict(["intercom token unavailable; cannot verify ownership"])));

        // The signed-in contact (role=user, external_id, older than 24 h), never the messenger
        // author email alone: a lead's email is typed in the browser.
        const anchor = await resolveOwnerAnchor({
          sessionKey,
          intercomReader,
          intercomToken,
          nowSeconds: () => Math.floor(nowFn() / 1000),
        });
        if (!anchor.ok) {
          return textResult(JSON.stringify(failClosedVerdict([
            `could not confirm a signed-in account on this conversation (${anchor.reason}); no request state was read, routed for human verification`,
          ])));
        }
        const trustedAuthorEmail = anchor.email;

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
        let proof_on_file: ProofOnFileResult | null = null;
        if (uvn_credits.length > 0) {
          const userIds = new Set<string>();
          for (const it of items) {
            const u = it.userId ?? it.user?.id;
            if (u !== null && u !== undefined && String(u)) userIds.add(String(u));
          }
          const now = nowFn();
          proof_on_file = checkProofOnFile(proofOnFilePath, userIds, uvn_credits.map((c) => c.cr_id), now);
          if (proof_on_file.state === "none") {
            const prior = botAdminId
              ? await intercomReader.findBotMarkerInOtherConversations({
                  conversationId: convId,
                  token: intercomToken,
                  botAdminId,
                  markers: priorAskMarkers(uvn_credits, now),
                  sinceUnix: Math.floor((now - PRIOR_ASK_WINDOW_MS) / 1000),
                  limit: PRIOR_ASK_MAX_CONVERSATIONS,
                })
              : "unknown";
            if (prior === "found") {
              proof_on_file = { state: "asked_before", reason: "we already asked this customer for proof in another conversation in the last 60 days" };
            } else if (prior !== "not_found") {
              proof_on_file = { state: "unknown", reason: "earlier proof requests in this customer's other conversations could not be checked" };
            }
          }
          if (proof_on_file.state === "on_file") {
            notes.push("proof is on file for this customer: never ask for proof again; you may tell them a document is on file for their requests, never whether it is enough");
          } else if (proof_on_file.state === "asked_before") {
            notes.push("we already asked this customer for proof in another conversation: do NOT ask again; hand off with a credit-verify ticket");
          } else if (proof_on_file.state === "none") {
            notes.push("no proof is on file for this customer: never tell them a document was received; if they ask what to send, the approved credit paragraph is the only proof wording");
          } else {
            notes.push(`proof-on-file could not be confirmed (${proof_on_file.reason}): do NOT ask for proof, and do NOT tell the customer nothing is needed; hand off with a credit-verify ticket`);
          }
        }
        // The one boolean. true needs one measured open request; false needs BOTH queues measured
        // empty; anything else is unknown and stays out of the cross-plugin fact.
        const open_request: boolean | null =
          uvn_credits.length > 0 || (awaiting_review !== null && awaiting_review.count > 0)
            ? true
            : awaiting_review === null
              ? null
              : false;
        if (open_request !== null) markOpenRequestFact(convId, open_request, nowFn());
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
          proof_on_file,
          open_request,
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

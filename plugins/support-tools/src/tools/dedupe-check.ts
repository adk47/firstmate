import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";

// dedupe_check — READ-ONLY verifier for customer profile-merge requests.
// It gathers ownership + same-person evidence and returns a PII-safe structured
// verdict. It NEVER merges, never writes, never reaches a tier-2 endpoint. The
// agent files a profile-merge ticket (via create_ticket) for Operations to
// execute; the merge itself stays human-gated.

const MAX_DUPLICATES = 5;
const MAX_NOTE_LEN = 500;
const UUID_PATTERN = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";

// ---- pure helpers -----------------------------------------------------------

// conv-id is derived in-plugin from the trusted gateway SESSION KEY
// (ctx.sessionKey), NEVER taken as an agent parameter — otherwise a customer
// could point the anti-spoof at someone else's conversation. Live runtime key
// format (edge `session.dmScope: "per-channel-peer"`, built by openclaw's
// buildAgentPeerSessionKey):
//   agent:support:intercom:direct:{convId}   (1:1 customer DM — ~all traffic)
//   agent:support:intercom:group:{convId}    (group conversation)
// where {convId} is the Intercom conversation id. The legacy
// `…:{wsId}:conversation:{convId}` shape (plugins/intercom/src/session-key.ts) is
// NOT what the runtime puts in ctx — kept only as a defensive fallback. The
// ephemeral sessionId UUID and non-intercom keys (…:main, …:slack:…, …:cron:…)
// match nothing → null → fail closed.
const SESSION_KEY_RE = /^agent:support:intercom:(?:direct|group):(.+)$/;
const SESSION_KEY_LEGACY_RE = /^agent:support:intercom:[^:]+:conversation:(.+)$/;
export function deriveConvId(sessionKey: string | undefined | null): string | null {
  if (!sessionKey) return null;
  const m = SESSION_KEY_RE.exec(sessionKey) ?? SESSION_KEY_LEGACY_RE.exec(sessionKey);
  const convId = m?.[1]?.trim();
  return convId ? convId : null;
}

// Strip the markers the gateway uses to fence trusted context, so customer-
// derived text can't smuggle a fake [CONVERSATION_CONTEXT] block into the
// ticket the ops agent later reads (mirrors intercom/channel.ts INJECTION_MARKER_REGEX).
const INJECTION_MARKER_REGEX = /\[\/?(?:CONVERSATION_CONTEXT|CUSTOMER_MESSAGE)\]/gi;
export function stripInjectionMarkers(s: string): string {
  return s.replace(INJECTION_MARKER_REGEX, "").trim();
}
export function sanitizeNote(s: string): string {
  return stripInjectionMarkers(String(s ?? "")).slice(0, MAX_NOTE_LEN);
}

// ---- verdict assembly (pure) ------------------------------------------------

interface Workspace {
  email?: string;
  isClaimed?: boolean;
}
interface RawProfile {
  source?: string;
  id?: string;
}
export interface ProfileBody {
  isClaimed?: boolean;
  workspaces?: Workspace[];
  creditCount?: number;
  rawProfiles?: RawProfile[];
  ipis?: Array<number | string>;
}

export interface BuildVerdictInput {
  trustedAuthorEmail: string | null;
  requesterEmail?: string | null;
  survivorProfileId?: string;
  survivor: ProfileBody;
  survivorCreditTitles?: string[];
  // body === null means the requested duplicate could not be loaded — it is
  // surfaced as an "unresolved" entry, NEVER dropped.
  duplicates: Array<{ profileId: string; body: ProfileBody | null; creditTitles?: string[] }>;
  notes?: string[];
  // Optional provenance stamp; passed straight through. Omitted in pure unit
  // tests (→ undefined → dropped by JSON.stringify), set by the tool at runtime.
  verified_at?: string;
}

export interface DuplicateVerdict {
  profile_id: string;
  claim_state: "unclaimed" | "claimed_same_owner" | "claimed_different_user" | "unresolved";
  // How many claimed workspaces the duplicate has; claimed_same_owner with more than
  // one means someone else has also claimed it.
  claimed_workspace_count: number;
  credit_count: number;
  shared_external_id: "none" | "weak";
  // The distinct PLATFORMS whose external id overlapped survivor↔duplicate
  // (e.g. ["ipi","tidal"]), sorted. PLATFORM NAMES ONLY — the raw id after the
  // colon is never emitted (PII/leak rule). [] when there is no overlap.
  matched_external_id_sources: string[];
  shared_track_count: number;
  // Honest denominator for the ratio: how many titles we actually compared
  // (titles are capped/degrade to [], so dividing by full creditCount would lie).
  compared_track_count: number;
  // shared_track_count / compared_track_count, 0..1, 2dp; 0 when nothing compared.
  // Lets a ticket read "5/6 shared" instead of a bare count. Corroboration only —
  // shared tracks can be a collaboration, never on its own same-person proof.
  shared_track_ratio: number;
}

export interface Verdict {
  verified: boolean;
  owner_undetermined: boolean;
  impersonation_flag: boolean;
  owns_survivor: boolean;
  // The survivor profile id these facts were checked against, so a consumer can
  // bind owns_survivor to one profile. Absent on a fail-closed verdict.
  survivor_profile_id?: string;
  survivor_claimed_workspace_count: number;
  // false when there are zero duplicates to assess OR any requested duplicate
  // could not be loaded — an incomplete/empty run must never read as clean evidence.
  all_duplicates_resolved: boolean;
  // Empire-cluster (same-name-many-artists) detection needs a name-cluster scan
  // we deliberately do NOT run here, so this is always "not_performed".
  cluster_size_check: "not_performed";
  duplicates: DuplicateVerdict[];
  notes: string[];
  // ISO timestamp of when these facts were gathered (stamped by the tool, not
  // by buildVerdict — so the pure builder stays deterministic and omits it in
  // unit tests). Anchors the ops "facts true as of …" freshness caveat; the
  // mandatory pre-merge GET re-confirms claim-state at execution time.
  verified_at?: string;
}

function lc(s: string | null | undefined): string {
  return (s ?? "").toLowerCase();
}
function claimedWorkspaces(body: ProfileBody): Workspace[] {
  return (Array.isArray(body.workspaces) ? body.workspaces : []).filter((w) => w?.isClaimed === true);
}
function externalKeys(body: ProfileBody): Set<string> {
  const keys = new Set<string>();
  if (Array.isArray(body.rawProfiles)) {
    for (const r of body.rawProfiles) {
      if (r?.id) keys.add(`${r.source ?? ""}:${r.id}`);
    }
  }
  if (Array.isArray(body.ipis)) {
    for (const ipi of body.ipis) keys.add(`ipi:${ipi}`);
  }
  return keys;
}
function titleSet(titles: string[] | undefined): Set<string> {
  return new Set((titles ?? []).map((t) => lc(t).trim()).filter(Boolean));
}

export function failClosedVerdict(notes: string[] = []): Verdict {
  return {
    verified: false,
    owner_undetermined: true,
    impersonation_flag: false,
    owns_survivor: false,
    survivor_claimed_workspace_count: 0,
    all_duplicates_resolved: false,
    cluster_size_check: "not_performed",
    duplicates: [],
    notes: notes.map(sanitizeNote),
  };
}

export function buildVerdict(input: BuildVerdictInput): Verdict {
  const trusted = input.trustedAuthorEmail ? lc(input.trustedAuthorEmail) : null;
  const requester = input.requesterEmail ? lc(input.requesterEmail) : null;
  const owner_undetermined = !trusted;

  const survClaimed = claimedWorkspaces(input.survivor);
  const survivor_claimed_workspace_count = survClaimed.length;
  const owns_survivor =
    !owner_undetermined &&
    input.survivor.isClaimed === true &&
    survClaimed.length === 1 &&
    lc(survClaimed[0].email) === trusted;

  // The typed-vs-Intercom email mismatch is an INDEPENDENT signal: a customer
  // who typed a different email than their Intercom contact is suspicious even
  // if owns_survivor is already false for another reason.
  const impersonation_flag = !!trusted && !!requester && requester !== trusted;

  const survKeys = externalKeys(input.survivor);
  const survTitles = titleSet(input.survivorCreditTitles);

  const duplicates: DuplicateVerdict[] = input.duplicates.map((d) => {
    if (!d.body) {
      // Could not load this requested duplicate. Surface it EXPLICITLY — never
      // drop it, or a verified=true verdict could hide missing evidence.
      return {
        profile_id: d.profileId,
        claim_state: "unresolved" as const,
        claimed_workspace_count: 0,
        credit_count: 0,
        shared_external_id: "none" as const,
        matched_external_id_sources: [],
        shared_track_count: 0,
        compared_track_count: 0,
        shared_track_ratio: 0,
      };
    }
    const dupClaimed = claimedWorkspaces(d.body);
    let claim_state: DuplicateVerdict["claim_state"];
    if (dupClaimed.length === 0) {
      claim_state = "unclaimed";
    } else if (trusted && dupClaimed.some((w) => lc(w.email) === trusted)) {
      claim_state = "claimed_same_owner";
    } else {
      claim_state = "claimed_different_user";
    }

    const dupKeys = externalKeys(d.body);
    const matchedSources = new Set<string>();
    for (const k of dupKeys) {
      if (survKeys.has(k)) {
        // Keep only the PLATFORM prefix (substring before the first ":"); the
        // raw id after it is never collected, so it can never reach the ticket.
        const src = k.slice(0, k.indexOf(":")) || "unknown";
        matchedSources.add(src);
      }
    }
    const matched_external_id_sources = [...matchedSources].sort();
    // Still NEVER "strong" — shared external IDs are the Maui/Empire false-positive source.
    const shared_external_id: DuplicateVerdict["shared_external_id"] =
      matched_external_id_sources.length > 0 ? "weak" : "none";

    const dupTitles = titleSet(d.creditTitles);
    let shared_track_count = 0;
    for (const t of dupTitles) if (survTitles.has(t)) shared_track_count++;
    const compared_track_count = Math.min(survTitles.size, dupTitles.size);
    const shared_track_ratio =
      compared_track_count > 0 ? Math.round((shared_track_count / compared_track_count) * 100) / 100 : 0;

    return {
      profile_id: d.profileId,
      claim_state,
      claimed_workspace_count: dupClaimed.length,
      credit_count: Number(d.body.creditCount ?? 0),
      shared_external_id,
      matched_external_id_sources,
      shared_track_count,
      compared_track_count,
      shared_track_ratio,
    };
  });

  // `duplicates.length > 0` guards the vacuous-true trap: with zero duplicates,
  // `[].every(...)` is true, which would let an owned survivor read as verified
  // while assessing nothing. Zero duplicates is the most incomplete run of all,
  // so it must NOT count as "all resolved" (QA #405 r3343126327).
  const all_duplicates_resolved = duplicates.length > 0 && duplicates.every((d) => d.claim_state !== "unresolved");

  return {
    // An incomplete run (a duplicate we couldn't load) must NOT read as clean.
    verified: owns_survivor && !impersonation_flag && !owner_undetermined && all_duplicates_resolved,
    owner_undetermined,
    impersonation_flag,
    owns_survivor,
    ...(input.survivorProfileId ? { survivor_profile_id: input.survivorProfileId } : {}),
    survivor_claimed_workspace_count,
    all_duplicates_resolved,
    cluster_size_check: "not_performed",
    duplicates,
    notes: (input.notes ?? []).map(sanitizeNote).filter(Boolean),
    ...(input.verified_at ? { verified_at: input.verified_at } : {}),
  };
}

// ---- the tool ---------------------------------------------------------------

const Parameters = Type.Object({
  survivorProfileId: Type.Optional(
    Type.String({ pattern: UUID_PATTERN, description: "UUID of the profile the customer wants to KEEP (the survivor). Provide this or survivorProfileUrl." }),
  ),
  survivorProfileUrl: Type.Optional(
    Type.String({ description: "Full https://credits.muso.ai/profile/<uuid> URL of the survivor profile." }),
  ),
  duplicateProfileIds: Type.Optional(
    Type.Array(Type.String(), { maxItems: MAX_DUPLICATES, description: "UUIDs of the duplicate profile(s) to fold into the survivor. Max 5." }),
  ),
  duplicateProfileUrls: Type.Optional(
    Type.Array(Type.String(), { maxItems: MAX_DUPLICATES, description: "Full profile URLs of the duplicate(s). Max 5." }),
  ),
  requesterEmail: Type.Optional(
    Type.String({ description: "Customer's email as stated in the conversation. UNTRUSTED — only compared against the Intercom contact email; never the source of truth." }),
  ),
});

type Params = Static<typeof Parameters>;

export interface DedupeCheckDeps {
  adminClient: MusoAdminClient;
  intercomReader: IntercomReader;
  rateLimiter: RateLimiter;
  sessionKey: string;
  intercomToken: string;
  // Shared with create_ticket (one instance in index.ts): the only source of
  // merge_intake.requester_owns.
  verdictStore?: DedupeVerdictStore;
}

const VERDICT_TTL_MS = 2 * 60 * 60_000;

/** Verdicts dedupe_check itself computed, per (conversation, survivor, sorted duplicates); 2h TTL, in memory. */
export class DedupeVerdictStore {
  private entries = new Map<string, { verdict: Verdict; atMs: number }>();

  constructor(private readonly now: () => number = Date.now) {}

  private key(convId: string, survivorId: string, duplicateIds: string[]): string {
    const dups = [...new Set(duplicateIds.map((d) => d.trim().toLowerCase()))].sort();
    return `${convId}|${survivorId.trim().toLowerCase()}|${dups.join(",")}`;
  }

  put(convId: string, survivorId: string, duplicateIds: string[], verdict: Verdict): void {
    const nowMs = this.now();
    for (const [k, e] of this.entries) if (nowMs - e.atMs > VERDICT_TTL_MS) this.entries.delete(k);
    this.entries.set(this.key(convId, survivorId, duplicateIds), { verdict, atMs: nowMs });
  }

  get(convId: string | null, survivorId: string | null, duplicateIds: string[]): Verdict | null {
    if (!convId || !survivorId || duplicateIds.length === 0) return null;
    const e = this.entries.get(this.key(convId, survivorId, duplicateIds));
    if (!e || this.now() - e.atMs > VERDICT_TTL_MS) return null;
    return e.verdict;
  }
}

function resolveId(id: string | undefined, url: string | undefined): string | null {
  if (id && id.trim()) return id.trim();
  if (url && url.trim()) return extractProfileIdFromUrl(url.trim());
  return null;
}

export function createDedupeCheckTool(deps: DedupeCheckDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, intercomReader, rateLimiter, sessionKey, intercomToken, verdictStore } = deps;

  async function fetchProfileBody(profileId: string): Promise<ProfileBody | null> {
    const resp = await adminClient.get<{ data?: ProfileBody }>(`/api/v3/admin/profile/${encodeURIComponent(profileId)}`);
    if (!resp.ok) return null;
    return ((resp.data as any)?.data ?? resp.data ?? {}) as ProfileBody;
  }

  async function fetchCreditTitles(profileId: string): Promise<string[]> {
    const resp = await adminClient.get<{ data?: { items?: Array<{ title?: string }> } }>(
      `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?limit=100&offset=0`,
    );
    if (!resp.ok) return []; // degrade gracefully — a missing shared-track signal is never a failure
    const items = (resp.data as any)?.data?.items ?? [];
    return (items as Array<{ title?: string }>).map((it) => String(it.title ?? "")).filter(Boolean);
  }

  return {
    name: "dedupe_check",
    label: "Verify a customer profile-merge request (read-only)",
    description:
      "Read-only verifier for a customer's duplicate-profile merge request. Anchors ownership to the Intercom contact's real email (anti-spoof), inspects the survivor + duplicate profiles, and returns a PII-safe structured verdict (owns_survivor, per-duplicate claim_state, weak/none shared-id signal with the matched external-id PLATFORMS, shared track count + ratio, impersonation/owner_undetermined flags). " +
      "It NEVER merges and NEVER writes — after calling it, file a profile-merge ticket via create_ticket for Operations to execute. " +
      "Fails closed (owner_undetermined) when ownership cannot be verified. Rate limit: 10 calls / 60 min per session.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      if (!rateLimiter.check(sessionKey, "dedupe_check", 60, 10).allowed) {
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

        const survivorId = resolveId(params.survivorProfileId, params.survivorProfileUrl);
        if (!survivorId) return textResult(JSON.stringify(failClosedVerdict(["survivor profile not provided"])));

        const survivorBody = await fetchProfileBody(survivorId);
        if (!survivorBody) return textResult(JSON.stringify(failClosedVerdict(["could not load the survivor profile"])));
        const survivorCreditTitles = await fetchCreditTitles(survivorId);

        const dupIds = [
          ...(params.duplicateProfileIds ?? []),
          ...((params.duplicateProfileUrls ?? []).map((u) => extractProfileIdFromUrl(u)).filter((x): x is string => !!x)),
        ]
          .map((s) => String(s).trim())
          .filter(Boolean)
          .slice(0, MAX_DUPLICATES);

        // No (valid) duplicate to assess → fail closed. The arrays are optional
        // and invalid URLs are filtered out, so an owned survivor with zero
        // resolved duplicates would otherwise build a vacuously "all resolved"
        // verdict and file a clean-looking profile-merge ticket assessing
        // nothing (QA #405 r3343126327).
        if (dupIds.length === 0) {
          return textResult(JSON.stringify(failClosedVerdict([
            "no valid duplicate profile was provided; there is nothing to assess for a merge — ask the customer for each duplicate profile URL",
          ])));
        }

        const duplicates: BuildVerdictInput["duplicates"] = [];
        for (const dupId of dupIds) {
          const body = await fetchProfileBody(dupId);
          if (!body) {
            // Surface the unloadable duplicate as unresolved — never drop it, or
            // the verdict could look clean while missing evidence (QA #405).
            duplicates.push({ profileId: dupId, body: null, creditTitles: [] });
            continue;
          }
          const creditTitles = await fetchCreditTitles(dupId);
          duplicates.push({ profileId: dupId, body, creditTitles });
        }

        const verdict = buildVerdict({
          trustedAuthorEmail,
          requesterEmail: params.requesterEmail,
          survivorProfileId: survivorId,
          survivor: survivorBody,
          survivorCreditTitles,
          duplicates,
          verified_at: new Date().toISOString(),
        });
        verdictStore?.put(convId, survivorId, dupIds, verdict);
        return textResult(JSON.stringify(verdict));
      } catch {
        // Any unexpected failure must fail CLOSED, never throw and never pass.
        return textResult(JSON.stringify(failClosedVerdict(["unexpected error during verification; routed for human review"])));
      }
    },
  };
}

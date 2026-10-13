/**
 * Read-only analytics triage for support.
 *
 * THE INVARIANT THIS FILE EXISTS TO HOLD: never report a number the backend did
 * not measure.
 *
 * `GET /analytics-status` serves its lifetime metrics from a Redis-cached cube
 * read and never queries Trino inline. On a cache miss it says so honestly —
 * `cubeStatus: "warming"`, `lifetime: null` — and schedules a background warm.
 * This tool used to collapse that into `(analytics.lifetime ?? {})` and then
 * read `Number(lifetime.tracksWithData ?? 0)`, turning "not measured" into a
 * confident `0`. Worse, the backend classifies `status` from the history row
 * alone on a cold pass, so a healthy profile with history and an unread cube
 * comes back `inconsistent` — which mapped to `create_analytics_followup`.
 *
 * The result on 2026-08-18: Saga Beats (327 credits, 278 tracks, healthy) was
 * reported to support as `ready: false, 0 tracks, 0 credits` and escalated as a
 * data mismatch. The analytics were never broken; the cache was cold.
 *
 * So: `measured` gates every cube-derived field, unmeasured reads report null
 * rather than zero, and a warming cube retries once before answering.
 *
 * A SECOND, ORTHOGONAL INVARIANT: a stream figure is serialized only for a
 * verified account holding an ACTIVE seat on this exact profile. On
 * 2026-09-30 Caroline handed an unsubscribed contact, Tobi Wikström, another
 * customer's lifetime stream breakdown — this tool resolved the profile from
 * whatever the customer typed and had no entitlement check at all. The gate
 * (`resolveAnalyticsEntitlement`) runs before the cube read above and on
 * deny returns before any of the cube logic below executes; the two
 * invariants never interact.
 */
import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import type { IntercomReader } from "../intercom-client.js";
import { resolveAnalyticsEntitlement, type AnalyticsEntitlementDeps, type AnalyticsDenyReason } from "../analytics-entitlement.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";

const Parameters = Type.Object({
  profile_id: Type.Optional(Type.String({ description: "Bare Muso profile UUID" })),
  profile_url: Type.Optional(Type.String({ description: "Full https://credits.muso.ai/profile/<uuid> URL" })),
  email: Type.Optional(Type.String({ description: "Customer account email — used for lookup, never echoed back" })),
  name: Type.Optional(Type.String({ description: "Profile display name to resolve via autocomplete/search" })),
  source_platform: Type.Optional(Type.String({ description: "Optional platform named by the customer, e.g. spotify, youtube, shazam, tiktok, instagram" })),
  track_title: Type.Optional(Type.String({ description: "Optional track title named by the customer; echoed only as support context" })),
  release_title: Type.Optional(Type.String({ description: "Optional release title named by the customer; echoed only as support context" })),
});

type Params = Static<typeof Parameters>;

interface ToolDeps {
  adminClient: MusoAdminClient;
  rateLimiter: RateLimiter;
  sessionId: string;
  // Anti-spoof anchor for the entitlement gate: the trusted gateway session
  // KEY (carries the convId), NOT sessionId (an ephemeral UUID that never
  // matches — see resolveAnalyticsEntitlement / deriveConvId). sessionId
  // stays separate because the rate limiter above keys on it.
  sessionKey: string;
  intercomReader: IntercomReader;
  intercomToken: string;
  musoBin?: AnalyticsEntitlementDeps["musoBin"];
  env?: AnalyticsEntitlementDeps["env"];
  execFileImpl?: AnalyticsEntitlementDeps["execFileImpl"];
  /** Injectable for tests; defaults to a real timer. */
  sleep?: (ms: number) => Promise<void>;
}

// A cold cube read schedules a background warm and returns immediately, so the
// value of retrying is that the warm has usually landed by the second read.
// Kept short: this runs inside a live support conversation.
const WARM_RETRY_DELAY_MS = 1500;

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

const PII_KEYS = new Set(["email", "phone", "phoneNumber", "address", "paymentMethod", "stripeId"]);

function stripPii(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (PII_KEYS.has(k)) continue;
    out[k] = v;
  }
  return out;
}

function structuredFailure(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ found: false, reason, ...extra }));
}

function numberAt(obj: Record<string, unknown>, key: string): number {
  const value = Number(obj[key]);
  return Number.isFinite(value) ? value : 0;
}

function normalizePlatform(raw: string | undefined): string {
  return (raw ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "_");
}

function platformKeys(platform: string): string[] {
  switch (platform) {
    case "spotify":
      return ["spotify_streams"];
    case "youtube":
      return ["youtube_streams", "youtube_views", "youtube_videos"];
    case "soundcloud":
      return ["soundcloud_streams"];
    case "audiomack":
      return ["audiomack_streams"];
    case "anghami":
      return ["anghami_streams"];
    case "qobuz":
      return ["qobuz_streams"];
    case "shazam":
      return ["shazam_shazams"];
    case "tiktok":
      return ["tiktok_views", "tiktok_videos"];
    case "instagram":
      return ["instagram_views", "instagram_videos"];
    default:
      return [];
  }
}

function inspectRequestedPlatform(
  platformTotals: Record<string, unknown>,
  sourcePlatform: string | undefined,
  measured: boolean,
) {
  const platform = normalizePlatform(sourcePlatform);
  if (!platform) return null;
  const keys = platformKeys(platform);
  if (keys.length === 0) {
    return {
      platform,
      recognized: false,
      has_data: null,
      total: null,
    };
  }
  // Unmeasured is NOT "zero". Summing absent keys yields 0, which would answer
  // "does this customer have Spotify data?" with a confident "no" on the
  // strength of a read that never happened.
  if (!measured) {
    return {
      platform,
      recognized: true,
      has_data: null,
      total: null,
    };
  }
  const total = keys.reduce((sum, key) => sum + numberAt(platformTotals, key), 0);
  return {
    platform,
    recognized: true,
    has_data: total > 0,
    total,
  };
}

function supportActionForStatus(status: string): string {
  switch (status) {
    case "fresh":
      return "answer_from_status";
    case "delayed":
    case "initializing":
      return "explain_delay";
    case "missing":
    case "stale":
    case "inconsistent":
      return "create_analytics_followup";
    // The cube never answered. Every metric below is unmeasured, and the
    // backend's own `status` for this profile was classified from the history
    // row ALONE — which is why a cold read surfaces as `inconsistent` (history
    // present, no lifetime data) and used to open a false analytics ticket.
    // See the header note.
    case "warming":
      return "retry_after_warm";
    default:
      return "human_review";
  }
}

function diagnosisForStatus(status: string): string {
  switch (status) {
    case "fresh":
      return "Analytics data is present for this profile and the latest observed update is recent.";
    case "delayed":
      return "Analytics data exists for this profile, but some tracks are still processing.";
    case "initializing":
      return "Analytics setup has started for this profile, but customer-facing data is not visible yet.";
    case "missing":
      return "No analytics data is visible for this profile yet.";
    case "stale":
      return "Analytics data exists for this profile, but the latest observed update is older than expected.";
    case "inconsistent":
      return "Analytics readiness and visible data disagree for this profile, so a human should review it.";
    case "warming":
      return "The analytics cache for this profile is still warming, so no metrics were read. This is a cold-cache state, not a data problem — retry the lookup shortly.";
    default:
      return "Analytics status could not be determined from the available read-only signals.";
  }
}

// The entitlement gate's five deny reasons split into two kinds, and the
// deny payload must say which kind it is (QA finding, MUS-1476 round 3): a
// CONFIRMED negative (no_active_seat, profile_not_in_workspace — the module
// resolved the customer and checked their seat) versus an UNDETERMINED
// outcome (owner_undetermined, account_not_resolved, check_unavailable — a
// verification step itself did not complete). Collapsing both into "you
// need Pro" pitches an upgrade to an existing paying subscriber whenever
// verification fails transiently, or permanently whenever
// MUSOAI_INTERCOM_TOKEN is unset. `routeToHuman` already marks this split at
// every deny() call site; these two maps make the customer-facing payload
// agree with it instead of asserting a conclusion the gate never reached.
function supportActionForDeny(reason: AnalyticsDenyReason): "explain_pro_requirement" | "human_review" {
  switch (reason) {
    case "no_active_seat":
    case "profile_not_in_workspace":
      return "explain_pro_requirement";
    case "owner_undetermined":
    case "account_not_resolved":
    case "check_unavailable":
      return "human_review";
  }
}

function diagnosisForDeny(reason: AnalyticsDenyReason): string {
  switch (reason) {
    case "no_active_seat":
    case "profile_not_in_workspace":
      return "Detailed analytics require an active Pro or Business subscription with a seat assigned to this profile.";
    case "owner_undetermined":
    case "account_not_resolved":
    case "check_unavailable":
      return "We could not confirm your account access to this profile's analytics right now. A team member will follow up.";
  }
}

export function createProfileAnalyticsStatusTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId, sessionKey, intercomReader, intercomToken, musoBin, env, execFileImpl, sleep = defaultSleep } = deps;

  return {
    name: "profile_analytics_status",
    label: "Profile Analytics Status",
    description:
      "Read-only support diagnosis for a profile's analytics state. Use after profile_status and subscription_status on analytics, streams, stale numbers, or missing-data complaints. Gated on the verified customer's own access to that profile's analytics (an ACTIVE seat) — a non-entitled customer gets a diagnosis with no figures. Returns structured JSON; never triggers refreshes or writes.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionId, "profile_analytics_status", 1, 10).allowed) {
          return structuredFailure("rate_limited");
        }

        let profileId: string | null = null;
        let profileRow: Record<string, unknown> = {};

        if (params.profile_id) profileId = params.profile_id;
        else if (params.profile_url) profileId = extractProfileIdFromUrl(params.profile_url);

        if (!profileId && !params.email && !params.name) {
          return structuredFailure("missing_input");
        }

        if (!profileId) {
          const query = params.email ?? params.name ?? "";
          const searchResp = await adminClient.get<{ data: Record<string, unknown>[] }>(
            `/api/v3/admin/profile/search?keyword=${encodeURIComponent(query)}&limit=5`,
          );

          if (!searchResp.ok) return structuredFailure("lookup_unavailable");
          const results = searchResp.data?.data ?? [];
          if (results.length === 0) return structuredFailure("no_match");
          if (results.length > 1) {
            return structuredFailure("multiple_matches", {
              matches: results.slice(0, 3).map((r) => String(r.name ?? "")),
            });
          }

          profileRow = stripPii(results[0]);
          profileId = String(results[0].id ?? "");
        } else {
          const direct = await adminClient.get<{ data: Record<string, unknown> }>(
            `/api/v3/admin/profile/${encodeURIComponent(profileId)}`,
          );
          if (direct.ok) {
            profileRow = stripPii((direct.data as any)?.data ?? direct.data ?? {});
          }
        }

        if (!profileId) return structuredFailure("no_match");

        const profileSummary = {
          id: profileId,
          name: String(profileRow.name ?? ""),
          verified: Boolean(profileRow.isClaimed ?? profileRow.verified),
          primary_role: (() => {
            const cc = profileRow.commonCredits;
            if (Array.isArray(cc) && cc.length > 0) return String(cc[0]);
            return String(profileRow.role ?? profileRow.primaryRole ?? "");
          })(),
        };

        // The gate runs BEFORE the analytics-status read and on deny we go no
        // further — the endpoint must never be hit, and the deny payload OMITS
        // every numeric key rather than nulling it (nulling collides with the
        // cold-cache `measured: false` meaning below).
        const entitlement = await resolveAnalyticsEntitlement({
          profileId,
          sessionKey,
          intercomReader,
          intercomToken,
          musoBin,
          env,
          execFileImpl,
        });
        if (!entitlement.entitled) {
          return textResult(
            JSON.stringify({
              found: true,
              profile: profileSummary,
              analytics: {
                entitled: false,
                reason: entitlement.reason,
                route_to_human: entitlement.routeToHuman,
                support_action: supportActionForDeny(entitlement.reason),
                diagnosis: diagnosisForDeny(entitlement.reason),
              },
            }),
          );
        }

        const readAnalytics = async (): Promise<Record<string, unknown> | null> => {
          const resp = await adminClient.get<{ data?: Record<string, unknown> } | Record<string, unknown>>(
            `/api/v3/admin/profile/${encodeURIComponent(profileId)}/analytics-status`,
          );
          if (!resp.ok) return null;
          return ((resp.data as any)?.data ?? resp.data ?? {}) as Record<string, unknown>;
        };

        let analytics = await readAnalytics();
        if (!analytics) return structuredFailure("lookup_unavailable");

        // A cold read scheduled a background warm and returned without touching
        // the cube. Give that warm a moment and read once more — in the common
        // case the second read is fully populated and support gets a real
        // answer instead of a shrug.
        if (String(analytics.cubeStatus ?? "") === "warming") {
          await sleep(WARM_RETRY_DELAY_MS);
          const retried = await readAnalytics();
          if (retried) analytics = retried;
        }

        const cubeStatus = String(analytics.cubeStatus ?? "");
        const lifetimeRaw = analytics.lifetime ?? null;
        const lifetime = (lifetimeRaw ?? {}) as Record<string, unknown>;
        const freshness = (analytics.freshness ?? {}) as Record<string, unknown>;
        const latestRun = (analytics.latestRun ?? {}) as Record<string, unknown>;
        const platformTotals = (lifetime.platformTotals ?? {}) as Record<string, unknown>;

        // Did a cube read actually happen?
        //   ready   -> yes. `lifetime: null` then means genuinely empty, and 0
        //              is a true statement about this profile.
        //   warming -> no. Nothing below was measured.
        //   absent  -> the backend predates cubeStatus; fall back to the only
        //              evidence available rather than assuming either way.
        const measured = cubeStatus === "ready" ? true
          : cubeStatus === "warming" ? false
          : lifetimeRaw !== null;

        // Report the cube state as the status when it is the reason we have no
        // numbers. The backend's own `status` is classified from the history row
        // alone on a cold read, so it reads `inconsistent`/`missing` for a
        // perfectly healthy profile — which is what escalated Saga Beats.
        const status = !measured && cubeStatus === "warming"
          ? "warming"
          : String(analytics.status ?? "unknown");
        const requestedPlatform = inspectRequestedPlatform(platformTotals, params.source_platform, measured);
        const metric = (key: string): number | null =>
          measured ? Number((lifetime as Record<string, unknown>)[key] ?? 0) : null;

        const output = {
          found: true,
          profile: profileSummary,
          analytics: {
            entitled: true,
            grant: entitlement.grant,
            status,
            // initialized is derived from the history row, which IS read on a
            // cold pass, so it stays a boolean.
            initialized: Boolean(analytics.analyticsInitialized),
            // ready is not: the backend computes it from lifetime cube data, so
            // an unread cube yields `false` — a claim that the profile is not
            // ready, made without looking. That literal `ready: false` is what
            // support escalated on 2026-08-18 for a profile that was fine.
            ready: measured ? Boolean(analytics.analyticsReady) : null,
            diagnosis: diagnosisForStatus(status),
            support_action: supportActionForStatus(status),
            freshness: {
              latest_observed_at: String(freshness.latestObservedAt ?? ""),
              latest_observed_age_hours: freshness.latestObservedAgeHours ?? null,
            },
            processing: {
              latest_run_date: String(latestRun.date ?? ""),
              in_progress_tracks_count: Number(latestRun.inProgressTracksCount ?? 0),
            },
            cube_status: cubeStatus || null,
            metrics: {
              // `measured: false` means the cube was never read. The numeric
              // fields are null rather than 0 precisely so that a cold cache
              // cannot be reported to a customer as "you have no data".
              measured,
              tracks_with_data: metric("tracksWithData"),
              credit_count: metric("creditCount"),
              totals: measured ? (lifetime.totals ?? {}) : null,
              platform_totals: measured ? platformTotals : null,
              requested_platform: requestedPlatform,
            },
          },
          customer_provided_context: {
            source_platform: params.source_platform ?? "",
            track_title: params.track_title ?? "",
            release_title: params.release_title ?? "",
          },
        };
        return textResult(JSON.stringify(output));
      } catch (_err) {
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

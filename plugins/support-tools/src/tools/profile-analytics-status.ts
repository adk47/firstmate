import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
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
}

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

function inspectRequestedPlatform(platformTotals: Record<string, unknown>, sourcePlatform: string | undefined) {
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
    default:
      return "Analytics status could not be determined from the available read-only signals.";
  }
}

export function createProfileAnalyticsStatusTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "profile_analytics_status",
    label: "Profile Analytics Status",
    description:
      "Read-only support diagnosis for a profile's analytics state. Use after profile_status and subscription_status on analytics, streams, stale numbers, or missing-data complaints. Returns structured JSON; never triggers refreshes or writes.",
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

        const statusResp = await adminClient.get<{ data?: Record<string, unknown> } | Record<string, unknown>>(
          `/api/v3/admin/profile/${encodeURIComponent(profileId)}/analytics-status`,
        );
        if (!statusResp.ok) return structuredFailure("lookup_unavailable");

        const analytics = ((statusResp.data as any)?.data ?? statusResp.data ?? {}) as Record<string, unknown>;
        const lifetime = (analytics.lifetime ?? {}) as Record<string, unknown>;
        const freshness = (analytics.freshness ?? {}) as Record<string, unknown>;
        const latestRun = (analytics.latestRun ?? {}) as Record<string, unknown>;
        const platformTotals = (lifetime.platformTotals ?? {}) as Record<string, unknown>;
        const status = String(analytics.status ?? "unknown");
        const requestedPlatform = inspectRequestedPlatform(platformTotals, params.source_platform);

        const output = {
          found: true,
          profile: {
            id: profileId,
            name: String(profileRow.name ?? ""),
            verified: Boolean(profileRow.isClaimed ?? profileRow.verified),
            primary_role: (() => {
              const cc = profileRow.commonCredits;
              if (Array.isArray(cc) && cc.length > 0) return String(cc[0]);
              return String(profileRow.role ?? profileRow.primaryRole ?? "");
            })(),
          },
          analytics: {
            status,
            initialized: Boolean(analytics.analyticsInitialized),
            ready: Boolean(analytics.analyticsReady),
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
            metrics: {
              tracks_with_data: Number(lifetime.tracksWithData ?? 0),
              credit_count: Number(lifetime.creditCount ?? 0),
              totals: lifetime.totals ?? {},
              platform_totals: platformTotals,
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

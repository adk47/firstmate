import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";

const Parameters = Type.Object({
  profileId: Type.String({ description: "Profile ID from profile_lookup. Required." }),
  keyword: Type.Optional(Type.String({ description: "Filter credits by track or album name" })),
  creditRole: Type.Optional(Type.String({ description: "Filter by credit role (e.g., Producer, Songwriter)" })),
  limit: Type.Optional(Type.Number({ description: "Results per page (default 20, max 100)", default: 20 })),
  offset: Type.Optional(Type.Number({ description: "Pagination offset (default 0)", default: 0 })),
});

type Params = Static<typeof Parameters>;

interface FilteredCredit {
  creditRoles: string[];
  trackTitle: string;
  albumTitle: string;
  releaseDate: string;
  artists: string[];
}

interface FilteredCreditsResult {
  totalCount: number;
  hasMore: boolean;
  credits: FilteredCredit[];
}

// Admin endpoint wraps items one level deeper: { data: { items: [...] } }
interface AdminCreditsResponse {
  data: {
    items: Record<string, unknown>[];
    totalCount?: number;
    hasMoreToLoad?: boolean;
    total?: number;
    limit?: number;
    offset?: number;
  };
}

interface ToolDeps {
  adminClient: MusoAdminClient;
  rateLimiter: RateLimiter;
  sessionId: string;
}

export function filterCreditsResults(raw: Record<string, unknown>): FilteredCreditsResult {
  const items = (raw.items as Record<string, unknown>[]) ?? [];
  const totalCount = Number(raw.totalCount ?? raw.total ?? items.length);
  const hasMore = raw.hasMoreToLoad !== undefined
    ? Boolean(raw.hasMoreToLoad)
    : Number(raw.offset ?? 0) + Number(raw.limit ?? items.length) < totalCount;
  return {
    totalCount,
    hasMore,
    credits: items.map((item) => {
      const rawCredits = (item.credits as unknown[]) ?? [];
      const creditRoles = rawCredits.map((c) =>
        typeof c === "string" ? c : String((c as Record<string, unknown>).child ?? "")
      );
      // Admin endpoint: title is at item level, no nested track/album objects
      const trackTitle = String(item.title ?? "");
      const albumTitle = ""; // admin endpoint does not return album title
      const artists = ((item.artists as Record<string, unknown>[]) ?? []).map((a) =>
        String(a.name ?? "")
      );
      return {
        creditRoles,
        trackTitle,
        albumTitle,
        releaseDate: String(item.releaseDate ?? ""),
        artists,
      };
    }),
  };
}

export function createCreditsSearchTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "credits_search",
    label: "Credits Search",
    description:
      "Look up music credits for a specific profile. Requires a profileId from profile_lookup. Optionally filter by track name, credit role, and paginate results.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const { profileId, keyword, creditRole, limit = 20, offset = 0 } = params;

      if (!rateLimiter.check(sessionId, "credits_search", 1, 10).allowed) {
        return textResult(JSON.stringify({ ok: false, reason: "rate_limited" }));
      }

      const queryParams = new URLSearchParams();
      if (keyword) queryParams.set("keyword", keyword);
      if (creditRole) queryParams.append("filter[]", creditRole);
      queryParams.set("limit", String(limit));
      queryParams.set("offset", String(offset));

      const path = `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?${queryParams}`;
      const result = await adminClient.get<AdminCreditsResponse>(path);

      if (!result.ok) {
        return textResult(JSON.stringify({ ok: false, reason: "lookup_unavailable" }));
      }

      // Admin endpoint wraps result one level deeper in data.data
      const innerData = (result.data as any)?.data ?? result.data ?? {};
      const filtered = filterCreditsResults(innerData as Record<string, unknown>);

      if (filtered.credits.length === 0) {
        return textResult(JSON.stringify({ ok: true, totalCount: 0, hasMore: false, credits: [] }));
      }

      return textResult(JSON.stringify({ ok: true, ...filtered }));
    },
  };
}

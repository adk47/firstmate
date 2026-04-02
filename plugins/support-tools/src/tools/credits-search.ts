import { Type, type Static } from "@sinclair/typebox";
import type { AgentTool, AgentToolResult } from "@mariozechner/pi-agent-core";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";

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

interface ToolDeps {
  http: HttpClient;
  rateLimiter: RateLimiter;
  musoApiBase: string;
  musoApiKey: string;
  sessionId: string;
}

export function filterCreditsResults(raw: Record<string, unknown>): FilteredCreditsResult {
  const items = (raw.items as Record<string, unknown>[]) ?? [];
  return {
    totalCount: Number(raw.totalCount ?? 0),
    hasMore: Boolean(raw.hasMoreToLoad),
    credits: items.map((item) => {
      const rawCredits = (item.credits as unknown[]) ?? [];
      const creditRoles = rawCredits.map((c) =>
        typeof c === "string" ? c : String((c as Record<string, unknown>).child ?? "")
      );
      const track = (item.track as Record<string, unknown>) ?? {};
      const album = (item.album as Record<string, unknown>) ?? {};
      const artists = ((item.artists as Record<string, unknown>[]) ?? []).map((a) =>
        String(a.name ?? "")
      );
      return {
        creditRoles,
        trackTitle: String(track.title ?? ""),
        albumTitle: String(album.title ?? ""),
        releaseDate: String(item.releaseDate ?? ""),
        artists,
      };
    }),
  };
}

function textResult(text: string): AgentToolResult<unknown> {
  return { content: [{ type: "text", text }], details: {} };
}

export function createCreditsSearchTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, musoApiBase, musoApiKey, sessionId } = deps;
  const headers = { "x-api-key": musoApiKey };

  return {
    name: "credits_search",
    label: "Credits Search",
    description:
      "Look up music credits for a specific profile. Requires a profileId from profile_lookup. Optionally filter by track name, credit role, and paginate results.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const { profileId, keyword, creditRole, limit = 20, offset = 0 } = params;

      if (!rateLimiter.check(sessionId, "credits_search", 1, 10).allowed) {
        return textResult(
          "Too many credit lookups. Please wait a moment before trying again."
        );
      }

      const queryParams = new URLSearchParams();
      if (keyword) queryParams.set("keyword", keyword);
      if (creditRole) queryParams.append("filter[]", creditRole);
      queryParams.set("limit", String(limit));
      queryParams.set("offset", String(offset));

      const url = `${musoApiBase}/api/c/v4/profile/${encodeURIComponent(profileId)}/credits?${queryParams}`;
      const result = await http.get<Record<string, unknown>>(url, { headers });

      if (!result.ok) {
        return textResult(
          "Unable to search credits right now. Try again shortly or ask me to create a support ticket."
        );
      }

      const filtered = filterCreditsResults(result.data);

      if (filtered.totalCount === 0) {
        return textResult("No credits found for this profile.");
      }

      return textResult(JSON.stringify(filtered));
    },
  };
}

import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";

const Parameters = Type.Object({
  query: Type.String({ description: "Name, partial name, or muso.ai profile URL to search for" }),
});

type Params = Static<typeof Parameters>;

interface ProfileResult {
  profileId: string;
  name: string;
  type: string;
  verified: boolean;
  creditsCount: number;
}

interface ToolDeps {
  adminClient: MusoAdminClient;
  rateLimiter: RateLimiter;
  sessionId: string;
}

export function extractProfileIdFromUrl(input: string): string | null {
  try {
    const url = new URL(input);
    const match = url.pathname.match(/^\/profile\/([^/?]+)/);
    return match ? match[1].replace(/\/$/, "") : null;
  } catch {
    return null;
  }
}

export function filterProfileResults(raw: Record<string, unknown>[]): ProfileResult[] {
  return raw.map((r) => ({
    profileId: String(r.id ?? ""),
    name: String(r.name ?? ""),
    type: String(r.type ?? "unknown"),
    verified: Boolean(r.isClaimed ?? r.verified),
    creditsCount: Number(r.creditCount ?? r.creditsCount ?? 0),
  }));
}

export function createProfileLookupTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "profile_lookup",
    label: "Profile Lookup",
    description:
      "Search for a Muso.AI profile by name or URL. Returns public profile information including name, type, verification status, and credits count.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const { query } = params;

      if (!rateLimiter.check(sessionId, "profile_lookup", 1, 10).allowed) {
        return textResult(JSON.stringify({ ok: false, reason: "rate_limited" }));
      }

      // Check if query is a profile URL
      const profileId = extractProfileIdFromUrl(query);
      if (profileId) {
        return textResult(
          JSON.stringify({
            ok: true,
            profileId,
            note: "Profile ID extracted from URL. Use credits_search with this ID to look up their credits.",
          }),
        );
      }

      // Search using admin endpoint
      const encodedQuery = encodeURIComponent(query);
      const searchResult = await adminClient.get<{ data: Record<string, unknown>[] }>(
        `/api/v3/admin/profile/search?keyword=${encodedQuery}&limit=5`,
      );

      if (!searchResult.ok) {
        return textResult(JSON.stringify({ ok: false, reason: "lookup_unavailable" }));
      }

      const results: Record<string, unknown>[] = searchResult.data?.data ?? [];

      if (results.length === 0) {
        return textResult(JSON.stringify({ ok: true, profiles: [], count: 0 }));
      }

      const filtered = filterProfileResults(results);
      return textResult(JSON.stringify({ ok: true, profiles: filtered, count: filtered.length }));
    },
  };
}

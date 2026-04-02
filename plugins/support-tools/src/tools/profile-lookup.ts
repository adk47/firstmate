import { Type, type Static } from "@sinclair/typebox";
import type { AgentTool, AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";

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
  http: HttpClient;
  rateLimiter: RateLimiter;
  musoApiBase: string;
  musoApiKey: string;
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
    verified: Boolean(r.verified),
    creditsCount: Number(r.creditCount ?? r.creditsCount ?? 0),
  }));
}

function textResult(text: string): AgentToolResult<unknown> {
  return { content: [{ type: "text", text }], details: {} };
}

export function createProfileLookupTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, musoApiBase, musoApiKey, sessionId } = deps;
  const headers = { "x-api-key": musoApiKey };

  return {
    name: "profile_lookup",
    label: "Profile Lookup",
    description:
      "Search for a Muso.AI profile by name or URL. Returns public profile information including name, type, verification status, and credits count.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      const { query } = params;

      if (!rateLimiter.check(sessionId, "profile_lookup", 1, 10).allowed) {
        return textResult("Too many profile lookups. Please wait a moment before trying again.");
      }

      // Check if query is a profile URL
      const profileId = extractProfileIdFromUrl(query);
      if (profileId) {
        return textResult(
          JSON.stringify({
            profileId,
            note: "Profile ID extracted from URL. Use credits_search with this ID to look up their credits.",
          }),
        );
      }

      // Try autocomplete first
      const encodedQuery = encodeURIComponent(query);
      const autocompleteResult = await http.get<{ results: Record<string, unknown>[] }>(
        `${musoApiBase}/api/c/v5/search/autocomplete?q=${encodedQuery}&types=profiles&limit=5`,
        { headers },
      );

      if (!autocompleteResult.ok) {
        return textResult("Unable to look up profiles right now. Try again shortly or ask me to create a support ticket.");
      }

      let results = autocompleteResult.data.results ?? [];

      // Fall back to full search if autocomplete returns 0 results
      if (results.length === 0) {
        const searchResult = await http.post<{ results: Record<string, unknown>[] }>(
          `${musoApiBase}/api/c/v5/search`,
          {
            headers,
            body: { keyword: query, type: ["profile"], limit: 10 },
          },
        );

        if (searchResult.ok) {
          results = searchResult.data.results ?? [];
        }
      }

      if (results.length === 0) {
        return textResult(`No profiles found matching '${query}'. Check the name or spelling.`);
      }

      const filtered = filterProfileResults(results);
      return textResult(JSON.stringify({ profiles: filtered, count: filtered.length }));
    },
  };
}

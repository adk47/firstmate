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

export function createProfileStatusTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "profile_status",
    label: "Profile Status",
    description:
      "Bundled read-only view of a customer's profile — name, role, verified flag, credits count, and the latest 3 credits (sorted by release date descending). Returns structured JSON. Use this FIRST whenever a customer mentions analytics, streams, data freshness, or whether their account 'is working'.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionId, "profile_status", 1, 10).allowed) {
          return structuredFailure("rate_limited");
        }

        // Input precedence: profile_id > profile_url > email > name
        let profileId: string | null = null;
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

          let results: Record<string, unknown>[] = [];
          if (searchResp.ok) results = searchResp.data?.data ?? [];

          if (!searchResp.ok) return structuredFailure("lookup_unavailable");
          if (results.length === 0) return structuredFailure("no_match");
          if (results.length > 1) {
            return structuredFailure("multiple_matches", {
              matches: results.slice(0, 3).map((r) => String(r.name ?? "")),
            });
          }

          profileId = String(results[0].id ?? "");
          const r = stripPii(results[0]);
          return await fetchCreditsAndAssemble(adminClient, profileId, r);
        }

        // Direct profileId path — fetch bare profile then credits.
        const direct = await adminClient.get<{ data: Record<string, unknown> }>(
          `/api/v3/admin/profile/${encodeURIComponent(profileId)}`,
        );
        if (direct.ok) {
          // Admin endpoint wraps in data.data
          const profileRow = stripPii((direct.data as any)?.data ?? direct.data ?? {});
          return await fetchCreditsAndAssemble(adminClient, profileId, profileRow);
        }
        // Fallback: if bare-profile endpoint is unavailable, try credits alone.
        return await fetchCreditsAndAssemble(adminClient, profileId, {});
      } catch (_err) {
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

async function fetchCreditsAndAssemble(
  adminClient: MusoAdminClient,
  profileId: string,
  profileRow: Record<string, unknown>,
): Promise<AgentToolResult<unknown>> {
  const credResp = await adminClient.get<{ data: { items: Record<string, unknown>[]; totalCount?: number } }>(
    `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?limit=20&offset=0`,
  );
  if (!credResp.ok) return textResult(JSON.stringify({ found: false, reason: "lookup_unavailable" }));

  // Admin endpoint wraps: response.data.data.items
  const innerData = (credResp.data as any)?.data ?? {};
  const items: Record<string, unknown>[] = innerData.items ?? [];

  const latest = items
    .map((it) => {
      const credits = (it.credits as unknown[]) ?? [];
      const role = typeof credits[0] === "string"
        ? String(credits[0])
        : String(((credits[0] as Record<string, unknown>) ?? {}).child ?? "");
      // Admin endpoint: title is at item level (no nested track object)
      return {
        track: String(it.title ?? ""),
        release: "", // admin endpoint does not return album title
        role,
        date: String(it.releaseDate ?? ""),
      };
    })
    .filter((c) => c.date)
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, 3);

  // Ownership-check fields for the customer-credit-removal skill's Step 2
  // (PR #337 review item #5). Workspace emails here are the profile-owner's
  // own emails (Caroline already sees the same email via Intercom contact),
  // not third-party PII, so safe to expose. Each workspace is reduced to
  // the two fields the skill actually reads.
  const rawWorkspaces = Array.isArray(profileRow.workspaces) ? profileRow.workspaces : [];
  const workspaces = rawWorkspaces.map((w) => {
    const ws = w as Record<string, unknown>;
    return {
      email: String(ws.email ?? ""),
      isClaimed: Boolean(ws.isClaimed),
    };
  });
  const rawKnownAs = Array.isArray(profileRow.knownAsNames) ? profileRow.knownAsNames : [];
  const knownAsNames = rawKnownAs.map((n) => String(n));

  const output = {
    found: true,
    profile: {
      id: profileId,
      name: String(profileRow.name ?? ""),
      // `verified` is the legacy collapsed boolean (kept for back-compat);
      // `isClaimed` is the raw upstream field that the ownership-check
      // chain in remove-credits.sh reads.
      verified: Boolean(profileRow.isClaimed ?? profileRow.verified),
      isClaimed: Boolean(profileRow.isClaimed),
      primary_role: (() => {
        const cc = profileRow.commonCredits;
        if (Array.isArray(cc) && cc.length > 0) return String(cc[0]);
        return String(profileRow.role ?? profileRow.primaryRole ?? "");
      })(),
      credits_count: Number(profileRow.creditCount ?? profileRow.creditsCount ?? 0),
      workspaces,
      knownAsNames,
    },
    latest_credits: latest,
    latest_credit_date: latest[0]?.date ?? "",
  };
  return textResult(JSON.stringify(output));
}

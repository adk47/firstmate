import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { createHttpClient } from "./http.js";
import { RateLimiter } from "./rate-limiter.js";
import { createProfileLookupTool } from "./tools/profile-lookup.js";
import { createCreditsSearchTool } from "./tools/credits-search.js";
import { createCreateTicketTool } from "./tools/create-ticket.js";
import { createSubscriptionStatusTool } from "./tools/subscription-status.js";
export default definePluginEntry({
  id: "support-tools",
  name: "Support Agent Tools",
  description: "Profile lookup, credits search, ticket creation, and subscription status tools for the support agent.",
  register(api: any) {
    // OpenClaw passes the entry's `config` block (from
    // openclaw-*.json plugins.entries["support-tools"].config) as
    // `api.pluginConfig`. The legacy `api.config["support-tools"]` path
    // was a misread: `api.config` is the full openclaw config, which
    // does not have a top-level "support-tools" key. Fall back to the
    // legacy path AND env vars so old deploys keep working during the
    // rollout.
    //
    // openclaw 4.27 passes the raw entry.config block — including
    // unresolved secret-ref objects like {source: "env", id: "X"} — as
    // api.pluginConfig. Filter to string-only values so the secret-ref
    // shapes fall through to the env-var fallbacks below instead of
    // crashing the required-keys .startsWith() check on register
    // (which on 2026-05-05 took main gateway into a 60+ restart
    // crash-loop after PR #238 deployed).
    const _legacy = (((api.config ?? {}) as Record<string, unknown>)["support-tools"] ?? {}) as Record<string, unknown>;
    const _entry = (api.pluginConfig ?? {}) as Record<string, unknown>;
    const pluginConfig: Record<string, string> = {};
    for (const [_k, _v] of Object.entries({ ..._legacy, ..._entry })) {
      if (typeof _v === "string") pluginConfig[_k] = _v;
    }

    const musoApiBase = pluginConfig.musoApiBase ?? process.env.MUSO_API_BASE ?? "https://api.muso.ai";
    const musoApiKey = pluginConfig.musoApiKey ?? process.env.MUSO_CUSTOMER_API_KEY ?? "";
    const clickupApiKey = pluginConfig.clickupApiKey ?? process.env.CLICKUP_API_KEY ?? "";
    const clickupListId = pluginConfig.clickupListId ?? process.env.CLICKUP_LIST_ID ?? "";
    const clickupProfileIdFieldId =
      pluginConfig.clickupProfileIdFieldId ?? process.env.CLICKUP_PROFILE_ID_FIELD_ID ?? "";
    const clickupUserEmailFieldId =
      pluginConfig.clickupUserEmailFieldId ?? process.env.CLICKUP_USER_EMAIL_FIELD_ID ?? "";
    const DEFAULT_PROFILE_MERGE_ASSIGNEE_ID = 66250052;
    const profileMergeAssigneeIdRaw = pluginConfig.profileMergeAssigneeId ?? process.env.PROFILE_MERGE_ASSIGNEE_ID ?? "";
    let profileMergeAssigneeId: number | undefined;
    if (profileMergeAssigneeIdRaw) {
      const parsed = Number(profileMergeAssigneeIdRaw);
      if (Number.isFinite(parsed)) {
        profileMergeAssigneeId = parsed;
      } else {
        console.warn(`[support-tools] Invalid profileMergeAssigneeId override "${profileMergeAssigneeIdRaw}" — falling back to default.`);
        profileMergeAssigneeId = DEFAULT_PROFILE_MERGE_ASSIGNEE_ID;
      }
    } else {
      profileMergeAssigneeId = DEFAULT_PROFILE_MERGE_ASSIGNEE_ID;
    }

    const required = { musoApiKey, clickupApiKey, clickupListId, clickupProfileIdFieldId, clickupUserEmailFieldId };
    const missing = Object.entries(required).filter(([, v]) => !v || v.startsWith("TODO")).map(([k]) => k);
    if (missing.length > 0) {
      console.warn(`[support-tools] Missing config keys: ${missing.join(", ")}. Affected tools will not function correctly.`);
    }

    const http = createHttpClient();
    const rateLimiter = new RateLimiter();

    const profileLookupFactory = (ctx: any) => {
      return createProfileLookupTool({ http, rateLimiter, musoApiBase, musoApiKey, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(profileLookupFactory, { name: "profile_lookup" });

    const creditsSearchFactory = (ctx: any) => {
      return createCreditsSearchTool({ http, rateLimiter, musoApiBase, musoApiKey, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(creditsSearchFactory, { name: "credits_search" });

    api.registerTool(createSubscriptionStatusTool(), { name: "subscription_status" });

    const createTicketFactory = (ctx: any) => {
      return createCreateTicketTool({
        http,
        rateLimiter,
        clickupApiKey,
        clickupListId,
        clickupProfileIdFieldId,
        clickupUserEmailFieldId,
        sessionId: ctx.sessionId ?? "unknown",
        profileMergeAssigneeId,
      });
    };
    api.registerTool(createTicketFactory, { name: "create_ticket" });
  },
});

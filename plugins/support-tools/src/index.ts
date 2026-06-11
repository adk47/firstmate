import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { createHttpClient } from "./http.js";
import { createMusoAdminClient } from "./muso-admin-client.js";
import { RateLimiter } from "./rate-limiter.js";
import { SessionTicketRegistry } from "./session-ticket-registry.js";
import { createProfileLookupTool } from "./tools/profile-lookup.js";
import { createCreditsSearchTool } from "./tools/credits-search.js";
import { createCreateTicketTool } from "./tools/create-ticket.js";
import { createSubscriptionStatusTool } from "./tools/subscription-status.js";
import { createProfileStatusTool } from "./tools/profile-status.js";
import { createRemoveCreditsTool, DEFAULT_REMOVE_CREDITS_SCRIPT } from "./tools/remove-credits.js";
import { createDedupeCheckTool } from "./tools/dedupe-check.js";
import { createIntercomReader } from "./intercom-client.js";
export default definePluginEntry({
  id: "support-tools",
  name: "Support Agent Tools",
  description: "Support agent tools: profile lookup/status, credits search, subscription status, ticket creation, and self-service credit removal.",
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
    const adminEmail = pluginConfig.adminEmail ?? process.env.MUSO_ADMIN_EMAIL ?? "";
    const adminPassword = pluginConfig.adminPassword ?? process.env.MUSO_ADMIN_PASSWORD ?? "";
    const clickupApiKey = pluginConfig.clickupApiKey ?? process.env.CLICKUP_API_KEY ?? "";
    const clickupListId = pluginConfig.clickupListId ?? process.env.CLICKUP_LIST_ID ?? "";
    const clickupProfileIdFieldId =
      pluginConfig.clickupProfileIdFieldId ?? process.env.CLICKUP_PROFILE_ID_FIELD_ID ?? "";
    const clickupUserEmailFieldId =
      pluginConfig.clickupUserEmailFieldId ?? process.env.CLICKUP_USER_EMAIL_FIELD_ID ?? "";
    // Enrichment field ids — default to the known ClickUp field UUIDs for list
    // 901000600160 so ticket enrichment works without a config change; still
    // overridable via config/env if the list/fields ever move.
    const clickupIntercomLinkFieldId =
      pluginConfig.clickupIntercomLinkFieldId ?? process.env.CLICKUP_INTERCOM_LINK_FIELD_ID ?? "c32dbf6e-f680-4ff1-a532-192bb96245c3";
    const clickupMusoUrlFieldId =
      pluginConfig.clickupMusoUrlFieldId ?? process.env.CLICKUP_MUSO_URL_FIELD_ID ?? "fb08a61a-2870-4b2f-b6cd-c404dccfb97e";
    const clickupTeamFieldId =
      pluginConfig.clickupTeamFieldId ?? process.env.CLICKUP_TEAM_FIELD_ID ?? "552c2c28-dc56-48bc-a6a6-6b9a76344acc";
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

    const required = { adminEmail, adminPassword, clickupApiKey, clickupListId, clickupProfileIdFieldId, clickupUserEmailFieldId };
    const missing = Object.entries(required).filter(([, v]) => !v || v.startsWith("TODO")).map(([k]) => k);
    if (missing.length > 0) {
      console.warn(`[support-tools] Missing config keys: ${missing.join(", ")}. Affected tools will not function correctly.`);
    }

    const http = createHttpClient();
    const musoAdminClient = createMusoAdminClient({ http, musoApiBase, adminEmail, adminPassword });
    const rateLimiter = new RateLimiter();
    // Shared across sessions (like rateLimiter) so repeat create_ticket calls
    // in one conversation append to the earlier ticket instead of duplicating.
    const sessionTickets = new SessionTicketRegistry();

    const profileLookupFactory = (ctx: any) => {
      return createProfileLookupTool({ adminClient: musoAdminClient, rateLimiter, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(profileLookupFactory, { name: "profile_lookup" });

    const creditsSearchFactory = (ctx: any) => {
      return createCreditsSearchTool({ adminClient: musoAdminClient, rateLimiter, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(creditsSearchFactory, { name: "credits_search" });

    const profileStatusFactory = (ctx: any) => {
      return createProfileStatusTool({ adminClient: musoAdminClient, rateLimiter, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(profileStatusFactory, { name: "profile_status" });

    api.registerTool(createSubscriptionStatusTool(), { name: "subscription_status" });

    const createTicketFactory = (ctx: any) => {
      return createCreateTicketTool({
        http,
        rateLimiter,
        sessionTickets,
        clickupApiKey,
        clickupListId,
        clickupProfileIdFieldId,
        clickupUserEmailFieldId,
        clickupIntercomLinkFieldId,
        clickupMusoUrlFieldId,
        clickupTeamFieldId,
        sessionId: ctx.sessionId ?? "unknown",
        profileMergeAssigneeId,
      });
    };
    api.registerTool(createTicketFactory, { name: "create_ticket" });

    const removeCreditsScriptPath =
      pluginConfig.removeCreditsScriptPath ?? DEFAULT_REMOVE_CREDITS_SCRIPT;
    const removeCreditsFactory = (ctx: any) => {
      return createRemoveCreditsTool({
        scriptPath: removeCreditsScriptPath,
        rateLimiter,
        sessionId: ctx.sessionId ?? "unknown",
      });
    };
    api.registerTool(removeCreditsFactory, { name: "remove_credits" });

    // dedupe_check — read-only profile-merge verifier. The Intercom token is
    // read from process.env (it lives in edge.env); it is NOT a hydra-env
    // secret-ref and NOT a hard-required key — when absent the tool fails
    // CLOSED (owner_undetermined), it does not break the other tools.
    const intercomToken = pluginConfig.intercomToken ?? process.env.MUSOAI_INTERCOM_TOKEN ?? "";
    if (!intercomToken) {
      console.warn("[support-tools] MUSOAI_INTERCOM_TOKEN not set; dedupe_check will fail closed (no ownership verification).");
    }
    const intercomReader = createIntercomReader(http);
    const dedupeCheckFactory = (ctx: any) => {
      return createDedupeCheckTool({
        adminClient: musoAdminClient,
        intercomReader,
        rateLimiter,
        sessionId: ctx.sessionId ?? "unknown",
        intercomToken,
      });
    };
    api.registerTool(dedupeCheckFactory, { name: "dedupe_check" });
  },
});

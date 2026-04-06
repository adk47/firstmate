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
    const config = (api.config ?? {}) as Record<string, unknown>;
    const pluginConfig = (config["support-tools"] ?? {}) as Record<string, string>;

    const musoApiBase = pluginConfig.musoApiBase ?? process.env.MUSO_API_BASE ?? "https://api.muso.ai";
    const musoApiKey = pluginConfig.musoApiKey ?? process.env.MUSO_CUSTOMER_API_KEY ?? "";
    const clickupApiKey = pluginConfig.clickupApiKey ?? process.env.CLICKUP_API_KEY ?? "";
    const clickupListId = pluginConfig.clickupListId ?? "";
    const clickupProfileIdFieldId = pluginConfig.clickupProfileIdFieldId ?? "";
    const clickupUserEmailFieldId = pluginConfig.clickupUserEmailFieldId ?? "";

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
      });
    };
    api.registerTool(createTicketFactory, { name: "create_ticket" });
  },
});

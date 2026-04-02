import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { createHttpClient } from "./http.js";
import { RateLimiter } from "./rate-limiter.js";
import { createProfileLookupTool } from "./tools/profile-lookup.js";
import { createCreditsSearchTool } from "./tools/credits-search.js";
import { createCreateTicketTool } from "./tools/create-ticket.js";
import { createSubscriptionStatusTool } from "./tools/subscription-status.js";
import type { OpenClawPluginToolFactory } from "openclaw/plugin-sdk";

export default definePluginEntry({
  id: "support-tools",
  name: "Support Agent Tools",
  description: "Profile lookup, credits search, ticket creation, and subscription status tools for the support agent.",
  register(api) {
    const config = (api.config ?? {}) as Record<string, unknown>;
    const pluginConfig = (config["support-tools"] ?? {}) as Record<string, string>;

    const musoApiBase = pluginConfig.musoApiBase ?? "https://api.muso.ai";
    const musoApiKey = pluginConfig.musoApiKey ?? "";
    const clickupApiKey = pluginConfig.clickupApiKey ?? "";
    const clickupListId = pluginConfig.clickupListId ?? "";
    const clickupProfileIdFieldId = pluginConfig.clickupProfileIdFieldId ?? "";
    const clickupUserEmailFieldId = pluginConfig.clickupUserEmailFieldId ?? "";

    const http = createHttpClient();
    const rateLimiter = new RateLimiter();

    // All tools registered as factories to get sessionId from context for rate limiting
    const profileLookupFactory: OpenClawPluginToolFactory = (ctx) => {
      return createProfileLookupTool({ http, rateLimiter, musoApiBase, musoApiKey, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(profileLookupFactory, { name: "profile_lookup" });

    const creditsSearchFactory: OpenClawPluginToolFactory = (ctx) => {
      return createCreditsSearchTool({ http, rateLimiter, musoApiBase, musoApiKey, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(creditsSearchFactory, { name: "credits_search" });

    // subscription_status: static stub (no rate limiting needed)
    api.registerTool(createSubscriptionStatusTool());

    const createTicketFactory: OpenClawPluginToolFactory = (ctx) => {
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

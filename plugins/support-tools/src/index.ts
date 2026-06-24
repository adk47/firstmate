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
import { createOrderLookupTool } from "./tools/order-lookup.js";
import { createRemoveCreditsTool, DEFAULT_REMOVE_CREDITS_SCRIPT } from "./tools/remove-credits.js";
import { createOrderAddressUpdateTool, DEFAULT_UPDATE_ORDER_ADDRESS_SCRIPT } from "./tools/order-address-update.js";
import { createDedupeCheckTool } from "./tools/dedupe-check.js";
import { createCreditVerificationCheckTool } from "./tools/credit-verification-check.js";
import { createProfilesClaimSelfTool, DEFAULT_PROFILES_CLAIM_SELF_SCRIPT } from "./tools/profiles-claim-self.js";
import { createCreditsVerifyTool, DEFAULT_CREDITS_VERIFY_SCRIPT } from "./tools/credits-verify.js";
import { createProfilesConsolidateTool, DEFAULT_PROFILES_CONSOLIDATE_SCRIPT } from "./tools/profiles-consolidate.js";
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
    // Intercom app-id for ticket deeplinks — defaults to Muso's workspace id
    // (the live session key no longer carries it); overridable via config/env.
    const intercomWorkspaceId =
      pluginConfig.intercomWorkspaceId ?? process.env.INTERCOM_WORKSPACE_ID ?? "dwjzhcge";
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

    const orderLookupFactory = (ctx: any) => {
      return createOrderLookupTool({ adminClient: musoAdminClient, rateLimiter, sessionId: ctx.sessionId ?? "unknown" });
    };
    api.registerTool(orderLookupFactory, { name: "order_lookup" });

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
        intercomWorkspaceId,
        clickupMusoUrlFieldId,
        clickupTeamFieldId,
        sessionId: ctx.sessionId ?? "unknown",
        sessionKey: ctx.sessionKey ?? "unknown",
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

    // order_address_update — gated edit of an order's shipping recipient. Same
    // wrapper-as-security-boundary pattern as remove_credits: the wrapper (not the
    // GET-only MusoAdminClient) does the write, and is the ownership/audit boundary.
    const updateOrderAddressScriptPath =
      pluginConfig.updateOrderAddressScriptPath ?? DEFAULT_UPDATE_ORDER_ADDRESS_SCRIPT;
    const orderAddressUpdateFactory = (ctx: any) => {
      return createOrderAddressUpdateTool({
        scriptPath: updateOrderAddressScriptPath,
        rateLimiter,
        sessionId: ctx.sessionId ?? "unknown",
      });
    };
    api.registerTool(orderAddressUpdateFactory, { name: "order_address_update" });

    // dedupe_check — read-only profile-merge verifier. The Intercom token is
    // read from process.env (it lives in edge.env); it is NOT a hydra-env
    // secret-ref and NOT a hard-required key — when absent the tool fails
    // CLOSED (owner_undetermined), it does not break the other tools.
    const intercomToken = pluginConfig.intercomToken ?? process.env.MUSOAI_INTERCOM_TOKEN ?? "";
    if (!intercomToken) {
      console.warn("[support-tools] MUSOAI_INTERCOM_TOKEN not set; dedupe_check and credit_verification_check will fail closed (no ownership verification).");
    }
    const intercomReader = createIntercomReader(http);
    const dedupeCheckFactory = (ctx: any) => {
      return createDedupeCheckTool({
        adminClient: musoAdminClient,
        intercomReader,
        rateLimiter,
        // Anti-spoof anchor: the trusted gateway session KEY (carries the convId),
        // NOT ctx.sessionId (an ephemeral UUID that never matches). See deriveConvId.
        sessionKey: ctx.sessionKey ?? "unknown",
        intercomToken,
      });
    };
    api.registerTool(dedupeCheckFactory, { name: "dedupe_check" });

    // credit_verification_check — read-only lookup of a customer's
    // user_verification_needed credits, anchored to the verified Intercom
    // contact email (same anti-spoof as dedupe_check). Reads only; the
    // recommend-approve handoff is a create_ticket call, and the gated
    // PUT status=approved stays human/ops via muso-admin-api.sh. Reuses the
    // same intercomToken (fails closed when absent).
    // Phase-1 dark-ship flag (default OFF). Enable per-account only after live
    // observation, mirroring the personalization rollout (PR #416). Read from
    // the RAW entry/legacy config (not the string-filtered pluginConfig) so the
    // natural JSON boolean `true` works as well as "true"/"1"/1; only
    // boolean/string/number values count — any other shape (e.g. an unresolved
    // secret-ref object) falls through to the CREDIT_VERIFICATION_ENABLED env
    // instead of shadowing it. Anything unrecognized stays OFF.
    // Entry-before-legacy mirrors the `{..._legacy, ..._entry}` spread
    // precedence used for pluginConfig above.
    const creditVerificationRaw =
      [_entry.creditVerificationEnabled, _legacy.creditVerificationEnabled].find(
        (v) => typeof v === "boolean" || typeof v === "string" || typeof v === "number",
      ) ?? process.env.CREDIT_VERIFICATION_ENABLED;
    const creditVerificationEnabled =
      creditVerificationRaw === true || creditVerificationRaw === 1 || creditVerificationRaw === "true" || creditVerificationRaw === "1";
    const creditVerificationCheckFactory = (ctx: any) => {
      return createCreditVerificationCheckTool({
        adminClient: musoAdminClient,
        intercomReader,
        rateLimiter,
        // Anti-spoof anchor: the trusted gateway session KEY (carries the convId),
        // NOT ctx.sessionId (an ephemeral UUID that never matches). See deriveConvId.
        sessionKey: ctx.sessionKey ?? "unknown",
        intercomToken,
        enabled: creditVerificationEnabled,
      });
    };
    api.registerTool(creditVerificationCheckFactory, { name: "credit_verification_check" });

    // profiles_claim_self — gated WRITE counterpart of dedupe/verification checks:
    // verify the customer's OWN pending profile claim by shelling
    // `muso profiles claim-self --actor-identity <verified-email>` (muso-cli's
    // capability gate does ownership + audit; the binary must be on edge). The
    // actor email is the ctx-derived verified Intercom author (deriveConvId →
    // getAuthorEmail), never a model arg. Dark-ship flag default OFF, same
    // boolean/string/number coercion as credit_verification_check above.
    const profilesClaimSelfRaw =
      [_entry.profilesClaimSelfEnabled, _legacy.profilesClaimSelfEnabled].find(
        (v) => typeof v === "boolean" || typeof v === "string" || typeof v === "number",
      ) ?? process.env.PROFILES_CLAIM_SELF_ENABLED;
    const profilesClaimSelfEnabled =
      profilesClaimSelfRaw === true || profilesClaimSelfRaw === 1 || profilesClaimSelfRaw === "true" || profilesClaimSelfRaw === "1";
    const profilesClaimSelfScriptPath =
      pluginConfig.profilesClaimSelfScriptPath ?? DEFAULT_PROFILES_CLAIM_SELF_SCRIPT;
    const profilesClaimSelfFactory = (ctx: any) => {
      return createProfilesClaimSelfTool({
        scriptPath: profilesClaimSelfScriptPath,
        rateLimiter,
        // Anti-spoof anchor: the trusted gateway session KEY (carries the convId).
        sessionKey: ctx.sessionKey ?? "unknown",
        intercomReader,
        intercomToken,
        enabled: profilesClaimSelfEnabled,
      });
    };
    api.registerTool(profilesClaimSelfFactory, { name: "profiles_claim_self" });

    // credits_verify — gated WRITE counterpart of credit_verification_check:
    // verify (approve) the customer's OWN pending, catalog-corroborated credit
    // request by shelling `muso credits verify --actor-identity <verified-email>`
    // (muso-cli's capability gate does ownership + audit; the binary must be on
    // edge). The actor email is the ctx-derived verified Intercom author
    // (deriveConvId → getAuthorEmail), never a model arg. Dark-ship flag default
    // OFF, same boolean/string/number coercion as profiles_claim_self above.
    const creditsVerifyRaw =
      [_entry.creditsVerifyEnabled, _legacy.creditsVerifyEnabled].find(
        (v) => typeof v === "boolean" || typeof v === "string" || typeof v === "number",
      ) ?? process.env.CREDITS_VERIFY_ENABLED;
    const creditsVerifyEnabled =
      creditsVerifyRaw === true || creditsVerifyRaw === 1 || creditsVerifyRaw === "true" || creditsVerifyRaw === "1";
    const creditsVerifyScriptPath =
      pluginConfig.creditsVerifyScriptPath ?? DEFAULT_CREDITS_VERIFY_SCRIPT;
    const creditsVerifyFactory = (ctx: any) => {
      return createCreditsVerifyTool({
        scriptPath: creditsVerifyScriptPath,
        rateLimiter,
        // Anti-spoof anchor: the trusted gateway session KEY (carries the convId).
        sessionKey: ctx.sessionKey ?? "unknown",
        intercomReader,
        intercomToken,
        enabled: creditsVerifyEnabled,
      });
    };
    api.registerTool(creditsVerifyFactory, { name: "credits_verify" });

    // profiles_consolidate — gated WRITE counterpart of dedupe_check
    // (APPROVAL-tier): fold the customer's OWN unclaimed same-name duplicates
    // into the profile they own by shelling
    // `muso profiles consolidate --actor-identity <verified-email>` (muso-cli's
    // capability gate does ownership + audit; the binary must be on edge). The
    // actor email is the ctx-derived verified Intercom author, never a model
    // arg. Dark-ship flag default OFF, same coercion as the verbs above.
    const profilesConsolidateRaw =
      [_entry.profilesConsolidateEnabled, _legacy.profilesConsolidateEnabled].find(
        (v) => typeof v === "boolean" || typeof v === "string" || typeof v === "number",
      ) ?? process.env.PROFILES_CONSOLIDATE_ENABLED;
    const profilesConsolidateEnabled =
      profilesConsolidateRaw === true || profilesConsolidateRaw === 1 || profilesConsolidateRaw === "true" || profilesConsolidateRaw === "1";
    const profilesConsolidateScriptPath =
      pluginConfig.profilesConsolidateScriptPath ?? DEFAULT_PROFILES_CONSOLIDATE_SCRIPT;
    const profilesConsolidateFactory = (ctx: any) => {
      return createProfilesConsolidateTool({
        scriptPath: profilesConsolidateScriptPath,
        rateLimiter,
        // Anti-spoof anchor: the trusted gateway session KEY (carries the convId).
        sessionKey: ctx.sessionKey ?? "unknown",
        intercomReader,
        intercomToken,
        enabled: profilesConsolidateEnabled,
      });
    };
    api.registerTool(profilesConsolidateFactory, { name: "profiles_consolidate" });
  },
});

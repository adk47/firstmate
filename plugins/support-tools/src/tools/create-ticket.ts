import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";

const Parameters = Type.Object({
  actionType: Type.String({ description: "Type of action request. One of: credit-claim, credit-correction, profile-claim, support-general, analytics-followup, profile-merge, unmerge-request, bulk-credit-change, profile-update, subscription-refund, data-deletion, dispute, data-export" }),
  customerEmail: Type.String({ description: "Customer's email address" }),
  summary: Type.String({ description: "Plain English description of what the customer is requesting" }),
  customerProfileId: Type.Optional(Type.String({ description: "Customer's Muso profile ID, if known from profile_lookup" })),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Additional action-specific details (e.g., track name, credit role)" })),
  conversationSummary: Type.String({ description: "2-3 sentence summary of the conversation context" }),
});

type Params = Static<typeof Parameters>;

// Discriminated union of every shape this tool returns. Centralized so that
// a typo on one branch doesn't slip through; consumers can rely on `reason`
// to differentiate failure modes.
export type CreateTicketResult =
  | { submitted: true; ticket_id: string; sla: string; action_type: string; tier: number }
  | { submitted: false; reason: "rate_limited" }
  | { submitted: false; reason: "queue_busy" }
  | {
      submitted: false;
      reason: "profile_merge_capture_incomplete";
      missing: string[];
      hint: string;
    }
  | {
      submitted: false;
      reason: "capture_incomplete";
      action_type: string;
      missing: string[];
      hint: string;
    };

function ticketResult(r: CreateTicketResult): AgentToolResult<unknown> {
  return textResult(JSON.stringify(r));
}

const TIER_MAP: Record<string, number> = {
  "credit-claim": 1, "credit-correction": 1, "profile-claim": 1, "support-general": 1, "analytics-followup": 1,
  "profile-merge": 2, "unmerge-request": 2, "bulk-credit-change": 2, "profile-update": 2,
  "subscription-refund": 3, "data-deletion": 3, "dispute": 3, "data-export": 3,
};

const TIER_TO_PRIORITY: Record<number, number> = { 1: 3, 2: 2, 3: 1 };

export const TIER_SLAS: Record<number, string> = {
  1: "2 business days",
  2: "5 business days",
  3: "5-10 business days",
};

export function getTierForAction(actionType: string): number {
  return TIER_MAP[actionType] ?? 1;
}

// Tier-2 actions that MUTATE a specific profile and are genuinely unactionable
// without knowing which profile. Gated below (require customerProfileId).
// Deliberately does NOT include tier-1 types — an over-strict gate that blocks
// Caroline from filing would *cause* dropped customers, the exact harm we're
// fixing. profile-merge has its own richer gate above.
const PROFILE_ANCHOR_REQUIRED = new Set(["profile-update", "bulk-credit-change", "unmerge-request"]);

// ClickUp "Team" dropdown option ids (list 901000600160). Growth owns
// account/billing/support; Catalog owns the catalog data (credits, profiles,
// tracks, analytics, merges).
const TEAM_OPTION_CATALOG = "da684786-49eb-4306-87c2-30c093d6dc35";
const TEAM_OPTION_GROWTH = "fab5b56c-953f-490f-8eb9-2d33f108114f";
const GROWTH_ACTIONS = new Set([
  "subscription-refund", "data-deletion", "data-export", "dispute", "support-general",
]);

export function teamOptionFor(actionType: string): string {
  return GROWTH_ACTIONS.has(actionType) ? TEAM_OPTION_GROWTH : TEAM_OPTION_CATALOG;
}

// Recover the Intercom workspace + conversation id from the support agent's
// session key (`agent:support:intercom:<workspaceId>:conversation:<conversationId>`
// — see plugins/intercom/src/session-key.ts). Returns null for any other shape
// ("unknown", non-Intercom channels) so enrichment is best-effort and NEVER
// blocks ticket creation on a parse miss.
export function parseIntercomSession(
  sessionId: string,
): { workspaceId: string; conversationId: string } | null {
  const m = /^agent:support:intercom:([^:]+):conversation:(.+)$/.exec(sessionId ?? "");
  if (!m) return null;
  return { workspaceId: m[1], conversationId: m[2] };
}

export function intercomDeeplink(workspaceId: string, conversationId: string): string {
  return `https://app.intercom.com/a/inbox/${workspaceId}/inbox/conversation/${conversationId}`;
}

export function musoProfileUrl(profileId: string): string {
  return `https://credits.muso.ai/profile/${profileId}`;
}

export function buildTicketDescription(params: {
  summary: string; actionType: string; tier: number; customerEmail: string;
  customerProfileId?: string; details?: Record<string, unknown>;
  conversationSummary: string; sessionId: string;
}): string {
  const actionRequest = {
    action_type: params.actionType,
    approval_tier: params.tier,
    customer_email: params.customerEmail,
    customer_profile_id: params.customerProfileId ?? null,
    details: params.details ?? {},
    conversation_summary: params.conversationSummary,
    cs_session_id: params.sessionId,
  };
  return [
    `Customer ${params.customerEmail} requests: ${params.summary}`,
    "",
    "---ACTION-REQUEST---",
    JSON.stringify(actionRequest, null, 2),
    "---END-ACTION-REQUEST---",
  ].join("\n");
}

interface ToolDeps {
  http: HttpClient; rateLimiter: RateLimiter;
  clickupApiKey: string; clickupListId: string;
  clickupProfileIdFieldId: string; clickupUserEmailFieldId: string;
  sessionId: string;
  profileMergeAssigneeId?: number;
  // Enrichment field ids — each is added to the ticket ONLY when its id is set
  // (wired with real defaults in index.ts). Optional so existing callers/tests
  // that don't pass them are unaffected.
  clickupIntercomLinkFieldId?: string;
  clickupMusoUrlFieldId?: string;
  clickupTeamFieldId?: string;
}

export function createCreateTicketTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, clickupApiKey, clickupListId, clickupProfileIdFieldId, clickupUserEmailFieldId, sessionId, profileMergeAssigneeId } = deps;
  const { clickupIntercomLinkFieldId, clickupMusoUrlFieldId, clickupTeamFieldId } = deps;

  return {
    name: "create_ticket",
    label: "Create Support Ticket",
    description: "Create a support ticket in the team's task system for customer requests that require human action (credit claims, profile merges, analytics followups, refunds, data deletion, etc.).",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Validate BEFORE the rate-limit check. A malformed profile-merge call
      // shouldn't consume the 2-per-60s budget — the agent will retry once it
      // gets the missing fields from the customer, and that retry should be
      // unaffected by previous validation failures.
      if (params.actionType === "profile-merge") {
        const missing: string[] = [];
        if (!params.customerProfileId || !params.customerProfileId.trim()) {
          missing.push("customerProfileId");
        }
        const details = params.details ?? {};
        const mainUrl = typeof details.main_profile_url === "string" ? details.main_profile_url.trim() : "";
        if (!mainUrl) missing.push("details.main_profile_url");
        const dupUrls = Array.isArray(details.duplicate_profile_urls)
          ? details.duplicate_profile_urls.filter((u): u is string => typeof u === "string" && u.trim().length > 0)
          : [];
        if (dupUrls.length === 0) missing.push("details.duplicate_profile_urls");
        if (missing.length > 0) {
          return ticketResult({
            submitted: false,
            reason: "profile_merge_capture_incomplete",
            missing,
            hint: "Profile-merge tickets need customer_profile_id, details.main_profile_url, and details.duplicate_profile_urls[]. Ask the customer for both the profile they want to keep AND each duplicate URL before retrying.",
          });
        }
      }

      // Profile-mutating tier-2 actions can't be actioned without knowing WHICH
      // profile. Require customerProfileId for them (light gate — tier-1 stays
      // ungated so Caroline can always file). Runs before the rate-limit check
      // so a retry after capturing the id isn't penalised.
      if (PROFILE_ANCHOR_REQUIRED.has(params.actionType)) {
        if (!params.customerProfileId || !params.customerProfileId.trim()) {
          return ticketResult({
            submitted: false,
            reason: "capture_incomplete",
            action_type: params.actionType,
            missing: ["customerProfileId"],
            hint: `${params.actionType} needs the customer's Muso profile id (which profile to act on). Run profile_lookup or ask the customer for their profile URL before retrying.`,
          });
        }
      }

      if (!rateLimiter.check(sessionId, "create_ticket", 60, 2).allowed) {
        return ticketResult({ submitted: false, reason: "rate_limited" });
      }

      if (!(params.actionType in TIER_MAP)) {
        console.warn(`[support-tools] Unknown actionType "${params.actionType}", defaulting to tier 1`);
      }

      const tier = getTierForAction(params.actionType);
      const priority = TIER_TO_PRIORITY[tier] ?? 3;
      const sla = TIER_SLAS[tier] ?? "2 business days";

      const description = buildTicketDescription({
        summary: params.summary, actionType: params.actionType, tier,
        customerEmail: params.customerEmail, customerProfileId: params.customerProfileId,
        details: params.details, conversationSummary: params.conversationSummary, sessionId,
      });

      const customFields: { id: string; value: string }[] = [
        { id: clickupUserEmailFieldId, value: params.customerEmail },
      ];
      if (params.customerProfileId) {
        customFields.push({ id: clickupProfileIdFieldId, value: params.customerProfileId });
      }

      // --- Enrichment (each field added only when its id is configured) ---
      // Intercom Link: the keystone that lets a resolved ticket be mapped back
      // to its conversation. Recovered deterministically from the session key;
      // best-effort — absent for non-Intercom sessions, never blocks creation.
      const intercomSession = parseIntercomSession(sessionId);
      if (clickupIntercomLinkFieldId && intercomSession) {
        customFields.push({
          id: clickupIntercomLinkFieldId,
          value: intercomDeeplink(intercomSession.workspaceId, intercomSession.conversationId),
        });
      }
      if (clickupMusoUrlFieldId && params.customerProfileId) {
        customFields.push({ id: clickupMusoUrlFieldId, value: musoProfileUrl(params.customerProfileId) });
      }
      if (clickupTeamFieldId) {
        customFields.push({ id: clickupTeamFieldId, value: teamOptionFor(params.actionType) });
      }

      const tags = ["hydra-action-request", `tier-${tier}`, `action:${params.actionType}`];
      if (params.actionType === "analytics-followup") tags.push("analytics-followup");

      // Title carries the customer (+ short profile id) so ops can scan/dedup
      // the queue without opening each ticket — the legacy human tickets did
      // this with artist names; Caroline's tickets were all identical before.
      const titleParts = [`Action Request: ${params.actionType}`, params.customerEmail];
      if (params.customerProfileId) titleParts.push(params.customerProfileId.slice(0, 8));
      const name = titleParts.join(" | ");

      const body: Record<string, unknown> = {
        name,
        description,
        status: "to do",
        priority,
        tags,
        custom_fields: customFields,
      };
      if (params.actionType === "profile-merge" && profileMergeAssigneeId) {
        body.assignees = [profileMergeAssigneeId];
      }

      const result = await http.post<{ id: string }>(
        `https://api.clickup.com/api/v2/list/${clickupListId}/task`,
        { headers: { Authorization: clickupApiKey }, body },
      );

      if (!result.ok) {
        return ticketResult({ submitted: false, reason: "queue_busy" });
      }

      return ticketResult({ submitted: true, ticket_id: result.data.id, sla, action_type: params.actionType, tier });
    },
  };
}

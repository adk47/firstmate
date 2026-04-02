import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";

const Parameters = Type.Object({
  actionType: Type.String({ description: "Type of action request. One of: credit-claim, credit-correction, profile-claim, support-general, profile-merge, bulk-credit-change, profile-update, subscription-refund, data-deletion, dispute, data-export" }),
  customerEmail: Type.String({ description: "Customer's email address" }),
  summary: Type.String({ description: "Plain English description of what the customer is requesting" }),
  customerProfileId: Type.Optional(Type.String({ description: "Customer's Muso profile ID, if known from profile_lookup" })),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Additional action-specific details (e.g., track name, credit role)" })),
  conversationSummary: Type.String({ description: "2-3 sentence summary of the conversation context" }),
});

type Params = Static<typeof Parameters>;

const TIER_MAP: Record<string, number> = {
  "credit-claim": 1, "credit-correction": 1, "profile-claim": 1, "support-general": 1,
  "profile-merge": 2, "bulk-credit-change": 2, "profile-update": 2,
  "subscription-refund": 3, "data-deletion": 3, "dispute": 3, "data-export": 3,
};

const TIER_TO_PRIORITY: Record<number, number> = { 1: 3, 2: 2, 3: 1 };

export const TIER_SLAS: Record<number, string> = {
  1: "48 hours",
  2: "5 business days",
  3: "5-10 business days",
};

export function getTierForAction(actionType: string): number {
  return TIER_MAP[actionType] ?? 1;
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
}

export function createCreateTicketTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, clickupApiKey, clickupListId, clickupProfileIdFieldId, clickupUserEmailFieldId, sessionId } = deps;

  return {
    name: "create_ticket",
    label: "Create Support Ticket",
    description: "Create a support ticket in the team's task system for customer requests that require human action (credit claims, profile merges, refunds, data deletion, etc.).",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      if (!rateLimiter.check(sessionId, "create_ticket", 60, 2).allowed) {
        return textResult("You've already submitted requests this session. Our team will follow up on all of them.");
      }

      if (!(params.actionType in TIER_MAP)) {
        console.warn(`[support-tools] Unknown actionType "${params.actionType}", defaulting to tier 1`);
      }

      const tier = getTierForAction(params.actionType);
      const priority = TIER_TO_PRIORITY[tier] ?? 3;
      const sla = TIER_SLAS[tier] ?? "48 hours";

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

      const result = await http.post<{ id: string }>(
        `https://api.clickup.com/api/v2/list/${clickupListId}/task`,
        {
          headers: { Authorization: clickupApiKey },
          body: {
            name: `Action Request: ${params.actionType}`,
            description,
            status: "to do",
            priority,
            tags: ["hydra-action-request", `tier-${tier}`],
            custom_fields: customFields,
          },
        },
      );

      if (!result.ok) {
        return textResult("Unable to create a ticket right now. Please email support@muso.ai directly.");
      }

      return textResult(JSON.stringify({
        ticketId: result.data.id,
        message: `Support request #${result.data.id} created. Our team will review it within ${sla}.`,
      }));
    },
  };
}

import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";

const Parameters = Type.Object({
  query: Type.Optional(Type.String({ description: "What the customer is asking about their subscription" })),
});

type Params = Static<typeof Parameters>;

export function createSubscriptionStatusTool(): AgentTool<typeof Parameters, unknown> {
  return {
    name: "subscription_status",
    label: "Subscription Status",
    description: "Check a customer's subscription status, plan, or billing information. Note: this feature is not yet available — returns a structured not-implemented response. Caroline should suggest a follow-up via create_ticket.",
    parameters: Parameters,
    async execute(_toolCallId: string, _params: Params): Promise<AgentToolResult<unknown>> {
      return textResult(JSON.stringify({
        ok: false,
        reason: "not_implemented",
        suggest_followup: true,
      }));
    },
  };
}

import { Type, type Static } from "@sinclair/typebox";
import type { AgentTool, AgentToolResult } from "@mariozechner/pi-agent-core";

const Parameters = Type.Object({
  query: Type.Optional(Type.String({ description: "What the customer is asking about their subscription" })),
});

type Params = Static<typeof Parameters>;

export function createSubscriptionStatusTool(): AgentTool<typeof Parameters, unknown> {
  return {
    name: "subscription_status",
    label: "Subscription Status",
    description: "Check a customer's subscription status, plan, or billing information. Note: this feature is not yet available — will offer to create a support ticket instead.",
    parameters: Parameters,
    async execute(_toolCallId: string, _params: Params): Promise<AgentToolResult<unknown>> {
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            message: "Subscription status lookup is not yet available. To check subscription details, I can create a support ticket for the team to investigate.",
            suggestTicket: true,
          }),
        }],
        details: {},
      };
    },
  };
}

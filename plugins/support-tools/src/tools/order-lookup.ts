import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";

const Parameters = Type.Object({
  order_ref: Type.String({
    minLength: 1,
    pattern: "^[A-Za-z0-9_-]+$",
    description:
      "Order reference to look up — any of: the internal order UUID (Prodigi merchantReference), the order number, or Prodigi's own order id.",
  }),
});

type Params = Static<typeof Parameters>;

interface ToolDeps {
  adminClient: MusoAdminClient;
  rateLimiter: RateLimiter;
  sessionId: string;
}

function structuredFailure(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ found: false, reason, ...extra }));
}

// Admin endpoints wrap their payload as `{ data: <payload> }`; tolerate an
// un-wrapped body too (defensive, matches profile_status).
function unwrap(body: unknown): Record<string, unknown> {
  const b = (body ?? {}) as Record<string, unknown>;
  const inner = (b.data ?? b) as Record<string, unknown>;
  return inner && typeof inner === "object" ? inner : {};
}

export function createOrderLookupTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "order_lookup",
    label: "Order Lookup",
    description:
      "Read-only lookup of a plaque/poster order by its internal id, order number, or Prodigi order id. Returns the order status, the shipping address (Prodigi format), tracking, and an item summary — never payment details. Use it for Prodigi address-confirmation requests and customer order/shipping questions (see the order-fulfillment skill).",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionId, "order_lookup", 1, 10).allowed) {
          return structuredFailure("rate_limited");
        }
        const ref = (params.order_ref ?? "").trim();
        if (!ref) return structuredFailure("missing_input");

        const resp = await adminClient.get<unknown>(`/api/v3/admin/orders/${encodeURIComponent(ref)}`);
        if (!resp.ok) {
          if (resp.status === 404) return structuredFailure("not_found");
          return structuredFailure("lookup_unavailable");
        }

        const order = unwrap(resp.data);
        const shipment = (order.shipment ?? null) as Record<string, unknown> | null;
        const rawItems = Array.isArray(order.items) ? (order.items as Record<string, unknown>[]) : [];

        // Surface only fulfilment-relevant fields. The shipping address + phone
        // ARE the working data here (this tool exists to confirm/correct them),
        // but payment data is dropped — it is never needed to fix a shipment.
        const out = {
          found: true,
          order: {
            id: order.id ?? null,
            orderNumber: order.orderNumber ?? null,
            prodigiOrderId: order.prodigiOrderId ?? null,
            status: order.status ?? null,
            createdAt: order.createdAt ?? null,
            items: rawItems.map((i) => ({
              productName: i.productName ?? null,
              size: i.size ?? null,
              quantity: i.quantity ?? null,
              trackName: i.trackName ?? null,
              profileName: i.profileName ?? null,
            })),
            shipment: shipment
              ? {
                  address: shipment.address ?? null,
                  phoneNumber: shipment.phoneNumber ?? null,
                  trackingNumber: shipment.trackingNumber ?? null,
                  trackingUrl: shipment.trackingUrl ?? null,
                }
              : null,
          },
        };
        return textResult(JSON.stringify(out));
      } catch (_err) {
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

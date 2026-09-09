import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MusoAdminClient } from "../muso-admin-client.js";
import { expectedTaxIdLabels } from "../order-address.js";

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

// Surface only whether a customs tax id (Mexico RFC/CURP) is on file + its type —
// never the value (no reason to echo a stored tax id to the support agent).
function taxIdMeta(raw: unknown): { present: boolean; type?: string | null } {
  const t = raw as Record<string, unknown> | null | undefined;
  return t && typeof t === "object"
    ? { present: t.present === true, type: (t.type as string) ?? null }
    : { present: false };
}

// A paid order the backend is deliberately NOT forwarding to Prodigi, because
// sending it as-is would get the parcel rejected or returned. Mirrors core-backend
// `services/orders/constants.js`'s HOLD_STATUSES.
const HOLD_STATUSES = ["NEEDS_TAX_ID", "NEEDS_CONTACT_INFO"];

export interface HoldDescriptor {
  status: string; // the hold status itself
  missing: ("taxId" | "phone")[]; // what still has to be collected
  taxIdLabel: string | null; // what THIS destination calls the id ("RFC or CURP")
  countryCode: string | null;
}

// A held order looks exactly like "nothing happened" to the customer, and the one
// thing Caroline needs is what to ask for. The admin API does not say: its DTO
// (core-backend `services/orders/mapOrderToDto.js`) carries status, shipment and
// taxId, but no hold reason -- so we derive it here rather than instructing Caroline
// to infer it, which would leave her guessing the destination's own name for the id.
//
// The derivation reads the STATUS, and deliberately NOT `shipment.phoneNumber`.
// That field is the PRODIGI recipient's phone (`recipient?.phoneNumber || null`,
// where `recipient = thirdPartyData?.recipient`), and a held order is by definition
// one we never handed to Prodigi -- so it is null on EVERY held order, whatever
// phone we actually hold in `details.shipping.phone`. Reading it would make every
// held order report a missing phone and send Caroline back to the customer for a
// number we may already have. (The requested-phone fallback is core-backend #9699,
// still open; the MARKETPLACE_ITEM branch of the DTO already does it, the poster
// branch does not. Revisit this only when that ships.)
//
// The status is authoritative instead, because `processOrder` sets it from exactly
// this test: a customs-gated destination with no stored tax id pushes `taxId`, an
// unusable `details.shipping.phone` pushes `phone`, and the hold is NEEDS_TAX_ID
// when `taxId` is among them, else NEEDS_CONTACT_INFO. So NEEDS_CONTACT_INFO proves
// the phone is what is outstanding, and NEEDS_TAX_ID proves the tax id is -- while
// leaving open that the phone is missing too, which nothing in this DTO can reveal.
// `order_address_update` requires a phone regardless, so the skill has Caroline
// confirm it with the customer on any release; that is a field she cannot read, not
// a thing we are re-asking for.
function holdDescriptor(
  status: unknown,
  countryCode: unknown,
  taxIdPresent: boolean,
): HoldDescriptor | null {
  if (typeof status !== "string" || !HOLD_STATUSES.includes(status)) return null;

  const country = typeof countryCode === "string" && countryCode.trim() ? countryCode.trim().toUpperCase() : null;

  // NEEDS_TAX_ID with an id already on file is contradictory -- the backend would
  // have released it on the next processOrder run. Report nothing outstanding rather
  // than demand an id we hold; the skill routes an empty list to the team.
  const needsTaxId = status === "NEEDS_TAX_ID" && !taxIdPresent;
  const missing: ("taxId" | "phone")[] = needsTaxId
    ? ["taxId"]
    : status === "NEEDS_CONTACT_INFO"
      ? ["phone"]
      : [];

  return {
    status,
    missing,
    // Null when the destination is not one we know to be customs-gated. The status
    // still says a tax id is wanted, so this reads as "ask, but our country table
    // cannot name it" -- a signal the table has fallen behind the backend's.
    taxIdLabel: needsTaxId ? expectedTaxIdLabels(country) || null : null,
    countryCode: country,
  };
}

export function createOrderLookupTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { adminClient, rateLimiter, sessionId } = deps;

  return {
    name: "order_lookup",
    label: "Order Lookup",
    description:
      "Read-only lookup of a plaque/poster order by its internal id, order number, or Prodigi order id. Returns the order status, the shipping address (Prodigi format), tracking, and an item summary — never payment details. When the order is on a fulfilment hold (NEEDS_TAX_ID / NEEDS_CONTACT_INFO) it also returns `hold`, naming what is still outstanding and what the destination calls its tax id. Use it for Prodigi address-confirmation requests and customer order/shipping questions (see the order-fulfillment skill).",
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
        const taxId = taxIdMeta(order.taxId);
        const address = (shipment?.address ?? null) as Record<string, unknown> | null;

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
            // Whether a customs tax id is already on file, so Caroline can skip
            // re-asking for it (see taxIdMeta — the value is never echoed).
            taxId,
            // Non-null only for a NEEDS_TAX_ID / NEEDS_CONTACT_INFO order: what the
            // order is still waiting on, and what its destination calls the id.
            hold: holdDescriptor(order.status, address?.countryCode, taxId.present),
          },
        };
        return textResult(JSON.stringify(out));
      } catch (_err) {
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

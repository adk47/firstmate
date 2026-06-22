import { describe, it, expect, vi, beforeEach } from "vitest";
import { createOrderLookupTool } from "../src/tools/order-lookup.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient } from "../src/muso-admin-client.js";

const UUID = "6a468d83-b71d-4720-bb12-79ae8dfa55f8";

// A realistic admin order DTO (Prodigi-shape address), wrapped in the admin
// `{ data: ... }` envelope and carrying payment data that must NOT leak.
const ORDER_BODY = {
  data: {
    id: UUID,
    orderNumber: "k3n9Xa",
    prodigiOrderId: "66812882101295104",
    status: "PROCESSING",
    createdAt: "2026-06-10T00:00:00.000Z",
    items: [{ productName: "Acrylic Plaque 12x12", size: "12x12", quantity: 1, trackName: null, profileName: "Some Artist" }],
    shipment: {
      address: { line1: "Av Enriquillo 36", townOrCity: "Santo Domingo", postalOrZipCode: "11108", countryCode: "DO" },
      phoneNumber: "+1 809 555 0100",
      trackingNumber: null,
      trackingUrl: null,
    },
    payment: { totalAmount: 99, currency: "USD" },
  },
};

function makeClient(get: MusoAdminClient["get"]): MusoAdminClient {
  return { get };
}

const parse = (r: { content: { type: string; text: string }[] }) => JSON.parse(r.content[0].text);

describe("createOrderLookupTool", () => {
  let rateLimiter: RateLimiter;
  beforeEach(() => { rateLimiter = new RateLimiter(); });

  it("returns missing_input and does not call the API when order_ref is blank", async () => {
    const get = vi.fn();
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: "  " }));
    expect(out).toEqual({ found: false, reason: "missing_input" });
    expect(get).not.toHaveBeenCalled();
  });

  it("looks up by the given ref and returns a PII-scoped order WITHOUT payment data", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });

    const out = parse(await tool.execute("c", { order_ref: UUID }));

    expect(get).toHaveBeenCalledWith(`/api/v3/admin/orders/${UUID}`);
    expect(out.found).toBe(true);
    expect(out.order.id).toBe(UUID);
    expect(out.order.orderNumber).toBe("k3n9Xa");
    expect(out.order.prodigiOrderId).toBe("66812882101295104");
    expect(out.order.status).toBe("PROCESSING");
    expect(out.order.shipment.address.townOrCity).toBe("Santo Domingo");
    expect(out.order.shipment.phoneNumber).toBe("+1 809 555 0100");
    expect(out.order.items[0].productName).toBe("Acrylic Plaque 12x12");
    // Payment must never be surfaced to the support agent.
    expect(JSON.stringify(out)).not.toContain("payment");
    expect(JSON.stringify(out)).not.toContain("totalAmount");
    // No tax id on this order → present:false.
    expect(out.order.taxId).toEqual({ present: false });
  });

  it("surfaces taxId present/type but NEVER the value", async () => {
    const withTax = { data: { ...ORDER_BODY.data, taxId: { present: true, type: "rfc", value: "GODE561231GR8" } } };
    const get = vi.fn(async () => ({ ok: true, status: 200, data: withTax }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.order.taxId).toEqual({ present: true, type: "rfc" });
    // The stored RFC value must not leak to the agent.
    expect(JSON.stringify(out)).not.toContain("GODE561231GR8");
  });

  it("treats a malformed (non-object) taxId from the DTO as not-present", async () => {
    const weird = { data: { ...ORDER_BODY.data, taxId: "unexpected-string" } };
    const get = vi.fn(async () => ({ ok: true, status: 200, data: weird }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.order.taxId).toEqual({ present: false });
  });

  it("url-encodes the ref", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    await tool.execute("c", { order_ref: "a b/c" });
    expect(get).toHaveBeenCalledWith("/api/v3/admin/orders/a%20b%2Fc");
  });

  it("tolerates an un-enveloped body", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY.data }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.found).toBe(true);
    expect(out.order.id).toBe(UUID);
  });

  it("maps a 404 to not_found", async () => {
    const get = vi.fn(async () => ({ ok: false, status: 404, error: "Order not found" }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out).toEqual({ found: false, reason: "not_found" });
  });

  it("maps other failures (incl. the route not deployed yet) to lookup_unavailable", async () => {
    const get = vi.fn(async () => ({ ok: false, status: 0, error: "path not allowlisted" }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out).toEqual({ found: false, reason: "lookup_unavailable" });
  });

  it("rate-limits at 10/min per session", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    for (let i = 0; i < 10; i++) await tool.execute("c", { order_ref: UUID });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out).toEqual({ found: false, reason: "rate_limited" });
  });
});

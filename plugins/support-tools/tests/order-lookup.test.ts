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

// The admin order DTO (core-backend `services/orders/mapOrderToDto.js`) carries NO
// hold reason — only status, shipment and taxId. The doctrine tells Caroline to ask
// for exactly what a held order is waiting on, so the tool derives that here. These
// tests pin the derivation, because getting it wrong is customer-visible: asking a
// Brazilian for an "RFC", or re-asking for a phone number we already hold.
describe("createOrderLookupTool — fulfilment holds", () => {
  let rateLimiter: RateLimiter;
  beforeEach(() => { rateLimiter = new RateLimiter(); });

  const held = (over: Record<string, unknown>, shipmentOver: Record<string, unknown> = {}) => ({
    data: {
      ...ORDER_BODY.data,
      ...over,
      shipment: { ...ORDER_BODY.data.shipment, ...shipmentOver },
    },
  });

  const lookup = async (body: unknown) => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: body }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s" });
    return parse(await tool.execute("c", { order_ref: UUID }));
  };

  it("returns hold: null for an order that is not held", async () => {
    const out = await lookup(ORDER_BODY); // PROCESSING
    expect(out.order.hold).toBeNull();
  });

  it("names the tax id by what the DESTINATION calls it, not 'tax id'", async () => {
    const out = await lookup(held(
      { status: "NEEDS_TAX_ID", taxId: { present: false } },
      { address: { ...ORDER_BODY.data.shipment.address, countryCode: "BR" } },
    ));
    expect(out.order.hold).toEqual({
      status: "NEEDS_TAX_ID",
      missing: ["taxId"],
      taxIdLabel: "CPF or CNPJ",
      countryCode: "BR",
    });
  });

  it("says RNC for a Dominican order (the DGII's name), never the wire key RCN", async () => {
    const out = await lookup(held({ status: "NEEDS_TAX_ID", taxId: { present: false } })); // DO
    expect(out.order.hold.taxIdLabel).toBe("RNC");
  });

  // THE REGRESSION THIS SECTION EXISTS FOR. `shipment.phoneNumber` is the PRODIGI
  // recipient's phone, and a held order was never sent to Prodigi, so the deployed
  // DTO returns null for it on EVERY held order -- including one whose perfectly
  // good phone sits in details.shipping.phone. Deriving "needs a phone" from that
  // field sent Caroline back to the customer for a number we already had, on every
  // single held order.
  it("does NOT report a missing phone on a NEEDS_TAX_ID order whose phone is invisible pre-Prodigi", async () => {
    const out = await lookup(held(
      { status: "NEEDS_TAX_ID", taxId: { present: false } },
      { address: { ...ORDER_BODY.data.shipment.address, countryCode: "MX" }, phoneNumber: null },
    ));
    expect(out.order.hold.missing).toEqual(["taxId"]);
    expect(out.order.hold.missing).not.toContain("phone");
  });

  it("reads the hold from the STATUS, so a null Prodigi phone changes nothing", async () => {
    // Same order, phone field present vs null: the descriptor must be identical.
    const withPhone = await lookup(held({ status: "NEEDS_TAX_ID", taxId: { present: false } }, { phoneNumber: "+1 809 555 0100" }));
    const withNull = await lookup(held({ status: "NEEDS_TAX_ID", taxId: { present: false } }, { phoneNumber: null }));
    expect(withPhone.order.hold).toEqual(withNull.order.hold);
  });

  it("reports phone on NEEDS_CONTACT_INFO — the status is the backend's own statement", async () => {
    // processOrder only reaches NEEDS_CONTACT_INFO when the stored phone failed
    // isUsablePhone AND the tax id was fine, so the status proves it on its own.
    const out = await lookup(held({ status: "NEEDS_CONTACT_INFO", taxId: { present: true } }, { phoneNumber: null }));
    expect(out.order.hold.missing).toEqual(["phone"]);
    expect(out.order.hold.taxIdLabel).toBeNull();
  });

  it("does NOT list a tax id that is already on file", async () => {
    // Contradictory state (id stored, hold not yet released). Demanding it again
    // would ask the customer for something we hold; an empty list routes to the team.
    const out = await lookup(held({ status: "NEEDS_TAX_ID", taxId: { present: true, type: "rcn" } }));
    expect(out.order.hold.missing).toEqual([]);
    expect(out.order.hold.taxIdLabel).toBeNull();
  });

  it("still says a tax id is needed when the destination is not in our country table", async () => {
    // The backend held it, so an id IS wanted -- our table has simply fallen behind.
    // Reporting missing: [] here would tell Caroline nothing is outstanding.
    const out = await lookup(held(
      { status: "NEEDS_TAX_ID", taxId: { present: false } },
      { address: { ...ORDER_BODY.data.shipment.address, countryCode: "US" } },
    ));
    expect(out.order.hold.missing).toEqual(["taxId"]);
    expect(out.order.hold.taxIdLabel).toBeNull();
    expect(out.order.hold.countryCode).toBe("US");
  });

  it("survives an order with no shipment at all", async () => {
    const out = await lookup({ data: { ...ORDER_BODY.data, status: "NEEDS_CONTACT_INFO", shipment: null } });
    expect(out.order.hold.missing).toEqual(["phone"]);
    expect(out.order.hold.countryCode).toBeNull();
  });
});

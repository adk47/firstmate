import { describe, it, expect, vi, beforeEach } from "vitest";
import { createOrderLookupTool, orderDetailsRequireIvFrom } from "../src/tools/order-lookup.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { MusoAdminClient } from "../src/muso-admin-client.js";
import type { ContactIdentity, IntercomReader } from "../src/intercom-client.js";

const NOW = 1793116800;
const SESSION_KEY = "agent:support:intercom:direct:215476000000001";
function contact(over: Partial<ContactIdentity> = {}): ContactIdentity {
  return { email: "owner@example.com", role: "user", externalId: "pro-77", contactCreatedAt: NOW - 30 * 86400,
    conversationCreatedAt: NOW - 3600, ...over };
}
function reader(who: ContactIdentity | null): IntercomReader {
  return { getAuthorEmail: vi.fn(async () => who?.email ?? null), getLatestCustomerPart: vi.fn(async () => null),
    findBotMarkerInOtherConversations: vi.fn(async () => "unknown" as const),
    getContactIdentity: vi.fn(async () => who) } as IntercomReader;
}
// The order's own customer, verified: the full order comes back.
const OWNER = { orderDetailsRequireIv: false, sessionKey: SESSION_KEY, intercomToken: "tok", intercomReader: reader(contact()), nowSeconds: () => NOW };

const UUID = "6a468d83-b71d-4720-bb12-79ae8dfa55f8";

// A realistic admin order DTO (Prodigi-shape address), wrapped in the admin
// `{ data: ... }` envelope and carrying payment data that must NOT leak.
const ORDER_BODY = {
  data: {
    id: UUID,
    orderNumber: "k3n9Xa",
    prodigiOrderId: "66812882101295104",
    status: "PROCESSING",
    customerEmail: "Owner@Example.com",
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
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: "  " }));
    expect(out).toEqual({ found: false, reason: "missing_input" });
    expect(get).not.toHaveBeenCalled();
  });

  it("looks up by the given ref and returns a PII-scoped order WITHOUT payment data", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });

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
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.order.taxId).toEqual({ present: true, type: "rfc" });
    // The stored RFC value must not leak to the agent.
    expect(JSON.stringify(out)).not.toContain("GODE561231GR8");
  });

  it("treats a malformed (non-object) taxId from the DTO as not-present", async () => {
    const weird = { data: { ...ORDER_BODY.data, taxId: "unexpected-string" } };
    const get = vi.fn(async () => ({ ok: true, status: 200, data: weird }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.order.taxId).toEqual({ present: false });
  });

  it("url-encodes the ref", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    await tool.execute("c", { order_ref: "a b/c" });
    expect(get).toHaveBeenCalledWith("/api/v3/admin/orders/a%20b%2Fc");
  });

  it("tolerates an un-enveloped body", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY.data }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out.found).toBe(true);
    expect(out.order.id).toBe(UUID);
  });

  it("maps a 404 to not_found", async () => {
    const get = vi.fn(async () => ({ ok: false, status: 404, error: "Order not found" }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out).toEqual({ found: false, reason: "not_found" });
  });

  it("maps other failures (incl. the route not deployed yet) to lookup_unavailable", async () => {
    const get = vi.fn(async () => ({ ok: false, status: 0, error: "path not allowlisted" }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
    const out = parse(await tool.execute("c", { order_ref: UUID }));
    expect(out).toEqual({ found: false, reason: "lookup_unavailable" });
  });

  it("rate-limits at 10/min per session", async () => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
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
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter, sessionId: "s", ...OWNER });
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

// caroline-redteam-r1 EX-1: order_lookup handed a stranger's home address + phone to whoever named the
// order (gpt-6-sol 3/3). The full order goes only to the order's own, verified Intercom contact.
describe("createOrderLookupTool — owner anchor (EX-1)", () => {
  const PII = ["Av Enriquillo", "Santo Domingo", "11108", "+1 809 555 0100", "Acrylic Plaque", "Some Artist", "k3n9Xa", "66812882101295104"];
  const run = async (deps: Record<string, unknown>, body: unknown = ORDER_BODY) => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: body }));
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter: new RateLimiter(), sessionId: "s", ...deps } as any);
    return parse(await tool.execute("c", { order_ref: UUID }));
  };
  const expectStatusOnly = (out: any, check: string) => {
    expect(out).toMatchObject({ found: true, owner_verified: false, reason: "owner_undetermined", owner_check: check });
    expect(Object.keys(out.order).sort()).toEqual(["hold", "status"]);
    const dump = JSON.stringify(out);
    for (const p of PII) expect(dump, p).not.toContain(p);
  };

  it("the verified owner (case-insensitive email) gets the full order", async () => {
    const out = await run(OWNER);
    expect(out.owner_verified).toBe(true);
    expect(out.order.shipment.address.townOrCity).toBe("Santo Domingo");
  });

  it("a different contact gets status + hold only (the red-team attack)", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ email: "attacker@evil.test" })) }), "owner_mismatch");
  });

  it("a lead gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ role: "lead" })) }), "contact_not_user");
  });

  it("a contact with no external_id gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ externalId: null })) }), "contact_no_external_id");
  });

  it("a freshly minted contact on a fresh conversation (the spoof signature) gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ contactCreatedAt: NOW - 600, conversationCreatedAt: NOW - 300 })) }), "contact_too_new");
  });

  it("a contact under 24 h old is refused even on an OLDER conversation (no re-boot escape hatch)", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ contactCreatedAt: NOW - 600, conversationCreatedAt: NOW - 30 * 86400 })) }), "contact_too_new");
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(contact({ contactCreatedAt: NOW - 86400, conversationCreatedAt: NOW - 30 * 86400 })) }), "contact_too_new");
    expect((await run({ ...OWNER, intercomReader: reader(contact({ contactCreatedAt: NOW - 86401 })) })).owner_verified).toBe(true);
  });

  it("an unreadable contact gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomReader: reader(null) }), "contact_unreadable");
  });

  it("Slack (no Intercom conversation in the session key) gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, sessionKey: "agent:support:slack:channel:C123" }), "no_conversation");
  });

  it("no Intercom token gets status + hold only", async () => {
    expectStatusOnly(await run({ ...OWNER, intercomToken: "" }), "no_intercom_token");
  });

  it("an order without a customer email is never shown", async () => {
    const body = { data: { ...ORDER_BODY.data, customerEmail: null } };
    expectStatusOnly(await run(OWNER, body), "order_owner_unknown");
  });

  it("a held order still says what it waits on, to anyone", async () => {
    const body = { data: { ...ORDER_BODY.data, status: "NEEDS_CONTACT_INFO" } };
    const out = await run({ ...OWNER, intercomReader: reader(contact({ email: "x@y.z" })) }, body);
    expect(out.order).toMatchObject({ status: "NEEDS_CONTACT_INFO", hold: { missing: ["phone"] } });
  });
});

// firstmate 08:38Z / QA: until Intercom Identity Verification is on, NO caller gets order details, not
// even a contact that passes the owner anchor (IV off = a known email + professional id is enough).
describe("createOrderLookupTool — ORDER_DETAILS_REQUIRE_IV (default on)", () => {
  const PII = ["Av Enriquillo", "Santo Domingo", "11108", "+1 809 555 0100", "Acrylic Plaque", "Some Artist", "k3n9Xa", "66812882101295104"];
  const run = async (extra: Record<string, unknown>) => {
    const get = vi.fn(async () => ({ ok: true, status: 200, data: ORDER_BODY }));
    const r = reader(contact());
    const tool = createOrderLookupTool({ adminClient: makeClient(get as any), rateLimiter: new RateLimiter(), sessionId: "s",
      sessionKey: SESSION_KEY, intercomToken: "tok", intercomReader: r, nowSeconds: () => NOW, ...extra } as any);
    return { out: parse(await tool.execute("c", { order_ref: UUID })), r };
  };

  for (const [label, extra] of [["absent (the default)", {}], ["true", { orderDetailsRequireIv: true }]] as const) {
    it(`flag ${label}: even the verified owner gets status + hold only, and Intercom is not read`, async () => {
      const { out, r } = await run(extra);
      expect(out).toMatchObject({ found: true, owner_verified: false, reason: "owner_undetermined", owner_check: "identity_verification_off" });
      expect(Object.keys(out.order).sort()).toEqual(["hold", "status"]);
      for (const p of PII) expect(JSON.stringify(out), p).not.toContain(p);
      expect(r.getContactIdentity).not.toHaveBeenCalled();
    });
  }

  it("the flag parse fails closed: only false/'false'/0/'0' open the detail path", () => {
    for (const v of [undefined, null, "", true, "true", 1, "1", "no", "off", "FALSE ", {}]) expect(orderDetailsRequireIvFrom(v), String(v)).toBe(true);
    for (const v of [false, "false", 0, "0"]) expect(orderDetailsRequireIvFrom(v), String(v)).toBe(false);
  });

  it("flag explicitly false: the owner-anchored path returns the owner's full order", async () => {
    const { out } = await run({ orderDetailsRequireIv: false });
    expect(out.owner_verified).toBe(true);
  });
});

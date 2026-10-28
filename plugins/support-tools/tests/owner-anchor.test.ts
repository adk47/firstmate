import { describe, it, expect, vi } from "vitest";
import { createIntercomReader } from "../src/intercom-client.js";

// The reader behind the owner anchor (caroline-redteam-r1 EX-1/EX-2): the conversation's ONE contact,
// from the contact record, never message text.
describe("intercom-client getContactIdentity", () => {
  const http = (conv: unknown, contact: unknown, contactOk = true) =>
    ({
      get: vi.fn(async (url: string) =>
        url.includes("/contacts/") ? (contactOk ? { ok: true, data: contact } : { ok: false, status: 500 }) : { ok: true, data: conv }),
      post: vi.fn(),
      put: vi.fn(),
    }) as any;
  const conv = (o: Record<string, unknown> = {}) => ({ created_at: 1793100000, source: { author: { type: "admin" } },
    contacts: { contacts: [{ id: "k1" }] }, ...o });

  it("reads role, email, external_id and both creation times", async () => {
    const r = createIntercomReader(http(conv(), { role: "user", email: "Ann@Example.com", external_id: "p1", created_at: 1700000000 }));
    expect(await r.getContactIdentity!("c", "tok")).toEqual({ email: "ann@example.com", role: "user", externalId: "p1",
      contactCreatedAt: 1700000000, conversationCreatedAt: 1793100000 });
  });

  it("is null for two contacts, no contact, an unreadable contact, no email, or a non-contact role", async () => {
    const ok = { role: "user", email: "a@b.co", external_id: "p1", created_at: 1 };
    expect(await createIntercomReader(http(conv({ contacts: { contacts: [{ id: "k1" }, { id: "k2" }] } }), ok)).getContactIdentity!("c", "t")).toBeNull();
    expect(await createIntercomReader(http(conv({ contacts: { contacts: [] } }), ok)).getContactIdentity!("c", "t")).toBeNull();
    expect(await createIntercomReader(http(conv(), ok, false)).getContactIdentity!("c", "t")).toBeNull();
    expect(await createIntercomReader(http(conv(), { ...ok, email: "" })).getContactIdentity!("c", "t")).toBeNull();
    expect(await createIntercomReader(http(conv(), { ...ok, role: "admin" })).getContactIdentity!("c", "t")).toBeNull();
  });

  it("is null when the contact-authored source email differs from the contact record", async () => {
    const c = conv({ source: { author: { type: "user", email: "other@x.co" } } });
    expect(await createIntercomReader(http(c, { role: "user", email: "a@b.co", external_id: "p1", created_at: 1 })).getContactIdentity!("c", "t")).toBeNull();
  });

  it("returns a lead as a lead (the anchor refuses it) and a missing external_id as null", async () => {
    const r = createIntercomReader(http(conv(), { role: "lead", email: "a@b.co", created_at: 1 }));
    expect(await r.getContactIdentity!("c", "t")).toMatchObject({ role: "lead", externalId: null });
  });
});

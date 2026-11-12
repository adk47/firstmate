import { describe, expect, it } from "vitest";
import { captureAddress, restoreAddress, sameRecipient, type OrderRecipient } from "../src/order-address-revert.js";

const PRIOR: OrderRecipient = {
  name: "Demo Customer", phone: "+15550000001", line1: "1 Old Road", line2: "Unit 4",
  city: "Springfield", state: "IL", postcode: "62701", country: "US", company: "Demo Co",
};
const NEW: OrderRecipient = { ...PRIOR, line1: "123 Demo Street", line2: "", city: "Shelbyville" };

function store(initial: OrderRecipient) {
  let current = { ...initial };
  const writes: OrderRecipient[] = [];
  return {
    writes,
    read: async () => ({ ...current }),
    write: async (_ref: string, r: OrderRecipient) => { writes.push({ ...r }); current = { ...r }; },
  };
}

describe("order address revert: capture before the write, restore byte-for-byte", () => {
  it("restores every field the write touched, including the ones it cleared", async () => {
    const s = store(PRIOR);
    const captured = await captureAddress(s, "ord-1");
    await s.write("ord-1", NEW);
    expect(sameRecipient(await s.read("ord-1"), PRIOR)).toBe(false);
    const out = await restoreAddress(s, captured);
    expect(out).toEqual({ restored: true, mismatched: [] });
    expect(await s.read("ord-1")).toEqual(PRIOR); // line2 and company come back too
  });

  it("FAILS if the capture is skipped: a revert built from the post-write state cannot restore", async () => {
    const s = store(PRIOR);
    await s.write("ord-1", NEW);
    // The mistake this test exists to catch: capturing AFTER the write.
    const late = await captureAddress(s, "ord-1");
    const out = await restoreAddress(s, late);
    expect(out.restored).toBe(true); // it "restores" the NEW address
    expect(await s.read("ord-1")).toEqual(NEW);
    expect(sameRecipient(await s.read("ord-1"), PRIOR)).toBe(false); // the prior address is gone
  });

  it("a capture that read no address is not a revert point", async () => {
    const s = store({ ...PRIOR, line1: "" });
    await expect(captureAddress(s, "ord-1")).rejects.toThrow(/capture failed/);
  });

  it("a restore that does not land reports the fields that differ", async () => {
    const s = store(PRIOR);
    const captured = await captureAddress(s, "ord-1");
    await s.write("ord-1", NEW);
    const broken = { ...s, write: async () => {}, read: async () => ({ ...NEW }) };
    const out = await restoreAddress(broken, captured);
    expect(out.restored).toBe(false);
    expect(out.mismatched).toContain("line1");
  });
});

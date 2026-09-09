import { describe, it, expect } from "vitest";
import {
  validateProdigiAddress,
  toStripeAddress,
  normalizeTaxId,
  requiresTaxId,
  expectedTaxIdLabels,
  isUsablePhone,
  PRODIGI_MAX_LINE,
  type ProdigiAddressInput,
} from "../src/order-address.js";

const GOOD: ProdigiAddressInput = {
  name: "Maria Perez",
  line1: "Av Enriquillo 36",
  line2: "Apt 1101",
  postcode: "11108",
  city: "Santo Domingo",
  country: "DO",
  phone: "+1 809 555 0100",
};

describe("validateProdigiAddress", () => {
  it("passes a well-formed address", () => {
    const v = validateProdigiAddress(GOOD);
    expect(v.ok).toBe(true);
    expect(v.missing).toEqual([]);
    expect(v.over_length).toEqual([]);
    expect(v.invalid).toEqual([]);
    expect(v.warnings).toEqual([]);
  });

  it("rejects a full country name — Prodigi countryCode must be a 2-letter ISO code", () => {
    const v = validateProdigiAddress({ ...GOOD, country: "Dominican Republic" });
    expect(v.ok).toBe(false);
    expect(v.invalid).toContainEqual({ field: "Country", reason: "must be a 2-letter ISO country code (e.g. DO, US)" });
    // a valid 2-letter code (any case) passes
    expect(validateProdigiAddress({ ...GOOD, country: "do" }).ok).toBe(true);
  });

  it("flags every required field that is missing or blank", () => {
    const v = validateProdigiAddress({ line1: "x", city: "y", country: "z", postcode: "1", name: "  " });
    // name is whitespace-only (missing), phone absent.
    expect(v.ok).toBe(false);
    expect(v.missing).toContain("Name");
    expect(v.missing).toContain("Phone number");
    expect(v.missing).not.toContain("Address Line 1");
  });

  it("flags lines longer than 40 characters", () => {
    const longLine = "A".repeat(PRODIGI_MAX_LINE + 5);
    const v = validateProdigiAddress({ ...GOOD, line1: longLine });
    expect(v.ok).toBe(false);
    expect(v.over_length).toContainEqual({ field: "Address Line 1", length: longLine.length, value: longLine });
  });

  it("does NOT flag a line exactly 40 characters", () => {
    const exactly40 = "A".repeat(PRODIGI_MAX_LINE);
    const v = validateProdigiAddress({ ...GOOD, line1: exactly40 });
    expect(v.over_length).toEqual([]);
  });

  // The actual garbled address from Prodigi's email (screenshot): the street was
  // entered in the Recipient field, there is no recipient name, and no phone.
  it("catches the real garbled Dominican Republic address from the support email", () => {
    const garbled: ProdigiAddressInput = {
      name: "av enriqullo Nro 36, los cedrozgos", // street crammed into the name slot
      line1: "apto 1101",
      city: "santo domingo",
      postcode: "11108",
      country: "DOMINICAN REPUBLIC",
      // phone intentionally absent — Prodigi requires it
    };
    const v = validateProdigiAddress(garbled);
    expect(v.ok).toBe(false);
    expect(v.missing).toContain("Phone number");
    expect(v.warnings).toContain("recipient_name_looks_like_a_street_address");
  });

  it("treats a non-object input as an empty (fully-missing) address rather than throwing", () => {
    expect(() => validateProdigiAddress(undefined)).not.toThrow();
    const v = validateProdigiAddress("not an address");
    expect(v.ok).toBe(false);
    expect(v.missing.length).toBeGreaterThan(0);
  });

  it("does not warn on a normal name that happens to contain a token but no digit", () => {
    const v = validateProdigiAddress({ ...GOOD, name: "Stuart Avery" });
    expect(v.warnings).toEqual([]);
  });
});

describe("toStripeAddress", () => {
  it("maps the input to a Stripe-shape address for the admin PUT (postcode→postal_code), omitting blanks", () => {
    expect(toStripeAddress(GOOD)).toEqual({
      line1: "Av Enriquillo 36",
      line2: "Apt 1101",
      city: "Santo Domingo",
      postal_code: "11108",
      country: "DO",
    });
    // state/company/line2 absent → those keys are omitted entirely.
    expect(toStripeAddress({ line1: "x", city: "y", postcode: "1", country: "DO" })).toEqual({
      line1: "x", city: "y", postal_code: "1", country: "DO",
    });
  });

  it("upper-cases the ISO country code (Prodigi countryCode is upper-case)", () => {
    expect(toStripeAddress({ ...GOOD, country: "do" }).country).toBe("DO");
  });
});

// The tax-id rules are scoped PER DESTINATION COUNTRY and mirror core-backend's
// `services/orders/taxId.js` TAX_ID_RULES, which is the authority: PUT
// /admin/orders/:id re-validates against the destination and 400s on a mismatch.
// These tests pin the agreement — a shape we accept that the backend refuses is a
// false "saved" to the customer; one we refuse that it accepts leaves a shippable
// order held, which is the bug this whole path exists to prevent.
describe("normalizeTaxId — Mexico (RFC / CURP)", () => {
  it("accepts a 13-char individual RFC and infers type rfc", () => {
    const t = normalizeTaxId("GODE561231GR8", undefined, "MX");
    expect(t.ok).toBe(true);
    expect(t.value).toBe("GODE561231GR8");
    expect(t.type).toBe("rfc");
  });

  it("accepts a 12-char company RFC and infers type rfc", () => {
    expect(normalizeTaxId("ABC850101XYZ", undefined, "MX").type).toBe("rfc");
  });

  it("accepts an 18-char CURP and infers type curp", () => {
    const t = normalizeTaxId("BADD110313HCMLNS09", undefined, "MX");
    expect(t.ok).toBe(true);
    expect(t.type).toBe("curp");
  });

  it("normalizes case, spaces, dots and dashes", () => {
    const t = normalizeTaxId(" gode-561231.gr8 ", undefined, "MX");
    expect(t.ok).toBe(true);
    expect(t.value).toBe("GODE561231GR8");
  });

  it("accepts the Ñ and & characters that valid RFC/CURP ids legitimately contain", () => {
    const indiv = normalizeTaxId("PEÑA850101AB1", undefined, "MX"); // Ñ in the name portion
    expect(indiv.ok).toBe(true);
    expect(indiv.value).toBe("PEÑA850101AB1");
    const company = normalizeTaxId("AB&850101XY1", undefined, "MX"); // & in company initials
    expect(company.ok).toBe(true);
    expect(company.type).toBe("rfc");
    expect(normalizeTaxId("peña850101ab1", undefined, "MX").value).toBe("PEÑA850101AB1");
  });

  it("rejects a value whose length is neither RFC (12–13) nor CURP (18)", () => {
    // Forwarding a typeless id would have the backend silently drop it — a false
    // "saved" while the order stays held.
    const eleven = normalizeTaxId("ABCDE123456", undefined, "MX");
    expect(eleven.ok).toBe(false);
    expect(eleven.type).toBeNull();
    expect(eleven.reason).toMatch(/RFC or CURP/);
    expect(normalizeTaxId("ABCDE123456789", undefined, "MX").ok).toBe(false);
  });

  it("rejects a tax_id_type that disagrees with the id's shape (no silent override)", () => {
    const t = normalizeTaxId("BADD110313HCMLNS09", "rfc", "MX"); // 18 chars is a CURP
    expect(t.ok).toBe(false);
    expect(t.type).toBeNull();
    expect(t.reason).toMatch(/doesn't match the id's shape/i);
  });

  it("accepts an explicit type that matches the shape (confirmation only)", () => {
    const t = normalizeTaxId("GODE561231GR8", "rfc", "MX");
    expect(t.ok).toBe(true);
    expect(t.type).toBe("rfc");
  });

  it("rejects an indeterminate id even with an explicit type (an override can't fake a shape)", () => {
    const t = normalizeTaxId("ABCDE123456", "rfc", "MX");
    expect(t.ok).toBe(false);
    expect(t.type).toBeNull();
  });
});

describe("normalizeTaxId — the other seven customs-gated destinations", () => {
  // Each of these was rejected outright before the rules were country-scoped: the
  // validator only knew Mexico's 12/13/18-char shapes, so a held Brazilian order
  // could not be released by Caroline at all even though the backend accepts it.
  it.each([
    ["BR", "111.444.777-35", "cpf", "CPF or CNPJ"],
    ["BR", "11222333000181", "cnpj", "CPF or CNPJ"],
    ["CL", "12345678-K", "rut", "RUT"],
    ["AR", "20-12345678-9", "cuit", "CUIT"],
    ["PE", "20123456789", "ruc", "RUC"],
    ["CO", "900123456", "nit", "NIT"],
    ["EC", "1791234567001", "ruc", "RUC"],
    ["DO", "101234567", "rcn", "RNC"],
    ["DO", "40212345678", "rcn", "RNC"], // the 11-digit cédula
  ])("accepts a valid %s id (%s) as type %s", (country, raw, type) => {
    const t = normalizeTaxId(raw, undefined, country);
    expect(t.ok).toBe(true);
    expect(t.type).toBe(type);
    expect(t.value).toMatch(/^[A-Z0-9]+$/); // punctuation stripped
  });

  it("names the DOMINICAN id RNC, not the wire type key 'rcn'", () => {
    // The stored type stays `rcn` (core-backend's key, and Stripe's `do_rcn`), but
    // the customer only knows RNC — Registro Nacional de Contribuyentes, per the
    // DGII. Asking a Dominican customer for an "RCN" names nothing that exists.
    const t = normalizeTaxId("12345", undefined, "DO"); // wrong shape → the label surfaces
    expect(t.ok).toBe(false);
    expect(t.reason).toMatch(/RNC/);
    expect(t.reason).not.toMatch(/RCN/);
  });

  it("rejects an id valid for ANOTHER country — shapes collide across borders", () => {
    // An 11-digit Brazilian CPF is exactly an Argentine CUIT's shape. Grading
    // globally would print a CPF on a parcel to Argentina as a CUIT and have it
    // returned by customs, which is the bounce the hold exists to prevent.
    const mexican = normalizeTaxId("GODE561231GR8", undefined, "BR"); // RFC on a BR order
    expect(mexican.ok).toBe(false);
    expect(mexican.reason).toMatch(/not a valid CPF or CNPJ for BR/);

    const brazilian = normalizeTaxId("11144477735", undefined, "MX"); // CPF on an MX order
    expect(brazilian.ok).toBe(false);
  });

  it("rejects a type hint the destination does not use", () => {
    // Stripe collects the id against the BILLING country, which need not be the
    // destination — so 'cpf' can legitimately arrive on an order shipping to AR.
    // Relabelling it 'cuit' by shape would ship a CPF as a CUIT.
    const t = normalizeTaxId("20123456789", "cpf", "AR");
    expect(t.ok).toBe(false);
    expect(t.type).toBeNull();
    expect(t.reason).toMatch(/isn't used by AR/);
  });
});

describe("normalizeTaxId — non-gated destinations and bad input", () => {
  it("rejects a tax id for a country that has no customs tax-id requirement", () => {
    // The backend 400s on this ("no known customs tax-id format"), so accepting it
    // here would only produce a failure one layer later, with a worse message.
    const t = normalizeTaxId("123456789", undefined, "US");
    expect(t.ok).toBe(false);
    expect(t.reason).toMatch(/US has no customs tax-id requirement/);
  });

  it("rejects a tax id with no country at all rather than defaulting to Mexico", () => {
    const t = normalizeTaxId("GODE561231GR8");
    expect(t.ok).toBe(false);
    expect(t.reason).toMatch(/the destination has no customs tax-id requirement/);
  });

  it("accepts a lower-case country code", () => {
    expect(normalizeTaxId("11144477735", undefined, "br").ok).toBe(true);
  });

  it("treats empty / non-string input as not-ok rather than throwing", () => {
    expect(normalizeTaxId("", undefined, "MX").ok).toBe(false);
    expect(normalizeTaxId("", undefined, "MX").reason).toBe("empty");
    expect(() => normalizeTaxId(undefined, undefined, "MX")).not.toThrow();
    expect(normalizeTaxId(undefined, undefined, "MX").ok).toBe(false);
    // Punctuation-only sanitizes to empty — "empty", not a shape complaint.
    expect(normalizeTaxId("---", undefined, "MX").reason).toBe("empty");
  });
});

describe("requiresTaxId / expectedTaxIdLabels", () => {
  it("reports the eight gated destinations and nothing else", () => {
    for (const c of ["MX", "BR", "CL", "AR", "PE", "CO", "EC", "DO"]) {
      expect(requiresTaxId(c)).toBe(true);
    }
    for (const c of ["US", "GB", "IT", "", null, undefined]) {
      expect(requiresTaxId(c)).toBe(false);
    }
  });

  it("joins multi-type labels the way Caroline reads them aloud", () => {
    expect(expectedTaxIdLabels("MX")).toBe("RFC or CURP");
    expect(expectedTaxIdLabels("BR")).toBe("CPF or CNPJ");
    expect(expectedTaxIdLabels("CL")).toBe("RUT");
    expect(expectedTaxIdLabels("DO")).toBe("RNC");
    expect(expectedTaxIdLabels("US")).toBe("");
  });
});

describe("isUsablePhone / the phone gate", () => {
  // core-backend refuses an undialable phone on PUT /admin/orders/:id, and holds the
  // order as NEEDS_CONTACT_INFO until a usable one arrives. Accepting one here would
  // send Caroline into a 400 she cannot explain to the customer.
  it("accepts real numbers in the formats Stripe and wallets actually return", () => {
    for (const p of ["+1 809 555 0100", "(809) 555-0100", "+52 55 1234 5678", "8095550100"]) {
      expect(isUsablePhone(p)).toBe(true);
    }
  });

  it("refuses values with fewer than 7 digits, however they are dressed up", () => {
    for (const p of ["123", "n/a", "", "---", "+1 (2) 3"]) {
      expect(isUsablePhone(p)).toBe(false);
    }
  });

  it("does not throw on non-string input", () => {
    expect(isUsablePhone(undefined)).toBe(false);
    expect(isUsablePhone(null)).toBe(false);
    expect(isUsablePhone(8095550100)).toBe(true); // a number is dialable too
  });

  it("blocks an address whose phone is present but undialable, naming the phone", () => {
    const v = validateProdigiAddress({ ...GOOD, phone: "123" });
    expect(v.ok).toBe(false);
    expect(v.invalid.map((i) => i.field)).toContain("Phone number");
    // Present-but-invalid is NOT the same as absent — "missing" would tell Caroline
    // to collect a number she already has.
    expect(v.missing).not.toContain("Phone number");
  });

  it("still reports an absent phone as missing, not invalid", () => {
    const v = validateProdigiAddress({ ...GOOD, phone: "" });
    expect(v.missing).toContain("Phone number");
    expect(v.invalid.map((i) => i.field)).not.toContain("Phone number");
  });
});

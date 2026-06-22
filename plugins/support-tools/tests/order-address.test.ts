import { describe, it, expect } from "vitest";
import {
  validateProdigiAddress,
  toStripeAddress,
  normalizeTaxId,
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

describe("normalizeTaxId", () => {
  it("accepts a 13-char individual RFC and infers type rfc", () => {
    const t = normalizeTaxId("GODE561231GR8");
    expect(t.ok).toBe(true);
    expect(t.value).toBe("GODE561231GR8");
    expect(t.type).toBe("rfc");
    expect(t.warnings).toEqual([]);
  });

  it("accepts a 12-char company RFC and infers type rfc", () => {
    expect(normalizeTaxId("ABC850101XYZ").type).toBe("rfc");
  });

  it("accepts an 18-char CURP and infers type curp", () => {
    const t = normalizeTaxId("BADD110313HCMLNS09");
    expect(t.ok).toBe(true);
    expect(t.type).toBe("curp");
  });

  it("normalizes case, spaces, dots and dashes", () => {
    const t = normalizeTaxId(" gode-561231.gr8 ");
    expect(t.ok).toBe(true);
    expect(t.value).toBe("GODE561231GR8");
  });

  it("rejects an obviously-malformed id (too short / non-alphanumeric)", () => {
    expect(normalizeTaxId("123").ok).toBe(false);
    expect(normalizeTaxId("RFC!!!INVALID").ok).toBe(false);
    expect(normalizeTaxId("123").reason).toMatch(/10.?18/);
  });

  it("treats empty / non-string input as not-ok rather than throwing", () => {
    expect(normalizeTaxId("").ok).toBe(false);
    expect(normalizeTaxId("").reason).toBe("empty");
    expect(() => normalizeTaxId(undefined)).not.toThrow();
    expect(normalizeTaxId(undefined).ok).toBe(false);
  });

  it("rejects a tax_id_type that disagrees with the id's length (no silent override)", () => {
    // 18 chars is a CURP; a caller declaring it 'rfc' is a contradiction the backend
    // would also reject — refuse rather than forward a misclassified id (false 'saved').
    const t = normalizeTaxId("BADD110313HCMLNS09", "rfc");
    expect(t.ok).toBe(false);
    expect(t.type).toBeNull();
    expect(t.reason).toMatch(/match the id's length/i);
  });

  it("accepts an explicit type that matches the length (confirmation, no warning)", () => {
    const t = normalizeTaxId("GODE561231GR8", "rfc"); // 13 chars + rfc → agree
    expect(t.ok).toBe(true);
    expect(t.type).toBe("rfc");
    expect(t.warnings).toEqual([]);
  });

  it("warns on an unrecognized type but still accepts a well-shaped value", () => {
    const t = normalizeTaxId("GODE561231GR8", "vat");
    expect(t.ok).toBe(true);
    expect(t.type).toBe("rfc"); // falls back to inferred
    expect(t.warnings.join(" ")).toMatch(/unrecognized/);
  });

  it("accepts the Ñ and & characters that valid RFC/CURP ids legitimately contain", () => {
    // Ñ in an individual RFC's name portion (13 chars).
    const indiv = normalizeTaxId("PEÑA850101AB1");
    expect(indiv.ok).toBe(true);
    expect(indiv.type).toBe("rfc");
    expect(indiv.value).toBe("PEÑA850101AB1");
    // & in a company RFC's name initials (12 chars).
    const company = normalizeTaxId("AB&850101XY1");
    expect(company.ok).toBe(true);
    expect(company.type).toBe("rfc");
    // lower-case ñ upper-cases to Ñ.
    expect(normalizeTaxId("peña850101ab1").value).toBe("PEÑA850101AB1");
  });

  it("rejects a well-charactered value whose length is neither RFC (12–13) nor CURP (18)", () => {
    // 11 chars: passes the charset gate but type can't be determined → reject
    // rather than forward a typeless id the backend would silently drop.
    const eleven = normalizeTaxId("ABCDE123456");
    expect(eleven.ok).toBe(false);
    expect(eleven.type).toBeNull();
    expect(eleven.reason).toMatch(/RFC.*CURP|double-check/);
    // 14 chars: same.
    expect(normalizeTaxId("ABCDE123456789").ok).toBe(false);
  });

  it("rejects an indeterminate-length id even with an explicit type (an override can't fake a valid length)", () => {
    // 11 chars is not a valid RFC (12–13) or CURP (18) length; declaring it 'rfc'
    // must not make it pass — the backend would reject it anyway.
    const t = normalizeTaxId("ABCDE123456", "rfc");
    expect(t.ok).toBe(false);
    expect(t.type).toBeNull();
  });
});

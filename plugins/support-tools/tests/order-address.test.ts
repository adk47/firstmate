import { describe, it, expect } from "vitest";
import {
  validateProdigiAddress,
  toStripeAddress,
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

// Deterministic Prodigi shipping-address validation + formatting.
//
// Prodigi (Muso's print-on-demand plaque vendor) rejects any address line
// longer than 40 characters and asks support to reply with a specific labelled
// template. The Muso backend does NOT validate this anywhere — the order create
// path (`core-backend/src/components/prodigi/getProdigiAddressFromStripeAddress.js`)
// passes the checkout address straight through — so malformed addresses reach
// Prodigi, get bounced, and a human has to reformat them by hand. This module
// is the single source of truth for those rules.
//
// Phase 1 consumer: a non-blocking annotator on `order-fulfillment` tickets
// (create-ticket.ts) so ops gets a deterministic "is this Prodigi-valid?" stamp
// without re-counting characters. The same rules are reused by the Phase-2
// write-to-Prodigi gate and by `order_lookup` (DTO → input mapping) once those
// land — hence the mappers below live here too, so the field mapping has one home.

export const PRODIGI_MAX_LINE = 40;

// One field per line in Prodigi's confirmation template. `company`, `line2`,
// and `state` are the "(if applicable)" lines — optional. Everything else is
// required (Prodigi marks the phone number MANDATORY).
export interface ProdigiAddressInput {
  name?: string; // recipient full NAME — NOT a street (a common malformation)
  company?: string;
  line1?: string; // street & house number
  line2?: string; // building / block / apartment
  postcode?: string;
  city?: string;
  state?: string;
  country?: string;
  phone?: string;
}

interface FieldSpec {
  key: keyof ProdigiAddressInput;
  label: string;
}

// All template fields in Prodigi's requested order (used for the reply template
// and the per-line length check).
const TEMPLATE_FIELDS: FieldSpec[] = [
  { key: "name", label: "Name" },
  { key: "company", label: "Company" },
  { key: "line1", label: "Address Line 1" },
  { key: "line2", label: "Address Line 2" },
  { key: "postcode", label: "Postcode" },
  { key: "city", label: "City" },
  { key: "state", label: "State/Province" },
  { key: "country", label: "Country" },
  { key: "phone", label: "Phone number" },
];

const REQUIRED_FIELDS: FieldSpec[] = TEMPLATE_FIELDS.filter((f) =>
  ["name", "line1", "postcode", "city", "country", "phone"].includes(f.key),
);

export interface AddressViolation {
  field: string;
  length: number;
  value: string;
}

export interface AddressValidation {
  ok: boolean;
  missing: string[]; // labels of required fields that are empty/whitespace
  over_length: AddressViolation[]; // fields whose value exceeds 40 chars
  invalid: { field: string; reason: string }[]; // present but wrong-format (blocks)
  warnings: string[]; // heuristic tells (non-blocking)
}

function val(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

// ISO-3166 alpha-2: the backend maps address.country straight into Prodigi's
// `countryCode`, which MUST be a 2-letter code (e.g. "DO", not "Dominican
// Republic"). A full country name would survive to Prodigi and be rejected.
const ISO2_RE = /^[A-Za-z]{2}$/;

// The checkout often crams a street into the recipient/name field (the email's
// "Recipient" was literally "av enriqullo Nro 36, los cedrozgos"). Tell: the
// name carries a digit AND a street token. Warning only — never blocks.
const STREET_TOKENS =
  /\b(av|ave|avenida|calle|st|street|nro|no|rd|road|blvd|apt|apto|suite|ste)\b/i;

function nameLooksLikeStreet(name: string): boolean {
  return /\d/.test(name) && STREET_TOKENS.test(name);
}

export function validateProdigiAddress(input: ProdigiAddressInput | unknown): AddressValidation {
  const addr: ProdigiAddressInput =
    input && typeof input === "object" ? (input as ProdigiAddressInput) : {};

  const missing = REQUIRED_FIELDS.filter((f) => !val(addr[f.key])).map((f) => f.label);

  const over_length: AddressViolation[] = [];
  for (const f of TEMPLATE_FIELDS) {
    const v = val(addr[f.key]);
    if (v.length > PRODIGI_MAX_LINE) {
      over_length.push({ field: f.label, length: v.length, value: v });
    }
  }

  const invalid: { field: string; reason: string }[] = [];
  const country = val(addr.country);
  if (country !== "" && !ISO2_RE.test(country)) {
    invalid.push({ field: "Country", reason: "must be a 2-letter ISO country code (e.g. DO, US)" });
  }

  const warnings: string[] = [];
  if (nameLooksLikeStreet(val(addr.name))) {
    warnings.push("recipient_name_looks_like_a_street_address");
  }

  return {
    ok: missing.length === 0 && over_length.length === 0 && invalid.length === 0,
    missing,
    over_length,
    invalid,
    warnings,
  };
}

export interface StripeAddress {
  line1?: string;
  line2?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
}

// Map our neutral input → the Stripe-shape `address` the admin
// `PUT /admin/orders/:id` expects (the backend re-derives the Prodigi shape via
// getProdigiAddressFromStripeAddress). Address fields only — name/phone/email are
// sent as top-level PUT params, not inside `address`. Empty fields are omitted.
export function toStripeAddress(input: ProdigiAddressInput): StripeAddress {
  const out: StripeAddress = {};
  if (val(input.line1)) out.line1 = val(input.line1);
  if (val(input.line2)) out.line2 = val(input.line2);
  if (val(input.city)) out.city = val(input.city);
  if (val(input.state)) out.state = val(input.state);
  if (val(input.postcode)) out.postal_code = val(input.postcode);
  // country is validated to ISO alpha-2 before apply; normalize to upper-case
  // (Prodigi countryCode is upper-case alpha-2).
  if (val(input.country)) out.country = val(input.country).toUpperCase();
  return out;
}

// --- Recipient tax ID (Mexico RFC / CURP) -----------------------------------
//
// Since 1 Jan 2025 Mexican customs (SAT, art. 3.7.5) requires the *recipient's*
// RFC or CURP on imports; without it the parcel is held at customs and returned.
// Prodigi's recipient payload has no dedicated tax field, so the backend embeds
// the value into the recipient address it sends Prodigi (see the order tax-id
// backend spec). This helper normalizes + shape-checks what Caroline collects
// before it rides along in the `PUT /admin/orders/:id` body as `taxId`/`taxIdType`.
//
//   RFC  — 12 (legal entities) or 13 (individuals) alphanumeric chars
//   CURP — 18 alphanumeric chars
//
// We strip spaces/dots/dashes, upper-case, and require a valid RFC/CURP length:
// an obviously-malformed id is rejected because applying a bad one is no better
// than applying none (it still bounces at customs). Type is inferred from length
// (RFC 12–13, CURP 18); an explicit tax_id_type may confirm but not override it —
// a mismatch is rejected, matching the backend's length-per-type validation.
export type TaxIdType = "rfc" | "curp";

export interface TaxIdResult {
  ok: boolean;
  value: string; // normalized: upper-case, alphanumeric only
  type: TaxIdType | null; // inferred/provided; null if indeterminate
  reason?: string; // set when ok === false
  warnings: string[];
}

// RFC/CURP are A–Z and 0–9, PLUS `Ñ` (appears in the name portion of an
// individual RFC/CURP) and `&` (appears in a company RFC's name initials). Both
// are legitimate id characters, so the charset must allow them or valid ids get
// false-rejected. NB: core-backend currently strips non-`[A-Z0-9]` (mangling
// Ñ/&) — flagged for the backend in the order tax-id spec.
const TAXID_CHAR_RE = /^[A-Z0-9Ñ&]{10,18}$/;

export function normalizeTaxId(rawValue: unknown, rawType?: unknown): TaxIdResult {
  // val() does the string type-guard + trim (the trailing whitespace it trims is
  // also removed by the replace below — kept for consistency with the other
  // validators in this file); strip inner spaces/dots/dashes and upper-case.
  const value = val(rawValue).replace(/[\s.\-]/g, "").toUpperCase();
  const warnings: string[] = [];

  if (!value) return { ok: false, value: "", type: null, reason: "empty", warnings };
  if (!TAXID_CHAR_RE.test(value)) {
    return {
      ok: false,
      value,
      type: null,
      reason: "must be 10–18 letters/digits (Mexico RFC is 12–13, CURP is 18)",
      warnings,
    };
  }

  // Type is determined by length: RFC is 12–13 chars, CURP is 18.
  const type: TaxIdType | null =
    value.length === 18 ? "curp" : value.length === 12 || value.length === 13 ? "rfc" : null;

  // An explicit tax_id_type may CONFIRM the length-inferred type but never override
  // it: a declared type that disagrees with the length is rejected, not forwarded.
  // The backend applies the same length-per-type rule (it nulls a type that
  // contradicts the value's shape), so overriding here would only produce a false
  // "saved" before the backend drops the id.
  const provided = typeof rawType === "string" ? rawType.trim().toLowerCase() : "";
  if (provided && provided !== "rfc" && provided !== "curp") {
    warnings.push(`unrecognized tax_id_type "${provided}" — expected rfc or curp; using the length-inferred type`);
  } else if ((provided === "rfc" || provided === "curp") && provided !== type) {
    return {
      ok: false,
      value,
      type: null,
      reason: `tax_id_type "${provided}" doesn't match the id's length (RFC is 12–13 chars, CURP is 18) — double-check the id and its type`,
      warnings,
    };
  }

  // No valid length (a 10–11 or 14–17 char value) is neither RFC nor CURP — reject
  // it rather than forward a typeless id the backend can't classify and would
  // silently drop (a false "saved" to the customer).
  if (!type) {
    return {
      ok: false,
      value,
      type: null,
      reason: "couldn't tell if this is an RFC (12–13 chars) or a CURP (18 chars) — please double-check the id",
      warnings,
    };
  }

  return { ok: true, value, type, warnings };
}

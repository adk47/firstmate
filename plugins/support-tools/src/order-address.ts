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

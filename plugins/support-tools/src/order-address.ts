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

// Shortest plausible dialable number (local subscriber numbers bottom out around 7).
// Mirrors core-backend `services/orders/recipientContact.js`'s MIN_PHONE_DIGITS.
export const MIN_PHONE_DIGITS = 7;

// Prodigi marks the recipient phone mandatory and couriers require one on the
// commercial invoice, so an order without a usable one is held as NEEDS_CONTACT_INFO
// and `PUT /admin/orders/:id` 400s on an unusable value. Deliberately a shape check,
// not a validator, exactly as the backend does it: Stripe does not guarantee E.164
// for wallet payments, and refusing a real but oddly-formatted number would hold a
// shippable order for no customs benefit.
export function isUsablePhone(value: unknown): boolean {
  if (typeof value !== "string" && typeof value !== "number") return false;
  return String(value).replace(/\D/g, "").length >= MIN_PHONE_DIGITS;
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
  // A phone the backend will refuse is worse than none: releasing a
  // NEEDS_CONTACT_INFO hold is exactly what this tool is for, and forwarding an
  // undialable number gets a 400 from the wrapper that reads to Caroline as a tool
  // failure rather than "ask the customer for a longer number".
  const phone = val(addr.phone);
  if (phone !== "" && !isUsablePhone(phone)) {
    invalid.push({ field: "Phone number", reason: `must contain at least ${MIN_PHONE_DIGITS} digits — couriers need a dialable number for customs clearance` });
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

// --- Recipient tax ID (customs-gated destinations) ---------------------------
//
// Customs in eight Latin-American destinations requires the *recipient's* tax id
// on imports (Mexico's SAT art. 3.7.5 since 2025-01-01 is only the most common
// case); without it the parcel is held and returned. Prodigi's recipient payload
// has no dedicated tax field, so the backend embeds the value into the recipient
// address it sends Prodigi.
//
// This table MIRRORS core-backend `src/services/orders/taxId.js`'s TAX_ID_RULES,
// which is the authority: `PUT /admin/orders/:id` re-validates the id against the
// destination country and rejects a mismatch with `expectedTaxIdLabels(country)`.
// We pre-check here only so Caroline gets specific fix-it feedback before the
// wrapper runs — so the two MUST agree. A plugin rule stricter than the backend's
// false-rejects a valid id and leaves a shippable order held; a looser one produces
// a "saved" the backend then refuses. Keep them in lockstep: if a country or shape
// changes there, change it here in the same PR.
//
// Scoping is per COUNTRY, never global: an 11-digit Brazilian CPF and an Argentine
// CUIT are the same shape, so a global match would print a CPF on a parcel to
// Argentina as a CUIT and be returned by customs.
export type TaxIdType = "rfc" | "curp" | "cpf" | "cnpj" | "rut" | "cuit" | "ruc" | "nit" | "rcn";

interface TaxIdTypeRule {
  pattern: RegExp; // matched against the SANITIZED value (upper-case, punctuation stripped)
  label: string; // what the customer's country calls it — this is what Caroline asks for
  shape: string; // human description of the shape, for the fix-it message
}

const TAX_ID_RULES: Readonly<Record<string, Readonly<Record<string, TaxIdTypeRule>>>> = Object.freeze({
  // Mexico — RFC 12 (company) / 13 (individual), CURP exactly 18. The alphanumeric
  // exception: both encode name characters, and Ñ/& are legitimate id characters.
  MX: {
    rfc: { pattern: /^[A-ZÑ&0-9]{12,13}$/, label: "RFC", shape: "12–13 letters/digits" },
    curp: { pattern: /^[A-ZÑ&0-9]{18}$/, label: "CURP", shape: "18 letters/digits" },
  },
  BR: {
    cpf: { pattern: /^[0-9]{11}$/, label: "CPF", shape: "11 digits" },
    cnpj: { pattern: /^[0-9]{14}$/, label: "CNPJ", shape: "14 digits" },
  },
  // Chile — 7–8 digits plus a check digit that may be the letter K.
  CL: { rut: { pattern: /^[0-9]{7,8}[0-9K]$/, label: "RUT", shape: "8–9 characters, may end in K" } },
  AR: { cuit: { pattern: /^[0-9]{11}$/, label: "CUIT", shape: "11 digits" } },
  PE: { ruc: { pattern: /^[0-9]{11}$/, label: "RUC", shape: "11 digits" } },
  CO: { nit: { pattern: /^[0-9]{9,10}$/, label: "NIT", shape: "9–10 digits" } },
  EC: { ruc: { pattern: /^[0-9]{13}$/, label: "RUC", shape: "13 digits" } },
  // Dominican Republic — 9 digits (company RNC) or the 11-digit cédula.
  // The customer-facing name is **RNC** (Registro Nacional de Contribuyentes, per
  // the DGII). The `rcn` TYPE KEY is deliberately kept: it is the wire value
  // core-backend stores and Stripe's `do_rcn` tax-id type, and a type hint is
  // checked against that key. Only the label — what Caroline says out loud — is RNC.
  DO: { rcn: { pattern: /^([0-9]{9}|[0-9]{11})$/, label: "RNC", shape: "9 or 11 digits" } },
});

/** The rules for a destination, or null when it isn't customs-gated. */
function rulesForCountry(country: unknown): Readonly<Record<string, TaxIdTypeRule>> | null {
  const key = typeof country === "string" ? country.trim().toUpperCase() : "";
  return TAX_ID_RULES[key] ?? null;
}

/** Whether a destination country requires a recipient tax id for customs. */
export function requiresTaxId(country: unknown): boolean {
  return rulesForCountry(country) !== null;
}

/**
 * The id names a destination expects, joined for a human: 'BR' -> "CPF or CNPJ".
 * Empty string when the country isn't gated. This is the label Caroline reads to
 * the customer, so it must be the LOCAL name — "tax id" means nothing to them.
 */
export function expectedTaxIdLabels(country: unknown): string {
  const rules = rulesForCountry(country);
  if (!rules) return "";
  const labels = Object.values(rules).map((r) => r.label);
  return labels.length > 1 ? `${labels.slice(0, -1).join(", ")} or ${labels[labels.length - 1]}` : labels[0];
}

/** "RFC is 12–13 letters/digits, CURP is 18 letters/digits" — for the fix-it message. */
function describeTaxIdShapes(rules: Readonly<Record<string, TaxIdTypeRule>>): string {
  return Object.values(rules)
    .map((r) => `${r.label} is ${r.shape}`)
    .join(", ");
}

export interface TaxIdResult {
  ok: boolean;
  value: string; // normalized: upper-case, punctuation stripped
  type: TaxIdType | null; // resolved within the destination's rules; null when invalid
  reason?: string; // set when ok === false
}

// Upper-case + strip punctuation/spaces, KEEPING the chars an id legitimately uses:
// Ñ (the name portion of an RFC/CURP) and & (a company RFC's name initials). NFC so
// a decomposed Ñ counts as one character. Mirrors core-backend's sanitizeTaxIdValue —
// stripping a different character set would make the two disagree on the same input.
function sanitizeTaxIdValue(value: unknown): string {
  return val(value).normalize("NFC").toUpperCase().replace(/[^A-Z0-9Ñ&]/g, "");
}

/**
 * Normalize + shape-check a recipient tax id against its DESTINATION country.
 *
 * `country` is required and decides which shapes are valid: grading a Brazilian CPF
 * against Mexico's rules (or vice versa) either false-rejects a valid id or accepts
 * one that customs will bounce. A malformed id is rejected rather than forwarded —
 * applying a bad one is no better than applying none, since it still bounces at
 * customs, and the backend would drop it anyway (a false "saved" to the customer).
 *
 * An explicit `tax_id_type` may CONFIRM the shape-inferred type but never override
 * it, and must be a type this destination accepts. A hint naming another country's
 * type is a mismatch, not a licence to relabel: Stripe collects the id against the
 * BILLING country, which need not be the destination.
 */
export function normalizeTaxId(rawValue: unknown, rawType?: unknown, country?: unknown): TaxIdResult {
  const value = sanitizeTaxIdValue(rawValue);
  if (!value) return { ok: false, value: "", type: null, reason: "empty" };

  const rules = rulesForCountry(country);
  if (!rules) {
    // Not a customs-gated destination (or no country supplied). Forwarding the id
    // would produce a 400 from the backend, so say what is actually wrong.
    const where = val(country) ? val(country).toUpperCase() : "the destination";
    return {
      ok: false,
      value,
      type: null,
      reason: `${where} has no customs tax-id requirement — don't collect one for this order`
    };
  }

  const matches = Object.entries(rules)
    .filter(([, r]) => r.pattern.test(value))
    .map(([type]) => type as TaxIdType);

  if (matches.length === 0) {
    return {
      ok: false,
      value,
      type: null,
      reason: `not a valid ${expectedTaxIdLabels(country)} for ${val(country).toUpperCase()} — ${describeTaxIdShapes(rules)}`
    };
  }

  const provided = typeof rawType === "string" ? rawType.trim().toLowerCase() : "";
  if (provided) {
    if (!rules[provided]) {
      // A type this destination doesn't use at all (e.g. 'rfc' on a Brazilian order).
      return {
        ok: false,
        value,
        type: null,
        reason: `tax_id_type "${provided}" isn't used by ${val(country).toUpperCase()} — expected ${expectedTaxIdLabels(country)}`
      };
    }
    if (!matches.includes(provided as TaxIdType)) {
      return {
        ok: false,
        value,
        type: null,
        reason: `tax_id_type "${provided}" doesn't match the id's shape (${describeTaxIdShapes(rules)}) — double-check the id and its type`
      };
    }
    return { ok: true, value, type: provided as TaxIdType };
  }

  // Unhinted: the patterns are disjoint per type within a country, so the match is exact.
  return { ok: true, value, type: matches[0] };
}

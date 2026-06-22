# Backend spec — recipient tax-ID capture for Mexico (and customs-required countries)

**Owner:** core-backend team · **Requested by:** support/hydra (Caroline) · **Date:** 2026-06-22

This is the `core-backend` half of the plaque-order customs fix. The hydra/Caroline
half (collecting + forwarding the tax id) has shipped; this spec is what the backend
must do to make it effective end-to-end. Repo: `core-backend` (prod serves `master`).

## Why

Plaque/poster orders to **Mexico are held at customs and returned** when the
recipient's tax ID is missing. Since 1 Jan 2025 (SAT, art. 3.7.5) Mexican customs
requires the recipient's **RFC** (12–13 chars) or **CURP** (18 chars) on imports — for
**all** recipients, individuals and businesses. Prodigi requires the same for MX.

Evidence (live, 2026-06-22):
- Mexico is a top-5 international destination — **110 paid orders**.
- **~92% (101/110) carry no tax ID.** The `details.shipping.tax_ids` array is
  populated on only 49 orders across *all* countries.
- Intercom shows real, recurring, manually-handled customs **holds and returns**
  ("returned back… problem with the customs clearance"; "returned as per the courier's
  email"; "on hold due to pending customs fees"; "the courier need more details for
  the recipient to help this clear").

## Root cause

Stripe checkout already collects tax IDs —
`src/components/stripe/createOrderCheckoutSession.js` sets
`tax_id_collection: { enabled: true }` — but:
1. it's **optional**, so most MX buyers skip it;
2. the webhook **doesn't reliably persist** it
   (`src/controllers/payment/common/stripeWebhook.js` spreads `customer_details` /
   `shipping_details` into `details.shipping`, but `tax_ids` only lands when Stripe
   happens to include it inline); and
3. it is **never forwarded to Prodigi** (`src/components/prodigi/createOrder.js` +
   `getProdigiAddressFromStripeAddress.js` build a recipient with no tax field).

So we don't need to build capture from scratch — we need to **retain, require-for-MX,
and forward** what Stripe already collects.

## What hydra/Caroline already sends (the contract to honor)

`order_address_update` (the Caroline tool) → `PUT /admin/orders/:orderId`. Its body
already carries `{ name, phoneNumber, email?, address }`; it now ALSO sends, when the
customer provides a tax id:

```jsonc
{
  "name": "...", "phoneNumber": "...", "email": "...",
  "address": { "line1": "...", "city": "...", "postal_code": "...", "country": "MX", ... },
  "taxId": "GODE561231GR8",   // normalized: upper-case, alphanumeric, 10–18 chars
  "taxIdType": "rfc"          // "rfc" | "curp" (inferred from length when not given)
}
```

The current PUT handler (`src/apis/_admin/orders/updateOrder.js`) destructures fields
by name, so `taxId`/`taxIdType` are **silently ignored today** (no 400 — safe). Task
A4 below is to read and honor them.

## Backend tasks

**A1 — Retain the tax ID at checkout.** In `stripeWebhook.js`
(`checkout.session.completed`), persist the collected tax id into
`details.shipping.tax_ids` reliably — retrieve the session with `tax_ids` expanded if
the webhook payload doesn't include it inline (the expansion pattern already exists in
`src/services/marketplace/handleMarketplaceCheckout.js`).

**A2 — Forward RFC/CURP to Prodigi.** Prodigi's recipient payload has no tax field, so
per Prodigi's guidance embed the RFC/CURP into the recipient address it receives, for
MX (and any country that requires it). Touch `src/components/prodigi/createOrder.js`,
`src/components/prodigi/getProdigiAddressFromStripeAddress.js`, and the recipient build
in `src/components/prodigi/updateOrder.js`. Respect Prodigi's **40-char/line** limit.

**A3 — Hold MX-without-RFC instead of shipping into a bounce** (the agreed
"hold-and-collect" design). In `src/services/orders/processOrder.js`, if
`country === 'MX'` and no RFC/CURP is present, set a new hold status (e.g.
`NEEDS_TAX_ID` / `ON_HOLD`) rather than creating the Prodigi order. Add the status to
`src/services/orders/constants.js`. Caroline/Ops collect the id (A4) and release.

**A4 — Accept `taxId`/`taxIdType` on `PUT /admin/orders/:orderId`**
(`src/apis/_admin/orders/updateOrder.js`): read them, write to
`details.shipping.tax_ids`, forward to Prodigi via A2's path, and release an A3 hold.
This is what makes Caroline's collected RFC take effect.

**A5 — Track returns.** Add `RETURNED` / `CUSTOMS_HELD` statuses
(`src/services/orders/constants.js`) and validate the status set in
`src/apis/_admin/orders/updateOrderTracking.js` (it currently accepts any string).
Today a bounced parcel stays `SHIPPED` forever, so returns are unmeasurable.

**A6 (optional, product call) — DTO surfacing.** Include `tax_ids` (presence/value) in
the order DTO (`src/services/orders/mapOrderToDto.js`) so `order_lookup` can show
whether an order already has a tax id (avoids re-asking). Not required for the fix.

## Verification

- Place a test MX checkout **with** an RFC → assert `details.shipping.tax_ids` is
  stored and the RFC reaches the Prodigi recipient address; place one **without** →
  assert the order holds (A3) instead of creating a Prodigi order.
- `order_address_update` with `tax_id` on a held MX order → assert it persists and
  releases the hold (A4).
- Re-run the support team's Trino/Intercom queries after rollout to watch the
  no-tax-id share (101/110) and customs-conversation volume fall.

## Decisions already made (support side)

- **Hold-and-collect**, not a required RFC field at MX checkout (avoid conversion hit).
  If you'd prefer a required Stripe custom field for MX, that's your call — flag it.
- All order code is **CODEOWNERS @adk47**-gated; Aaron has final sign-off.

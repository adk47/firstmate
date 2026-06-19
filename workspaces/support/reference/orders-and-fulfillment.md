# Orders & fulfillment (plaques / posters via Prodigi)

Doctrine for handling physical-product order support. Pairs with the
`order-fulfillment` skill. This is internal reference — never read these internal
names or mechanics out to a customer.

## What the product is

Muso sells physical **acrylic plaques** (and posters) that celebrate an artist's
streams/milestones. They're customized in the web app, paid via Stripe checkout, then
**printed and shipped by a third-party print-on-demand vendor, Prodigi**. Plaques can
be ordered on any plan (including free Lite) — a paid subscription is not required.

## Order lifecycle

`NEW` → `PAID` → `PROCESSING` → `SHIPPED` → (`CANCELLED`)

- **NEW** — order created, awaiting Stripe payment.
- **PAID** — payment succeeded.
- **PROCESSING** — sent to Prodigi for printing.
- **SHIPPED** — Prodigi has dispatched it; tracking is available.
- **CANCELLED** — cancelled by Prodigi or by us.

The shipping address is collected on the **Stripe checkout page**, not in the app, so
a customer can't simply re-edit it in their settings after paying — address fixes go
through the team.

## The two order ids (important)

A Prodigi message usually quotes **two** references for the same order:

| Looks like | What it is |
|---|---|
| `6a468d83-b71d-4720-bb12-79ae8dfa55f8` (UUID) | **Our** internal order id (Prodigi's `merchantReference`) |
| `66812882101295104` (long number) | **Prodigi's** own order id |

Capture both when present — the team uses the UUID to find the order on our side and
the number to talk to Prodigi.

## The 40-character rule + required fields

**Prodigi rejects any address line longer than 40 characters.** Muso does not validate
this at checkout, so over-long or malformed addresses reach Prodigi, bounce, and
Prodigi emails us to fix them. When confirming/correcting an address, every line must
be **≤ 40 characters**, and these fields are required:

- **Name** (a real recipient name — not a street), **Address Line 1**, **Postcode**,
  **City**, **Country**, and a **Phone number** (Prodigi marks phone mandatory).
- **Country must be a 2-letter ISO code** (e.g. `DO`, `US`) — Prodigi's `countryCode`
  rejects full names. `order_address_update` refuses a full country name; convert it.
- Optional ("if applicable"): **Company**, **Address Line 2**, **State/Province**.

Prodigi asks us to reply in this labelled template:

```
Name:
Company (if applicable):
Address Line 1 (street & house number):
Address Line 2 (if applicable):
Postcode:
City:
State/Province etc. (if applicable):
Country:
Phone number (mandatory):
```

## Address field mapping

The same address shows up in three shapes — keep them straight:

| Checkout (Stripe) | Prodigi / order record | Prodigi reply template |
|---|---|---|
| `line1` | `line1` | Address Line 1 |
| `line2` | `line2` | Address Line 2 |
| `city` | `townOrCity` | City |
| `state` | `stateOrCounty` | State/Province |
| `postal_code` | `postalOrZipCode` | Postcode |
| `country` | `countryCode` | Country |
| name / phone (alongside) | recipient `name` / `phoneNumber` | Name / Phone number |

## Malformed-address tells

Watch for these — they're why Prodigi usually writes in:

- **A street typed into the recipient/Name field** with no actual person's name
  (real example: recipient = `av enriqullo Nro 36, los cedrozgos`). The team will
  need the real recipient name.
- **No phone number** (Prodigi requires it).
- **Any line over 40 characters.**

When the address can't be made valid from what's in front of you (no name, no phone),
the right move is to get the corrected address **from the customer** before it goes
back to Prodigi — say so in the request you file.

## Vendor lane vs customer lane

- **Vendor lane** — the message is from **Prodigi** (`@prodigi.com` /
  `@prodigigroup.com`, or signed "Prodigi") asking us to confirm/correct an address.
  Prodigi is the vendor, **not** the order owner — do **not** apply the customer
  ownership checks to them. They legitimately ask about customers' orders; that's the
  relationship.
- **Customer lane** — a customer asking about their own plaque (status, tracking, or
  an address change).

## What Caroline can and can't do here (today)

- **Can — read**: look an order up with `order_lookup` (by internal id, order number,
  or Prodigi id) to read its status + shipping address.
- **Can — edit (gated, owner only)**: correct an order's shipping recipient with
  `order_address_update`. The wrapper verifies the requester is the order owner
  (Intercom contact email == the order's owner email, re-checked server-side) and
  validates the address (≤40-char lines + required Name/Line1/Postcode/City/Country/
  Phone). Always dry-run → show the customer → explicit "yes" → apply. On any refusal
  it falls back to a ticket.
- **Can — escalate**: file a structured `order-fulfillment` request (Tier 1, 2 business
  days) for anything she can't apply (vendor-lane requests, non-owner requesters,
  already-shipped orders, apply failures). The request carries a deterministic
  `address_validation` stamp.
- **Cannot**: reply to Prodigi on Muso's behalf, or edit an order on a vendor's
  say-so — the corrected address must come from the customer. The team handles the
  vendor-facing reply.

## Quick customer answers

- *Do I need a paid plan to order a plaque?* No — available on any plan, including free
  Lite.
- *How long until it arrives?* It's printed to order then shipped, so allow time for
  both; if they want the live status, get the order id and flag it for the team.
- *Can you change my delivery address?* Get the order id and the full corrected address
  (short lines, ~40 chars max, with a phone number) and flag it for the team — the
  print order may already be in production, so it's not guaranteed but they'll try.

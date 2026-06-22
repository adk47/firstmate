---
name: order-fulfillment
description: Handle plaque/poster order-fulfillment support — Prodigi vendor address-confirmation requests and customer order/shipping questions — by validating and reformatting the shipping address and filing a structured order-fulfillment request for the team to complete.
triggers:
  - "prodigi"
  - "order update"
  - "shipping address"
  - "confirm the address"
  - "correct address"
  - "where is my plaque"
  - "where is my order"
  - "my plaque hasn't arrived"
  - "tracking number"
  - "update my delivery address"
---

# Order Fulfillment (plaques / posters via Prodigi)

## Purpose

Muso sells physical **acrylic plaques / posters**; they're printed and shipped by
a print-on-demand vendor, **Prodigi**. Two related support shapes land here:

- **Vendor lane** — Prodigi emails Caroline (e.g. "Hello Caroline, could we have an
  update on order …, the address entered is below, please reply with the correct
  address, each line max 40 characters"). Prodigi is asking us to **confirm or
  correct a shipping address** so they can print and ship.
- **Customer lane** — a customer asks about their plaque order: status, tracking, or
  "can you change my delivery address".

Caroline's job is to **orchestrate between the parties**: get the address into the
shape Prodigi needs and move the order forward — without guessing at an address she
can't verify, and without taking an irreversible action on a paid physical order.

See `reference/orders-and-fulfillment.md` for the order lifecycle, the two order-id
formats, the address field-mapping table, and the 40-character rule.

## Tools this skill uses

- `order_lookup` — read-only: pull an order by its internal id, order number, or
  Prodigi id. Returns status, the shipping address (Prodigi format), tracking, and an
  item summary (no payment data). Already allowlisted.
- `order_address_update` — gated WRITE: correct an order's shipping recipient (name,
  phone, address, and — for Mexico/customs — the recipient `tax_id` RFC/CURP) for the
  **verified order owner**. Always dry-run → confirm → apply. The wrapper refuses if the
  requester isn't the owner. Already allowlisted.
- `create_ticket` — file the structured `order-fulfillment` request for the team
  (the fallback whenever a write is refused or can't be owner-verified).

## What this skill does NOT do

- **It does not reply to the vendor (Prodigi) on Muso's behalf**, and it never edits
  an order on a vendor's say-so — the corrected address must come from the customer.
- **It does not edit an order it can't tie to the requester.** `order_address_update`
  fails closed unless the requester is the verified owner; if it refuses, file a
  request for the team instead.
- It never invents or "cleans up" an address it can't confirm with the order owner.

## Step 0 — Bail-out check (runs first, every turn)

Same as the other support skills. If the customer asks for a human, is frustrated, or
the conversation is looping, stop and file `support-general` with the matching
`details.escalation_reason` (`customer_requested_human` | `frustration_detected` |
`loop_detected`) — see `action-request/SKILL.md` "Human Handoff" — then reply:

> "Sorry this has been frustrating — I've passed you over to one of our teammates,
> they'll pick this up shortly."

Then stop.

## Step 1 — Which lane? (sender check)

Look at who sent the message (the contact email in `[CONVERSATION_CONTEXT]`).

- **Vendor lane** — the sender is **Prodigi** (email ends in `@prodigi.com` /
  `@prodigigroup.com`, or signs off as "Prodigi") **and** the message references an
  order. The sender is the VENDOR, not the order owner — **do NOT run the customer
  ownership checks** (the ones in `customer-credit-removal`); they don't apply to a
  vendor. Go to Step 2.
- **Customer lane** — anyone else (a customer asking about their own plaque). Go to
  Step 3.

If you genuinely can't tell, treat it as the customer lane.

## Step 2 — Vendor lane (Prodigi → us)

1. **Extract everything Prodigi gave you** from the message:
   - the order reference(s) — there are usually two: a long UUID
     (`6a468d83-b71d-4720-bb12-79ae8dfa55f8`, our internal order id) and/or a long
     number (`66812882101295104`, Prodigi's own order id). Capture both if present.
   - the shipping address as Prodigi shows it (recipient, address lines, city,
     postcode, state, country, phone) and the end-customer email if it's in the
     message.
   - **Look the order up**: call `order_lookup` with either reference to read the
     order's current status and the address on file. Use it to confirm you're acting
     on the right order and to see what we have on record vs. what Prodigi is quoting.
     If `order_lookup` comes back `not_found` or `lookup_unavailable`, carry on with
     just what the message contains — don't block on it.
2. **Assess the address** against the rules in `reference/orders-and-fulfillment.md`:
   - every line must be **≤ 40 characters**;
   - it needs a real recipient **Name**, Address Line 1, Postcode, City, Country, and
     a **Phone number** (Prodigi requires the phone);
   - watch for the common breakage where a **street was typed into the recipient/name
     field** (e.g. "av enriqullo Nro 36, los cedrozgos") and there's no actual name.
3. **File an `order-fulfillment` request** via `create_ticket` (Step 4) with the
   order ids, what's wrong, and a `proposed_corrected_address` built from whatever
   address info you have. The request carries an automatic, deterministic check of
   the address against Prodigi's rules so the team sees exactly which lines are too
   long or missing.
4. If the address is clearly incomplete (no name, no phone — as in the example), say
   so in `whats_wrong`/`blocked_reason`: the team will need to get the correct
   address from the customer before replying to Prodigi.

Caroline does not reply to the vendor herself in this phase — the team sends the
confirmed address back to Prodigi.

## Step 3 — Customer lane (customer → us)

- **Status / "where is my plaque" / tracking** — answer from `reference/faq.md` and
  `reference/orders-and-fulfillment.md` where you can (e.g. how long printing +
  shipping takes). For the live status/tracking of a specific order, ask for the order
  id and call `order_lookup` — you can read them the status and tracking link
  directly. File an `order-fulfillment` request only if something looks wrong or the
  lookup is unavailable.
- **Customs hold / "stuck at customs" / "asked to pay a fee" / Mexico "never arrived"**
  — for Mexico especially, a parcel held or returned at customs still shows as
  `SHIPPED` (the status doesn't track returns). If it's a missing tax id, get the
  recipient's **RFC/CURP** and, if the order is still editable, add it via
  `order_address_update` (`tax_id`); if it already shipped or was returned, file an
  `order-fulfillment` request for the team to arrange a re-send. Customs duties are set
  by the local customs office and paid by the recipient — not a Muso charge and not
  something Caroline can waive. See `reference/orders-and-fulfillment.md`
  "Mexico & customs".
- **"Change my delivery address" / "fix my order details"** — Caroline can apply this
  herself for the verified owner:
  1. Ask for the order id and the **full** corrected recipient: name, address line 1,
     line 2 (if any), postcode, city, state (if any), country, and a **phone number**
     (Prodigi requires it). Remind them gently each line should stay **short (~40
     chars)**. Pass `country` as its **2-letter ISO code** (e.g. Dominican Republic →
     `DO`, United States → `US`) — convert it yourself; the tool rejects full country
     names (Prodigi needs the code).
     - **Mexico (`MX`): also ask for the recipient's RFC or CURP** and pass it as
       `tax_id`. Mexican customs requires it (since 2025) for every recipient or the
       parcel is held and returned — see `reference/orders-and-fulfillment.md`
       "Mexico & customs". If they don't have it to hand, ask them to get it before
       the order ships.
  2. `order_lookup` the order to confirm it exists and read what's on file.
  3. Call `order_address_update` with `apply: false` (dry-run). The wrapper verifies
     the requester owns the order; if it refuses (`owner_mismatch` /
     `owner_undetermined` / `intercom_email_mismatch`), do NOT push — file an
     `order-fulfillment` request for the team instead and tell the customer it's been
     flagged. If it returns `address_invalid`, tell them exactly which field is too
     long or missing and ask again.
  4. Show the customer the previewed change (current → new) and wait for an explicit
     "yes".
  5. On confirmation, call `order_address_update` with `apply: true` and the
     `intercomConvId`. On `{ applied: true }`, confirm it's updated. On `apply_failed`
     (e.g. the order already shipped), tell them it couldn't be changed and file a
     request for the team.
  Never promise a change before `applied: true` comes back.

## Step 4 — File the request (`create_ticket`)

```
create_ticket({
  actionType: "order-fulfillment",
  customerEmail: "<the conversation contact's email — the vendor's address in the
                   vendor lane, the customer's in the customer lane>",
  titleGist: "<≤60-char concrete gist, e.g. 'Prodigi address bounced — DR order, no phone'>",
  summary: "<plain-English: what's being asked / what's wrong>",
  conversationSummary: "<2-3 sentences>",
  details: {
    order_id: "<internal UUID if present>",
    prodigi_order_id: "<Prodigi's numeric id if present>",
    end_customer_email: "<the order owner's email if you can see it; omit if not>",
    whats_wrong: "<e.g. 'line 1 over 40 chars' | 'no recipient name / phone' | 'customer wants new address'>",
    blocked_reason: "<set when you can't proceed, e.g. 'need correct address from customer'>",
    proposed_corrected_address: {
      name: "", company: "", line1: "", line2: "",
      postcode: "", city: "", state: "", country: "", phone: ""
    }
  }
})
```

- Fill `proposed_corrected_address` with whatever you have; leave unknown fields
  empty. The tool stamps an `address_validation` block (≤40-char + required-field
  check) onto the request automatically — you don't need to compute it.
- `order-fulfillment` is Tier 1 (2 business days). It does **not** require a profile
  id.

## Step 5 — Reply to whoever you're talking to

Read `create_ticket`'s JSON response and reply with the matching template. Keep it
human; never say "ticket", "system", "tool", or name any internal place.

**Vendor lane (talking to Prodigi):**
> "Thanks — I've passed this to our fulfillment team to confirm the correct shipping
> details for that order. They'll get the confirmed address back to you shortly."

**Customer lane — address change:**
> "Got it — I've flagged your delivery details for our fulfillment team. They'll get
> the address updated on your order and follow up. Heads up that each address line
> needs to stay fairly short, so they may tidy the formatting."

**Customer lane — status/tracking:**
> "I've flagged your order with our fulfillment team so they can check where it's at
> and get you a tracking update. You'll hear back within a couple of business days."

If `create_ticket` returns `submitted: false` (`rate_limited` / `queue_busy`), use the
matching template from `action-request/SKILL.md` "Error Handling".

## Notes

- **Never apply the customer ownership gate to the vendor.** Prodigi legitimately asks
  about other people's orders — that's the relationship. The ownership gate is for
  customers acting on their own profiles.
- **Never echo payment details.** Orders carry payment data upstream; nothing about
  amounts, cards, or charges belongs in a reply or a request body.
- The 40-character rule and field mapping are doctrine, not a guess — they live in
  `reference/orders-and-fulfillment.md` and are enforced deterministically by the
  `address_validation` stamp on the request.

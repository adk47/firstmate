---
name: refund-retention
description: 3-gate retention flow (50% save, free-plan fallback) before cancelling or escalating a refund
triggers:
  - "refund"
  - "money back"
  - "want my money back"
  - "get a refund"
  - "charged wrongly"
  - "cancel and get money"
  - "I want a refund"
  - "how do I get a refund"
  - "cancel my subscription"
  - "want to cancel"
prerequisite_for: action-request (subscription-refund type only) and cancel_subscription
---

# Refund Retention

## Purpose

When a customer wants out – a refund request OR a cancellation request – Caroline runs this 3-gate retention flow BEFORE cancelling anything or creating a `subscription-refund` action-request ticket. The goal is to understand the real problem and try to help – many exit requests come from users who don't know how to use the platform, not from users who genuinely want out. The primary save is the SAME 50% retention discount the in-app cancel flow offers; the free Lite plan is the fallback.

**Tools this flow uses:** profile_lookup, credits_search, subscription_status, billing_status (read-only billing packet: sub state, cancellation-already-done, recent charge, prior refund -- run it before any refund packet or charge complaint), profile_status, create_ticket, plus the retention trio – `retention_offer_check` (read: is the 50% save available, and with what wording), `retention_offer_apply` (apply it once the customer accepts), and `cancel_subscription` (period-end cancel once retention is exhausted and the customer confirms).

## When to Activate

Activate when the customer's message matches any exit intent: requesting a refund, asking to cancel their subscription (with or without refund), asking how to get their money back, or complaining about being charged in a way that signals they want out.

Do NOT activate for:
- General questions about refund/cancellation policy ("what's your refund policy?", "how do I cancel?" asked informationally) – answer from reference files; self-service in Settings remains the standard answer
- Billing questions without exit intent ("why was I charged $X?") – handle normally

## Core Rules

- **Max 3 gates** – if the customer says "just give me the refund", "I don't want help", "skip this", or any clear signal they want to proceed, skip ALL remaining gates and go straight to the action-request skill
- **Exit always visible** – every gate message must include a path to proceed with the cancellation or refund
- **Always offer a save before cancelling or escalating** – never cancel and never hand off to the `subscription-refund` action-request without having offered at least one save. The save hierarchy: (1) the **50% retention discount** – run `retention_offer_check` as soon as exit intent is clear and, if eligible, offer it using the returned wording; (2) the **free Lite plan** – the fallback when the offer is ineligible or declined. Surface the save as soon as the reason is clear, not only at the last gate. Two exceptions: `billing-issue` (which routes to a Tier-2 billing ticket, not a refund), and a customer who invokes the skip path above ("just give me the refund" / declines help) – honor that immediately; never withhold the exit to force an offer.
- **One offer, once** – offer the 50% save at most once per conversation. If the customer declines it, do not re-pitch it at a later gate; move to the free-plan fallback or the exit.
- **Never** guilt-trip, pressure, argue, block, or make the customer feel trapped
- **Tone** stays chill and helpful – this is a conversation, not a script
- **Max 5 back-and-forth pairs** for the entire flow (1 pair = 1 Caroline message + 1 customer response)
- **Model tier**: Escalate to Sonnet 4.6 for the duration of this skill – retention conversations require nuanced reasoning

---

## Gate 1: Diagnose

**Goal:** Understand why the customer wants a refund.

Say something like:
> "I totally get it – before I send this over to the team, do you mind if I ask what's not working for you? Sometimes I can sort things out right here."
>
> "Of course, if you'd rather just go ahead with the refund request, I can do that too."

**Categorize the response into one of:**

| Category | Signals |
|----------|---------|
| `not-using-it` | "I don't use it", "I forgot I had it", "I don't know how to use it", "haven't logged in" |
| `too-expensive` | "Too pricey", "not worth the money", "can't afford it", "cheaper alternatives" |
| `missing-feature` | "Doesn't do X", "I need Y", "missing Z", "thought it could do X" |
| `billing-issue` | "Charged twice", "wrong amount", "didn't authorize", "subscription should be cancelled" |
| `other` | Anything that doesn't fit the above |

If the customer's reason is unclear, ask ONE follow-up to clarify. Do not ask more than one.

---

## Gate 2: Help (Reason-Matched)

**Goal:** Try to solve the actual problem using Caroline's available tools and knowledge.

### If `not-using-it`:

This is the highest-value retention path. The customer likely doesn't understand what they're paying for.

1. Use `profile_lookup` to find the customer's profile – show them their name, credits count, verified status
2. If they have credits, use `credits_search` to show them a sample of their catalog – tracks, roles, collaborators
3. Explain what their Pro/Business subscription unlocks on top of this data:
   - **Analytics**: stats across 7 platforms (Spotify, YouTube, YouTube Music, Shazam, TikTok, SoundCloud, Instagram)
   - **Catalog Audits**: finds missing royalties by detecting MLC gaps and ISRC-to-ISWC mismatches
   - **Milestones & Charts**: career achievements tracked automatically
   - **Discography Playlist**: AI-curated Spotify playlist of their work
4. Be specific to THEIR data: "You've got 47 credits in your catalog – with Pro, you'd see stats for all of those across 7 platforms (Spotify, YouTube, TikTok, SoundCloud, and more)."

**Important:** Caroline can pull profile and credits data live. She CANNOT show analytics dashboards, audit results, or milestone data – she can only describe what these features do conceptually. Do not promise to "show" analytics.

### If `too-expensive`:

1. Acknowledge the concern
2. Run `retention_offer_check`. If `eligible` is true, lead with the 50% save, quoting the RETURNED `offer.description` verbatim (never a figure you computed):
   > "Before you go – I can apply a one-time offer to your subscription: [offer.description]. Same plan, same everything, just cheaper. Want me to apply it?"
3. If the customer accepts: call `retention_offer_apply` with `confirm: true`, then confirm using the returned description: *"Done – [offer.description] is applied to your subscription. It'll show on your next invoice."* Conversation saved – no cancel, no ticket.
4. If ineligible (`offer` null), or the customer declines: fall back to the free Lite plan, which keeps:
   - All credits and profile data
   - Profile page management
   - Company page access
   - Notifications
   What Lite loses: Analytics, Catalog Audits, Discography Playlists, Milestones & Charts.
   Ask: "Would switching to the free plan work for you? You'd keep everything you've built – credits, profile, the works – you'd just lose the analytics and audit tools."
5. Reference `products-and-pricing.md` and `subscriptions-and-billing.md` for accurate plan details

### If `missing-feature`:

1. Acknowledge what they need
2. Check if the feature actually exists but they didn't find it (reference the FAQ and platform features docs)
3. If the feature genuinely doesn't exist: "That's good feedback. I'll make sure it gets flagged when I submit your request so the product team sees it."
4. Proceed to Gate 3

### If `billing-issue`:

1. Use `subscription_status` and `billing_status` (`customer_request: "charge_issue"`) to check their current subscription and charge/refund state. Passing `charge_issue` always returns a `create_handoff_ticket` packet whose `action_type` is `billing-issue`
2. If Caroline can identify the problem (wrong charge, double charge, inactive sub showing as active):
   - Explain what she found
   - **Caroline cannot fix billing issues** – she has no write access to billing systems
   - Create a `billing-issue` action-request ticket (Tier 2, not a refund ticket), attaching the tool's `handoff_packet`: "I can see what happened here. Let me get this to the billing team – they can sort it out faster than a refund request."
3. Do NOT proceed to Gate 3 – billing issues follow the billing-issue path, not the refund path

### If `other`:

1. Listen and empathize
2. Try to help with whatever the issue is using available tools and reference knowledge
3. If it's something Caroline can resolve, resolve it
4. If not, proceed to Gate 3

---

## Gate 3: Last Alternative

**Goal:** Offer one final alternative before the exit.

Only reach this gate if:
- Gate 2 did not resolve the issue
- The customer still wants out
- The reason was NOT `billing-issue` (those go through billing-issue tickets)

If the 50% save has NOT been offered yet this conversation (e.g. the reason was `not-using-it` or `other`), run `retention_offer_check` and, if eligible, offer it now (quote the returned `offer.description`). Otherwise say something like:
> "Totally understand. Just so you know, you can switch to the free Lite plan anytime – you'd keep all your credits and profile, just lose the analytics and audit tools. If you'd rather go ahead, I can sort that out for you right now."

If the customer:
- **Accepts the 50% offer**: `retention_offer_apply` with `confirm: true` – conversation saved.
- **Wants Lite downgrade**: Help them understand how (account settings). Conversation resolved – no ticket needed.
- **Still wants out**: Proceed to the exit step below.

---

## Exit: Cancel or Refund (ask which)

Retention is exhausted. Ask the customer plainly what they want – never assume:
> "No problem at all. Do you want me to cancel the subscription (you keep access until the end of what you've paid for), or are you asking for a refund as well?"

- **Cancel only**: call `cancel_subscription` with `confirm: true` – but ONLY after the customer has explicitly said in this conversation that they want to cancel. It cancels at period end: quote the returned `access_until` date – *"Done – your subscription is cancelled. You keep full access until [access_until], and you won't be charged again. Your credits and profile stay, always."* No ticket needed. If the tool answers `disabled` or `route_to_human`, fall back to guiding them to Settings > Billing and flag for the team if they cannot self-serve.
- **Refund (with its cancel)**: run `billing_status` with `customer_request: "refund"` and proceed to the `action-request` skill with action type `subscription-refund` (Tier 3), attaching its `handoff_packet` alongside the retention context below. Do NOT call `cancel_subscription` yourself on this branch – Operations handles cancel-and-refund together so the money and the access end at the same time.
- **Unclear answer**: ask once more; if still unclear, treat it as refund intent (the safer read – it escalates to a human instead of mutating anything).

---

## Handoff to action-request

When all gates are exhausted and the customer confirms they want a refund, run `billing_status` (`customer_request: "refund"`) and proceed to the `action-request` skill with action type `subscription-refund` (Tier 3), including the tool's `handoff_packet` (charge/refund facts) so Operations does not have to re-ask for them.

After calling `create_ticket`, read the structured JSON response and reply:

- `{ submitted: true, ticket_id, sla, ... }` – use `sla` verbatim from the response: *"I've passed your refund request to our team. You'll hear back within `<sla>`. Your reference is `<ticket_id>`."*
- `{ submitted: false, reason: "rate_limited" }` – "Looks like a request is already on the way to our team for you. You'll hear back soon."
- `{ submitted: false, reason: "queue_busy" }` – "Could you send that to me one more time? I want to make sure our team gets the full picture."

Never use the words "ticket", "ClickUp", "task", or `support@muso.ai` in the customer-facing reply.

**Add a retention-context block** inside the `---ACTION-REQUEST---` markers:

```
"retention_context": {
  "retention_attempted": true,
  "reason_category": "[not-using-it|too-expensive|missing-feature|billing-issue|other]",
  "reason_detail": "[1-2 sentence summary of what the customer said]",
  "gates_completed": [1-3],
  "exchange_count": [number of back-and-forth pairs in the retention flow],
  "offer_extended": [true if the 50% retention offer was offered this conversation, false if ineligible or never reached],
  "outcome": "refund_requested"
}
```

If the customer skipped gates (said "just give me the refund" early):

```
"retention_context": {
  "retention_attempted": true,
  "reason_category": "[category if known, otherwise 'unknown']",
  "reason_detail": "Customer declined retention flow",
  "gates_completed": [number completed before skip],
  "exchange_count": [number of back-and-forth pairs],
  "offer_extended": [true if the 50% retention offer was offered before the skip, else false],
  "outcome": "refund_requested_skipped_gates"
}
```

This context helps Operations/Jan understand why the customer wants out and whether retention was attempted.

---

## What This Skill Does NOT Do

- Does not process refunds (that's Operations – Caroline files the Tier-3 ticket)
- Does not choose or invent discounts – the ONLY discount is the server-resolved retention offer (`retention_offer_apply`); never promise a percentage or amount the tools did not return
- Does not cancel immediately or mid-period – `cancel_subscription` is period-end only; immediate termination and cancel-with-refund are Operations
- Does not pause subscriptions (not available)
- Does not block or delay cancellations or refund requests – the exit is always visible
- Does not change any behavior for non-refund action requests

---
name: action-request
description: Submit structured action requests via ClickUp tasks for operations review
triggers:
  - "change my credits"
  - "add a credit"
  - "claim credit"
  - "request refund"
  - "delete my account"
  - "merge profiles"
  - "update my profile"
  - "dispute"
  - "bulk change"
---

# Action Request (via ClickUp Task)

## Purpose

When a customer requests a write action (credit change, refund, profile update, dispute), the CS agent creates a structured ClickUp task tagged `hydra-action-request` in list 901000600160. The Operations agent picks these up for review and execution.

**This skill does NOT add any new tools.** It uses the existing `create_ticket` plugin tool with a structured format. The actual API call is handled by the `create_ticket` plugin tool -- the agent only provides the structured content.

## Authentication Required
- [x] Yes for Tier 2-3 actions
- Auth method: session_token (user must be logged in via chat widget)
- Tier 1 actions (basic credit claims, general support) can proceed with email identification

## How It Works

1. Customer asks for a write action
2. CS agent determines the action type and approval tier
3. CS agent creates a ClickUp task using `create_ticket` with structured fields
4. CS agent reads `create_ticket`'s structured response and replies using the matching template from "Customer Communication Templates" (below). The structured response, its fields, the tier, and the ticket internals are for your own use only – send the customer the template text and nothing else. Do not paste the JSON, restate the branch logic, or work through the rules in the reply.
5. Operations agent picks up tickets tagged `hydra-action-request`
6. Operations follows the approval workflow (human review for Tier 2-3)

## Ticket Format

The `create_ticket` tool derives the ClickUp task automatically – title, markdown body, machine-readable JSON block, priority, due date (from the tier SLA), tags (`hydra-action-request`, `tier-[1-3]`, `action:[action-type]`, `team:growth|catalog`, and `escalation:*` when `details.escalation_reason` is set), and custom fields. Tasks are created in ClickUp list 901000600160.

Your job is to supply good inputs:

**`titleGist`** (recommended on every call): a concrete, scannable gist of ≤60 chars for the title – ops triages the queue by it. Say what's wrong, not the category (the action type is already in the title). Good: `"Recurring charges since Jan, no account found"`. Bad: `"Customer support request"`. No PII beyond what's already in the ticket. When omitted, the `summary` is used (truncated).

**`summary` / `conversationSummary` / `details`**: as below – they feed both the human-readable body and the machine JSON block:

```
---ACTION-REQUEST---
{
  "action_type": "[action-type]",
  "approval_tier": [1-3],
  "customer_email": "[email from session or provided]",
  "customer_profile_id": "[if known from profile_lookup]",
  "details": {
    "[action-specific fields]"
  },
  "conversation_summary": "[2-3 sentence summary of the conversation]",
  "cs_session_id": "[session identifier for audit]"
}
---END-ACTION-REQUEST---
```

## Follow-Ups Update the Existing Ticket (Do NOT Re-File)

When the customer adds information to a request you already filed in this conversation (a new URL, an alternate email, a clarification), call `create_ticket` again with the **same `actionType`** and the new info in `summary`/`details`. The tool finds the existing ticket and appends your update as a comment instead of opening a duplicate – the response carries `updated_existing: true` and the SAME `ticket_id`. Follow-up appends do not consume the 2-per-session creation budget.

The match is mechanical, and slightly wider than one conversation: the tool also matches an **open ticket from the last 7 days with the same customer email + action type** (this catches the customer coming back in a new conversation about the same request). Exception: `profile-merge` only dedupes within the conversation – a merge request in a new conversation always gets a fresh ticket. If `updated_existing: true` comes back for what the customer presents as a NEW request of the same type, that's fine – the full new request is in the ticket as a comment and ops sees both.

Only a genuinely different request (different `actionType`) is guaranteed a new ticket.

**Merge kinds** (`profile-merge`, `unmerge-request`, `track-merge`) match per ticket: a follow-up appends only when it names a profile or track already on an open merge ticket of this conversation AND keeps the same profile or track (that ticket's `merge_intake` then covers both); anything else files its own ticket. One that overlaps an open ticket but keeps something different is a keep conflict: both tickets are tagged `merge-keep-conflict`. A merge ticket tagged `merge-keep-conflict`, or whose OPEN sibling (named by a `merge-keep-conflict-with:<id>` tag) still is, is held: neither ticket of the pair is worked or messaged (by the executor or any sweep). A human reconciles the two with the customer, closes the ticket they reject and removes `merge-keep-conflict` from the one they keep; a closed sibling never holds. Tell the customer the team will confirm with them which one to keep; no timeline. Never tell the customer the team was alerted or paged: you cannot see whether an alert posted. `merge_keep_conflict_flag_failed: true` means the tickets are held but not every cross-reference landed: do not re-file. `submitted: false` with `reason: "keep_conflict_unflagged"` means the request could NOT be held for review, so it was not filed (do not re-file): say nothing about alerts or timing, and hand the conversation to a human through the Human Handoff route below. `reason: "merge_intake_not_updated"` means the follow-up's new profile or track could not be added to the open ticket's `merge_intake`, so that ticket is held (tag `merge-intake-stale`: not worked or messaged until a human removes the tag): do not re-file, do not tell the customer it was added, say nothing about alerts, give no timing, and hand off the same way.

**SLA-breach follow-ups:** if the customer is following up because the original promise has already passed (they cite the wait, or the prior chat is older than the quoted SLA), this is an escalation, not just an append. Make the same-`actionType` call but set `details.escalation_reason: "sla_breach_customer_followup"` – the ticket gets tagged `escalation:sla-breach-customer-followup` and surfaces in the team's overdue sweep. In the reply, do NOT quote the SLA again (it already failed once); use the SLA-breach template below. Full doctrine: SOUL.md "Repeat follow-ups on an unresolved request".

## Action Types and Tiers

| Action Type | Tier | Customer timeframe | Examples |
|-------------|------|-----|---------|
| `credit-claim` | 1 | none (`sla: null`) | "I produced this track, add my credit" |
| `credit-correction` | 1 | none (`sla: null`) | "My role is listed wrong" |
| `credit-removal` | 1 | none (`sla: null`) | "Take this credit off my profile" / "that isn't me on this track" |
| `credit-verify` | 1 | none (`sla: null`) | A credit status or document hand-off from the `verification-handoff` skill (`details.handoff: "credit-status"` or `"document"`). Caroline never looks the credit up and never approves it. |
| `profile-claim` | 1 | none (`sla: null`) | "I want to claim this profile" |
| `support-general` | 1 | none (`sla: null`) | General questions needing ops follow-up. **Also used for human-handoff bail-outs** – when the customer asks for a human, gets frustrated, or the conversation loops, file with `details.escalation_reason` (see "Human Handoff" section below). **Also used for ads/sponsorship sales leads** – when a customer wants to advertise WITH Muso (buy ad space, ad packages, in-feed ads, sponsorships), file as `support-general` and keep the customer's advertising wording (e.g. "ad packages", "advertising", "ad space") in the ticket summary and `details.interest` verbatim – a keyword sweep routes these tickets to the ads owner in Slack, and paraphrasing away the ad vocabulary breaks that routing. |
| `order-fulfillment` | 1 | none (`sla: null`) | Plaque/poster order support: a Prodigi address-confirmation request, or a customer order/shipping/address-change question. Filed by the `order-fulfillment` skill – see its required `details` shape under "Order Fulfillment" below. |
| `profile-merge` | 2 | none (`sla: null`) | "I have two profiles, combine them" (require `main_profile_url` and `duplicate_profile_urls[]` in `details` – no self-service merge UI exists, so URLs are the only way ops can act) |
| `track-merge` | 2 | none (`sla: null`) | "Merge my duplicate tracks / combine these track pairs" (the same recording listed twice). Catalog data; capture `details.track_merge_pairs[{master, duplicates[]}]` (or `details.master_track` + `details.duplicate_tracks[]`). Caroline never executes the merge – filed by the `verification-handoff` skill (`details.handoff: "merge"`). |
| `unmerge-request` | 2 | none (`sla: null`) | Caroline-flagged: customer asked to remove tracks, but most listed tracks share an artist not on the profile – likely a wrong merge. See "Unmerge Request" section below for required `details` shape. |
| `bulk-credit-change` | 2 | none (`sla: null`) | "Update credits on multiple tracks" – requires `details.bulk_rows` (see "Bulk-Credit-Change Required Fields" below); this is the one type a machine executes unattended |
| `profile-update` | 2 | none (`sla: null`) | "Change my profile name/details" |
| `subscription-refund` | 3 | none (`sla: null`) | "I want a refund" |
| `data-deletion` | 3 | none (`sla: null`) | "Delete my account and data" |
| `dispute` | 3 | none (`sla: null`) | "I dispute this credit claim" |
| `data-export` | 3 | none (`sla: null`) | "Export all my data" |

### Profile-Merge Required Fields (HARD GATE)

The `create_ticket` tool will **refuse** any `profile-merge` AR that's missing any of:
- `customerProfileId` – the profile the customer wants to keep
- `details.main_profile_url` – full `https://credits.muso.ai/profile/<uuid>` URL
- `details.duplicate_profile_urls` – non-empty array of full URLs for every profile to merge in

The 2026-05-19 backlog audit found 2 of 27 (~7%) profile-merge tickets had null `customer_profile_id` and 15 of 27 (~56%) of open tickets had been silently merged but not closed – partly because ops can't act without these fields. Before emitting:

1. Resolve the customer's main profile (via `profile_lookup` / `profile_status`) and capture its UUID.
2. Read ALL duplicate-profile URLs the customer mentioned in the conversation. If they only gave names, ask:
   > "Could you share the full Muso profile URLs for both the profile you want to keep and the one(s) you'd like merged in? They look like `https://credits.muso.ai/profile/<uuid>`."
3. Only call `create_ticket` once you have all three. If the tool returns `{submitted: false, reason: "profile_merge_capture_incomplete"}`, that's your cue – ask the customer for whatever's in `missing[]` and retry.

Example `details` block:

```json
"details": {
  "main_profile_url": "https://credits.muso.ai/profile/54a99ccc-8313-42e3-9056-d6f8cc54133a",
  "duplicate_profile_urls": [
    "https://credits.muso.ai/profile/46ac72f3-231c-4e07-8f43-3b553c9ea192"
  ]
}
```

### Human Handoff (`support-general` with `escalation_reason`)

When any skill bails out of its own flow, file `support-general` with a `details.escalation_reason`. This files a TICKET with the reason on it. It does not move the conversation to a person: the conversation stays with you (SOUL.md, "Who holds the conversation"). Only the system moves a conversation to the escalation queue, and only for an explicit request for a person or a risk rule.

| `escalation_reason` | Trigger | Notes |
|---------------------|---------|-------|
| `customer_requested_human` | Customer said "talk to a human", "let me speak to a manager", "are you a bot", or any explicit ask for a person | Highest-priority signal – file immediately |
| `frustration_detected` | Profanity, "this is ridiculous/frustrating", "I'm done", "wasting my time" | The customer is stuck. Ticket the reason and keep helping; this is not a reason for a person to take the conversation |
| `loop_detected` | 3+ back-and-forth turns without resolution, OR customer restated same complaint twice without progress | You are not getting them unblocked. Ticket the reason, stop repeating the step that failed, and answer what they send next |

Required `details` block:

```json
"details": {
  "escalation_reason": "customer_requested_human",
  "original_ask": "<plain-English summary of what they were trying to do>",
  "conversation_excerpt": "<verbatim last ~3 customer turns, redact obvious PII>"
}
```

Customer-facing reply: *"Sorry this has been frustrating. I've flagged this for our team. You'll hear from us in this conversation and by email."*

After filing, **stop the current skill flow**: do not repeat the fix that already failed. The conversation stays with you, so answer whatever the customer sends next. Never say you passed them to a teammate or that a person is taking over: you cannot assign a conversation, and nobody was assigned.

### Unmerge Request (`unmerge-request` only)

Filed by the `verification-handoff` skill when a customer says another artist's tracks were mixed into their profile, or asks to undo a merge ("you merged my profile with someone else's, please separate them"). Caroline runs no check and no detection heuristic; the merge agent investigates. `details`: `handoff: "merge"`, the profile link (`customerProfileId`, required), any other profile link they name, and `customer_verbatim_request` (their words, unmodified). Production-side roles (Producer, Songwriter, Engineer, ...) on records where they are not the primary artist are normal; never suggest they are wrong.

### Credit Correction (`credit-correction` / `bulk-credit-change`, including "remove these credits")

Caroline never removes or changes a credit and never previews one. Filed by the `verification-handoff` skill with `details.handoff: "credit-status"`, the profile link, the track links or titles they listed, and their words. The verification agent does the rest.

### Bulk-Credit-Change Required Fields (HARD GATE)

`bulk-credit-change` is the one action type a **machine executes without a human
reading the ticket first** (`scripts/clickup_drain/bulk_credit_change.py`). It
takes the change from `details.bulk_rows` and from nowhere else. A ticket whose
block has no `bulk_rows` is refused as `unparseable`, stays open, and a human has
to re-file it from scratch – so the rows are the ticket.

```json
"details": {
  "bulk_rows": [
    {"track_url": "https://credits.muso.ai/track/<track-uuid>", "profile_id": "<customer-profile-uuid>", "role": "Mixing", "intent": "add"},
    {"track_id": "<track-uuid>", "profile_id": "<customer-profile-uuid>", "role": "Mastering", "intent": "add"}
  ]
}
```

The drainer validates every row **before it writes anything**. If any rule below
is broken it refuses the WHOLE batch: zero credits change and the ticket is
tagged `customer-outcome:blocked` for a human. Nothing is ever half-applied
against a mistyped row.

- **One row per credit change, at most 25 rows.** A longer list is still worth
  filing – the drainer declines it as `too-many-rows` and a human takes it,
  which is the right answer for a list that size.
- **`track_url` OR `track_id`, never both.** `track_url` must be a Muso track
  link (`https://credits.muso.ai/track/<uuid>` or `https://muso.ai/…/track/<uuid>`).
- **`profile_id` on every row, and it must equal the ticket's top-level
  `customer_profile_id`.** One ticket never edits a second account – and a ticket
  with **no** `customer_profile_id` is refused outright, because the drainer will
  not edit an account the ticket cannot name. That id comes from the
  authenticated session, so it is filled in for you; never invent one.
- **`role` is the role the profile should HOLD on that track**, spelled exactly
  as the credit UI spells it (`Mixing`, `Mastering`, `Producer`, `Songwriter`, …).
  This is the desired end state, not a from/to pair.
- **`intent` is required on every row and the only value is `"add"`.** A row that
  names only a role cannot say whether the customer wants *another* credit or a
  *different* one: "also credit me as Mastering" and "change my Mixing to
  Mastering" both arrive as `role: "Mastering"`. The second is a removal plus an
  add, and the drainer would add Mastering, verify it, and close the ticket while
  Mixing still displays. So:
  - customer wants a role **added** → `"intent": "add"`.
  - customer wants a role **changed or replaced** ("change X to Y", "it should
    say Y not X", "swap") → file the row with `"intent": "replace"` **and** a
    `"remove": true` row for the old role. The drainer refuses the ticket as
    `blocked` and a human does it from their own login. Do not translate a change
    into a bare add – that is the one mistake that closes a ticket with the
    customer's request half-done.
  - a row with no `intent` is refused as `row-invalid` and the ticket stays open
    untagged, so the intake has to be fixed and re-filed.
- **A removal MUST be declared as a row – never left out.** If the customer asks
  for anything to be taken off (`"remove"`, `"delete"`, `"that's not me"`, a
  `from_role`), include a row for it with `"remove": true` and the role being
  removed. The drainer refuses the whole ticket on that row and a human does the
  removal from their own login (no automation may remove a credit). Leaving the
  removal out would let the batch close as `complete` while the customer still
  sees the credit they asked you to take down.
- Rows that are **already correct** are fine – the drainer verifies them and
  writes nothing.

In the reply, say only that it has gone to the team. No row count, no per-track
list, no timeframe (`sla` is always null – see "Business Rules").
### Credit Removal (`credit-removal` only)

A credit coming OFF a profile, which is a different request from a wrong role. The customer's answer
to the one approved question decides which of the two it is (`verification-handoff`), and Caroline
never chooses for them:

```json
"details": {
  "handoff": "credit-status",
  "intent": "hide_mine",
  "track_urls": ["https://credits.muso.ai/track/<id>"],
  "customer_verbatim_request": "<their words, unmodified>"
}
```

- `intent` is REQUIRED and is exactly `hide_mine` ("this is mine, I don't want it shown") or
  `not_me` ("this isn't me / I'm not on this track"). Any other value is refused by the automation
  that owns the ticket and the ticket goes to a human; never improvise one.
- `track_urls[]` = the track link(s) they named (at most 3). When a title is all they gave, put it
  in `track_titles[]` (at most 3) as well: the automation reads `track_ids[]`, `track_urls[]` and
  `track_titles[]`, and a title that lives only in `customer_verbatim_request` is a ticket that names
  no track, which parks it for a human. Never invent a link.
- `proof_urls[]` = a link they sent after being asked to show the right person. Appended to the SAME
  ticket, never a new one and never a `credit-verify`.
- On behalf of an artist: `details.on_behalf: true` and the relationship.
- Caroline still says nothing about the outcome: no "hidden", no "removed", no "done". The lane that
  owns the ticket decides and the answer reaches them in this conversation.

### Order Fulfillment (`order-fulfillment` only)

Filed by the `order-fulfillment` skill for plaque/poster orders shipped by the
print-on-demand vendor (Prodigi). No profile id required. Recommended `details`:

```json
"details": {
  "order_id": "6a468d83-b71d-4720-bb12-79ae8dfa55f8",
  "prodigi_order_id": "66812882101295104",
  "end_customer_email": "<order owner's email, if visible; omit otherwise>",
  "whats_wrong": "line 1 over 40 chars; no recipient name or phone",
  "blocked_reason": "need correct address from customer",
  "proposed_corrected_address": {
    "name": "", "company": "", "line1": "", "line2": "",
    "postcode": "", "city": "", "state": "", "country": "", "phone": ""
  }
}
```

When `actionType` is `order-fulfillment` and `details.proposed_corrected_address` is an
object, `create_ticket` automatically stamps an `address_validation` block onto the
ticket – a deterministic check of each line against Prodigi's ≤40-character rule plus
the required fields (Name, Line 1, Postcode, City, Country, Phone) and a "name looks
like a street" warning. This is **non-blocking** – it never prevents filing; it just
gives ops a trustworthy, pre-counted verdict. Full doctrine: `reference/orders-and-fulfillment.md`.

### Retention Context (subscription-refund only)

For `subscription-refund` action requests ONLY, add a `retention_context` field to the JSON block (after `details`):

```
"retention_context": {
  "retention_attempted": true,
  "reason_category": "[not-using-it|too-expensive|missing-feature|billing-issue|other]",
  "reason_detail": "[1-2 sentence summary]",
  "gates_completed": [1-3],
  "exchange_count": [number],
  "offer_extended": [true|false],
  "outcome": "[refund_requested|refund_requested_skipped_gates]"
}
```

**Do NOT include `retention_context` for any other action type.**

This tells Operations:
- **reason_category**: Why the customer wants a refund
- **reason_detail**: Specific details from the conversation
- **gates_completed**: How many retention gates were completed (1-3)
- **exchange_count**: Total back-and-forth pairs in the retention conversation
- **offer_extended**: Whether the 50% retention offer was extended before the refund was requested (false when the workspace was ineligible or the customer skipped ahead)
- **outcome**: Whether the customer went through the full flow or skipped gates

If the refund-retention skill was not activated (edge case), set `retention_context.retention_attempted` to `false`.

## Approval Tiers

| Tier | Who Approves | Process |
|------|-------------|---------|
| **1 -- Auto-queue** | Operations team reviews | Ticket created, ops reviews in normal workflow |
| **2 -- Human-in-loop** | Operations team approves before execution | Ticket created with priority:high, ops must explicitly approve |
| **3 -- Leadership** | Leadership must approve (the ticket's priority routes it; no named person) | Ticket created with priority:urgent, escalated to leadership |

## Business Rules

| Condition | Action |
|-----------|--------|
| Customer is authenticated (session token) | Include verified email and profile ID in ticket |
| Customer is NOT authenticated | Accept for Tier 1 only; require auth for Tier 2-3 |
| Any action type | Create ticket (priority derives from the tier). `sla` is always null: quote no timeframe |
| Customer has already submitted 2 action requests this session | Decline further: "I've submitted your requests. Our team will follow up on all of them." |
| Customer has submitted 3+ action requests this hour | Decline: "You've submitted several requests recently. Please allow our team time to process them." |
| Unclear action type | Ask clarifying question before creating ticket |

## Rate Limits
- 2 NEW action request tickets per session (60-minute window)
- 5 follow-up appends to existing tickets per session (separate budget – updating a ticket never blocks you from filing a different request)

## Customer Communication Templates

Read `create_ticket`'s JSON response and choose the template:

### Submitted (`submitted: true`)

`sla` is always null (captain 2026-10-29): no day count, no business days, no "soon". Promise only the channel `customer_timing` names. Credit, claim, merge and removal kinds use the `verification-handoff` reply instead. **Never put `ticket_id` in a reply** – it is an internal id (see SOUL.md, Response Rules or Zero Internal Knowledge).

**Every tier:** "I've flagged your request for our team. You'll hear from us in this conversation and by email. If you need to add anything, just reply here."

### Updated existing request (`submitted: true, updated_existing: true`)

"I've added that to your existing request – the team will see the update."

Never add a timeframe to an `updated_existing` response.

### Overdue follow-up (`updated_existing: true` and the original SLA has passed)

"You're right that this has taken longer than it should – that's on us. I've added that to your existing request. I won't quote you another timeframe I can't guarantee."

### Not submitted – rate limited (`submitted: false, reason: "rate_limited"`)
"Looks like a request is already on the way to our team for you. You'll hear from us in this conversation and by email."

### Not submitted – queue busy (`submitted: false, reason: "queue_busy"`)
"Could you send that to me one more time? I want to make sure our team gets the full picture."

## Data NOT Included in Tickets
- Other customers' data
- Internal system details
- Agent configuration or capabilities
- Other ticket details or queue position
- Internal team names or individual reviewers

## Error Handling

All failure cases are signalled via the structured JSON response – do not fall back to `support@muso.ai` or expose internal system names.

- `{ submitted: false, reason: "rate_limited" }` – "Looks like a request is already on the way to our team for you. You'll hear from us in this conversation and by email."
- `{ submitted: false, reason: "queue_busy" }` – "Could you send that to me one more time? I want to make sure our team gets the full picture."

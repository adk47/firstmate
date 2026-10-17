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

**SLA-breach follow-ups:** if the customer is following up because the original promise has already passed (they cite the wait, or the prior chat is older than the quoted SLA), this is an escalation, not just an append. Make the same-`actionType` call but set `details.escalation_reason: "sla_breach_customer_followup"` – the ticket gets tagged `escalation:sla-breach-customer-followup` and surfaces in the team's overdue sweep. In the reply, do NOT quote the SLA again (it already failed once); use the SLA-breach template below. Full doctrine: SOUL.md "Repeat follow-ups on an unresolved request".

## Action Types and Tiers

| Action Type | Tier | SLA | Examples |
|-------------|------|-----|---------|
| `credit-claim` | 1 | 2 business days | "I produced this track, add my credit" |
| `credit-correction` | 1 | 2 business days | "My role is listed wrong" |
| `credit-verify` | 1 | 2 business days | A pending ("user verification needed") credit case from the `customer-credit-verification` skill – recommend-approve or needs-human handoff with the proof evidence. File via that skill's Step 4, not ad hoc. |
| `profile-claim` | 1 | 2 business days | "I want to claim this profile" |
| `support-general` | 1 | 2 business days | General questions needing ops follow-up. **Also used for human-handoff bail-outs** – when the customer asks for a human, gets frustrated, or the conversation loops, file with `details.escalation_reason` (see "Human Handoff" section below). **Also used for ads/sponsorship sales leads** – when a customer wants to advertise WITH Muso (buy ad space, ad packages, in-feed ads, sponsorships), file as `support-general` and keep the customer's advertising wording (e.g. "ad packages", "advertising", "ad space") in the ticket summary and `details.interest` verbatim – a keyword sweep routes these tickets to the ads owner in Slack, and paraphrasing away the ad vocabulary breaks that routing. |
| `order-fulfillment` | 1 | 2 business days | Plaque/poster order support: a Prodigi address-confirmation request, or a customer order/shipping/address-change question. Filed by the `order-fulfillment` skill – see its required `details` shape under "Order Fulfillment" below. |
| `profile-merge` | 2 | 5 business days | "I have two profiles, combine them" (require `main_profile_url` and `duplicate_profile_urls[]` in `details` – no self-service merge UI exists, so URLs are the only way ops can act) |
| `track-merge` | 2 | 5 business days | "Merge my duplicate tracks / combine these track pairs" (the same recording listed twice). Catalog data; capture `details.track_merge_pairs[{master, duplicates[]}]` (or `details.master_track` + `details.duplicate_tracks[]`). Caroline never executes the merge – filed by the `customer-track-dedupe` skill. |
| `unmerge-request` | 2 | 5 business days | Caroline-flagged: customer asked to remove tracks, but most listed tracks share an artist not on the profile – likely a wrong merge. See "Unmerge Request" section below for required `details` shape. |
| `bulk-credit-change` | 2 | 5 business days | "Update credits on multiple tracks" |
| `profile-update` | 2 | 5 business days | "Change my profile name/details" |
| `subscription-refund` | 3 | 5-10 business days | "I want a refund" |
| `data-deletion` | 3 | 10 business days | "Delete my account and data" |
| `dispute` | 3 | 10 business days | "I dispute this credit claim" |
| `data-export` | 3 | 10 business days | "Export all my data" |

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

When the customer-credit-removal skill (preview and route only; it never removes a credit) or any future skill decides to bail out and hand off to a teammate, file `support-general` with a `details.escalation_reason`:

| `escalation_reason` | Trigger | Notes |
|---------------------|---------|-------|
| `customer_requested_human` | Customer said "talk to a human", "let me speak to a manager", "are you a bot", or any explicit ask for a person | Highest-priority signal – file immediately |
| `frustration_detected` | Profanity, "this is ridiculous/frustrating", "I'm done", "wasting my time" | The customer may not have asked for a human explicitly but is clearly stuck |
| `loop_detected` | 3+ back-and-forth turns without resolution, OR customer restated same complaint twice without progress | Caroline isn't getting them unblocked; human eyes needed |

Required `details` block:

```json
"details": {
  "escalation_reason": "customer_requested_human",
  "original_ask": "<plain-English summary of what they were trying to do>",
  "conversation_excerpt": "<verbatim last ~3 customer turns, redact obvious PII>"
}
```

Customer-facing reply: *"Sorry this has been frustrating – I've passed you over to one of our teammates, they'll pick this up shortly."*

After filing, **stop the current skill flow.** Don't propose further fixes or ask more clarifying questions. The teammate will take over.

### Unmerge Request (`unmerge-request` only)

Filed by the `customer-credit-removal` skill (preview and route only) when it detects that a customer's "remove these tracks" request looks like a wrong-merge case. Trigger: 10+ listed tracks share a single primary artist NOT on the profile's roster (i.e., not in `profile.name` or `profile.knownAsNames`), AND the profile owner has no production-side role on those tracks (see canonical role list below). Caroline does NOT execute the unmerge – Aaron approval is required (see `muso-ops-profiles/SKILL.md`). This ticket gives Aaron pre-fetched context so he can decide in seconds.

**Canonical production-side role list** (used by Caroline's unmerge-detection AND by the wrapper script's `refused_production_role_on_track` guard):

`Producer`, `Co-Producer`, `Songwriter`, `Composer`, `Lyricist`, `Mixing`, `Mixing Engineer`, `Mastering`, `Mastering Engineer`, `Engineer`, `Recording Engineer`, `Arranger`.

The wrapper script enforces this list mechanically per row – if a customer asks to remove a track where their profile holds any of these roles, the script refuses with `refused_production_role_on_track` and Caroline routes to `action-request` (`credit-correction`) for ops review. The list is the same in both places by design; if you update one, update the other.

**False-positive guardrail (do NOT file `unmerge-request` for these)**:
- Producer / songwriter / engineer profiles where the profile owner's `credits[]` on most tracks is one of the production-side roles above. Producers and writers legitimately appear on records where they aren't the primary artist – that's the work they do. If you're tempted to file `unmerge-request` for a profile like this, stop and re-check the role distribution before escalating. This was the ticket 869ck6tv6 lesson.

Required `details` block (everything Caroline can supply from `profile_status` + the conversation):

```json
"details": {
  "suspect_artist_names": ["Don Pero"],
  "suspect_track_count": 12,
  "total_listed_count": 17,
  "profile_name": "Achille G",
  "profile_known_as": ["Achille G", "Achille"],
  "customer_verbatim_request": "Hey, can you remove these tracks from my profile, they're not mine: ...",
  "suggested_action": "investigate_as_unmerge"
}
```

Fields:
- `suspect_artist_names[]` – the artist(s) Caroline flagged as not belonging on the profile
- `suspect_track_count` – how many of the listed tracks share that artist
- `total_listed_count` – total tracks the customer asked about (the ratio matters)
- `profile_name`, `profile_known_as[]` – what the profile is supposed to be (read from `profile.name` and `profile.knownAsNames` in the `profile_status` response)
- `customer_verbatim_request` – the customer's words, unmodified
- `suggested_action` – currently always `"investigate_as_unmerge"`; reserved for future enums

**Not supplied by Caroline** – fetched by ops at triage time:
- `raw_profile_sources[]` – the upstream sources this profile pulls from. `profile_status` doesn't expose `rawProfiles[]`, so Caroline can't include it. Ops fetches it directly via the admin API when investigating (it's the load-bearing field for "which raw_profile brought the unwanted tracks in").

### Credit Correction – removal (`credit-correction` from `customer-credit-removal`)

Caroline never removes a credit. When `customer-credit-removal` routes a removal ask, the packet IS the staged request: it carries one row per preview result so a staff run can consume them directly. Removal packets file as `credit-correction`, which `TIER_MAP` puts at tier 1 with a 2-business-day SLA; a dedicated tier-2 `credit-removal-request` type is tracked in MUS-10728 and this section changes with it. Required `details` block:

```json
"details": {
  "removal_rows": [
    {"track_id": "<uuid>", "profile_id": "<uuid>", "label": "<artist, or 'Name (requester req)'>",
     "track_title": "<title>", "roles": "Composer,Co-Producer", "ref": "Intercom <conv_id>"}
  ],
  "requester_email": "<intercom-verified>",
  "preview_source": "remove_credits dry-run <ISO ts>"
}
```

- One object per `results[]` row the preview resolved (`track_id` = `matched_track_id`, `track_title` = `matched_title`). A `would_remove` row has no roles: take `roles` from the Step 3 `credits_search` `credits[]` entries matched by title and artists (`creditRoles`), comma-joined, never invented; same-title tracks with different roles are flagged in `label`.
- `ref` is a traceable origin: `Intercom <conv_id>`, a ClickUp id, or a Slack/Buzz ts.
- The six row fields map, in order, to six tab-separated columns (`track_id`, `profile_id`, `label`, `track_title`, `roles`, `ref`; no header) that a staff run reads. If the preview resolved no rows (the wrapper refused first), file `removal_rows: []` plus the customer's verbatim request with each track named by title; otherwise do not file the packet without rows.

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
| **3 -- Leadership** | Aaron or Jan must approve | Ticket created with priority:urgent, escalated to leadership |

## Business Rules

| Condition | Action |
|-----------|--------|
| Customer is authenticated (session token) | Include verified email and profile ID in ticket |
| Customer is NOT authenticated | Accept for Tier 1 only; require auth for Tier 2-3 |
| Action type maps to Tier 1 | Create ticket, use `sla` from structured response |
| Action type maps to Tier 2 | Create ticket with priority:high, tell customer "5 business days" |
| Action type maps to Tier 3 | Create ticket with priority:urgent, tell customer "our leadership team will review" |
| Customer has already submitted 2 action requests this session | Decline further: "I've submitted your requests. Our team will follow up on all of them." |
| Customer has submitted 3+ action requests this hour | Decline: "You've submitted several requests recently. Please allow our team time to process them." |
| Unclear action type | Ask clarifying question before creating ticket |

## Rate Limits
- 2 NEW action request tickets per session (60-minute window)
- 5 follow-up appends to existing tickets per session (separate budget – updating a ticket never blocks you from filing a different request)

## Customer Communication Templates

Read `create_ticket`'s JSON response and choose the template:

### Submitted (`submitted: true`)

Use `sla` verbatim from the response. **Never put `ticket_id` in a reply** – it is an internal id (see SOUL.md, Response Rules or Zero Internal Knowledge).

**Tier 1:** "I've flagged your request for our team. You'll hear back within `<sla>`. If you need to add anything, just reply here."

**Tier 2:** "I've escalated your request to our operations team. This type of request requires manual review – you'll hear back within `<sla>`. If you need to add anything, just reply here."

**Tier 3:** "I've passed your request to our senior team for review. You can expect a response within `<sla>`. If you need to add anything, just reply here."

### Updated existing request (`submitted: true, updated_existing: true`)

"I've added that to your existing request – the team will see the update."

Do NOT re-quote the `sla` on an `updated_existing` response – the clock started when the ticket was first filed, and repeating the timeframe on every follow-up reads as a fresh promise.

### Overdue follow-up (`updated_existing: true` and the original SLA has passed)

"You're right that this has taken longer than it should – that's on us. I've raised the priority on your existing request so it's flagged for the team's overdue review. I won't quote you another timeframe I can't guarantee, but it is marked at the highest priority I can set."

### Not submitted – rate limited (`submitted: false, reason: "rate_limited"`)
"Looks like a request is already on the way to our team for you. You'll hear back soon."

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

- `{ submitted: false, reason: "rate_limited" }` – "Looks like a request is already on the way to our team for you. You'll hear back soon."
- `{ submitted: false, reason: "queue_busy" }` – "Could you send that to me one more time? I want to make sure our team gets the full picture."

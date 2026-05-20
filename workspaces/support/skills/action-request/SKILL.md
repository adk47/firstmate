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
4. CS agent reads `create_ticket`'s structured response (JSON), then composes the customer-facing reply:
   - `{ submitted: true, ticket_id, sla, action_type, tier }` – say: *"I've flagged your request for our team. You'll hear back within `<sla>`."*
   - `{ submitted: false, reason: "rate_limited" }` – acknowledge and stop: *"Looks like a request is already on the way to our team for you. You'll hear back soon."*
   - `{ submitted: false, reason: "queue_busy" }` – ask the customer to retry their message: *"Could you send that to me one more time? I want to make sure our team gets the full picture."*

   Never use the words "ticket", "ClickUp", "task", or `support@muso.ai` in the customer-facing reply.
5. Operations agent picks up tickets tagged `hydra-action-request`
6. Operations follows the approval workflow (human review for Tier 2-3)

## Ticket Format

Every action request ticket MUST use this structure:

**Subject**: `Action Request: [action-type]`

**Tags**: `hydra-action-request`, `tier-[1-3]`

**Note**: Tasks are created in ClickUp list 901000600160. Tags are applied as ClickUp task tags.

**Description** (includes machine-readable JSON block):
```
Customer [name/email] requests: [plain English summary]

---ACTION-REQUEST---
{
  "action_type": "[action-type]",
  "approval_tier": [1-3],
  "customer_email": "[email from session or provided]",
  "customer_profile_id": "[if known from profile_lookup]",
  "customer_workspace_id": "[if known from session context]",
  "details": {
    "[action-specific fields]"
  },
  "conversation_summary": "[2-3 sentence summary of the conversation]",
  "cs_session_id": "[session identifier for audit]"
}
---END-ACTION-REQUEST---
```

## Action Types and Tiers

| Action Type | Tier | SLA | Examples |
|-------------|------|-----|---------|
| `credit-claim` | 1 | 2 business days | "I produced this track, add my credit" |
| `credit-correction` | 1 | 2 business days | "My role is listed wrong" |
| `profile-claim` | 1 | 2 business days | "I want to claim this profile" |
| `support-general` | 1 | 2 business days | General questions needing ops follow-up |
| `profile-merge` | 2 | 5 business days | "I have two profiles, combine them" (require `main_profile_url` and `duplicate_profile_urls[]` in `details` – no self-service merge UI exists, so URLs are the only way ops can act) |
| `bulk-credit-change` | 2 | 5 business days | "Update credits on multiple tracks" |
| `profile-update` | 2 | 5 business days | "Change my profile name/details" |
| `subscription-refund` | 3 | 5-10 business days | "I want a refund" |
| `data-deletion` | 3 | 10 business days | "Delete my account and data" |
| `dispute` | 3 | 10 business days | "I dispute this credit claim" |
| `data-export` | 3 | 10 business days | "Export all my data" |

### Profile-Merge Required Fields (HARD GATE)

The `create_ticket` tool will **refuse** any `profile-merge` AR that's missing any of:
- `customerProfileId` — the profile the customer wants to keep
- `details.main_profile_url` — full `https://credits.muso.ai/profile/<uuid>` URL
- `details.duplicate_profile_urls` — non-empty array of full URLs for every profile to merge in

The 2026-05-19 backlog audit found 2 of 27 (~7%) profile-merge tickets had null `customer_profile_id` and 15 of 27 (~56%) of open tickets had been silently merged but not closed — partly because ops can't act without these fields. Before emitting:

1. Resolve the customer's main profile (via `profile_lookup` / `profile_status`) and capture its UUID.
2. Read ALL duplicate-profile URLs the customer mentioned in the conversation. If they only gave names, ask:
   > "Could you share the full Muso profile URLs for both the profile you want to keep and the one(s) you'd like merged in? They look like `https://credits.muso.ai/profile/<uuid>`."
3. Only call `create_ticket` once you have all three. If the tool returns `{submitted: false, reason: "profile_merge_capture_incomplete"}`, that's your cue — ask the customer for whatever's in `missing[]` and retry.

Example `details` block:

```json
"details": {
  "main_profile_url": "https://credits.muso.ai/profile/54a99ccc-8313-42e3-9056-d6f8cc54133a",
  "duplicate_profile_urls": [
    "https://credits.muso.ai/profile/46ac72f3-231c-4e07-8f43-3b553c9ea192"
  ]
}
```

### Retention Context (subscription-refund only)

For `subscription-refund` action requests ONLY, add a `retention_context` field to the JSON block (after `details`):

```
"retention_context": {
  "retention_attempted": true,
  "reason_category": "[not-using-it|too-expensive|missing-feature|billing-issue|other]",
  "reason_detail": "[1-2 sentence summary]",
  "gates_completed": [1-3],
  "exchange_count": [number],
  "outcome": "[refund_requested|refund_requested_skipped_gates]"
}
```

**Do NOT include `retention_context` for any other action type.**

This tells Operations:
- **reason_category**: Why the customer wants a refund
- **reason_detail**: Specific details from the conversation
- **gates_completed**: How many retention gates were completed (1-3)
- **exchange_count**: Total back-and-forth pairs in the retention conversation
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
- 2 action request tickets per session (60-minute window)

## Customer Communication Templates

Read `create_ticket`'s JSON response and choose the template:

### Submitted (`submitted: true`)

Use `ticket_id` as the reference and `sla` verbatim from the response:

**Tier 1:** "I've flagged your request for our team. You'll hear back within `<sla>`. Your reference is `<ticket_id>`."

**Tier 2:** "I've escalated your request to our operations team. This type of request requires manual review – you'll hear back within `<sla>`. Your reference is `<ticket_id>`."

**Tier 3:** "I've passed your request to our senior team for review. You can expect a response within `<sla>`. Your reference is `<ticket_id>`."

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

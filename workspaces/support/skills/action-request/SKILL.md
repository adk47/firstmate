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
4. CS agent tells the customer: "I've submitted your request. Our team will review it within [SLA]."
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
| `credit-claim` | 1 | 48 hours | "I produced this track, add my credit" |
| `credit-correction` | 1 | 48 hours | "My role is listed wrong" |
| `profile-claim` | 1 | 48 hours | "I want to claim this profile" |
| `support-general` | 1 | 48 hours | General questions needing ops follow-up |
| `profile-merge` | 2 | 5 business days | "I have two profiles, combine them" |
| `bulk-credit-change` | 2 | 5 business days | "Update credits on multiple tracks" |
| `profile-update` | 2 | 5 business days | "Change my profile name/details" |
| `subscription-refund` | 3 | 5-10 business days | "I want a refund" |
| `data-deletion` | 3 | 10 business days | "Delete my account and data" |
| `dispute` | 3 | 10 business days | "I dispute this credit claim" |
| `data-export` | 3 | 10 business days | "Export all my data" |

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
| Action type maps to Tier 1 | Create ticket, tell customer "48 hours" |
| Action type maps to Tier 2 | Create ticket with priority:high, tell customer "5 business days" |
| Action type maps to Tier 3 | Create ticket with priority:urgent, tell customer "our leadership team will review" |
| Customer has already submitted 2 action requests this session | Decline further: "I've submitted your requests. Our team will follow up on all of them." |
| Customer has submitted 3+ action requests this hour | Decline: "You've submitted several requests recently. Please allow our team time to process them." |
| Unclear action type | Ask clarifying question before creating ticket |

## Rate Limits
- 2 action request tickets per session (60-minute window)

## Customer Communication Templates

### Tier 1 (Auto-queue)
"I've submitted your [action] request. Our team will review it within 48 hours. You'll receive an update at [email]. Your reference number is [ticket ID]."

### Tier 2 (Human-in-loop)
"I've escalated your [action] request to our operations team. This type of request requires manual review and typically takes up to 5 business days. Your reference number is [ticket ID]."

### Tier 3 (Leadership)
"I've submitted your [action] request for leadership review. Given the nature of this request, our senior team will review it personally. You can expect a response within 5-10 business days. Your reference number is [ticket ID]."

## Data NOT Included in Tickets
- Other customers' data
- Internal system details
- Agent configuration or capabilities
- Other ticket details or queue position
- Internal team names or individual reviewers

## Error Handling
- ClickUp API error: "I wasn't able to create a ticket right now. Please email support@muso.ai directly with your request."
- Rate limited: "You've submitted several requests. Our team will process them. For additional requests, please email support@muso.ai."

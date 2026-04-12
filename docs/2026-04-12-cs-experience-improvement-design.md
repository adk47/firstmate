# CS Experience Improvement -- Design Spec

**Date**: 2026-04-12
**Author**: Nick + Claude
**Status**: Draft
**Triggered by**: Aaron's feedback on Intercom chat support quality (2026-04-11)

## Problem

Aaron tested the Intercom support chat and reported:
- Wrong contact name displayed (serhii@muso.ai instead of the expected support identity)
- Overall experience described as "horrible from the very first screen forward"
- Core issue is AI response quality, not the Intercom widget UX

## Scope

Four improvement areas, all in-scope:

1. **Model upgrade** -- GLM-5 to GLM-5.1
2. **SOUL.md & prompting** -- sharper personality, better response patterns, reduced ticket-bouncing
3. **Knowledge base enrichment** -- troubleshooting flows, empirical data from real conversations
4. **Bot identity fix** -- dedicated Caroline admin in Intercom

## Out of Scope

- Intercom Messenger widget UI/appearance changes
- Implementing the `subscription_status` tool (stub remains, mitigated with self-service guidance)
- Dynamic admin mapping (ADR-024 Decision 5 -- deferred until support team > 3)

---

## 1. Model Upgrade

**Change**: Swap GLM-5 to GLM-5.1 as the primary model for the support agent.

**Config** (`openclaw-main.json`, support agent section):
```
Primary:   fireworks/accounts/fireworks/models/glm-5.1
Fallback1: fireworks/accounts/fireworks/models/deepseek-v3p2
Fallback2: anthropic/claude-haiku-4-5-20251001
```

**Rationale**: GLM-5.1 has reasoning capabilities and better instruction-following than GLM-5. Already proven on the operations agent. CS volume is low enough that the cost delta is negligible.

**SOUL.md updates**:
- Update Identity section model reference
- Update Model Tier Selection table

---

## 2. SOUL.md & Prompting Improvements

### 2A. Reduce ticket-bouncing

Current behavior: anything outside 4 tools -> "let me create a ticket." This is the wrong default when the answer exists in the knowledge base.

New escalation ladder:
1. Answer from reference docs if covered
2. Give self-service guidance if possible (e.g., "go to Settings > Billing")
3. Create a ticket only when a human action is genuinely required (refund, data fix, account recovery)

Update the Scope Enforcement and Escalation Protocol sections to reflect this hierarchy.

### 2B. Response pattern guidance

Add explicit guidance for common scenarios:

- **Greeting handling**: When customer opens with vague "hi" or "I need help", ask one focused question. Do not dump capabilities.
- **Troubleshooting before escalation**: Walk through diagnostic steps before creating tickets. "Have you tried X? If that doesn't work, try Y."
- **Subscription questions**: Since `subscription_status` is a stub, guide to self-service ("Check Settings > Billing") instead of immediately creating a ticket.

### 2C. Tone calibration for GLM-5.1

- Add 2-3 few-shot example responses showing ideal tone and length:
  1. Simple FAQ answer (1-2 sentences, direct)
  2. Troubleshooting walkthrough (step-by-step, conversational)
  3. Graceful escalation to ticket (empathetic, clear next steps)
- Specify response length targets: 1-3 sentences for simple answers, max 1 short paragraph for complex ones
- Add "never do" list: never start with "Great question!", never apologize more than once per conversation, never use bullet lists for simple answers, never use emojis

---

## 3. Knowledge Base Enrichment

### 3A. Empirical data analysis (prerequisite)

Before writing new content, pull real conversation data:

1. Use Intercom API to fetch ~20k conversations from before 2026-03-01 (pre-Caroline era, real human CS data)
2. Categorize each conversation: topic, resolution path, escalation reason
3. Extract the top question categories by frequency
4. Identify the top 10 failure modes and most common customer frustration patterns
5. Validate existing FAQ coverage against actual questions asked

Findings will directly inform sections 3B-3D.

### 3B. Troubleshooting flows in `faq.md`

Replace one-line "create a support ticket" answers with step-by-step resolution paths for common issues. Examples (to be validated against real data):
- Profile discovery issues
- Credit correction guidance (Muso-sourced vs external-sourced)
- Analytics visibility problems
- Login/access issues

### 3C. New `reference/common-issues.md`

Dedicated troubleshooting reference with decision trees for the top 10 support scenarios (up to 15 if data warrants it) identified from conversation data. Gives Caroline structured resolution paths.

### 3D. Enhanced `subscriptions-and-billing.md`

Add self-service instructions for common subscription actions:
- Upgrade/downgrade flow
- Cancellation flow
- Payment method update
- Renewal date check
- Subscription expiration behavior

This compensates for the `subscription_status` tool stub.

---

## 4. Bot Identity Fix

### 4A. Current admin mapping (verified via API)

| ID | Name | Email | Notes |
|----|------|-------|-------|
| 4359478 | Operator | operator+dwjzhcge@intercom.io | Current `botAdminId` -- Intercom built-in operator |
| 5201828 | Aaron Kaufman | aaron@muso.ai | |
| 5465657 | Jan Delmo | jandelmo89@gmail.com | Also used as `defaultInboxId` |
| 5733748 | Serhii Ostaphchuk | serhii@muso.ai | |
| 5763097 | Muso Operations | operations@muso.ai | Possible reuse candidate |
| 7057669 | Admin | services-admin@muso.ai | |

Bot currently replies as "Operator" (4359478). Aaron may have seen Serhii's name due to assignment routing rather than the reply itself.

### 4B. Create dedicated Intercom admin (manual step)

- Create a new admin in Intercom workspace `dwjzhcge` with:
  - Name: "Caroline"
  - Avatar: appropriate support bot image
  - Email: caroline@muso.ai or support@muso.ai (requires a valid domain alias)
- Record the new admin ID
- Alternative: rename the existing "Operator" (4359478) to "Caroline" if Intercom allows it -- avoids creating a new seat

### 4C. Update config

- Update `openclaw-main.json`: `"botAdminId": "<new-caroline-admin-id>"`
- This is a one-line config change once the admin ID is known

---

## Implementation Order

1. **Empirical data pull** -- Intercom API conversation analysis (informs everything else)
2. **Bot identity** -- create admin, update config (quick win, independent)
3. **Knowledge base** -- rewrite based on real data
4. **SOUL.md** -- update prompting with new patterns and model reference
5. **Model upgrade** -- swap to GLM-5.1 (config change, do last so KB and prompt are ready)
6. **Testing** -- test the full flow end-to-end via Intercom

## Rollback

If GLM-5.1 performs worse than GLM-5 in production, rollback is a single config line change in `openclaw-main.json` (swap primary back to `glm-5`). SOUL.md and KB changes are model-agnostic and don't need to be reverted.

## API Access (verified)

- Intercom API token has conversation read access (confirmed 2026-04-12)
- 202,662 total conversations available for analysis
- Admin list endpoint works -- all admin IDs mapped above

## Success Criteria

- Replies show "Caroline" as the contact, not "Operator" or serhii@muso.ai
- Caroline resolves common questions without creating tickets (measured by ticket creation rate before/after)
- Response tone is natural, concise, and helpful (qualitative review by Aaron)
- No regressions in security posture (honeypot, canary detection, etc.)

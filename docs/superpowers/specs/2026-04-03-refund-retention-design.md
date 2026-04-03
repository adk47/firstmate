# Refund Retention Gates + Caroline Smith Identity

**Date:** 2026-04-03
**Branch:** feat/refund-gates
**Status:** Approved

---

## Problem

The CS agent immediately creates a Tier-3 refund ticket when a customer requests a refund. There are zero gates — no attempt to understand the problem or help the user before escalating. Aaron observed a user who "doesn't know how to use Muso" and had "no credits" requesting a refund. We're making it too easy to churn.

## Goals

1. Add 3 gated steps before a refund ticket is created — diagnose, help, offer alternatives
2. Give the CS agent the identity "Caroline Smith" so it doesn't introduce itself as "Muso's CS agent"
3. Log retention context in action-request tickets so Operations has churn intelligence

## Non-Goals

- Changing the action-request skill format (only adding a retention-context block)
- Changing the Operations refund investigation or processor flows
- Adding subscription pause or discount capabilities (not currently available)

---

## Change 1: Identity — Caroline Smith (SOUL.md)

### Name and Introduction

- **Name:** Caroline Smith
- **Introduction:** "Hey! I'm Caroline -- I'm here to help with anything Muso. Profiles, credits, subscriptions, whatever you need."
- **Identity response:** If asked "who are you?" → "I'm Caroline -- I'm an AI assistant on the Muso support team."
- Honest about being AI if asked, but doesn't volunteer it unprompted
- Never says "CS agent", "customer service bot", or "Muso's AI agent"

### Honeypot Update

Update the canned honeypot response to use first person naturally:
> "I can help with profiles, credits, subscriptions, and getting tickets to the right people. What do you need?"

(No change to the honeypot detection logic itself.)

---

## Change 2: Refund Retention Skill

**Location:** `workspaces/support/skills/refund-retention/SKILL.md`

### Trigger

Caroline detects a refund request (keywords: refund, money back, cancel and get money, charged wrongly, want my money back, etc.).

### Gate 1 — Diagnose

Ask what's not working. Categorize into: `not-using-it`, `too-expensive`, `missing-feature`, `billing-issue`, `other`.

Example tone:
> "I totally get it — before I send this over to the team, do you mind if I ask what's not working for you? Sometimes I can sort things out right here."

Exit always visible:
> "Of course, if you'd rather just go ahead with the refund request, I can do that too."

### Gate 2 — Help (reason-matched)

| Reason | Action |
|--------|--------|
| `not-using-it` | Use `profile_lookup` / `credits_search` to show the user their own profile and credits data. Explain conceptually what analytics, audits, and milestones offer — but be clear Caroline can only pull profile and credits info live. She cannot demo analytics dashboards or audit results directly. |
| `too-expensive` | Mention Lite (free) keeps credits + profile, loses analytics/audits/milestones. Reference `products-and-pricing.md` and `subscriptions-and-billing.md` for accurate plan details. Ask if downgrade would work. |
| `missing-feature` | Acknowledge, note what they need, explain it'll be flagged in the ticket. |
| `billing-issue` | Use `subscription_status` to diagnose (wrong charge, double charge, inactive sub). Caroline can identify billing problems but **cannot fix them** — if a billing error is confirmed, escalate as a `billing-issue` action-request ticket (not a refund ticket). |
| `other` | Listen, empathize, try to help with whatever it is. |

### Gate 3 — Last Alternative

If user still wants out after Gate 2:
> "Totally understand. Just so you know, you can also switch to Lite for free — you'd keep all your credits and profile, just lose the analytics side. If you'd rather go with the refund, I'll get that over to the team right now."

If they confirm refund → proceed to `action-request` skill (Tier 3 ticket).

### Rules

- **Max 3 gates** — if the user says "just give me the refund" at any point, skip remaining gates and create the ticket immediately
- **Never** guilt-trip, block, argue, or pressure
- **Tone** stays chill and helpful throughout — natural conversation, not a script
- Entire flow should complete in under 5 back-and-forth pairs (1 pair = 1 Caroline message + 1 user response). With 3 gates that's 3-4 pairs minimum, leaving 1-2 pairs of slack.

---

## Change 3: Retention Context in Action-Request Tickets

When `refund-retention` completes and the user still wants a refund, the action-request ticket body gains a `retention-context` block inside the `---ACTION-REQUEST---` markers:

```
retention_attempted: true
reason_category: not-using-it
reason_detail: "User didn't know how to view analytics for their profile"
gates_completed: 3
exchange_count: 4
outcome: refund_requested
```

This gives Jan/Operations context on why the user still wants out, and confirms Caroline tried to help.

---

## Flow Diagram

```
Customer says "I want a refund"
        |
  refund-retention skill activates
        |
  Gate 1: Diagnose (ask what's wrong)
        |
  Gate 2: Help (reason-matched intervention)
        |
  Gate 3: Offer alternative (Lite downgrade)
        |
  User still wants refund?
        |--- no ---> retained, conversation continues normally
        |--- yes --> action-request skill (unchanged)
                        |
                  Tier 3 ticket created (with retention-context)
                        |
                  Operations picks up ticket
```

## Files Changed

| File | Change |
|------|--------|
| `workspaces/support/SOUL.md` | Name → Caroline Smith, updated intro + honeypot response |
| `workspaces/support/skills/refund-retention/SKILL.md` | New file — 3-gate retention flow |
| `workspaces/support/skills/action-request/SKILL.md` | Add retention-context block to refund ticket format |

## Expected Impact

Industry benchmarks suggest a 3-gate retention flow saves 15-25% of refund requests. The "not-using-it" segment (which matches the observed user behavior) has the highest save rate at 20-30% when paired with hands-on product education.

---
name: muso-winback-engine
description: |
  Orchestrator and system architecture for the Muso churned Pro win back engine.
  Routes win back requests to the right specialized subskill and holds shared
  config for every muso-winback-* skill (sheet IDs, GHL IDs, channel, voice).

  Completely separate from B2B Ads outreach. Different audience, different
  sheet, different GHL location, different API key.

  Use when: ANY churned Pro win back related request, to route to the right
  subskill, or when you need to understand the full win back system architecture.

  Triggers: "winback", "win back", "win-back", "churned pro", "churn recovery",
  "re-engage churned", "high-value churns", "reactivation"
depends-on:
  - muso-winback-writer
  - muso-winback-sender
  - muso-winback-followup
  - muso-winback-reply-scanner
  - muso-winback-ghl-sync
  - muso-winback-reporter
  - muso-winback-qa
  - muso-slack-formatter
metadata:
  version: "2.0"
  last-updated: "2026-04-09"
---

<!-- WORKSPACE-DIVERGENCE: newer-than-canonical orchestrator architecture (v2.0); depends on workspace-only muso-winback-* subskills not present in skills-all/. Backport/converge tracked separately. -->

# Muso Win Back Engine (Orchestrator)

Entry point for all churned Pro win back work. This skill does not do the work
itself. It routes requests to the right subskill and holds the shared config
(`references/config.md`) that every subskill reads from.

## Critical Distinction: NOT B2B Ads Outreach

This engine is completely separate from `muso-outreach-*`.

| | Win Back (THIS engine) | B2B Ads Outreach |
|---|---|---|
| Audience | Individual Pro users who cancelled | Companies that never had Muso |
| Intelligence store | Sheet `1_gltz...` (high_value_churn + pro_churned_all) | NocoDB B2B-Ads Intelligence (Contacts `m9vsbijhrr9ddeu` + Company `mvr6nmzcv7albxt`) |
| GHL Location | `fmK5Vl9sJv49WTYA0QyP` (Muso Win Back) | `S5w31kRRgsBjjiVATWlP` (B2B Ads) |
| GHL API Key | `$GHL_WINBACK_API_KEY` | `$GHL_API_KEY` |
| Pipeline | `Churn -> Win-back` (`AZa8jK5S7UyQ0fqfxzyB`) | `B2B-Ads-Clio` (`GeSt85TueSvJ0SNFZXfQ`) |
| Email style | Personal Aaron, 150 to 350 chars, no CTA pitch | Private Invite, 80 to 120 words |
| Slack channel | `#win-back-alerts` (`C0ARTH6U0S2`) | `#sales-alerts` (`C0ARQ021M40`) |
| Gmail label | `Win-Back` | `B2B - Ads` |
| Cadence | Day 0, Day 7, Day 45, Day 90 (Lost) | Day 0, Day 7, Day 14, Day 140 |

**Never mix the two.** Wrong API key on the wrong location, wrong sheet on the
wrong audience, wrong notification channel. The QA skill catches drift.

## Access Control

Write access (send emails, update sheets, modify GHL): **Aaron (U7RP6HKUZ)** and
**Nick (U0AL36NADEY)** only. Everyone else is read only.

## Subskill Map

| Request | Route To | What It Does |
|---------|----------|--------------|
| "Send win back batch" | `muso-winback-sender` | Pull tier, draft, present, send, sheet+GHL sync |
| "Draft a winback email" | `muso-winback-writer` | Copy craft per user type, template selection |
| "Send follow ups" | `muso-winback-followup` | Day 7, Day 45 cadence, mark Lost at Day 90 |
| "Check for replies" | `muso-winback-reply-scanner` | 3x daily Gmail scan, classify, GHL move |
| "Sync sheet to GHL" | `muso-winback-ghl-sync` | Bidirectional state reconciliation |
| "Win back report" | `muso-winback-reporter` | Daily, weekly, batch reports |
| "Audit win back" | `muso-winback-qa` | Validates sheet, GHL, Stripe, em dashes, drift |

## Shared Config

All subskills read from `references/config.md`. Never hardcode sheet IDs, GHL
IDs, channels, accounts, or stage IDs in a subskill.

Config covers:
- Win back master sheet (`1_gltz...`) and tabs (`pro_churned_all`, `high_value_churn`)
- GHL location, pipeline, API key env var, and stage info
- Stripe pre send check
- 4 Muso email accounts and voice
- `#win-back-alerts` channel
- Cadence (Day 0, 7, 45, 90 Lost)
- Volume and pacing (120/day, 40 per email account, timezone batched)
- Coupon codes (TBD)
- DNS deliverability requirements
- API log destinations

## Architecture Overview

```
                  ┌──────────────────────────┐
                  │  muso-winback-engine     │
                  │      (orchestrator)      │
                  └────────────┬─────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
  ┌─────▼──────┐        ┌──────▼──────┐        ┌──────▼──────┐
  │   WRITER   │        │   SENDER    │        │  FOLLOWUP   │
  │  Voice +   │        │  Pull tier, │        │  Day 7, 45, │
  │  templates │        │  draft,     │        │  90 = Lost  │
  │  per user  │        │  send, log  │        │             │
  │  type      │        │             │        │             │
  └────────────┘        └─────────────┘        └─────────────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  REPLY SCANNER      │
                    │  3x daily Gmail     │
                    │  classify + move    │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │     GHL SYNC        │
                    │ Sheet <-> GHL +     │
                    │ Stripe verify       │
                    └──────────┬──────────┘
                               │
                  ┌────────────┴────────────┐
                  │                         │
            ┌─────▼──────┐           ┌──────▼──────┐
            │  REPORTER  │           │     QA      │
            │  daily/wk  │           │  daily audit│
            └────────────┘           └─────────────┘
```

## Data Flow

1. **High value churned users imported to GHL** (~1080 contacts at `Churned` stage)
2. **Sheet `high_value_churn` is the source of truth** for who is in scope
3. **Sender** picks a tier batch, calls **Writer** for copy, presents to Nick/Aaron
4. **On approval, Sender** runs the Pre Send Stripe Check, then sends, applies label, updates sheet, calls **GHL Sync** to move stage
5. **Reply Scanner** runs 3x daily, detects inbound, calls **GHL Sync** to move stage
6. **Followup** runs on cadence (Day 7, Day 45), uses **Writer** + **Sender** for the send
7. **GHL Sync** also runs daily reconciliation across all sources
8. **Reporter** reads logs and writes daily summaries
9. **QA** audits everything daily

## Hard Rules (apply to every subskill)

- **Pre Send Stripe Check is MANDATORY** before every email (initial, follow up, reply). Skip if user has active subscription.
- Never use em dash (—) in any email or output
- Never send without explicit Aaron or Nick approval
- Never send on Saturday or Sunday
- Never send outside 8 AM to 6 PM CST window
- Never send more than 3 emails to one person (initial + 2 follow ups)
- Never argue with someone who says no
- Never reply instantly (use response timing delays)
- Never mix B2B Ads API key or sheet or pipeline (use win back resources only)
- Never CC + BCC (triggers phishing detectors). CC `support@muso.ai` only.
- Always reference public profile data (credits, roles, popularity) in copy
- Always check Gmail before sending to avoid double contact
- Always update sheet after every action
- Always sync GHL stage after every state change
- Always log every action to `api-logs/`
- Always present drafts for approval before sending
- Always post notifications to `#win-back-alerts`

## References

- `references/config.md`, shared config for ALL win back subskills
- `references/pipeline-stages.md`, GHL stage IDs
- `references/user-types.md`, 6 user type classification rules
- `references/product-knowledge.md`, what Pro unlocks (for accurate copy)
- `../muso-winback-writer/references/email-templates.md`, full template library

## Outstanding Items (TBD before launch)

- [ ] **Coupon codes**: Nick to provide current codes (old `LITE10`, `LITE20A` may be deprecated)
- [ ] **Hive strategy**: Nick will explain how to route across the 4 Muso email accounts (a@, ak@, aaron.k@, f@)
- [ ] **Email account warming**: ak@, aaron.k@, f@ need to be warmed before full volume
- [ ] **DNS verification**: confirm DKIM, SPF, DMARC are valid
- [ ] **Stage ID verification**: re fetch GHL stage IDs to confirm they have not changed
- [ ] **First batch QA**: dry run a batch of 5 to 10 to validate the full flow before going live

## Legacy Files

The previous `muso-winback-pro` skill had Python and bash scripts in
`scripts/`. These have been preserved in `muso-winback-engine/legacy-scripts/`
for reference. They are NOT part of the current production flow and need
review before use. The new subskills do not depend on them.

## History

- 2026-04-09: orchestrator created during win back rebuild. Old `muso-winback-engine` and `muso-winback-pro` consolidated into 8 subskills with shared config. Lite-to-Pro track dropped. Cadence changed from 7/14/21 to 7/45/90.

---
title: Win Back Engine (Churned Pro)
description: High level overview of the churned Pro win back engine
type: workflow
status: active
source: muso-winback-engine SKILL.md and subskills
last-verified: 2026-04-09
related: [[company/muso-ai]], [[lessons/outreach-failures]], [[people/aaron]]
---

# Win Back Engine (Churned Pro)

## What It Is

End to end win back engine for churned Muso Pro subscribers. Sends personalized
emails from Aaron's account, monitors replies, runs Stripe re subscription checks
on every send, manages a multi touch follow up cadence, and stops cleanly when
a user converts, declines, or goes silent.

**Completely separate from the B2B Ads outreach engine.** Different audience,
different sheet, different GHL location, different API key.

## Architecture

8 specialized subskills under the `muso-winback-*` namespace.

| Subskill | Job |
|----------|-----|
| `muso-winback-engine` | Orchestrator, routing, shared config |
| `muso-winback-writer` | Copy craft, voice, template selection per user type |
| `muso-winback-sender` | Pull tier, draft, present, send, log |
| `muso-winback-followup` | Day 7 / Day 45 / Day 90 cadence |
| `muso-winback-reply-scanner` | Scan all 4 Muso accounts 3x daily |
| `muso-winback-ghl-sync` | Single point of GHL writes (Win Back location) |
| `muso-winback-reporter` | Daily and weekly reports |
| `muso-winback-qa` | Daily audits, drift detection, em dash sweeps |

## Sources of Truth

1. **Win Back Master Sheet** (`1_gltz...`):
   - Tab `pro_churned_all` (gid=280335637), all churned Pro users
   - Tab `high_value_churn` (gid=638190710), ~1080 high value subset imported to GHL
2. **GHL Win Back Pipeline** (`Churn -> Win-back`, `AZa8jK5S7UyQ0fqfxzyB`) at location `fmK5Vl9sJv49WTYA0QyP`
3. **Gmail** across all 4 Muso accounts with `Win-Back` label
4. **Stripe** for re subscription detection (mandatory pre send check)

## Pipeline Stages (7)

Churned → Next Up → Emailed → Follow-up → Replied → Re-subscribed (won) / Lost / No Answer

## Cadence (Day 0, 7, 45, 90)

| Touch | Days After Initial | Action |
|-------|--------------------|--------|
| Initial | 0 | First email |
| Follow up 1 | 7 | Day 7 nudge |
| Follow up 2 | 45 | Day 45 fresh angle |
| Lost | 90 | Mark `Lost / No Answer` |

Stop after 2 follow ups with no reply. Never send weekends.

## Voice

All win back emails are in Aaron Kaufman's voice (founder writing personally to
a creator). Sent from `a@muso.ai` by default. Multi email hive (a@, ak@, aaron.k@,
f@) is planned but not yet wired.

## Key Differences vs B2B Ads Outreach

| | Win Back | B2B Ads |
|---|---|---|
| Audience | Individual churned Pro users | Companies that never had Muso |
| GHL Location | `fmK5Vl9sJv49WTYA0QyP` | `S5w31kRRgsBjjiVATWlP` |
| GHL API key | `$GHL_WINBACK_API_KEY` | `$GHL_API_KEY` |
| Slack channel | `#win-back-alerts` | `#sales-alerts` |
| Gmail label | `Win-Back` | `B2B - Ads` |
| Email length | 150 to 350 chars | 80 to 120 words |
| Cadence | 0, 7, 45, 90 (Lost) | 0, 7, 14, 140 |
| CC | `support@muso.ai` always | none |
| Pre send check | Stripe (mandatory) | none |

**Never mix the two.** The QA skill catches drift.

## Hard Rules

- Pre Send Stripe Check is MANDATORY before every email
- Never use em dash in any output (see [[decisions/2026-04-em-dash-prohibited]])
- Never send on Saturday or Sunday
- Never send outside 8 AM to 6 PM CST
- Never send more than 3 emails total per contact (initial + 2 follow ups)
- Never argue with a declined user
- Never reply instantly (use timing delays)
- Never mix B2B Ads API key, location, or pipeline
- Never CC + BCC together (CC `support@muso.ai` only)
- Always reference public profile data only (not clickstream)

## Outstanding Items (TBD before launch)

- Coupon codes (Fede to provide; old `LITE10` and `LITE20A` may be deprecated)
- Hive strategy (Fede will explain how to route across the 4 emails)
- Email account warming (`ak@`, `aaron.k@`, `f@` need warming)
- DNS deliverability verification (DKIM, SPF, DMARC)
- GHL stage ID re verification
- First batch dry run

## Where the Skill Files Live

- `skills/muso-winback-engine/SKILL.md`, the orchestrator
- `skills/muso-winback-engine/references/config.md`, shared config
- `skills/muso-winback-engine/references/pipeline-stages.md`, GHL stage IDs
- `skills/muso-winback-engine/references/user-types.md`, 6 user type rules
- `skills/muso-winback-engine/references/product-knowledge.md`, what Pro unlocks
- `skills/muso-winback-engine/legacy-scripts/`, old scripts preserved for reference (review before use)
- `skills/muso-winback-writer/SKILL.md`, copy craft
- `skills/muso-winback-writer/references/email-templates.md`, full template library
- `skills/muso-winback-{sender,followup,reply-scanner,ghl-sync,reporter,qa}/SKILL.md`

## Status

Campaigns have NEVER actually launched. ~1080 high value pro users were imported
to GHL. The engine was being set up when the previous CMO config drifted. The
2026-04-09 rebuild brings the engine to a state where it can be wire tested via
STARTUP.md and then launched.

## History

- 2026-04-09: rebuilt from monolithic `muso-winback-engine` and `muso-winback-pro` into 8 subskills with shared config. Cadence changed to 7/45/90. Lite-to-Pro track dropped. API key moved to env var. CC only (BCC removed).

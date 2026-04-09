---
title: Win Back Engine Rebuild
description: Rebuild of the churned Pro win back engine, April 2026
type: decision
status: active
source: conversation with Fede 2026-04-09
last-verified: 2026-04-09
related: [[workflows/winback-engine]], [[decisions/2026-04-cmo-rebuild]]
---

# Decision: Win Back Engine Rebuild

**Date**: 2026-04-09
**Decided by**: Fede
**Status**: In progress (campaigns never actually launched)

## Background

The previous CMO config had two overlapping win back skills:
1. `muso-winback-engine` (newer, broader, with Lite Upgrade track)
2. `muso-winback-pro` (older, more operational, with scripts)

Neither launched. Fede had imported ~1080 high value churned Pro users to the
GHL Win Back location but never sent the campaigns. The skills had drifted from
the original Clio era setup and needed rebuild.

## Changes Made

### Architectural

- **Split into 8 subskills** following the same pattern as the rebuilt outreach engine
- **Single shared config file** at `muso-winback-engine/references/config.md`
- **Old scripts preserved** in `muso-winback-engine/legacy-scripts/` with a README explaining their status

### Configuration

- **Cadence changed**: was 7d / 14d / 21d, now 7d / 45d / 90d (90 = Lost)
- **API key moved to env var**: was hardcoded `pit-239a5db4-6ba1-4b6e-857d-0f8cc4464410`, now `$GHL_WINBACK_API_KEY` (separate from `$GHL_API_KEY` to prevent confusion with B2B Ads)
- **Channel migrated**: was `#clio_x_fede` and `#clio_analyst`, now `#win-back-alerts` (`C0ARTH6U0S2`)
- **CC only**: was CC `support@muso.ai` AND BCC `aaron@muso.ai`, now CC only (BCC removed because CC + BCC together triggers phishing detectors)
- **Sheet structure updated**: tabs `pro_churned_all` and `high_value_churn` (with the latter being the ~1080 imported set)

### Scope

- **Lite-to-Pro track dropped**: the second campaign in the old `muso-winback-engine` (upgrading high value Lite users to Pro) was removed. Fede did not recognize it during the rebuild conversation, and there was no evidence it was ever launched. Can be re added later as a separate engine if needed.
- **Multi language support kept**: 7 supported languages (English, French, Italian, Dutch, Spanish, Portuguese, German)
- **6 user type detection kept**: with refinement that pre assigned `email_template` in the sheet overrides auto detection

### Copy

- **All em dashes stripped** from templates and skill documentation
- **Coupon codes removed** pending Fede's new codes (old `LITE10` and `LITE20A` may be deprecated)
- **Day 45 follow up template added** (`FOLLOWUP_DAY_45`) for the new cadence

### Hive

- **4 Muso email accounts documented**: `a@`, `ak@`, `aaron.k@`, `f@`
- **Default sender**: `a@muso.ai` for now
- **Hive routing**: planned, requires email engine spec (separate work)
- **Warming protocol**: documented for `ak@`, `aaron.k@`, `f@` before full volume

### Quality

- **`muso-winback-qa` skill added**: daily audit covering config integrity, GHL stage IDs, sheet to GHL drift, Pre Send Stripe Check compliance, em dash sweeps, volume caps, cadence sanity, CC/BCC, DNS deliverability, hive balance

## Outstanding (Before Launch)

- [ ] Fede provides current coupon codes
- [ ] Fede explains hive strategy
- [ ] Email warming for `ak@`, `aaron.k@`, `f@`
- [ ] DKIM, SPF, DMARC verification
- [ ] GHL stage ID re fetch (verify they have not changed)
- [ ] First batch dry run on 5 to 10 contacts
- [ ] STARTUP.md Phase to be added for win back wire up

## What Fede Said

> campaigns never actually launched, we have some contacts imported on ghl but never actually launched, i was still setting this up
>
> first send then follow up Day 7 first follow-up, Day 45 second, Day 90 = lost
>
> Only CC support@muso.ai
>
> 40 per email (but again we need to warm the emails up the @f ak@ and aaron.k@)

## History

- 2026-04-09: rebuild executed during CMO rebuild conversation

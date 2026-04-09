# Win Back User Type Detection

Classify each churned Pro contact into one of 6 user types. The type drives
which email template the writer skill uses.

**Run the classification in order.** First match wins.

## Classification Rules

### Type 1: Has Credits (~83% of population)

**Signal**: `credits_count > 0`

**Sub types** (refine the template selection within Type 1):

- **Songwriter / Producer with high credits** (`credits_count >= 1000`, roles include songwriter or producer)
  → Template: `MLC_ROYALTIES`
- **Engineer / Mixer / Mastering with large catalog** (`credits_count >= 500`, roles include engineer/mixer/mastering)
  → Template: `CATALOG_ANALYTICS`
- **Was active on analytics or audits** (`used_analytics > 0` OR `used_audits > 0`)
  → Template: `WERE_USING_IT`
- **Cancelled for price** (`cancel_reason ~= "too_expensive"` or `"price"`)
  → Template: `PRICE_SENSITIVE`
- **Cancelled for "not using it"** (`cancel_reason ~= "not_using"`)
  → Template: `FEATURE_DISCOVERY`
- **B2B / Organization profile** (`profile_type ~= "organization"` or `"label"`)
  → Template: `TEAM_ROSTER`
- **Default Type 1** (no strong sub signal)
  → Template: `GENERAL_WINBACK`

### Type 2: Roster Tracker (~5%)

**Signal**: `credits_count = 0` AND `used_roster > 0`

User had no personal credits but actively used Roster to track other artists.
Pitch: Discovery and Roster analytics, not personal credits.

→ Template: `ROSTER_TRACKER`

### Type 3: Credit Builder (~2.5%)

**Signal**: `credits_count = 0` AND `submitted_credits > 0`

User was actively building their catalog by submitting credit corrections. Got
stuck mid setup. Lead with help getting set up, not features.

→ Template: `CREDIT_BUILDER`

### Type 4: Power Browser (~4%)

**Signal**: `credits_count = 0` AND (`used_analytics + used_audits + viewed_profiles > 20`) AND `profile_id` exists

Heavy browser/analyzer behavior, has a claimed profile. Help them connect their
catalog so they can see their own data.

→ Template: `POWER_BROWSER`

### Type 5: Needs Help (Onboarding Rescue)

**Signal**: same engagement signals as Type 4 BUT `profile_id = NONE` (no claimed profile)

Got stuck in onboarding. Genuine help offer.

→ Template: `NEEDS_HELP_SETUP`

### Type 6: Tire Kicker (default)

**Signal**: everything else (low engagement, low logins)

Specifically: `credits_count = 0`, `used_analytics + used_audits + viewed_profiles < 5`, `logins_last_90d < 3`

Generic short pitch. Low effort, low expectation.

→ Template: `TIRE_KICKER`

## Pre Assigned Templates Override

The `high_value_churn` sheet has an `email_template` column where Fede may
pre assign a specific template per row. **If `email_template` is set in the
row, use it directly and skip the auto detection above.**

The `psychological_lever` and `winback_strategy` columns provide additional
context for the writer to personalize the hook.

## Why This Matters

Past versions tried to send the same template to everyone. Reply rates were
terrible. Different user types have different reasons to come back. The MLC
royalties pitch lands for songwriters and producers but means nothing to a
roster tracker.

Match the template to the user, not the campaign.

## See Also

- `email-templates.md` (in `muso-winback-writer/references/`) for the actual template copy
- `product-knowledge.md` for what Pro unlocks (so the writer can be accurate)

## History

- 2026-03-21: 6 user types defined in original muso-winback-engine skill
- 2026-04-09: migrated to dedicated reference file during win back rebuild

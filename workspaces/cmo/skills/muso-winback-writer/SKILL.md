---
name: muso-winback-writer
description: |
  Draft personalized win back emails for churned Muso Pro users in Aaron's voice.
  Selects template based on user type detection (or pre assigned template from
  the sheet), personalizes from public profile data, and returns ready to send
  HTML.

  Companion to muso-winback-engine. Handles copy craft only.

  Use when: writing or editing a win back email, drafting follow ups, personalizing
  a template for a specific churned user.

  Triggers: "winback email", "draft winback", "write winback", "winback copy",
  "churned user email"
depends-on:
  - muso-winback-engine
metadata:
  version: "1.0"
  last-updated: "2026-04-09"
---

# Muso Win Back Writer

Copy craft for churned Pro win back. Owns voice, template selection, personalization.
Called by `muso-winback-sender` and `muso-winback-followup` to produce the
actual email body.

## Shared Config

All IDs, accounts, sheets, channels, and rules come from
`../muso-winback-engine/references/config.md`. Never hardcode.

## Voice: Aaron Kaufman

All win back emails are written in Aaron's voice (regardless of which Muso
email account they are sent from in the hive rotation).

- **Personal.** Founder writing to a creator. Not a marketing email.
- **Direct.** No fluff. No "hope this finds you well." No "just reaching out."
- **Confident.** State facts. Reference real things from their profile.
- **Helpful.** Genuine offer of value, not a sales pitch.
- **Short.** 150 to 350 characters body. Shorter is better.
- **Plain.** No images, no tables, no fancy formatting. Plain styled text.

Sign off: just `Aaron` (no title, no company, no footer).

## Hard Rules

- **Em dash (—) PROHIBITED.** Zero tolerance. Use commas, periods, parentheses, or restructure.
- Body 150 to 350 characters (shorter is better)
- 3 paragraphs max
- HTML only. Wrap each paragraph in `<p>...</p>`.
- Hyperlink "Muso" or "Muso.AI" ONCE, first mention only:
  `<a href="https://muso.ai/" style="text-decoration:none;color:inherit">Muso.AI</a>`
- Sign off with just "Aaron"
- Reference PUBLIC profile data only (credits, roles, popularity, profile_name)
- Never reference clickstream / behavioral data (audit views, login counts), that is creepy
- Never use "click here", "verify", "action required", "account inactive" (spam triggers)
- Match the user's language (English, French, Italian, Dutch, Spanish, Portuguese, German)

## Data Sources

This skill reads from the win back master sheet:

- **Sheet ID**: `1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`
- **Tabs**: `pro_churned_all`, `high_value_churn`
- **Account**: `a@muso.ai`

Key columns the writer cares about:
- `email`, `first_name`, `last_name`, `profile_name` (personalization)
- `credits_count`, `popularity`, `roles`, `primary_genre` (hooks)
- `cancel_reason`, `cancel_comment` (psychological lever)
- `Language`, `Country` (multi language)
- `email_template` (pre assigned template if set, overrides auto detection)
- `psychological_lever`, `winback_strategy` (pre assigned hook angle if set)

## Template Selection Logic

### Step 1: Check for Pre Assigned Template

If the row has `email_template` set, use it directly. Skip auto detection.

### Step 2: Auto Detect User Type

If `email_template` is empty, classify by user type per
`../muso-winback-engine/references/user-types.md`. The 6 types:

1. **Has Credits** (`credits_count > 0`), 83% of population
2. **Roster Tracker** (`used_roster > 0`, no credits), 5%
3. **Credit Builder** (`submitted_credits > 0`, no credits), 2.5%
4. **Power Browser** (heavy browsing, claimed profile, no credits), 4%
5. **Needs Help** (heavy browsing, NO claimed profile, no credits)
6. **Tire Kicker** (low engagement, default)

For Type 1, refine further by sub signal:
- High credits + songwriter/producer → `MLC_ROYALTIES`
- High credits + engineer/mixer → `CATALOG_ANALYTICS`
- Was active on features → `WERE_USING_IT`
- Cancelled for price → `PRICE_SENSITIVE`
- Cancelled "not using it" → `FEATURE_DISCOVERY`
- Org / label profile → `TEAM_ROSTER`
- Default Type 1 → `GENERAL_WINBACK`

### Step 3: Personalize

Use the template from `references/email-templates.md`. Substitute variables:

- `{first_name}` from sheet
- `{profile_name}` from sheet
- `{credits_count}` from sheet
- `{roles}` from sheet (e.g., "Engineer, Producer")
- `{popularity}` (only reference indirectly: "one of the larger catalogs")

### Step 4: Apply Psychological Lever (if set)

If the row has `psychological_lever` set, weave it into the hook. Examples:
- "MLC royalties" → lead with the MLC audit angle
- "catalog scale" → lead with credit count
- "platform analytics" → lead with streaming data depth

### Step 5: Multi Language

If `Language` column is set to anything other than English, translate the
template to that language. Maintain Aaron's voice (direct, personal, short).
The greeting and sign off should also match the language.

Supported languages from prior config: English, French, Italian, Dutch,
Spanish, Portuguese, German.

### Step 6: Apply Coupon Code

**TBD.** Coupon codes are not finalized. Until Nick provides current codes,
do NOT include any coupon code in drafts. Flag the gap in the draft preview.

When ready, the upgrade link is `https://app.muso.ai/pricing?plan=pro`.

## Subject Lines

- Initial: `{first_name}, quick question about your {credits_count} credits` (English)
- Follow up: `re: {original_subject}` (threaded reply, not new email)
- Variations per template are in `references/email-templates.md`

## Personalization Checklist

Before handing an email back to sender, verify:

- [ ] First sentence references something real and specific from their profile
- [ ] `credits_count` is mentioned accurately if Type 1
- [ ] No banned phrases ("just reaching out", "hope this finds you well", etc.)
- [ ] No em dash anywhere
- [ ] 150 to 350 characters body
- [ ] HTML wrapped, Muso.AI hyperlinked once
- [ ] Sign off is just "Aaron"
- [ ] No "click here", "verify", "action required" (spam triggers)
- [ ] Language matches recipient's `Language` column
- [ ] If `email_template` was pre assigned, the template name matches

## Inputs / Outputs

**Inputs** (from `muso-winback-sender` or `muso-winback-followup`):
- Row from `high_value_churn` or `pro_churned_all`
- Touch number (initial, FU-01 = Day 7, FU-02 = Day 45)
- Sender account (default `a@muso.ai`, may be `ak@`/`aaron.k@`/`f@` per hive routing)

**Outputs**:
- `subject`: subject line string
- `body_html`: HTML body wrapped in `<p>` tags
- `template_id`: which template was used (e.g., `MLC_ROYALTIES`)
- `language`: which language the email is in
- `checklist_passed`: boolean

## References

- `references/email-templates.md`, full template library
- `../muso-winback-engine/references/user-types.md`, classification rules
- `../muso-winback-engine/references/product-knowledge.md`, what Pro unlocks
- `../muso-winback-engine/references/config.md`, shared config

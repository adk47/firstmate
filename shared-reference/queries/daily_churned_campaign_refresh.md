# Daily Churned Pro Campaign Sheet Refresh

## Sheet
- ID: 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs
- Title: Win-Back Campaign - Churned Pro Users (Enriched)
- Sheet tab name: Win-Back Campaign - Churned Pro Users (Enriched)

## CRITICAL: DO NOT REPLACE THE SHEET
This sheet has manual tracking columns (AI-AN): outreach_status, email_sent_date, email_variant, response_status, notes, stage.
These columns are filled in manually by the team. If you replace/overwrite the sheet, that data is LOST.

## What to do
1. Run the SQL query at `queries/churned_pro_campaign.sql` via Athena (workgroup: clio-agent, region: us-west-2)
2. CRITICAL: Only Pro plans — filter `plan LIKE '%pro%'`. Expected ~8K users, NOT 15K.
3. Download the Athena result CSV from S3
4. Read existing emails from column B of the sheet (use gog sheets get)
5. Compare: find emails in the Athena result that are NOT already in the sheet
6. For each new email, append a row using gog sheets append (batch if possible)
7. Post update to #clio_analyst (C0ADREBPNQ2) thread 1771797985.472499: "Added X new churned users (total now: Y)"
8. If total exceeds 10,000, alert Aaron
9. Also update data columns for existing users if their profile data changed (popularity, credits, etc.) — but NEVER touch columns AI-AN

## Account
- Google Sheets: a@muso.ai (GOG_KEYRING_PASSWORD from ~/.zshrc env var — do NOT hardcode)
- Athena: default profile, workgroup clio-agent, region us-west-2

## Tracking Columns (AI-AN) — NEVER OVERWRITE
- AI: outreach_status (not_contacted / contacted / responded / converted / declined)
- AJ: email_sent_date
- AK: email_variant (which email template was used)
- AL: response_status (opened / clicked / replied / bounced / unsubscribed)
- AM: notes (free text)
- AN: stage (new / nurture / hot_lead / won / lost)

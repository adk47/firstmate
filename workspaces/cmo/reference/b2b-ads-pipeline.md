# B2B Muso Ads Pipeline

Architecture and ownership for the B2B-Ads-Clio lead pipeline.

## Architecture (corrected 2026-04-11)

Discovery tools (web search, Datagma/Snov.io when wired) → *NocoDB* (B2B-Ads Intelligence — Contacts `m9vsbijhrr9ddeu` + Company `mvr6nmzcv7albxt`) → *GHL* (CRM pipeline: `B2B-Ads-Clio`) → Aaron closes.

- *NocoDB = source of truth for leads* (templates + KB stay on the Google Sheet)
- *GHL = source of truth for pipeline stage / sales process*
- Athena is NOT part of lead sourcing. Can help with stats/personalization data only.
- Klaviyo is OFF-LIMITS for cold outreach. Warmed Gmail only.
- Enrichment: Datagma + Snov.io (planned, not yet wired). Clay is fully deprecated and removed.
- All config (sheet IDs, GHL IDs, channels, voices) lives in `muso-outreach-engine/references/config.md`

## Execution Ownership

- Fede owns ALL outreach execution (GHL, LinkedIn, pipeline). HYDRA provides data intelligence + drafting.
- 1:1 emails from a@muso.ai are CEO-level outreach (AI-drafted), NOT Klaviyo blasts.

## Templates

- Provocateur template is DEAD. Private Invite template only.
- Templates must reference actual platform data (roster, credits, streams).

## Crosscheck Rules (4-point, per config.md)

Sheet logbook + NocoDB Contacts Intelligence + GHL + Gmail label. Never report outreach numbers from one source only.

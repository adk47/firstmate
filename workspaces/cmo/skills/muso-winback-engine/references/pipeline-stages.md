# Win Back Pipeline Stages

GHL pipeline configuration for the churned Pro win back engine.

- **Location ID**: `fmK5Vl9sJv49WTYA0QyP` (Muso Win Back location)
- **Pipeline ID**: `AZa8jK5S7UyQ0fqfxzyB` (Churn -> Win-back)
- **API key**: `$GHL_WINBACK_API_KEY` (separate from `$GHL_API_KEY` which is for B2B Ads)

## Stage List (7 stages)

| Order | Stage Name | Stage ID | Trigger |
|---|---|---|---|
| 1 | Churned | `819bd77b-9b34-4773-bdb3-4f532f925a9a` | Imported, not yet emailed |
| 2 | Next Up | `6f5fe454-c404-49c5-ac0c-c05299781ca2` | Queued for next batch |
| 3 | Emailed | `c01f6866-106a-4663-b177-93af8603a920` | Initial email sent |
| 4 | Replied | `73b66a22-98cb-47a5-b4fd-3b558394cc7b` | Reply detected in Gmail |
| 5 | Follow-up | `24f693ab-714e-4585-9245-100e50210eaa` | Day 7 or Day 45 follow up sent |
| 6 | Re-subscribed | `e51bd206-edec-4bb5-b344-39b2d96cd39e` | Detected in Stripe (won) |
| 7 | Lost / No Answer | `6a357aa2-e62b-4e7e-92dc-d124530c44b2` | Day 90 no reply, or declined |

## Verification

Stage IDs above were captured from prior config (2026-03 era). Verify they are
still current by running this fetch command. Update IDs if any have changed:

```bash
curl -s -G "https://services.leadconnectorhq.com/opportunities/pipelines" \
  -H "Authorization: Bearer $GHL_WINBACK_API_KEY" \
  -H "Version: 2021-07-28" \
  -d "locationId=fmK5Vl9sJv49WTYA0QyP" \
  | python3 -c 'import json, sys
data = json.load(sys.stdin)
for p in data.get("pipelines", []):
    if p["id"] == "AZa8jK5S7UyQ0fqfxzyB":
        for s in p.get("stages", []):
            print(f"{s[\"name\"]:<20} {s[\"id\"]}")'
```

This is part of STARTUP.md Phase 5 verification.

## Stage Transition Logic

| Event | From Stage | To Stage |
|---|---|---|
| Imported into GHL | (none) | Churned |
| Queued for next batch | Churned | Next Up |
| Initial email sent | Next Up (or Churned) | Emailed |
| Day 7 follow up sent | Emailed | Follow-up |
| Day 45 follow up sent | Follow-up | Follow-up (no stage change, log only) |
| Inbound reply detected | Emailed or Follow-up | Replied |
| Stripe re subscription detected | any | Re-subscribed |
| Day 90 no reply | Follow-up | Lost / No Answer |
| User declines | any | Lost / No Answer |
| Bounced or invalid email | any | Lost / No Answer |

## Notes

- Use GET with `page=N` for opportunity searches (POST is broken).
- Always pass `Version: 2021-07-28` header.
- Tags: `win-back-pro`, plus optional `high-value`, `payment-recovery`, cancel reason tags.
- Opportunity name format: `{first_name} {last_name} | {profile_name}`
- Monetary value: set to `Total LTV` from the high_value_churn sheet.

## History

- 2026-03-21: original 7 stage IDs documented in muso-winback-pro skill
- 2026-04-09: migrated to dedicated reference file during win back rebuild

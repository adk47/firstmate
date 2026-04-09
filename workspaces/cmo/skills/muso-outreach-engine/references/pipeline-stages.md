# B2B-Ads-Clio Pipeline Stages

GHL pipeline configuration for the B2B Ads sales outreach engine.

- **Location ID**: `S5w31kRRgsBjjiVATWlP` (B2B Ads sales location)
- **Pipeline ID**: `GeSt85TueSvJ0SNFZXfQ` (B2B-Ads-Clio)

## Stage List (11 stages)

| Order | Stage Name | Stage ID | Trigger |
|---|---|---|---|
| 1 | Cold | TBD | Contact in sheet, not yet emailed |
| 2 | Emailed | TBD | First outreach sent |
| 3 | Follow-up | TBD | Follow up sent (FU-01 through FU-04) |
| 4 | Replied | TBD | Reply detected in Gmail |
| 5 | Meeting Booked | TBD | Calendar booking or verbal confirmation |
| 6 | No-Show | TBD | Meeting did not happen |
| 7 | Awaiting for Application | TBD | Prospect reviewing, application pending |
| 8 | Proposal Draft | TBD | Proposal being drafted |
| 9 | Proposal Sent | TBD | Contract and pricing shared |
| 10 | Closed Won | TBD | Signed client |
| 11 | Closed Lost | TBD | Passed or went cold |

**Stage IDs are marked TBD.** They must be fetched live from GHL before the first
send. Legacy IDs from prior skill versions are stale because `Awaiting for
Application` and `Proposal Draft` were added after.

## Fetching Live Stage IDs

Run this to pull current IDs from GHL and update the table above:

```bash
source ~/.zshrc && curl -s -G "https://services.leadconnectorhq.com/opportunities/pipelines" \
  -H "Authorization: Bearer $GHL_API_KEY" \
  -H "Version: 2021-07-28" \
  -d "locationId=S5w31kRRgsBjjiVATWlP" \
  | python3 -c 'import json, sys
data = json.load(sys.stdin)
for p in data.get("pipelines", []):
    if p["id"] == "GeSt85TueSvJ0SNFZXfQ":
        for s in p.get("stages", []):
            print(f"{s[\"name\"]:<30} {s[\"id\"]}")'
```

Update the Stage ID column above with the output.

## Stage Transition Logic

The outreach engine should move opportunities between stages automatically on these
events:

| Event | From Stage | To Stage |
|---|---|---|
| Initial email sent | Cold | Emailed |
| Follow up sent (FU-01/02/03/04) | Emailed or Follow-up | Follow-up |
| Inbound reply detected | Emailed or Follow-up | Replied |
| Calendar booking detected | Replied | Meeting Booked |
| Meeting did not happen | Meeting Booked | No-Show |
| Prospect confirms interest, waiting on formal app | Replied or Meeting Booked | Awaiting for Application |
| Drafting proposal | Awaiting for Application | Proposal Draft |
| Proposal sent to prospect | Proposal Draft | Proposal Sent |
| Contract signed | Proposal Sent | Closed Won |
| Prospect passes or goes cold | any | Closed Lost |

## Notes

- Every new opportunity should include the `sheet_row_id` custom field so it can be
  traced back to `contacts_intelligence`.
- Opportunity name format: `{Company Name} | {Contact Name}`
- Tags: `B2B-Ads`, `Outreach`
- Use GET with `page=N` for opportunity searches. POST search is broken (caps at
  100, cursor does not work).

## History

- 2026-03-19: original 9 stage IDs documented in the skill file.
- 2026-04-09: added `Awaiting for Application` and `Proposal Draft` (now 11 stages).
  Stage IDs marked TBD pending live fetch.

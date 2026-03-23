---
name: muso-ops-credits
description: |
  Credit request processing for Muso.AI ops team. Review, approve, and reject
  user-submitted credit additions/changes with source verification.
  
  Replaces: Retool credit request management
  
  Use when: processing credit requests, reviewing pending credits, checking credit
  sources, managing user-added credits.

  Triggers: "credit request", "pending credits", "approve credit", "reject credit",
  "credit queue", "user credits", "credit source"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), Athena (credit analysis).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Ops — Credit Requests

Process user-submitted credit additions and changes.

## Access Control

Check sender_id tier from `muso-ops-admin`:
- Tier 1-3: full credit request operations
- Tier 4: read-only

## Workflows

### List Pending Credit Requests

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/credit-requests?status=pending&limit=20"
```

Also get pending counts:
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/credit-requests/counts"
```

### Review Credit Request

**Step 1: Pull request details**
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/credit-request/<id>"
```

**Step 2: Verify credit legitimacy**
For the track being credited:
```sql
-- Check existing credits on the track
SELECT t._id, t.title, t.popularity, t.default_release_label
FROM "platform-industry-bi-prod".matvw_catalog_track t
WHERE t._id = '<track_id>'
  AND t.is_deleted = false
```

**Step 3: Cross-reference**
- Does this person appear in industry data for this track?
- Is the role plausible given the track's genre/era/label?
- Web search: "[person name]" "[track title]" credits

**Step 4: Present verdict with recommendation**

### Approve Credit Request

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/w/admin/credit-request/<id>" '{"status":"approved"}'
```

### Reject Credit Request

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/w/admin/credit-request/<id>" '{"status":"rejected","reason":"[reason]"}'
```

Standard rejection reasons:
- "No matching credits found in industry data sources"
- "Credit already exists from verified industry feed"
- "Track metadata doesn't support this credit role"
- "Duplicate request — previously processed"

### Profiles with Pending Requests

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/credit-requests/profiles"
```

Useful for: identifying high-volume submitters, potential spam, or workspaces
that need cleansing.

## Fraud Signals

- 🚩 User submitting credits to tracks they have no industry connection to
- 🚩 Bulk credit submissions (>20 in one day)
- 🚩 Credits to high-popularity tracks by unknown profiles
- 🚩 Same user adding themselves to tracks across multiple unrelated genres
- 🚩 Credit additions right after profile claiming (padding credits)

## Alternatives to Suggest

When rejecting:
- "If you produced this track, ask your distributor to update the metadata"
- "Credits from industry sources (labels, distributors) are automatically reflected"
- "For live/session credits, provide documentation (session sheets, contracts)"

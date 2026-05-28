---
name: muso-ops-tracks
description: |
  Track management for Muso.AI ops team. Search, view, merge/unmerge tracks,
  manage analytics source links, handle raw credits, and trigger captures.
  
  Replaces: Retool "Ops Hub > Analytics Track Issues" and track management screens
  
  Use when: managing analytics links, merging tracks, fixing source link assignments,
  triggering track capture, viewing raw credits, track investigation.

  Triggers: "track", "analytics link", "source link", "merge track", "unmerge track",
  "track credits", "raw credits", "trigger capture", "move link", "remove link"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), Athena (track data).
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Track Management

Track lifecycle: search → investigate → modify → verify.

## Access Control

- Tier 1-2: All track operations including merge/unmerge
- Tier 3: Search, view, manage analytics links. NO merge/unmerge.
- Tier 4: Read-only

## Workflows

### Search Tracks

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/tracks/search?keyword=track+name&limit=10"
```

```sql
SELECT _id, title, popularity, default_release_label, release_timestamp
FROM hive."platform-industry-bi-prod".matvw_catalog_track
WHERE lower(title) LIKE '%track name%'
  AND is_deleted = false
ORDER BY popularity DESC
LIMIT 20
```

### View Track Details

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<track_id>"
```

### Manage Analytics Links

**List links:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<track_id>/analytics-sources"
```

**Add link:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/track/<track_id>/analytics-sources" \
  '{"url":"https://open.spotify.com/track/..."}'
```

**Remove link:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/track/<track_id>/analytics-sources" \
  '{"linkId":"<link_id>"}'
```

**Move link between tracks:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PATCH "/admin/track/<track_id>/analytics-sources" \
  '{"linkId":"<link_id>","fromTrackId":"<source_track_id>"}'
```

⚠️ **A source can only be assigned to a single track.** If you see "Link is already assigned":
1. Find which track currently has it
2. Remove from incorrect track
3. Add to correct track

### Merge Tracks

⚠️ Tier 2+ only.

Pre-merge: compare both tracks (credits, analytics links, popularity).

```bash
# Direction: mergeInto = SURVIVOR (kept). tracksIds = LOSERS (soft-deleted, redirected to survivor).
# Endpoint: POST /admin/tracks/merge
# Body: { mergeInto: <primary_id>, tracksIds: [<duplicate_id>, ...] }
# Backend handler: core-backend/src/apis/_admin/track/mergeTracks.js
# A missing `mergeInto` returns "Track ID is required"; missing `tracksIds` returns "Tracks IDs are required". Field names are exact.
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/tracks/merge" \
  '{"mergeInto":"<primary_id>","tracksIds":["<duplicate_id>"]}'
```

### Unmerge Tracks

⚠️ Tier 2+ only.

```bash
# Direction: unmergeFrom = the SURVIVOR (kept). tracksIds = the merged-in tracks to extract back out.
# Endpoint: POST /admin/tracks/unmerge
# Body: { unmergeFrom: <primary_id>, tracksIds: [<merged_in_id>, ...] }
# Backend handler: core-backend/src/apis/_admin/track/unmergeTracks.js
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/tracks/unmerge" \
  '{"unmergeFrom":"<primary_id>","tracksIds":["<merged_in_id>"]}'
```

### View Raw Credits

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<track_id>/raw-credits"
```

### Add/Remove Credits

**Add credit:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/track/<track_id>/profile/<profile_id>/credits" \
  '{"role":"producer"}'
```

**Remove credit:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/track/<track_id>/profile/<profile_id>/credits"
```

### Trigger Capture

Force-refresh analytics data for a track:

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/track/capture/<track_id>"
```

### Enrich Track from URL

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/track/enrichByUrl" '{"enrichmentUrl":"https://open.spotify.com/track/..."}'
```

## Common Issues (from Retool docs)

- **"Link is already assigned to a different track"** → Find the current track, remove, then re-add
- **Credits from Spotify are wrong** → User must fix on Spotify/distributor first. We mirror industry data.
- **"Non-musical" link incorrectly marked** → Fix in Aurora stats DB: `is_not_music = false`. Updates next day.
- **YouTube playlist claiming** → Assign the single YouTube link to any one of the user's tracks

## Important Rule

**NEVER merge tracks into albums.** Database changes are too complex/hacky. Decline these requests and explain that system integrity takes priority.

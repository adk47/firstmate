---
name: muso-ops-profiles
description: |
  Profile management for Muso.AI ops team. Search, view, merge, unmerge, link/unlink
  external IDs, enrich from external sources, and manage profile data.
  
  Replaces: Retool "Growth > Support > Merging" and profile management screens
  
  Use when: merging profiles, unmerging profiles, linking Spotify IDs, enriching profiles,
  managing profile data, searching for profiles, profile investigation.

  Triggers: "merge profile", "unmerge", "link spotify", "enrich profile", "profile search",
  "find profile", "profile details", "link external", "avatar upload",
  "unlink raw profile", "remove raw profile", "remove spotify link", "remove tidal link"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-verify-profile
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), Athena (profile data), web_search.
metadata:
  version: "1.2"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Profile Management

Full profile lifecycle: search → investigate → modify → verify.

## Access Control

- Tier 1-2: All profile operations including merge/unmerge
- Tier 3: Search, view, enrich, link/unlink. NO merge/unmerge.
- Tier 4: Read-only (search and view)

## Workflows

### Search Profiles

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/profile/search?keyword=John+Producer&limit=10"
```

Supplement with Athena for richer results:
```sql
SELECT _id, name, profile_type, credits_count, common_credits,
       collaborations_count, popularity, rank, country, primary_genre
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE lower(name) LIKE '%john producer%'
  AND is_deleted = false
ORDER BY popularity DESC
LIMIT 20
```

### View Profile Details

Combine admin API + Athena for complete picture:

```bash
# Admin API
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/profile/<profile_id>"
```

```sql
-- Athena: full profile data
SELECT * FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = '<profile_id>' AND is_deleted = false

-- Athena: claiming status
SELECT * FROM postgresql_core.public.claiming
WHERE profileid = '<profile_id>'

-- Athena: team/workspace
SELECT t.name, t.email, rs.status as seat_status
FROM postgresql_core.public.roster_seats rs
JOIN postgresql_core.public.teams t ON rs.teamid = t.id
WHERE rs.profileid = '<profile_id>'
```

### Merge Profiles

⚠️ Tier 2+ only. This is a significant, hard-to-undo operation.

**Pre-merge checklist (MANDATORY):**

1. **Confirm same person** — compare names, aliases, IPIs, credits, genres
2. **Check credit intersection** — shared tracks between profiles
3. **Identify primary** — which profile keeps its ID (usually higher popularity/credits)
4. **Check claiming status** — claimed profiles need extra care
5. **Show side-by-side comparison**

```
🔀 *Profile Merge Preview*

*Primary (keeps ID):*
• [Name A] — 500 credits, 120 collabs, rank #2,345
• IPI: 123456789 (ASCAP)
• Claimed: Yes (team: label@example.com)

*Secondary (merges into primary):*
• [Name B] — 45 credits, 12 collabs, rank #89,000
• IPI: none
• Claimed: No

*Credit Intersection:* 8 shared tracks
*Name Similarity:* 95% (alias match)

⚠️ This will merge [Name B] → [Name A]. The secondary profile will be marked deleted.
Proceed? (yes/no)
```

Execute:
```bash
# Direction: mergeInto = SURVIVOR (kept). profilesIds = LOSERS (soft-deleted, redirected to survivor).
# Endpoint: POST /admin/profiles/merge
# Body: { mergeInto: <primary_id>, profilesIds: [<duplicate_id>, ...] }
# Backend handler: core-backend/src/apis/_admin/profile/mergeProfiles.js
# A missing `mergeInto` returns "Profile ID is required"; a missing `profilesIds`
# returns "Profiles IDs are required". Field names are exact — do not rename.
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profiles/merge" \
  '{"mergeInto":"<primary_id>","profilesIds":["<duplicate_id>"]}'
```

### Unmerge Profile

⚠️ Tier 2+ only.

**Pre-unmerge checklist:**
1. Verify the `merged_to_id` is correct
2. Check credit intersection — move shared credits to correct profile first
3. Confirm the unmerge target

```bash
# Direction: unmergeFrom = the SURVIVOR (kept). profilesIds = the merged-in profiles to extract back out.
# Endpoint: POST /admin/profiles/unmerge
# Body: { unmergeFrom: <primary_id>, profilesIds: [<merged_in_id>, ...] }
# Backend handler: core-backend/src/apis/_admin/profile/unmergeProfiles.js
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profiles/unmerge" \
  '{"unmergeFrom":"<primary_id>","profilesIds":["<merged_in_id>"]}'
```

**Post-unmerge:** Verify both profiles have correct credits. Full update takes up to 24h.

### Link / Unlink External ID (IPI only)

> ⚠️ Despite the section name's history, `link-external` / `unlink-external` only
> handle **IPI** for profiles. The handler accepts `{externalColumn, externalId}`
> and downstream validation in `industry-data-processing` rejects every column
> except `"ipi"` (`profile_operations.link_external_columns()` returns `["ipi"]`).
> Source platform IDs (Spotify, Tidal, etc.) go through **Unlink Raw Profile** below.

Link an IPI:
```bash
# Endpoint: POST /admin/profile/:profileId/link-external
# Body: { externalColumn: "ipi" /* ONLY legal value; all others rejected downstream */, externalId: "<ipi_number>" }
# Backend handler: core-backend/src/apis/_admin/profile/linkExternalIds.js
# Downstream constraint: industry-data-processing/processors/catalog/operations/profile_operations.py:33
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profile/<profile_id>/link-external" \
  '{"externalColumn":"ipi","externalId":"00123456789"}'
```

Unlink an IPI:
```bash
# Endpoint: POST /admin/profile/:profileId/unlink-external
# Body: { externalColumn: "ipi" /* ONLY legal value */, externalId: "<ipi_number>" }
# Backend handler: core-backend/src/apis/_admin/profile/unlinkExternalIds.js
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profile/<profile_id>/unlink-external" \
  '{"externalColumn":"ipi","externalId":"00123456789"}'
```

Before linking: verify the IPI actually belongs to this profile (web search + IPI registry).

### Unlink Raw Profile (Spotify, Tidal, etc.)

For source-platform raw profile IDs (NOT IPI). Raw IDs are passed in
`<source>:<external_id>` form. Valid sources are defined in
`industry-data-processing/common/common_values.py` → `Source`:
`spotify`, `tidal`, `genius`, `jaxsta`, `youtube_music`, `mlc`, `muso`.

```bash
# Endpoint: POST /admin/profile/:profileId/unlink
# Body: { rawIds: ["<source>:<external_id>", ...] }
# Backend handler: core-backend/src/apis/_admin/profile/unlinkProfile.js
# Missing/empty rawIds returns "Raw IDs are required".
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profile/<profile_id>/unlink" \
  '{"rawIds":["spotify:<spotify_artist_id>","tidal:<tidal_artist_id>"]}'
```

Pre-flight checks:
1. List the profile's raw links first (admin GET on the profile, or Trino
   `hive."platform-industry-bi-prod".matvw_catalog_profile.raw_ids`) so the operator has a known starting set.
2. Confirm in Slack which raw IDs to drop, then echo them back before submit.

Post-unlink: only release-date fields update in real time; the catalog pipeline
takes up to 24h to reflect the unlink across credits and analytics.

### Enrich Profile

From URL (handler reads `enrichmentUrl` + optional `profileId`):
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/profile/enrichByUrl" \
  '{"enrichmentUrl":"https://open.spotify.com/artist/...","profileId":"<profile_id>"}'
```

From Spotify ID (path takes the spotify artist id):
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/artist/<spotify_artist_id>/enrich"
```

### Upload Avatar

When ops uploads an image to Slack for a profile avatar:
1. Download the image from Slack
2. Upload via admin API multipart endpoint

```bash
# Method PUT, route segment is /image (not /avatar). The wrapper's `upload` uses PUT.
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  upload "/admin/profile/<profile_id>/image" /tmp/avatar.jpg
```

### Clear Profile Cache

```bash
# Method DELETE, route segment is /cache (not /clear-cache).
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/profile/<profile_id>/cache"
```

### Export Credits

```bash
# Method GET, path uses /admin/professional/:id/credits/export.
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/professional/<profile_id>/credits/export"
```

## Merge Prevention Rules (from Retool docs)

Profiles will NOT auto-merge if:
- Track similarity < 50%
- Name similarity < 80% (Levenshtein)
- Claimed profiles are NEVER merged automatically

## Common Issues

- **"Artist not found"** → Try legal name, known aliases, or Spotify ID
- **Post-merge credits wrong** → Pipeline takes up to 24h. Check again tomorrow.
- **Unmerge timing** → Only release date updates in real-time. Everything else: 24h pipeline.

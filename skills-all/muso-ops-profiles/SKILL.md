---
name: muso-ops-profiles
description: |
  Profile management for Muso.AI ops team. Search, view, merge, unmerge, link/unlink
  external IDs, enrich from external sources, and manage profile data.
  
  Replaces: Retool "Growth > Support > Merging" and profile management screens
  
  Use when: merging profiles, unmerging profiles, linking Spotify IDs, enriching profiles,
  managing profile data, searching for profiles, profile investigation.

  Triggers: "merge profile", "unmerge", "link spotify", "enrich profile", "profile search",
  "find profile", "profile details", "link external", "unlink", "avatar upload"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-verify-profile
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Requires: muso-ops-admin (API gateway), Athena (profile data), web_search.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
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
  call GET "/w/admin/profiles/search?q=John+Producer&limit=10"
```

Supplement with Athena for richer results:
```sql
SELECT _id, name, profile_type, credits_count, common_credits,
       collaborations_count, popularity, rank, country, primary_genre
FROM "platform-industry-bi-prod".matvw_catalog_profile
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
  call GET "/w/admin/profile/<profile_id>"
```

```sql
-- Athena: full profile data
SELECT * FROM "platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = '<profile_id>' AND is_deleted = false

-- Athena: claiming status
SELECT * FROM "platform-core-backend-export-prod".public_claiming
WHERE profileid = '<profile_id>'

-- Athena: team/workspace
SELECT t.name, t.email, rs.status as seat_status
FROM "platform-core-backend-export-prod".public_roster_seats rs
JOIN "platform-core-backend-export-prod".public_teams t ON rs.teamid = t.id
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
# Note: merge endpoint is /admin/profiles/merge (plural), takes source+target in body
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profiles/merge" '{"sourceProfileId":"<secondary_id>","targetProfileId":"<primary_id>"}'
```

### Unmerge Profile

⚠️ Tier 2+ only.

**Pre-unmerge checklist:**
1. Verify the `merged_to_id` is correct
2. Check credit intersection — move shared credits to correct profile first
3. Confirm the unmerge target

```bash
# Note: unmerge is also at /admin/profiles/unmerge (plural)
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profiles/unmerge" '{"profileId":"<profile_id>"}'
```

**Post-unmerge:** Verify both profiles have correct credits. Full update takes up to 24h.

### Link External ID (Spotify, etc.)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/<profile_id>/link-external" \
  '{"platform":"spotify","externalId":"spotify_artist_id"}'
```

Before linking: verify the external ID actually belongs to this profile.
Web search + API check to confirm.

### Unlink External ID

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/<profile_id>/unlink-external" \
  '{"platform":"spotify","externalId":"spotify_artist_id"}'
```

### Enrich Profile

From URL:
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/enrich-by-url" '{"url":"https://open.spotify.com/artist/..."}'
```

From Spotify ID:
```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/enrich-by-spotify" '{"spotifyId":"..."}'
```

### Upload Avatar

When ops uploads an image to Slack for a profile avatar:
1. Download the image from Slack
2. Upload via admin API multipart endpoint

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  upload "/w/admin/profile/<profile_id>/avatar" /tmp/avatar.jpg
```

### Clear Profile Cache

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/<profile_id>/clear-cache"
```

### Export Credits

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/w/admin/profile/<profile_id>/export-credits"
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

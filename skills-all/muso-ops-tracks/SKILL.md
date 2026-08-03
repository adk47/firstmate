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
  Requires: muso-ops-admin (API gateway), Trino (track data).
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Track Management

Track lifecycle: search → investigate → modify → verify.

> This is a **canonical** skill (no workspace shadow). If you need to read its
> own files, they live under `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-tracks/`
> — NOT under `workspaces/operations/skills/`, which does not exist for this skill.

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
  '{"link":"https://open.spotify.com/track/..."}'
```

**Remove link:**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/track/<track_id>/analytics-sources" \
  '{"linkId":"<link_id>"}'
```

🛑 **Bulk-gated (incident 2026-05-26).** This DELETE counts toward the bulk
destructive budget — after 10 destructive DELETEs in 15 minutes the gate
refuses further ones until you pass `--confirmed-by aaron --approval-msg-id <ts>`.
Removing analytics links in bulk to "clean up broken/pending sources" is the
exact action that wiped 285 real source rows; the `in_progress=true, name=null`
stubs carried live stream data. See `muso-ops-admin` → **Bulk Destructive Gate**.

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

### Ghost/source-less track cleanup

Use this when a profile has a real credit on a placeholder catalog row with no
source metadata, while a separate source-backed row already exists for the same
recording. The goal is to keep the profile credit intact by merging the
source-less loser into the source-backed survivor.

Do **not** delete the ghost row, remove analytics links, or remove/re-add the
profile credit as the primary fix. Track merge is the catalog-preserving repair.

**1. Read both candidate rows.**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<ghost_track_id>"

bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<survivor_track_id>"

bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<survivor_track_id>/analytics-sources"
```

Before merging, confirm:
- the loser is source-less or effectively a placeholder: no artists, no Spotify
  IDs, no ISRCs, no label/publisher, and low/no popularity;
- the survivor is source-backed with resolved artists and at least one durable
  source identifier (Spotify ID, ISRC, or equivalent analytics source);
- the title and source evidence point to the same recording.

If there are many same-title catalog rows, hold until the survivor is proven by
source metadata. Never choose a survivor from title alone.

**2. Merge in the safe direction.**
```bash
# mergeInto = source-backed SURVIVOR (kept)
# tracksIds = source-less LOSER rows (soft-deleted, redirected to survivor)
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/tracks/merge" \
  '{"mergeInto":"<survivor_track_id>","tracksIds":["<ghost_track_id>"]}'
```

**3. Verify by read-back.**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<ghost_track_id>"

bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<survivor_track_id>"

bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/profile/<profile_id>/credits?limit=200&offset=0"
```

A clean read-back shows:
- the old ghost ID resolves to the survivor or is marked merged/deleted;
- the survivor still has the source-backed metadata;
- the profile credit appears on the survivor track ID;
- the ghost track ID no longer appears as a separate row on the profile.

Report the final state as:
```text
<ghost_track_id> -> <survivor_track_id> - <title>, <artists>, source <id>,
ISRC <isrc>, <profile_name> <role> present.
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

### Removal Requests ("remove these tracks from profile X")

🛑 **Never use the bulk profile endpoint (`DELETE /admin/profile/:id/credits`) for
removal requests.** It returns 200 but only routes raw-role-row deletes through the
raw-ingestion queue; the **materialized credits users see are untouched**, so the
tracks never disappear (2026-07 La Mano 1.9 / Matt Wright incident: two 200'd bulk
batches, zero visible change after 24h). The displayed credits are NOT a live view
over raw sources — tracks with zero remaining raw assertions keep displaying.

The effective lever is the per-track DELETE above, one (track, profile) pair per
call. It edits the materialized credits directly and **overrides still-active
external raw credits** (tidal/mlc/jaxsta) — the canonical procedure per
`muso-clio/references/kt/2026-02-04_user-requests-pt-3.md` ("manually remove
incorrect credits (overrides raw source)").

Playbook:

1. Resolve each requested title to its track id via
   `GET /admin/profile/<profile_id>/credits?keyword=...` — match on title AND
   artist (generic titles like "Intro"/"Baby" collide). If more than one
   candidate still matches, STOP and confirm the exact track id with the
   requester — never guess. The list's offset pagination has unstable
   ordering: dedupe fetched items by track id.
2. Canary one delete, read back the credits **list** to confirm it vanished
   (~20s — this is a synchronous edit to materialized rows, not an async
   pipeline job; the up-to-24h lag note in `muso-ops-profiles` applies to
   raw-unlink, not this). Then process the rest.
3. More than 10 destructive DELETEs in 15 min trips the tier-2 gate
   (`policy_refused`) — expected. Escalate for second-human approval
   (`--confirmed-by <approver>` + `--approval-msg-id <slack-ts>` on
   `muso-admin-api.sh`; muso-cli calls the latter `--approval-ref`); do NOT
   pace batches to slide under it.
4. Verify N/N via the credits list. `creditCount` on `GET /admin/profile/:id`
   is a lagging cached stat — never use it as the landed/not-landed signal.

Caveats: primary-artist credits are refused by the server unless `?force=true`
(ops use only — double-check before forcing). A wrongly-deleted credit is
recoverable via the Add credit POST above.

If the wrong credits trace to a wrong-artist raw link, consider also unlinking
that raw profile so re-ingestion can't re-assert them — but see the mixed-raw
warning in `muso-ops-profiles` → Unlink Raw Profile first.

Credit removals do **not** refresh the profile's Collaborators list — that table
is derived separately and needs its own rebuild. Finish with
`muso-ops-collaborators`.

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

### Fix missing artwork / credit details — full recipe

This is the procedure for "fix the tracks / artwork / credit details" requests
(ops SOUL routes them here). Artwork, `label`, `p_line`, `c_line`,
`spotifyLabel`, and `artists` are **mirrored from a Spotify source** — we do not
author them (see "Credits from Spotify are wrong" below). So the recipe is:
verify a source exists → trigger the repair → **wait** → read back → report.

**1. Precondition — confirm a resolved Spotify source exists.** Enrich/capture
populate those fields *from* a Spotify analytics source. A track with no Spotify
source cannot be enriched, full stop.
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<track_id>/analytics-sources"
```
- No Spotify source at all → the track **cannot be enriched** here. Add one only
  if you have a real, matching Spotify release URL (see "Add link" above); if no
  match exists, report `cannot enrich — no Spotify match` and stop. Do NOT loop
  capture/enrich against a track with no source.

**2. Trigger the repair** — `capture/<track_id>` and/or `enrichByUrl` (above).

**3. The repair is ASYNC — a `200` means QUEUED, not done.** `enrichByUrl` and
`capture` hand off to an SQS → capture-worker → Industry-Processing → catalog
pipeline owned by core-backend/Catalog; it is NOT synchronous. Immediately after
a `200`, the analytics source will read `pending=true / name=null` and the catalog
fields will still be empty — **this is the normal in-flight state, not a failure**
(same `in_progress=true, name=null` state the bulk-delete gate protects, above).
Reading the track back in the same breath as the `200` and calling it "failing"
is wrong — that was the 2026-06-09 mis-report.

**4. Verify by read-back, after a wait.** Re-read the track a few minutes later
(start ~5–15 min) and check the actual fields:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/track/<track_id>"   # inspect: artwork, label, p_line, c_line, spotifyLabel, artists
```

**5. Report THREE states per track — never a premature binary fixed/failing:**
- `✅ materialized` — fields are now populated.
- `⏳ still pending` — repair queued, not yet materialized; say so and give a
  re-check time. This is a normal, honest outcome, not a failure.
- `❌ cannot enrich (no Spotify match)` — no source to mirror from (step 1).

**6. Escalate to core-backend/Catalog ONLY for a genuine pipeline bug** — a track
that HAS a resolved Spotify source but whose fields stay null well past the
window (e.g. ~1h). That is distinct from "still pending" and "no match". Do not
escalate (and do not invent a ticket/owner — see ops SOUL honesty doctrine) for
the first two states.

## Common Issues (from Retool docs)

- **"Link is already assigned to a different track"** → Find the current track, remove, then re-add
- **Credits from Spotify are wrong** → User must fix on Spotify/distributor first. We mirror industry data.
- **"Non-musical" link incorrectly marked** → Fix in Aurora stats DB: `is_not_music = false`. Updates next day.
- **YouTube playlist claiming** → Assign the single YouTube link to any one of the user's tracks

## Important Rule

**NEVER merge tracks into albums.** Database changes are too complex/hacky. Decline these requests and explain that system integrity takes priority.

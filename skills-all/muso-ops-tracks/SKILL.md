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
  - muso-cli
compatibility: |
  Requires: muso-ops-admin (API gateway), Trino (track data), and a muso-cli
  carrying the `tracks sources` verb group (Muso-AI/muso-cli#36) for the
  analytics-link workflows.
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

### "Hide this track from public" / "delete this track" / "remove these credits": NEVER `DELETE /admin/track/:id`

🛑 Incident of 2026-10-20 14:05Z: Jan's "hide track from public" (WE SMOKE `2631b04d`) was self-approved into two whole-track DELETEs. Core refused both, and nothing changed.

**What exists:**
- **There is no track hide/unlist in core.** No hidden or visibility flag, no endpoint. Checked in core-backend `src/apis/index.w.js` and `src/models`.
- **`DELETE /admin/track/:id`** is a **whole-track Catalog/IDP tombstone**: the track AND every served credit on it, for every profile.
- **`DELETE /admin/track/:id/profile/:pid/credits`** removes that profile's credits.
- **Both are removals.** Core refuses agents on both (403 `credit_removal_agent_refused`). `muso-admin-api.sh` refuses them under god-mode self-approve (`MUSO_REMOVAL_NO_SELF_APPROVE`).
- **Never retry them, and never through another wrapper or identity** (`muso api`, `--confirmed-by`, a different requester).

**Reply rules (one message, then stop):**
1. **A "hide" request:** read the track back and answer:
   > I can't hide tracks yet. Removing it would delete the whole track "<title>" and its N credits (on M profiles) for everyone. What's the reason?

   The only visibility-only option today is the web legal-hold list. It answers 410 to signed-out visitors only; signed-in users, the API and search still see the track. It is an H-DevOps env change, meant for legal notices. Mention it only when the reason is legal.
2. **Any removal request without a recorded reason:** ask exactly one question, "What's the reason for removing it?", and do nothing else. A removal needs one of:
   - **DSP-removal proof:** the track is gone from Spotify, Apple and the other DSPs;
   - **different-profile proof:** the credit belongs to someone else;
   - **plus a label check.**
3. **With a recorded reason:** follow **Removal Requests** below. Post the handoff (targets + reason, with whole-track and credit removals named separately), and a named human executes it from their own login (or the credit-ops identity once it is live). Read back afterwards. Do not execute it yourself.

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

**Use `muso tracks sources` — do not hand-roll these payloads.** Every field
name below is a trap that has cost real writes, and the CLI holds all of them
still in typed code with golden tests. Hand-rolled `muso-admin-api.sh call`
bodies are how the 2026-07-15 incident happened.

> **Requires muso-cli >= 0.11.1** (the `tracks sources` verb group, Muso-AI/muso-cli#36).
> Check before you rely on it:
> ```bash
> muso tracks --help 2>/dev/null | grep -qE '^[[:space:]]+sources[[:space:]]' || echo "CLI too old — escalate, do NOT hand-roll the payload"
> ```
> Test for the verb ROW, not the exit code: `muso tracks sources --help` prints the
> parent `tracks` help and **exits 0** on a CLI that lacks the verb, so an
> exit-status probe passes on exactly the version it must reject.
> If the deployed CLI predates it, escalate to get muso-cli released rather than
> reaching for `muso-admin-api.sh` — reconstructing these bodies by hand is the
> exact failure this section exists to prevent.

**List links** — the only evidence a source write landed:
```bash
muso --env prod --json tracks sources list <track_id>
```

**Add link:**
```bash
muso --env prod --json tracks sources add <track_id> \
  --link "https://open.spotify.com/track/..." --requester <you>@muso.ai
```
The add reads the source list back and reports `attached` and `pending`. Trust
those, not the HTTP status — see **Verify after writing** below.

**Remove link:**
```bash
muso --env prod --json tracks sources remove <track_id> \
  --link "https://open.spotify.com/track/..." --requester <you>@muso.ai --yes
```
`--link` is required even when you know the link id: `deleteAnalyticsLink.js`
runs `new URL(link)` before it ever looks at `linkId`, so an id-only body
answers `400 Invalid link!`.

🛑 **Bulk-gated (incident 2026-05-26).** This DELETE counts toward the bulk
destructive budget — after 10 destructive DELETEs in 15 minutes the gate refuses
further ones until an explicit human decision is cited. If the requester is
Aaron, Jan or Nick, **that decision is their own request message** — cite it and
carry on, do not page anyone: on the operations agent pass
`--approval-msg-id <slack-ts> --approval-author-id <Uxxxxxxxx>`; elsewhere pass
`--confirmed-by <their handle> --approval-ref <slack-ts>`. For any other
requester you need a real approver's decision.
(On `muso-admin-api.sh` that timestamp flag is spelled `--approval-msg-id`; the
CLI calls it `--approval-ref`. Use the CLI spelling with the commands above.)
Removing analytics links in bulk to "clean up broken/pending sources" is the
exact action that wiped 285 real source rows; the `in_progress=true, name=null`
stubs carried live stream data. See `muso-ops-admin` → **Bulk Destructive Gate**.

**Move link between tracks:**
```bash
muso --env prod --json tracks sources move <destination_track_id> \
  --link-id <link_id> --requester <you>@muso.ai
```
The track in the path is the **destination**. There is no source-track
parameter — the PATCH body is `{id?, linkId?}` and any `fromTrackId` is
silently ignored (`moveAnalyticsLink.js`).

⚠️ **A source can only be assigned to a single track.** If you see "Link is already assigned":
1. Find which track currently has it
2. `tracks sources move` it onto the correct track (do NOT remove-then-add —
   the remove is bulk-gated and destroys the captured counters)

### Verify after writing

**Incident 2026-07-15 → 2026-07-16.** Ops added 10 YouTube sources, reported
success, and the requester came back with "analytics still at 0". Two separate
mistakes, both avoidable here:

1. **`200` is not evidence.** The add/remove/move endpoints all answer an empty
   200 with no body and no link id. Only `tracks sources list` proves anything.
   Re-run it and confirm the link is present.
2. **`pending: true` means capture has not finished.** Capture is asynchronous.
   Wait and re-check; do not report numbers off a pending source. If a source
   is still pending long after, `muso tracks capture <track_id>` re-queues the
   whole track at high priority.
3. **A source attaches to a TRACK, not to a profile.** It only reaches a
   profile's analytics if that profile holds a credit on that track. Verify
   with `muso profiles credits list <profile_id>` — the TRACK column carries
   the ids. Worked example: track `b7a75b06-f1ef-40c0-97be-df82ad6a3b75`
   ("Mi Razón") carries a Tristana-produced YouTube video, but Tristana holds
   no credit on it, so those 146k streams accrue to Patty Theone instead.
4. **Report the entity you actually checked.** Name the id *and* the display
   name in the reply. The same 2026-07-15 thread also carried a profile-merge
   request, and the status readback was taken off that request's profile
   (`7662f5b3…` = Keaton Simons) rather than the profile the sources belonged
   to — which is why the work looked failed when it had succeeded.

### Merge Tracks

**Merge keep conflicts — HOLD.** Do not execute a merge / unmerge / track-merge ticket tagged `merge-keep-conflict`, nor one whose OPEN sibling (named by a `merge-keep-conflict-with:<id>` tag on either ticket) still carries it: Caroline filed two requests in one conversation that keep different profiles / tracks. A human reconciles them with the customer, closes the ticket they reject and removes `merge-keep-conflict` from the one they keep; a closed sibling never holds. Nor one tagged `merge-intake-stale`: a follow-up's merge targets could not be written to its description, so the description is incomplete; a human removes the tag once it is fixed. Same rule as `scripts/lib/merge_keep_conflict.py`, which every merge sweep uses.

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

**Remove credit: agents never execute it.** `DELETE /admin/track/<track_id>/profile/<profile_id>/credits` is a removal. Core refuses agent identities (403 `credit_removal_agent_refused`), and `muso-admin-api.sh` refuses it under god-mode self-approve (`MUSO_REMOVAL_NO_SELF_APPROVE`). Use the handoff below.

### Removal Requests ("remove these tracks from profile X", "delete this track")

**Agents prepare, a named human executes, and agents verify.** There is no agent execution path for any removal (2026-10-20 WE SMOKE incident; firstmate 121/122). A requester's message is **never** an approval for a removal, from anyone. That includes god-mode and Aaron/Jan/Nick, and it applies whether or not you cite their Slack ts.

1. **Reason first.** If no reason is recorded, ask the one question from the top section ("What's the reason for removing it?") and stop. A removal needs one of:
   - DSP-removal proof (gone from Spotify/Apple/the other DSPs);
   - different-profile proof (the credit belongs to someone else);
   - plus a label check.
2. **Resolve the exact targets, read-only.**
   - Look each title up with `GET /admin/profile/<profile_id>/credits?keyword=...` and match on title AND artist. Generic titles collide; if more than one candidate matches, STOP and confirm the track id. Dedupe by track id, because offset pagination reorders.
   - For a whole track, `GET /admin/track/<track_id>` gives the title, artists and popularity. Count the served credits and the profiles they sit on.
3. **Post the handoff in the thread, then stop.** Include:
   - the reason and its proof link;
   - the exact list of targets, named by kind:
     - **credit removal:** (track id, title, profile id) pairs, executed one pair per call;
     - **whole track:** track id, title, and N credits on M profiles. This is a Catalog/IDP tombstone for every profile, not a profile edit;
   - the named human who executes it from their **own interactive login** (core's `correctionPath`), or the credit-ops identity once it is live.
4. **Read back after they report it done.** Report N/N, or name each pair that did not land; never report a removal you did not read back.
   - **Credit removal:** the profile's credits list no longer shows each pair. This is a synchronous edit, so allow about 20 s. `creditCount` on `GET /admin/profile/:id` is a lagging cache, never the signal.
   - **Whole track:** `GET /admin/track/<track_id>` shows it deleted (or 404s), every affected profile's credits list no longer shows it, and the public page `https://muso.ai/track/<track_id>` no longer serves it.
5. **Follow-ups**, also executed by the human:
   - Credit removals do not refresh Collaborators; run `muso-ops-collaborators`.
   - If the wrong credits trace to a wrong-artist raw link, consider unlinking that raw profile so re-ingestion can't re-assert them. Read the mixed-raw warning in `muso-ops-profiles` → Unlink Raw Profile first.

**Reference for the human executor**, not for agents:
- **The bulk profile endpoint does nothing visible.** `DELETE /admin/profile/:id/credits` returns 200, but it only queues raw-row deletes; the materialized credits users see stay. This bit us with La Mano 1.9 and Matt Wright in 2026-07.
- **The effective lever is the per-pair DELETE.** It edits materialized credits directly and overrides still-active external raw credits (tidal/mlc/jaxsta).
- **Primary-artist credits need `?force=true`.**
- **A wrong removal is recoverable** with the Add credit POST above.

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

- **"Link is already assigned to a different track"** → find which track has it, then
  `tracks sources move` it onto the correct one. Do NOT remove-then-add: the remove is
  bulk-gated and destroys the captured counters (see "A source can only be assigned to a
  single track" above)
- **Credits from Spotify are wrong** → User must fix on Spotify/distributor first. We mirror industry data.
- **"Non-musical" link incorrectly marked** → Fix in Aurora stats DB: `is_not_music = false`. Updates next day.
- **YouTube playlist claiming** → Assign the single YouTube link to any one of the user's tracks

## Important Rule

**NEVER merge tracks into albums.** Database changes are too complex/hacky. Decline these requests and explain that system integrity takes priority.

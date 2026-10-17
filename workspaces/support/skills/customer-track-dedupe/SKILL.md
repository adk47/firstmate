---
name: customer-track-dedupe
description: When a customer asks to merge/dedupe duplicate TRACKS (not profiles), capture which track to keep and which duplicate(s) to fold in, then file ONE high-signal track-merge ticket for the Catalog/Operations team. Caroline NEVER merges.
triggers:
  - "merge my duplicate tracks"
  - "merge these tracks"
  - "combine these tracks"
  - "these two tracks are the same"
  - "this track is listed twice"
  - "duplicate track"
  - "duplicate tracks"
  - "merge these track pairs"
  - "this is the same song"
---

# Customer Track Dedupe (capture + file)

## Purpose

A customer says the same recording appears as two (or more) tracks and wants the
duplicates folded into one master. Caroline **captures** which track to keep and which
to fold in, then files a `track-merge` action-request for the Catalog/Operations team.
**Caroline never merges** – the track merge is an irreversible tier-2 write
(`POST /admin/tracks/merge`) executed by a trusted human after their own pre-merge
checks. This is distinct from a *profile* merge (see `customer-profile-dedupe`) and from
"remove these tracks from my profile" (see `customer-credit-removal`, which previews and routes, never removes).

## What this skill does NOT do

- Execute a track merge or unmerge (Caroline has no track-merge tool – Operations executes).
- Verify that two tracks are truly duplicates. There is **no track-ownership /
  track-dedupe read tool** (the admin read allowlist has no `/track` path), so Caroline
  cannot resolve track UUIDs or confirm a duplicate the way `dedupe_check` does for
  profiles. Treat the customer's list as **claims to capture**, corroborated only lightly
  (below), and let Operations resolve the ids and decide.
- Promise a completion time. The merge is human-gated.

## Tools this skill uses

- `credits_search` / `profile_status` – **light, read-only corroboration only**: confirm
  the named tracks plausibly appear among the customer's credited tracks. These return
  track **names**, not the UUIDs the merge API needs, and cannot tell master from
  duplicate – so this is corroboration, not verification. Do **not** block filing on it.
- `create_ticket` – file the `track-merge` action-request (tier-2) for the team.

## Flow

### Step 1 – Capture the pairs

From the customer's message, identify for each duplicate:
- the **master** (the track they want to keep), and
- the **duplicate(s)** to fold into it.

If they gave names or URLs, you may run `credits_search` against their profile to
sanity-check the tracks exist on their catalog, but never require it.

### Step 2 – File ONE ticket for all pairs

`create_ticket` is capped at 2 creates per session, so a 7-pair request must go in a
**single** ticket. Put every pair in `details.track_merge_pairs`:

`create_ticket(actionType="track-merge", customerEmail=<their email>, details={ track_merge_pairs: [{ master: "<keep>", duplicates: ["<fold-in>", ...] }, ...], customer_note: "<sanitized ask>" })`

For a single merge you may instead use the flat shape
`details.master_track` + `details.duplicate_tracks[]`. If `create_ticket` returns
`{submitted:false, reason:"capture_incomplete"}`, ask the customer for whatever's in
`missing[]` (which track to keep + each duplicate) and retry.

### Step 3 – Reply to the customer

- Confirm you've **filed the request for the team** to review and action. Do **not** say
  "done" / "merged" – you didn't merge anything.
- Set **no timeline** ("the team will take it from here").
- Never echo raw internal ids; keep it to the track names the customer used.

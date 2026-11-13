---
name: muso-ops-collaborators
description: |
  The profile "Collaborators" list and its counts. The table is DERIVED from
  track co-credits — there is no collaborator record to edit or delete. Gives
  the three real levers, the supported rebuild procedure, the counting traps,
  and the red line against direct SQL on catalog_profile_collaboration.

  Use when: a customer or ops asks to remove/hide someone from a profile's
  collaborators list, the list looks stale or wrong, or the collaborations
  count disagrees with the list.

  Triggers: "remove these collaborators", "remove collaborator from profile",
  "hide this person from my collaborators", "collaborator list is wrong",
  "collaborators are stale", "collaborations count wrong", "rebuild
  collaborators", "still showing as a collaborator", "not my collaborator"
depends-on:
  - muso-ops-admin
  - muso-ops-tracks
  - muso-ops-profiles
  - muso-slack-formatter
compatibility: |
  Requires: muso-ops-admin (muso-admin-api.sh) or muso-cli, and Trino
  (postgresql_catalog) for the type-inclusive read. Main gateway only.
metadata:
  version: "1.1"
  source-repo: "Muso-AI/hydra"
  verified-against: |
    live prod reads + rebuild on d5776b6b (2026-07-29); rebuild read-back
    doctrine against industry-data-processing fd2ede01 (#1478), deployed to
    prod in image 20260805-413 (2026-08-05)
allowed-tools:
  - exec
---

# Muso Ops — Collaborators

## The one thing to understand first

**The collaborators list is derived. It is not authored, and there is no
collaborator record to delete.**

A pair (profile A, collaborator B) exists in
`postgresql_catalog.public.catalog_profile_collaboration` **because A and B are
credited on the same track.** The writer walks the profile's current
non-deleted master tracks and counts every co-credited profile on each
(`industry-data-processing/.../fastlane_cube_writers/profile_collaboration_writer.py:115-166`).
The table is hash-partitioned; `bucket = sum(profile_id utf-8 bytes) % 30`.

So "remove this collaborator" is never a delete. It is one of exactly three
levers:

| Lever | How | Notes |
|---|---|---|
| (a) Change the credits | Per-track `DELETE /admin/track/<track_id>/profile/<profile_id>/credits` | The only lever that removes a *backed* pair. See `muso-ops-tracks` § Removal Requests — **never** the bulk `DELETE /admin/profile/:id/credits`, it 200s and changes nothing visible |
| (b) Whole-profile tombstone | the reversible hide-list PR, not an API call | Excluded on both write and read (`_is_tombstoned`, `profile_collaboration_writer.py:178-205`). All-or-nothing. The profile soft-delete endpoint is a REMOVAL and is refused by both wrappers (`MUSO_REMOVAL_NO_SELF_APPROVE`, 2026-11-04) — hiding is a merged list PR a named human lands, and undo is removing the id from both lists |
| (c) Pair-level suppression | **DOES NOT EXIST** | No endpoint, no column, no table. Do not imply it is coming |

Things that look like they should help and **do not**: profile cache clear,
`analytics recalculate`, fastlane triggers. Those refresh the analytics cube,
which is a different table from the one serving this list.

## RED LINE — never write SQL against these tables

**Never propose, draft, script, or execute SQL against
`catalog_profile_collaboration` or `catalog_profile_aggregations`. Not with
approval. Not "just this once". Not as a snippet for a human to run.**

Not because it is forbidden — **because it does not work.**

Every rebuild recomputes the profile's full row set from its current master
tracks and then executes:

```
DELETE FROM catalog_profile_collaboration
WHERE bucket = %s AND profile_id = %s AND NOT (collaborator_id = ANY(%s))
```

(`profile_collaboration_writer.py:239-263`). Any row you hand-delete is
re-inserted, and any row you hand-insert is deleted, by the **next** rebuild,
fastlane write, or offline Spark pass — with no error and no audit trail tying
the reversion to your change. You would have taken production write risk, burned
a second-human approval, told the customer it was fixed, and shipped a change
with a *negative* half-life.

This is not theoretical. On 2026-07-29 the Ops agent proposed a bounded 32-row
DELETE for exactly this request. A rebuild of that same profile then reported
`rowsDeleted: 0` — **every single row it wanted to delete was live and backed by
a current track credit.** All 32 would have come back.

Hydra's database access is read-only by design (Trino `postgresql_catalog`).
Wanting to get around that is itself the signal to stop and escalate.

**If the supported procedure does not solve it, the answer is the honest reply
below or an escalation to the data-platform owners — never a hand-written
mutation.**

## The supported procedure

```
1. Resolve every named person to a profile UUID (see "Name resolution").
2. Read the CURRENT list. Establish, per name: on the page or not?
3. For anyone on the page, find WHY — the shared tracks behind the pair.
4. If those shared credits are WRONG -> remove them per-track
   (muso-ops-tracks § Removal Requests), verify in the credits list.
5. Rebuild the profile:
      POST /admin/profile/<profileId>/collaborators/rebuild   (body {})
6. Re-read the list and report what actually changed.
```

**What rebuild does**: recomputes the profile's rows from current master tracks,
deletes rows the tracks no longer support, and clears the profile API cache.
Synchronous, idempotent, convergent — re-running it is the remedy for a bad run,
so it does **not** need tier-2 approval artifacts
(`api/v1/routers/admin/collaboration_router.py:171-270`).

**What rebuild does NOT do:**

- **It does not touch the other direction.** The delete predicate is scoped to
  one `profile_id`. Rebuilding A removes B from A's page; A stays on B's page
  until B is rebuilt too. Rebuild the other profile *only* if the requester
  actually asked for it — a large collaborator profile means rewriting thousands
  of that person's rows to fix one.
- **It does not fix wrong credits.** It reads current state. Run it only *after*
  the credit edit shows in the credits list.
- **It does not remove a pair backed by a real shared credit.** Nothing does.
- **It does not promise the headline count is *visible* yet.** It now proves the
  count is stored on the primary; the number the requester sees comes from a
  replica. See below.

## The counting traps

There are three different numbers and they routinely disagree. Never quote one
as if it validates another.

1. **`totalCount` from `GET /admin/profile/:id/collaborators`** — this is the
   list the user is scrolling.
2. **Row count in `catalog_profile_collaboration`** — larger, because the admin
   list only returns `collaborator_type = 'artist'` rows. **Organization-typed
   rows are invisible to that endpoint but are really in the table.** Measured
   2026-07-29 on one profile: 151 direct rows = 123 artist + 28 organization,
   and the endpoint returned exactly 123.
3. **`collaboratorsCount` on `GET /admin/profile/:id`** — the header number. It
   is stored separately in `catalog_profile_aggregations` and **is frequently
   stale.** Same profile, same day: header 136 vs 123 countable rows. Its
   denominator matches neither number above: the aggregate counts `artist`
   **and** `professional` rows
   (`collaboration_router.py:72 _COUNTED_COLLABORATOR_TYPES`, mirroring the
   offline `profile_collaborations_count.py` whitelist), while the admin list
   returns artist only.

And one split that explains most disagreements: **the rebuild writes the
primary; the header and Trino both read replicas.** The aggregate is upserted
through `CatalogWriterPostgreClient` (`PG_CATALOG_WRITER_CONNECT_STRING`), the
profile header reads it through `CatalogReaderConnection` (the node-19 replica),
and Trino reads a standby too. A header that lags a *confirmed* write is
replication lag, not a failed upsert — and that, not a broken rebuild, is the
most likely explanation of the 2026-07-29 observation below.

Three traps that follow:

- **The `type` query parameter is silently ignored.** `?type=organization`,
  `?type=artist` and `?type=professional` return byte-identical results —
  core-backend accepts the param and never forwards it. You cannot see the
  organization rows through the admin API at all; use Trino for a type-inclusive
  read.
- **The `type` field in each returned item is the collaborator's own profile
  type, NOT the table's `collaborator_type`.** A row can come back tagged
  `professional` while its `collaborator_type` in the table is `artist`. Do not
  infer table state from the response field — they are different columns with
  the same-sounding name.
- **A rebuild returns two numbers now — compare them, never quote one alone.**
  Until 2026-08-05 the endpoint returned the count it *intended* to write, so a
  correction that never became visible was indistinguishable from one that did
  (measured 2026-07-29: a rebuild answered `collaborationsCount: 123` while the
  aggregations table and the header still read 136 ten minutes later). Since
  Muso-AI/industry-data-processing#1478 it reads the aggregate **twice** —
  `collaborationsCount` re-read from the primary after the upsert commits
  (`collaboration_router.py:105`), and `collaborationsCountVisible` read through
  the profile header's own accessor, i.e. the number the requester will
  actually see (`:161`). Read the pair:

  | Response | Meaning | Action |
  |---|---|---|
  | `collaborationsCount` == `collaborationsCountVisible` | consistent — **not** proof; the reader may have fallen back to the primary | confirm the header on the profile and correlate the fallback log (see below), *then* done |
  | the two differ | write is durable, replica is behind | re-read the header later; escalate replication if it persists |
  | `collaborationsCountVisible: null` | could not be observed — the rebuild still succeeded | re-run; check logs |
  | 502 `aggregate readback mismatch: computed=… stored=…` | the primary does not hold `computed` — the upsert missed, **or** a concurrent legitimate writer (V3 PDP / Spark) changed the row between commit and re-read. The endpoint cannot tell which | never report `computed`; escalate to data-platform quoting **both** numbers |
  | 502 `aggregate write committed but could not be verified` | unproven, **not** failed | re-run; do not assume either outcome |

  **Disagreement is conclusive; agreement is not.** `CatalogReaderConnection`
  falls back to the primary when `PG_CATALOG_READER_CONNECT_STRING` is unset and
  on a transient checkout error, so the two numbers can agree on exactly the run
  where they should not — that fallback logs itself, so correlate before calling
  it clean. When the header is what the requester cares about, confirm it on the
  profile itself before promising anything.

Type-inclusive read (bucket predicate is required — an unbucketed scan of all
30 partitions gets killed by the standby's recovery conflict):

```bash
# bucket = sum(profile_id utf-8 bytes) % 30
muso query "SELECT collaborator_type, count(*) FROM
  postgresql_catalog.public.catalog_profile_collaboration
  WHERE bucket = <B> AND profile_id = '<uuid>' GROUP BY 1"
```

## Name resolution

Resolve every named person to a profile UUID **before any read or write**.

- `muso --env prod profiles search "<name>" --json`.
- **More than one plausible match → STOP and ask the requester for the exact
  profile id or a muso.ai profile URL.** Never pick the highest-popularity
  match. Never pick "the obvious one". A single request routinely yields six
  live "Manuel Gonzalez" profiles that are genuinely different people.
- Echo the resolved list back — `Name — UUID — shared tracks` — and get
  confirmation before mutating anything.
- Collaborator endpoints require the catalog **UUID**. A numeric id is rejected
  `400 Invalid Profile ID`; if you are holding a numeric id you have the wrong
  identifier.
- **Do not treat translations or lookalikes as matches.** Requests arrive with
  browser-translated names ("Proyectos de ley de ataque") and punctuation
  variants ("Young Tru$t" vs "Young Trust"). Report them as unmatched and ask —
  guessing here mutates the wrong person's profile.
- Expect a large share of requested names to be **absent from the list
  entirely**. On 2026-07-29, 16 of 24 requested names had no match in any of the
  151 direct rows, exact or fuzzy. Say so plainly instead of hunting for
  something to remove.

## Honest answer when the pair is backed by real credits

Use this when the collaborator is on the page because a genuine shared credit
puts them there.

> Thanks for flagging this — here is what is actually going on.
>
> Your Collaborators list is not a list we can edit directly. It is generated
> automatically from the credits you and the other person share on the same
> tracks. If you are both credited on a release, the pairing shows up on both
> profiles.
>
> That means there are two possible outcomes:
>
> 1. **The shared credits are wrong.** If you are not actually credited on
>    [track], we will remove that credit, and the collaboration disappears once
>    the list refreshes. Tell me which tracks are wrong and I will check them.
> 2. **The shared credits are correct.** Then I cannot remove the pairing,
>    because removing it would mean removing a credit that genuinely belongs to
>    you. We do not have a way to hide an individual person while keeping the
>    underlying credits accurate — and I would rather tell you that than take it
>    off and have it come back.
>
> [If any named tracks are genuinely wrong, list them here and confirm the plan.]

Rules around the template:

- Never quote an ETA for the refresh. Confirm once you have re-read the list.
- **Never say "removed" until you have re-read the list** and seen it gone.
- Never offer suppression as an upcoming feature. It is not built and has no
  date.
- If the customer disputes credit *ownership* rather than display, that is a
  credits question — route to `muso-ops-tracks` / `muso-audit-profile-credits`.
- Report unmatched names as unmatched. Do not quietly drop them.

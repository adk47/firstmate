# Pair-level collaborator suppression — backend spec

**Status:** proposal, not implemented. Owner: data-platform (industry-data-processing
+ platform-data-processing) with a thin core-backend proxy.
**Written:** 2026-07-29, off a live investigation of profile
`d5776b6b-438c-42f2-bc90-aa9913f423be`.

## Why

Customers ask us to remove specific people from their profile's Collaborators
list while keeping their credits and tracks intact. **Today that is impossible,
and there is no honest partial answer.**

`catalog_profile_collaboration` is derived: a pair (A, B) exists because A and B
are credited on the same track
(`profile_collaboration_writer.py:115-166`). The only exclusion in the whole
stack is a *whole-profile* tombstone (`_is_tombstoned`, `:178-205`). There is no
pair-level anything.

The gap has a concrete cost. On 2026-07-29 a request to remove ~24 named
collaborators produced an Ops proposal for a **32-row direct production DELETE**,
escalated for owner approval. A rebuild of that profile then returned:

```
rowsUpserted: 151, rowsDeleted: 0, collaborationsCount: 123
```

`rowsDeleted: 0` means **every row the plan wanted to delete was live and backed
by a current track credit.** All 32 would have been silently re-inserted by the
next rebuild or offline Spark pass. The supported path could not help, and the
unsupported path could not work.

## Design

### Storage: a new table, not a column

`catalog_profile_collaboration_suppression`. A flag on the serving row dies four
independent ways, any one disqualifying:

1. The offline full-rebuild swaps the table out
   (`platform-data-processing/migrations/dwh_initial_fill/rename_tmp_*.sql`).
2. `_delete_stale_rows` (`profile_collaboration_writer.py:239-263`) physically
   deletes the row the flag rides on — and a flag cannot exist at all for a pair
   with no current row (pre-emptive suppression).
3. The offline upsert overwrites every non-preserved column
   (`platform-data-processing/src/persist/drivers/common/aurora.py:390-398`);
   `preserve_columns` is not configured for this table.
4. No room for audit fields on a serving row rewritten 6-12x/day.

```sql
CREATE TABLE catalog_profile_collaboration_suppression (
    id                uuid         NOT NULL DEFAULT gen_random_uuid(),
    profile_id        varchar(36)  NOT NULL,  -- the page the pair is hidden FROM
    collaborator_id   varchar(36)  NOT NULL,  -- who is hidden ON that page
    bucket            int          NOT NULL,  -- sum(profile_id utf-8 bytes) % 30
    scope             varchar(16)  NOT NULL DEFAULT 'directional',
    group_id          uuid         NULL,      -- links the two rows of a 'mutual' pair
    reason_code       varchar(32)  NOT NULL,
    reason_note       text         NULL,
    reference         text         NULL,      -- ticket / Slack ts
    created_by        varchar(320) NOT NULL,
    created_by_type   varchar(32)  NOT NULL DEFAULT 'operations',
    created_at        timestamptz  NOT NULL DEFAULT now(),
    revoked_at        timestamptz  NULL,
    revoked_by        varchar(320) NULL,
    revoke_note       text         NULL,
    CONSTRAINT cpcs_pkey PRIMARY KEY (id),
    CONSTRAINT cpcs_not_self  CHECK (profile_id <> collaborator_id),
    CONSTRAINT cpcs_scope_chk CHECK (scope IN ('directional','mutual'))
);

CREATE UNIQUE INDEX cpcs_active_uk
    ON catalog_profile_collaboration_suppression (profile_id, collaborator_id)
    WHERE revoked_at IS NULL;
CREATE INDEX cpcs_profile_idx
    ON catalog_profile_collaboration_suppression (profile_id) WHERE revoked_at IS NULL;
CREATE INDEX cpcs_collaborator_idx
    ON catalog_profile_collaboration_suppression (collaborator_id) WHERE revoked_at IS NULL;
```

Surrogate PK + partial unique index gives soft revoke and full re-suppress
history. `bucket` is denormalized so every sweep is PK-targeted — **there is no
index on `collaborator_id`** in the serving table
(`profile_serving_purge.py:36-44`), so a reverse-keyed predicate scans all 30
partitions.

### Directional by default

`scope='directional'` hides B on A's page only. `scope='mutual'` is an explicit,
reason-coded escalation (`legal|harassment|privacy|fraud`) writing two rows under
one `group_id`.

Rationale: the model is directional and asymmetrically indexed (above); consent —
auto-mirroring lets A silently edit B's page and decrement B's headline count;
and it is not a data lie, because the credits still exist on both sides.
Suppression is a display policy on one profile's panel, not a claim the
collaboration never happened. This also matches what customers actually ask for:
"get them off *my* page."

**Document loudly:** with `directional`, X's page still shows the requester.

### Migration

Alembic, `[catalog]` section, `alembic/versions/catalog/`, chained off
`20260601_0001_catalog_baseline.py`. Hand-written and additive (autogenerate is
disabled, `env.py:26-30`). **No `CREATE INDEX CONCURRENTLY`** — it goes through
PgBouncer. Mirror the DDL into
`platform-data-processing/deploy/ddl/catalog/` as documentation-of-record.

### Writer change (small)

In `compute_and_replace`, inside the existing write transaction and before
`copy_upsert`: load active suppressions for the profile, filter them out of
`rows`. `_delete_stale_rows` then removes any pre-existing row for free, because
the keep-list is derived from `rows` — exactly how the tombstone fix works.

### Fail-closed is the whole feature

A suppression read that errors **must abort the write** with a distinct
`suppression_read_failed` reason, added to the fail-loud prefix tuple at
`collaboration_router.py:101`. An empty-set-on-error default republishes every
suppressed pair with no signal — the single highest-value fail-open here. Same on
the Spark side: raise, never fall back to an empty anti-join DataFrame.

### Ship order

1. Migration + model — no behavior change.
2. **Read-side `NOT EXISTS`** in `get_profile_collaborator_v2.generate_main_query`
   — put it in the WHERE so `count_query` sees it too. Suppression becomes
   user-visibly effective and *cannot* fail open, before any writer knows the
   table exists.
3. Admin endpoints (suppress / list / revoke) + a PK-targeted sweep job.
4. Online writer filter.
5. core-backend proxy + routes (copy `rebuildProfileCollaborators.js` +
   `src/apis/index.w.js:57`, `Acl.allow(['admin'])`, derive the actor from
   `req.requester` — never from the client).
6. **Spark `build_full_artifact` anti-join — required, not optional.** A third
   writer (`analytics_profile_operations.py:2316-2319`, `:2386-2389`) copies
   Mongo's `collaborations_count` over the corrected value, so the count is only
   truthful if the filter lives in the artifact.

### Known non-bug to document in the endpoint

Suppressing an `organization` collaborator does not move `collaborations_count`
— that count spans `artist|professional` only (`collaboration_router.py:32-35`).

## Open item found during this investigation

`_sync_aggregations_collaborations_count` (`collaboration_router.py:52-85`)
**returns the value it SELECTed, not a read-back.** The endpoint therefore
reports success whether or not its upsert landed. Observed 2026-07-29: a rebuild
returned `collaborationsCount: 123` while both
`catalog_profile_aggregations.collaborations_count` and the admin profile header
still read `136` ten minutes later. Needs data-platform triage independently of
this feature; a read-back before returning would make it self-evident.

## CLI / ops surface (blocked on the above)

```
muso profiles collaborators suppress   <profileId> --collaborator <id>... --reason <code>
muso profiles collaborators unsuppress <profileId> --collaborator <id>...
```

Unlike `rebuild` (convergent, plain write tier), suppression is operator-chosen
and **non-convergent** — a rebuild will not restore an accidental suppression and
will not clear a malicious one. It belongs in muso-cli's `approvalPatterns` when
it lands. Do not register stub subcommands before the endpoint exists:
`agentdocs.go` walks the live cobra tree, so anything registered is taught to
agents as a real capability.

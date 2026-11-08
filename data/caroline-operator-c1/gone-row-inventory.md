# The three `GONE` erasure rows: is the data erased, or only the page?

Measured 2026-11-08 on node-8 against the **core app database** (`MUSO_DB_PROD_CORE_DSN`,
`dbname=core`, read-only user `hydra_ro`) and the catalog read model (Trino,
`postgresql_catalog.public`). This answers firstmate's inbox 169 question, which decides
whether a statutory letter may be sent at all.

**Answer: none of the three is case (i).** In every one, the profile row is gone from the
catalog and the public page 404s, but personal data still exists in the core database. Under
the ruling — the letter path opens ONLY for (i) — **no letter may be sent for any of these
three until the data is actually erased.**

## What `GONE` actually means

`scripts/gdpr_pipeline/identity.py:182` — "the catalog and the public page both answer 404 and
this id was never on a hide list: removed outside the hide process (deleted or merged); a
person confirms what happened before any letter". It is decided by `sources.page_facts` →
`profile_doc(pid)` (admin API 404 → None) **and** `public_status("profile", pid) == 404`.

So `GONE` is a **page** check. It has never been a data check. That is why the question was
the right one to ask.

## The rows

| # | requester | profile ids | verdict |
|---|---|---|---|
| 147 | Zyon Khalifa | `303867d9-e744-452d-9d58-dda7a7002a3b` | **(ii) and (iii)** |
| 148 | MPro | `4c7dd32d-55dd-4973-b4bc-841704ef4f2b` | **(ii)**, minimal |
| 149 | Sam Scotland | `8ee1f3c0-f00e-492a-a853-18565fe7b4b7`, `ba5455c3-fe5a-4630-b5de-1c7c5dbb6f45` | **(ii)** |

`#313` Dara Dler Tawfik is **not** a `GONE` row — it is `ASK_LINK` with `pages=[]`, one ask
already attempted (state `unknown`). `#150` Kirk Johnston is `JAN_REVIEW` (dmca_takedown) and
is Jan's scope call, not this inventory's.

## The checks, per row

### #147 — (ii) and (iii)

- `catalog_profile`, `catalog_profile_track`, `catalog_profile_collaboration`,
  `matvw_profile_credit`, `catalog_member`, `catalog_publisher_profile`: **0 rows**. The
  catalog profile is gone.
- `catalog_profile_aggregations`: 1 row, every field zero/NULL — an empty counter keyed to the id.
- `catalog_label_profile`: **5 rows still carry the name** ("Zkai") alongside five company
  names. Personal data, in the catalog.
- Core `users`: the owning user row **still exists** with email, first/last/full name, a Google
  subject id, and a signup record holding an IP address and country. Not erased.
- Core `claiming`: 1 row, `status=processed`, carrying a **personal Instagram handle** in
  `verificationLinks`, plus `userId` and `teamId`.
- Core `resolved_user_ad_profiles`: 1 row — claimed flag, stream count, credit count, primary
  genre, roles, last-active timestamp. A behavioural profile.
- Core `profile_analytics_stats_history`: 1 row.
- Core `profile_views`: 4 rows with this id as `viewed_profile_id`.
- **(iii) also true**: the same user account owns a **live successor profile**
  `bb908b26-327a-4f63-9012-04be09fa017d` (36 credits, 25 collaborations, 4 years active), and
  the view rows show that successor viewing the old id. The data did not disappear; it moved.

### #148 — (ii), minimal

- Catalog: 0 rows everywhere except one zeroed `catalog_profile_aggregations` row.
- Core: **no `users` row** links to this id (checked `neptuneProfessionalId` and
  `representationProfileId`), no `claiming` row, no credits, no tracks.
- Core `profile_views`: **1 row** with this id as `viewed_profile_id`.
- So the only surviving record is a view event. That is still a record, and it is still not
  erased — but it holds no name, email or contact detail.

### #149 — (ii)

- Catalog: 0 rows for both ids except one zeroed aggregation row for `8ee1f3c0`.
- Core `users`: the owning user row **still exists** with email, first/last/full name, a Google
  subject id, and a signup record holding an IP address and country. Linked via
  `neptuneProfessionalId = ba5455c3-…`.
- Core `claiming`: 1 row, `status=processed`, `reason="created by user"`, with `userId` and
  `teamId`.
- Core `profile_views`: 1 row with `8ee1f3c0` as `viewed_profile_id`.
- No same-name profile exists in the catalog, so (iii) does not apply here.

## What was NOT found

- **No erasure was ever attempted.** `messaging_erasure_pending` has 0 rows for either user,
  and it is the only erasure-shaped table in the core database.
- **No merge ledger row.** `profile_merges` has 0 rows for all four ids, so the (iii) finding
  for #147 rests on the shared `userId` and the view rows, not on a recorded merge.
- **No soft-delete flag on `users`.** The table has no `deletedAt`; the rows are live.

## What this means for the deadline

All three are due 2026-11-09. None can be answered with a letter today, because a letter may
only describe a deletion that happened, and in all three the data is still there.

The work that would unblock them is a **prod write on the erasure surface** — deleting or
anonymising the `users` row, the `claiming` row, the `resolved_user_ad_profiles` row, the
`profile_analytics_stats_history` row, the `profile_views` rows, and (for #147) the five
`catalog_label_profile` rows and the successor profile's ownership. That is a captain
decision, and it is the one to take to him with this inventory.

A late honest letter beats an on-time false one.

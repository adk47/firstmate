# PG downsize and ClickHouse cutover: what is measured, 2026-11-13

Lane `pg-downsize-ch-cutover-f1`. Every number below was read from a live system between
2026-11-13T00:15Z and 02:33Z (ev35 to ev39: 05:24Z to 05:27Z) and names its evidence file in `evidence/` (the `.sql` is the query, the
`.out`/`.csv`/`.json` is the result with its run time in the header). All sessions were read-only
(`default_transaction_read_only=on`, `kubectl get`, `clickhouse-client --readonly 1`, OVH `GET`).
No DAG was triggered, paused or unpaused and no PG setting was touched.

Hosts: **n17** = `node-17-pg-primary-writer` (10.0.0.17, PG 17.9 primary), **n19** =
`node-19-pg-replica-and-builder` (10.0.0.19, the only replica).

## The answer in six lines

1. **Neither zero is reachable in November.** Analytics-family databases are 89.3% of all blocks PG
   read from disk in the last 7.1 days (both hosts) and 99.3% of all tuples written (ev30, ev31).
2. **V4 does not move analytics off PG today. V4 cubes land in PG.** `v4_olap_cubes` builds 14 cube
   families and stages each as `cube_analytics_<x>_<N+1>` in PG `olap`; no `cube_analytics_*` table
   exists in any ClickHouse cluster (ev21). The ClickHouse tier built to take them, CHI
   `analytics-prod`, is `spec.stop=yes`, 0/0 pods, no PVC (ev20).
3. **V4 is itself one of the largest PG readers.** `v4_stats_facts_load` re-reads the stats tables
   from n19 every day: about 195.7 B rows of the 450.8 B rows n19's `stats` reads have returned (ev10, ev09).
4. **The dominant reader and cube writer is the IDP fastlane**: 564 pods (ev22). The switch that makes
   it yield to V4 exists and is off everywhere: `cube_suffixes.fastlane_yield = false` for 21 of 21
   families (ev17), `v4_fastlane_yield` paused with 0 runs (ev18), `IDP_FASTLANE_YIELD_TO_V4` set on no
   deployment (ev22).
5. **What can be given back in November: node-49 and node-50, $5,978/month pre-tax**, and only if the
   ticker cutover passes its gate and the fastlane is off the boxes by Fri 27 Nov (see Sequence). They are not idle: they run 380 of the 400
   `industry-proc-fastlane-v2` pods and 8 of the 12 ClickHouse pods that still serve ticker reads (ev23).
6. **The PG pair cannot be downsized at the 1 and 2 December renewals.** n17 is at 81% of 14 TB,
   writes WAL at 7.52 TiB/day and had `io full avg60 = 31.77` when sampled (ev24, ev28). The earliest
   renewal a smaller pair can land on is 1 and 2 January; that is a money decision for the captain.

## 1. What still reads PG for analytics

### 1a. Read volume, analytics versus transactional

"Analytics family" = databases `stats`, `olap`, `catalog`, `analytics`, `industry_calculations`.
"Transactional" = `core`, `feed`, `authentik`, `kong`, `platform_auth`. "Platform" = `airflow`,
`hive_metastore`, `iceberg_catalog`, `data_steward`, `postgres`.

**A quarter could not be measured** (section 7). The longest window that exists is 7.1 days:
Prometheus `increase(pg_stat_database_*[91d])`, TSDB lowest timestamp 2026-11-06T00:00:00Z, run
2026-11-13T02:17:38Z (ev30, split computed in ev31).

| Measure, 7.1 days | Hosts | Total | Analytics family | Transactional | Platform |
|---|---|---|---|---|---|
| Blocks read from outside shared buffers | n17 | 1.033e11 | 85.7% | 14.1% | 0.2% |
| Blocks read from outside shared buffers | n19 | 9.872e10 | 93.0% | 7.0% | 0.0% |
| Blocks read from outside shared buffers | both | 2.021e11 | **89.3%** | **10.6%** | 0.1% |
| Tuples scanned (`tup_returned`) | both | 2.061e12 | 40.4% | 57.1% | 2.5% |
| Tuples fetched (`tup_fetched`) | both | 8.993e11 | 40.0% | 59.8% | 0.1% |
| Commits | both | 1.139e10 | 95.3% | 3.3% | 1.2% |

The two views disagree and both are true. By tuples, transactional is larger (`core` on n19 is 31.3%
of all tuples scanned, `feed` on n17 25.7%). By disk blocks, analytics is nine tenths, and disk is what
is saturated: `stats` alone is 75.3% of all blocks read on both hosts.

Shorter measured window, two `pg_stat_database` snapshots 6,359 s apart (A 00:19:30Z, B 02:05:29Z;
ev12, deltas in ev28):

| Host | Blocks read | Rate | Share by database |
|---|---|---|---|
| n17 | 1,817,647,645 | 7,851 GiB/h | stats 57.9%, core 28.0%, olap 7.3%, analytics 5.2%, catalog 1.2% |
| n19 | 1,483,403,048 | 6,407 GiB/h | stats 84.3%, core 11.1%, analytics 3.3%, catalog 0.6% |

### 1b. Top consumers, each mapped to its issuer

Cumulative columns are `pg_stat_statements` totals folded by relation (ev16; n17 `stats_reset`
2026-06-20, n19 2026-06-21; lossy, see section 7). Window columns are the 1.77 h A to B delta per
statement (ev13, ev28). Query text is in ev29. "Named by session" means `application_name` was sampled
against the `query_id` (ev15); "by code" means the text was matched in the service repo.

| # | Consumer | Issuer | How identified | Cumulative | In the 1.77 h window |
|---|---|---|---|---|---|
| R1 | `track_daily` per-profile window reads (LOCF and delta windows; queryids -1553054039769019196, 2214863175886206164, -2037529466112218811, -709929211709219153, -8850958813059235032) | IDP fastlane cube writers: `industry-proc-fastlane-priority` (150 pods) and `-mega` (10) on n19; `industry-proc-fastlane-v2` (400 pods) on n17 through pgbouncer | Named by session on n19 (ev15). By code: `fastlane_cube_writers/{dates_cube_writer,industry_stat_profile_writer,profile_collaborator_cube_writer,profile_credit_writer,locf_intervals}.py`. v2's reader secret is the primary's bouncer (ev22) | n19: 167 M calls, 149.6 B rows, 14,817 exec-hours, 424 B blocks | n19: 39.0 of 43.5 `stats` exec-hours (90%), 973.8 M of 1,228 M blocks (79%). n17: 11.1 exec-hours |
| R2 | V4 daily facts load: `track_daily WHERE date = $1`, ctid-range extracts of `profile_track`, `album_track`, `track`, and whole `analytics_video_tiktok` / `analytics_link_spotify` | Airflow DAG `v4_stats_facts_load` (SparkApp `v4-stats-facts`, daily 06:23Z, 14 of 14 runs ok in 14 days, ev18) | By query shape (quoted identifiers, ctid ranges) plus the DAG's docstring. Not named by session | n19: 70.46 B + 45.54 B + 26.88 B + 14.20 B + 19.8 B + 18.8 B = about 195.7 B rows | Did not run in the window |
| R3 | `analytics_link` by `track_id = ANY(...)` (569286942632052879) and per-track-source CTEs (-5173349918025204224, -3551118359116872780) | IDP fastlane (lifetime totals) | Named by session: `industry-proc-fastlane-priority` (ev15) | n17: 27.9 M calls, 97.4 B rows, 3,522 exec-hours, 86.5 B blocks. n19: 1.2 M calls, 15.7 B rows | n17: 2.0 exec-hours, 57.7 M blocks |
| R4 | `no_video_row` eligibility CTE over `analytics_link` and `analytics_video` (1094077187582001326) | IDP catalog sync, `analytics_profile_operations.py:2943` (`industry-proc-catalog-v2`, 40 pods) | By code | n17: 15.4 M calls, 1,801 exec-hours, 244 B blocks | n17: 2.3 exec-hours, 237.8 M blocks (31% of all `stats` blocks pgss saw on n17) |
| R5 | `profile_track` lookups by profile | IDP fastlane and catalog sync | By code | n17: 117.5 M calls, 41.9 B rows. n19: 66 M calls, 76.7 B rows, 1,013 exec-hours (includes R2's extract) | not split out |
| R6 | Served cube views in `olap` on n19: `cube_analytics_track_view`, `_industry_stat_profile_view`, `_profile_view`, `_album_view`, `_collaborator_view`, `_profile_dates_view` | `industry-api` (3 pods), customer read path | By code (`api/v1/routers/profile/get_profile_stats.py`); role `muso-stats-pg` on `olap` | 31,435,509 / 14,345,450 / 12,425,905 / 115,856 / 110,549 / 38,440 calls; 85 exec-hours on the track view | 167,231 calls, 0.1 exec-hours |
| R7 | `v4_poc.paid_tracks JOIN public.track_daily` and other `v4_poc` reads | `ticker-api-prod` / `ticker-poc-api` (V4 ticker), role `v4poc_rw`, `PG_HOST=10.0.0.17` (ev23) | Named by session (ev06, ev15) | 180,793 calls, 27 exec-hours since 2026-11-12 | 2.6 exec-hours, 92.2 M blocks on the primary |
| R8 | `catalog_profile_aggregations`, `catalog_member` | IDP API and catalog workers | By code | n19: 383 M calls / 1.41 B rows; 1.20 B calls / 433 M rows | not split out |
| R9 | `credit_score_charts`, `credit_score_charts_entries`, `profile_track_milestone` in `industry_calculations` | charts and milestone read path, role `muso-ic-pg` | By role and relation only | n19: 24.7 M, 22.9 M and 0.9 M calls | 17,241 calls |
| R10 | `analytics.entities`, `filler_query_stalest_after`, `spotify_playcount_claims` | analytics-worker (capture scheduler; `analytics-filler` on n19) | Named by session (ev11) | n19: 1.01 B rows; n17: 352 M + 348 M rows | n17 `analytics`: 4.1 exec-hours |

Top by **calls** is not an analytics query at all: `SELECT $1` from role `muso-analytics`, 25.4 B calls
on n17 (ev04), and `BEGIN`/`COMMIT`/`DISCARD ALL` at 77.9 B (`analytics`) and 35.0 B (`stats`) (ev02).
That is analytics-worker's and pgbouncer's connection chatter.

Transactional consumers, for contrast: `core` (core-backend; 489 `core-paid-ro` sessions on n19,
ev11), `feed`, `authentik`, `kong`, and Airflow's own metadata (4.4 B read calls, 114 exec-hours, ev02).

## 2. What still writes PG for analytics

Tuples written on n17 in 7.1 days: 1.331e10, **99.3% analytics family** (stats 41.8%, olap 30.5%,
analytics 14.0%, catalog 7.8%, industry_calculations 5.1%); transactional 0.5% (ev30, ev31).
WAL in the 1.77 h window: 608,609,368,184 bytes = 91.3 MiB/s = **7.52 TiB/day** (ev12, ev28).

WAL per writer is the cumulative `pg_stat_statements.wal_bytes` (ev05, ev16), with each entry's own
`stats_since`; window WAL is from ev28.

| # | Writer | Target | Issuer | Cumulative WAL | Window WAL |
|---|---|---|---|---|---|
| W1 | Batched `analytics_link` upsert (`WITH v AS (SELECT * FROM unnest(...))`, queryids -3793548785045396670, -3206784974791733282) | `stats.analytics_link` | IDP industry-worker (`industry-worker-v2` 80 pods, `-medium-v2` 50, `-backlog` 20), `processors/analytics/batch_upsert_engine.py` | 18 TB + 8,469 GB since 2026-10-12 | 87.2 + 27.7 = 114.9 GiB |
| W2 | Other `analytics_link` and `analytics_video` updates | `stats.analytics_link`, `stats.analytics_video` | industry-worker (named by session for the paired reads, ev15) | 2,968 GB + 901 GB | part of `stats` 197.9 GiB |
| W3 | `entities` update and upsert | `analytics.entities_p_*` | analytics-worker, role `muso-analytics` | 5,700 GB since 2026-09-23 | 38.4 GiB |
| W4 | Fastlane cube writers: `COPY _bu_stage`, `_collab_cube_stage`, `_dates_cube_stage`, deletes and inserts on `cube_analytics_*` | `olap` (collaborator_624 829 GB, profile_dates_640 253 GB, track_626 about 44 GB, credit_1014 78 GB, `_bu_stage` 286 GB) | IDP fastlane, `helpers/bulk_upsert.py`, `fastlane_cube_writers/*` | `olap` write statements total 1,206 GB, plus 1,674 GB carried by the writer's own `SELECT COUNT(*)` checks on `cube_analytics_track_626_*` (ev34) | 14.0 GiB; 100.1 M tuples written |
| W5 | Profile to track sync: `_pt_sync` temp table, `DELETE FROM profile_track` | `stats.profile_track` | IDP catalog sync, `analytics_profile_operations.py:1809` | 646 GB + 871 GB | not split out |
| W6 | Milestones upsert | `industry_calculations.profile_track_milestone` (721 GB table) | IDP fastlane `profile_milestone_writer.py` | 645 GB since 2026-10-13 | 3.2 GiB |
| W7 | Catalog bucket stage | `catalog.catalog_profile_track_N`, `_collaboration_N` | IDP catalog-v2, `helpers/bulk_upsert.py` | 198 GB | 1.0 GiB |
| W8 | `track_daily` upserts | `stats.track_daily` (2,037 GB, 221 partitions) | role `muso-stats-pg`; issuer not identified beyond the role | 42 GB since 2026-10-12 | not split out |
| W9 | V4 writers | `stats.v4_poc` (role `v4poc_rw`, ticker-api); `olap` staged cube generations (role `v4_olap_writer`) | `ticker-api-prod`; `v4_olap_cubes` stage step | 2.2 GB; `v4_olap_writer` had 61 transactions on record | 0.4 GiB |

Reads on the primary write WAL too. Seven `SELECT COUNT(*) FROM cube_analytics_track_626_<period>`
statements carry 222 to 254 GB of WAL each, 1,674 GB together since 2026-10-15 (ev34), and read
statements in `stats` carry 4,659 GB (ev02). I did not verify the mechanism; a read that cleans up
pages left by the cube writers' delete-and-insert churn would produce it. Moving those reads off the
primary removes that WAL with them.

Only 45% of the window's WAL (about 255 of 566.8 GiB) is attributed to a statement by
`pg_stat_statements`. The rest is not attributable from this source (section 7).

## 3. Map to V4 and ClickHouse

ClickHouse tables are from `system.tables` on shard 0 replica 0 of each cluster (ev21). DAG state is
from the Airflow metadata DB (ev18). Code is `platform-data-processing-v4` `origin/main` 31e24067 and
`industry-data-processing` `origin/main` 8ae9c1dc.

| Consumer | ClickHouse table and V4 job today | Gap |
|---|---|---|
| R1, W4 cube families `industry_stat_profile`, `industry_stat_profile_roster`, `credit`, `profile`, `credit_dates`, `profile_dates`, `list`, `list_dates`, `list_profile`, `list_profile_dates`, `list_track`, `list_track_dates`, `track`, `album` | **No ClickHouse table.** V4 job exists: `v4_olap_cubes`, one SparkApp per family (`v4-cubes-<family>`), but its output is a PG table in `olap` | The V4 build replaces the fastlane *writer*, not PG. Last successful `v4_olap_cubes` run: 2026-10-29 02:15Z; 14 days: 2 runs, 0 ok, 1 failed, 1 running since 2026-11-11 05:21Z. Only 4 families are V4-promoted (`credit` 10-11, `list` 10-05, `list_dates` 09-11, `profile` 11-10); 17 never were (ev17) |
| R1, W4 family `collaborator` (1,014 GB served, the largest cube) | None | No V4 SparkApp in `CUBE_APPS`, no staged generation, no ClickHouse table |
| R6 `/v1/profile/{id}/stats` (`cube_analytics_industry_stat_profile_view`) | `ticker_prod.cube_industry_stat_profile`, job `v4_industry_stat_profile_cube` | Table has **0 rows**; DAG paused, 0 runs. Its gate refuses on the default source (the DAG's docstring records 219 of 300 profiles rendering lower on 2026-09-05); it needs mirror `calc.cube_analytics_industry_stat_profile_pg_served` (`v4_industry_stat_profile_serving_mirror`, running) as source. Reader switch `SHADOW_CH_CUBE_VIEW_RULE` is set on no deployment |
| R6 `cube_analytics_profile_view` | `ticker_prod.cube_profile`, job `v4_profile_cube_ch` | **Table does not exist** in ClickHouse. DAG paused, 0 runs ever; its DDL (`platform-ticker` `118_profile_cube.sql`) is not applied |
| R6 track, album, collaborator, profile_dates views | None | No table, no job |
| R1 windowed stats (`cube_analytics_stats_windowed_view`) | `ticker_prod.rollup_1d_local` (578,180,399 rows on shard 0) behind views `cube_windowed_stats_locf_view` and `cube_windowed_stats_exact_view`; fed by Kafka engines `kafka_analytics_high` / `kafka_analytics_medium` and the `mv_*` chain, not by an Airflow job | Mapped in `industry-api` (`SHADOW_CH_VIEW_MAP`) but `SHADOW_MIRROR_ENABLED=false` (ev22). `rollup_1d_local` is 578 M rows against 5.83 B live rows in PG `track_daily` (ev07): it is not the full history. `processed_track_daily_local` has 0 rows |
| R2 V4's own facts load | Iceberg `industry.matvw_stats_{track,profile_track,album_track,track_daily}` plus `analytics_video`, `analytics_link`, job `v4_stats_facts_load` | This job *is* the PG reader. It stops reading PG only when the facts have a source other than PG `stats` |
| R3, R4, R5, W1, W2, W5 capture state (`analytics_link`, `analytics_video`, `profile_track`) | `ticker_prod.raw_events_local` (86.8 M rows) and `catalog_observe_local` receive the same events from Kafka; job `v4_analytics_link_extract` copies PG to Iceberg | `v4_analytics_link_extract` is paused, and it reads PG. Nothing replaces PG as the place industry-worker judges and stores a link's current value |
| R7 ticker-api `v4_poc` | `ticker_prod.dim_paid_entities`, `entity_set_snapshots`, `profile_box_stats` already hold the ClickHouse side | ticker-api still joins `v4_poc.paid_tracks` to PG `track_daily` on the primary |
| R8 catalog aggregations and members | No ClickHouse table. Jobs `v4_catalog_profile_aggregations_extract`, `v4_catalog_member_extract` (14 of 14 ok) copy PG to Iceberg | Extracts read PG; serving stays on PG |
| R9, W6 charts and milestones | No ClickHouse table. Jobs `v4_charts_refresh`, `v4_charts_weekly`, `v4_milestones` (5 ok, 9 failed in 14 days) | Output lands in PG `industry_calculations` |
| R10, W3 analytics-worker `entities` | None | Capture scheduler state. No V4 or ClickHouse design found in either repo |

Ticker ClickHouse itself is mid-cutover: service `clickhouse-ticker-prod` still selects the old CHI
`ticker-prod`, and `ticker-api-prod` reads through it (ev23). The 12 `ticker-tier` hosts serve no reads. For the
ingest and rollup tables they are not a second copy: they are extra replicas of the same replicated
tables as the old hosts (same Keeper path, 4 of 4 replicas active on shard 0, queue 0, delay 0; ev35).
`dim_paid_entities` and `nowcast_rate` are different: on the tier they are separate, unreplicated
tables filled by the tier's own refreshers, while the old cluster still runs its own five (ev36).

## 4. Giveback sizing

Prices are OVH plan plus options, pre-tax, per month, read from the OVH API at 02:05Z and 02:15Z
(ev25, ev26). No server has `deleteAtExpiration` set or a termination date. Fleet total: 49 servers,
$26,569/month pre-tax.

| Machine | Role today (measured) | Monthly | Next billing | Returnable when |
|---|---|---|---|---|
| node-49-PDP | 190 `fastlane-v2` pods, 8 `raw-v2`, 4 old `chi-ticker-prod` pods; requests 29% CPU, 60% memory | $2,989 | 2026-12-01T14:38Z | Old ticker CHI retired through the gate in section 5 **and** `fastlane-v2` off the box |
| node-50-PDP | 190 `fastlane-v2` pods, 9 `raw-v2`, 4 old `chi-ticker-prod` pods, hive-metastore, Longhorn CSI | $2,989 | 2026-12-01T05:56Z | Same |
| node-17 (n17) | PG primary; 96 threads, 503 GiB, 14 TB RAID0 at 81% | $1,768 | 2026-12-01T22:03Z | Downsize, not cancel: see below |
| node-19 (n19) | PG replica; 64 threads, 503 GiB, 21 TB RAID0 at 55%; also runs Vault, elasticmq, zot | $2,018 | 2026-12-02T02:46Z | Downsize with n17 |
| node-69-ch, node-70-ch | Labelled for `analytics-prod` (stopped, empty). Each runs one `keeper-prod` member, 2 of the 3 | $361 each | **2026-11-14T15:56Z and 16:16Z** | Not returnable: they hold ticker Keeper quorum. They renew tomorrow with no action |
| node-29-PDP | Airflow, Spark, 4 old ticker CH pods, 1 `keeper-prod` member | $2,764 | 2026-12-02T03:37Z | Not this month |
| node-46/47/48/52/53/54 | `ticker-tier`, 2 CH pods each | $289 each | 1 and 2 Dec | Keep: they become the ticker read path |

**Milestone A, node-49 and node-50: $5,978/month.** Neither condition is met today. `fastlane-v2` requests
1 GiB per pod (ev33), so the 380 pods on those two boxes need 380 GiB of requested memory somewhere
else, or the deployment has to shrink. It is pinned at 400 by a KEDA `paused-replicas` annotation
above its own 230 to 280 range (ev33).

**Milestone B, PG pair downsize: $3,786/month today.** The target pair in the house wiki
(2 x ADVANCE-4, about $1,028 each, recorded 2026-10-13) would free about $1,730/month. I did not
re-quote that price or check stock. What n17 holds (ev01, ev32):

| Database | Size | Leaves PG when |
|---|---|---|
| `olap` | 3,104 GB: served cubes 2,318 GB (collaborator 1,014 GB, track 956 GB), staged 313 GB, neither served nor staged 461 GB | cubes are served from ClickHouse |
| `stats` | 3,039 GB: `track_daily` 2,037 GB, `profile_track` 175 GB, link and video tables about 530 GB | `track_daily` has another home; capture state has no plan |
| `industry_calculations` | 2,186 GB: `profile_track_milestone` 721 GB | milestones and charts leave PG |
| `catalog` | 1,886 GB | no plan found |
| `analytics` | 181 GB | no plan found |
| Transactional and platform (`core` 135 GB, `feed` 110 GB, the rest under 10 GB) | about 252 GB | stays |
| Eight `muso-*-dev` copies on the prod primary | about 83 GB | could move at any time |

With `olap` and `track_daily` gone the databases would still total about 5.6 TB. A box sized for the
transactional remainder needs all five analytics-family databases gone.

Disk that can be freed without moving anything, all of it DDL: 461 GB of cube generations that are
neither served nor staged (208 leaf tables, ev32), about 40 GB of `catalog.audit_stats_backup_*`,
19 GB `backup_profile_track_milestone_N` (last read 2026-06-22) and 21 GB `stg_N` (last read
2026-07-31) (ev07). This buys headroom, not a smaller box.

## 5. Sequence for the rest of November

Today is Fri 13 Nov. Dates are the latest each step can land and still make the 1 December renewals.
Sign-off follows the standing fences: money, irreversible actions and DDL are the captain's; reversible
config belongs to the owning lane.

| Date | Consumer retired | Change | Machine freed | Revert | Signs off |
|---|---|---|---|---|---|
| Tue 17 Nov, latest Fri 20 | None; precondition for the read switch | Runbook S6: the small refreshers and the publisher move to tier 0-0 (`cutover.sh STEP=singletons`) | None | The runbook's S6 reverse: drop the tier's copies, prove them gone, then restart the old cluster's views | Ticker lane |
| Wed 18 Nov, latest Mon 23 | Ticker reads on the old CHI | Runbook S7: merge https://github.com/Muso-AI/H-DevOps/pull/4525 (open; ticker clients to `clickhouse-ticker-tier`) | None yet | Revert that PR and redeploy. The old hosts stay in the replica set through the soak | Firstmate merges; ticker lane posts the S6 proof first |
| 72 h from the actual S7 time | None | Runbook S8: soak with zero stop-rule breaches, plus gates G1 to G3 below | None | The S7 reverse | Ticker lane posts the reading |
| Mon 23 Nov, latest Thu 26 | The old `chi-ticker-prod` (12 pods) | Runbook S9, first half: `spec.stop` the old CHI (https://github.com/Muso-AI/H-DevOps/pull/4565, open; PVCs and PVs kept) | 8 CH pods off node-49/50, 4 off node-29 | `stop: "no"`; the data is still on disk and the replicas are still registered | Firstmate merges on the S9 GO line, only with G1 to G3 passed |
| At least 24 h after the stop; latest Fri 27 | The old replicas' Keeper metadata | Runbook S9, second half: `SYSTEM DROP REPLICA` for the 12 old names | None | None from Keeper. The restore path is the backup named in G3 | **Captain** (irreversible) |
| Wed 18 Nov, gate | Nothing; this is the precondition for every yield | One complete `v4_olap_cubes` run, then a daily one | None | Not applicable | V4 lane |
| Mon 23 Nov | Fastlane writers and their `track_daily` window reads for `credit`, `list`, `list_dates`, `profile` (the 4 V4-promoted families) | `v4_fastlane_yield` with `{"family":…, "yield":true, "execute":true}` per family, then `IDP_FASTLANE_YIELD_TO_V4` on the fastlane deployments | None directly; cuts R1 and W4 | `yield:false` (always allowed) and the env var off | Firstmate for the env change, captain for go |
| Wed 25 Nov | `fastlane-v2` on node-49/50 | Lower the pinned replica count to what the yielded families allow and move the remainder off the two boxes | Empties node-49/50 of fastlane | Restore the replica count and the node preference | Fastlane lane; captain if a customer latency guardrail is hit |
| **Fri 27 Nov**, last safe day Mon 30 | None | Set terminate-at-expiry on node-49 and node-50, only after G3 | **node-49, node-50: $5,978/month from December** | Clear the mark before 2026-12-01T05:56Z | **Captain** (money) |
| Any day | None | Drop the 461 GB of unserved, unstaged cube generations and the listed backup tables | No machine; about 540 GB on n17 | None | **Captain** (DDL) |
| By Mon 30 Nov | None | Decide whether cubes are to be served from ClickHouse on node-69/70, and unfence the DDL for it | None in November | Not applicable | **Captain** |
| 31 Dec (n17), 1 Jan (n19) | PG as the cube store | Order the smaller pair and mark the old one | n17, n19 replaced: about $1,730/month | Clear the marks before expiry | **Captain** (money) |

### Acceptance gate for retiring the old ticker cluster

The ticker rows follow the existing runbook (`H-DevOps` `docs/runbooks/ch-tier-move-2026-10.md`,
`origin/main` e40b1bd91e). Its last dated plan put S6 on 3 Nov, S7 on 5 Nov and S9 on 9 Nov. Measured
today, none of the three has happened: none of the five refreshers on the old cluster is disabled,
tier 0-0 runs only its two local ones, `ticker-api-prod` reads the old Service and `ticker-prod` has no stop
flag (ev36, ev37). The dates above are that plan moved forward, not new steps.

The runbook's own gate for S9 is the 72-hour soak. Three more are required here before the stop, and
the `DROP REPLICA` waits at least 24 hours after it. The three gates and the 24-hour hold are this
report's proposal, not the runbook's; the ticker lane owns the wording.

- **G1, the tier alone holds a complete copy of every replicated table.** On all 12 tier hosts, for
  every replicated table: `is_readonly = 0`, `queue_size = 0`, `absolute_delay = 0` and two active
  tier replicas per shard, read from `system.replicas`; and the part-hash comparison the runbook
  already uses (`scripts/ch/tier-pilot/parity.py`, through `verify.sh`) passes for every shard, tier
  against old. Row counts are not the test. The two clusters showed 578,180,399 and 578,180,317 rows
  in `rollup_1d_local` at 00:25Z (ev21), and they are replicas of one aggregating table (ev35), where
  a replica's row count moves with merges and in-flight inserts. `dim_paid_entities` on the old host
  read 212,124,418 rows at 00:25Z and 112,301,983 at 05:25Z (ev21, ev36). A row count shows parity
  in neither direction.
- **G2, the tier answers the same as the old cluster for what is not replicated.**
  `dim_paid_entities` and `nowcast_rate` are computed separately on each side (ev36), so replication
  proves nothing about them. Required: the same key set and the same per-key values on both sides
  read with `FINAL`, after a refresh has completed on both; and the same ticker-api requests sent to
  both Services for a fixed sample of at least 300 paid profiles, with zero differences that a
  re-read after the next refresh does not clear. This has to run during the soak, while both
  clusters still answer.
- **G3, a restore point that does not live on the boxes being returned.** Today the only ClickHouse
  backup job for this data is `ticker-prod-ch-backup`, daily at 03:51Z, and its records are on the old
  cluster's host: 330 created and 6 failed since 2026-10-25, newest 2026-11-13 04:14Z (ev38, ev39).
  Tier 0-0 has none on record (ev36), no backup job names the tier (ev37), and
  `ticker-ch-restore-drill` is suspended and has never run (ev38). A job that starts its backups on
  the old cluster stops working when that cluster is stopped. Required before the stop: a backup
  taken from the tier, and one restore of it proven. The kept PVs are not that restore point once the
  machines go: they are local disks, 8 of the 12 on node-49 and node-50, and the old replicas of
  shards 1 and 4 are on those two boxes only (ev37).

If any of G1 to G3 fails, the old CHI is not stopped, node-49 and node-50 renew for December, and the
cost is $5,978 for the month.

The yield on 23 Nov only holds while V4 stamps a fresh promotion: `v4_fastlane_yield` requires one
inside 24 hours and the fastlane honours it for 48. `profile`'s stamp of 2026-11-10 19:02Z has already
aged out. If the 18 Nov gate is missed, the 23, 25 and 27 Nov rows slip with it and node-49/50 renew
for December.

## 6. The three hardest blockers

**B1. There is no ClickHouse destination for the cubes.** Evidence: `CUBE_APPS` in
`dags/v4/dag_v4_olap_cubes.py` writes PG; ev21 finds no `cube_analytics_*` table in four clusters and
0 rows in the one cube table that exists; ev20 shows `analytics-prod` stopped with no volumes on boxes
that renew 14 Nov. Two loader DAGs exist for 2 of 15 families and neither has run.
*Captain's:* whether cubes go to ClickHouse at all, and the DDL fence. *Lanes':* the loaders, once
that is decided.

**B2. V4 does not complete a cube run, so the fastlane cannot yield.** Evidence: `v4_olap_cubes` last
succeeded 2026-10-29; `v4_calc_inputs`, which triggers it, failed 9 of its last 14 runs (ev18); 21 of
21 families have `fastlane_yield = false` (ev17). Until this holds daily, 564 fastlane pods keep issuing
90% of n19's `stats` execution time.
*Lanes':* the cadence. *Captain's:* the house wiki (2026-11-06) attributes the `v4_calc_inputs` refusals
to a partial 2026-05-30 snapshot whose repair is reserved to him. I did not re-verify that cause, and
`v4_calc_inputs` did succeed on 2026-11-11.

**B3. PG is the source of truth for the stats facts, and V4 reads it.** Evidence: W1 to W3 are 27 TB,
3.9 TB and 5.7 TB of WAL from industry-worker and analytics-worker; R2 shows V4 re-reading the result.
"PG analytics writes retired" has no design behind it for `analytics_link`, `analytics_video`,
`profile_track` or `entities`.
*Captain's:* whether capture state counts as an analytics write. If it does, the second zero needs a
new design, not a cutover. If it does not, the second zero is W4 and W6 only, and B1 and B2 cover it.

## 7. What I could not measure, and why

- **A quarter of read volume.** Prometheus keeps 7.1 days. `pg_stat_database.stats_reset` is NULL on
  both hosts, so the cumulative counters have no known start. `pg_stat_statements` has evicted
  3,317,431 entries on n17 and 207,453 on n19 against a 5,000-entry limit (ev01, ev08). The 7.1-day
  split is the longest measured window; multiplying it to 91 days would be a projection.
- **Which pod is behind a pgbouncer session.** Most n17 sessions arrive from 127.0.0.1 with a blank
  `application_name`. The bouncer's admin console asks for a password I did not have and did not go
  looking for (ev14). Those consumers are mapped by query text.
- **55% of the window's WAL.** Not attributed to any statement. Autovacuum, full-page images and
  evicted statements are not separable from this source.
- **`core`'s 508.7 M blocks read on n17 in the window.** `pg_stat_statements` shows 333 K for role
  `muso-app`. Unexplained.
- **`pg_stat_statements` window totals are a floor.** 3,365 of n17's 4,858 entries were new between
  the two snapshots.
- **R2's issuer** is identified by query shape and docstring, not by a session.
- **W8's issuer** (who upserts `track_daily`) is not identified beyond the role.
- **Where 380 fastlane pods could go.** I read their requests, not the free memory on other nodes.
- **The smaller PG pair's price and stock.** Taken from the house wiki, not from OVH.
- **Tax.** All prices are pre-tax; the wiki records 6.6% US sales tax on invoices.
- **ClickHouse totals.** Row counts are one replica of one shard per cluster.
- **Why `analytics-prod` is stopped**, and how the `v4_olap_cubes` run started 2026-11-11 will end.
- **n17's load.** PSI and `iostat` are one 5-second sample at 00:29Z (ev24).
- **Ticker parity.** I ran none of G1 to G3. ev35 is shard 0 replica 0 of each cluster, not all 24
  hosts, and I compared no query results between the two clusters.
- **Whether the ticker backups restore**, and what the backup job covers. I read the job's
  schedule and the backup records, not its script and not a restore.
- **Why the runbook's S6, S7 and S9 dates passed without running.**

## Evidence index

| ev | File | What |
|---|---|---|
| 01 | `01-n17-databases` | database sizes, counters, pgss health |
| 02, 09 | `02-n17-…`, `09-n19-pgss-by-db-role-kind` | pgss by database, role, kind |
| 03, 04, 10 | top read statements by rows and by calls | |
| 05 | `05-n17-pgss-top-writes` | top writers by WAL |
| 06, 11 | sessions by application and client | |
| 07 | `07-n17-user-tables-*` | table sizes and tuple counters per database |
| 08 | `08-n19-identity` | replica identity and lag |
| 12, 13, 28 | snapshots A and B, and `28-rates-A-to-B.out` | measured rates |
| 14 | `14-not-measured-pgbouncer.txt` | the refused console |
| 15 | `15-activity-queryid-sample-*` | `application_name` to `query_id` (query text removed) |
| 16 | `16-pgss-by-relation-*` | pgss folded by relation |
| 17 | `17-n17-cube-suffixes` | cube registry and yield flags |
| 18 | `18-n17-airflow-dags` | every DAG's state and 14-day runs |
| 19, 20, 23 | ClickHouse topology, `analytics-prod`, services and pods per node | |
| 21 | `21-ch-tables-*` | ClickHouse tables per cluster |
| 22, 33 | deployment env; fastlane placement and KEDA | |
| 24 | `24-pg-hosts-hardware.out` | CPU, RAM, disks, PSI, iostat |
| 25, 26, 27 | OVH inventory, option prices, unnamed servers | |
| 29 | `29-pgss-query-text-*` | text of the dominant statements |
| 30, 31 | Prometheus 7.1-day increases and the split | |
| 32 | `32-n17-olap-generations` | cube generations: served, staged, neither |
| 34 | `34-n17-olap-top-wal` | the `olap` statements with the most WAL, with text |
| 35 | `35-ch-ticker-replicas-*` | replica sets of the ticker tables on each cluster |
| 36 | `36-ch-ticker-refreshers-*` | refreshers, engines of the unreplicated targets, backups on record |
| 37 | `37-k8s-ticker-rollback-surface.out` | `CH_URL` now, CHI stop flags, PVCs and where they live, backup cronjobs |
| 38, 39 | `38-k8s-ticker-backup-jobs.out`, `39-ch-ticker-backups-*` | the backup and restore-drill jobs; backup records by status |

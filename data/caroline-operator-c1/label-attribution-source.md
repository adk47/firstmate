# What still supplies the label-to-person attribution

Answer to firstmate's inbox 171 ask: `catalog_label_profile` is computed, so deleting the five
rows is a gesture the next computation can undo. This names the source, the job, and the table.

Measured 2026-11-11 on node-8 against the cluster's Mongo (`industry` database) and the Airflow
metadata. Profile under investigation: `303867d9-e744-452d-9d58-dda7a7002a3b`.

## The chain, end to end

```
Mongo industry.catalog_profile          (name, profile_type, raw_profile_ids, deleted)
Mongo industry.raw_recording            (artist_ids, release_ids, deleted)
Mongo industry.raw_recording_credit     (profile_id, recording_id, credit, deleted)
Mongo industry.raw_release              (release_type, deleted)
Mongo industry.catalog_release          (raw_release_ids, deleted)
        │
        ▼  Airflow: v4/calc/label_profile_relation.py :: build_label_profile_relation
calc.label_profile_relation_full        (dark)
calc.label_profile_relation_deletes     (dark, PersistType.DELETE)
        │
        ▼  promotion (not in this DAG)
Postgres catalog.catalog_label_profile  ← the five rows that render
```

## The job

- **Repo**: `Muso-AI/industry-data-processing`
- **File**: `/opt/airflow/dags/v4/calc/label_profile_relation.py` (209 lines), function
  `build_label_profile_relation`
- **Legacy twin**: `contracts/materialize/label_profile_relation.py` +
  `label_profile_relation_deletes.py`, DAG `dag_calculate_industry_db_default` — **not loaded in
  this Airflow at all** (no `dag` row, no `dag_run`). Only `v4_*` DAGs run. So the V4 file is the
  live one.
- **Outputs**: `calc.label_profile_relation_full` and `calc.label_profile_relation_deletes`.
  The file's own header says "Nothing here writes PG: the outputs are dark `calc.*` tables."

## How the attribution is actually built

```python
label_recording = (rrc.filter(F.col("profile_id").like("spotify:%"))
                      .filter(F.col("recording_id").like("spotify:%"))
                      .filter(F.col("credit").like("%label%"))
                      .select(F.col("profile_id").alias("raw_label_id"), "recording_id").distinct())
release_recording = (rec.withColumn("release_id", F.explode("release_ids"))
                        .withColumn("raw_artist_id", F.explode("artist_ids"))
                        .select("release_id", "raw_artist_id", "recording_id")
                        .join(rr, "release_id").join(label_recording, "recording_id").join(cr, "release_id"))
spotify = (cp.withColumn("raw_profile_id", F.explode("raw_profile_ids"))
             .filter(F.col("raw_profile_id").like("spotify:%")))
```

So the **artist** side of the pair comes from `raw_recording.artist_ids`, and the **label** side
from `raw_recording_credit` rows whose `credit` contains "label". Both are joined through
`raw_release` and `catalog_release`. The name comes from `catalog_profile.name`.

## What is still live in the source

| collection | what | count | soft-deleted |
|---|---|---|---|
| `catalog_profile` | the profile doc itself | 1 | **YES** — `is_deleted: true`, `deleted_timestamp: 2026-10-13T15:09:31.081Z`, `deleted_by: {id: jan@muso.ai, type: operations, sub_type: muso-cli}` |
| `raw_recording` | recordings whose `artist_ids` contain `spotify:3yQIiVImU9DT1HViNoglsC` | **57** | **0** — all live |
| `raw_recording_credit` | rows for `spotify:3yQIiVImU9DT1HViNoglsC` | **58** | 1 |
| `raw_recording_credit` | rows for `tidal:15343553` | **67** | 0 |
| `raw_recording_credit` | rows for `muso:303867d9-…` | 0 | — |

The profile's `raw_profile_ids` are `['tidal:15343553', 'spotify:3yQIiVImU9DT1HViNoglsC',
'muso:303867d9-e744-452d-9d58-dda7a7002a3b']`.

## The two findings that decide the fix

**1. The profile is already soft-deleted, and the calc honours that.** `_live(df)` filters
`~_is_deleted_flag(df)` on every input, and the doc carries `deleted.is_deleted: true`. So a
correct recompute would drop this profile from the relation — the five Postgres rows are
**stale**, not regenerated. That means the delete path is not reaching Postgres: either the calc
has not run since 2026-10-13, or the promotion from `calc.*` to `catalog.catalog_label_profile`
does not apply `label_profile_relation_deletes`.

**2. The underlying data is not erased.** 57 recordings still list the artist, and 124 of the
125 `raw_recording_credit` rows are still live (58 spotify, of which 1 is soft-deleted; 67 tidal,
none deleted). So even a correct recompute removes only the *name* (because `catalog_profile` is
soft-deleted) - the artist attribution in `raw_recording.artist_ids` survives, and any future
recompute that reads a non-deleted profile doc would put the pair back.

## The ask, precisely

For core-backend / industry-data-processing:

1. **Soft-delete the source rows** using the platform's own mechanism (`deleted.is_deleted`):
   - remove `spotify:3yQIiVImU9DT1HViNoglsC` from `artist_ids` on the 57 `raw_recording` docs
     (or soft-delete those docs if the recording is genuinely the person's);
   - soft-delete the 58 `raw_recording_credit` rows for `spotify:3yQIiVImU9DT1HViNoglsC` and the
     67 for `tidal:15343553`.
2. **Then let the calc recompute** — `calc.label_profile_relation_full` drops the pair and
   `calc.label_profile_relation_deletes` carries it.
3. **Fix the promotion** so `label_profile_relation_deletes` actually reaches
   `catalog.catalog_label_profile`. This is the real defect: a soft-deleted profile has been
   rendering on five live label pages since 2026-10-13, which is 29 days.

Deleting the five Postgres rows alone is the gesture firstmate warned about: the calc can
regenerate them from the still-live `artist_ids`, and it would leave the 57 recordings and the
124 live credit rows untouched.

## How to reach the data

**Do not print the credential, and do not pass it as a command argument.** Sending the secret's
raw value to the terminal puts it in the scrollback or a session recording; passing it through
`env` puts it in the process table. Either way a live database credential escapes the secret
store.

What an operator needs to know, none of which is itself secret:

- The MongoDB URI is the `MONGO_URI` key of the `data-processing/mongo-rs0-credentials` secret.
  It points at `mongodb.databases.svc.cluster.local:27018`, database `industry`, authenticating
  as `svc_industry_worker_r2`. Obtain the value through the approved masked secret-access
  workflow for your environment; never decode it to stdout.
- The `databases/mongodb-auth` root password does **not** authenticate against this instance, so
  reaching for it wastes an attempt.
- Queries run inside the scheduler pod, where `pymongo` 4.17.0 is installed. Give the pod the
  credential through its own secret mechanism rather than the command line.
- Airflow metadata: `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN` in the same pod; the `dag` and
  `dag_run` tables answer "is this DAG even loaded" - which is how the legacy DAG was ruled out.
- The DAG source is only readable inside the pod, at `/opt/airflow/dags/`.

# Handover: catalog-admin lane retention + refresh inflow (H-DevOps)

**Status: B1 DONE (live and in IaC). B2 WITHDRAWN. Nothing is waiting on
H-DevOps.** [H-DevOps #2294](https://github.com/Muso-AI/H-DevOps/pull/2294)
merged 2026-08-03 13:47Z (`261b8364`), so the topic manifest now carries 30d and
converges it on every run — a rebuild from IaC no longer reverts to 7d. Nothing
is on fire. This document is now a reference, not a request. See B1 below.

Prepared 2026-07-28 by Nick, re-measured 2026-07-31, **re-measured and acted on
2026-08-03**. Everything below was measured, not inferred; where a claim is
second-hand it says so.

### Current state, measured 2026-08-03T10:5xZ

| | 2026-07-27 | 2026-07-28 | 2026-07-31 | **2026-08-03** |
|---|---|---|---|---|
| `TOTAL-LAG` | 76,295 | 7,870 | 25,082 | **0** |
| topic partitions | 9 | 9 | 27 | **27** |
| prod replicas | 9 | 9 | 20 | **20** |
| `retention.ms` | 7d | 7d | 7d | **30d — B1 APPLIED** |

**B1 is applied and verified live**: `retention.ms 604800000 → 2592000000`, source
`DYNAMIC_TOPIC_CONFIG`. `retention.local.target.ms` is unchanged at `86400000`
(1 day), so broker disk is unaffected and the change lands on object storage only.

**The lane is fully drained.** `TOTAL-LAG` **0** on all 27 partitions, group
`Stable`, 20 members. Consumer offset equals log-end offset everywhere.

**Correction to the 2026-07-31 note: the retention frontier was NOT frozen.**
Between 07-31 and 08-03 `LOG-START-OFFSET` advanced on six partitions —
p0 86085 → 176313, p2 90207 → 178594, and p3/p4/p6/p7 all left 0. The earlier
"frozen since 2026-07-27, the mechanism has not fired" claim was wrong.

**It caused no loss**, because the consumer was at the head the whole time —
retention only deleted already-consumed data. That is luck of timing, not a
safeguard, which is precisely why B1 was worth applying.

**`KAFKA_POLL_HOT_*` remain unset** (both default 1), and `QUEUE_CATALOG` /
`QUEUE_CATALOG_HIGH` still both point at this deployment's own topic, so the
self-amplification loop described under "Durable fix" is intact. That remains
optional.

## Why it matters

Admin profile-merges (`POST /admin/profiles/merge`) return a hollow 200 and are
folded asynchronously by the IDP catalog worker off this topic. When the lane's
drain ETA approaches its retention window, retention eats the tail as fast as the
head advances and merge requests are **deleted before the worker ever consumes
them** — with no dead-letter row and no log line. `redpanda.remote.delete=true`,
so tiered copies go too, and reads below `LOG-START-OFFSET` clamp.

**The live window is `retention.ms` = 30d, since 2026-08-03 (B1, below).** It was
**7d** when the impact below was measured, with an effective floor of ~14.8d —
deletion is per closed segment and `segment.ms` = 14d, so at 7d the segment roll,
not retention, set the window. At 30d retention dominates and the window is ~30d.

**B1 pushes this failure mode out; it does not remove it.** A backlog whose drain
ETA exceeds 30d loses records in exactly the same way, and just as silently. 30d
is far beyond any drain time this lane has shown, which is why it is enough — not
because the mechanism is gone.

Measured impact on 2026-07-28: **5 unlanded pairs out of 511** examined, two of
them past the retention frontier. Small — but silent, and it recurs whenever the
lane backs up again.

> Correction worth carrying: an earlier internal note put this at "39 lost
> merges". That number came from a detector that could not recognise a
> third-canonical collapse and alerted on pairs that were fine. Do not quote it.

## B1 — `retention.ms` 7d → 30d — **APPLIED 2026-08-03**

Highest value, near-zero cost. Broker disk is unaffected —
`retention.local.target.ms` is 86400000 (1 day), so the change lands on object
storage only.

```bash
kubectl -n queuing exec redpanda-v2-0 -c redpanda -- \
  rpk topic alter-config industry-proc-catalog-admin-prod \
      --set retention.ms=2592000000
```

Ran 2026-08-03, returned `OK`. Verified: `retention.ms 2592000000
DYNAMIC_TOPIC_CONFIG`.

**Trap — `rpk topic create` alone never converges a live topic.** The Job at
`k8s/prod/queuing/redpanda/topics/industry-proc-catalog-admin-prod.yaml` runs
`rpk topic create … || echo TOPIC_ALREADY_EXISTS` and **exits 0**, so editing its
`--topic-config` flags changes nothing on a live topic. Fixed in
**H-DevOps PR #2294**, merged 2026-08-03 (`261b8364`): it adds an `alter-config`
step that converges retention on every run, plus a `describe -c` assertion that
actually fails the Job when it did not converge (`alter-config` alone exits 0 on
broker rejection in rpk v24.3.9), and corrects the create flags to 27 partitions
/ 30d. The IaC and the live topic now agree; a rebuild no longer reverts to 7d.

**Verify:** the fix widens the margin a future backlog would have to outrun (a
drain ETA past 30d still loses records), so there is no immediate observable to
watch — the frontier advancing is normal and harmless while lag is 0. What to
check instead: `retention.ms` still reads 2592000000, and
`rpk group describe industry-proc-catalog-admin-prod` shows no partition whose
`CURRENT-OFFSET` sits below its `LOG-START-OFFSET`.

## B2 — cut refresh inflow at the source — ~~**WITHDRAWN 2026-08-03. Do not apply.**~~

The proposal was, on `industry-proc-catalog-admin` in
`k8s/prod/workers/industry-processors.yaml`:

```yaml
- { name: IDP_CREDIT_SYNC_SERVING_REFRESH_DEBOUNCE_SEC, value: "86400" }   # was 300
```

**Why it was proposed:** `refresh_analytics_profile_full` was **0.9% of messages but
49.4% of worker-time** (mean 820 s, max 1362 s) at `KAFKA_POLL_HOT_INFLIGHT=1`. The
`sync` flood is a red herring — 99% of messages, 0.19% of time. Producer is
`processors/catalog/sync/sync_recording_credit.py:97`.

**Why it is wrong.** The claim that it "keeps #1385's staleness fix" holds for the
mechanism but not at that magnitude. Per the docstring at
`sync_recording_credit.py:57-68`, the value is *"at most one enqueue per profile per
`IDP_CREDIT_SYNC_SERVING_REFRESH_DEBOUNCE_SEC`"*. At 86400 that means: a credit added
to a profile that already refreshed today gets **no serving refresh for up to 24
hours** — it lands in the raw tier but never reaches `profile_track` or the
collaboration cubes. The `must_materialize` flag does not save it; that flag guards
the *completion*-debounce (#1434), while the coalescing here happens earlier, at the
`serving_refresh_last_enqueued` claim.

That is precisely the "admin credit-adds looked lost for hours" failure class this
lane has already hit twice — task #209 (2026-07-16) and the 07-16 regression cited in
the producer comment at `sync_recording_credit.py:66`. Trading a silent-loss bug for a
silent-staleness bug is not a fix.

**Its premise is also gone.** The 49.4% figure was measured *while the lane was
backlogged at 9 partitions / 9 replicas*. At 27 partitions / 20 replicas the lane sits
at `TOTAL-LAG` 0, so refresh cost is no longer contended for.

**If refresh inflow ever becomes the constraint again**, the right lever is the
"Durable fix" below — split `refresh_analytics_profile_full` onto its own topic and
pool, so slow refreshes cannot starve interactive admin syncs. That is IDP #209's
tracked fix. A larger debounce only hides the coupling behind stale serving data.

**Rollout caveat, retained for whoever does touch this deployment:** in-flight tasks
run 820–1362 s and `executor.shutdown(wait=True)` blocks on them, while
`terminationGracePeriodSeconds` is explicitly **30 s** (verified live 2026-08-03) →
SIGKILL mid-work. Raise the grace period and use `maxUnavailable: 1` before any
rollout of this deployment. Note the current strategy is `maxUnavailable: 25%`.

## Before touching pods

Freeze the node-1 watchdog first. `H-DevOps:scripts/devops-agent/router-dispatch.sh:407-600`
auto-restarts this deployment at ≥30 min frozen and `rpk group seek`s past the head
at ≥45 min — it will race manual work. Confirm quiet via `/root/wedge-evidence/`.

## What NOT to do

1. **No `rpk group seek`** on the admin group — discards tens of thousands of syncs
   unaudited and recovers nothing.
2. **Do not raise either concurrency knob alone.** Per-pod concurrency is
   `min(KAFKA_POLL_HOT_WORKERS, owned_partitions × KAFKA_POLL_HOT_INFLIGHT)`
   (`config.py:285-286`). Both are unset (default 1), so `WORKERS` is the binding
   term and raising `INFLIGHT` alone is still a no-op — that holds at 27/20 just as
   it did at 9/9. Raising **both** exhausts `PG_MAX_CONNECTIONS=5` (SQLAlchemy pool
   derives to 5+2, still unchanged) and risks the whale-profile OOM crashloop that
   pinned this lane at 0 members on 2026-06-13 — though the memory limit is now
   28Gi, up from the 16Gi in force then, so that headroom is worth re-measuring
   before assuming the old ceiling.
3. ~~**Do not expand 9 → 12 partitions.**~~ **Withdrawn 2026-07-31 — this advice
   was wrong.** The reasoning (an uneven `range` assignment re-couples pods) ignored
   the more important constraint: a consumer group cannot usefully run more members
   than partitions, so 9 partitions capped the lane at 9 consumers. The expansion to
   27 is what allowed scaling to 20 replicas, which drained the lane to `TOTAL-LAG`
   0. Do not revert it. An earlier version of this note also credited the expansion
   with stopping the retention frontier — that was wrong, and the 2026-08-03
   measurement above disproves it: the frontier kept advancing on six partitions,
   harmlessly, because the consumer stayed at the head. The manifest's stated
   key-remapping rationale is still wrong too — `p.produce()` is called with **no
   `key=`**; worth correcting when you touch the file.
4. **Do not set `QUEUE_CREDIT_SYNC_TARGET` here** — syncs cost 0.03 s each. Diverting
   them buries customer-facing credit syncs to fix a problem they do not cause.
5. **Never route merges to `…_CATALOG_ADMIN_PRIORITY`** — it points at the fastlane
   topic whose processor does not understand `merge`. That is the 2026-06-09 incident
   (13 merges / 21 profiles lost over ~20 days). `mergeProfiles.js` correctly avoids
   `{priority:true}`; leave it.

## Durable fix, if you want to go further (needs IDP code, not just config)

The lane self-amplifies: `process_catalog.py` consumes `config.QUEUE_CATALOG_HIGH`
and the refresh producers publish to the *same symbol*, which on this deployment is
its own topic. No env separates them. Splitting it means adding
`QUEUE_PROFILE_REFRESH_TARGET` to `config.py`, using
`QUEUE_PROFILE_REFRESH_TARGET or QUEUE_CATALOG_HIGH` in the three producers, and
registering it in `common/startup_guards.py::validate_catalog_produce_targets()` so a
typo crashes loudly instead of dropping silently. **Create the topic before anything
references it** — the guard raises `RuntimeError` on a dead target and would
CrashLoopBackOff every pod in the deployment (20 as of 2026-08-03) — add it to
`QUEUE_BACKEND_MAP` (or produces fall through to elasticmq), and extend the
`catalog-admin-partition-stall` PrometheusRule plus the node-1 watchdog regex, or the
new lane is unmonitored.

This is optional — B1 is applied, and it moves the silent-loss window from ~14.8d
out to 30d, past any drain time this lane has shown. It does not eliminate the
failure mode. This split is now the *only* remaining answer to the head-of-line
coupling, since B2 is withdrawn.

## Two earlier questions — both resolved, no action needed

Recorded so nobody re-raises them. Verified 2026-07-31:

1. `industry-worker-v2-backlog` was pinned to `20260714-373` while the fleet moved
   on. **Resolved** — it and `industry-proc-catalog-admin` are both now on
   `20260731-407`.
2. `Deploy: Infrastructure` had failed on every core-backend image-tag commit since
   >=2026-07-22 with `duplicate entries for key [name="AWS_SQS_INDUSTRY_PROC_RAW_HIGH"]`.
   **Resolved** — the last three runs (2026-07-31 14:26, 14:33, 14:38Z) all succeeded.

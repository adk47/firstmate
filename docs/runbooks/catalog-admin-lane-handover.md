# Handover: catalog-admin lane retention + refresh inflow (H-DevOps)

**Status: PREVENTION, not an incident.** Nothing is on fire. This is a request to
close a structural gap so a silent-loss failure cannot recur, at operator
convenience.

Prepared 2026-07-28 by Nick, **re-measured 2026-07-31**. Two config changes, both
on OVH prod, both reversible. Everything below was measured, not inferred; where a
claim is second-hand it says so.

### Current state, measured 2026-07-31T14:2xZ

| | 2026-07-27 | 2026-07-28 | **2026-07-31** |
|---|---|---|---|
| `TOTAL-LAG` | 76,295 | 7,870 | **25,082** |
| topic partitions | 9 | 9 | **27** |
| prod replicas | 9 | 9 | **20** |
| `retention.ms` | 7d | 7d | **7d — B1 still not applied** |

**Lag tripled, but no new data was lost.** `LOG-START-OFFSET` on p0/p1/p2 is
frozen at exactly **86085 / 106218 / 90207** — unchanged since 2026-07-27 — and
partitions 3–26 have a start offset of **0**, i.e. retention has deleted nothing
there at all. The silent-loss mechanism has not fired in four days.

**Someone already applied a throughput fix** (partitions 9 → 27, replicas 9 → 20,
memory limit 16Gi → 28Gi), and that is why the frontier stopped advancing. Credit
where due; it also invalidates one of our earlier recommendations — see "What NOT
to do" item 3, corrected below.

**Still unapplied and still worth doing:** B1 (retention) and B2 (refresh
debounce). `KAFKA_POLL_HOT_*` remain unset (both default 1), and `QUEUE_CATALOG` /
`QUEUE_CATALOG_HIGH` still both point at this deployment's own topic, so the
self-amplification loop described under "Durable fix" is intact.

## Why it matters

Admin profile-merges (`POST /admin/profiles/merge`) return a hollow 200 and are
folded asynchronously by the IDP catalog worker off this topic. The topic's
configured `retention.ms` is **7d**, with an effective floor of ~14.8d (deletion
is per closed segment; `segment.ms` = 14d). When the lane's drain ETA approaches
its retention window, retention eats the tail as fast as the head advances and
merge requests are **deleted before the worker ever consumes them** — with no
dead-letter row and no log line. `redpanda.remote.delete=true`, so tiered copies
go too, and reads below `LOG-START-OFFSET` clamp.

Measured impact on 2026-07-28: **5 unlanded pairs out of 511** examined, two of
them past the retention frontier. Small — but silent, and it recurs whenever the
lane backs up again.

> Correction worth carrying: an earlier internal note put this at "39 lost
> merges". That number came from a detector that could not recognise a
> third-canonical collapse and alerted on pairs that were fine. Do not quote it.

## B1 — `retention.ms` 7d → 30d

Highest value, near-zero cost. Broker disk is unaffected —
`retention.local.target.ms` is 86400000 (1 day), so the change lands on object
storage only.

```bash
kubectl -n queuing exec redpanda-v2-0 -c redpanda -- \
  rpk topic alter-config industry-proc-catalog-admin-prod \
      --set retention.ms=2592000000
```

**Trap — the IaC file will not do this for you.** The Job at
`k8s/prod/queuing/redpanda/topics/industry-proc-catalog-admin-prod.yaml` runs
`rpk topic create … || echo TOPIC_ALREADY_EXISTS` and **exits 0**, so editing it
changes nothing on a live topic. Please update it anyway (add an explicit
`alter-config` line) so a rebuild-from-scratch is correct — and while there, the
manifest still says `--partitions 3` when the live topic now has **27**.

**Verify:** `LOG-START-OFFSET` on p0/p1/p2 stays frozen at 86085 / 106218 / 90207
over 48h, and partitions 3-26 stay at 0. (Those values have already held since
2026-07-27, so this confirms the change did no harm rather than proving it fixed
something — the fix is that a FUTURE backlog cannot outrun retention.)

## B2 — cut refresh inflow at the source

On `industry-proc-catalog-admin` in `k8s/prod/workers/industry-processors.yaml`:

```yaml
- { name: IDP_CREDIT_SYNC_SERVING_REFRESH_DEBOUNCE_SEC, value: "86400" }   # was 300
```

`refresh_analytics_profile_full` was **0.9% of messages but 49.4% of worker-time**
(mean 820 s, max 1362 s) at `KAFKA_POLL_HOT_INFLIGHT=1`. The `sync` flood is a red
herring — 99% of messages, 0.19% of time. Producer is
`processors/catalog/sync/sync_recording_credit.py:97`.

Preferred over the `IDP_REFRESH_PROFILE_SERVING_ON_MUSO_CREDIT_SYNC=false` kill
switch because it keeps #1385's staleness fix while cutting enqueue rate up to
~288× for hot profiles.

**Rollout caveat:** in-flight tasks run 820–1362 s and `executor.shutdown(wait=True)`
blocks on them, while `terminationGracePeriodSeconds` is now explicitly **30 s**
(verified 2026-07-31) → SIGKILL mid-work. Raise the grace period, use
`maxUnavailable: 1`.

**Verify:** refresh share of the topic head drops from ~25–39% to single digits;
`TOTAL-LAG` continues falling.

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
   27 is what allowed scaling to 20 replicas, and the retention frontier stopped
   advancing as a result. Do not revert it. (The manifest's stated key-remapping
   rationale is still wrong — `p.produce()` is called with **no `key=`**; worth
   correcting when you touch the file.)
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
CrashLoopBackOff all 9 pods — add it to `QUEUE_BACKEND_MAP` (or produces fall through
to elasticmq), and extend the `catalog-admin-partition-stall` PrometheusRule plus the
node-1 watchdog regex, or the new lane is unmonitored.

B1 alone removes the silent-loss mode. This is optional.

## Two earlier questions — both resolved, no action needed

Recorded so nobody re-raises them. Verified 2026-07-31:

1. `industry-worker-v2-backlog` was pinned to `20260714-373` while the fleet moved
   on. **Resolved** — it and `industry-proc-catalog-admin` are both now on
   `20260731-407`.
2. `Deploy: Infrastructure` had failed on every core-backend image-tag commit since
   >=2026-07-22 with `duplicate entries for key [name="AWS_SQS_INDUSTRY_PROC_RAW_HIGH"]`.
   **Resolved** — the last three runs (2026-07-31 14:26, 14:33, 14:38Z) all succeeded.

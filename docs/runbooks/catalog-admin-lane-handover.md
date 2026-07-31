# Handover: catalog-admin lane retention + refresh inflow (H-DevOps)

**Status: PREVENTION, not an incident.** Nothing is on fire. `TOTAL-LAG` on
`industry-proc-catalog-admin-prod` was 76,295 on 2026-07-27 and **7,870** on
2026-07-28T17:12Z — the lane drained ~90% on its own. This is a request to close
a structural gap so the failure cannot recur, at operator convenience.

Prepared 2026-07-28 by Nick. Two config changes, both on OVH prod, both
reversible. Everything below was measured, not inferred; where a claim is
second-hand it says so.

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
manifest still says `--partitions 3` when the live topic has **9**.

**Verify:** `LOG-START-OFFSET` on p0/p1/p2 frozen at 86085 / 106218 / 90207 over
48h.

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
blocks on them, while `terminationGracePeriodSeconds` is unset (30 s default) →
SIGKILL mid-work. Raise the grace period, use `maxUnavailable: 1`.

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
   (`config.py:285-286`); with 9 pods / 9 partitions each pod owns exactly 1, so
   either knob by itself is a no-op. Raising **both** exhausts `PG_MAX_CONNECTIONS=5`
   (SQLAlchemy pool derives to 5+2) and reintroduces the whale-profile OOM crashloop
   that pinned this lane at 0 members on 2026-06-13.
3. **Do not expand 9 → 12 partitions.** With 9 replicas the `range` assignor would
   give 3 pods two partitions each, re-coupling them and reintroducing head-of-line
   blocking. (The manifest's stated key-remapping rationale is also wrong —
   `p.produce()` is called with **no `key=`**; worth correcting when you touch it.)
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

## Two open questions

1. Is `industry-worker-v2-backlog` intentionally pinned to `20260714-373` while the
   rest of the fleet moved to `20260727-390`?
2. `Deploy: Infrastructure` has failed on every core-backend image-tag commit since
   ≥2026-07-22 with `duplicate entries for key [name="AWS_SQS_INDUSTRY_PROC_RAW_HIGH"]`.
   The YAML is **clean** (one occurrence per container; `--dry-run=server` exits 0) and
   the "typed patch object" wording points at server-side-apply managed-field corruption
   on the live object rather than a file bug — likely needs `--force-conflicts` or a
   managed-field cleanup. Unrelated to the above.

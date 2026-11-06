# QA scale Q2 — a real broker, N parallel reviewer pods, and a bounded reconciler

**Status:** design v3 — APPROVED 2026-11-04T13:04Z (inbox 004); building now
**Date:** 2026-11-04
**Lane:** `qa-scale-q2` (branch `fm/qa-scale-q2`, worktree `/home/aaron/orca/workspaces/hydra/fm-qa-scale-q2`)
**Owner:** firstmate
**Inputs:** inbox 001 (reconcile 30-min timeout), inbox 002 (broker de-dup + cluster autoscale + placement), inbox 003 (post design before building)
**Captain's intent (Aaron 2026-11-04 12:4xZ):** "is QA scaled yet. are you removing bottlenecks?" — top priority CI/CD and DevOps bottlenecks; scale the automated QA reviewer so many PRs review in parallel, it survives gateway restarts, and it reports its queue.

This document is the gate. Nothing is built until the broker rules, the scaling numbers and the node list below are posted (done: `state/qa-scale-q2.status`, 2026-11-04T12:5xZ).

---

## 1. Measured facts this design is built on

### 1.1 The current QA path loses time in four places

1. **Launch fragility.** `scripts/qa-dispatch-pr-review.sh` mints a one-shot `openclaw cron add --at "+5s"` job. The dispatch only succeeds if the gateway handshake works at the exact moment the PR's CI finishes. Gateway restarts on 2026-11-04 at 10:59Z and 11:20Z produced "gateway unreachable / opening handshake timed out" and exit 75 ("nothing queued"). The PR then sits `pending` until someone notices.
2. **Restart fragility.** openclaw does not re-arm a past-due one-shot across a restart. The killed job leaves no journal line, no session key, no session file. `docs/designs/2026-08-13-qa-review-loss-reconciler.md` documents the full mechanism. Confirmed losses: `muso-skills#2` (18 h undetected), `core-backend#9243` (15 days undetected).
3. **One serialized execution lane.** Today the `qa` agent runs reviews serially behind each other. hydra #1730 waited ~1 h behind 5 PRs. Cron concurrency is one process-global lane (`cron.maxConcurrentRuns`, upstream default 8) — not per agent. The 2026.8.1 schema reshape removed Hydra's `cron.maxConcurrentRuns: 12` pin (#896), so the lane runs at the default.
4. **The reconciler that was supposed to catch 1-3 is itself a 30-min monolith** (inbox 001).

### 1.2 The reconciler bug, root-caused (inbox 001)

`scripts/qa-review-reconcile.sh` runs as a systemd timer (node-8) and as a suspended K8s CronJob in `hydra-qa` (`*/15 * * * *`, `activeDeadlineSeconds: 1800`).

- **Work per tick is serial and unbounded.** For each of ~17 repos: `gh pr list --limit 1000 --json number,headRefOid,baseRefName,isDraft,author,updatedAt,createdAt,url`, plus a second `gh pr list --search "updated:>=…"` rollup call. Then per in-scope PR, up to 5 sequential `gh` calls: commit, timeline (paginated), reviews (paginated), status, plus a Slack UID resolve. With 300–1000 open PRs across the fleet this is thousands of serial API calls at ~0.3–1 s each.
- **State is written ONCE at the end** (`qar_state_write_atomic`, ~line 1297; the unit's own comment says "state is written ONCE, after all repo loops complete"). At `TimeoutStartSec=1800` systemd SIGTERMs the tick and **every attempts / last_attempt_epoch / ready_cache write from that tick is discarded**. But the dispatch side effects (cron jobs, comments, statuses) already fired inline during the loop. So the tick does the work and throws away the bookkeeping that would stop it repeating. The next tick sees the same PRs as fresh candidates and re-dispatches → duplicate reviews → the "one PR cost 91 min" report.
- **No change detection.** A PR whose `updatedAt` and head sha have not moved costs the same 4–5 calls every 15 min. The only cache is `qar_ready_cache` for the timeline.
- **Starvation.** A tick killed at 1800 s never reaches repos later in `REPOS` order; those PRs are never reconciled at all.
- **Truncation.** `PRLIST_LIMIT=1000` is treated as "presumed truncated" and pages every tick — the guard is correct but the fix is pagination, not a bigger cap.

### 1.3 The pod path today (measured live, 2026-11-04T12:5xZ)

`kubectl -n hydra-qa get deploy qa-review-gateway`:

- `spec.paused: true`, `replicas: 2`, **0/2 ready — the Deployment has never run in prod.** Annotation: `muso.ai/inert-reason: 2026-10-28 (node8-to-pods T9): paused (no ReplicaSet, no pod) until the README canary step; node-8 still runs every QA review.`
- HPA: `cpu: <unknown>/60%`, **min 2, max 6** — CPU-based, not queue depth. `minReplicas: 2` cannot satisfy "min 4".
- **Hard** `requiredDuringScheduling` nodeAffinity to `ovh-node-29`, `node-67-pdp`, `node-68-pdp`. `ovh-node-29` is on the give-back list, and 67/68 have ~2 cores free each. The current affinity is exactly wrong for the new rules.
- Pod requests: `cpu: 2`, `memory: 4Gi`; limits `4` / `8Gi`.
- Tolerates `dedicated=data-processing:NoSchedule` — only needed because of the pdp pin.
- `topologySpreadConstraints`: hostname, `maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`.
- Volumes already mounted: `/opt/hydra/workspaces/qa`, `/var/lib/hydra-qa`, `/var/lib/hydra`, `/var/cache/qa-bot`, `/run/hydra`, `/opt/hydra/secrets`.
- Namespace `hydra-qa` also holds: PVCs `qa-approval-retry-state` (1Gi RWO longhorn), `qa-reconcile-state` (1Gi RWO longhorn); CronJobs `qa-review-reconcile` and `qa-approval-retry`, **both `suspend: True`**; Secrets `qa-reconciler-env`, `qa-review-gateway-env`, `qa-review-gateway-files`, `qa-review-gateway-token`.
- The pod profile (`pods/qa-review-gateway/openclaw-qa.json`) has exactly one agent, `qa`; `scripts/tests/qa-review-gateway-profile.bats` asserts `agents.list == ["qa"]` and lockstep with `openclaw-main.json`.

### 1.4 Queue infrastructure already in the cluster (no new spend)

- **KEDA is installed**: CRDs `scaledobjects.keda.sh`, `scaledjobs.keda.sh`, `triggerauthentications.keda.sh`; external metrics API served by `muso-system/keda-operator-metrics-apiserver`. "Autoscale on queue depth" needs no new component.
- **`queuing` namespace already runs two brokers**: `elasticmq` Deployment (SQS-compatible, port 9324) and `redpanda-v2` StatefulSet (Kafka API, 4/4 replicas).
- **StorageClasses**: `longhorn` (default), `local-path`, `local-nvme`, plus dedicated longhorn classes.
- Prometheus / Grafana / Loki / Alertmanager are live in `monitoring`.

### 1.5 Node capacity, measured (allocatable − sum of pod requests, 2026-11-04T12:5xZ)

| Node | CPU alloc | CPU free | Mem alloc | Mem free | Pods | Taint | Verdict |
|---|---|---|---|---|---|---|---|
| node-33-aw | 32 | 13.0 | 238Gi | 76Gi | 308 | `dedicated=app-serving:PreferNoSchedule` | **preferred** |
| node-34-aw | 32 | 12.2 | 238Gi | 75Gi | 303 | same | **preferred** |
| node-40-aw | 32 | 11.8 | 238Gi | 76Gi | 296 | same | **preferred** |
| node-41-aw | 32 | 11.7 | 238Gi | 76Gi | 298 | same | **preferred** |
| node-43-aw | 32 | 11.3 | 238Gi | 66Gi | 301 | same | **preferred** |
| node-59-aw | 32 | 7.5 | 238Gi | 195Gi | 103 | same | **preferred** |
| node-57-aw | 32 | 7.2 | 238Gi | 61Gi | 293 | same | allowed |
| node-58-aw | 32 | 5.0 | 238Gi | 42Gi | 275 | same | allowed |

**A loss is news once.** `lost_window` only sees arrivals inside the window, so a
row enqueued more than an hour ago that disappears *now* is invisible to it —
`lost_total` goes to 1 while `lost_window` stays 0, and because the arrival is
outside every future window it would never page at all. The digest therefore
pages on the cumulative `lost_total` too, but only when it **grows**: the counter
never decreases, so paging on it unconditionally would page forever after a
single incident and train people to ignore the channel. The last paged value
lives in the digest state file.
| node-60-aw | 32 | 4.0 | 238Gi | 99Gi | 277 | same | allowed |
| ovh-node-5 | 48 | 22.3 | 124Gi | 14Gi | 101 | `dedicated=app-serving:PreferNoSchedule` | allowed, **mem-tight** |
| ovh-node-3 | 48 | 21.3 | 126Gi | 99Gi | 42 | control-plane `NoSchedule` | not schedulable |
| ovh-node-1/2 | 48 | 29.2/26.7 | 126Gi | 104/91Gi | 45/93 | control-plane `NoSchedule` | not schedulable |
| ovh-node-4 | 48 | 0.4 | 112Gi | −9Gi | 188 | — | oversubscribed |
| node-35/36/37/38/39/42/44/45/51 | 32 | 0.1–1.8 | 238Gi | 47–103Gi | 253–308 | app-serving | CPU-full |
| node-46/47/48/52/53/54-red-panda | 12 | 1.4–3.2 | 126Gi | 29Gi | 14–15 | clickhouse-tier `NoSchedule` | **cordoned** |
| **node-49-pdp** | 380 | 274.4 | 739Gi | 482Gi | 19 | data-processing `NoSchedule` | **FORBIDDEN** (give-back) |
| **node-50-pdp** | 380 | 273.4 | 739Gi | 479Gi | 23 | data-processing `NoSchedule` | **FORBIDDEN** (give-back) |
| **ovh-node-29** | 189 | 84.9 | 995Gi | 594Gi | 39 | data-processing `NoSchedule` | **FORBIDDEN** (give-back) |
| **ovh-node-20** | 48 | −16.0 | 80Gi | −66Gi | 264 | — | **FORBIDDEN** (oversubscribed, give-back) |
| **ovh-node-19** | 64 | 38.9 | 504Gi | 482Gi | 17 | `workload-type=stateful:NoSchedule` | **FORBIDDEN** (Postgres n19) |
| node-55/56-mongot | 16 | 11.2 | 126Gi | 93Gi | 9 | `dedicated=mongot:NoSchedule` | Mongo-dedicated, not preferred |
| node-61/62/64/65-rp | 24 | ~3.2 | 125Gi | 4Gi | 9–10 | redpanda `NoSchedule/NoExecute` | not preferred |
| node-67/68-pdp | 28 | 2.6/1.9 | 995Gi | 845/522Gi | 25/22 | data-processing `NoSchedule` | full |
| node-69/70-ch | 28 | 23.4 | 113Gi | 100Gi | 8 | clickhouse-analytics `NoSchedule` | analytics-dedicated |
| **node-8 (ovh-node-8)** | 24 | 11.3 | 62Gi | 45Gi | 97 | `dedicated=hydra:PreferNoSchedule` | **fallback only** |

`node-28` and `n17` from the captain's list are **not present in this cluster** (node-28 was the Mongo host replaced 14 Nov; `ovh-node-19` is n19). The hard exclusion list is enforced by hostname regardless, so an absent node is harmless.

**Read of the numbers:** the forbidden pdp/ovh-node-29 boxes hold ~633 CPU cores of spare, but they are exactly the boxes being given back. The usable fleet is the `-aw` app-serving pool: ~56 cores and ~450Gi of measured spare across 9 nodes, plus `ovh-node-5` (22 cores, 14Gi mem) and the 45Gi/11-core node-8 fallback. At 16 reviewer pods this is comfortable; at 24 it still fits without touching a forbidden node.

---

## 2. Broker rules (inbox 002.1)

The dispatcher becomes a **real broker**. It owns the queue, the keys, the leases and the metrics. Reviewers only claim work.

### 2.1 Key

```
key = <repo>#<pr>@<head_sha>          (lowercased repo, integer pr, 40-char sha)
```

The key is the unit of "has this exact commit been reviewed". It is not the PR: a PR can legitimately carry several heads over its life, and each head needs its own verdict.

### 2.2 Dedupe — "the same key is never reviewed twice"

| Situation | Behaviour | Result |
|---|---|---|
| No row for the key | insert `queued` | accepted |
| Key `queued` | return **`duplicate`** (no new row) | producer sees rc 76 |
| Key `running` | return **`duplicate`** | producer sees rc 76 |
| Key `done` | return **`duplicate`** | producer sees rc 76 |
| Key `dead` | return `duplicate` unless `force=1` | operator retry only |

`done` is terminal for that key. **Carve-out (documented, configurable):** a *NO-GO* or *CANNOT REVIEW* verdict may be re-dispatched for the same head by an explicit re-review request (`force=1`), because `qa-tier-recheck.yml` legitimately re-reviews the same head after a tier label fix. Default `QA_BROKER_DEDUPE_DONE=go-only`: a `GO` key is never re-reviewed; a failing key may be re-reviewed up to `QA_BROKER_MAX_REVIEWS_PER_KEY=2` so a broken loop cannot spin. The cap counts **completed reviews** (`jobs.reviews`, incremented on `finish`), not `attempts`: reopening a done row resets the per-run retry budget, so an attempts-based cap would let every `--force` look like the first one and never fire. This preserves the captain's rule for the normal case without making a NO-GO PR permanently unmergeable.

### 2.3 Supersede — a newer head cancels the queued older one

**Only when the producer asserts the new key is the PR's current head** (`--current-head` / `"current_head": true`). Arrival order is not commit order: a delayed dispatch for an *older* head arrives after the current one, and superseding on arrival order alone cancels the review of the head that actually matters, leaving the stale head as the only claimable job. The broker cannot see GitHub, so the dispatcher — which can — resolves `repos/<repo>/pulls/<pr>` `.head.sha` first and:

- **differs from the dispatched sha** → `STALE-HEAD`, exit 0, nothing enqueued (the current head has its own dispatch);
- **matches** → enqueue with supersede rights;
- **lookup failed** → enqueue *without* supersede rights and say so. Fail safe: an extra review of an old head is wasted work, a cancelled review of the current head is a missing verdict.

**"Is this the current head" is a check-then-act, so the assertion alone is not enough.** Dispatch A can verify head A, head B can be pushed, dispatch B can verify and enqueue B, and only *then* can A's delayed POST arrive still claiming `current_head`. Arrival order cannot break that tie; the *verification* order can. So the same read that verifies the head also returns the PR's `updated_at`, which the dispatcher carries as `head_order`. ISO-8601 UTC sorts lexicographically, so the broker compares strings and needs no clock of its own, and a queued row is superseded only when its token is **strictly older**. An unverified row (empty token) is never superseded.

- New key arrives for the same `(repo, pr)`.
- If the older key is **`queued`**: mark it `superseded` (terminal, no review) and enqueue the new key. The older head is never reviewed — its diff no longer exists as the PR head.
- If the older key is **`running`**: do **not** kill the turn. Set `supersede_requested=1` on the running row; when it finishes, its verdict is posted (it is still a true verdict for that sha), and the new key is enqueued immediately. Never two active reviews for one PR.
- If the older key is `done`/`dead`: just enqueue the new key.

### 2.4 Lease — one PR gets exactly one active review

- `claim` sets `lease_owner`, `lease_until = now + QA_REVIEW_TIMEOUT_S + 120`, `last_heartbeat_at = now`.
- **Both `finish` and `fail` require the current `lease_owner`.** `finish` always did; `fail` did not, so a worker whose lease was reaped and reassigned could requeue the *new* owner's running review — duplicate work, and a dead-letter charged to the wrong attempt. A non-owner `fail` returns `{"status":"not_owner"}` and mutates nothing; a `queued` row means the reaper already took it back, so there is nothing left for that worker to record.
- The worker renews the lease (`heartbeat`, every `QA_WORKER_HEARTBEAT_S=120`) while its turn runs.
- `reap` (every 60 s) returns a `running` row to `queued` with a 120 s `not_before` when **either**
  - `lease_until < now` → `last_error='lease expired'`, or
  - `last_heartbeat_at < now − QA_BROKER_HEARTBEAT_STALE_S` (default 360 s = 3 missed beats) → `last_error='heartbeat stale'`.

  The second condition is what makes a restart cheap, and it was found by running the drill rather than by reading the code: a worker killed with `SIGKILL` (pod eviction, node drain, `kubectl delete --force`) never releases its lease, so a lease-only reaper held that PR for the full 25 min lease — most of the wait budget the queue exists to protect. The first drill showed it exactly: after `kill -9` of both workers, `running 1 depth 0` and `reap` changed nothing. With the heartbeat condition the same drill recovers in one stale window. The two reasons are recorded separately so an operator can tell a hung review from a dead pod.

  A crashed reviewer therefore re-queues its job; the PR still has at most one active review at a time.
- A partial unique index enforces it in the database, not just in code:

```sql
CREATE UNIQUE INDEX one_active_review_per_pr
  ON jobs(repo, pr) WHERE status = 'running';
```

### 2.5 Retry / backoff / dead-letter — "never a silent drop"

| Class | Signature | Backoff | Attempts |
|---|---|---|---|
| transport | stderr matches `PRE_GATEWAY_SIGNATURES` (shared list, `scripts/lib/qa-dispatch-signatures.sh`) | `min(30m, 120s × 2^(n−1))` | `QA_MAX_TRANSPORT_ATTEMPTS=12` (~4 h) |
| provider quota/429 | `usage cap`, `429`, `insufficient_quota`, `rate_limit` | 30 m flat | 4 |
| review turn error | other non-zero rc | `min(10m, 60s × 2^(n−1))` | `QA_MAX_ATTEMPTS=3` |
| lease expired | reaper | 120 s | counts as a review attempt |

**The three budgets are independent, and that is a column, not a comment.** The
review budget is `jobs.review_attempts`, incremented only by a turn that ran and
failed (or a lease that expired mid-turn). It is deliberately NOT `jobs.attempts`,
which counts every claim: a transport retry incremented that too, so with
`MAX_TRANSPORT_ATTEMPTS=12` and `MAX_REVIEW_ATTEMPTS=3` three transport failures
left a job one review failure from dead-letter, and the budgets were not separate
at all. `attempts` stays as the informational claim count.

**A turn that exits 0 but publishes no `qa-review` status is a FAILURE, not a
`done` row.** The repos read the status, not the broker, so recording it as done
makes the row terminal with no verdict on the PR: it sits unreviewed forever and
nothing retries it — the exact silent drop this queue exists to prevent. The
worker re-reads the status `QA_WORKER_VERDICT_GRACE_S` (5s) up to 3 times first,
because the skill posts it and a turn can return a moment before the API
reflects it; only then does it record a `review`-class failure.

**A broker response is only believed when it carries an explicit `rc`.** The
worker asks curl for `%{http_code}` on its own line. An integer `rc` in the body
is authoritative whatever the status, because the broker's own contract uses the
status to carry meaning (409 duplicate, 200+`rc:1` empty claim, 500+`rc:3` up but
broken). A response with **no** `rc` is a transport failure (75): a proxy's
bodyless 502 used to read as "nothing to claim", so every reviewer treated an
unavailable broker as an idle queue while accepted jobs waited, and a JSON 502
without `rc` defaulted to 0 and looped on a missing job id.

**"Published" means published by THIS turn, by the QA identity.** A forced re-review reopens the
same key, so the previous verdict is still on the commit: a turn that exits 0
without publishing anything would read the OLD status, record it as this run's
verdict, and consume the re-review slot while the PR still has no fresh verdict.
The worker takes the newest `qa-review` `created_at` BEFORE the turn and accepts
only a status strictly newer than that. Comparing GitHub timestamps against each
other, never against the pod's clock, keeps it immune to skew.

**An empty baseline and an unreadable one are different answers.** A commit with
no `qa-review` status yet legitimately has an empty baseline, and the filter is a
no-op for it. A *failed* read is not that: it would silently disable the filter
and let a forced re-review finish on the previous verdict. `newest_status_at`
therefore signals a read failure with its exit status, and the worker requeues
the job as a `transport` failure instead of running a turn whose verdict it
could not attribute. The review has not run yet, so nothing is lost.

The dispatcher applies the same rule to `/enqueue`: an explicit `rc` in the body
is authoritative whatever the status, so the broker's documented **409 + `rc:76`**
duplicate is deduped rather than reported as broker-unavailable. Requiring 2xx
there made every repeat dispatch exit 75, which the reconciler then retried
forever.

The status must also come from the QA identity (`QA_STATUS_IDENTITIES`, default
`muso-qa-bot,muso-qa-bot[bot],adk47` — the same logins the approval policy
trusts). `qa-review` is a public context: any actor with write access can post
it, and a status posted by someone else after the baseline would be recorded as
this turn's verdict, consuming the re-review slot with a verdict this reviewer
never produced.

Exhaustion → `dead` + an `events` row + a **page** to `#clio_devops` with the PR URL and last error. A dead row is never deleted; it is visible in `stats` and in the digest.

**A head that moves mid-review retires the job; it is not a failure.** The
skill resolves the PR's head itself, so a turn that started on A and finished
after B was pushed reviewed **B** and published its status on B. The worker only
ever looks at A, so that successful turn reads as `unknown` — and treating it as
a failure would re-review B, spend a review attempt, and eventually dead-letter
a PR that is in fact being reviewed. So before recording a no-verdict failure
the worker reads the PR's current head; if it differs from the claimed sha the
job is retired as `superseded` via `abandon`, which charges **no** attempt and
is not counted as `dead` or `lost`. A dispatch for B is already on its way, so
nothing is dropped. An unreadable head is *not* evidence of a move: the worker
falls back to the normal no-verdict failure, because retiring a job whose review
genuinely failed would lose it.

**A dead row is retryable, but only on an explicit `force`.** The budget is
spent on an *outage* — a dead gateway, a spent quota — and once that is fixed
the PR still has no verdict. So `enqueue --force` on a dead key reopens the same
row (budgets reset, `last_error` cleared, `queued_at` moved, `enqueued_at`
preserved) and records a `reopen` event; without `force` it stays `duplicate`
(rc 76). The asymmetry is deliberate: an automatic reconciler retry must not
resurrect a job that already exhausted its budget, or a permanently broken
review would spin forever. Before this, a dead key answered `duplicate` even
with `force`, so the only ways out were a new commit or hand-editing the
database — the operator-retry path the table in §2.2 promises did not exist.

### 2.6 Exit-code contract (unchanged for producers)

`scripts/qa-dispatch-pr-review.sh` keeps its argument order and meaning, and in broker mode returns:
`0` enqueued · `2` usage/validation · `75` nothing queued (broker/DB unreachable) · `76` duplicate refused.

**`0` requires a 2xx AND an explicit `rc` in the body.** `curl` exits 0 on a 502, and a proxy error body has no `rc`, so defaulting a missing `rc` to 0 reported "enqueued" for a row that does not exist — the reconciler then treats the review as dispatched and the PR never gets a verdict. The dispatcher asks curl for `%{http_code}` on its own line and classifies anything that is not 2xx-with-an-`rc` as `75`.
The producers (`qa-autoreview.yml`, `external-pr-review.yml`, `qa-tier-recheck.yml`, `qa-review-reconcile.sh`) do not change.

### 2.7 Durable store

Broker state lives in the **broker's own transactional store**, because the dedupe/lease/supersede invariants need transactional key uniqueness (`UNIQUE(repo,pr,head_sha)` + a partial unique index on `(repo,pr) WHERE running`) that a message queue does not provide. Approved substrate, in order of preference:

1. **Single-replica broker + Longhorn RWO PVC + SQLite** — zero new infrastructure: `hydra-qa` already holds Longhorn PVCs (`qa-reconcile-state`, `qa-approval-retry-state`) and the namespace exists. This is the shipping choice; it needs one Deployment and one 2Gi PVC.
2. **Postgres** (`databases` namespace, operator-managed) if multi-replica brokers are wanted later — same SQL, `FOR UPDATE SKIP LOCKED` replaces `BEGIN IMMEDIATE`. Never on n17/n19.
3. **elasticmq** (the SQS-compatible broker already running in the `queuing` namespace) is approved as the *wake-up transport* for workers — a worker that long-polls SQS instead of the broker's HTTP API. It is **not** the authoritative store: SQS has no cross-message uniqueness, so "the same key is never reviewed twice" would still need the state table, and running both would add a hop without removing the store. Use it when worker polling load justifies it; nothing in this design depends on it.

### 2.7.1 The broker reaps itself

`reap()` runs on a timer **inside the broker process** (`QA_BROKER_REAP_INTERVAL_S`,
default 60s), not from a worker or a cron. A worker cannot own the reaper — a
worker is exactly the thing that dies — and the digest is an hourly cron that may
not be installed. The broker is the one process whose whole job is to be up, and
it is the single writer, so the reap is serialized with every claim by
construction. Without it a killed worker's row stays `running` forever: depth
reads zero, no replacement can claim it, and the PR is lost operationally even
though the queue is intact.

### 2.7.2 Two timestamps, two jobs

`enqueued_at` is the **original arrival** and is never rewritten. `queued_at` is
when the row most recently entered the queue, and a forced re-review moves only
that. The split exists because the two uses conflict:

- **Accounting** needs an immutable arrival, or the identity
  `arrivals == open + terminal + lost` breaks. Reopening used to move
  `enqueued_at` into the current window without adding an `enqueue` event, so one
  reopened old row plus one newly deleted job read `lost_window=0` while
  `lost_total=1` — the loss alarm was cancelled by an unrelated re-review.
- **Wait time** needs the most recent queue entry, or a re-review's wait is
  measured from an arrival days ago and inflates p95.

So `lost` windows on `enqueued_at`, and depth age, wait p50/p95 and claim
ordering use `COALESCE(queued_at, enqueued_at)`.

### 2.8 Transport contract — the queue is the broker's, not the caller's

The store above lives in the **broker pod's** filesystem, so a dispatcher running
on node-8 or a CI runner cannot write it. `qa-dispatch-pr-review.sh` therefore
POSTs to `${QA_BROKER_URL}/enqueue` and only uses the local CLI when
`QA_BROKER_URL=cli` (tests, single-host). Writing a node-local SQLite file would
return 0 while the broker's queue stayed empty — a silent drop with a success
exit code, which is the exact failure class this whole design exists to remove.

HTTP status is not the contract; the **body's `rc`** is, because the CLI's exit
codes are not valid HTTP status lines (`76` would be written as `HTTP/1.1 76`,
which curl reports as a failed connection rather than a duplicate):

| Endpoint | HTTP | body `rc` | meaning |
|---|---|---|---|
| `/enqueue` | 200 | 0 | queued |
| `/enqueue` | 409 | 76 | duplicate / superseded |
| `/claim` | 200 | 0 | a job |
| `/claim` | **200** | **1** | nothing to claim |
| any | 400/404 | 2 | usage / unknown route |
| any | 500 | **3** | internal error |

`rc 3` is deliberately distinct from `rc 1`: a broker that cannot read its own
store must never look like an idle queue, or accepted PRs wait with no worker
error anywhere. The worker logs it loudly and backs off.

`/claim` deliberately does **not** answer `204`: a 204 cannot carry a body, and
the worker reads the body's `rc`, so an empty body parses as `2` ("malformed") —
an idle worker then logs a claim error every poll forever and a one-shot worker
never exits. The client is defensive in the same direction: an empty body on
`/claim` is `rc 1`, not `rc 2`.

**`rc` means the transport result on every answer, and nothing else.** `fail()`
used to return the review turn's own exit code under `rc`, so a *successful*
`/fail` answered `rc: 1` and the worker read it as "nothing claimed". The review
turn's code is now `review_rc`; `rc` is reserved for the table above.

### 2.8.1 Mutations are authenticated

Every `POST` requires the shared `QA_BROKER_TOKEN`, sent as
`X-QA-Broker-Token` (or `Authorization: Bearer`). Without it, any pod that can
reach the service could `POST /claim` and `/finish` with a worker name of its
choosing, record a `go` for a PR nobody reviewed, and consume the job so the
real review never runs. The queue is the only thing between a PR and a verdict,
so an unauthenticated write is a way to forge one.

**It fails closed.** With no `QA_BROKER_TOKEN` configured the broker answers
`503` to every mutation rather than serving them openly. The escape hatch is
explicit — `QA_BROKER_ALLOW_UNAUTHENTICATED=1` — and exists for local CLI use and
the test suite, never for a deployment. `GET /healthz` and `GET /stats` stay
open: the digest and the liveness probe must not need the secret.

### 2.8.2 A malformed cap is a misconfiguration, not "unlimited"

`_env_int` returns its default on an unparseable value, and every cap's default
is `0` = unlimited. So `QA_BROKER_MAX_RUNNING=bad` (a typo, a stray quote, a
templating bug) silently removed the ceiling and let every worker claim at once
against one model route and one GitHub REST budget. Caps are read through
`_env_cap`, which raises on a malformed or negative value; the caller answers
`500`/`rc 3` and the worker logs it loudly. A cap that cannot be parsed is never
a request for no cap.

---

## 3. Scaling numbers (inbox 002.2)

### 3.1 Shape

- **Reviewers = the `qa-review-gateway` Deployment**, un-paused. Each pod is one reviewer: its own openclaw gateway (local mode) with the `qa` agent, its own `/var/lib/hydra-qa`, its own scratch. N pods = N independent review lanes.
- **Broker = a separate Deployment** (`qa-broker`), 1 replica + its Postgres/PVC, Service `qa-broker.hydra-qa.svc:8080`.
- **Autoscaler = KEDA `ScaledObject`** on queue depth: **`minReplicaCount: 4`, `maxReplicaCount: 24`** (approved), trigger = broker `/stats` queue-depth metric (`queued + running`), target ~4 jobs per pod, `cooldownPeriod: 120`, `pollingInterval: 15`. The first ramp starts the effective ceiling at 16 and widens to 24 once the wait p95 holds under 15 min; the manifest's max is 24 from day one so the ceiling is a KEDA setting, not a redeploy.
- The existing CPU HPA is replaced by the KEDA ScaledObject for this Deployment (two autoscalers on one Deployment is not allowed).

### 3.2 Pod requests — "small, measured"

Current: `2 CPU / 4Gi` request per pod. That number was chosen for a gateway that also serves chat traffic; a reviewer pod spends most of its life waiting on the DeepSeek API.

**Approved posture:** the 2 CPU / 4Gi request is far too big for a reviewer that is API-bound. **Measure one live review first**, then set `requests` near its p95 — expected `250m–500m CPU / 1Gi`. Start at `requests: 500m / 1Gi`, `limits: 2 CPU / 4Gi`; after the first hour of real traffic, replace the request with `p95 x 1.25` from metrics-server and post both numbers. The `2 CPU / 4Gi` figure in the current Deployment was sized for a chat-serving gateway, not an API-bound reviewer.

| Replicas | Requested CPU | Requested mem |
|---|---|---|
| 4 | 2 cores | 4Gi |
| 16 | 8 cores | 16Gi |
| 24 | 12 cores | 24Gi |

Against measured spare (≈56 cores / ≈450Gi on the `-aw` pool), 24 pods at 500m/1Gi use ~12 cores and ~24Gi — roughly a fifth of the CPU spare and a twentieth of the memory spare. Even at the current 2 CPU/4Gi request 24 pods would fit; the smaller request simply leaves the busiest nodes room. **Post-rollout measurement gate:** after 1 h, read actual p95 CPU/memory per pod from metrics-server and set requests to `p95 × 1.25`; post both the requested and measured numbers to `#clio_devops`. The Deployment has never run, so no honest per-pod usage number exists yet — that measurement is the first thing the live run produces.

### 3.3 Placement rules (inbox 002.3)

**Soft anti-affinity, not hard.** A hard `requiredDuringScheduling` affinity pinned the current Deployment to `ovh-node-29` (a give-back box) and to 67/68-pdp, and a hard exclusion would leave pods Pending whenever the preferred pool fills. The approved posture is a **soft** `preferredDuringSchedulingIgnoredDuringExecution` anti-affinity against the give-back boxes plus the measured spare list as preference: the scheduler avoids them when it can and still places a pod when it cannot. The one hard constraint kept is "not a control-plane / not a tainted pdp box", which the absence of the data-processing toleration already enforces.

**Preferred-avoid (soft) — pods should not land on:**
`node-49-pdp`, `node-50-pdp`, `ovh-node-29`, `ovh-node-20`, `node-28`, `n17`, `n19`, `ovh-node-19`
(the five give-back/Mongo boxes plus the two Postgres hosts; absent names are harmless).

Enforced as:
1. `preferredDuringSchedulingIgnoredDuringExecution` `nodeAffinity` with `kubernetes.io/hostname NotIn [<list>]`, weight 100 — a strong preference the scheduler honours whenever an alternative node has room.
2. **Drop the `dedicated=data-processing` toleration.** The pdp boxes are `NoSchedule`; without the toleration the scheduler cannot place there even if the affinity is edited later. This is the hard half, and it also fixes the current wrong pin to `ovh-node-29`.

**Preferred — measured spare, weighted:**
`node-33-aw`, `node-34-aw`, `node-40-aw`, `node-41-aw`, `node-43-aw` (weight 100, ~12 cores/76Gi each), `node-59-aw` (weight 80, 7.5 cores/195Gi), `node-57-aw`, `node-58-aw`, `node-60-aw` (weight 40).

**Spread:** keep `topologySpreadConstraints` on hostname, `maxSkew: 1`, but change `whenUnsatisfiable` to `DoNotSchedule` only if 16 pods across ≥9 nodes is provable; otherwise `ScheduleAnyway` (safe).

**Node-8 is fallback only.** `ovh-node-8` (node-8) stays out of the preferred list. The node-8 systemd pool + cron dispatch remains installed and `QA_DISPATCH_MODE=broker` falls back to it when the broker is unreachable.

**No new servers, no new spend:** everything above reuses the existing cluster, the existing longhorn storage, the existing KEDA and the existing broker namespace.

### 3.4 Throughput expectation (why 4–16 is enough)

Measured on node-8: **29.6 reviews/h, p50 129 s, p95 264 s, max 489 s** (`data/node8-to-pods-fable-a2/report.md`, m2). One reviewer lane ≈ 27 reviews/h at p50 129 s. Four lanes ≈ 100/h; sixteen ≈ 400/h, far above observed demand (29.6/h average). The bottleneck is the queue and the wait, not raw capacity — so min 4 is already ~3× today's throughput, and 16 is the burst ceiling. Starting at 16 rather than 24 leaves headroom on the busiest `-aw` nodes while proving the metric works.

---

## 4. The bounded reconciler (inbox 001)

The reconciler stays a **detector**, not the queue — but it stops being a monolith. Five changes:

1. **Per-tick wall-clock budget** (`QA_RECONCILE_TICK_BUDGET_S`, default 600 s vs the 1800 s systemd timeout) and a **per-repo budget** (`QA_RECONCILE_REPO_BUDGET_S`, default 90 s). When a budget is exhausted the tick stops cleanly and **writes state**, then defers the remainder.
2. **Round-robin cursor** persisted in state (`__meta__.next_repo_index`): the next tick starts at the repo after the last one processed. No repo starves; the 1800 s SIGTERM can never truncate the tail again.
3. **Incremental change detection.** Persist a per-PR fingerprint `(head_sha, updatedAt, qa_review_status_state, status_updated_at)`. If the fingerprint is unchanged since the last **completed** tick and the PR is not a candidate, skip all per-PR reads. Force a full sweep every `QA_RECONCILE_FULL_SWEEP_EVERY` ticks (default 4 = hourly) so a missed signal cannot hide.
4. **Read reordering** (cheap → expensive): commit → in-scope → grace/cooldown/suppressor → only then reviews + status. Today reviews and status are read *before* grace/cooldown, so every PR in cooldown costs 2–3 pointless calls. Reordering removes the majority of reads during a storm.
5. **Checkpointed state writes** after each repo (atomic), not once at the end. A kill loses at most one repo's bookkeeping.

Plus: paginate the PR list instead of a 1000-row cap (`--paginate`), so truncation pages stop firing and no PR is invisible. The truncation guard remains as a belt-and-braces check on the paginated result.

**CronJob change:** in `hydra-qa`, `qa-review-reconcile` gets `activeDeadlineSeconds: 660` (budget + margin) so Kubernetes enforces the bound, not a SIGTERM after 30 min. `concurrencyPolicy: Forbid` stays. The node-8 systemd unit's `TimeoutStartSec` drops to 660 to match.

---

## 5. Metrics and the hourly Slack line

Broker `GET /stats?window=3600` returns JSON: `depth`, `running`, `oldest_queued_age_s`, `wait_p50`, `wait_p95`, `done_1h`, `verdicts{go,no_go,cannot_review,unknown}`, `dead`, `retries`, `by_repo{depth,oldest}`.

- **One line per hour** to `#clio_devops` (`C0ADV2W76G4`, via `scripts/lib/slack-notify.sh`):
  `QA queue: depth=3 running=4 wait p50=42s p95=6m12s verdicts=17/h failures=1 oldest=2m10s`
  plus the oldest job's PR URL when depth > 0. Default: only when there was activity or depth > 0; `QA_DIGEST_ALWAYS=1` posts idle lines too.
- **Page** (not digest) on: dead > 0; depth > 20 for 15 min; no worker heartbeat 5 min; wait p95 > 15 min for two consecutive hours (the definition-of-done metric).
- **Dedupe metrics are first-class** (inbox 002 asks for them): `duplicates_dropped_1h`, `superseded_1h`, `lease_expired_1h`, `active_reviews_per_pr_max` (must be 1). A non-1 max is an alert.
- Prometheus: the broker exposes `/metrics`; the KEDA trigger reads the same queue-depth gauge, so autoscaling and the digest cannot disagree.

### 5.1 Lost jobs — the metric that proves nothing vanished (inbox 005)

`lost_window` / `lost_total` = **arrivals − (open + terminal)**, where arrivals are
counted from the append-only `events` log (`kind='enqueue'`), NOT from the `jobs`
table. Counting both sides from `jobs` makes the subtraction identically zero, so
a deleted row would be invisible — the metric would be tautological. The events
row is written in the same transaction as the insert, so it is the durable record
of what was accepted. Any non-zero value pages: it means a job was accepted and
then disappeared, which is the one failure a durable queue must never have
silently. Pinned by `qa-broker.bats` ("a row deleted behind the broker's back is
counted as lost").

### 5.2 Fleet-wide in-flight cap (inbox 005)

`QA_BROKER_MAX_RUNNING` (default 0 = unlimited) is enforced in `claim()`, the
single writer. The per-repo cap stops one repo monopolising the workers; this one
stops the WORKERS monopolising the shared model route and the shared GitHub REST
budget. Scaling to 24 pods must not mean 24 simultaneous reviews against one
quota, so the cap lives in the broker rather than in each pod.

### 5.3 Shared GitHub REST budget (inbox 005)

Every review spends REST calls under ONE App installation, so N pods share one
budget. `scripts/lib/qa-gh-budget.sh` probes `gh api rate_limit` (free — it does
not count against the limit), caches the result in a shared file for
`QA_GH_BUDGET_TTL_S` (300s) so 24 pods do not each poll, and reports
`ok:<n>` / `low:<n>` / `unknown`. The worker refuses to claim below
`QA_GH_BUDGET_FLOOR` (800) or when the budget is unknown — claiming a job it
cannot finish burns a review slot and ends in a false `CANNOT REVIEW` on a real
PR. A stale cache survives a transient probe failure; a probe failure with no
cache is `unknown`, never `ok`.

**The stale fallback is bounded** (`QA_GH_BUDGET_MAX_STALE_S`, 1800s). A probe
that fails *forever* — revoked token, DNS, a proxy answering 500 — would
otherwise keep serving the last good reading, and a stale `ok:5000` authorizes
claims indefinitely while the real budget drains to zero. Past the bound the
answer is `unknown`, which the worker treats as "do not claim": fail closed,
never fail open.

**The probe is scoped to the identity the reviews spend.** `qa-gh.sh` only
picks the GitHub App installation when it is given `--repo` (or
`QA_GH_IDENTITY=app`); an unscoped call uses the ambient **host** account. So an
unscoped `api rate_limit` measures the host's quota, not the installation's —
and in App mode those are different budgets. The host can read 5000 remaining
while the installation the reviews actually spend is exhausted, the gate says
`ok`, and every review then 403s mid-turn into a false `CANNOT REVIEW` on a real
PR. The probe therefore passes `--repo` (`QA_GH_BUDGET_REPO`, defaulting to the
first entry of `policies/qa-approval-policy.json` `.identity.app_repos`), and
the cache records its `scope` so a reading taken under one identity is a **miss**
for another rather than an answer. One installation is assumed: its quota is
shared across all its repos, so any repo in `app_repos` answers for all of them.
The worker's own status reads pass `--repo` for the same reason — the read must
measure the identity the review writes with.

### 5.4 The digest is one line, and it pages separately

`scripts/qa-broker-digest.sh` posts ONE line per hour (a channel that gets a wall
of text every hour gets muted, and a muted channel is the same as no monitoring)
and a second, louder line only when a threshold is crossed: `lost > 0`, `dead > 0`,
`depth > QA_DIGEST_DEPTH`, `oldest > QA_DIGEST_OLDEST_S`, or `p95 > QA_DIGEST_P95_S`
for `QA_DIGEST_P95_STREAK` (2) consecutive hours — one slow hour is a burst, two is
a trend, and the streak is persisted in `QA_DIGEST_STATE`. An unreachable broker
renders `UNKNOWN`, never `depth 0`: an unreadable queue is not an empty queue.

---

## 6. Rollout, fallback and rollback

| Stage | Action | Gate |
|---|---|---|
| 0 | Merge the broker + worker code + profile changes (node-8 path untouched, `QA_DISPATCH_MODE=gateway-cron`) | CI + QA verdict format unchanged |
| 1 | Deploy broker (1 replica) + KEDA ScaledObject min 4 / max 16; keep `spec.paused: true` | broker `/stats` reachable; lease/dedupe tests green |
| 2 | **Un-pause reviewers and run live as soon as the code works** (Aaron's live-first rule), flip `QA_DISPATCH_MODE=broker`; KEDA drives 4→24 on queue depth | post wait p50/p95 as soon as the first parallel reviews land; drift captures the manifests |
| 3 | Raise to 16 if p95 wait < 15 min and measured pod usage justifies the request size | post measured CPU/mem |
| 4 | Revert = set `spec.paused: true` + `QA_DISPATCH_MODE=gateway-cron` | queue drains or is drained by the reconciler |

**Kill switches:** pause reviewers (`spec.paused`/replicas 0) — producers keep enqueueing, nothing is lost; revert dispatch (`QA_DISPATCH_MODE=gateway-cron`) — cron path exactly as today; revert model (`QA_WORKER_MODEL`) — same queue, previous model.

**node-8 fallback: there is deliberately NO automatic one.** The systemd pool and the cron dispatch stay installed, and `QA_DISPATCH_MODE=gateway-cron` reverts to them, but `qa-dispatch-pr-review.sh` does **not** fall back on its own when the broker is unreachable: it exits **75** (`BROKER-UNAVAILABLE`) and the reconciler retries with backoff.

An earlier draft of this section promised a silent fallback to the cron path. It was dropped because it is worse than the failure it hides:

- **It double-dispatches.** The broker may have accepted the enqueue and lost only the response, so falling back would review the same head twice — and the cron path has no dedupe against the broker's queue.
- **It reintroduces the bottleneck invisibly.** The cron path is the serial one-agent lane this work exists to replace. Falling back to it under load is exactly when it is slowest, and the PR would look dispatched while waiting an hour.
- **It hides the outage.** A broker that is down is an incident. Exit 75 is a signal the reconciler and the digest already act on; a fallback would turn it into silence.

So the safety net is the **queue**, not a second dispatcher: a producer that cannot reach the broker has queued nothing, and the reconciler re-runs it. Reverting to cron is a deliberate operator action (`QA_DISPATCH_MODE=gateway-cron`), never an automatic one.

---

## 7. Model route

Reviewer pods keep the same skill, prompt and verdict format. The model is `deepseek/deepseek-v4.1-flash-1017` on the OpenRouter route with ZDR (`provider: {data_collection: "deny"}`), the same posture as the credit-verification direct-HTTP path (`scripts/credit_verify/docverify/extract.py`), temperature 0. **No fallbacks** on the reviewer model: a fallback to a non-ZDR route would break the privacy guarantee; a failed call retries through the queue instead. `QA_WORKER_MODEL` overrides to `openai/gpt-6-sol` without touching the queue.

ZDR verification gate before N=16: read OpenRouter's generation metadata for the first two reviews and assert the data policy; if openclaw cannot enforce it per request, enforce ZDR-only at the OpenRouter account level and note it in the PR.

### 7.1 The turn invocation is a real CLI contract, not a guess

The worker runs one synchronous turn per job:

```
openclaw agent --agent qa --session-id <fresh id> \
  --timeout <QA_REVIEW_TIMEOUT_S> --json --message <prompt> [--model <QA_WORKER_MODEL>]
```

**`--session-id`, never `--session`.** The installed CLI has no `--session`
option and rejects the whole invocation (`OpenClaw does not recognize option
"--session"`), so a worker that passes it dies before the agent starts: the job
is retried as a review failure and then dead-lettered with no `qa-review`
verdict, which is the exact silent-drop this queue exists to prevent. A fresh
id per job is what gives each review its own isolated session. The live-verified
reference for this form is `scripts/lib/websearch-probe.sh`, which also
establishes that `--timeout` is the gateway-side bound and the outer `timeout`
must sit above it so it never wins the race.

**The test stub parses like the real CLI.** A stub that accepts any flag cannot
catch an invocation the binary rejects, and that is how `--session isolated`
shipped green. `scripts/tests/qa-worker.bats`'s `openclaw` stub accepts only the
documented option set and exits 1 on anything else, so an unsupported flag fails
the suite instead of production.

---

## 8. Tests

| # | Test | Asserts |
|---|---|---|
| 1 | `broker: same key twice while queued` | second call returns `duplicate`/rc 76; one row |
| 2 | `broker: same key while running` | duplicate; no second active review |
| 3 | `broker: same key when done (GO)` | duplicate by default |
| 4 | `broker: same key when done (NO-GO)` + force | accepted, capped at 2 |
| 5 | `broker: newer head supersedes queued older` | older `superseded`, new `queued` (with `--current-head`) |
| 5b | `broker: delayed OLDER head does not cancel the current head` | both rows stay `queued`; the current head is still claimable |
| 5c | `broker: no --current-head → nothing superseded` | fail-safe default |
| 5d | `dispatch: stale head` | `STALE-HEAD`, exit 0, nothing enqueued |
| 5e | `dispatch: current head` | enqueued with supersede rights; a second head supersedes the first |
| 5f | `dispatch: head lookup failed` | still enqueues, without supersede rights |
| 6 | `broker: newer head during running` | `supersede_requested=1`; verdict still posted; new key enqueued |
| 6b | `broker: non-owner fail` | `not_owner`, row untouched, the real owner can still finish |
| 6c | `broker: reaped job failed late` | `not_owner`; the reaper's requeue stands; no attempt consumed |
| 6d | `broker: transport retries do not spend the review budget` | 3 transport + 2 review failures still `queued`; the 3rd review failure is the one that dead-letters |
| 6e | `broker: a lease expiry spends the review budget` | `review_attempts=1`, `transport_attempts=0` |
| 6f | `worker: a turn that publishes no status is requeued` | `queued`/no verdict, `review_attempts=1`, never `done` |
| 6g | `worker: a status that appears during the grace window` | normal `done`/`go` |
| 6h | `budget: a permanently failing probe stops trusting the cache` | past `MAX_STALE` → `unknown`, not the stale `ok` |
| 6i | `dispatch: a 502 with a JSON body and no rc` | exit 75, never "enqueued" |
| 6j | `dispatch: a 200 with no rc in the body` | exit 75 |
| 6k | `worker: a forced re-review does not finish on the PREVIOUS verdict` | `queued`/no verdict, not the stale NO-GO |
| 6l | `worker: a status posted AFTER the baseline is this run's verdict` | normal `done`/`go` |
| 6m | `worker: a qa-review status from another actor` | not this run's verdict; requeued |
| 6n | `worker: a bodyless 502 from the broker` | transport failure, never "queue empty" |
| 6o | `worker: a JSON 502 without rc` | transport failure, never a claim |
| 7 | `broker: lease expiry re-queues` | row back to `queued`, attempts preserved, exactly one active |
| 8 | `broker: one_active_review_per_pr index` | concurrent claims → one wins |
| 9 | `broker: restart survival` | kill broker mid-run, restart → queued rows intact |
| 10 | `broker: dead-letter + page` | attempts exhausted → `dead`, page payload |
| 11 | `broker: fairness` | repo A×5 + repo B×1 at 2 slots → B before A's 3rd; per-repo cap |
| 12 | `worker: prompt equality` | worker message byte-identical to the legacy cron path |
| 13 | `worker: transport failure` | rc 75/timeout → retry with backoff, never silent |
| 14 | `worker: NO-GO turn` | rc 0 → `done`, not dead |
| 15 | `reconcile: budget bound` | tick stops at budget, state written, cursor advances |
| 16 | `reconcile: no starvation` | two ticks cover all repos exactly once (cursor) |
| 17 | `reconcile: changed-only` | unchanged fingerprint → zero per-PR reads; full sweep every 4 ticks |
| 18 | `reconcile: checkpoint` | kill after repo 2 → repos 1–2 bookkeeping persisted |
| 19 | `verdict contract` | three tokens; `GO→success`, `NO-GO/CANNOT→failure`; status states unchanged |
| 20 | `placement` | rendered manifest has no forbidden hostname and no data-processing toleration |

Integration drill (documented in the PR, run before N=16): restart drill — enqueue 3 real PRs, restart the broker and one reviewer mid-run, assert all reach `done`/`dead` with zero `queued` orphans; no-lost-dispatch proof — stop reviewers 10 min with 2 rows queued, restart, both complete, and `enqueue count == done+dead+superseded`.

---

## 9. What does not change

The three verdict tokens (`GO`, `NO-GO`, `CANNOT REVIEW`); the `qa-review` status state machine (`pending`/`success`/`failure` posted through `scripts/qa-gh.sh` under the QA App identity so branch-protection app-pinning still works); the requester-UID resolution and approval tier (`scripts/lib/qa-author-slack-uid.sh`, `qa-pr-approve.sh`); the skill, prompt and comment/thread semantics; the producers' CLI contract. Only the launch and bookkeeping mechanism changes.

---

## 10. Open items to confirm during build (not blockers to posting)

1. Postgres for the broker vs single-replica SQLite on Longhorn — choose Postgres if the operator cluster accepts a new database; otherwise SQLite. Same SQL either way.
2. Whether openclaw can enforce ZDR per request on the openrouter provider; if not, enforce account-level and document.
3. `whenUnsatisfiable: DoNotSchedule` for topology spread — only if 16 pods across ≥9 nodes is provable.
4. The H-DevOps side (`k8s/prod/hydra-qa/`) needs the Deployment/HPA→KEDA/affinity/placement changes; this PR ships the hydra-side code + profile + this design and the manifest diff as a patch for H-DevOps.

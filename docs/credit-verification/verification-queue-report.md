# The captain's every-30-minutes queue report

Captain 2026-10-26 ~20:40Z (verbatim): "i want a report every 30 min in slack how many
credits and profile verification are open by group (haven't been touched by us, approved in
last 24 hrs, awaiting documentation and communicated with, awaiting documentation without
communication, any other category you think i should know about)". Profile verification =
profile claims.

`scripts/verification-queue-report.py` · `/etc/cron.d/verification-queue-report` (every 30
min, written by `scripts/install-aux-units.sh`) · DM to the captain (`U7RP6HKUZ`) as the
devops bot · kill switch `touch /etc/hydra/verification-queue-report.disabled` (the
`--dry-run`/`--json` diagnosis paths still work while it is set).

## What it measures

A third table, **PROFILE MERGES**, covers the merge queue: nobody has touched them yet,
waiting on the user (must claim the duplicate first), held for a person (contested / conflict /
intake stale) — all three read from the ClickUp *User Requests* list (`901000600160`,
`action:profile-merge`, three single-status walks: the CLI silently ignores a multi-status
filter and pages the whole list in ~3 min) — plus executing/stuck (`profile_merges`
`callback_received` + `unverified`) and done in the last 24h. Rows this host cannot measure say
so: core records no row when a merge is refused, so *declined/closed in the last 24h* is
unmeasured until the resolved-ticket read is wired.

Every report also carries the captain's pause banner at the top: _"Paused by captain order
23:30Z: approvals of validator-declined rows, name-match, claim approvals other than one-time
code."_ It sits there until firstmate says the order is lifted — without it a flat
"never touched" number reads as a broken machine instead of an obeyed order.

| | CREDITS | PROFILE CLAIMS |
|---|---|---|
| population | `credit_requests`, `deletedat IS NULL`, status not `approved`/`rejected` | `claiming`, `deletedat IS NULL`, status `pending` |
| paid | the row's `workspaceid` holds an active/trialing subscription | the row's `teamid` does |
| approved last 24h | rows that reached `approved` (`updatedat` window) | rows that reached `processed` |
| declined last 24h | rows that reached `rejected` | rows that reached `rejected` |

Everything per row prints users / requests (or claims) and, in brackets, the paid users,
"paid" being counted on the ROW-owner's paid status, then the oldest age in the bucket —
that is the age of the longest-open row there, not the newest.

## The buckets, in precedence order

First match wins, so the buckets partition the open population exactly and
`total open = sum of the buckets` (the script self-checks this on every run and reports the
mismatch instead of printing a total it cannot defend).

1. **Held for fraud / watchlist** — the user (or, for claims, the claimed profile) is in
   `policies/fraud-watchlist.json`. Both tiers (`fraud`, `review`) hold an approval.
2. **User sent documents — we owe a look** — ONLY evidence that a document arrived *after*
   the request it serves: core recording a `proofRequest.responseAt` later than that row's
   `createdat`, or a dated ledger proof reply later than the user's newest open request. An
   undated `proof on file` hold does **not** count — the proof feed carries no timestamps, so
   such a hold is structurally an old accepted document and the decider itself files it as
   "human review" (see the Fable ruling below).
3. **Sitting with a person** — a `support` write (a support ticket/ask was raised), a
   human-review hold (`emailed support@`, `support already requested`), the user replying
   to a note (`extension_requested_at`), a flagged refusal hold already posted to
   #cs_priority, or the user being in the proof feed's `gmail_contacts_90d`.
4. **Muted — no more messages** — a messaging refusal hold whose `next_recheck_at` is
   still in the future.
5. **Needs documents — user told** — an ASK note went out (`verify-live`, `retro-past`,
   `uvn-status`, `gap-ask`; `sent` or `attempted`) or core stamped
   `proofRequest.noticeSentAt` / `infoRequest.responseAt`.
6. **Not touched by us at all** — no ask, no message and no decision has EVER been written
   for that user. This is the bucket to act on, so it is measured strictly: one status note
   in the ledger moves a user out of it.
7. **Needs documents — user NOT told** — we decided something (a hold, a defer) but never
   asked the user for the document.

Claims are classified with CLAIM-scoped facts only: a claim note in the ledger
(`request_ids_json` carries `claim-<claiming.id>`), the claimant emailing support@, the
watchlist. A credit decision says nothing about a claim and must never make one look
touched.

## Deliberate limits

- **Not an Intercom assignee census.** "Sitting with a person" means our own machinery
  handed the row to a human (support write / human-review hold / reply / flagged hold /
  support@ contact). Mapping Intercom `admin_assignee_id` to a Muso user id per run is not
  reliable enough to put in a number the captain acts on; the open-conversation arithmetic
  already lives in the ops steward's `s1_tick.py` scoreboard.
- **Read-only.** Trino replica (with `query_max_execution_time='90s'` and a hard subprocess
  timeout), the hydra ledger opened `mode=ro`, and two local JSON feeds. The only writes
  are one Slack DM and `/var/lib/hydra/verification-queue-report/last.json`, which is what
  makes the arrows — under `/var/lib`, never `/opt/hydra`, which the deploy rsyncs away.
- **Runtime ~35s** on node-8 (the Trino round-trip dominates), against a 30-minute cadence.
  `flock` in the cron line stops a manual run from double-posting into the DM.
- **The first run prints no arrows.** There is no previous report to compare with; that is
  not an error.

## The headline: three decision buckets (Fable, firstmate 014)

The report opens with these, and **no raw status count** — a status name ("unverified") is not a
decision, and the running 10K figure it produced was a source of confusion rather than
information:

```
*HEADLINE*
*Awaiting US* · 5,625 users / 65,822 requests (1,521 paid)  — we owe the next move
*Awaiting the USER* · 1,734 users / 17,797 requests (498 paid)  — we asked, the ball is theirs
*DECIDED-NOT-CLOSED* · 160 users / 907 requests (paid not measured)  — ruled, the write never landed  (no outcome recorded 726, shadow 141, skipped:expected_status_mismatch 33)
```

- **Awaiting US** = `untouched` + `not_told` + `docs_in` + `human` (we owe the next move).
- **Awaiting the USER** = `told` (we asked; the ball is theirs).
- **DECIDED-NOT-CLOSED** = a ruling exists in the ledger but its write never landed. Read from
  the ledger alone, so it runs on node-8 with no Mac and no tray files: for every apply-mode
  `approve`/`support` decision in a 7-day window, the latest `decision_outcomes` row decides
  whether it executed (`approve → approved`, `support → user_verification_needed`). **A missing
  outcome is the loudest case** — the write was never attempted or never returned — and it is
  counted, never assumed done. The block names the reasons rather than totalling them.
- `watch` / `muted` rows are a gate, not a decision, so they stay in the CREDITS / CLAIMS tables
  and are not in the headline.
- An unreadable ledger makes that third bucket read **unmeasured**, never "0 decided".

## Comms coverage — who is still owed a message (captain 2026-10-27 20:1xZ)

> "are you sure all users that need to be communicated have been already? If not get on it —
> make this a durable process that does not rely on my computer; do this all on OVH."

Every 30-minute report carries a COMMS COVERAGE block with five classes, each split **paid /
free** with the oldest age on each side and **the job that owns sending the message**:

| class | "never told" means | owner job |
|---|---|---|
| credits waiting on us, never told | no ask, no message and no decision has ever been written (`untouched`) | verify-ask-wiring-h2 |
| credits owing proof, never asked | we decided something but never asked for the document (`not_told`) | verify-ask-wiring-h2 |
| profile claims pending, never told | no claim note ever went out (`untouched`) | claim-lane-resume-c2 |
| profile merges pending, never told | the ClickUp ticket carries no "we have touched this" tag | merge-queue-clear-q1 |
| Intercom inbound, never answered | the customer is waiting and **no admin has ever replied** | intercom-backlog-i1 |

- **Paid is never invented.** Merges carry no plan and Intercom paid needs an account join, so
  those two classes print `paid not measured on this source` instead of `0`; credits and claims
  are split exactly from the row-owner's active/trialing subscription.
- **Paging is growth-only**: the captain is DMed when a class **grows**, or when a **paid** user
  passes **48h untold** (once per crossing, never every tick). A shrinking class is the system
  working, so it is silent. The first reading of the baseline pages nothing — "grew from 0" is
  an artefact of having no previous number.
- **Everything runs on OVH**: the block is computed and DMed by the same node-8 cron job as the
  rest of the report. Nothing about it touches a laptop, and no step needs the captain's machine.

## The backlog sentinel (captain 21:05Z)

> "no backlog should ever form from here on out for anything that is waiting on us! if it
> does get me involved immediately"

Every tick also sweeps the lanes where the ball is in OUR court. Each lane has an SLA and a
named owner. **An item is a breach when it is past its SLA now AND was not already past it at
the `2026-10-26T21:00Z` baseline.** That includes items that entered the lane before the line
but whose SLA only lapsed after it — a decider hold entered at 20:45Z with a 1h SLA was healthy
at the baseline and must still page at 21:45Z. The captain is DMed once per new breach:

```
BACKLOG FORMING: credit documents back, we owe a look 3 items, oldest 2d, owner credit-status-realtime-n1
```

| lane | SLA | owner |
|---|---|---|
| credits nobody has touched | 24h | verify-ask-wiring-h2 |
| credit documents back, we owe a look | 24h | user-decisions-fable-d1 + doc-verify-build-b1 |
| profile claims nobody has touched | 24h | claim-lane-resume-c2 |
| claim documents back, we owe a look | 24h | claim-lane-resume-c2 |
| profile merges waiting on us | 24h | profile-merge-ops-m1 |
| Intercom: the customer spoke last | 4h | cs-systemic-c3 |
| support@ emails with no reply | 4h | cs-systemic-c3 |
| decider holds only a person can clear | 1h | ops-completeness-fable-o1 |

**Why "entered" and not "created".** The clock starts when the ball moved into our court —
the document landing, the ask going out, the *start of the current* dead-end hold episode —
never the row's birthday. Two consequences that are load-bearing:

- The decider re-emits the same holds every 15 minutes. Using the LATEST decision time would
  reset the clock forever and the sentinel would never fire, so the ledger keeps the FIRST
  dead-end hold per user (`first_deadend`, `first_proof_hold`).
- `decider holds only a person can clear` counts only the marks the machine will never
  finish on its own — `validator reject rule fired` and `server approval guard would
  refuse`. A `score approval not now: …` hold is waiting for data a later run picks up by
  itself, not for a person.

**The pre-baseline backlog is not a breach.** Items already overdue **at** 21:00Z (entered +
SLA <= the line) are the legacy backlog. They are reported as one line in the 30-minute report —
`Old backlog from before the 21:00Z line · N items ▼56` — and that number **must fall every
report**: a rise pages immediately, and the same number two reports running pages as
`BACKLOG STUCK` (flat at zero is not a stall).

**A document only counts if it postdates the request (Fable, 2026-10-27).** The "credit
documents back, we owe a look" lane used to count *any* proof entry, including documents
accepted long before the request existed. Measured before the fix: of **88,492** open credit
requests, **zero** carry a core `proofRequest.responseAt` at all, and **all 752** users in the
lane came from the decider's `proof on file` hold — which reads the proof feed, and every one of
its 88,116 entries is undated. The lane could not tell a returned document from an old accepted
one. It now requires evidence:

- **core** — a row counts only when `proofRequest.responseAt` is later than that row's own
  `createdat` (exact, per request);
- **ledger** — a tagged proof counts only when `proof_tagged_at` is later than the user's
  **newest** open request. A per-user bound cannot name the request a note served, so the strict
  end is the only safe one: a worse-than-exact rule here makes the lane quieter, never louder;
- the decider's `proof on file` hold is **not** this lane. Its own sentence is "a document is
  already on file; never ask again; human review", so those users are counted **with a person**.

Prod effect: `credits_docs_in` 752 -> 0 and "sitting with a person" 824 -> 1,602, with the open
total unchanged — the work did not disappear, it moved to the lane that actually owns it.

**Held by captain order is not a backlog.** Four lanes are held by the captain's own order
(2026-10-27 00:52Z): credit documents back (`no paperwork asks until a returned document can be
accepted`), claims nobody has touched (`claim sends are behind hydra #1377 review`), Intercom
customer-spoke-last (`no new copy`), decider holds (`approvals paused until the account gate is
live`). They stay visible in the report — and in the state file's `held` block — with their
owner, the unblock step and an ETA, and they page **once per change of their item set or
blocker sentence** — never because the oldest item aged another hour (that produced 120 held
pages on 10-27) and never as "backlog forming". A lane whose blocker has shipped stops being
held and pages as an ordinary breach. A new breach in any OTHER lane still pages immediately.

**Unmeasured is never zero.** The support@ lane has no per-thread ledger on this host: the
hourly triage is an agent skill that reads Gmail and persists nothing, and `gog` needs a
keyring password. It is reported as `unmeasured`, and the report prints
`No live source on this host for: … — that lane is unmeasured, not clear`. A 0 there would
be a lie of the exact kind this report exists to prevent.

**State, for firstmate and for the next tick**: `/var/lib/hydra/backlog-sentinel/state.json`
— `{ts, baseline, breaches:[{bucket,label,owner,count,oldest_h,items}], legacy:{lane:count},
unmeasured:[…], undateable:{…}, items:{lane:{id:entered}}, intercom:{items,last_walk},
merges:{items,last_walk}}`. The `items`/`intercom`/`merges` blocks are what make the ticks
cheap: Intercom is maintained as a **delta** (conversations updated or closed since
`last_walk`), so a tick reads a handful of them instead of walking 5,262 open conversations,
which cost ~170s on its own. Delivery is its own ledger (`paged`): an item is recorded as told only after Slack confirms,
an undelivered or kill-switch-suppressed page is retried on the next tick, and an entry is
pruned as soon as its breach clears so a returning episode pages again. A lane we could not
measure keeps its last known set, its ledger, and reads `unmeasured` — a broken probe may
neither hide work nor clear what the captain was already told.
Kill switch for the pages (the report keeps running):
`touch /etc/hydra/backlog-sentinel.disabled`.

**Two ticks.** Every 30 minutes: the report plus the full sentinel (~33s). Every 5 minutes:
`--light`, the sentinel only (~2.3s) — it carries the credits/claims/decider sets from the
last full tick (re-running those two Trino queries 12x an hour would buy nothing: an item
only crosses its SLA on an age, which the light tick recomputes) but re-reads merges and the
Intercom delta, because a customer replying is the one thing that can move a waiting item
between ticks. A light tick never posts the report.

## Checking it

```bash
python3 /opt/hydra/scripts/verification-queue-report.py --dry-run   # the message, no post
python3 /opt/hydra/scripts/verification-queue-report.py --json      # the raw measurement
python3 /opt/hydra/scripts/verification-queue-report.py --selftest  # bucket fixtures
python3 /opt/hydra/scripts/verification-queue-report.py --light     # the 5-minute tick, no post
cat /var/lib/hydra/backlog-sentinel/state.json                      # breaches firstmate reads
tail -20 /var/log/verification-queue-report.log
```

Tests: `scripts/tests/test_verification_queue_report.py` (buckets, partition invariant,
arrows, the sentinel's breach/legacy/not-yet-due split, the once-per-new-breach dedupe and
the legacy stall rule) and `scripts/tests/verification-queue-report-cron.bats` (both cron.d
lines, which is the half that silently rots).

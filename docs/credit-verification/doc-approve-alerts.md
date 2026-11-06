# The doc-verified T0/T1 class's two alerts

[key=doc-approval-doctrine] Fable d2 (2026-11-03 19:30Z) ruled the class — a dv-4 verified
document may approve a T0/T1 credit, 1 per request, ≤ 50/day, provisional 7 days,
reversible — and named exactly two things to watch once it is armed:

1. **the decider approved 0 in 6 h while eligible > 0**
2. **dv-4 verified single-candidate documents with no approved_refs > 24 h**

This is that watch. The class itself is `scripts/credit_review/doc_approve.py` + the
`document_small_track` registry entry (hydra #1684 / #1685); this document covers only the
monitoring.

## The halves

| file | what it does |
| --- | --- |
| `scripts/credit-decide-watchdog.py` | evaluates the two alerts, `--json` for machines, `NO_REPLY` when quiet |
| `scripts/credit-decide-watchdog.sh` | the only thing that POSTS (through `scripts/lib/slack-notify.sh`, so real `<@UID>` mentions) |
| cron `credit-decide-watchdog-hourly` | `bash /opt/hydra/scripts/credit-decide-watchdog.sh`, hourly at `:17` UTC, delivery `none` (the wrapper posts) |

`:17` sits clear of the decider's `:00/:15/:30/:45`, the doc-verify reader's `:50`, D5b's
`:35` and the profile-link job's `:45`.

## What each alert actually reads

- **eligible**: the decider's OWN read-only verdict, not a smaller set of the watchdog's
  own. `scripts/credit_review/doc_measure.py` is the one measurement both this watchdog and
  the arming dry run (`credit-review.py doc-approvals --dry-run`) call, so forensics,
  cross-check, same-release, role, doc-reuse, tier, account, hold, claimant and the caps are
  all asked, and the number an operator arms on cannot drift from the number the alerts page
  on (qa-review #1766 r1 finding 4, r2 carried-forward). The CLI really does call
  `doc_measure.measure` - it used to orchestrate its own `doc_approve.dry_run`, so on an
  `AdminError` reading core it substituted empty ages and exited 0 with zero eligible rows
  while the watchdog reported BLIND on that identical failure (qa-review #1766 r5 finding 2).
  One measurement, one error contract: a core outage refuses the arming number too. A class
  whose documents all fail a
  later gate reports zero eligible rows and does **not** page a stalled decider, because zero
  approvals is then the correct answer. `per_guard` in `--json` says which gate refused what.

  It is the **cap-admitted** set, not the pre-cap `would_approve` count (qa-review #1766 r3
  finding 1). When today's 50 user slots or 10 profile slots are already spent, the decider
  correctly approves nothing, so counting those rows as approvable work would page a stalled
  decider for behaving correctly. `plan_caps` returns `admitted` and that is what the alert
  reads; the rolled rows are still reported, as `rolled_to_tomorrow` in `--json` and in the
  cron log line.
- **approved in 6 h**: `doc_approvals.approved_at` within the window, counting only the
  states that mean the class DID approve something — `provisional`, `confirmed`, `pulled`
  (`APPROVED_STATES`). `released` is not one: the core write did not confirm, so the slot
  went back and nothing was approved. `pulled` IS one: the decider approved and the pull
  sweep later reverted it, which is the decider running, not stalling.

  `indeterminate` is **not** one either (qa-review #1766 r6). Its core write outcome is
  explicitly UNKNOWN, so counting it as a completed approval asserts a fact the system did
  not measure — and it suppresses the stall alert precisely when nobody knows whether the
  decider is working. The count is reported beside the approval count instead, and the
  alert says so:

  ```
  ... The decider is not clearing the class. (1 row(s) in that window are INDETERMINATE:
  the core write outcome is unknown, so they are not counted as approvals.)
  ```

  The row still holds its slot (`_cap_refusal` and `_spent_today` count it), because core
  may have committed it. Unknown is not the same as free.
- **standing ref**: a `provisional` or `confirmed` row for that request. `pulled` and
  `released` are not refs.
- **stale**: in the eligible set, no standing ref, and the verdict that puts it there has
  itself been on file for more than 24 h (a document re-judged an hour ago restarts its own
  clock — the alert is about a *standing* verdict nobody acted on).

## Gated on the class being armed — on purpose

Both alerts fire only when BOTH switches are on: the registry entry `document_small_track`
approved (`approved: true` + `approved_by` + `approval_ref`) and
`/etc/hydra/doc-approve.disabled` absent. While the class is dormant it approves nothing
*by design*, so an hourly page about the backlog it is deliberately not clearing is noise
that trains people to ignore the alert that matters. Dormant ticks put the same numbers on
the cron log (`eligible N, approved 6h M, sitting > 24h K`) and page nothing.

The 24 h alert also covers what the 6 h count cannot see: a class that stops writing refs
while the decider keeps approving other classes still shows throughput > 0.

A **planned maintenance window** (`scripts/hydra-maintenance.sh start`) stands the watchdog
down entirely, in both halves: the wrapper sources `lib/maintenance-flag.sh` and exits before
starting python, and the python half checks the same flag so a direct invocation is guarded
too. A window stops the scheduled jobs on purpose, so "0 approvals in 6 h" is the window
talking, not a stalled decider. `--json` still evaluates, because a human asking for the
numbers during a window wants the numbers. This is the same guard every other fleet-health
watchdog carries, enforced by `scripts/tests/maintenance-guard-drift.bats`.

## Read-only, and it says when it is not running

The watchdog approves nothing, reverts nothing, arms nothing, writes no ledger row, sends
nothing to a user, and it does not run the provisional sweep (`credit-review.py
doc-approvals --pull` stays a human's command — a cron tick must not move a row between
states). It opens its stores `mode=ro` and never creates them: a watchdog that creates the
ledger it audits reports a healthy empty class.

When it cannot read its inputs it **pages** (qa-review #1766 r1 finding 6, r2 finding 1, r3
findings 2-5). It used to set `status: unreadable`, print `NO_REPLY` and exit 0, so a missing
or corrupt doc-verify/proof store — or a missing, corrupt or `decisions`-less ledger — after
arming left every tick blind while the watcher looked quiet. Silence must never be ambiguous
between "nothing to say" and "the watcher cannot see". When it cannot RUN at all, the wrapper
pages that the watchdog is **NOT running**.

Every input is now in that set, because each one used to fail into a plausible-looking number:

| input | the old failure | now |
|---|---|---|
| the ledger file | missing → "0 approvals, no standing refs" | BLIND |
| `doc_approvals` query | error → 0 approvals, empty standing set | BLIND |
| core account ages | `AdminError` → every row `claimant_no_history`, eligible 0, quiet tick | BLIND |
| the deny/hold policy | unreadable → `None` → **nobody held**, so a denied user counted as approvable | BLIND |
| the second doc-store read (verdict ages) | error → `{}` → every row looks stale → a fabricated 24 h alert | BLIND |

An unmeasured input is a refusal, not a pass. The decider itself fails closed on the same
policy, so a measurement that held nobody would disagree with the thing it is measuring.

## Operating it

```bash
# what it sees right now (machine channel; no Slack, no writes)
python3 scripts/credit-decide-watchdog.py --json

# the rendered Slack text, or NO_REPLY
python3 scripts/credit-decide-watchdog.py

# prove the delivery path without posting
CREDIT_DECIDE_WATCHDOG_NOTIFY=never bash scripts/credit-decide-watchdog.sh

# the class's own readback, for comparison
python3 scripts/credit-review.py doc-approvals --user 145833
```

Tests: `python3 -m pytest scripts/tests/test_credit_decide_watchdog.py` (evaluation, one
test per clause and per boundary) and `bats scripts/tests/credit-decide-watchdog.bats`
(delivery: NO_REPLY silence, one post per firing tick, the not-running page, argv, and the
cron entry's shape).

**CI runs the file directly (`python3 scripts/tests/test_credit_decide_watchdog.py`), not
through pytest, so the `__main__` block must stay the LAST statement in the file.** A test
class defined below it is invisible to direct invocation: `unittest.main()` discovers the
classes that exist when it is called. This file shipped that way once and CI ran 38 of 52
tests while reporting OK, hiding the cap-admission, blind-input, tier-split and
indeterminate-write regressions (qa-review #1766 r7 finding 1). `test_doc_approve.py` (122 of
125) and `test_doc_verify.py` (209 of 215) had the same shape.

`scripts/tests/test_ci_test_discovery.py` now pins the invariant for every file this workflow
invokes that way: nothing may follow the `__main__` block, and direct invocation must run the
same number of tests pytest collects. It is a scan, not three fixes, because the third
occurrence was found by the scan.

## The shadow measurement (Fable R22)

Fable R22 (2026-11-05 20:2xZ) keeps the cap in **USERS** (50 per UTC day) and tightens the bounds under
it to **5 requests per user per day** and **10 per profile per day**, `paid_first_oldest`, and asked for
the shadow period to be *measured*: "shadow 24 h would-approve users/requests per day". The 2026-11-04
ruling's 25/user is superseded.

`scripts/credit-decide-watchdog.py --shadow-report` builds that plan from the decider's eligible set,
per USER, and prints one line:

```
:bar_chart: doc-verified T0/T1 *SHADOW* would approve today: N user(s) / M request(s)
(T0 3, T1 1, unreadable popularity 0; 2 refused by the tier line, of which 1 at popularity 0;
R22 caps 50 users/day, 5/user, 10/profile; K request(s) roll to tomorrow; largest holder L).
The caps are simulated against today's ledger, so slots already spent count against the plan.
A popularity of 0 is REFUSED by the tier line (R22a D1), never counted as a small track.
```

The plan is **not a second opinion** (qa-review #1766 r1 finding 5). It asks `doc_approve.gate_tier`
about every row and hands the survivors to `doc_approve.plan_caps` — the same simulation the arming
dry run uses — so slots already spent today, the 10/profile cap, user 51 and the roll-over are the
decider's numbers. It used to start from an empty day, ignore the profile cap, drop users past the
50th from `rolled_to_tomorrow`, and count a popularity-0 track as T0 although `gate_tier` refuses it,
which overstated approvable credits.

The tier split is in the line **on purpose.** `0` is falsy in Python, so a falsiness slip anywhere on
the way to the tier gate would read a zero-popularity track as absent and route a whole cohort to the
wrong tier with nothing in the output to show it. The split makes that visible: `refused by the tier
line` counts every row `gate_tier` refused, and `of which N at popularity 0` names the R22a D1
population inside it. `unreadable popularity` counts only rows whose popularity could not be read at
all. Popularity comes from the ledger's own newest `decisions` row per request; a request the ledger
has not seen is counted **unknown**, never small.

The split counts the **cap-admitted** set, the same set the headline `N user(s) / M request(s)`
counts (qa-review #1766 r5 finding 1). It used to count every pre-cap `would_approve` row, so with 49
fleet slots already spent and two eligible T1 requests the line read "1 request(s)" beside "T1 2" -
a tier diagnostic contradicting its own headline, on the number an operator arms on. When the caps
bite, the pre-cap population is still shown, explicitly labelled:

```
... largest holder 1; before today's caps: T0 0, T1 2).
```

The gap between the two IS the cap pressure, so it is named rather than dropped. When nothing rolls
the clause is absent, because a second identical number is noise.

Cron `credit-decide-watchdog-shadow-daily` posts it at **07:17Z** (after the decider's 03:00-07:00
window has settled, before the day's traffic builds). It is **read-only** - the shadow number is a
projection, never a write - and it prints `NO_REPLY` the moment the class is armed, because from
then on the two throughput alerts are the measurement.

### What core's own guard excludes from the class

A document is recorded in **our** ledger (`doc_approvals`), never in core, and the approval PUT carries
no proof id. So core's agent guard still decides whether the approval may be written, and the decider
asks that mirror (`policy.server_approval_refusal`) **at plan time**: an eligible document the mirror
refuses is skipped by name (`doc_refused_by_core`) rather than planned and demoted later.

The class therefore covers exactly what core accepts: stored popularity `1..59`, validator risk below
`100`, `band_hint` A, no profile-risk level, no `proofRequest` marker, and no client-sourced metadata
source. A **popularity of 0** is refused by `gate_tier` itself (R22a D1: a zero is an unattributable
track, not a small one), and core refuses it too as `popularity_unattributable`, so that cohort is
**not** covered today. Widening it is a core-backend guard change (accepting document proof), not a
hydra one - so read the shadow numbers as "documents that pass the document gates", and treat
`doc_refused_by_core` in the run report as the honest delta between that and what the class may
actually write.

**Dated shadow -> live line:** the class is in SHADOW from 2026-11-04 (this stack) and stays shadow
until Fable's arming word flips `document_small_track.approved` to true. No live doc-based approval can
be written before that flip.

**R22's arming condition (2026-11-05 20:2xZ), all four in the R22 delta PR:** the auto-freeze exists in
code with a test that a single reversal freezes the class; the 14-day 100% audit is writing rows
(`doc_approval_audit`); the requester notice is wired (core's own approval notice, recorded in the audit
row); and the caps are R22's (5/user, 10/profile). The first approvals are reported with their **ledger
ids**, and the auto-freeze is confirmed armed **before** the first approval lands.

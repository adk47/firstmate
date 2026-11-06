# Switching the automatic credit approver back on — one page for the captain

Prepared 2026-11-06 22:20Z. **Every number below was measured on the production host that day; none is an estimate.**
Where a guard does not exist, this says so.

## 1. What approving actually does to a person

A credit request is someone saying "I worked on this track, in this role". It waits in a queue until something
approves it.

Approving has exactly one effect: the request goes from *needs verification* to *approved*, and the credit then shows
on that person's profile and on the track's credit list as an ordinary professional credit — indistinguishable from
one a human approved by hand. It is public: anyone looking at the track sees it.

**They are not told.** The sender that used to email "we added your credit, please help us verify it"
(`credit-trust-verify-notify-15m`) is switched off and marked retired, and nothing else sends a note on approval. The
person finds it on their profile.

**Can it be undone?** Yes, mechanically: `credit-review.py revert --apply` puts the row back to *needs verification*
and records why. Two honest caveats:

- In the code running in production today, that tool reports success even when some rows were skipped, so a partial
  undo reads as a complete one. The fix is written and tested but sits in an **unmerged** PR (#1717) — not live.
- Anything the person has already done with the credit (cited it, used it as evidence) leaves no trace we can erase.

## 2. The exact population

If the automatic approver were switched on right now, measured 2026-11-06T22:05Z:

- **9 requests, belonging to 8 people.**
- **6 of those 9 requests (5 of the 8 people) belong to paying users**; 3 requests (3 people) to free users.
- **7 of the 9 sit at risk 0.0** — the validator's own confidence that the person is wrong is zero. The other two are
  at 0.08 and 13.4.
- All 9 are currently *needs verification*, all 9 in IDP band A.
- Hard ceilings regardless of queue size: **20 requests per person, 50 per profile, 2,000 per day fleet-wide**, and
  nothing at risk 30 or above is ever eligible.

Nine is not a cap. It is every row that currently qualifies.

**The big backlog is a different problem and this switch does not touch it.** 15,563 requests sit in *needs
verification* for 1,577 people — 610 of them paying users holding 4,459 requests, 967 free users holding 11,104.
Nearly all of that is blocked upstream by a core rule that refuses any IDP band hint other than A.

**The decider's own approve rate over the last 7 days** (its ledger): 294,378 decisions across 1,671 people —
**0 approvals**, 184,631 deferrals, 96,385 support-provided, 13,362 holds. It has approved nothing in a week.

## 3. The three worst things that could happen if it is wrong

**a. A credit is granted to someone who did not do the work, and it is public on the track.**
*The guards, in order:* (i) only rows the validator already approved at risk under 30, in band A; (ii) an **hourly
approval auditor** that is live and busy — it re-checks every credit approved in the previous 90 minutes, by any
route, against the catalog and (model phase is switched on) a web-search model for every big track plus a 10% sample
of the rest. It is not theoretical: **2,408 re-checks in the last 24 hours**, most recent 21:46Z today. Over the last
7 days it returned 1,080 confirmed, 83 contradicted, 223 suspect, 143 reject-recommended, 930 needs-human. A
contradicted **big-track** credit raises a `CREDIT-AUDIT ALERT` in #credit-verification and is queued for human
re-review.
*The honest gaps:* the auditor **records a verdict and raises an alert; it does not remove the credit** — a
contradicted credit stays live and public until a human acts on it. Alerts are wired for big tracks; a contradicted
small-track credit is recorded but does not page anyone. And by far its largest output is **UNVERIFIABLE — 5,749 of
8,335 re-checks in the last 7 days** — so for most rows the auditor reaches no opinion at all, and "it was audited"
is not the same claim as "it was checked".

**b. A stale "these are fine" decision gets reused after a refresh failed.**
This is the exact accident that put the hold on: on 2026-11-05 a refresh failed with a permission error and left a
previous run's approval document readable.
*The guard, proved on production today:* two full runs — the second replaced the first, and the machine's own durable
record says the first is gone and names the second. Then, deliberately breaking the refresh with a permission error:
the surviving approval document was **refused**, with the system reporting "the last attempt did not produce a fresh
document; the bytes on disk are a previous run's" instead of executing it. Log:
`/var/lib/hydra/credit-review/proof/run-21-32-PROVED.log`.

**c. It grants far more than intended because a limit is wrong.**
*The guard:* the four caps above, plus a rule that paying users must be served first — and if a run can no longer
honour that ordering it fails loudly instead of continuing.
*The honest gap:* the caps are enforced as each row is written, but **nothing alerts as a day's total approaches
2,000.**

There is a fourth risk worth naming: the undo (section 1) is the safety net for all three, and it is currently
weaker than it looks until #1717 merges. The auditor in (a) narrows the window in which a wrong credit goes
uncorrected; it does not close it.

## 4. The one-line revert

The approver is a scheduled job, `credit-trust-score-approve-15m`, and it is **already switched off in the live
scheduler**. The lock file is the *second* lock, not the only one — removing it restores nothing by itself. Both have
to be turned on.

To make it run, both must be enabled. To stop it, one line — this re-creates the "stop" file:

```
install -m 644 /dev/null /etc/hydra/credit-trust-score-approve.disabled
```

and set `enabled: 0` on `credit-trust-score-approve-15m` in the scheduler. Credits already granted are undone with
`credit-review.py revert --apply` (see the caveat in section 1).

## 5. The question

**Switch the automatic approver on — 9 requests for 8 people, 6 of them paying, the worst at risk 13.4, using a
mechanism we have now watched refuse a stale approval document — or leave it off, and give that backlog to people
instead?**

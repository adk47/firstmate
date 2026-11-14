# verif-reask-14d-r1: who the day-14 reminder is for

Read-only, node-8 ledger `/var/lib/hydra/credit-review/ledger.sqlite3`, the proof stores, the core replica and
Intercom, by `measure_cohort.py` in this directory. Measured 2026-11-13T18:27Z (the 16:52Z run gave the same cohort).

| step | users |
| --- | --- |
| ever asked, account id known | 3,471 |
| last ask 14 or more days old | 1,826 |
| ... with a request still `user_verification_needed` in core | 1,641 |
| ... and no document on file (proof intake, doc-verify, proof-on-file, ledger proof tag) | 1,375 |
| ... and no reply since the ask (ledger or Intercom) | **1,359** |
| of those, last asked by uvn-status (the reminder's family) | 1,353 |
| ... with a request the ask named still open | 1,349 |
| ... never followed up by any sender | 1,110 |

- Last-ask age of all asked users: 275 under 7 days, 1,370 at 7 to 13 days, 1,826 at 14 to 29 days, none older.
  The 1,370 become due over the following week.
- 244 of the 1,359 already got a follow-up: the `reminder-1` emails of 2026-11-09, sent by `system:reminder-driver`,
  a sender that is not in this repo. Those rows carry the account email and no account id.
- A second read the same day found up to 12 of the 1,548 uvn-status-asked accounts with a `first-ask-1` email (also
  from outside this repo) after their ask. The rule leaves them out (`noted_since_ask`), so the first-day audience is
  about 1,100.
- None of the 1,548 had a status line or any other note of this gate after their ask.

Not measured here: how many the gate's own per-user re-read holds at the send, and whether the copy reviewer
approves the reminder's bodies. Nothing was sent by this work.

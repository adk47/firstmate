# Bucket 1: uvn-status "documents on file" is stuck, not complete

Read 21:54-22:10Z on 2026-11-13 from node-8. The list is the 20:05Z tick's
`/root/h2-runs/sched/20261113T2005Z/owing-uvn.json` (3,183 users), the documents are
`/var/lib/credit-trust/proof-on-file.json` (generated 20:58:27Z). No send gate was changed or run.

## What the hold is

`uvn_status.list_hold` drops a listed user as `documents on file` when `documents_block` finds a
document that counts for them, unless a stage-2 verdict released every asked credit. Only stage 2
can release it (`stage2_verdicts.RELEASES`).

| | paid | free | how it was read |
|---|---|---|---|
| listed users | 924 | 2,259 | `jq '[.users[]\|select(.skip==null)]'` on the list |
| held as documents on file | 485 | 942 | `/tmp/sfz-docs_bucket.jq`: a proof-on-file entry that names a listed request, has no date, or is dated on or after the user's oldest listed request |
| their listed requests | 7,841 | 18,108 | one row per (user, request) of those users, `/tmp/sfz-blocked.csv` |

## Why no verdict can release them

Stage 2 judges only what `proof/stage2.py:260 held_rows()` selects: the decider's latest `apply` or
`judge` row per request, when it is a `hold` (or a documented `approve_partial`) whose reason starts
`proof on file`. A request with no such row is never in stage 2's population.

| | paid | free |
|---|---|---|
| listed requests with no decider row at all | 5,534 | 13,824 |
| listed requests with only a `shadow` row | 0 | 448 |
| users with no `proof on file` hold on any listed request | 365 of 485 | 766 of 942 |
| users with every listed request judged by stage 2 | 51 | 83 |

Query (ledger index `decisions_req` on `decisions(request_id)`, one probe per listed request):

```sql
SELECT b.seg, CASE WHEN NOT EXISTS(SELECT 1 FROM decisions d WHERE d.request_id=b.rid) THEN 'none'
  WHEN NOT EXISTS(SELECT 1 FROM decisions d WHERE d.request_id=b.rid AND d.mode IN ('apply','judge'))
  THEN 'shadow_only' ELSE 'has' END k, count(*) FROM b GROUP BY 1, 2;
```

## Why the decider never rows them

The decider reads one status. `decide.py:2290 held_rows()` lists
`admin_api.list_requests(admin, status=UNVERIFIED, ...)` and nothing else; `user_verification_needed`
is a status it writes, never one it reads.

Status of the no-row requests, from the list's own `facts` (joined in memory on request id):

| status on the list | paid | free |
|---|---|---|
| `user_verification_needed` | 5,534 | 13,494 |
| `unverified` (the decider has not reached them yet) | 0 | 330 |

So 19,028 of the 19,358 no-row requests are in a status the decider does not read.

They were in that status before the decider existed. Its first ledger row is
`2026-10-17T10:45:12Z` (`SELECT id, decided_at FROM decisions ORDER BY id LIMIT 1`). A sample of 300
no-row requests (the first 150 paid and first 150 free in request-id order), one replica query,
4.0 s:

```sql
SELECT status, <updatedat - createdat bucket>, <updatedat before 2026-10-17 10:45:12 UTC>, count(*)
FROM postgresql_core.public.credit_requests WHERE id IN (<300 ids>) GROUP BY 1, 2, 3;
```

| last write to the row | n of 300 |
|---|---|
| `user_verification_needed`, last written before the decider's first run | 287 |
| `user_verification_needed`, last written since | 8 |
| `unverified`, created this month | 5 |

Of the 287, 153 were last written the day they were created and 110 more within 30 days. Created
2024-05 to 2026-10. `updatedat` is the row's last write of any kind, so for the 8 written since it
does not say when the status changed.

## What this means

These are not people who are done. A document is on file for each of them, filed against a request
that is in `user_verification_needed` and has no decider row. In the sample, 287 of 300 were already
there before the decider's first run, so the decider did not put them there; the other 13 are not
settled by this read.
The uvn-status list holds them because a document is on file; the only job that can turn that
document into a verdict takes its work from decider rows these requests do not have. Nothing in
the current path reads the document, so the hold does not end.

The exact stuck state: **listed request in `user_verification_needed` with a document on file and
no decider `proof on file` hold: 365 paid and 766 free users.**

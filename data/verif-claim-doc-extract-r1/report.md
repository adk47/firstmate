# Claim documents with no credit request were selected by nothing: the measurement

Task `verif-claim-doc-extract-r1`, 2026-11-13. Every number below was read on node-8 (`/opt/hydra` at deployed
sha `c0f06f8fd`), read-only: both stores opened `mode=ro`, no write, no model call, no message.

## The brief's premise was stale

The brief named `intake_read.intake_docs` (`candidate_request_ids_json != '[]'`) as the reason 51 claims read
`unreadable: not_extracted`. That filter is still there and is still right for the credit path. The selection
the brief asked for already exists: `runner.claim_only_docs`, merged as #1931 (`9ac753605`, 2026-11-13 06:48Z).

- It reached node-8 at 12:58Z (`runner.py` mtime; `.deployed-sha` contains `9ac753605`).
- The ladder pass that produced the 51 ran at 12:40Z, before that deploy.
- The first doc-verify run carrying the selection was 13:50Z.

So "the selection is missing" was false by the time the brief was written. What was true is below.

## What was actually wrong: the selection got the slots the credit filings left, and they left none

`run()` selected the credit filings first, up to `max_docs`, and gave the claim-only filings
`max_docs - len(credit filings)`. The cron is `run --max-docs 40 --workers 4`, 10 slots a worker.

Measured 2026-11-13T13:56:06Z with `measure_selection.py` (calls `runner._intake_docs` and
`runner.claim_only_docs` exactly as `run` does, per shard):

| shard | slots | credit filings owing a read | claim-only filings owing a read | room left | claim-only selected |
|---|---|---|---|---|---|
| 0 | 10 | 135 | 35 | 0 | 0 |
| 1 | 10 | 117 | 25 | 0 | 0 |
| 2 | 10 | 110 | 36 | 0 | 0 |
| 3 | 10 | 131 | 20 | 0 | 0 |
| all | 40 | 493 | 116 | 0 | 0 |

Open-claim accounts: 2,022. `proof_intake` rows with no candidate request: 2,407; with bytes on file: 1,383; of
an account with an open claim: 133 (116 owe a read; the rest are owed by `blob-backfill`, already extracted, or
the same bytes as another filing).

The 13:50Z run then did what the table predicts. Read back from `dv_steps` and `proof_intake`: it located 40
documents, 40 of them filed with a credit request, 0 filed with none.

The credit queue does not drain on its own (`measure_head_of_line.py`, same hour): of the 490 credit filings
owing a read, 391 have keys still unfinished, 70 had their candidates change, 29 were never keyed. The 40 at the
head were received between 2024-05-21 and 2026-09-13. Room for a claimant's filing was not coming.

## The fix

`runner.claim_only_room(max_docs, credit_filings, floor=CLAIM_ONLY_FLOOR)`: the room the credit filings leave,
and never fewer than 5 per worker. The floor is on top of `max_docs`.

- The credit filings are selected by the same call with the same arguments, before the floor is looked at. They
  lose no slot. That is why the floor is additive and not a share of the 10: a share would have taken 5 reads
  an hour per worker from a credit queue of 493.
- `floor` is capped at `max_docs`, and a run asked for 0 documents reads 0.
- The run line gains `claim_only_waiting`: the filings owing a read that this run had no slot for. Before it, a
  starved queue and an empty one both read `claim_only: 0`, which is how this went a run unnoticed.

## Dry run of the fix on the live stores

`dry_run_after.py`, 2026-11-13T14:20:31Z, read-only (the selection only: no document fetched, no model call, no
step written). The rule run is this PR's `claim_only_room`, sent as source with the script because node-8 does
not have it. Output: `dry_run_after.json`.

| shard | credit filings selected | claim-only owing a read | selected before | selected after | still waiting after |
|---|---|---|---|---|---|
| 0 | 10 | 35 | 0 | 5 | 30 |
| 1 | 10 | 25 | 0 | 5 | 20 |
| 2 | 10 | 36 | 0 | 5 | 31 |
| 3 | 10 | 20 | 0 | 5 | 15 |
| all | 40 | 116 | 0 | 20 | 96 |

The credit filings selected are 40 under both rules. The 20 claim-only filings belong to 17 account-shard pairs
(4, 5, 3 and 5 accounts per shard).

## What it costs

- Reads: at most 5 more per worker per run, 20 an hour on the cron's 4 workers, while any are waiting.
  116 owe a read today, 36 in the fullest shard, so the backlog is read in 8 hourly runs; then it is the arrivals.
- Money: one extraction per document. `dv_llm_calls`, `outcome='ok'`: `gpt-6-sol` (the subscription tier) 3,523
  calls at $0; `deepseek/deepseek-v4.1-flash-1017` 3,542 calls, mean $0.00064, max $0.00775. Today's spend when
  read (about 14:00Z) was $0.00 over 157 calls. 116 documents are $0 while the subscription tier answers, $0.07 at the
  metered mean and $0.90 if every one cost the most any call ever has, against the $5.00 daily cap
  (`extract.DAILY_USD`), which this change does not touch. The dearest of the 12 days read is $0.50 (2026-11-04).
- Time: a 10-document worker took 185 s at the median and 864 s at the worst since 2026-11-12T12Z (75 worker
  runs; 86 s a document at the worst). 15 documents at that worst rate are 1,296 s, inside the cron's 3,000 s.

## What this does not show

- No run with the fix has happened on node-8: this is a PR, not a deploy. The ladder's `not_extracted` count
  (51 at 12:40Z) is unchanged by it until a deploy succeeds and doc-verify has run. The 16:40Z ladder pass will
  still read the store as the unfixed reader left it.
- 26 `no_bytes_on_file`, 8 `extraction_failed` and 1 `empty_extraction` are other reasons and are not touched.
- A claim whose document is read may still be `needs_human_review`: a read is not a decision.
- Nothing here decides, approves, or messages. The executor is still unwired.

## Files

- `measure_selection.py`: the per-shard table.
- `measure_head_of_line.py`: why the credit queue leaves no room.
- `dry_run_after.py`, `dry_run_after.json`: the next run's selection under both rules.

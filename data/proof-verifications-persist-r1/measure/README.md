# The read-back, measured on production

Read-only on node-8, 2026-11-15 07:43Z. `mode=ro` connections, SELECT only; nothing written, enabled or disabled.

- `per_run.py`: the query. `ssh root@<node-8> 'nice -n 10 python3 - 2026-11-14T17:45:00Z' < per_run.py`.
- `per-run-1.json`: its output. Run ids, counts and times only.
- `exact-sql-0650.json`: `DocVerifyStore.run_rows`' two queries, as pushed, on the four run ids of the 06:50Z tick,
  with the seconds each took.
- `table.md`: `per-run-1.json` as a table, one row per run id.

## What it says

60 run ids started between 2026-11-14 17:50Z and 2026-11-15 06:50Z. Every one has `dv_steps` rows, and every one has
as many `dv_outcomes` rows as `gate` + `account_hold` steps (11,650 against 11,650). The read-back's condition holds
for 60 and fails for 0.

## What it does not say

The run's own counters (`documents`, `pairs`, `superseded`) are on file for none of the 60. They exist only in the
`[credit-doc-verify] run {...}` line, which the journal does not hold, `cron_run_receipts` does not carry, and the
gateway's last-run output (first 2,000 characters) ends ahead of. The `gate` and `account_hold` step counts stand in
for `pairs + superseded`. They are rows the same run wrote into the other table, not the counter.

A run that wrote nothing leaves no run id, so it cannot be a row here. The 14 gateway receipts in the window each
have 4 run ids on file. Four run ids (`dv-2026-11-14T21:49:05Z-*`) have no receipt; who started them was not
established.

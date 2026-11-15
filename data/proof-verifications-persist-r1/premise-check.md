# proof-verifications-persist-r1: the premise does not match the code

Checked 2026-11-15 on `fm/proof-verifications-persist-r1` at `7f59b7219` (= `origin/main`), before
writing any code. Nothing is changed or committed yet.

## What the brief says

"credit-doc-verify ... reaches verdicts, but nothing it decides is readable afterwards: the
proof_verifications table has the right schema and ZERO rows."

## What the code and the measurements say

1. **doc-verify already records every verdict, in its own store.**
   `scripts/credit_verify/docverify/runner.py:555` calls `store.outcome(...)` for every claim it
   judges, which inserts into `dv_outcomes` in `/var/lib/hydra-credit-verify/doc-verify.sqlite`
   (`docverify/store.py:271`), with every step in `dv_steps`.
   Measured on node-8 by lane `docverify-blind-check-r1` at 2026-11-15 01:23Z
   (`fm/docverify-blind-check-r1:data/docverify-blind-check-r1/report.md`): **355,074 standing claim
   rows**, 66 of them `verified`. Two days earlier `data/proof-processing-ovh-e1/measurements/measure-1350Z.json`
   read 49,126 `unverifiable`, 3,428 `unknown` and 29 `verified` claims.

2. **`proof_verifications` is a different table, in a different file, owned by a different job.**
   It is `scripts/credit_review/proof_verifications.py`, store
   `/var/lib/hydra/credit-review/proof-verifications.sqlite3`, added with the credit-removal executor
   (#1839). It records a LINK a `not_me` removal claimant sent, and its verdict answers one question:
   does the link name a different person (`different`), the claimant (`same`), neither (`unreadable`),
   or was it not graded (`pending`). Its only writer is `removal_executor._record_proof`.

3. **Its zero rows have a cause in the code that is not doc-verify.**
   The table's one writer runs only on an apply run: `removal_executor.py:656-660` returns before
   `_record_proof` (line 667) when `apply` is false. The only cron for it,
   `clickup-credit-removal-hourly`, is a dry run (no `--apply`) and ships `enabled: false`
   (`cron-jobs.json:2146`). No job that runs today can write a row there. I did not read the
   production file myself; zero rows is what this code predicts.

## Why I did not build the mirror as specified

- doc-verify emits five outcomes (`gate.py:50`: forged, contradicted, verified, unverifiable,
  unknown). The spec maps one. The other four have no honest target: `different` is the verdict the
  removal executor submits to the removal gate as evidence FOR a removal (`pv.GRADED`,
  `removal_executor._unsubmitted`), so `contradicted -> different` or `verified -> same` would put
  credit-request verdicts into a removal ledger under words that mean something else there.
- `unverifiable -> unreadable` would mislabel most rows. The blind check found 91.8% of
  `unverifiable` rows are documents that WERE read (63.4% with credits extracted); only 8.2% had
  under 20 characters of text.
- The table requires `ticket_id` and `profile_id` (NOT NULL). doc-verify has neither: it keys on
  proof sha256, credit request id, role and user id.
- "A re-run updates rather than duplicates" contradicts that store's stated contract ("a row is never
  updated in place"), which the removal tests rely on.
- I found no earlier `unverifiable`/`unreadable` map in git history (`git log --all -S` and `-G` over
  `scripts/`), so I cannot confirm the "previous fix was silently reverted" this is meant to guard.

## What is true in the intent, and still open

"Make silence impossible" names a real gap. `credit-doc-verify.py cmd_run` returns 0 unless the
provider is down (`scripts/credit-doc-verify.py:204-210`). A run in which every document raises
records a `run`/`error` step per document, puts the errors in one stderr line, and exits 0. Nothing
reads the store back to confirm the run left rows.

## Options

- **A (my recommendation).** No write to `proof_verifications`. In `credit-doc-verify.py run`, read
  back the rows written under this run's `run_id` and exit non-zero, naming the fact, when documents
  were processed and none were written (and when claims were judged and no `dv_outcomes` row
  exists). Add a pin test on doc-verify's outcome vocabulary against the maps that read it
  (`ops_intake/sources.OUTCOME_WORDS`, the proof reviewer, the claim ladder), failing when either
  side gains or loses a term.
- **B.** Build the mirror as written. Needs a ruling first on: the target word for forged,
  contradicted, verified and unknown; what goes in `ticket_id` / `profile_id`; and update-in-place in
  a store documented as append-only.
- **C.** Close the lane.

## Ruling

Firstmate, 2026-11-15T06:42Z: **A, no mirror.** `dv_outcomes` is the store of record for doc-verify's
verdicts; `proof_verifications` stays the removal executor's link table and is not touched. The change
is the read-back guard and the vocabulary pin, nothing else.

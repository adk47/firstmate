# The claim document ladder with no person in it (`cdl-2`): the measured population, on a fixture

Run 2026-11-13 on the branch `fm/claims-no-human-p1`, locally, on a synthetic fixture. Nothing on
node-8 was read or written for this report, no claim changed and nothing was sent. Operator doc:
`docs/credit-verification/claim-doc-ladder.md`.

## Result

The 219 open claims with a document on file, in the shape the deployed ladder recorded them, end
as: **1 approved, 114 refused with an ask, 7 asked for a readable copy, 97 awaiting a read of
ours. None ends at a person.** All 219 re-derive from the store.

The fixture is not the real rows. Two of its numbers are assumptions, listed under "What this does
not show", and on the real rows the refused count can only be lower than 114 and the awaiting
count higher than 97.

## Where a documented claim could end before this change

Deployed ladder `cdl-1`, read on node-8 at 2026-11-13T20:42:31Z
(`/var/lib/hydra/claim-doc-ladder/decisions.sqlite`, `latest.json`): 3,358 open claims, 219 with a
document on file, 2,617 with none, 522 with no account.

| A documented claim ended as | Claims | What happened next |
|---|---|---|
| `approved` | 1 | recorded in shadow |
| `needs_human_review` | 114 | listed by `queue` for a person; nothing told the claimant |
| `unreadable` | 104 | listed by `queue --outcome unreadable` for a person |
| `refused` | 0 | only two contradiction classes could refuse, and neither occurred |

A claim with no document got no row, and still gets none.

## The same population under `cdl-2`

| `cdl-1` reason | Claims | `cdl-2` outcome | Ask, or the job that owes the read |
|---|---|---|---|
| `document_names_claimant_and_profile` | 1 | approved | |
| `claimant_not_named` | 58 | refused | `proof_naming_claimant` |
| `profile_not_in_catalog` | 27 | refused | `claimed_profile_link` |
| `doc_type_not_accepted` | 14 | refused | `accepted_document_type` |
| `profile_not_named` | 12 | refused | `proof_naming_profile` |
| `no_release_named` | 2 | refused | `release_on_profile` |
| `releases_not_on_profile` | 1 | refused | `release_on_profile` |
| `not_extracted` | 63 | awaiting_read | `doc-verify` |
| `no_bytes_on_file` | 32 | awaiting_read | `byte-restore` |
| `extraction_failed` | 8 | 2 awaiting_read, 6 resend | `doc-verify`; `readable_copy` |
| `empty_extraction` | 1 | resend | `readable_copy` |

Totals: approved 1, refused 114, resend 7, awaiting_read 97 (65 owed by `doc-verify`, 32 by
`byte-restore`). Every route names a job: `doc-verify` and `byte-restore` are crons
(`credit-doc-verify`, `credit-doc-verify-blob-backfill`), and the fact reads the ladder does not do
itself (`doc-sources`) come from the `claim-doc-ladder.timer` run, whose rows keep their age in
`report` and `list`. **`credit-doc-verify-blob-backfill` ships switched off**, so the 32 rows on
`byte-restore` have no read coming until it is armed, and the ladder reports them as `job: disabled`
rather than as work in progress.
The one `empty_extraction` claim stays a `resend`: its document was read, its kind is one the claim
accepts, and nothing in it could be read. A document that parsed, said nothing and is of a kind the
claim never accepts is refused on its kind instead (`doc_type_not_accepted`), not asked for again.

When the 97 unread documents are read, the next pass gives each claim its verdict or its ask with
no other step (`test_when_doc_verify_reads_what_it_owes_the_claim_gets_its_verdict_or_its_ask`).

## The 153 claims the claim proof ask leaves out

Measured by claims-no-doc-ask-p1 on node-8, 2026-11-13T23:20Z: of 1,850 claims on the live list, 153
(120 people, 36 of the claims paid) are left out of the claim proof ask because the claimant has a
document on file and a standing ladder row. The deployed ladder had 118 of them as
`needs_human_review`, 33 as `unreadable` and 2 as `approved`. The same shape through this branch,
on synthetic facts (`HeldBackPopulationTests`):

| `cdl-1` | Claims | `cdl-2` |
|---|---:|---|
| `approved` | 2 | 2 approved, each a row in the ladder's store with both hashes and its `decided` event |
| `needs_human_review` | 118 | 118 refused, each with a specific ask; none for a person |
| `unreadable`: `empty_extraction` | 13 | 13 resend: the copy was read and nothing in it could be; ask for a clear copy, or a link |
| `unreadable`: `extraction_failed` | 6 | 4 resend (doc-verify has given its last answer), 2 awaiting_read (`doc-verify` still retries). Split assumed, not measured |
| `unreadable`: `no_bytes_on_file` | 10 | 10 awaiting_read on `byte-restore`: we never stored the bytes the claimant sent, so the read is ours. The job is switched off |
| `unreadable`: `not_extracted` | 4 | 4 awaiting_read on `doc-verify`: we have the bytes and have not read them |

So of the 33: 17 are the claimant's move (resend) and 16 are ours (10 of those on a job that is not
armed). The 36 paid claims are decided first, then the other 117, each group by claim id; which
outcome each paid claim has was not measured, so the fixture spreads them evenly.

"Written" for the 2 approvals means recorded in the ladder's own store. Nothing writes an approval
to core: that executor does not exist and this PR does not add one.

## What this does not show

- **How the 8 `extraction_failed` claims split.** `cdl-1` did not record whether doc-verify would
  read a failed document again. The fixture assumes 2 still retried, 2 out of attempts on our
  tooling and 4 with nothing to read. The real split is not measured.
- **Claims with more than one document.** The fixture gives each claim one document. Real claimants
  have several (460 documents for the 132 claimants behind 192 claims on 2026-11-12). Under `cdl-1` the best-read document
  decided; under `cdl-2` one unread document keeps the whole claim `awaiting_read`. So some of the
  114 will be `awaiting_read` on the real rows until their other documents are read. How many is
  not measured.
- **The real rows.** The snapshot holds names and stays on node-8. No pass of this branch has run
  there.
- **Any claimant receiving an ask.** The ask is recorded on the row; nothing sends it.

## Reproduce

```bash
python3 scripts/tests/test_claim_doc_ladder.py MeasuredPopulationTests
python3 scripts/tests/test_claim_doc_ladder.py HeldBackPopulationTests
```

`MEASURED` and `FAILED_AS` in that file are the counts above; `measured_population()` builds the
snapshot and the tests run it through `plan`, `run`, `verify` and `standing`.

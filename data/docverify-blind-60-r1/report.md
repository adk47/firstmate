# docverify-blind-60-r1: the reader scored on 60 record-type documents, by an independent judge

**Result: NOT MEASURED. The judge found 4 supportable claims in the 60; the bar needs 10.** The reader verified
0 of those 4 and 0 of the 60. It also accepted none of the 47 claims the judge said the document does not support.

Measured 2026-11-16 on node-8 (verifier `dv-4`, deployed `9d01302c5`) and ak47 (the judge). Nothing in
production was changed: the reader, the gate, the thresholds and the copy are untouched, the approval writer
stays behind its flag, and no customer was sent anything.

## What was measured

1. **The sample** (`sample.md`, `tools/draw_sample.py`): 60 of the 980 documents whose `dv-4` extraction gave a
   type the gate accepts as a record (`gate.RECORD_DOC_TYPES`), frozen at `2026-11-15T01:23:59Z`, where the count is
   980 exactly. Proportional over the six types, then a seeded draw inside each: invoice 21, pro_registration 17,
   contract 12, split_sheet 5, receipt 3, letter 2. The draw read only each document's id and type, never an
   outcome, so nothing the reader decided chose a document.
2. **One claim per document** (`tools/build_cases.py`): a record document is filed against many credit requests
   (median 12.5 candidate claims per sampled document, mean 70.7, up to 436). The claim scored is the one the
   document's own text best names (name and title in the text, then title, then name, then any), ties broken by a
   seeded hash. That reads the document's text (the reader's input), never the reader's output.
3. **The judge** (`tools/judge.py`): `claude-opus-5-5`, no tools, one call per document. It is given the document
   itself (27 as an image, 24 as a PDF) and the claim: the credited name and the account's other names, the role,
   the track and its artists. That is an allow-list (`CLAIM_FIELDS`); a claim carrying any other key is refused.
   It is never given the reader's verdict, reason, extraction, gate detail, H3 verdict or document type, and its
   instructions name none of them (pinned by `scripts/tests/docverify-blind-60.bats`). It answers `yes`, `no` or
   `cannot_tell` with one line of reasoning. Nobody labelled anything by hand.
4. **The reader's verdict** is the deployed reader's own standing `dv-4` outcome for that claim at the cutoff. It
   was re-run read-only (`tools/run_reader.py`: production stores opened `mode=ro`, a scratch store per case,
   the recorded extraction and DSP credits replayed, no model, admin, Intercom or Gmail call). On all 51 documents
   whose bytes are on node-8 the re-run gave production's answer (50 `unverifiable`, 1 `unknown`).

## The confusion matrix

Reader verdict x judge verdict, 60 documents (`labels.json`, `tools/score.py`):

| reader \ judge | yes | no | cannot_tell | not_judged | total |
|---|---|---|---|---|---|
| verified | 0 | 0 | 0 | 0 | 0 |
| unverifiable | 4 | 46 | 0 | 9 | 59 |
| unknown | 0 | 1 | 0 | 0 | 1 |
| **total** | 4 | 47 | 0 | 9 | **60** |

- `not_judged` (9): no copy of the document's bytes is on node-8 (no blob, no intake file path, no reader cache).
  The judge cannot be shown a document that is not there; these were recorded, not re-drawn. The re-run reader
  could not open them either (7 `unknown` with `not located`, 2 with no outcome row); production's answer for all
  9, made when it could read them, was `unverifiable`.
- `cannot_tell` (0): the judge could read every document it was shown.

## The bar

**Denominator: the claims the judge says the document supports = 4.** The bar is 8 of 10; with 4 it is
**NOT MEASURED (4 supportable claims, the bar needs 10)**, not a rate. Of the 4, the reader verified 0:

| case | stratum | judge, in short | reader's blockers |
|---|---|---|---|
| D07 | contract | signed writer agreement names the claimant sole writer of the track | `no_independent_source` |
| D35 | letter | signed label letter names the claimant A&R on the listed release, the track among them | `no_independent_source`, `document_does_not_name_claim` |
| D58 | split_sheet | signed split letter lists the claimant as a writer of the track, 25% | `h3_not_approving`, `no_independent_source`, `document_does_not_name_claim` |
| D59 | split_sheet | publishing schedule lists the track with the claimant as songwriter and composer, 50% | `h3_not_approving`, `document_does_not_name_claim` |

On 3 of the 4 the reader's own finding is that the document does not name the claim, where the judge read it
naming the claimant on the track. 4 is too few to call that a pattern; it is where to look first.

Specificity, stated as counts because it is not the bar: of the 47 claims the judge said are not supported, the
reader accepted 0 (46 `unverifiable`, 1 `unknown`).

## Why a sample of 60 record documents holds only 4 supportable claims

The documents are records; the claims filed against them mostly are not about them. Of the 47 `no` answers,
almost every reason is the same shape: the document is real and about a different track, artist or person
("a registration for 'ARRIBA', not 'YEEYAY'", "invoice credits the claimant for 'Bathwater', not 'Choosing
You'"), or names the claimant in another role (composer, not A&R; studio drummer, not engineer). Only 7 of the 60
documents had any candidate claim whose name and title both appear in the document's text, and 2 of those 7 are
supported. That agrees with the earlier measurement: 16.64 requests per document, and the document names the
claim on 0.50% of rows.

So drawing 60 documents, even 60 record documents, does not give the bar its 10. The bar's denominator lives in
the (document, claim) pairs where the document names the track; a draw meant to reach 10 supportable claims has
to be made over those pairs. That is a new sample with its own seed, not a re-draw of this one, and it is not
done here.

## Credit approval impact

Before: the approval writer is behind its flag; the reader verified 0 of these 60 documents. After: the same.
This change adds measurement tools, a report and a test suite under `data/` and `scripts/tests/`; it changes no
reader, gate, threshold, copy, writer, cron or customer message.

## Files

- Committed: `sample.md`, `labels.json` (case, id prefix, stratum, both verdicts, the reader's blockers; no names,
  titles or request ids), `report.md`, `tools/*.py`, `scripts/tests/docverify-blind-60.bats`.
- Off git, because they carry claimants' names, track titles and request ids: the full sample, the cases, the
  judge's verdicts with their one-line reasons, and the reader re-run, in
  `/home/aaron/fm-creds-1/data/docverify-blind-60-r1/` (`sample.json`, `cases.json`, `judge.json`, `reader.json`).

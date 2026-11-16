# doc-verify blind check: the supportable denominator

Definition, fixed before counting: a positive is SUPPORTABLE when its document's type is one of
`gate.RECORD_H3_KINDS` (`split_sheet`, `contract`, `invoice`, `letter_of_direction`, `pro_portal`;
`scripts/credit_verify/docverify/gate.py:79`) AND its extracted text names the claimant.

The 10 positives are the blind check's own set (branch `fm/docverify-blind-check-r1`,
https://github.com/Muso-AI/hydra/pull/2030, `data/docverify-blind-check-r1/results.json`). Nothing was re-drawn.

Sources, read-only, 2026-11-16 ~19:40Z:
- **kind**: the `kind` that doc-verify recorded on the document's `text` step (`dv_steps.detail_json`, node-8
  `/var/lib/hydra-credit-verify/doc-verify.sqlite`, opened read-only). The gate uses `h3.kind or` this value
  (`runner.py:582`). The H3 verdict store (`proof.sqlite`) was write-locked by a running tick when read, so the
  H3-side kind was not read; for the nine non-record documents the gate's own blocker `not_a_document_of_record`
  on every claim (`gate.py:351`) confirms whichever kind it used was not a record kind.
- **names the claimant**: `extraction.names_claimant`, a field of the blind-check harness's own `extraction`
  summary block in `data/docverify-blind-check-r1/results.json` (the production `Extraction` has no such field),
  with the harness's whole-token match on the extracted text (`text_has_claim_name`) beside it.

| case | request | extraction doc_type | kind | kind in RECORD_H3_KINDS | extraction names claimant | text contains name | supportable |
|---|---|---|---|---|---|---|---|
| P01 | 889faafb | credits_page | catalog_page | no | yes | yes | no |
| P02 | 6c0a9ba4 | dashboard_screenshot | catalog_page | no | yes | yes | no |
| P03 | 211328ae | credits_page | catalog_page | no | yes | yes | no |
| P04 | 4ce25c2f | pro_registration | pro_portal | **yes** | yes | yes | **yes** |
| P05 | bed9759f | credits_page | unknown | no | yes | yes | no |
| P06 | 1a2c2a40 | dashboard_screenshot | unknown | no | no | yes | no |
| P07 | ab1635e0 | credits_page | catalog_page | no | yes | yes | no |
| P08 | 38eadc66 | credits_page | unknown | no | yes | yes | no |
| P09 | 358f53c9 | credits_page | unknown | no | yes | yes | no |
| P10 | 1d579e85 | credits_page | unknown | no | yes | yes | no |

Raw headline, kept as disclosed: **0 of 10 positives accepted** (9 `unverifiable`, 1 `unknown`).

P04, the one supportable positive, came out `unknown` on `H3 UNDETERMINED` (a tooling answer, not a judgement):
its 2 claims carry only the blocker `tooling_h3_undetermined`.

SUPPORTABLE: 1 of 10

**NOT MEASURED, supportable subset is 1 of 10.** 0 of 1 accepted (the one came out `unknown` on a tooling
answer, not a reader judgement).

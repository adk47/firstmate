# doc-verify: the bar on the supportable subset, and the proof-on-file holds split by record type

Status: read-only measurement, 2026-11-16 ~20:26Z, node-8 (deployed tree `9d01302c5`). Nothing was changed on
node-8: no gate, reader, threshold, copy, kill file or `doc_class.shadow` was touched, nothing was armed and
nothing was sent. Every store was opened `mode=ro`; the tools are piped over ssh and leave no file behind.

## 1. The bar

### Headline, disclosed as measured: 0 of 10

The blind check (https://github.com/Muso-AI/hydra/pull/2030, `data/docverify-blind-check-r1/results.json`)
accepted **0 of its 10 positives** (9 `unverifiable`, 1 `unknown`) against a WORKING bar of 8 of 10. That
number stays the headline: it is the one that showed the gate refuses most positives by document type before
the reader is asked anything.

### The supportable subset, defined before counting

A positive is SUPPORTABLE when both hold:

1. its document is a record type: the kind doc-verify recorded for it is in `gate.RECORD_H3_KINDS`
   (`split_sheet`, `contract`, `invoice`, `letter_of_direction`, `pro_portal`;
   `scripts/credit_verify/docverify/gate.py:79`), and
2. its extracted text names the claimant of the request.

The sample is the blind check's own 10 positives. Nothing was re-drawn: re-drawing to positives the gate
already accepts would measure the instrument against itself.

### Result: NOT MEASURED, the supportable subset is 1 of 10

Per-positive evidence: [`denominator.md`](./denominator.md). Nine of the ten positives are credits pages or
dashboard screenshots (kind `catalog_page` or `unknown`); only P04 (a PRO registration, kind `pro_portal`) is a
record type, and it names the claimant. The gate's record test on its two type branches (`gate.py:351`:
extraction `doc_type` in `RECORD_DOC_TYPES` OR kind in `RECORD_H3_KINDS`) gives the same 1: the other nine
are `credits_page` or `dashboard_screenshot` by extraction too.

0 of 1 accepted (the one came out `unknown` on a tooling answer, not a reader judgement). For the record only,
the tooling answer was `H3 UNDETERMINED`: its claims carry only the blocker `tooling_h3_undetermined`.

**What this means:** the blind check as drawn cannot tell whether the reader is good. 0 of 10 is a document-type
result. The bar needs a positive sample of at least 10 record-type documents that name their claimant, drawn
by the same blind procedure from the record-type population (section 2 shows 296 users whose holds rest on
one), not a re-draw of this sample.

## 2. The "proof on file: human review" holds, split by record type

### Population, fixed before reading any document

Every request whose LATEST credit-review ledger row (highest id, any mode) carries the decider's
`proof on file: human review` sentence (`decide.py` `DOC_ON_FILE_HOLD`). Ledger read at its row of
2026-11-16T20:25:46Z:

| | requests | users | paid requests | paid users |
|---|---|---|---|---|
| population | 30,517 | 2,378 | 12,072 | 1,034 |

**The brief's 268 was not reproduced.** No slice tried (paid, mode, the #1959 hand-off suffix, decision day,
latest-row or any-row) gives 268; the nearest are 265 paid users on 2026-10-26 rows and 267 judge-mode requests
today. This report uses the whole population above, stated, rather than a number it cannot rebuild.

### The rule (one lane per request, first match wins)

The document is the one doc-verify (`dv-4`) read for that request; when doc-verify holds no row for the
request itself, the hold is the user's (proof on file is per user), so the user's own documents are read.

| lane | rule | what happens |
|---|---|---|
| `no_document_read` | doc-verify has read no document of the request or the user | not split: there is no document type to read. Not an ask. |
| `account_hold` | a document of the account is forged or on hold (`dv_outcomes.account_hold`, outcome `forged`, or need `account_on_hold`) | never asked |
| `record_type` | any document is of record by the gate's own test (extraction `doc_type` in `RECORD_DOC_TYPES`, or kind in `RECORD_H3_KINDS`; the gate's third branch, an F9 dashboard, is excluded on purpose — a dashboard is evidence, not a document of record) | **waits on the bar** |
| `not_record_ask` | no document is of record | **one ask**: the need the gate itself recorded on the row (`dv_outcomes.need`), in the approved words of `proof_reviewer.ASK_LINES`; where every read was `unknown` and the gate recorded no need, the gate's own `readable_document` ask |

Both the record lists and the ask words are imported from the deployed tree, never restated
(`tools/split.py`; the rule is pinned by `tools/test_split.py`, 13 tests). The ask is the gate's own need
code, so no new copy exists: each one names a concrete document. Ties between needs recorded equally often
prefer the document of record, then the F9 dashboard, the issuer line, a readable copy.

### Result

| lane | requests | users | paid requests | paid users |
|---|---|---|---|---|
| (a) `record_type`: waits on the bar | **3,819** | **296** | 1,421 | 158 |
| (b) `not_record_ask`: one specific ask | **13,683** | **953** | 5,312 | 466 |
| `account_hold`: never asked | 3 | 1 | 3 | 1 |
| `no_document_read`: no document to type | 13,012 | 1,144 | 5,336 | 417 |
| total | 30,517 | 2,378 (16 users span more than one lane) | 12,072 | 1,034 |

The asks in (b), by the need the gate recorded:

| need code | requests | users | the ask, in its approved words |
|---|---|---|---|
| `distributor_dashboard_with_code` | 10,988 | 843 | one screenshot of your distributor dashboard that shows the release and the code we send you |
| `readable_document` | 2,227 | 79 | the same document as a PDF or a clear photo of the whole page |
| `issuer_email_from_official_domain` | 443 | 37 | one line from the issuer's own address confirming your role on the track, or their original email with its headers |
| `counterparty_signed_or_registered` | 25 | 1 | a split sheet or agreement signed by the artist or label, a PRO registration that lists you in your role, a royalty statement that names the track, an invoice, or a letter from the label |

What the (b) documents are (distinct documents, by the extraction's `doc_type`): `other` 1,632,
`credits_page` 1,225, `dashboard_screenshot` 561, `email_screenshot` 211, `email` 7, `none` 1 (no
`extract` step recorded).

### Caveats a reader needs

- **The record test is the gate's, not the kind alone.** By kind alone, (a) would be about 2,694 requests: 1,128
  requests rest on a document the extraction reads as a contract, invoice, letter, split sheet, receipt or PRO
  registration while its kind is not a record kind. The gate accepts those as of record (`gate.py:351`, whose
  `or f9` branch is the one part of its test this lane does not use), so asking them for a split sheet would ask
  for what they already sent. The supportable-subset definition in
  section 1 uses the kind as the brief fixed it; on the blind check's 10 the two tests agree.
- **`no_document_read` is 43% of the population and is not an ask.** None of its 1,144 users has a document
  doc-verify has read, so there is no document type to split on.
- **A lane is not a send list.** Any sender that acts on (b) still applies its own gates: `policy.never_ask`,
  comm_state, the one-message-a-day rule and the signed copy gate. This report sends nothing and arms nothing.
- **Ledger state, not core state.** A request's latest ledger row is not its live status; some of these may
  already be decided elsewhere.
- **Kinds are the `text` step's.** The gate uses `h3.kind or` that value; the H3 store was not read here
  (it was write-locked by a running tick at an earlier read).

## Reproduce

```
ssh root@40.160.32.80 'cd /opt/hydra/scripts && nice -n 10 python3 -' \
    < data/docverify-bar-on-supportable-subset-r1/tools/split.py > split.json        # counts only
ssh root@40.160.32.80 'cd /opt/hydra/scripts && nice -n 10 python3 - --rows' \
    < data/docverify-bar-on-supportable-subset-r1/tools/split.py > rows.json         # + one row per request
python3 data/docverify-bar-on-supportable-subset-r1/tools/test_split.py
```

`split-summary.json` is the committed counts. The per-request rows (request and user ids, each with its lane,
need and ask) are customer data and are NOT committed: they are at
`/home/aaron/fm-creds-1/data/docverify-bar-on-supportable-subset-r1/split-rows-20261116T2017Z.json` on ak47.

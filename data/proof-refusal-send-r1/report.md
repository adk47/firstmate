# proof-refusal: who is told, who is held, and why it is not 395

Read-only against node-8 on 2026-11-15. Nothing was written on node-8 and nothing was sent.
The 14:53Z rows were produced by this PR's own `scripts/credit_review/proof_refusal.py`
(`build`, then `payloads`' re-read of core), run from stdin against the deployed tree at
`be9e53e6e`; the gate campaign is not deployed, so no body was rendered there.

## The denominator moved

| read | rejected rows in `verify_proof_reviews` | people |
| --- | --- | --- |
| 13:57Z | 2,559 (reviewer runs `pr-20261115T125207Z`, `pr-20261115T125501Z`) | 390 with an account, 11 rows with none |
| 14:53Z | 6,659 (a third run, `pr-20261115T135501Z`, added 4,100) | 557 |

The reviewer is armed and runs hourly, so the number keeps moving. Each tick builds the list
again from the ledger; the list records the reviewer runs and the row count it was built from.

## The 395 was never one group (14:53Z, 6,659 rows)

A body says "What would change this: {evidence}". It is true only where the reader recorded
the need that evidence line belongs to (`proof_review_decisions.ask_need`).

| class | rows | people | what happens |
| --- | --- | --- | --- |
| listed: the reader's need is the one an approved body names | 630 | 81 (34 paying) | this family |
| held `reader_need:distributor_dashboard_with_code` | 3,790 | 422 | the armed `proof-need-ask` family asks them, with a code issued at send; no refusal body carries a code |
| held `reader_named_no_need` (`blocked:no_unverifiable_read`, `blocked:verify_at_off`) | 2,154 | 72 | the reason is known, what would change it is not; nothing is sent |
| held `no_body_for_reason` (`not_a_document`, `other_role`) | 85 | 51 | no approved wording |

Some people have both listed and held rows (2 of the 422, 4 of the 72, 3 of the 51); they are
told about the listed rows only.
Sending body A or B to the 422 would tell them a split sheet would change the result on rows
where the reader recorded that a dashboard screenshot with a code is what satisfies it.

## From listed to sent (14:53Z)

The send reads every listed request again from core.

| step | rows | people |
| --- | --- | --- |
| listed | 630 | 81 |
| every row dropped: held for a cause no document clears (`policy.never_ask`) | | 13 |
| every row dropped: no longer pending | | 10 |
| every row dropped: another ask class holds it (`approval_path`) | | 2 |
| a note can be rendered | 182 | 56 (23 paying) |
| inside 7 days of another note from this gate (deferred, offered again) | | 16 |
| would be sent on a first run | | 40 (11 paying) |

Rows in the 56 notes: `doesnt_name_you` 101, `unreadable` 62, `other_track` 19.
Sentence sets per note: 1 in 30 notes, 2 in 6, 3 in 4, 4 in 3, 5 in 3, 6 in 3, 7 in 2, 9 in 2,
12 in 3. A one-set note is an approved body byte for byte.
Rendered length at 14:04Z (59 notes then): 48 words shortest, 75 median, 633 longest. The gate
refuses a note over 1,500 words and does not cut it.

The 16 deferred people last heard from this gate through: `uvn-status` 6, a 14-day reminder 6,
a backlog reply 2, a document-result note 2. Their ids, and the held ids by class, are in
firstmate's lane data (`measure-1453Z-ids.json`), not in this repository.

## Not measured

- No body was rendered by the deployed gate, and no reviewer verdict exists for any body: the
  campaign is new and enforced, so the first tick after a deploy sends none.
- Bounces and complaints: nothing has been sent, so the read-back has only been run on fixtures.
- Whether a counterparty document passes doc-verify on a row whose recorded need is the
  dashboard screenshot.

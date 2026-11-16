# proof-return-path-e2e-1115: gaps found before the live round trip

Measured 2026-11-15 16:10-16:30Z, read-only, on node-8 (`/opt/hydra` at `be9e53e6e`) and the core replica.
Nothing was sent, written or changed on node-8, in core or in Intercom to produce this file.

## Where the live round trip stands

Not run. Three things stand between the branch and the 10-minute proof; one needs a decision (gap 1), one
needs a merge and a deploy (gap 2), one is being built as its own PR (gap 3).

## Gap 1: there is no seeded account (needs a decision)

A round trip needs an account with an OPEN credit request: the feeder files a document against the account's
open requests, and a filing with no candidate request is never read for a credit (`intake_read.intake_docs`
selects `candidate_request_ids_json != '[]'`).

| checked | result |
| --- | --- |
| `@muso.ai` accounts with any credit request | 4: `demo@` 16,608, `oleg@` 1,269, `nick@` 10, `daria+facebook@` 1. Every one of those requests is `approved` or `rejected`. |
| `e2e-suite-*`, `%test%@muso.ai`, `qa%@muso.ai`, `%+e2e%@muso.ai`, `aaron*` accounts | 0 credit requests on any of them; the `e2e-suite-spine-*` accounts are `emailconfirmed = false` and have no Intercom contact. |
| house wiki | no seeded verification account recorded; `demo@muso.ai` is recorded as "a demo/test account" (captain, SRC-2026-09-18-656). |

`demo@muso.ai` is the one account that already passes the feeder's identity rule (`intake.strict_identity`):
core user `77698`, professional id `46a7cdfb-b533-4aa3-8e6b-7274fd026525`, and an Intercom `user` contact
`6aa7a93f9656ea37461f50e2` whose `external_id` is that professional id, created 2026-09-14. The contact must be
older than 24 h, so an account created today could not file a document until tomorrow.

What it lacks is one open credit request. Nothing in this repo can create one: a credit request is created by
the signed-in user in the product, and I hold no session for that account.

Not verified: whether a new request on `demo@` would stay open. The account has thousands of approvals, so the
precedent and score approvers may decide a new request inside the hour, before an ask is sent. The request has
to be one the validators hold.

## Gap 2: the typed-code reader is not on node-8

`proof_intake` on node-8 has no `reply_text_json` column and `/opt/hydra` is at `be9e53e6e`; the reader change is
on `fm/proof-return-path-e2e-1115` (`69055ecdf`, pushed, no PR opened yet). Case (b), the code typed in the
reply, can be proven live only after that branch merges and a deploy succeeds. Cases (a) and (c) use the
document-text reader that is already deployed.

On the branch the three cases are proven on fixtures only (`scripts/tests/test_doc_verify.py` 235 tests,
`scripts/tests/test_proof_intake.py` 111 tests, both passing). That is not the acceptance.

## Gap 3: the deployed cadence cannot meet 10 minutes

| stage | cron | schedule | runs in 24 h | mean run | longest run |
| --- | --- | --- | --- | --- | --- |
| file | `credit-verify-proof-file` | :15 hourly | 24 | 218 s | 960 s |
| mark | `credit-proof-marker` | :45 hourly | 24 | 0.3 s | 1.1 s |
| read | `credit-doc-verify` | :50 hourly | 24 | 455 s | 1,040 s |
| review | `credit-proof-reviewer` | :55 hourly | 4 | 33 s | 85 s |

Source: the gateway's `cron_run_receipts`, last 24 h. From a customer's reply to a review row is 40 minutes at
best (reply at :14) and about 100 at worst (reply at :16). The reader also takes 40 documents a run, paying
accounts first and then oldest first, so a new filing from a free account waits behind the unread backlog. A
`.path` trigger on the reviewer alone moves none of this: the wait is in filing and reading.

Being built as its own PR: a narrow lane that, every few minutes, files and reads only the conversations that
carry an unconsumed code, then runs the marker and the reviewer.

## Decision needed for gap 1

1. A person with the `demo@muso.ai` login adds one credit in the app and gives me the request id. I drive the
   rest: first document, the dashboard ask, the reply as that contact, and the ledger rows.
2. Or I am told where that login lives and do step 1 myself in a browser.
3. Or another account is named that already has an open request and an Intercom `user` contact older than 24 h.

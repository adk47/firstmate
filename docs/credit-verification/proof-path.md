# The proof path: one feeder, one reader, one decision step, one marker, one reviewer

A customer's document goes through six stages: **file, read, decide, mark, review, tell**. This page names the one
job that owns each stage, what is still duplicated, and what is not armed. The measurements behind it are in
`data/proof-processing-ovh-e1/report.md` (node-8, 2026-11-13).

## The path

| stage | owner | schedule | reads | writes |
| --- | --- | --- | --- | --- |
| file | `credit-proof.py file-recent` (cron `credit-verify-proof-file`) | hourly :15 | Intercom conversations updated since the cursor, support@ messages with an attachment | `proof_intake`, one row per (account, file sha256), in `/var/lib/hydra-credit-verify/proof.sqlite` |
| read | `credit-doc-verify.py run` (cron `credit-doc-verify`) | hourly :50 | `proof_intake`, the document bytes, sources the customer does not control | `dv_outcomes` in `doc-verify.sqlite` (shadow) |
| decide | credits: `credit_review/doc_approve.py` through `decide.py`. Claims: `claim-doc-ladder.py` | not armed; 4 h (shadow) | `dv_outcomes` | `doc_approvals`; `claim-doc-ladder/decisions.sqlite` |
| mark | `credit_review/proof_marker.py apply` (cron `credit-proof-marker`) | hourly :45 | `proof_intake` (read-only), `verify_messages` | `verify_messages.proof_tagged_at`, one `proof_marks` row per tag |
| review | `credit_review/proof_reviewer.py apply` (cron `credit-proof-reviewer`, ships unarmed: `enabled: false`) | hourly :55 once armed | `verify_messages` under review, `dv_outcomes`, `dv_llm_calls`, `proof_intake` (all read-only) | `verify_proof_reviews` through `verify_ledger.record_proof_review`, one `proof_review_decisions` row per credit |
| tell | the existing senders, each behind the outbound copy gate | per campaign | the ledger | `verify_messages` |

Nothing on this page sends a message or approves a credit in core. The file and mark stages never judge. The
review stage is an AI verdict in the verify ledger; no person reviews a document.

## The feeder (`file-recent`)

One run at a time, under a lock on the state file `/var/lib/hydra-credit-verify/proof-file-state.json`.

- Both searches run first and their whole result is saved in the state (`carry`, `carry_messages`) before any
  conversation is read. The cursor (`since`) moves as soon as the searches complete.
- Conversations are filed 25 at a time (`recent.CHUNK`) and the state is saved after each chunk. A killed run
  redoes at most one chunk. Re-filing is idempotent.
- A run stops filing conversations at `--max-seconds` (2400) and carries the rest. The cron kills at 3000 s.
  support@ messages are still filed in that run: they are capped by count (`--max-messages`), not by time.
- `--max-fetches` caps attachment downloads per run, across all chunks.

Why it is built this way: until 2026-11-13 the state was saved only at the end of a run. A kill-file pause of about 24 h
(2026-11-10 19Z to 2026-11-11 19Z) left more conversations in the window than one run reads before the
3000 s kill, so every run was killed with nothing saved and the next one started over on a longer window: 36 of
the next 37 runs failed in 41 hours, 31 of them at the kill, and the window had grown to 2,835 conversations.
The cursor sat at 2026-11-10T17:15Z for 67 hours. The run records are in the gateway's `cron_run_receipts`.

A backlog is drained by running the same command back to back
(`data/proof-processing-ovh-e1/tools/run-feed-drain.sh`): raise `--max-fetches`, leave `--max-messages` alone
(it is the Gmail read rate).

Kill files: `/etc/hydra/credit-doc-intake.disabled`, `/etc/hydra/credit-verify.disabled`;
`/etc/hydra/gmail-readers.disabled` turns support@ off and keeps Intercom on.

## The marker (`proof_marker.py`)

`verify_messages.proof_tagged_at` answers "did they answer this note with a document?". The marker sets it from
`proof_intake`:

- the note is `sent` and has an account id, and that account filed a document dated at or after the note;
- a credit note: the document was filed against one of the requests the note names
  (`candidate_request_ids`). An old document does not answer a later ask;
- a claim note: any document from the account after the note.

The value written is the document's own `received_at`. A note with no account id is counted `unmeasured`, never
"no answer". An unreadable proof store is exit 2 and nothing is written.

A tag carries what `verify_ledger.mark_tagged` writes, in one transaction (rule `pm-2`):

- **the family**: the first note and every follow-up of it that has no tag, so no sibling keeps sending;
- **the attachment count**: `proof_attachments` is the number of documents that answer the note;
- **the rejected verdicts of every note the credits live under** (`verify_ledger.proof_families`). A note names
  credits first asked about on other notes, and a credit's verdict is stored under its own note. Clearing the
  first note alone left those credits rejected, and due for removal, after the customer sent the document.

A note is tagged only by a document no review has seen. A review suppresses the tag for the credits it was
recorded against (`verify_proof_reviews.request_id`, under that credit's own note); a review of another credit,
or on another note, hides nothing. A claim note has no credit to compare, so its own family is the unit, and a
review whose time cannot be read blocks the credit it belongs to. The same rule decides which rejected verdicts
a tag clears: one recorded at or after the document is a review of it and stands.

It does not write `conversation_id`. On a note that column is the thread the note was sent in, and an empty one
means the note went by email: `nothing_needed_overlap` reads it to decide where a correction goes. The marker
knows the document's conversation, which is another thread for a note sent by email (572 of the 585 notes marked
on 2026-11-13 went by email). The document's conversation stays in `proof_intake`, reachable through
`proof_marks.intake_id`.

| command | effect |
| --- | --- |
| `proof_marker.py plan` | counts only, opens both stores read-only |
| `proof_marker.py apply` | sets the tags in one transaction, prints the `run_id` |
| `proof_marker.py revert --run-id RUN` | undoes what that run set and nothing has changed since: the tags (the note's and its follow-ups'), the attachment count, the cleared verdicts. That document never answers the note again, but a document filed after it can |
| `proof_marker.py reconcile` | counts what the marks an earlier rule wrote lack against this one; writes nothing |
| `proof_marker.py reconcile --apply` | fills it in: the attachment count, the untagged follow-ups, the rejected verdicts older than the document. Sets no new tag; a verdict recorded after the document stands |

Kill file: `/etc/hydra/proof-marker.disabled` (stops `plan`, `apply` and `revert`; not `reconcile`, the repair a
person runs while the marker is held). `proof_marks` is created by the marker, not by
`verify_ledger.SCHEMA`: a table added there makes every read-only reader of the ledger refuse until a writer
has migrated it.

The marker replaces the Intercom tag sweep (`verify_notify.sweep_proofs` -> `intercom-verify-request.sh
tag-proof` -> `verify_ledger.mark_tagged`). That sweep runs only inside `verify-notify --mode apply`, whose cron
was retired on 2026-11-06, and it reads one conversation per note, which is not where documents are filed. It
never recorded a look on production (`proof_checked_at` is set on 0 rows). The 103 tags that existed before
2026-11-13 were written in one second on 2026-11-09 by a backfill that is not in this repo.

## The reviewer (`proof_reviewer.py`)

Captain, 2026-11-13: "never should we ever use a person to evaluate this". `verify_proof_reviews` had no writer
but a person typing `credit-review.py --proof-review`, and it had 0 rows. The reviewer is that writer. It runs
over every credit on a credit note whose proof is tagged and not yet reviewed, and records one verdict per
credit through `verify_ledger.record_proof_review`.

It calls no model. The verdict is doc-verify's recorded outcome for that credit (latest row per document,
request and role, for this account), and `reviewed_by` names the rule, the doc-verify version and the model
that read the document: `ai:proof-reviewer/pr-1 doc-verify/dv-4 model=<model>`.

| reading | verdict | what the customer is owed |
| --- | --- | --- |
| every document for the credit is read, every role the credit claims on the filing (`dv_intake_keys`, or the newest `dv_steps` `intake_keys` row when the table has none) has a `verified` read of its own and nothing is forged or contradicted | `accepted`: the credit is never removal-due. A verified read stands: an `unverifiable` document for the SAME role does not reopen it (a resubmission that verifies is accepted over the first document that did not), and a role with no verified read of its own is never carried by another role's. The ACCOUNT's hold does not change this: a verified document is true whether or not another document of that account was forged | nothing |
| anything else doc-verify read | `rejected`, with one of `REJECTION_REASONS` kept internal | the reason-free decline, and the specific ask: the doc-verify need code (`readable_document`, `counterparty_signed_or_registered`, `distributor_dashboard_with_code`, `issuer_email_from_official_domain`); a `forged`/`contradicted` read records the need it would have asked for, on the `blocked:account_on_hold` route, with `ask_need` and `ask` left empty like every blocked route |
| uncertain: a document for the credit is not read yet, its read is `unknown`, a claimed role was keyed and neither read nor cut by doc-verify (the per-run claim cap), the filing's keying was never recorded, or a note with no account id names a credit more than one account filed on (so the note cannot say which filing is its own) - even when another document already verified | no verdict at all, at any age: the credit stays under review waiting on our reader and is never removal-due | nothing: our reader's failure is ours to fix, so nothing is sent to the user about it, and every run writes how many credits wait on the reader and the age of the oldest (`wait_reader`, `oldest_days` in the file; the run's output prints them as `wait_reader` and `wait_reader_oldest_days`) to `--waiting-file`: our backlog is measured on our side (the queue report that will carry that file is a separate change, so until it lands the file itself is the report) |
| `other_track`: the reader read another document of the account and found nothing for THIS credit, or its fan-out cut marked the credit's keys not matched (a read filing with no claim) | `rejected`, never `accepted` | the decline, and the ask the failing read names when a read named one (`proof-need-ask` with that need code); only when nothing was read for this credit is there no ask, and the audit row then carries `blocked:no_unverifiable_read` (`blocked:account_on_hold` on a held account) and no need code |

An uncertain reading is never a pending state for a person and no staff queue exists. There is no clock on our
reader either: a document we have not read, or read only as `unknown`, produces no rejection and no ask however
long the backlog takes, so no timer can charge the user for our reader's delay. The internal reason
never leaves the ledger: `plan --list` prints the outcome and the ask only.

The reviewer sends nothing and approves nothing in core. Each audit row records the ask and the route it
would take (`ask_route`):

- `proof-need-ask`: the one reviewed ask path (`need_asks.py`), which sends on doc-verify's `unverifiable`
  row with the same need code. An `unknown` read is never sent: it means our reader could not answer, so
  the retry layer owns it and no message blames the user for our outage;
- `blocked:account_on_hold` (the account is never messaged, and a read doc-verify ruled `forged`,
  `forged_positive` or `contradicted` holds it), `blocked:verify_at_off` (the issuer-email ask is locked), and
  `blocked:no_unverifiable_read` (that path has no row to send on). A blocked ask is counted in the run's
  output, never dropped silently, and is not sent by anything today: so it is recorded as NO ask - `ask_need`
  and `ask` stay empty on the audit row - because a row carrying an ask nothing can send would claim a customer
  was told when they were not. The blocked route in the run's counters is our backlog, said plainly.

The decline is not sent by the reviewer either. The `decline` campaign stays locked behind
`DECLINE_CORE_ROUTE_OFF` and has no scheduled driver, so a rejected credit reads `HELD_NOT_TOLD` and is never
removed until its decline is on record.

| command | effect |
| --- | --- |
| `proof_reviewer.py plan [--list]` | counts only (`--list`: outcome and ask per credit), all stores read-only |
| `proof_reviewer.py apply [--max-notes N]` | records the verdicts, oldest tag first, at most N notes (default 200), in one transaction, prints the `run_id` |
| `proof_reviewer.py revert --run-id RUN` | deletes that run's verdicts nothing has rewritten since and puts the notes back under review |

A second `apply` decides nothing twice: a reviewed credit is no longer under review, and both verdicts are final for
that tag. Every verdict for a note's family is written before any tag is settled
(`verify_ledger.settle_proof_tags`, called once after all of them), so the order credits are written in cannot
decide whether another credit's verdict holds, and a family returns to "no proof" only once every credit its own
rows name is reviewed and any was rejected. A run is one `BEGIN IMMEDIATE` transaction: every verdict, its
`proof_review_decisions` row, the tags it settles and the record of which tags it cleared land together or not at
all, so a run killed part-way leaves the ledger as it found it and the next run decides the same notes. A rejected credit is decided again only when a new document re-tags its note, which is
`proof_marker.py`'s job, unchanged. The backlog is the same command with a larger bound. Kill file:
`/etc/hydra/proof-reviewer.disabled`. An unreadable store is exit 2 and nothing is written. `proof_review_decisions` is created by the reviewer, not by `verify_ledger.SCHEMA`,
for the reason `proof_marks` is. Claim notes are skipped: their documents are `claim-doc-ladder.py`'s.

## What the seven named processors are

| processor | what it is | on the path? |
| --- | --- | --- |
| `credit-proof.py` | four jobs in one file: `file-recent` (the feeder), `intercom` (file forensics, shadow), `stage2` (a second judge over the same documents, shadow), `email` (Maildir intake, cron disabled) | `file-recent` is the feeder |
| `cs-proof-feed.sh` | hourly scan of the same Intercom conversations and the same mailbox, exported to `cs-proofs.json` (the "proof on file" list the decider and the ask senders read) | a second feeder |
| `claim-proof-check-watchdog.py` | read-only alarm on the claim proof check's files | no: a watchdog |
| `credit-no-proof-close.py` | a coded close rule (`no_proof_after_ask`). No cron or timer runs it and its policy is `apply_enabled: false` | no: never run |
| `caroline_redteam_docverify.py` | a daily replay of injected-document test cases against the doc-verify prompt | no: a test |
| `resolution-matcher.py` | matches a shipped fix to the customers who reported it | no: not about proof |
| `close-resolved-conversations.py` | closes Intercom conversations whose ClickUp ticket is complete | no: not about proof |

Two of the seven handle documents. Neither set the marker, and no job did.

## What retires, and what replaces it

| retire | replacement | when |
| --- | --- | --- |
| the tag sweep: `verify_notify.sweep_proofs`, the `tag-proof` action, `verify_ledger.awaiting_proof` / `mark_checked` | `proof_marker.py` | now: its only caller's cron is already off. The code leaves in its own PR, with the gate script's `tag-proof` tests |
| `/usr/local/bin/cs-credit-proof-file.sh` and `/etc/cron.d/cs-credit-proof-file` on node-8 (not in this repo): a second caller of `file-recent` every 2 h with a 900 s kill | the hourly cron `credit-verify-proof-file` | when this change is deployed. Until then it runs the old code and only competes for the lock |
| `credit-no-proof-close.py`, `credit_review/no_proof_close.py` | `scale_drain.py`: an asked request with no proof by its date is `cannot_confirm`: a ledger row, no write and no message (captain 2026-11-14: no outcome is a person) | now, in its own PR: `fable_executor.py` imports the module |
| `credit-proof.py email` (Maildir) and its disabled cron | `file-recent`'s support@ read | now, in its own PR |
| `cs-proof-feed.sh` scans (`cs_proof_feed/proof_scan.py`, `gmail_proof.py`) | `file-recent`; `cs-proofs.json` built from `proof_intake` | must wait: the feed lists 32,480 accounts and `proof_intake` holds 2,648. The export moves only after `proof_intake` holds the same history, or every ask to the other accounts loses its "document on file" hold |
| `credit-proof.py stage2` | `credit-doc-verify.py` | must wait: `stage2_verdicts.py` is what releases a credit to the `gap-ask` and `uvn-status` asks |
| a second document decider (`scale_drain.py` rule `proof_verdict`, which reads the forensics verdict) | `doc_approve.py`, which reads the doc-verify outcome | must wait: decided when the document class is armed |

`claim-proof-check-watchdog.py`, `caroline_redteam_docverify.py`, `resolution-matcher.py` and
`close-resolved-conversations.py` stay. They were never proof processors.

## What is not armed

No job turns a read document into a core decision today. The reviewer's verdict lives in the verify ledger
(removal reads it); it writes no credit-request status.
Two later PRs do that, each on its own:

1. **the doc-verify refusal fix**: `credit-doc-verify.py`'s standing verdict is `verified` for 25 of 8,644 documents
   read (node-8, 2026-11-13 14:40Z), so the reader is the binding constraint before any decision step exists.
2. **the document gate predicate and arming**: a predicate for the document class in `muso-admin-api.sh`'s approve
   gate, then the registry row and `approve_arm`, per `data/proof-processing-ovh-e1/arming-wall.md`.

- `policies/credit-approval-automation.json`: the document class (`credit_review/doc_approve.py`) is
  `approved: false`. `doc_approvals` has 0 rows.
- doc-verify's outcomes stay in `doc-verify.sqlite`. Core's `credit_document_verdicts` table has 0 rows and no
  code in this repo writes it.
- `/var/lib/hydra-credit-verify/doc-approve.frozen` exists on node-8 since 2026-11-05 and holds the text of a
  test fixture (`filler-48`, `scripts/tests/test_doc_approve.py`). It blocks nothing while the class is not
  armed and it would block the class the day it is armed. A freeze is never cleared by code
  (`doc_approve.freeze`): a person reads it and removes it.
- There is no in-app upload channel to read: core's `verifications` table last took an `upload` row in 2018 and
  any row in 2022.

Arming a document decision is a new approval automation: a recorded captain decision and a registry row, never a
side effect of a feeder or marker change.

## Reading the path

`data/proof-processing-ovh-e1/tools/measure.py` prints the stage counts (documents on file, notes answered,
requests on answered notes by core status, doc-verify outcomes, decisions). Counts only. A failed replica read
prints `unread`, never zero.

# Proof processing on OVH: what was wrong, what was fixed, what moved (2026-11-13)

Host node-8. Baseline read 12:02-12:10Z (`baseline.md`), last measurement 13:50Z
(`measurements/measure-1350Z.json`). Counts only.

## Headline

- **No request moved to a decision because of this work, and none can yet.** No job on node-8 turns a read
  document into a decision. `doc_approvals` has 0 rows, core's `credit_document_verdicts` has 0 rows, and the
  document approval class is registered `approved: false`. Arming it is a captain decision.
- **The marker never fired from code.** The 103 rows were written in one second on 2026-11-09 by a backfill that
  is not in the repo. It is fixed: 662 sent notes are now marked answered, from the documents on file.
- **The document feeder had saved nothing for 67 hours.** It is fixed and its backlog is draining on node-8 now:
  355 documents filed so far today, 2,514 conversations still to read, about 4 more hours.

## Before and after

| measure | before (12:02-12:10Z) | after (13:50Z) |
| --- | --- | --- |
| documents on file (`proof_intake`) | 9,604 | 9,959 |
| accounts with a document | 2,611 | 2,660 |
| feeder cursor | 2026-11-10T17:15Z | 2026-11-13T13:01Z |
| conversations waiting to be read | 2,835, in a window no run could finish | 2,514, saved in the state, 400 read per run |
| sent notes marked answered (`proof_tagged_at`) | 103 | 662 |
| accounts with an answered note | not counted | 557 (271 paying at 13:33Z) |
| credit requests on an answered note | 1,751 | 7,925 |
| of those, still pending in core | 1,338 | 5,886 |
| requests named by a document on file, still pending in core | 23,221 (12:50Z) | 24,876 |
| requests moved to a decision by a document | 0 | 0 |
| `doc_approvals` rows | 0 | 0 |
| requests older than today that core decided today (every path) | 5 (12:50Z) | 5 |
| pending in core (`user_verification_needed` + `unverified`) | 99,903 (12:50Z) | 99,969 |

Pending in core rose by 66 in the hour: 1,108 of the pending requests were created today.

"Still waiting on us" has three sizes, all at 13:50Z: 5,886 pending requests on a note the customer answered
with a document; 24,876 pending requests that a document on file names; 99,969 pending in total.

## 1. The inbound path, processor by processor

| processor | reads | writes | last successful run | feeds a decision? |
| --- | --- | --- | --- | --- |
| `credit-proof.py file-recent` | Intercom conversations, support@ mail | `proof_intake` | 2026-11-10 17:15Z, then 36 of 37 runs failed | no: files only |
| `credit-proof.py intercom` / `stage2` | the same documents | `verdicts`, `stage2_shadow` (shadow) | stage2 11:20Z | no: stage 2 only releases a credit to an ask, and its four ask crons are off |
| `credit-proof.py email` (Maildir) | a mailbox | `proof_intake` | never: cron disabled | no |
| `cs-proof-feed.sh` | the same Intercom conversations and mailbox | `cs-proofs.json`, 87,217 entries for 32,480 accounts | 11:21Z | no: it holds an ask back when a document is on file |
| `claim-proof-check-watchdog.py` | the claim proof check's files | nothing | 12:43Z (inside `credit-verify-outbound.sh`) | no: an alarm. The check it watches ran 12:30Z in dry-run: 376 asked, 0 approved |
| `credit-no-proof-close.py` | the ledger | nothing | never: no cron, no timer, 0 rows | no |
| `caroline_redteam_docverify.py` | test cases | nothing | 06:10Z | no: a test |
| `resolution-matcher.py` | shipped fixes | Intercom notes | 12:25Z | no: not about proof |
| `close-resolved-conversations.py` | ClickUp, Intercom | Intercom closes | 08:35Z | no: not about proof |

The reader that follows the feeder is `credit-doc-verify.py` (not one of the seven), last run 11:52Z. Its newest
outcome per claim: unverifiable for 22,431 requests, unknown for 1,355, verified for 15. Of the 15 verified,
11 are still pending in core and 3 are approved. It has not yet keyed 2,715 of the 9,959 documents.

**Which one should set `proof_tagged_at`: none of the seven did.** The writer was the Intercom tag sweep
(`verify_notify.sweep_proofs`), reachable only from `verify-notify --mode apply`.

**Why it stopped on 13 October: it did not stop, it never ran.** The sweep's code landed on 2026-10-17
(`7fa1c1bd3`). It has recorded a look on 0 rows (`proof_checked_at`), and the journal has no tag line since
2026-10-01. All 103 marked rows have the same `updated_at`, 2026-11-09T12:48:03Z; 102 carry a marker dated
before the row was created; 96 have no conversation id, which the sweep always writes. Their dates run from
2026-05-22 to 2026-10-21. The cron that would run the sweep was retired on 2026-11-06.

## 2. The marker fix

`scripts/credit_review/proof_marker.py` sets the marker from `proof_intake`: a document dated after the note,
filed against one of the note's requests (any document for a claim note). Cron `credit-proof-marker`, hourly
:45, kill file `/etc/hydra/proof-marker.disabled`. Tests: `scripts/tests/test_proof_marker.py` (17), in PR
Validation.

Applied on node-8 from a scratch copy of this branch:

| run | notes marked |
| --- | --- |
| `pm-20261113T123401Z` | 534 |
| `pm-20261113T131320Z` | 18 |
| `pm-20261113T134321Z` | 7 |

By campaign at 13:50Z: uvn-status 257, status-team-review 143, status-doc-received 134, gap-ask 90,
claim-proof-ask 19, claim-status 16, proof-need-ask 2, verify-live 1.

Not marked, and why: 7,466 sent notes have no document dated after them; 17 have a document for a different
request; 1,517 sent notes carry no account id and cannot be measured.

The marker sends nothing. Its effect on senders: a marked credit note makes `past_user_done`, `uvn_user_done`
and the reminder gate answer `proof_received`, so those accounts are no longer asked again for a document they
sent.

## 3. Processing everything pending

Channels: Intercom ran. Email ran (`/etc/hydra/gmail-readers.disabled` is absent). There is no in-app upload
channel: core's `verifications` table took its last `upload` row in 2018.

Why the feeder was dark: the state was saved only when a run finished. A kill-file pause of about 24 hours (2026-11-10
19Z to 2026-11-11 19Z, 24 runs of 0 s in the gateway's run records) left more conversations than one run reads before the cron's 3000 s kill. From then, 36 of
37 runs failed (31 at the kill) and each started over on a longer window. A second caller on the host
(`/usr/local/bin/cs-credit-proof-file.sh`, not in the repo) reported exit 0 on "another run is in flight".

Fixed in `scripts/credit_verify/proof/recent.py`: the search result is saved before any conversation is read,
the state is saved every 25 conversations, and a run stops itself at 2400 s. Tests:
`scripts/tests/test_proof_intake.py` (91).

The drain on node-8 (`tools/run-feed-drain.sh`, this branch's code, production state and store), first full run
13:06-13:49Z:

| measure | count |
| --- | --- |
| conversations read | 400 |
| documents found | 579 |
| documents filed (new) | 192 |
| documents already on file | 370 |
| conversations with no document | 98 |
| conversations that could not be tied to one account | 62 |
| files that are not a PDF or image | 17 |
| file errors | 3 |
| conversations carried on the 500-download cap | 66 |
| emails taken | 60 |
| new documents from email | 0 |
| emails to retry / still carried | 2 / 61 |

Today in total: 355 documents filed (9,604 to 9,959), 559 notes marked, 0 requests moved to a decision.

Could not be read today (72 conversations in the unresolved tray): 62 where the Intercom contact's id is not a
Muso account, 6 with no user contact, 2 with two user contacts, 2 where the contact is younger than 24 h. These
are the feeder's identity rules and were not loosened.

Email is bound by the existing budget of 60 Gmail reads an hour. The run's email breakdown was cut off by the
log line's length; that is fixed in this branch (the line now carries counts) and reads from the next run.

## 4. One path

Target and retirement table: `docs/credit-verification/proof-path.md`. In short:

- one feeder: `credit-proof.py file-recent`;
- one reader: `credit-doc-verify.py`;
- one decision step: `doc_approve.py` for credits and `claim-doc-ladder.py` for claims, both not armed;
- one marker: `proof_marker.py`.

Retire now (each in its own PR, replacement named in the doc): the tag sweep, the host's second `file-recent`
caller, `credit-no-proof-close.py`, the Maildir `email` subcommand. Must wait: `cs-proof-feed.sh` (its list
covers 32,480 accounts and `proof_intake` 2,660) and `credit-proof.py stage2` (it releases credits to two ask
families). Nothing was deleted.

## 5. What is still open

1. **The decision step.** 11 pending requests have a verified document today and nothing acts on it. The
   decision to arm it was recorded at 13:59Z; the registry row is one of six switches, and hydra's own write gate
   refuses every document approval until it gets a predicate for the class: `arming-wall.md`.
2. **`/var/lib/hydra-credit-verify/doc-approve.frozen`** holds a test fixture's text since 2026-11-05. It would
   block the class the day it is armed. Not touched.
3. **Deploy.** node-8 runs `6e8a65d8`. Until this branch is deployed the hourly feeder is the old code and the
   marker cron does not exist.
4. **The brief's two counts were not reproduced.** 1,559 paying accounts have a document in `proof_intake`
   (the brief says 483). The 1,221 free list entries were not measured.

## Left running on node-8

| what | stops when | undo |
| --- | --- | --- |
| `/root/proof-e1/run-feed-drain.sh` (started 13:06Z) | nothing is carried, a kill file, a quota signal, a failed run, or 20 runs | kill it; a killed run loses nothing |
| `/root/proof-e1/run-marker-while-draining.sh` (every 30 min) | the drain ends | kill it; `proof_marker.py revert --run-id RUN` per run |

The three kill files present at the start (`apply-queue`, `credit-trust-decide-provisional-paid`,
`fable-decider`) were not touched. No message was sent. No credit status was written.

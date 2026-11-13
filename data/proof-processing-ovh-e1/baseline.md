# Proof processing on OVH: baseline (read-only), 2026-11-13 12:02-12:10Z

Host node-8, deployed sha `6e8a65d8b4e1e1ec8e9b0f6eb6a559b7a28a8f1f`. Every number below is a
read-only query (`sqlite3 -readonly`, `ls`, `ps`, `journalctl`). Nothing was written to the host.

## 1. The marker (`verify_messages.proof_tagged_at`)

| fact | value |
| --- | --- |
| rows with the marker | 103 |
| stamped range | 2026-05-22 .. 2026-10-21 |
| `updated_at` of those rows | 2026-11-09T12:48:03Z on all 103 (one second) |
| marker earlier than the row's own `created_at` | 102 of 103 |
| rows with a `conversation_id` | 7 of 103 |
| `proof_checked_at` set (the sweep's "I looked" stamp) | 0 rows |
| journal lines `TAGGED` / `tag-proof` since 2026-10-01 | 0 |

The only code that writes the marker is `verify_ledger.mark_tagged`, reached only through
`verify_notify.sweep_proofs` -> `intercom-verify-request.sh tag-proof`. All three landed in one
commit on 2026-10-17 (`7fa1c1bd3`, #1239). `mark_tagged` stamps the current time and always
writes a `conversation_id`. The 103 rows carry dates before the code existed, before the rows
existed, and 96 have no conversation id. So the 103 are one out-of-repo backfill on 2026-11-09
that copied document dates. **The production tagger has no recorded firing at all.** The marker
did not stop on 13 October; it never started.

Why it never ran: `sweep_proofs` is called only from `credit-review.py verify-notify --mode apply`,
whose cron `credit-trust-verify-notify-15m` is `enabled: false` (retired 2026-11-06; the retro wave
`credit-past-verify-wave-15m` is disabled too). Kill file `/etc/hydra/credit-verify-notify.disabled`
is absent, so the cron flag is the off-switch. None of the seven named processors writes the marker.

Sent rows in the ledger: 9,655 (`account_id` on 8,138; `sent_at` on 8,248; 1,517 carry only an
email key).

## 2. Documents are arriving (`proof.sqlite` `proof_intake`)

| fact | value |
| --- | --- |
| documents on file | 9,604 |
| accounts | 2,611 |
| newest `received_at` | 2026-11-13T09:19:13Z |
| rows with no local bytes (`file_path` NULL) | 3,737 |
| by writer: `credit-proof.py file` (Intercom) | 5,550 docs / 1,550 accounts, newest 2026-11-03 |
| by writer: `intake-cron` (Intercom, hourly) | 2,835 / 968, newest 2026-11-13T09:19Z |
| by writer: `file --source gmail` (email) | 1,219 / 406, newest 2026-11-10T17:42Z |
| `proof_link_intake` (links as proof) | 0 rows |

Received per day, last 8: 11-13 24, 11-12 62, 11-11 42, 11-10 120, 11-09 302, 11-08 84,
11-07 167, 11-06 343.

## 3. Reading and judging

| stage | store | measured |
| --- | --- | --- |
| forensics / stage 2 (shadow) | `stage2_shadow` | 48,750 rows, 15,314 requests, 1,342 accounts, newest 11:20Z today |
| stage 2 latest outcome per (request, role) | | need_more 26,119; no_document 8,895; review 205; human 30; undetermined 25; reject_hold 11; approve 2 |
| doc-verify (shadow) | `dv_outcomes` | 658,839 rows, 8,608 documents, 23,757 requests, 1,939 accounts, newest 11:52Z today |
| doc-verify by outcome (rows / requests) | | unverifiable 611,462 / 23,246; unknown 46,162 / 3,626; verified 950 / 161; forged 139 / 66; forged_positive 126 / 57 |
| intake rows doc-verify has keyed | `dv_intake_keys` | 7,239 (unmatched 516); distinct intake ids with an outcome 7,025 |

## 4. Deciding

| fact | value |
| --- | --- |
| `doc_approvals` rows | 0 |
| `doc_approval_freeze` row in the ledger | none |
| freeze marker file `/var/lib/hydra-credit-verify/doc-approve.frozen` | present, written 2026-11-05T21:19:31Z |
| its text | names `filler-48` and a 2026-10-11T03:00:00Z clock |
| `decisions` rows with `decision = approve`, last 10 days | 0 (only `judge` mode: support / defer / hold) |
| `request_state` | ASKED 61,228; OPEN_UNASKED 15,545; CLOSED_STALE 7,702; DUPLICATE 6,631; PROOF_RECEIVED 1,755 |
| newest `request_state.entered_at` | 2026-11-11T04:27Z |
| `state_transitions` rows | 0, ever |

`filler-<n>` is a fixture id in `scripts/tests/test_doc_approve.py:2010`. The freeze file on the
production path holds a test's text. The document approval class is registered and not armed
(`policies/credit-approval-automation.json`, `approved: false`), so the file blocks nothing today,
and it would block the class the day it is armed. Not touched.

## 5. Schedules on the host

| job | schedule | state at 12:05Z |
| --- | --- | --- |
| `cs-proof-feed.sh` | cron.d hourly :21 | ran 11:21Z, exit clean, feed 87,217 entries / 32,480 users; 16,309 contacts unresolved |
| `credit-proof.py file-recent` (openclaw cron `credit-verify-proof-file`) | hourly :15 | a run started 11:55:05Z, still running at 12:09Z |
| `cs-credit-proof-file.sh` (host file, not in the repo) | cron.d :37 every 2 h | every run since 2026-11-11 exits 0 with "another file-recent run is in flight" (13 times) or 124 |
| `proof-file-state.json` window | | `since` = 2026-11-10T17:15:02Z, file last written 2026-11-10T18:01:45Z |
| `credit-proof.py intercom` | openclaw :05,:35 | enabled |
| `credit-proof.py email` (Maildir) | openclaw */10 | `enabled: false` |
| `credit-proof.py stage2` | openclaw :20 | enabled, ran 11:20Z |
| `credit-doc-verify.py run` | openclaw :50 | enabled, ran 11:52Z |
| `claim-proof-check-c2` (core-backend lane, off-repo path) | cron.d :30 | ran 11:30Z; `claims.jsonl` 0 bytes |
| `claim-doc-ladder.timer` | 4 h | ran 08:40Z |
| `resolution-matcher.timer` | daily | ran 2026-11-12 12:16Z |
| `close-resolved-conversations.timer` | 6 h | ran 08:25Z |
| `credit-stage2-gap-ask-*`, `credit-stage2-uvn-*` | openclaw | all four `enabled: false` |

Kill files present: `apply-queue.disabled` (2026-11-13T01:10Z), `credit-trust-decide-provisional-paid.disabled`
(2026-10-21), `fable-decider.disabled` (2026-10-29). Not touched.

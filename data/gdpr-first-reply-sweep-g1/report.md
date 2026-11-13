# GDPR first reply: why 168 requests had no message, and what this change does

Read-only measurements of the live register on node-8 (`/var/lib/hydra-gdpr/erasure.sqlite`), 2026-11-13 02:10Z to
03:34Z. Register numbers and counts only: no name, address or body is in this file.

## The sweep: started 03:33Z, 25 sent, 143 still without a first message

Firstmate's instruction (inbox 001, 02:51Z) was to re-run the reviewer-host installer and send. What happened:

| step | result |
|---|---|
| installer re-run on ak47, 03:02:59Z, from the bytes node-8 runs (`7a761a4e9`) | rc 0; `outbound-copy-rubric-gdpr.md` (`9237b374`) installed; previous install kept as `outbound-copy-review.bak-20261113T030259Z` |
| review round before (02:51Z) | `skipped_bad_request 68`, `approve 0`, result `ok` |
| review round after (03:06Z) | `skipped_bad_request 0`, `queued 60`, `approve 48`, 12 `reviewer_unavailable` |
| review round after (03:21Z) | `skipped_bad_request 0`, `queued 60`, `approve 59`, `rewrite 1` |
| node-8 ladder tick, 03:26Z to 03:33Z | 46 owed: **25 sent**, 19 refused (no route), 2 held |
| clock read back, 03:34Z | `no_first_message` **168 -> 143**; `closed_without_response` still `[13]` |

All 25 are late status updates over Intercom, each sent on a signed verdict for its exact bytes, oldest statutory date
first among the requests with a route. None is in `sending` or `unknown`. The oldest answered is #327: received
2026-04-05, due 2026-05-05, sent 2026-11-13T03:33:03Z. The 25, in the order sent: #327, #341, #402, #235, #360, #325,
#365, #321, #211, #335, #355, #234, #233, #353, #348, #208, #370, #349, #350, #228, #347, #368, #369, #345, #231.

Each send is on its row: `erasure_sends.at` is the time it went, `erasure_requests.due_at` the statutory date,
`status_sent_at` and `next_contact_at` are stamped (25 of 25), and there is one `dsar_sent` event per send. The single
event carrying both dates (`first_reply_due_at`, `sent_at`) is in this change and is not deployed yet.

**Still to go, with nobody driving it:** 117 approved letters (37 acknowledgements, 80 status updates) leave on the
hourly tick, 25 a tick. The extra ticks were not forced: the cap is what bounded the first-ever ladder send to 25.

**Not done:**

- #13 is still closed and unwritten. Reopening it is `Run.reopen_unanswered` in this change; it needs a deploy.
- #468, the oldest open request (received 2024-01-04), has no identity chain and a `confirm-interim` send in
  `unknown` that only a person resolves. It was not written to.
- Each late update promises the next message within 14 days, and an answer date where we need nothing from the
  requester. The clock's `promises_missed` now has 25 dates to hold us to.
- After this change deploys, the installer has to be re-run on ak47 again so the reviewer host has the new
  `review_pull.py` and `gate.py`.

Undo of the install: `install-reviewer-host.sh --uninstall`, or restore the `.bak` directory. A sent message has no
undo.

## What was measured

| | 02:10Z | 03:00Z |
|---|---|---|
| open statutory requests (clock) | 306 | 307 |
| past their date | 151 | 151 |
| no first message after 48 h | 168 | 168 |
| closed with no final response | #13 | #13 |
| open statutory rows with no identity chain (`gates.v`) | 243 | 80 |
| ladder letters authored | 76, all held `copy_review_pending` | 76, all held |
| ladder letters sent, ever | 0 | 0 |
| bodies waiting at the copy gate (`pending-age`) | 68 | 68, oldest 5.5 h |

Of the 168: 118 past their date, 8 inside 3 days of it, 42 with 3 days or more left. 74 had a letter authored and
held; 94 had no identity chain and so were owed nothing.

## Four causes

1. **The reviewer host cannot review a statutory letter.** Its install (2026-11-12 08:45Z) has no
   `outbound-copy-rubric-gdpr.md`. `gate.review()` counted every `gdpr-ack` and `gdpr-status` body as
   `skipped_bad_request`, and the round printed `"result": "ok"` every 15 minutes with 68 bodies waiting.
   `review_pull.py` compared only the default rubric between the two hosts, so the check passed. Reproduced by
   loading the installed gate: `GateError: rubric 'gdpr' unreadable`. The installed `gate.py`, `review_pull.py`,
   default rubric and signers file are byte-identical to node-8's.
2. **A row decided before the identity chain shipped waited for its 20 h refresh.** The chain deployed at
   2026-11-12 21:32Z; `decide_all` did not select a recently decided row, and `dsar.owed` returns nothing for a row
   with no `gates.v`. 243 rows at 02:10Z, 80 at 03:00Z as the refresh works through them.
3. **A failed identity read left a request with no chain**, so a source that is down keeps every request arriving
   that day outside the ladder.
4. **A closed row is read by no pass.** #13 was created `closed` from the markdown register on 2026-11-01 with no
   response recorded; the clock named it and nothing could write to it.

## What this change does

- `review_pull.py` compares each waiting campaign's rubric on both hosts before reviewing it. A family this host
  lacks, or holds differently, is left unreviewed and named in `unreviewable`; the round exits 1 `incomplete`.
  `gate.review()` counts an unreadable rubric as `rubric_unavailable`, never as a bad request.
- `decide_all` selects a statutory row with no chain on every tick.
- `Run.chain_unread` writes an `unknown` chain when the identity reads fail and the row has none, so the row is
  owed `ack_unknown`. It makes no decision and never replaces a chain a real read wrote.
- `Run.reopen_unanswered` reopens a statutory row closed with no final response, before the tick decides. The
  markdown register can no longer create or set one closed. Undo: `status='closed'` on the row.
- Every ladder send writes a `dsar_sent` event with `received_at`, `statutory_due_at`, `sent_at` and, for a first
  message, `first_reply_due_at` (arrival + 24 h) and `first_reply_late_hours`.
- `dsar clock --json` lists `first_reply_overdue` (24 h). The line that pages keeps the 48 h list.

Which message is owed is unchanged, and so is the copy. A request past its date gets the late status update as its
first message, not an acknowledgement: the acknowledgement states an answer date that has already gone.

## What the sweep will not reach

- **60 of the 168 have no route a ladder letter can use** (measured 03:05Z from `conversation_id`, `gmail_thread`,
  `requester_email` and `channel`; 103 have an Intercom conversation and 5 a `support@` thread, so 108 are
  reachable). 41 arrived in a `legal@` or `notices@` thread, mailboxes this host cannot write, and 38 of those have
  no requester address on the row. 19 have neither a conversation nor a thread; 6 of those have an address. A ladder
  letter is never sent as a new mail thread (`send.deliver`), so an address alone is not a route. They stay on the
  clock.
- **8 are inside 3 days of their date** and are owed nothing until it passes.
- **A letter leaves only on the reviewer's approval of its exact bytes**, at most 25 a tick, hourly.

## Not verified

- One status body got a `rewrite` and stays held; which request it belongs to was not looked up.
- #13's Intercom thread was not read (no token in a plain shell on node-8): "no response" is the register's record.
- The reopen and the chainless selection were tested on fixtures and measured as counts on the live register (one
  closed row, 80 chainless rows), not run against a copy of it.

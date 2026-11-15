# The customer-last backlog drain (`scripts/intercom-backlog/drain.py`)

Captain 2026-11-13: "issues like this need responses by caroline and she isn't responding ... look at all
the intercom messages without responses". This is the sender for the open conversations nobody answers
because nothing in the plugin replies until the customer writes again.

## What was measured (2026-11-13 18:58Z, 9,496 open conversations)

The sentinel's `intercom_customer_last` rule named 1,669 conversations older than 4 hours. Read part by
part:

| | conversations |
|---|---|
| not owed: the thread ends on our own reply (865 posted as the workspace bot Caroline's answers went out under before she had a seat; the statistics flag does not count that author), a thanks, or automated mail | 953 |
| owed an answer | 610 |
| billing, erasure or legal | 106 |

So the sentinel's count overstates what is owed by more than half. `read_thread()` in the drain reads the
parts, not the statistics block, for that reason.

## What it sends

One fixed body from `LINES`, chosen by code. No name, count or date is filled in: the bytes the reviewer
approves are the bytes every person gets.

| line | sent when |
|---|---|
| `no-account` | no single Muso account resolves from the contact (the house resolver, then the bare account number; see below) |
| `credits-approved` | the thread asks where a request stands, and every request on the account is approved |
| `credits-decided` | as above, some approved and some declined |
| `credits-declined` | as above, and every request on the account was declined |
| `no-request` | as above, and the account has no credit request and no pending claim |
| `late-reply` | the thread is about something else (a merge, a removal, stats) and has been quiet over 30 days |
| `stale-close` | we wrote last, the customer has been silent over 90 days, no open promise: note, then close |

**Who the contact is comes from `scripts/credit_review/identity_resolver.py`, in `triage.py`.** The contact's
Intercom id resolves when it is, for exactly one account, the professional id, the Auth0 subject, or the
presented profile (a processed claim, or the profile the account represents). The mobile app logs into Intercom
with the presented profile. Until 2026-11-14 `triage.py` matched on the `users` table alone, so a mobile claimant
read as `no-identity`: the first armed run sent the `no-account` line to 26 threads, and 20 of those contacts
were signed in to an account the resolver finds. One recorded fallback follows the resolver: a contact whose
Intercom id is a bare account number (`users.id`) is that account, so no contact that matched before reads as
no account (firstmate 2026-11-14 21:42Z). The fallback is read only for an id the resolver leaves with no owner
at all and never overrides a refusal, so an id two accounts own, or one another account's claim was reverted
on, stays `ambiguous-identity`. `triage.py` writes `matched_by` (`users_id` when the fallback answered) and,
for an unresolved contact, `identity_why` on every row. An email match is never an identity.

**Send order is a recorded decision.** A paying customer comes first (firstmate 2026-11-15 09:14Z: "paid
first, then proof-sent, then oldest inside each group"); then the threads whose customer already sent
proof, because those customers did their part and are waiting on us (firstmate 2026-11-13 23:29Z, confirmed
2026-11-14 on review finding send-order-puts-proof-sent-ahead-of-oldest); then oldest first. Closes come
after every answer, and inside the closes and the hand-backs a paying customer is first too. A contact
with no account is not paid. A run is capped, so the order decides who is answered in a run, not just how
the plan reads: the first four runs (200 sends, 2026-11-14 and 11-15) went out without the paid key
(`plan_order` in `drain.py`). The three keys are lexicographic by decision (firstmate 2026-11-15 09:28Z,
on review finding paid-group-not-oldest-first): inside the paying customers, those who already sent proof
come first, then oldest.

**A thread with an open promise gets a line only when the line is the promised update.** The monitor's
ledger (`commitments`, open rows) lists what we told the customer we would do. The three
every-request-decided lines keep a `credit_verification` or `request_status` promise and nothing else;
`no-request`, `no-account` and `late-reply` keep none (`PROMISE_MET_BY`). Any other pairing is listed
`caroline` / `open_promise` in the plan with the promise kinds in its basis, and is handed back when the
customer spoke last. Measured on node-8 2026-11-14 15:32Z: 90 of the 610 owed threads carry an open
promise, and 62 of them were planned for a fixed line before this rule. The promises are read again in
the run and checked against the line picked in the run, so a promise opened after the plan, or an account
line that changed at send time, skips the row as `an open promise this line does not keep`. A thread
where WE wrote last and the open promise is not kept by a line gets nothing from this sender: there is
no customer message for Caroline's turn to answer, and the promise stays on the monitor's ledger.

## What it never sends, and where those rows go

| plan list | meaning |
|---|---|
| `owner` | the account has an open credit request or a pending claim. The verification senders own that answer (`proof-need-ask`, `uvn-status`, `status-doc-received`, `status-team-review`, `claim-status`); there is one reviewed ask path and this is not it. The row names the campaign. When the customer wrote in the last 30 days it is handed back (below); an older one stays with its campaign. |
| `caroline` | a thread about something other than a request's status, written in the last 30 days. A fixed line cannot answer it, so it is handed back to Caroline's live turn (below). |
| `separate` | billing, legal, erasure, or a hand-read override. Never handed back. A thread the monitor shapes as `gdpr_erasure`, `legal_notice` or `refund_dispute` joins this list whatever its census topic says (`SEPARATE_SHAPES`): the topic is a keyword read of the opening message, and on 2026-11-15 it had typed 11 such threads "other", which planned them for the late-reply line. The shape is a pattern match too, so the row is only kept out here: it is never sent, closed or handed back, and it has no sender until its own lane takes it. The shape is read again in the run, so a thread reclassified after the plan is skipped as `monitor shape <shape>: outside this sender`. Which lane owns each shape (firstmate 2026-11-15 08:07Z): `gdpr_erasure` the GDPR pipeline's DSAR ladder (`docs/support/gdpr-pipeline.md`); `legal_notice` and `refund_dispute` the legal / refund lane. This sender sends them nothing; the plan summary's `separate_by_class` is the count to hand over. |
| `held` | assigned to a person, the escalation queue or a staffed inbox (the holder table below), or a restricted contact. Never handed back. |
| `not_owed`, `unread` | nothing is owed, or the thread could not be read in full. Never handed back. |

## Who holds the thread

Read once from the monitor's ONE who-is-who rule — `policies/caroline-shapes.json`
`monitor.non_human_admin_ids` / `monitor.staffed_team_ids`, falling back to
`scripts/caroline_monitor/rules.py` — never from a second list in the sender.

| holder | who | what happens |
|---|---|---|
| `caroline` | `5763097` | answered |
| `bot` | any other id on the non-human list (the Operator bot `4359478` answers as Caroline) | assigned to Caroline first, then answered |
| `nobody` | no admin, and no worked team | assigned to Caroline first, then answered |
| `person` | any other admin id | held |
| `escalation_team` | no admin, the escalation team | held |
| `staffed_team` | no admin, a team on the staffed list (empty today) | held |

firstmate 2026-11-14 01:25Z: the bots count as Caroline-side, never as a person; an unassigned thread
is assigned to Caroline first and then answered, never planned and then skipped. The plan summary
counts the rows that will need it (`needs_assignment`), so the number is visible before a run.

A thread nothing of ours ever answered is still the population this sender exists for: 865 threads end
on a reply posted as the workspace bot, and every one of them read as "held by a person" until the
shared who-is-who rule replaced the raw id test.

## The hand-back

Every customer-last class has a sender in this file or a hand-back; nothing is left silently unanswered,
and nothing is reported as answered without a read of the thread that shows so.

**ONE hand-back note per thread, ever** (firstmate 2026-11-14 12:32Z): no repeats, no retry policy.

1. `drain.py send` walks the hand-back rows after the sending rows: every `caroline` row (a specific ask
   in the last 30 days, or an open promise no line here keeps) and every recent `owner` row, and only rows the send loop can post (`mode: answer`, the customer spoke last).
   Each passes the same send-time re-checks — its shared ledger key (`handback-<conversation id>`, one
   note per conversation ever), the user's one message per UTC day, a live read (still open, still
   customer-last, not held, no marker note on it yet), the erasure register and every contact on the
   thread against the restricted list. The note needs the thread on Caroline for the plugin's own gate,
   so a thread on a bot or on nobody is assigned to her first (the assignment step).
2. It posts ONE internal note as Caroline through `intercom-ops-write.sh note` (`--audience team`). The
   note is `HANDBACK_MARKER` plus the reason code and the class (`specific ask`, `open promise`, or the
   owner's campaign).
   It carries no customer text. The run audit gets `intent` before it and `handback_posted` after it.
   Hand-backs count inside `--max` and have their own per-run cap (25) with 2 s between them, because each
   one starts a model turn. A dry run posts nothing.
3. Both readers find the marker on a LINE of the stored body, never at its start: `intercom-ops-write.sh`
   puts its own `Note to team (internal Ops note, …)` header above the body it is given. `is_handback_note()`
   in `drain.py` and `handbackNoteReason()` in `plugins/intercom/src/filters.ts` are the two copies of that
   rule, a line each language, and nothing compares them: change both together.
4. `plugins/intercom/src/handler.ts` reads the thread live on `conversation.admin.noted`. Only this bot's
   own newest note, on an open thread assigned to her and still customer-last, continues into the
   ordinary customer-message path: every guard decides (restricted accounts, human hold, the escalation
   gate, blocked channel tags, risk assessment, the output guard), and the session is created when there
   is none. Any other note stays `ignored: internal note`. **The plugin half must be deployed before any
   hand-back can be confirmed**: nothing else turns the note into a reply.

**The thread is the record.** `read_thread` reports the newest marker note on the conversation
(`handback_note_at`), so "how is this hand-back going" is answered by reading the conversation, not by any
file a run wrote. At plan time a thread that carries a marker note is counted:

| plan summary | the thread shows | next |
|---|---|---|
| `handback_confirmed` | a worded comment of ours after the note | ordinary rules; not owed |
| `handback_pending` | the customer still last, the note younger than 24 h | nothing; listed |
| `handback_unconfirmed` | the customer still last, the note 24 h or older | nothing; listed, with the ids |

`handback_unconfirmed` is owed and it is visible: the plan carries the conversation ids
(`handback_unconfirmed_ids`), and the next `send` run prints each id as `HANDBACK UNCONFIRMED <id>
note_at=<ts>` (`HANDBACK PENDING <id> note_at=<ts>` inside the window, which is not owed) — every plan row
in that state, including the ones the send loop does not walk. **The plan only names which threads to look
at: the run reads each of them again and prints the state the thread shows then.** A hand-back Caroline
answered after the plan was made is counted `handback_confirmed` and is not printed as owed; a thread the
run cannot read is `HANDBACK UNREAD <id>` (`handback_unread`, with its id), which claims neither. In a run, a hand-back row the sender does not
post is classified by the state its live read shows (`pending` and `unconfirmed` are counted and printed;
`confirmed` is neither), and a row whose shared key is claimed but whose note is not visible is counted
`handback_unconfirmed` — a claim whose POST failed, returned rc 4 or died before finalize stays in that count
instead of disappearing. A thread that carries a marker note is Caroline's: this sender
posts nothing on it at all, no second note and no fixed line, so her live turn is the only answer there.

## Follow-ups, not in this change

- Nothing answers a thread whose hand-back stays unconfirmed. It is listed as owed on every plan and
  run; what answers it is a later decision.
- A thread handed back once is never handed back again by this sender. A customer who writes again on it
  later is answered only by Caroline's live turn on that new message.

## The checks a row passes at send time

The plan is a list of candidates. Each row is checked again, in this order, and any failure skips it with
a counted reason:

1. the shared message ledger: one reply per conversation ever, one message per user per UTC day. A
   thread with no email at all is keyed on `intercom-contact:<contact id>` (a prefix no email can
   equal), so its day's cap is per contact: the same person writing from two contacts is two keys. A
   thread with no email AND no contact id cannot be keyed and is counted as `no_ledger_key` among the
   rows the run can act on;
2. the thread read now: still open, nobody wrote since the plan, not held;
3. the erasure register and the open promises, read again: an erasure row skips the thread, any open
   promise skips a close, and a line is skipped unless it is the promised update;
4. for a line that states account facts: the request states read from the core replica now pick the line
   (the census never does), the fraud lens is asked, a document on file or an open ask in 30 days holds
   it, and the thread has exactly one contact;
5. the outbound copy gate approves these exact bytes. An `observed` answer is a hold here, whatever the
   mode table says;
6. `intercom-ops-write.sh --validate`, the assignment if the thread is on a bot or on nobody, the ledger
   claim, then the one POST.

## The assignment step

A thread whose live read shows holder `bot` or `nobody` is assigned to Caroline before anything is sent
on it — the fixed line, the hand-back note and the stale close alike. Holder `caroline` needs nothing;
the three held holders are skipped as they are.

1. Every re-check above runs first, so a thread that is going to be skipped is never re-assigned.
2. The ledger gets `intent` with `what: assign` and the BEFORE values (`admin_assignee_id`,
   `team_assignee_id`) as the inverse, then ONE Intercom assignment part is posted as Caroline with
   Caroline as the assignee (`message_type: assignment`, `admin_id` and `assignee_id` both `5763097` —
   the forward assignee is a constant in the sender), then `assigned` carrying the inverse.
3. A read-back must show Caroline holding the thread. Anything else, or a read that fails (including a
   transport reset), is a counted failure (`assignment not confirmed`) and nothing is sent on that thread
   this run — the run continues to the next row and still prints its summary. The `assigned` row is
   written before the read-back, so an assignment that could not be confirmed is still one the undo
   finds: the part was posted, whether or not the read could see it.
4. An assignment counts inside `--max` and is paced with the write that follows it. It writes no
   customer-visible message, so it needs no copy verdict, and it never closes anything.
5. A dry run assigns nothing and prints `DRY-ASSIGN <id> from <holder>`.

A store or a read that fails sends nothing. A close happens only after this run's own note posted on that
conversation, and the state is read back.

## Running it (node-8, root)

```
set -a; . /etc/openclaw/main.env; set +a
cd /opt/hydra/scripts/intercom-backlog
python3 census.py && python3 triage.py <census.jsonl>
python3 drain.py plan <census.triage.jsonl> --out plan.jsonl
python3 drain.py lines                 # asks the gate about every body; an unreviewed one is queued
python3 drain.py send plan.jsonl       # dry run: what would go, and every skip by reason
python3 drain.py send plan.jsonl --apply --ledger run.jsonl --max 200
```

`--max` is at most 200 per run, hand-backs included. `--only LINE,LINE` restricts a run to those
lines and walks no hand-backs.

## Arming

This sender ships unarmed: no cron job, no systemd unit, no schedule in this repo. It runs only when a
person runs it by command (firstmate arms it after deploy with one capped run of `--max 50` and reads the
result back). A schedule is a separate PR, and a test fails if `cron-jobs.json` or a systemd unit in this
repo starts invoking `drain.py` with `--apply`.

## Undo

- A sent note cannot be unsent.
- `python3 drain.py reopen --ledger run.jsonl` opens again every conversation that run closed. A closed
  conversation also opens by itself when the customer replies.
- `python3 drain.py unassign --ledger run.jsonl` restores every assignment that ledger recorded, from the
  inverse on its `assigned` row: back to unassigned (`assignee_id: "0"`, and the team it had) or back to
  the non-human admin it was on. It writes its own rows to `run.jsonl.unassign`.
  It reads each conversation live first and restores only what this sender still holds: Caroline as the
  admin assignee, the same team, the thread still open. It refuses, writes nothing and says why when a
  person holds it now, it was escalated or moved to a staffed inbox, it is closed, it cannot be read, the
  live assignment is not the one this sender made, or the recorded holder was a person's id (not a state
  this sender can create). `unassign` exits 4 when any restore failed.

## Not covered

- Caroline's reply on a handed-back thread passes her output guard, and carries no signed copy verdict:
  the note is a trigger, not copy, and the reply is her ordinary live turn. A fixed line would need a
  verdict; this path deliberately has none.
- Every line needs a signed approval before its first send; until the reviewer has read a body,
  `drain.py send` skips every row that would use it (`copy_held`).

# Caroline monitor, fix loop and promise ledger

One job on node-8 reads Intercom every 2 hours and does three things with the same reading:

1. **Monitor.** Counts what Caroline did with each conversation and pages `#clio_devops` when a
   number moves the wrong way.
2. **Fix loop.** Sorts every conversation into a *shape* (the kind of ask), keeps one register row
   per shape saying what would fix it, and re-measures a shape after its fix ships.
3. **Promise ledger.** Records every "someone will take this from here" as a commitment with an
   owner, and writes `/var/lib/hydra/support-backlog.json` so anything else can read how support
   stands.

It reads Intercom and posts to Slack. It sends nothing to any customer and changes nothing in
Intercom.

Code: `scripts/caroline_monitor/`, entry point `scripts/caroline-monitor.py`.
Register: `policies/caroline-shapes.json`. Recorded numbers: `data/caroline-monitor/`.

## The one number

**Hand-offs with nobody assigned, per week.** A conversation counts when Caroline told the
customer that a person or the team will take over or follow up, and the conversation was never
assigned to a person.

| Week (conversations opened) | Hand-offs with nobody assigned | Of conversations |
|---|---|---|
| 2 to 9 Nov | **1,078** | 1,436 (75%) |
| 26 Oct to 2 Nov | 818 | 1,102 (74%) |
| 19 to 26 Oct | 428 | 661 (65%) |
| 12 to 19 Oct | 263 | 450 (58%) |

Read on 2026-11-11 23:50Z from all 9,386 conversations Intercom listed (0 read errors). It is
rising, so the monitor pages on its first run.

Each conversation is read as it stood 48 hours after it opened. Without that, the newest week
would always be read younger than the week it is compared with, and would always look better.

Over the last 30 days the same reading gives 2,770. The intent-mining report said 2,678 for
nearly the same 30 days. The difference has two known causes:

- That report also counted "your request is in the queue" lines as a hand-off. This monitor does
  not, because a truthful queue line is the outcome we want once Caroline can read request state.
  Queue lines are counted separately.
- Hand labels showed the first version of the rules missed about one promise in five among
  conversations counted as *not* handed off (11 of 50). The wording rules were widened and
  re-labelled (now 4 of 50). The first version reproduced the report's 2,678 exactly; the
  widened one counts more.

## What is measured

Every number comes from the Intercom API, read-only: `POST /conversations/search` to list,
`GET /conversations/{id}?display_as=plaintext` to read. Every conversation in scope is read;
nothing is sampled.

Weekly numbers (conversations opened in the week, each read 48h after it opened):

| Metric | How it is counted | Pages when |
|---|---|---|
| Hand-off with nobody assigned | She said a person is coming; no assignment to a human admin or a staffed team | up 10% and 25 conversations on the week before, or above the recorded baseline week |
| Hand-off rate | She said a person is coming, assigned or not | up 5 points |
| Assignment rate | Assigned to a human admin (not Caroline, not the Operator bot, not the default team inbox) | not on its own, see below |
| Human reply rate | A person wrote a reply the customer can see | not on its own, see below |
| Assigned, no human reply | Handed off and assigned, no person replied inside 48h | up 25% and 25 |
| No reply at all after 24h | The customer wrote, nobody answered; robots and bounces excluded | up 50% and 10 |
| Resolved without a hand-off | Caroline answered, no hand-off, no queue line, no assignment, and the customer's last message has an answer | down 5 points |
| Date or day-count promise | She named a number of days or a date | above 14 a week |
| Per shape | Hand-offs with nobody assigned inside one shape | up 30% and 15 in that shape |
| Fits no named shape | Share of conversations in `other` or `product_question` | above 25% |

The assignment rate and the human reply rate have no wrong direction by themselves: the two
Caroline fixes in flight push assignment in opposite directions (one assigns when it hands off,
the other makes human assignment an exception). They are recorded every tick and page through
the two numbers built from them: hand-offs with nobody assigned, and assigned with no human reply.

"Resolved" cannot mean "closed in Intercom": 9,080 conversations are open and almost none is
ever closed.

The monitor also pages when it cannot measure: once two ticks in a row could not read Intercom,
the listing came back short, or more than 2% of reads failed. The first unreadable tick is
recorded and posts the `NOT MEASURED` health line but does not page; it does not fail the unit.
At the second it pages through its own Slack post, and the run exits non-zero only if that page
or the health line could not be delivered, so the systemd `OnFailure` pager is the backstop and
never a duplicate. A register that will not load is not a transient read failure and fails the
first tick. A reading it could not take is never shown as a quiet one.

An unchanged finding is paged again only after 72 hours, and at once if it gets 10% worse. A
page is marked as sent only after Slack confirms it.

A one-line weekly post (Monday 08:00 UTC, no mention) carries the headline so it can be watched
without a page.

Every run also posts one health line to the same channel, with no mention: what it read, the
headline, the last 24 hours, who is waiting, the promises, and whether anything is paging. A run
that could not measure posts `NOT MEASURED` with the reason and repeats no old number. A health
line that could not be posted fails the run. Switch it off with `monitor.slack.health_line`, or
send it elsewhere with `monitor.slack.health_channel` or `CAROLINE_MONITOR_HEALTH_CHANNEL`.

## How right the rules are

The rules are regular expressions in one file, `scripts/caroline_monitor/rules.py`. They were
checked by hand labels, recorded in `data/caroline-monitor/calibration.json` (counts only).
One AI rater labelled them, blind to what the rules said. There was no second rater.

- **Did she really promise a person?** 50 of 50 counted hand-offs were real promises. 4 of 50
  conversations counted as not handed off held a promise the rules missed. So the headline
  undercounts by about 2% (2,757 counted against an estimated 2,811 on the labelled read).
- **Which shape?** 287 labels. Weighted accuracy 67%. It varies a lot by shape:

| Shape | Right | Labels |
|---|---|---|
| proof_sent (the largest) | 83% | 30 |
| artist_link, robot_mail, refund_dispute, human_request | 100% | 8 to 15 each |
| merge_split, proof_what_needed, profile_edit, account_access | 88% | 8 each |
| request_status | 40% | 15 |
| claim_start_problem, track_fix_takedown, legal_notice | 25% | 8 each |
| product_question, other | 20% | 15 each |
| app_bug, declined_why | 0% | 8 and 6 |

The `shapes` command prints this next to every shape. A shape the rules get right less than half
the time cannot prove its own fix: its re-measure verdict is `unmeasured` until the rule is
tightened and re-labelled.

Changing a rule means bumping `RULES_VERSION`, re-labelling, and re-recording the baseline. CI
fails while the labels on file are for older rules.

## The fix loop

The unit of work is the shape, never the conversation. The register refuses anything that looks
like a conversation id or an inbox link.

1. **Classify.** `rules.classify` gives every conversation one of 30 shapes.
2. **Record.** `policies/caroline-shapes.json` has one row per shape. CI fails if a shape has no
   row.
3. **Decide the fix type.**
   - `rule`: a fixed answer exists.
   - `tool`: Caroline is missing something she needs to read.
   - `copy`: she promises something wrong.
   - `refusal`: she must not answer it, and says why and how to re-apply.
   - `person`: it truly needs a person. The row must say why. These shapes together may not
     pass 6% of conversations (4.2% today).
4. **Automate only `rule` and `tool`.** The checker refuses an automation entry on any other row.
5. **Re-measure.** When a fix ships, its row gets `shipped_at` and a link. From then on every
   tick compares that shape's rate in the week before the fix with the week after, against all
   other shapes as the control:
   - `worked`: the shape fell at least 30%, and at least 15 points more than the others.
   - `did_not_work`: it did not. This pages.
   - `fell_with_everything`: everything fell together, so the fix gets no credit.
   - `too_early`, `unmeasured`, `not_shipped`: said as such, never shown as a pass.

Commands:

```
scripts/caroline-monitor.py shapes       # one row per shape: size, hand-offs, fix type, status, owner
scripts/caroline-monitor.py remeasure    # verdict for every shipped fix
scripts/caroline-monitor.py report       # the whole reading
python3 scripts/check-caroline-shapes.py # the register is valid (also runs in CI)
```

### Worked example, already shipped: day-count promises

- Shape of failure: Caroline promised "within N business days". Nobody was bound by it.
- Fix type: copy. Shipped 2026-10-29 (hydra PR 1451).
- Re-measured by the same code: 403 of 662 conversations (61%) in the week before, 42 of 1,108
  (4%) in the week after. Verdict `worked`. The row is marked verified.
- What is left: 14 a week, all from the approved claim copy that still says "usually within a
  day". The page ceiling is pinned at 14 and can only be lowered. Changing approved copy needs
  the copy owner, so this change does not touch it.

### Worked example, in flight: customer sends proof

- Shape: `proof_sent`, 795 conversations last week, 701 handed off with nobody assigned. It is
  65% of the headline.
- Fix type: tool. She cannot read whether proof is on file, so she hands off. Owner:
  `caroline-read-state-tools-r1`.
- Step 5 is armed and has not run: that fix has not shipped. When its PR merges, set
  `shipped_at` and `ref` on the `proof_sent` row. The next tick after 9 days gives the verdict.

### What the two fixes in flight must tell the register

- `caroline-read-state-tools-r1`: set `shipped_at` on its five shape rows and on
  `global_fixes.same_step_assignment`.
- `intercom-no-human-assignment-k1`: if it adds a bot admin or an AI queue, add the id to
  `monitor.non_human_admin_ids`. If it adds a queue that people actually work, add the team id to
  `monitor.staffed_team_ids`. Until then a team inbox does not count as an assignment, because
  the default team inbox is where every conversation already sits.

Either change re-reads every conversation under the new definition on the next tick.

## What Caroline must never do

Four things are not hand-offs. They are refusals with a reason and a way to re-apply, and the
register must carry all four:

| Never | Measured by |
|---|---|
| Assert a legal position | shapes `legal_notice`, `gdpr_erasure` |
| Disclose how a decision was reached | shape `declined_why` |
| Label someone fraudulent | shape `claim_conflict` |
| Promise a date | the date-promise count above |

They are enforced by the output guard (`plugins/intercom/src/caroline-output-guard.ts`), not by
this monitor. Today a guard hit replaces her reply with the hand-off line and assigns a person:
168 conversations last week, all assigned, none answered by a person within 48 hours. So the
guard's hits are not in the headline; they are most of the "assigned, no human reply" rise.

## The promise ledger

Every hand-off line or queue line Caroline sends opens a commitment. The row holds the
conversation, what is being done, what resolves it, when a job next owes the customer a word,
and an owner.

- **The owner is a rule, a job or a tool.** The checker refuses a person. A kind nobody can keep
  yet has no owner and must say why; it is counted as unowned, not hidden.
- **Only a sent message closes it.** A person's reply, or a message we started that says
  something other than "still in the queue". Closing the conversation, approving the request or
  moving a ticket does not close it. There is no function that closes a commitment; the row is
  rewritten only from a new read of the thread.
- **A check-in keeps it and leaves it open.** A message we started that says where things stand
  counts as kept for that day and sets the next check 24 hours on.
- **Answering the customer's next message is not us coming back.** This is strict and it
  undercounts kept promises: 1,469 of the 1,896 conversations with a later reply were answers to
  a new message.
- **The due time is ours.** 24 hours, never told to the customer. The ledger makes no date
  promise.

Kinds, in the captain's order (2026-11-11):

| Priority | Kind | Owner | Open | Overdue |
|---|---|---|---|---|
| 1 | Credit verification | `job:request-comms` | 1,907 | 1,794 |
| 2 | Analytics | nobody yet | 32 | 31 |
| 3 | Refund | nobody yet | 48 | 47 |
| 3 | Request status | `job:request-comms` | 246 | 230 |
| 4 | Claim | `job:request-comms` | 147 | 141 |
| 4 | Erasure | `job:request-comms` | 54 | 52 |
| 4 | Merge | nobody yet | 118 | 113 |
| | No kind | nobody | 1,152 | 1,086 |

In the 24 hours before the reading, 49 promises were kept and 380 broke.

### What sends the message back

**The requirement to communicate back to users is NOT satisfied by this change.** The ledger
records each promise, decides when a word is owed and queues it; three separate parts have to
land before a customer receives a line, and two of them are not in this tree:

- **The copy gate** — firstmate lane `outbound-copy-fable-gate-v1`: every outbound line is
  reviewed and signed before it can be sent. In progress, not in this tree.
- **The promise ledger** — this change, lane `caroline-monitor-and-fixloop-k2`:
  `scripts/caroline_monitor/commitments.py` records each promise, decides when a word is owed,
  and queues it in the outbox below.
- **The Intercom send** — the request status driver `scripts/request_comms/`, lane
  `user-comms-status-u1`, hydra PR 1700: off behind `enabled: false` in
  `policies/request-status-lines.json` and the `/etc/hydra/request-comms.live` file.

The existing request status driver (`scripts/request_comms/`, hourly) already sends one fixed
line per request state. Before it sends, it asks the ledger whether that customer is waiting on
a promise of that request type, and if so it replies on that conversation instead of beside it.
A ledger it cannot read changes nothing about the send.

**That driver is off, and this change does not turn it on.** `policies/request-status-lines.json`
has `enabled: false`, most lines have no approval, and `/etc/hydra/request-comms.live` must
exist on node-8. Every line it would send is new outbound copy and needs the captain's yes on
the exact words. Until then the ledger measures promises and keeps none. The 49 kept today came
from jobs that already write outcomes into threads.

### The outbox

A promise coming due is enqueued in `commitment_outbox` (same `monitor.sqlite`, written by every
good tick in the same transaction that syncs the ledger). One row per due cycle, keyed
`(conversation_id, promised_at, due_at)`; a second tick in the same cycle adds nothing. The row
holds the kind, the owner, the request type, and the line it calls for **by reference only** —
request type plus state `waiting` in `policies/request-status-lines.json`. Never message text.

State is `queued`, or `held` with a reason read from the real switches at enqueue time:
`no_owner`, `no_request_type`, `line_missing`, `line_disabled`, `line_unapproved`,
`driver_disabled`, `driver_killed` (`/etc/hydra/request-comms.disabled` is present, so the driver
returns without sending), `driver_not_live` (the driver policy is on but `/etc/hydra/request-comms.live` is absent, so a real send would not happen). **Today every row is held**, because the driver and most lines are disabled
and several kinds have no owner — the outbox shows exactly what stands between a promise and a
word to the customer.

A check-in or close read back from the thread marks that cycle's row `sent` (with the time read
from the thread); a commitment that closes otherwise marks its open rows `superseded`. A row
never closes a commitment and nothing in the module sends. Rows are not deleted while their
commitment is open; a row whose promise is no longer read from the thread is deleted, so the
counts cannot outlive the promise they describe. Counts appear as `messages_queued`, `messages_held` and
`messages_held_by_reason` in `support-backlog.json` and in the report next to the promises.

Analytics, refunds and merges have no owner because no job can read whether they moved: the
analytics freshness tool is still being designed, and refund and merge tickets carry no Muso
user id.

## support-backlog.json

Written by every good tick to `/var/lib/hydra/support-backlog.json`. Counted on every open
conversation of any age plus everything touched in the last 26 hours, not on the weekly cohort.

| Field | Meaning | 2026-11-11 23:50Z |
|---|---|---|
| `open` | open conversations | 9,080 |
| `waiting_on_us` | open, the customer spoke last, more than 24h ago (robots excluded) | 1,594 |
| `waiting_on_us_by_wait` | the same, by how long | under 2d 32, 2 to 7d 19, 7 to 30d 18, 30 to 90d 134, over 90d 1,391 |
| `oldest_waiting_on_us_h` | the longest wait, in hours | 30,794 |
| `waiting_on_customer` | open, we spoke last | 7,345 |
| `promised_a_person_24h` | conversations where she said a person is coming, last 24h | 269 |
| `handed_to_human_24h` | conversations assigned to a person, last 24h | 63 |
| `human_replied_24h` | conversations a person replied in, last 24h | 0 |
| `commitments_open` | promises not yet closed by a sent message | 3,704 |
| `commitments_overdue` | open promises past their due time with nothing sent | 3,494 |
| `promises_kept_24h` | times we came back inside the due time, last 24h | 49 |
| `promises_broken_24h` | due times that passed with nothing sent, last 24h | 380 |
| `messages_queued` | due cycles whose status line is sendable and waiting for the driver | 0 |
| `messages_held` | due cycles held by a switch, with the count per reason in `messages_held_by_reason` | all of them today |
| `written_at` | when the tick that wrote it ran | |

Rules of the file:

- A tick that could not read Intercom does not rewrite it. `written_at` going stale is the
  signal.
- A number that was not measured is `null`, never 0.
- A read with even one conversation whose detail could not be fetched is not a whole-inbox read:
  `scope.whole_inbox` is false and every inbox-wide number is `null`.
- Counts only.

Two things a reader of the file should know:

- `waiting_on_us` will not reach 0 soon. 1,391 of the 1,594 have waited over 90 days; 770 of
  them opened in April 2026. A check that fires on `waiting_on_us > 0` or
  `oldest_waiting_on_us_h > 24` fires forever. Watch `waiting_on_us_by_wait.under_2d` and
  `2d_to_7d` for what is going wrong now.
- The tick also pages when `commitments_overdue` or `waiting_on_us` rises on the reading from a
  day before.

## Running it

Installed by `scripts/install-aux-units.sh` as `caroline-monitor.service` and
`caroline-monitor.timer` (every 2 hours). **It is not running until this change is deployed.**

- State: `/var/lib/hydra/caroline-monitor/monitor.sqlite`. It holds, per conversation, an id,
  two timestamps, whether it is open, a shape, and a list of (time, one-letter code). No message
  text. Ledger rows also hold Intercom's contact id, so a status line can find the thread.
- The first run reads every open conversation (about 9,400, about 12 minutes). Later runs read
  only what changed.
- A failing run pages through the unit failure pager as well, so a monitor whose own Slack post
  is broken is still heard. Exit codes for `tick`: **0** measured, or blind with the health line
  and the page it owed delivered; **1** a page or the health line could not be delivered;
  **2** a register that will not load (not a transient read failure). Only exit 0 is
  `SuccessExitStatus`, so a page the monitor already delivered never triggers `OnFailure` a
  second time.
- Page target: `#clio_devops`, mentioning Aaron. Override with `CAROLINE_MONITOR_SLACK_CHANNEL`
  and `CAROLINE_MONITOR_MENTION_IDS`.

Prove it can page, after the first run:

```
ssh root@node-8 'set -a; . /etc/openclaw/shared.env; . /etc/openclaw/edge.env; set +a;
  python3 /opt/hydra/scripts/caroline-monitor.py drill'
```

That posts one message marked DRILL down the real path and records nothing.

Stop it: `systemctl disable --now caroline-monitor.timer`. Nothing else depends on it except the
freshness of `support-backlog.json`. Remove it for good by reverting the commit and running the
installer.

Change a threshold: edit `monitor.page` in `policies/caroline-shapes.json`. The two ceilings
(`headline_ceiling_per_week`, `date_promise_max_per_week`) are pinned to the recorded baseline
and the checker only lets them come down.

## Known limits

- One AI rater, no second rater. Small shapes have 8 labels or fewer.
- Seven shapes are right less than half the time. Their counts are indicative only.
- The output guard leaves a tag, not the rule that fired, so guard hits cannot be split into the
  four exemptions.
- An assignment Intercom shows only as the final assignee, with no assignment event, is dated
  at the conversation's last update. That can make a hand-off look uncovered for longer than it
  was, never shorter.
- Kept promises are undercounted on purpose (see the ledger rules).
- The baseline is one reading. A campaign sent on the evening of 9 Nov added 145 conversations
  to the newest week; the same reading taken six hours earlier gave 964 of 1,280.

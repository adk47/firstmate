# Caroline coach: where a customer or Caroline got stuck

One job on node-8 reads Intercom every 30 minutes and counts **struggle signals** in two sets of
conversations:

1. every conversation touched in the last 30 minutes, whatever its age;
2. every open conversation where the customer wrote last and has waited 1 to 7 days, up to 300 a
   tick, longest wait first. Past 300 the reading says `PARTIAL` and how many it did not read.

It also counts, without reading them, the conversations where the customer has waited longer.

It reads Intercom (search and GET only) and the Caroline monitor's facts file. It sends nothing to
any customer, changes nothing in Intercom and posts nothing to Slack.

Code: `scripts/caroline_coach.py`. Tests: `tests/test_caroline_coach.py`,
`scripts/tests/install-aux-units-caroline-coach.bats`.

## Why there are two readers

`scripts/caroline-monitor.py` (`docs/support/caroline-monitor.md`) answers "what did Caroline do
with each conversation", every 2 hours, from events. It stays the one place that says what a
reply, a person, a promise of a person and the shape of an ask are.

The coach asks a different question, on a short interval and from the words: in what just
happened, where did somebody get stuck? It imports the monitor's rules (`rules.read_events`,
`rules.classify`, `backlog.waiting_since`) and its Intercom reads (`collect`). It does not
restate any of them. A test holds its walk over a thread's messages to the monitor's own.

A signal is a reason to open a thread, not a verdict about it. A count per signal is what turns
into one fix per pattern.

## The signals

| Signal | What the thread shows |
|---|---|
| `repeat_ask` | The customer sent the same ask again after we had answered it (word overlap 0.6 or more, both messages 5 words or more, at least one reply of ours between them). |
| `frustration` | The customer's words say they are stuck or angry ("still waiting", "third time", "nobody is replying", and similar). |
| `asks_human` | The customer asked for a person (the monitor's own rule). |
| `caroline_loop` | Caroline sent the same reply twice in one thread (word overlap 0.9 or more). |
| `caroline_cannot` | Caroline said she cannot do, see or tell something. |
| `promise_unbacked` | Caroline said a person is coming, no person was assigned at or after it, and no person holds the thread now. A person who held it earlier and gave it back does not count. |
| `guard_fallback` | The output guard replaced her reply with the fallback line. |
| `customer_unanswered` | The customer wrote last and has had no answer for 15 minutes or more. |

For `caroline_cannot` the row also says **what** she could not do, from the sentence that says it:
`when` (a date, a response time, making it faster), `proof_enough` (whether a document or
screenshot is enough, or reached the request), `status` (what state a claim, review or request
is in), `mail_bounce` (a delivery notice or an auto-reply), `other`.

For a conversation touched in the window, a signal counts only when the message that shows it is
inside the window. For a conversation in the waiting set, the whole thread is read. A conversation
in both sets is fetched once and read both ways.

The waiting set comes from the monitor's facts, which are up to two hours old. A conversation they
list as waiting that the live read shows answered since is counted as `answered_since` and is in
no signal count.

## What it does not measure

Two things the lane asked for cannot be read from a conversation, and the reading names them
under `not_measured` so their absence is not read as zero:

- `tool_error`: a failed tool call is in the gateway's log, not in the thread.
- `account_mismatch`: whether an answer matches the customer's account needs the account read.

The wording rules are regular expressions and have **no hand labels yet**. Nobody has measured
how often a signal is wrong. Two threads were read in full against their signals and the
sentences Caroline wrote were listed across 68 threads; that is all. `other` is the largest
`caroline_cannot` kind in the first reading, which says the kinds are still coarse.

Bounces and auto-replies (the monitor's `robot_mail` shape) are counted apart in the waiting set
and are not read: a delivery notice is not a customer waiting.

## The first reading

2026-11-15 02:43Z, run from this branch against node-8 before the job was deployed:

- 3 conversations touched in 30 minutes, 3 read, 0 read errors; all 3 carried a signal.
- 1,518 open conversations where the customer wrote last more than 24 hours ago, plus 27 robot
  mail. That is the monitor's own `waiting_on_us` (1,518) from the same facts, 67 minutes old.
  1,355 of them have waited more than 90 days.
- 43 of them have waited 1 to 7 days. All 43 were read. Signals, by conversation:

| Signal | Conversations (of 43) |
|---|---|
| `promise_unbacked` | 24 |
| `caroline_cannot` | 21 |
| `frustration` | 12 |
| `repeat_ask` | 11 |
| `caroline_loop` | 10 |
| `guard_fallback` | 10 |
| `asks_human` | 2 |

What she said she could not do, in those 21 (a conversation can carry several kinds): `status`
12, `other` 12, `when` 10, `proof_enough` 5.

The reading was repeated at 03:39Z after review changed the `promise_unbacked` rule to look at
who holds the thread now: 45 waiting 1 to 7 days, all 45 read, `promise_unbacked` 25. No thread
in that set is held by a person, so the rule change moved no count there.

## Reading it

On node-8:

```bash
cat /var/lib/hydra/caroline-coach/latest.json | python3 /opt/hydra/scripts/caroline_coach.py line
python3 /opt/hydra/scripts/caroline_coach.py tick --minutes 120        # a one-off reading, kept nowhere
python3 /opt/hydra/scripts/caroline_coach.py show <conversation id>    # one thread, to read
```

`latest.json` and `ticks/<unix time>.json` carry conversation ids, the ask's shape and signal
names. They never carry message text. `show` prints a thread to the terminal and stores nothing.
Readings older than 14 days are removed.

The one-line status:

```
read 3 of 3 conversations touched in 30 min (0 read errors); 3 with a struggle signal: caroline_cannot 1, ...;
customer last over 24h: 1518 plus 27 robot mail (monitor's reading, 67 min old), 43 of them under 7 days read: ...
```

- `SHORT READ` means Intercom listed more conversations than the search returned; the counts are
  a floor.
- `NOT MEASURED: <why>` means the reading could not run. The file then holds no counts at all, so
  an older tick's numbers are never the newest thing on disk. When Intercom could not be read the
  job exits 2. When the reason starts `reader fault:` the code itself failed, or met a record it
  did not expect: the job exits 1 and the unit pager fires.
- `PARTIAL: N more under 7 days not read` means the waiting set was larger than the limit of 300
  a tick. The signal counts then cover the 300 longest waits only.
- `aging over 24h: NOT MEASURED` means the monitor's facts file could not be read; the window
  part of the reading still stands.

## The job

`caroline-coach.timer`, every 30 minutes, installed by `scripts/install-aux-units.sh`. The window
the script reads (30 minutes, its default) is the timer's interval, and a bats case holds the two
together.

- Exit 0 and exit 2 are both a success for the unit. Exit 2 means Intercom could not be read,
  and that reading has already been written as NOT MEASURED. Any other exit is a fault in the
  reader and reaches the unit pager (`AUX_ONFAILURE_UNITS`, one page per 24 hours).
- Nothing pages when Intercom stays unreadable and the reading stays NOT MEASURED. Whoever reads
  `latest.json` sees it; nobody is told. That is a known gap, accepted because the reading is input for a fix and not an alarm.
- Each tick makes one search and one GET per conversation read: about 50 today, and at most the
  touched conversations plus 300.

Undo: `systemctl disable --now caroline-coach.timer` on node-8, and revert the PR that added the
block to `scripts/install-aux-units.sh`. The state directory `/var/lib/hydra/caroline-coach` can
be deleted; nothing else reads it.

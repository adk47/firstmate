# Unanswered-reply watchdog — a customer waiting on a person gets paged, paid first

`scripts/intercom-unanswered-reply-watchdog.py` reads every open or snoozed Intercom
conversation once an hour and pages `#cs_priority` (mentioning Jan) about the ones where a
customer has waited more than 24 h for a person. It is deterministic (no model), and it is
read-only on Intercom and on the replica: it never replies, tags, assigns, snoozes or closes.

```
scripts/intercom-unanswered-reply-watchdog.py        the check (docstring = the rules)
tests/test_intercom_unanswered_reply_watchdog.py     its behaviour, each case a way a customer goes unanswered
scripts/install-aux-units.sh                         intercom-unanswered-reply-watchdog.{service,timer}
scripts/tests/install-aux-units-unanswered-reply.bats   the unit is scheduled, and its failures page
/var/lib/intercom-unanswered-reply-watchdog/         state.json (verdict cache, page record) + latest.json (PII-free count)
```

## Why it exists

Captain, 2026-11-11: "can you assure these are not slipping through the cracks". The answer
was no. Conversation 215476618428402: a customer on two paid subscriptions answered
Caroline's question and asked for the status of his two page claims. Caroline replied twice
that she was "pulling in a teammate". No person had written in that thread for 13 days, and
nothing noticed, for two reasons:

- the checks that existed **count or report**; none of them pages (`intercom-backlog/count.py`
  writes a number to a file, `cs-needs-human-digest.py` and `cs-sla-report.py` are a daily and
  a weekly post, `reply_due_scan.py` builds an audience for one message family);
- they ask "did the customer write last?". In that thread the last message was Caroline's.
  A bot saying a teammate will follow up makes a thread look answered to every one of them.

### Not the same job as `caroline-monitor`

`scripts/caroline_monitor/` (merged 2026-11-11, doc `docs/support/caroline-monitor.md`) reads the
same conversations and pages `#clio_devops`, but on a different question: it compares WEEKLY
aggregates (hand-offs with nobody assigned, hand-off rate) against the recorded baseline and pages
when a number regresses. It answers "is the process getting worse?". It never names a thread, so a
customer can sit unanswered in it indefinitely and no page fires for them.

This watchdog never compares a week: it decides, per open thread, whether that thread is currently
owed an answer by a person, and names it with its wait and a deeplink. It answers "who is waiting
right now?". Two jobs, so two pages — this one carries the count so neither number can be inferred
from a chart somebody has to go read.

## The class

Decided by reading the thread, never from `statistics.last_admin_reply_at` alone.

| class | what it is | listed in the page |
|---|---|---|
| `customer_last` | the customer's latest real message has no reply after it | yes |
| `handoff_chased` | Caroline said a person would follow up, no person has replied since, the customer wrote again (more than a thank-you), and the thread still ends on such a promise | yes — for a free contact, ahead of `customer_last`; paid or unverified, every 72 h |
| `promise_open` | any other hand-off promise no person has kept | no — counted in every page |
| `not_owed` | the final customer message is a thank-you or noise | no — counted in `latest.json` |

Rules that decide the edges:

- **Only a human reply keeps a hand-off promise.** A human is any admin except Caroline. Her
  own later replies, internal notes, and other bots never end a promise and never restart its
  clock: the wait runs from the **first** promise nobody kept.
- Robot mail (out-of-office, bounces) is not a customer message. An attachment is a message on
  both sides: a file with no words is a customer message, and a human reply part carrying only
  an attachment answers the thread.
- Hand-off wording is `PROMISE_RE` in the script. It deliberately does not match a bare
  "within N days", which is how Caroline describes a normal turnaround.
- A conversation we opened and nobody answered owes nothing.

## Paid and free

The split uses the one house list, `/var/lib/credit-trust/paying-users.json`, through
`credit_review.decide.paying_users()`: an account is paying when it has an active or trial
user or workspace subscription, or claims an active roster seat (demo workspaces excluded).
A conversation is paid when a paying account matches it, tried in this order:

1. `contact` — a contact's Intercom `external_id` is the account's professional id or Auth0 id;
2. `sender_email` — the address that opened the conversation is the account's email;
3. `mentioned_email` — an address the customer typed in the thread is the account's email.

The third exists because people write from a different address than the one they paid with;
the thread above did. It only raises a page's priority. It is not identity and nothing may
write on it. Staff-domain addresses (`STAFF_EMAIL_DOMAINS`) are never a paid key. Emails are
held as sha256 only.

If the paying list is missing, malformed or older than 3 h, every thread is **unverified**,
never free: it pages like paid, the page says the split is incomplete, and the tick still
exits 0. A degraded split is a warning, not a failed unit: the tick measured and paged, and a
oneshot that exits non-zero freezes `lastSuccessfulTime`, which would make "the house list was
stale" indistinguishable from "the check is dead". Because the exit code no longer carries it,
the warning rides the count page: a degraded tick posts it at most once per `COUNT_EVERY_H`
(24 h), so a degrade inside that window is carried by the next count page rather than posting
immediately, and `latest.json` records it in `paid_split`.
The same holds when the list itself is usable but some paying accounts could not be mapped to
an Intercom identity this tick: a thread that did not match is **unverified**, never free,
and the page states how many accounts went unmapped. An account's identity keys are re-read
at least once a day (`IDMAP_TTL_S`), so a changed email, Auth0 id or professional id is
picked up instead of leaving that customer labelled free forever. A stale account whose
refresh fails is unmapped for that tick (unverified), never classified on keys it may no
longer own.

## N = 24 hours
Caroline answers in about a minute, so a thread still in the class after an hour is one she
could not answer; what it waits for is a person. 24 h gives every timezone one working day,
and it is the paid SLA the credit decider already uses (`decide.PAID_SLA`). Longer, and a
paying customer waits days before anyone is told. Shorter, and an overnight thread pages
before anyone could have read it.

Other clocks: a paid thread is listed again every 72 h (`REPAGE_H`) while the same episode is
unanswered; a free `customer_last` or `handoff_chased` thread is listed once and then every
7 days, a broken promise ahead of silence; at
most 25 lines per message, the rest on the next tick; anything waiting more than 30 days is
the old backlog, always counted and never listed.

## The page

One Slack message per tick, only when something is due. Paid first, a thread not yet paged
ahead of a repeat, oldest wait first; each line has the wait, the class, how paid was
decided, the subject and a link. Every message ends with the whole class count, paid, free
and unverified. When nothing is listable but any thread is still owed, free included, the
count alone is posted once a day (`COUNT_EVERY_H`), so the number is in front of a person
daily while it is not zero; a degraded paying split rides that same count page (see
"Paid and free").

A record of a page is written only after Slack confirms the post. A failed post records
nothing and everything retries on the next tick.

## Reading order and read budgets

A tick reads at most `MAX_READS` conversations in the open pass and stops at `READ_BUDGET_S`.
Both caps are applied **longest wait first**, on the wait the page itself reports: a thread
with a cached verdict is ordered by its owed-since `s` (the first unkept promise for
`handoff_chased` / `promise_open`, the customer's message for `customer_last`), and only a
thread with no cached verdict yet falls back to `last_contact_reply_at`, because its `s` is
unknown before the read.
A missing value sorts oldest. The threads a cap drops must be the freshest ones, because the
ones that have been waiting longest are the entire reason this check exists. Sorting
newest-first silently starved them on any tick where a cap or the budget bit.

The closed-without-answer pass is a second pass with its own caps: at most
`MAX_CLOSED_READS` conversations and its own budget (`CLOSED_BUDGET_S`) rather than whatever
the open pass left of `READ_BUDGET_S`. Sharing one deadline meant a busy open pass could
leave the closed pass zero seconds, so a thread that left the open set while still owed was
never re-read and sat in `unresolved_left` indefinitely. This pass is ordered the same way,
by the cached owed-since `s`, so a bulk close cannot fill its cap with the freshest
departures and starve a thread that has been waiting longest.

## Closed is not answered

A thread that was owed last tick and is no longer open is re-read. If it is still
unanswered, the same page reports it once as "closed without an answer", and it stays in
the published total (and `latest.json`'s `closed_unanswered`) until it is answered; no
retention window drops it while the question is still owed. A thread that could not be re-read is neither reported nor
forgotten: it keeps its cached owed verdict, stays in the published total and in `latest.json`'s
`unresolved_left`, and the tick is `"complete": false` until the re-read succeeds, so a failed
read can never publish a zero (or a smaller count) that no answer produced. A 404 on the detail
read is unreadability, not proof of an answer: the cached verdict is kept and the thread stays
counted, in both the open-search and closed paths. **Closing a conversation is not a way to make this count fall**: 317 were closed
that way on 2026-10-21 and 229 had to be reopened.

## What was measured on 2026-11-11

`--dry-run` on node-8, 20:23Z, complete read (0 unreadable), 9,050 open or snoozed
conversations, paying list 17 minutes old with 14,723 accounts:

| | customer wrote last | asked again after a hand-off | told a teammate would follow up | total |
|---|---:|---:|---:|---:|
| **paid** | 274 | 243 | 1,488 | **2,005** |
| free | 368 | 348 | 1,824 | 2,540 |
| paid status unverified | 0 | 0 | 0 | 0 |

4,545 threads waiting 24 h or more with no answer from a person. 1,231 of the paid ones
started waiting in the last 30 days; the oldest paid wait is 223 days. 243 lines were due to
be listed on the first tick. 120 more ended on a thank-you or noise and are not owed. Paid
was decided by contact id for 1,459 threads, sender email for 515 and a typed email for 31.

Reading the thread matters. In a diagnostic read at 20:07Z the same evening, `statistics`
alone called 1,705 open threads customer-last at 24 h or more; reading them left 607. Of the
rest, 781 ended on a bot message the statistics do not record as an admin reply (735 of them
from the legacy Operator bot), 169 were hand-off promises and 150 ended on a thank-you.

## Operating it

```
python3 scripts/intercom-unanswered-reply-watchdog.py --dry-run     # counts on stdout, the exact message on stderr; writes nothing
python3 scripts/intercom-unanswered-reply-watchdog.py --dry-run --at 2026-11-11T20:00:00Z
systemctl list-timers intercom-unanswered-reply-watchdog.timer
journalctl -u intercom-unanswered-reply-watchdog.service -n 50
cat /var/lib/intercom-unanswered-reply-watchdog/latest.json
```

- The first tick reads every open thread (about ten minutes); later ticks re-read only
  threads whose `updated_at` changed.
- Exit 0 clean; 1 no token, bad `--at` or a state file it does not recognise (left
  untouched); 2 the Intercom search failed, a conversation stayed unreadable, the Slack post
  failed, or the state could not be written. A degraded paying split is **not** exit 2: it is
  warned on the page and in `latest.json`'s `paid_split`. The service is in
  `AUX_ONFAILURE_UNITS`, so a non-zero tick pages `#clio_devops`.
- "Could not read" is its own state: an unreadable thread (a 404 included) keeps its previous verdict, is
  counted in `unread` (or `unresolved_left` once it has left the open set), stays in the
  published total, and `latest.json` says `"complete": false`.
- The unit sets `HOME=/root` because the paid lookup reaches the replica through `kubectl`,
  which needs the kubeconfig. Without it the split would read unverified on every tick.
- Environment overrides: `UNANSWERED_REPLY_CHANNEL`, `UNANSWERED_REPLY_MENTION_IDS`,
  `UNANSWERED_REPLY_STATE_DIR`, `UNANSWERED_REPLY_PAYING_FILE`, `UNANSWERED_REPLY_TRINO`.
- To stop it: `systemctl disable --now intercom-unanswered-reply-watchdog.timer`. It holds
  no customer-facing state, so stopping it changes nothing a customer sees.

## Limits

- A message a script posts under a human's admin id counts as a human reply. Sends that go
  through `intercom-ops-write.sh` post as Caroline and do not.
- `promise_open` is not listed line by line. 1,488 paid lines is a report nobody reads; the
  count is in every page instead. Working that pile down is a staffing decision, not a
  watchdog setting.
- The page tells a person. It does not answer the customer and it does not reassign the
  conversation.
- With the 30-day list window, the first day lists the backlog at 25 lines an hour, so the
  first tick's 243 lines take about ten hours to appear.

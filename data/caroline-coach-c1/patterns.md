# Caroline struggle patterns

One row per shape. A row is a reason to open a thread, never a verdict. Every number here is
measured on node-8 (`ovh-node-8`) by `scripts/caroline_coach.py census`, which reads the monitor's
facts and the live Intercom threads; nothing in this file is estimated.

Reading of record: **2026-11-15T23:40:23Z**, 9,759 open conversations, 0 read errors.

```
none 3,559 (promise_no_person 1,377, customer_last 910, not_english 525, holding_line 414,
            unclassified 189, only_cannot 124, no_message 16, refusal_no_way_forward 4)
answered 2,314 | decided 1,652 | waiting-on-customer 1,341 | closed-stale 893
humans-assigned 0
frustrated this hour 0
```

`none` is the lingering count: a conversation in no terminal state. It is 36% of the open inbox.

## The rows

| # | shape | count | what it is | state |
|---|---|---|---|---|
| 1 | `promise_no_person` | 1,377 | the last line is the hand-off that promises a teammate who does not exist | **stopped, 1,376 stranded** — see below |
| 2 | `customer_last` | 910 | the customer spoke last and nothing answered | open |
| 3 | `not_english` | 525 | the last line is in a language these rules cannot read | named gap, not a zero |
| 4 | `holding_line` | 414 | the drain's "we did not reply when you sent it" line, which is not an answer | open |
| 5 | `unclassified` | 189 | varied prose no rule matches | 1.9%, the number to watch |
| 6 | `only_cannot` | 124 | a "cannot" with no next step behind it | open |
| 7 | `refusal_no_way_forward` | 4 | a refusal that names nothing to do next | open |

## 1. The hand-off promise: stopped, and 1,376 conversations left behind it

The line is `"I'm pulling in a teammate to take this from here."` No teammate exists, so no job
ever answers those threads. By the day of the thread's last message:

```
2026-10-31   68      2026-11-05   71      2026-11-10  162
2026-11-01   69      2026-11-06  173      2026-11-11  147
2026-11-02   71      2026-11-07   62      2026-11-12   63
2026-11-03   54      2026-11-08   58      2026-11-13    4
2026-11-04   75      2026-11-09  179      2026-11-14    3
                                          2026-11-15    1
```

**The promise stopped on 2026-11-13** (4, then 3, then 1 a day, against 60–180 a day before). The
doctrine fix worked: Caroline no longer says it.

**The 1,376 conversations it already reached are still stranded.** They are 1–30 days old, we spoke
last, and the customer is waiting on a person who is not coming. No sender reaches them:

- `scripts/intercom-backlog/drain.py` selects **customer-last** threads only, so a thread where we
  spoke last is not in its audience at all.
- its `stale-close` line covers "customer silent over 90 days and we wrote last", and these are
  1–30 days old.
- `scripts/request_comms/` is the sender that would carry a follow-up, and it ships `enabled: false`.

So the largest single bucket in the lingering count is a promise we can no longer keep and cannot
yet correct. Turning a sender on is a captain decision on the exact copy, not a merge.

## What is not a pattern

`frustrated this hour` reads 0 on every tick so far. That is a measurement of the last hour's
customer messages in open threads, not a claim that nobody is frustrated: the window is one hour
and the regex is narrow. It is reported as measured, never as a zero that means "fine".

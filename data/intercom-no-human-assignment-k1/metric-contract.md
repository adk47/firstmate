# Metric contract: "assigned to a person" must read zero

For `caroline-monitor-and-fixloop-k2`, which owns the monitor and the page. This lane
(`intercom-no-human-assignment-k1`) changes the rules and does not build a second monitor: the only
thing shipped here is a one-shot read (`scripts/intercom-queue-reassign.py verify`) with the same
definitions, so the two can be compared.

Captain, 2026-11-11: "Jan is saying 50-100 assignments are happening to him a day can you cut this
to zero and have Caroline handle all of them."

## Two numbers, because one of them cannot see half the problem

### 1. `assigned_to_person` (events per UTC day) — pages above 0

Count conversation parts where all of these hold:

- `part_type` is one of `assignment`, `bulk_reassignment`, `message_assignment`,
  `default_assignment`
- `assigned_to.type` is `admin` and `assigned_to.id` is not Caroline (`5763097`)
- the part's `author.id` is not the same admin as `assigned_to.id`

The last line matters. A person assigning a conversation to themself is the explicit resume path
and is the one way a human is meant to take a thread. Report it as `self_assigned`, do not page on
it.

Split the paging count by author so the page names the rule:

| author | meaning |
|---|---|
| `5763097` | the plugin, or a script posting as Caroline. After this PR is live this must be 0: the plugin no longer has a code path that assigns to an admin other than itself. |
| `4359478` (Operator) | an Intercom-side workflow or assignment rule. Not changeable from the repo; the page should say "Intercom UI rule". |
| any other admin | a person assigned a thread to another person. |

Baseline, measured from the Intercom API on 2026-11-11 (every conversation updated in 15 days,
3,601 read, 0 unreadable). Assignments to admin `5465657` per UTC day:

| day | 10-27 | 10-28 | 10-29 | 10-30 | 10-31 | 11-01 | 11-02 | 11-03 | 11-04 | 11-05 | 11-06 | 11-07 | 11-08 | 11-09 | 11-10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| events | 5 | 3 | 10 | 5 | 3 | 3 | 51 | 59 | 44 | 44 | 54 | 29 | 31 | 65 | 55 |

Mean 48 a day from 11-02 to 11-10. 478 of the 485 were authored by `5763097`, 6 by the person
himself, 1 by Operator. Assignments to any other person in the window: 0.

### 2. `open_on_person` (conversations, point in time) — pages when it rises

`POST /conversations/search` with `admin_assignee_id = <admin>` and `state = open`, for every admin
that is not Caroline and not Operator.

This is the number that catches what the first one cannot. A reply posted as Caroline into a
closed conversation re-opens it on whoever it was assigned to when it closed, and Intercom writes
an `open` part, not an assignment part. On 2026-11-11 between 17:33Z and 18:25Z a notification
campaign did that to 312 conversations: the person's open queue went from 581 to 913.
Each of the 312 carries an `open` part authored by `5763097` in that window; in a sample of 60 of
the newly open threads, 3 had an assignment part from that day and the rest had been assigned
months earlier.

Suggested rule: page when `open_on_person` for any admin is higher than at the previous reading
and the increase is not explained by that admin's own `self_assigned` events.

After the reassignment in this lane the expected value for `5465657` is the count of threads left
in place for a named reason (see `report.md`, Part 2).

## Unmeasured is not zero

If a conversation in the window cannot be read, the count is a floor. `verify` prints
`UNMEASURED` and exits 1 in that case; the monitor should treat it the same way and not report a
clean day.

## The fields are already in the monitor's collector

`scripts/caroline_monitor/collect.py` keeps, per part, the type, the author type and id, and the
assignment target, plus `admin_assignee_id` on the thread. No new Intercom read is needed for
number 1. Number 2 is one search call per admin.

## Related numbers this lane expects to move

- `handoff_no_assignment` (the monitor's headline): this lane does not lower it by itself. The
  output guard no longer assigns anyone, and its fallback line no longer promises a person, so
  guard-blocked replies leave both the "promised a person" and the "assigned" columns. The
  hand-off line Caroline sends by doctrine on credit, claim and merge threads is
  `caroline-read-state-tools-r1`'s to change.
- Safety ledger rows (`/var/lib/hydra/injection-watch/ledger.jsonl`, kind `output_guard`): the
  `assignment` field is now `ai_queue`. Older rows carry `team_inbox`, `already_assigned`,
  `FAILED`. A reader that counted `team_inbox` as "handed to a person" should count `ai_queue` as
  "stayed with Caroline".
- Journal lines for the fix loop: `[intercom:handler] reclaim conv=<id> for the AI queue: <reason>`
  (a stale human assignment taken back) and
  `[intercom:assignment] escalated conv=<id> → team:<id> kind=<kind> reason=<reason>` (the only
  way a conversation leaves Caroline).

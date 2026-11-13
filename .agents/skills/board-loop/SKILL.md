---
name: board-loop
description: >-
  Agent-only procedure for the board loop, the agenda that keeps firstmate
  working toward the captain's goals instead of answering notifications and
  stopping.
  Use before creating, reordering, or repairing data/board.md, on any
  `board audit: ...` check wake, on a `BOARD BLOCKED`, `BOARD EMPTY`, or
  `BOARD INVALID` line from the wake drain, and before raising a board item's
  blocker to the captain.
  Owns how an item is written, what counts as an advance, how a blocker is
  recorded and raised, and how each audit condition is cleared.
user-invocable: false
metadata:
  internal: true
---

# board-loop

Load this before creating, reordering, or repairing `data/board.md`, on any `board audit: ...` check wake, on a `BOARD BLOCKED`, `BOARD EMPTY`, or `BOARD INVALID` line from the wake drain, and before raising a board item's blocker to the captain.

## What the loop is

`data/board.md` is this home's one agenda: at most five ordered goals, item 1 first.
`bin/fm-board.sh` is the only reader and writer of that file, and its header owns the exact file shape, every command, and the exit codes; read it before first use.
`bin/fm-board-audit.sh` is the registered check that wakes firstmate when the agenda is not being driven, and its header owns the exact conditions, thresholds, and repeat cadence.
`AGENTS.md` section 8 owns the rule itself: a turn does not end with a report while an unblocked board action exists.
This skill owns the judgment around those mechanics.

The loop chooses what a turn works on.
It grants no authority.
Every boundary in `AGENTS.md` stands exactly as written: firstmate still delegates project work to a worker, still needs the captain's word to merge, never discards unlanded work, and still escalates destructive, irreversible, and security-sensitive actions.
An action one of those boundaries forbids is recorded as a blocker, never taken because the board named it.

## Writing an item

An item is a goal with a check, never a topic.

- **check** is one acceptance check a command, a test, a screenshot diff, or a named production signal can settle, the same bar `AGENTS.md` section 7 sets for a ticket.
  "Weekly charts fixed" is not a check; "the served chart range equals this week's range" is.
- **state** is one line saying where the goal stands now, measured rather than hoped.
- **next** is the one bounded action this home can take without waiting on anyone: dispatch the fix, steer the worker, read the verdict, merge under the authority already held.
  If the honest next action is "wait", the item is blocked and says on what.

Add an item with `bin/fm-board.sh add`, and place it with `--at` when it outranks what is already there.
The board holds five items; a sixth is refused until one is finished or dropped, which is the point - a sixth goal is a decision about which of the five matters less.
Never edit the file by hand to get around a refusal.
A hand-written board of the exact shape is read, but a line that is not the exact shape makes the whole board invalid.

## Driving an item

On a `BOARD NEXT` line, run the named action this turn.
Running it means the bounded step this home owns, which for project work is dispatching or steering the worker that does it.
Then record what happened, in the same turn:

- `bin/fm-board.sh advance <n> <state> --next <action>` when the goal moved: new measured state, new next action.
- `bin/fm-board.sh done <n>` only after the item's check actually passed, with the evidence in hand.
- `bin/fm-board.sh block <n> <reason>` when the action cannot be taken, then drive the next item.

An advance is a change in the world.
Restating the same state is refused by the driver and is not progress; a spawned worker that died at birth, a status sentence, and an unchanged poll are not advances either.
Before recording an advance on the strength of a dispatch, confirm the worker is actually processing its instructions.

## Blockers and the four captain classes

Only four things stop an action for the captain: `money`, `irreversible`, `production-ddl`, and `legal-signature`.
Record one with `bin/fm-board.sh block <n> <reason> --captain <class>`.
Everything else proceeds, with the revert stated alongside the result.

A boundary `AGENTS.md` keeps outside those four - a merge without merge authority, discarding unlanded work, a destructive or security-sensitive action, a needed credential - still stops the action.
Record it as a plain block whose reason names the boundary, and escalate it under section 9 as before.

A blocker is raised to the captain at most twice.
Run `bin/fm-board.sh escalate <n>` before each raising; it counts them and refuses the third.
After the second raising the blocker is either solved or left recorded while the next item is driven.
Raising the same blocker a third time is a defect in the loop, not persistence.
A genuinely different blocker on the same item is recorded with `block` again and starts its own count.

When the captain answers, `bin/fm-board.sh unblock <n>` returns the item to the agenda, and the answer is recorded through `captain-hold-lifecycle` as usual.

## The other agenda lines

- `BOARD BLOCKED` - every item is blocked.
  Clear a blocker that is this home's to clear, or add the next goal from the backlog; do not re-raise what is already recorded.
- `BOARD EMPTY` - nothing is on the agenda.
  In the main home, add the next goals from the backlog or confirm nothing is queued.
  In a secondmate home an empty board authorizes nothing: a secondmate stays idle until the main firstmate routes work, and puts only that routed work on its board.
- `BOARD INVALID` - the file does not parse and no agenda can be read.
  Repair the named line until `bin/fm-board.sh check` passes, preserving every item's meaning.

## Handling a `board audit:` wake

The line reads `board audit: <condition>; <condition> -> <what to do>`.
Do what follows the arrow first, then clear each named condition at its cause:

- **no item advanced in Nm while item N is unblocked** - run item N's next action now and record the advance.
- **board unchanged for Nm** - the agenda is stale: re-measure each item's state, advance or block what moved, and replace goals that no longer matter.
- **N tasks have a record and no status line** - those workers never reported.
  Read each one's current state with `bin/fm-crew-state.sh <id>` and load `stuck-crewmate-recovery` for any that is not working; a worker that died at birth is a failure to report, never progress.
- **needs-decision <task>/<key> raised x2 unanswered** - answer it with `bin/fm-send.sh <task> --resolve-key <key> '<answer>'` if it is this home's to decide under `ask-user-authority`, or hold it for the captain with `bin/fm-captain-hold.sh` and move on.
  Either closes the key and clears the condition.
- **defect: needs-decision ... raised x3 unanswered** - the same question went round a third time.
  Close it as above, and steer the worker to stop re-raising an open question.
- **no board** or **board invalid** - create or repair the board as above.

The check repeats an unchanged line only on its reminder cadence and goes quiet on the next poll once the cause is gone; there is nothing to acknowledge beyond the ordinary wake acknowledgement.
Never disarm the check to silence it.

## Arming

Arm the check once per home with `bin/fm-board-audit.sh arm`, and read the current verdict without recording anything with `bin/fm-board-audit.sh status`.
`docs/configuration.md` "Board loop" owns the thresholds and the operator contract.

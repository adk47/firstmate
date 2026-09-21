---
name: roster
description: >-
  Print one scannable, plain-English roster of every agent firstmate supervises
  and every piece still running without supervision: what each is doing right
  now, the model it runs on, how much context it has used, and an expected
  completion estimate whose basis is stated in the cell. Use when the captain
  invokes /roster or asks what every agent is doing, which model each worker is
  on, whether anything is running without firstmate's supervision, or wants the
  fleet as a matrix.
user-invocable: true
metadata:
  internal: true
---

# roster

Answer "what is every agent doing, on what model, and when will it finish - and
what is running that firstmate is not supervising?" with one command.
`/roster` is a read-only report: it prints and exits, and a normal invocation
never steers a worker, merges a PR, dispatches, cleans up, or answers a decision.

## What it does

1. Run `bin/fm-roster.sh` once at invocation time.
   Its header and `--help` own the exact columns, the estimate basis, the
   environment overrides, and the degradation rules.
   Do not re-derive any of its facts by hand, and do not run a second
   fleet-state reader beside it.
2. Relay its output as the matrix.
3. Lead with what needs the captain, in plain words, before the matrix.
   If nothing needs him, say so in one line first.

The report is already captain-facing, so relay it rather than narrating how it
was produced.
It has two tables and a totals line:

- **Under firstmate supervision** - one row per supervised task: what it is
  doing right now, its project and kind, the model it runs on
  (`harness / model / effort`), the context it has used, how long ago it last
  reported, and its expected completion with the basis stated in the cell.
- **Not under supervision** - the migrated surfaces with no live firstmate task,
  the old cmux-app terminals still resumed on this host, and the Orca terminals
  bound to no task.

## Opening the answer

Open with the one thing the captain can act on now, then the matrix.
Rank what needs him and cap the visible list at five, holding the rest.

- A task waiting on firstmate (a decision, a blocker) belongs first.
- A PR that is open and awaiting merge, with its full `https://...` URL, comes
  next; never a bare number.
- A migrated surface whose heartbeat is stale, or an old terminal that is still
  burning an account, is worth naming.
- Nothing pending: say "nothing needs your action" in one line, then the matrix.

## Plain-English rule

`data/captain.md`'s working-style rules govern the chat summary: plain English
is mandatory and outranks completeness.
Name the real-world consequence before the mechanism, and never use a phrase the
captain did not use.
Translate every internal label before it reaches him - a task id, a status
prefix, a check name, or a column legend is not a sentence.
Say what a task is doing, not which record says so.
Keep the two tables intact under the lead, and put the captain's single next
action at the end.

## Estimates

The estimate column always states its basis, so an estimate is never read as a
promise:

- A standing lane (its title names a lane, watch, or loop, or it is idle on a
  tick) has no end - it shows its next tick.
- A ship task shows its stage: setting up, implementing with an estimate from
  recent completed work, blocked on firstmate, a PR open and awaiting merge, or
  awaiting cleanup after a merge.
- A scout shows whether its report is due or written.
- When there are too few completed tasks to measure, the cell says so and names
  its default rather than inventing a number.

## Limits

The pane columns are best-effort and cheap: a context figure appears only when a
pane read is available in time, and a missing file degrades to `-` in that cell
instead of failing the report.
This keeps the report bounded on a home with multi-megabyte status logs and
well under the captain's waiting patience.
The report describes what is running now; acting on anything it surfaces is a
separate, normal workflow under the usual authority rules.
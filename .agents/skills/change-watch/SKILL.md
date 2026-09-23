---
name: change-watch
description: >-
  Agent-only procedure for the post-merge change watch.
  Use on a `check: change-watch <task-id> <pr-url> <metric> regressed` wake, on a
  `check: change-watch <task-id> <pr-url> interrupted at +Nm` wake, on a
  `procevent when-cw-... <sequence>` completion wake for an armed change watch,
  or when deciding whether a merged change needs a by-effect watch.
  Owns how a regression is read, routed, and closed, and what a clean completion
  still owes.
user-invocable: false
metadata:
  internal: true
---

# change-watch

Load this on a `check: change-watch <task-id> <pr-url> <metric> regressed` wake, on a `check: change-watch <task-id> <pr-url> interrupted at +Nm` wake, on a `procevent when-cw-<hash> <sequence>` completion wake, or when deciding whether a merged change needs a by-effect watch.

## What the watch is

A merge is verified at merge time by content - the new env values or image tag are read on the live pods - which proves the change arrived and says nothing about the service afterwards.
`bin/fm-change-watch.sh` watches the change by effect instead: it samples the affected Deployment's own signals against a pre-deploy baseline at +5m, +15m, +30m, then hourly to +12h.
The affected Deployments are the documents the PR's diff hunks land in, under each document's own `metadata.namespace`; a Deployment declaring none is skipped with its reason, and when a hunk cannot be placed the whole manifest is watched and the registration line says so.
A registration that could not read a manifest says `could not read N manifest(s)`: that is a measurement gap to re-register once the forge answers, not a PR without a service.
`bin/fm-change-watch.sh`'s header is the one owner of the exact commands, metrics, bars, schedule, and test seams; read it before acting.

The watch is armed automatically when a merged PR touches a deployable service, from both `bin/fm-pr-merge.sh` and the watcher's merged-poll landing path.
Registration is additive: a registration failure never turns a successful merge into a reported failure, and a PR that touches no deployable service registers nothing.
Never register a watch by hand for a merge the hooks already covered; check `bin/fm-change-watch.sh status` first.

## Handling a regression wake

`check: change-watch <task-id> <pr-url> <metric> regressed`

1. Read the verdict with `bin/fm-change-watch.sh verdict <watch-id>`, where the watch id is `<task-id>-<pr-number>`; it names the metric, the measured value, the baseline, and the tick.
2. The mechanism already steered the owning task through `bin/fm-send.sh` with the numbers.
   A regression on the earliest samples usually still finds that task alive; a later one may not, and then the wake is the only route to a lane.
   Route to whichever lane owns the affected service rather than assuming the merged task still exists.
3. Treat it as a live incident lead, not a report: the affected Deployment, the metric, and the timing are the evidence, and the next scheduled sample is already running.
   A captain-facing escalation states the service, the metric and its numbers, the time since the merge, and the next decision.
4. The wake is handled when the lane has the numbers and the watch's verdict has been read; acknowledge it through the ordinary wake acknowledgement like any other `check` wake.

## Handling an interruption wake

`check: change-watch <task-id> <pr-url> interrupted at +Nm`

The drive stopped before the end of its schedule (a stale runner group stopped, a host reboot, an action timeout) and the verdict is `change-watch interrupted at +Nm`, never clean.
1. Read `bin/fm-change-watch.sh verdict <watch-id>` and the samples it did take; a regression it had already recorded is the check wake above, not this one.
2. Run the generic acknowledgement for the `procevent` outcome and `bin/fm-procevent-when.sh retire <name>` as `process-event-sources` requires.
3. Re-register with `bin/fm-change-watch.sh register <task-id> <pr-url>`: on an interrupted watch it retires the stopped source itself, re-arms exactly the remaining samples, and prints how many are left.
   A watch with no samples left completes instead, as clean or as completed unmeasured.

## Handling a completion wake

`procevent when-cw-<hash> <sequence>`

The armed watch drives itself through `bin/fm-procevent-when.sh`, so its one terminal outcome is a routine completion, not news.
Load `process-event-sources` for the `classify` and `handled` mechanics; the adapter commands and the acknowledgement contract are owned there.

- `fired` means the drive ran to the end of its schedule.
  Read `bin/fm-change-watch.sh verdict <watch-id>`: `change-watch clean` is the clean +12h completion, `change-watch completed unmeasured` means some target was never read across the whole schedule and the change is unverified by effect, and a `regressed ...` line means the check wake above is the real signal.
  A completed-unmeasured watch is a measurement gap to raise with the owning lane, never a pass.
- `action-failed`, `condition-error`, `never-true`, `rejected`, or `ambiguous` means the watch stopped without completing its schedule.
  Report what it actually says and re-register through the interruption path above when the verdict is `interrupted at +Nm`; a `rejected` watch is usually one whose script bytes changed under it, and an `ambiguous` one needs its verdict read before anything else.
- After handling, run the generic acknowledgement, then `bin/fm-procevent-when.sh retire <name>` before any re-register, as `process-event-sources` requires.

## What a clean completion still owes

A clean +12h watch appends one `note: change-watch clean for <pr-url>` line to the task's status log and records one wiki observation; clean means every target had at least one scored reading across the schedule.
A completed-unmeasured watch appends one `note: change-watch completed unmeasured for <pr-url> (never measured: ...)` line and records no wiki observation.
Neither is captain-facing news, so never surface a completion to the captain on its own.
The watch is read-only against the cluster; it writes only under the home's `state/change-watch/`, a metric it cannot read is `unmeasured` and skipped rather than scored as a pass, and a relative bar whose baseline was never read is recorded but not scored.

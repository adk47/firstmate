# Board loop

Repeatable evidence for `bin/fm-board.sh`, the board driver, and `bin/fm-board-audit.sh`, the registered check that wakes firstmate when the board is not being driven.
Each command's header owns its file shape, conditions, thresholds, and exit codes.
This record owns the proof that the driver refuses what it should, that the check goes dirty on each condition and quiet again when the cause is gone, and the statement of what was not exercised.

- Date: 2026-11-13
- Shell: bash 5.2.21, shellcheck 0.11.0
- Comparison base: `origin/main` at `11145c15`

Every transcript below ran against a throwaway home selected with `FM_HOME`, `FM_DATA_OVERRIDE`, and `FM_STATE_OVERRIDE`.
The clock was moved with `FM_BOARD_NOW`, set to the wall clock at the start of the run plus the offset each `# clock at` line names.
Output lines are verbatim; `[exit N]` marks a non-zero exit.

## The driver names the next action and prints the agenda line

```console
$ # clock at +0s
$ bin/fm-board.sh add "weekly charts" --check "the served chart range equals this week's range" --state "still serving last week" --next "rerun the chart build"
$ # clock at +0s
$ bin/fm-board.sh add "front door" --check "the public hostname answers 200" --state "DNS not changed" --next "apply the DNS change"
$ bin/fm-board.sh list
1	open	-	0	weekly charts	the served chart range equals this week's range	still serving last week	rerun the chart build	-
2	open	-	0	front door	the public hostname answers 200	DNS not changed	apply the DNS change	-
$ bin/fm-board.sh next
1	weekly charts	rerun the chart build	the served chart range equals this week's range
$ bin/fm-board.sh wake-line
BOARD NEXT: item 1 "weekly charts" - next: rerun the chart build | done when: the served chart range equals this week's range | run it this turn unless this wake carries captain-class content
```

## An idle unblocked item raises the alarm, and an advance clears it

The check is silent a minute after the board was written, prints one line once an hour has passed with no advance, stays quiet on the next poll inside the reminder interval, and is clear again after the item advances.
Restating the item's state is refused and does not count.

```console
$ # clock at +60s
$ bin/fm-board-audit.sh check
$ # clock at +3660s
$ bin/fm-board-audit.sh check
board audit: no item advanced in 61m while item 1 is unblocked -> drive item 1 "weekly charts": rerun the chart build
$ # clock at +3960s
$ bin/fm-board-audit.sh check
$ # clock at +4000s
$ bin/fm-board.sh advance 1 "build rerun, range matches this week" --next "confirm the served range in production"
$ # clock at +4000s
$ bin/fm-board.sh advance 1 "build rerun, range matches this week"
fm-board: item 1 is unchanged; a restated item has not advanced
[exit 1]
$ # clock at +4060s
$ bin/fm-board-audit.sh check
$ # clock at +4060s
$ bin/fm-board-audit.sh status
board audit: clear
```

## A blocked board raises no idle alarm, and a blocker is raised twice at most

With both items blocked there is no action to run, so the check is clear well past the idle interval.
The third raising of one recorded blocker is refused.

```console
$ # clock at +4100s
$ bin/fm-board.sh block 1 "waiting on the data vendor"
$ # clock at +4100s
$ bin/fm-board.sh block 2 "DNS change cannot be undone" --captain irreversible
$ bin/fm-board.sh next
fm-board: no unblocked item (2 on the board)
[exit 1]
$ bin/fm-board.sh wake-line
BOARD BLOCKED: all 2 items are blocked (1 waiting on the captain) - clear a blocker that is yours or add the next goal; a recorded blocker is not raised again
$ # clock at +9000s
$ bin/fm-board-audit.sh status
board audit: clear
$ bin/fm-board.sh escalate 2
escalation 1 of 2 for item 2
$ bin/fm-board.sh escalate 2
escalation 2 of 2 for item 2: this is the last one - solve it or leave it blocked and drive the next item
$ bin/fm-board.sh escalate 2
fm-board: item 2 blocker was already raised 2 times; a third raising is a defect - leave it blocked and drive the next item
[exit 5]
```

## A repeated needs-decision key is detected, and an answer clears it

Item 1 is unblocked again, then a worker's status log receives the same `needs-decision [key=dns]` line a second time, a third time, and finally a `resolved [key=dns]` line.

```console
$ # clock at +4200s
$ bin/fm-board.sh unblock 1
$ # clock at +4300s
$ bin/fm-board-audit.sh status
board audit: needs-decision lane-a/dns raised x2 unanswered (answer it or hold it, then move on) -> drive item 1 "weekly charts": confirm the served range in production
$ # clock at +4300s
$ bin/fm-board-audit.sh status
board audit: defect: needs-decision lane-a/dns raised x3 unanswered -> drive item 1 "weekly charts": confirm the served range in production
$ # clock at +4300s
$ bin/fm-board-audit.sh status
board audit: clear
```

## Arming binds a shim, and disarming removes it

```console
$ # clock at +5300s
$ bin/fm-board-audit.sh arm
armed: state/board-audit.check.sh
$ ls <home>/state | grep board
board-audit.check.sh
board-audit.check-trust
$ # clock at +5300s
$ bin/fm-board-audit.sh disarm
disarmed: state/board-audit.check.sh
$ ls <home>/state | grep -c board
0
```

## Tasks that never reported raise the alarm

This transcript ran in a second throwaway home with one board item.
Three task records with no status line are within the allowance, a fourth is not counted while its record is younger than the grace, and it clears once one task writes its first status line.

```console
$ # clock at +0s
$ bin/fm-board.sh add "weekly charts" --check "the served chart range equals this week's range" --state "still serving last week" --next "rerun the chart build"
$ # three task records, no status line; clock at +1000s
$ bin/fm-board-audit.sh status
board audit: clear
$ # a fourth task record; clock at +60s
$ bin/fm-board-audit.sh status
board audit: clear
$ # clock at +1000s
$ bin/fm-board-audit.sh status
board audit: 4 tasks have a record and no status line (lane-a lane-b lane-c lane-d) -> drive item 1 "weekly charts": rerun the chart build
$ # lane-d writes its first status line; clock at +1000s
$ bin/fm-board-audit.sh status
board audit: clear
```

## Automated tests

`bin/fm-test-run.sh tests/fm-board.test.sh tests/fm-board-audit.test.sh` reported `FM_TEST_SUMMARY total=2 failed=0`.
`tests/fm-board.test.sh` covers the driver and the agenda line a real `bin/fm-wake-drain.sh` run prints, including that a home with no board prints none.
`tests/fm-board-audit.test.sh` covers every condition above plus the stale-board condition, the reminder cadence, the secondmate and left-stopped exemptions, a captain hold closing a repeated key, and a missing or invalid board.
Both are plain bash tests on the repository's own `tests/lib.sh` harness; the repository has no bats dependency and this change adds none.

The neighbouring suites that read the same drain output were rerun and stayed green: the `fm-wake-drain-*` suites, the `fm-classify-*` suites, `tests/fm-session-start.test.sh`, and `tests/fm-afk-return.test.sh`.
`bin/fm-test-run.sh --changed --base origin/main` reported `FM_TEST_SUMMARY total=66 failed=0 skipped_gate=2`; the two skipped suites, `tests/fm-pi-primary-types.test.sh` and `tests/fm-calm-pi-extension.test.sh`, skipped on their own tooling gate and exercise nothing this change touches.

## Not exercised

- The check was not armed in a live home, and no live watcher polled it; arming was proven only as far as the bound shim running the check against its own home.
- The stale-board condition appears only in the automated test, because it reads the board file's real modification time rather than the stamped advance.
- The supervision-branch drain was not run; that the agenda line is main-only is shown by the code path, not by a test, because a branch drain needs a claimed-row snapshot this fixture does not build.
- The away-mode daemon and the away-mode return were not run against a home that keeps a board; they receive the agenda line as one extra non-wake output line.
- Whether a running firstmate obeys the rule in `AGENTS.md` section 8 is behavior no script here can prove; the check is the backstop for when it does not.

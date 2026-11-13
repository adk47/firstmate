# Why hydra PRs get stuck: seven causes, measured

Captain, 2026-11-12: "can fable fix our pr issues you keep mentioning. i dont get it why we keep
getting stuck".

Evidence collected 2026-11-13T03:33Z from `Muso-AI/hydra` (`evidence/`, read-only GitHub API).
Every number below is printed by `tools/measure.py table --evidence evidence` or by
`scripts/pr-doctor.py plan --all` (run 2026-11-13T06:37Z, 196 open PRs), unless it says otherwise.
The "after" figures marked live were read from this change's own PR,
https://github.com/Muso-AI/hydra/pull/1935.

## The answer

A PR that is ready to merge waits for two things GitHub does not show you, and neither is a
safety rule.

1. **GitHub grades a required check by the newest workflow run that posted it, not by the newest
   result.** Editing a PR title or body starts a new `PR Validation` run. That run does not test
   anything; its `validate` job only repeats what the head's real suite concluded. It read the head
   once. An edit made in the six minutes the suite needs found nothing to repeat, failed, and
   because it is the newer run its failure outranked the suite's green that arrived minutes later.
   The head was validated and unmergeable until a person found the failed job and re-ran it.
   6 of the last 50 merged PRs, 9.0 hours in total.
2. **The required check is green 6 minutes after a push, and the merge still waits 37 more for
   Bats.** Bats is not a required check, but the merge queue holds on any pending check, so the
   Bats job is the length of every round.

The first is fixed in this change and was watched working on a live edit. The second is shorter:
the slowest Bats shard took 27.9, 31.5, 28.4, 31.4 and 30.6 minutes on this PR's five runs, against a
median of 42.8.
The other five causes are below: one is a real requirement, two
are requirements that a tool can satisfy at open instead of a person afterwards, and two are
stock that nobody clears because nothing says what to do. `scripts/pr-doctor.py` now says it.
Two more, not in the brief, were found when this PR hit them (sections 8 and 9). Neither is
fixed here, and the second runs the unsafe way: after a title or body edit the merge queue can
read a failed job of the suite as a skip.

Branch protection is untouched. Ruleset 26901288 (`require-ci`: `validate` and `pr-title`,
non-strict) is read here and not changed, and nothing in this change needs it changed.

## The seven, classified

(a) real safety requirement, left alone. (b) wiring accident, fixed. (c) a policy a tool can
satisfy instead of a person.

| # | Cause in the brief | Class | What was measured | What changed |
|---|---|---|---|---|
| 1 | Metadata edit poisons a green head | (b) | 14 recorded failures of this kind on the sampled heads; 6 of 50 merged PRs; 2 open PRs BLOCKED by it now | `validate` waits for the running suite, then repeats its result |
| 2 | Guard wants production evidence that cannot exist before deploy | (c) | Not circular: the guard accepts a figure measured by a dry run on production data. #1922 failed 4 times on "After: not measured" and passed on "371 of 371 read back" from a read-only run | `pr-doctor.py preflight` runs the guard's own check on the body before the PR is opened |
| 3 | Wrong base branch | (a) + tool | 14 open PRs target a branch other than `main`; 6 of them target a branch whose own PR has already merged | `pr-doctor.py plan` names it and the one command |
| 4 | Conflicting branches never rebased | (a) | 102 of 192 open PRs | Not fixed. Cause measured, below |
| 5 | `credit-approval-guard` red by design | (a) + (b) | Not by design since #1849 (2026-11-08). 87 open PRs show it red; 65 of those bodies pass the guard today | `pr-doctor.py plan` separates a stale red (re-run) from a real one (the body) |
| 6 | Bats takes 35+ minutes on a 2-CPU pod | (b) | Slow shard: median 42.8 min over 48 runs | 4 shards instead of 2. Slowest shard 27.9 to 31.5 min on this PR's five runs |
| 7 | Some checks cannot be re-run | (b), a missing instruction | Every Actions check here re-runs in place for 30 days; 0 of the runs worth re-running are too old | `pr-doctor.py plan` prints the re-run; no empty commit |

### 1. Metadata poisoning: wiring accident, fixed

The real requirement inside it stays: **a title or body edit must never stand in for a
validation.** That is why the edit run has a `validate` job at all.

The accident was reading once. hydra#1926, head `37d839f38`: push at 01:17:35Z, body edit at
01:19:55Z, the edit run's `validate` failed at 01:20:05Z with the suite 3 min 45 s from done,
the suite's own `validate` went green at 01:23:54Z, and the PR merged at 02:21:10Z, two minutes
after someone re-ran the failed job. Same shape on #1894 (4.54 h), #1892, #1895, #1922, #1906.

The fix is `scripts/ci/validate-mirror.py`, called by the `validate` job only on an edit run:

- a suite that is still running is waited for (up to 25 minutes, which covers the suite's own
  20-minute cap), then its result is repeated;
- it exits 0 **only** when the head's newest real suite succeeded. No suite, a failed suite, a
  cancelled suite, a suite still running at the deadline and a GitHub read that keeps failing
  are all red;
- a head validated before the 2026-11-11 job split has no `validate-code`; its suite is the
  `validate` of a run with no `validate-code` in it. A `validate` from an edit run is never read
  as a suite, so one mirror cannot vouch for another;
- a newer validation that has started but not yet listed its suite job is waited for as well
  (QA's Critical finding on the fourth head, and it was right). A retarget onto `main` or a close
  and reopen starts a new validation of the same head sha, and its run is listed a few seconds
  before its `validate-code` job is. An edit landing in that gap found only the old green suite;
  the mirror would have gone green, and as the newest run's `validate` it would have outranked
  whatever the new validation went on to conclude. The old read-once job had the same gap. The
  mirror now also lists this workflow's runs on the head (`actions: read` on that one job): a run
  newer than the suite, other than its own, that has posted neither a suite nor a skipped
  placeholder is waited for, and an older green is never reported in its place. A cancelled or
  skipped run that posted nothing is ignored, because it changed nothing about the head and
  without the edit GitHub would still grade the suite before it; failing on it would leave the
  head red for good. On the 242 recorded heads (274 runs) the rule changes no verdict: the only
  runs with nothing posted are 18 whole-run skips from before the split and 1 cancelled run.

Not covered, on purpose: a re-run of a suite that already succeeded. A re-run keeps its run id
and reads the same merge commit, so it validates nothing the first attempt did not.

Tests: `scripts/tests/test_validate_mirror.py`, 52 cases, in PR Validation. 32 of 32 hand-made
mutants of the script and its wiring were caught (a running suite fails; a skipped placeholder
counts; a cancelled suite passes; a failed suite passes; an unreadable answer passes; the
deadline passes; a newer run with no suite yet is ignored; the run listing is never read; a
refused listing reads as an empty one; the job loses `actions: read`; and so on).

**Live, on this PR's second head:** pushed 05:50:27Z, the suite's `validate-code` started
05:50:39Z, the body was edited at 05:51:50Z. The edit run's `validate` started 05:52:14Z with the
suite 4 min 19 s from done, which is the moment the old job failed. It printed
`[0s] validate-code of run 43374642339 is in_progress`, waited, printed
`[264s] validate-code of run 43374642339 succeeded` and went green at 05:56:45Z, 12 seconds after
the suite. The head was never unmergeable. One edit, one head.

Meanwhile the old job is still on `main`: two more PRs were poisoned after the evidence was
collected (#1927 and #1934, seen at 06:22Z; #1934 has since been pushed again), so three open PRs
that do not conflict are in that state at 06:37Z.

Cost: on an edit made mid-suite the `validate` job now holds one runner pod while it waits. In
the replay the waits were 45 s to 420 s; live it was 264 s. On a push it is unchanged.

**A second, older form of the same accident** holds 3 open PRs that are otherwise ready (#1855,
#1856, #1863, BLOCKED 5 days): before the split a metadata edit skipped the whole run and posted
no `validate` at all, so GitHub still shows the required check as "expected" under the newer
run. Any title or body edit clears it; `pr-doctor.py plan` says so.

### 2. "Production evidence before deploy": a requirement a tool can meet

The guard (`.github/credit-approval/guard.py`) asks a credit-affecting PR for a
`## Credit approval impact` section with a BEFORE figure, an AFTER figure and the word `prod`.
It does not ask for a figure from a deployed change. A read-only run of the new code against the
same production rows gives a measured AFTER, and saying it is a dry run is the stated limitation.
What it refuses is "After: not measured", which is the honest sentence most lanes wrote.

`scripts/tests/test_pr_doctor.py` holds this against the real guard: the same body fails with
"After: not measured" and passes with a dry-run figure.

Not changed: `guard.py`. It already accepts the dry run, it is inside the credit-approval block
of `CODEOWNERS`, and making it accept "not measured" would be weakening it.

Changed: `scripts/pr-doctor.py preflight --body FILE` runs the guard's own path match and section
check on the branch and the body **before** `gh pr create`, and prints the dry-run instruction.
A body that is right at open is never edited after the push, which also removes the trigger of
cause 1. 6 open PRs fail the guard only on this wording (#1899, #1683, #1661, #1526, #1372, #1319).

### 3. Wrong base: legitimate, but silent

hydra#1981 does not exist (the API answers 404; the newest PR at collect time was #1929). The
cause is real though: 14 open PRs target a lane branch. `PR Validation` runs only for `main`, so
none of them can go green. Stacking on another lane's branch is a legitimate way to work, so this
is not blocked at open. Six are stranded: their base PR has merged (#1683, #1652, #1634, #1538,
#1523, #1461), and one more targets a branch whose PR closed unmerged (#1409).

`pr-doctor.py plan` prints `gh pr edit N --base main`, which starts a full validation by itself.
It is printed, never performed: retargeting someone's stack is the owner's call.

### 4. Conflicts: a real requirement, and the largest number

A head that conflicts with `main` cannot be validated; GitHub starts no `pull_request` run for
it. That is not wiring.

Measured: 102 of 192 open hydra PRs conflicted at collect time. (The brief's 243 of 622 is not
hydra's count; the org had 843 open PRs.) 68 of the 102 had not been touched for more than 7 days
(median 8.6 days), so most of this is work nobody is waiting for, not work that is stuck.

What makes fresh PRs conflict is measured too (`git merge-tree` of each head against `main`, 101
heads): `.github/workflows/pr-validate.yml` is in 27 of them and is the **only** conflicting file
in 8; with `AGENTS.md` it is the only cause in 11. Every lane appends its test to the same step
of that workflow and its paragraph to the same document. This PR does the same.

Not fixed here. The fix is to stop appending to one place (a sorted list of test files that the
step reads), and it touches how CI discovers tests (`test_ci_test_discovery.py` reads the
workflow), so it is its own change with its own review.

### 5. `credit-approval-guard`: real requirement, stale reds

It is not red by design any more. Since #1849 (merged 2026-11-08T05:28Z) a captain-authored PR is
graded on the impact section alone. It is also not a required check: the ruleset requires only
`validate` and `pr-title`.

Of the 87 open PRs whose newest guard run is red, 65 have a body that passes the guard's section
check today, and every one of those 65 reds completed before #1849 merged. Nothing re-runs a
check when its rule changes. 22 really fail: no section 9, no BEFORE figure 7, no AFTER figure 7,
no `prod` 6.

`pr-doctor.py plan` runs the guard's own check on the live body and says which it is. On the
open PRs that are not conflicting and target `main`: 20 with a stale red a re-run clears (37
re-runs, because the guard runs on two events and both are read), 7 whose body needs the edit.

One thing the count hides: the merge queue treats a guard failure as waived (a captain ruling in
`fm-merge-queue.sh`), so a stale guard red does not stop that queue. It stops a person reading the
PR, and it is the red that QA's approve step reads.

### 6. Bats: wiring accident, fixed by more shards

Bats is the same 2-CPU pod running 4 jobs. Its longest file, `credit-verify-outbound.bats` (131
cases, in series), was measured on a workstation with CPUs pinned: 630 s alone on two CPUs,
1,168 s with three other jobs on the same two. So the shard is CPU-bound, and re-ordering files
between two shards could not help (tried and reverted 2026-11-12, `docs/delivery-velocity.md`).
Four shards halve the other work the long file shares its pod with.

Nothing is dropped: same files, same cases, same `--jobs 4`, the count check and the no-silent-skip
gate are unchanged, and `scripts/tests/pr-validate-retarget.bats` pins the four places the shard
count appears to one number (4 of 4 mutants caught).

Measured on this PR (five runs, not a median; the sixth head's, 43395918471, took 11.2, 22.7,
30.6 and 25.2 min; the slowest shards of the two before it,
43382422986 and 43389275267, took 28.4 and 31.4 min): on the first two, shards took 10.3, 22.0, 25.3 and 27.9 min on
run 43371465645 and 9.9, 24.2, 28.4 and 31.5 min on run 43374642339. Both ran 423 of 423 files
and 9,444 cases with 0 failed; the last two-shard run before it (#1926) ran 422 files and 9,437
cases. On the second head everything was green 31.7 min after the push. The shards are uneven
because the split is by file count and one file is the floor.

Cost: a push now takes 4 Bats pods instead of 2 (9 pods at once for the whole run, was 7) from a
pool of 30. More than three simultaneous pushes queue; it was four.

What would remove the floor altogether is splitting that one file, in the lane that owns it.

### 7. "Cannot be re-run": they can

`validate`, `validate-code`, `pr-title`, `credit-approval-guard` and Bats are all GitHub Actions
jobs. `gh run rerun <run> --failed` re-runs them in place for 30 days and keeps the head and its
QA verdict. Five of the six poisoned merged PRs were cleared exactly that way (the sixth by a
later edit). Of the runs `pr-doctor.py` wants re-run today, 0 are older than 30 days.

Two limits, both now printed by the tool rather than discovered:

- a re-run reads the **same merge commit** as the original run. It clears an interrupted run or a
  flake. It does not clear a failure that came from `main`'s state that day: three open PRs
  (#1852, #1868, #1772) failed within 20 seconds on 2026-11-09 at the exec-posture step, the
  day that dated exception ran out, and are still red. `gh pr close N && gh pr reopen N` validates the same head against today's `main`
  with no commit. `--apply` never re-runs a failed suite blind for this reason;
- `qa-review` is a commit status, not a job. It is re-dispatched by `qa-tier-recheck.yml` or
  `qa-autoreview.yml`, not re-run.

**Not shipped: a `workflow_dispatch` trigger on `pr-validate.yml`.** A dispatch is not a
`pull_request` event. The suite reads the PR's base, merge commit and changed files throughout
(24 uses of `github.event.pull_request`; the rebase-staleness gate, the held-cron guard and the
exec-posture check all compare against the PR's base), so a
dispatched run would either skip those gates and still post a green `validate` on the head, which
lets unvalidated code merge, or need a second implementation of each. A re-run and a
close-and-reopen already give the same result without a commit.

### 8. Not in the brief: a cancelled guard run holds the merge queue for good

Found on this PR. `credit-approval-guard` runs on two events, `pull_request_target` (a push or an
edit) and `pull_request_review`, and both share one concurrency group with `cancel-in-progress`.
At 05:51:53Z a review and the body edit landed in the same second and the review's run cancelled
the edit's. `gh pr checks` keeps one check per event, the one that started last, so the cancelled
run stays listed beside the other event's green. The merge queue (`fm-merge-queue.sh`) holds a
row on any guard result that is not a pass or a failure, so it holds on that `cancel` until a
person re-runs it. Nothing reports it: the PR shows `validate` green and a guard that passed.

Class (b), a wiring accident. Open PRs in that state at 06:37Z: 2 (#1921, #1768), plus this one
until it was cleared.

Changed: `pr-doctor.py plan` reads the guard per event the way `gh pr checks` does and names the
cancelled run. `--apply` on this PR re-ran it: `cancel` at 05:51:54Z, `pass` at 06:08:07Z.

Not changed, and the one-line fix that would stop it happening: the guard's concurrency group
should carry the event name, as `pr-title-check.yml` already does
(`credit-approval-guard-<pr>-${{ github.event_name }}`). Each event would then cancel only its own
older runs and every event would still get a verdict, so nothing is weakened. It is not in this
PR because `credit-approval-guard.yaml` is in the credit-approval block of `CODEOWNERS`: the
change needs the captain's approval and its own impact section, and as a `pull_request_target`
workflow it runs from `main`, so it cannot be exercised by the PR that makes it.

### 9. Not in the brief: a title or body edit hides the suite's other jobs from the merge queue

Found on this PR's fifth head, and this one runs the unsafe way. An edit run skips every job of
the suite, and a skipped job still posts a check under its own name. `gh pr checks`, which the
merge queue reads, keeps one row per name: the one that started last. So after an edit the rows
for `Python unit tests (watchdog)`, `Plugin tests (vitest)`, `Shellcheck`, `Deploy pre-flight`
and the node-8 hand-off are the edit run's skips, and the queue takes a skip for green. Whether
the suite's real jobs are still running or have failed is not in what it reads. Bats is spared
by accident: a skipped matrix job keeps its unexpanded name, which matches no shard.

At 08:07Z this PR showed exactly that: `Python unit tests (watchdog)` had failed in the suite
(run 43389275267) and the listing said `skipping`.

Measured over the last 50 merged PRs: 14 had at least one suite job hidden at merge, 84 jobs in
all. None of the 84 was red. Two were still running (#1893, #1903), both on PRs merged by hand
while their Bats shards were running too, so the queue's reading played no part. In that sample
it has let nothing red through. It is one edit and one failing job away from doing so.

It is not a hole in the required check: `validate` is never hidden (the mirror posts a real
verdict under that name), and none of the hidden jobs is required by the ruleset. It is a hole
in the stricter rule the merge queue adds on top of the ruleset.

Changed: `pr-doctor.py plan` reads the jobs of the head's own suite run. It no longer calls a
head clear while one of them is running or ended any way but a pass or a skip, and it names the
job the listing hides. `scripts/tests/test_pr_doctor.py`, 69 cases, in PR Validation; 67 of 67
hand-made mutants of the tool's rules were caught, 17 of them on this one.

Not changed: the reader. `fm-merge-queue.sh` is in the firstmate repo, outside this change. The
fix there is to read the suite run's jobs (`actions/runs/<run>/jobs?filter=latest`) instead of
trusting a `skipping` row that comes from a run other than the head's suite. A workflow-side fix
(skipped jobs under names that collide with nothing) would lean on the same undocumented
behaviour that spares Bats, so it is not proposed.

## What this PR's own runs showed

- First head `09370ec5a`: the suite failed in 37 seconds, correctly. The legacy-domain guard found
  the old credits host in the title of a merged PR stored in `evidence/merged.json`. Nothing reads
  the titles, so the collector no longer stores them. That check was not run locally before the
  push; every script the suite calls was run before the second.
- Second head `e41f3337a`: suite green, the live edit above, the cancelled guard run of section 8.
- QA's finding on that head, and it was right: `pr-doctor.py plan` printed "nothing in CI is
  holding this head" at 06:09Z while three Bats shards were still running. The tool read
  `validate` and the guard and nothing else. It now reads every check the merge queue reads
  (`gh pr checks`) and QA's verdict, and calls a head clear only when all of them are a pass or a
  skip and QA passed it. An unreadable answer is an error, not "no checks".
- Third head `26858bad6`: the suite failed in 13 seconds at the rebase-staleness step, correctly.
  Another PR that edits `AGENTS.md` merged at 06:51:36Z, two minutes before the push at
  06:53:35Z, and the branch had been rebased less than five minutes before that. That is cause 4's mechanism
  on a small scale: three PRs that edit `AGENTS.md` merged in the hour before, and each one
  makes every open branch that edits it stale. The step is a real requirement and is unchanged.
  The habit that avoids the lost round is to fetch and rebase in the same command as the push.
- Fourth head `f2a18b0ed`: suite green (Bats shards 10.1, 20.6, 28.4 and 22.9 min), and QA's
  Critical finding on the mirror: the retarget-then-edit gap in section 1. Fixed on the fifth head.
- Fifth head `227ba3719`: `validate` green. The body was edited 7 seconds after the push; the
  edit run's `validate` listed the runs, waited 351 s for the suite and went green 11 s after it
  (`[0s] validate-code of run 43389275267 is in_progress`, `[351s] ... succeeded`). Bats shards
  10.5, 22.7, 31.4 and 25.9 min. QA: no Critical finding left, one Important one, that `tier:0`
  understates a change to the required check. Correct; it is `tier:2` now.
- The same head's `Python unit tests (watchdog)` failed, hidden as in section 9, on a test this PR
  does not touch: the kill-and-recover case of `scripts/tests/test_apply_queue.py`, added by
  #1922. It asks that all 120 jobs end `sent` or `uncertain`, and 1 was still `queued`. Since
  #1922 merged at 01:11Z that job has run to a verdict 30 times and failed 6, every time on this
  test, on 5 branches, with 1 to 9 jobs left queued. So one validation round in five is red on
  `main`'s own test, on a job the merge queue holds on. It was not reproduced locally: pinned to
  two idle CPUs it passed 12 of 12, and the one local failure, on a loaded box, had a different
  shape (`database is locked`, 89 queued). Not fixed here: `apply_queue.py` is under
  `scripts/credit_review/`, another lane's file in the credit-approval block. Until it is,
  `gh run rerun <run> --failed` clears it without a commit.
- Sixth head `174127db4`: suite green, that test included. Two defects in `pr-doctor.py plan`,
  both the same kind. One I hit: two minutes after the push it said no validation had ever run
  and to close and reopen, because `validate` is not listed until the suite job ends. It now
  reads which validation runs are still running and waits. One QA found (Important): with
  `validate` and QA green and `credit-approval-guard` still running, every rule passed and the
  tool said nothing was holding the head, while the merge queue was holding it. Correct. A
  running guard and a suite that is running again under an older green `validate` are waits now.
- That was the third time a head the queue was holding fell through every rule and read as
  clear (Bats on head 2, the hidden job on head 5, the guard on head 6). So clear is no longer
  the absence of a rule that fired. After the rules, the tool reads the queue's own view once
  more: any row that is not a pass or a skip, any job of the suite run that did not pass, or no
  passing QA verdict, with no rule naming it, prints `unknown` and the instruction to read
  `gh pr checks`. `unknown` is never applied and never printed as clear.

With that, the plan over all 196 open PRs at 06:37Z: 27 are clear (every check green, QA GO, not
merged), 96 conflict, 14 are on another base, 20 carry a QA NO-GO, 19 have a failed job that is
not a required check but that the merge queue holds on (16 of them a Bats shard), 9 a failed
suite, 2 have no QA verdict at all with nothing running (#1445, #1754; the command that re-fires
the review without re-running CI is printed), and 2 a red title. A PR can be in more than one.

Run again at 08:26Z with the suite-job rule of section 9, over 195 open PRs: 26 clear, and one
open PR with a suite job that is not green behind an edit's skip, which is this one.

## Where the hours go

Last 50 merged PRs, #1812 to #1926, merged 2026-11-08T00:28Z to 2026-11-13T02:21Z. Stages are
for the head that merged.

| Stage | Median | p90 | n |
|---|---|---|---|
| open -> merge | 4.42 h | 41.26 h | 50 |
| push -> merge | 0.90 h | 6.13 h | 50 |
| push -> `validate` green | 0.10 h | 0.18 h | 50 |
| `validate` green -> merge | 0.78 h | 6.03 h | 50 |
| `validate` green -> Bats done | 0.61 h | 0.72 h | 50 |
| QA GO -> merge | 0.79 h | 5.32 h | 35 |
| merge -> deployed | 3.91 h | 29.44 h | 50 |

15 of the 50 merged with no QA GO status on the merged head, so the QA row is 35.
push -> merge: 0.87 h for the 44 not poisoned, 1.13 h for the 6 poisoned.

Last 50 that stalled (the newest 50 open, non-draft heads older than 24 h), by primary cause:

| Cause | Primary | Present at all |
|---|---|---|
| conflicts with `main` | 25 | 25 |
| ready, not merged (nothing in CI holds it) | 10 | 10 |
| the suite failed | 4 | 7 |
| QA NO-GO | 3 | 10 |
| `validate` absent on the newest run | 3 | 5 |
| `credit-approval-guard` red | 2 | 16 |
| `validate` poisoned by a metadata edit | 2 | 2 |
| base is not `main` | 1 | 1 |

**Top three by count: conflicts (25), ready but not merged (10), a failed suite (4).** The second
is a waiting-for-a-decision cost, not a CI cost: all 28 open PRs in that state have a green
`validate` and a QA GO on the head, 24 of them have waited more than a day and 16 more than a week. `docs/delivery-velocity.md` rules 1 and 2
are the fix for it; no code here changes it.

## Before and after

| | Before | After | How the after was measured |
|---|---|---|---|
| Recorded metadata-edit `validate` failures on the sampled heads | 14 | 1 | Replay: the shipped script run over the recorded check runs of each head, on the recorded clock. A dry run on production data, not a measurement of the deployed change |
| Recorded metadata-edit `validate` successes | 22 | 22 | Same replay, other direction: none would now fail |
| Merged PRs poisoned | 6 of 50 | 1 of 50 | Replay. #1892 stays red: its suite was cancelled, so there was nothing green to repeat. That is the check working |
| Median push -> merge, the 6 poisoned | 1.13 h | 0.72 h | Replay; a PR is never assumed to merge before its Bats, its QA GO and its own green |
| Median push -> merge, all 50 | 0.90 h | 0.85 h | Replay, mirror change only. Bats is not in this row |
| A body edit made while the suite runs | `validate` red until re-run by hand | `validate` green 12 s and 11 s after the suite | Live, two edits on this PR: the second head, and the fifth with the run listing |
| Slowest Bats shard | 42.8 min (median of 48 two-shard runs; fastest 32.0, slowest 51.8) | 27.9, 31.5, 28.4, 31.4 and 30.6 min | Live, this PR's five full runs. Five runs, not a median |
| Open PRs with a poisoned `validate`, not conflicting | 3 at 06:37Z (2 at 03:33Z) | 0 after 3 re-runs | `pr-doctor.py plan`: #1886, #1887, #1927. Not performed |
| Open PRs held by a cancelled guard run | 3 | 2 | Live: this PR's was re-run with `--apply`. #1921 and #1768 not performed |
| Open PRs BLOCKED by an absent `validate` | 3 | 0 after 3 edits | `pr-doctor.py plan`: #1855, #1856, #1863. Not performed |
| Open PRs with a stale guard red, mergeable | 20 | 0 after 37 re-runs | `pr-doctor.py plan`. Not performed |
| Open PRs with a suite job not green behind an edit's skip | not visible to the merge queue | 1 at 08:26Z (this PR), named by `pr-doctor.py plan` | Live. The reader is not changed |
| Open PRs conflicting | 102 (96 at 06:37Z) | unchanged | Not addressed |
| Open PRs on a non-`main` base | 14 | 14 | Named, not retargeted |

The re-runs were not performed from this lane, except the one on this PR: they act on other
lanes' PRs, and the tool that proposes them is in this PR and not yet reviewed. 24 open PRs have
at least one. `scripts/pr-doctor.py plan --all --apply` performs the first re-run on each PR per
pass, so a PR with two takes two passes. It can only re-run failed jobs
(`rerun-failed-jobs` is the one write in the file, pinned by a test), and a re-run reports what
is true now; it cannot produce a pass.

Not measured: a median for either live figure (one edit, two Bats runs), and the count of
poisoned PRs after this merges. `tools/measure.py collect` then `table` reads both from the next
50 merged PRs.

## Revert

`git revert` of this PR's merge commit restores two shards and the read-once `validate`. Nothing
outside the repo was changed: no ruleset edit, no retarget, no other PR's text or checks. The one
re-run performed was of this PR's own cancelled guard run.

## Re-measure

```
python3 data/pr-pipeline-unblock-f1/tools/measure.py collect --out /tmp/evidence   # read-only
python3 data/pr-pipeline-unblock-f1/tools/measure.py table   --evidence /tmp/evidence
python3 data/pr-pipeline-unblock-f1/tools/measure.py replay  --evidence /tmp/evidence
python3 scripts/pr-doctor.py plan --all                                            # read-only
```

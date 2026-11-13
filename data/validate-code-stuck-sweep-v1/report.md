# Validated heads that stayed unmergeable: what held them, and the re-run nobody performed

Captain, 2026-11-13: "can fable fix all of these issues".

Read-only GitHub API, `Muso-AI/hydra`, 2026-11-13 11:32Z to 12:25Z. Evidence is in `evidence/`.
Every count below is printed by `scripts/ci/pr-rerun-sweep.py --all` (dry run), by
`scripts/pr-doctor.py plan --all`, or by `evidence/durations.py`, unless it says otherwise.

## The premise, corrected

The brief measured nine of the ten newest open PRs as blocked on `validate-code: skipped`, meaning
the validation stage never ran on that head. That reading is wrong, and the correction changes the
fix.

`validate-code: skipping` in `gh pr checks` is the placeholder a title or body edit posts. An edit
starts a PR Validation run that skips the suite on purpose, and `gh pr checks` keeps one row per
check name, the newest. The row says nothing about the suite's own `validate-code` on that head.
Of the ten newest PRs at 11:32Z, four were CLEAN, one conflicted, three were held by the credit
guard or a QA NO-GO, and two were held by the defect below.

**No open hydra head was unvalidated.** Across all 192 open PRs, `pr-doctor.py plan --all` found
zero heads whose suite had never run. What it found instead:

| Shape | Open PRs | Is the head validated? | What clears it |
|---|---|---|---|
| Suite green, required `validate` red: a title/body-edit run (newer, so the one GitHub grades) failed before the suite finished | 3 | yes | re-run the edit run's failed job (5 s) |
| Suite green, required `validate` "expected": a pre-2026-11-11 edit run posted its skipped check under a literal `validate${{ ...` name | 3 | yes | any `edited` event (the mirror then posts a real `validate`) |
| Suite FAILED | 8 | no | a person reads the failure. Correctly held. |
| `credit-approval-guard` red or cancelled on one of its two events, body passes the guard today | 21 | n/a (not `validate`) | re-run that guard run |

So the wall was six PRs, not nine of ten, and on every one of them validation had run and passed.
The defect is the one the brief names in its last sentence: nothing re-runs the check.

## Which option, and why

The brief offered three. None is taken as written.

- **(a) a `workflow_dispatch` that runs validate-code for a given head: rejected.** A dispatched run
  executes the default branch's workflow file against a ref, not the PR's merge commit, so it would
  validate something other than what merges. It would also be a second way to mint the required
  check, which is the thing the ruleset exists to prevent.
- **(c) the aggregator treats `skipped` as not-run and re-dispatches: not needed.** The aggregator
  already does the right thing since #1935: on an edit run, `validate` mirrors the head's real
  suite and fails closed. Its red is correct at the moment it is written. What goes wrong is that
  the red is never revisited after the suite turns green.
- **(b) re-trigger in place: taken, and made automatic.** GitHub can re-run the failed jobs of any
  run for 30 days. The re-run reads the same head, keeps the QA verdict, and reports what is true.
  `scripts/pr-doctor.py plan N --apply` has done exactly this since #1935, when a person ran it.

**What ships:** `.github/workflows/pr-rerun-sweep.yml`, which runs
`scripts/ci/pr-rerun-sweep.py` when a PR Validation run completes, every 2 hours, and on dispatch.
The script asks `pr-doctor.plan_pr` what holds each head and performs that plan's re-run:
`POST /actions/runs/{id}/rerun-failed-jobs`, at most one per PR per pass.

The rule that an unvalidated head cannot merge is untouched:

- The workflow's only write permission is `actions: write`. It cannot merge, push, edit a PR, post
  a status or create a check.
- A re-run cannot turn an unvalidated head green. The mirror exits 0 only when the head's newest
  real suite succeeded.
- The planner never offers a re-run for a suite that FAILED, a conflicting head, a head whose
  mergeability is unknown, or a QA NO-GO. Each has a test.
- Nothing is re-run while any run of the head is in progress, because both workflows cancel an
  in-progress run of their own concurrency group.
- A run is re-run at most twice (`MAX_ATTEMPTS = 3`), then reported as a warning and left.
- "Could not read" is exit 3, never a clean pass.
- Ruleset 26901288 is read and not changed.

Kill switch: repository variable `PR_RERUN_SWEEP_DISABLED=1`, or disable the workflow. Nothing
depends on it.

## What was unstuck, by hand, before the workflow exists

`workflow_run` and `schedule` run the default branch's copy of a workflow, so the automatic path
cannot act until this PR merges. The six were cleared with the same calls it will make. No commit
was pushed to any branch; every head is unchanged.

| PR | Head | Action | Result | Merge state |
|---|---|---|---|---|
| https://github.com/Muso-AI/hydra/pull/1936 | `b2b03fc0a` | re-ran failed job of run 43388110812 | `validate` success 12:17:41Z | BLOCKED → CLEAN |
| https://github.com/Muso-AI/hydra/pull/1927 | `0922b3a0a` | re-ran failed job of run 43372232929 | `validate` success 12:17:46Z | BLOCKED → CLEAN |
| https://github.com/Muso-AI/hydra/pull/1886 | `13f7328be` | re-ran failed job of run 43025286085 | `validate` success 12:17:49Z | BLOCKED → CLEAN |
| https://github.com/Muso-AI/hydra/pull/1863 | `f9669e092` | body edit, one trailing newline removed | run 43424609651 `validate` success 12:22:43Z | BLOCKED → CLEAN |
| https://github.com/Muso-AI/hydra/pull/1856 | `54f214ac6` | body edit, one trailing newline removed | run 43424769234 `validate` success 12:23:51Z | BLOCKED → CLEAN |
| https://github.com/Muso-AI/hydra/pull/1855 | `61e7e8911` | body edit, one trailing newline removed | run 43424774951 `validate` success 12:23:54Z | BLOCKED → CLEAN |

The first three were done with `pr-rerun-sweep.py --pr 1936 1927 1886 --apply`
(`evidence/unstick-apply.json`).

The last three are **outside what the sweep can do**, by design: they need an `edited` event and
the workflow holds no permission to edit a PR. They were edited by hand, after checking for each
one what that event would re-evaluate:

- the `validate` mirror, run by hand against each head, exited 0;
- today's credit guard, run with `--dry-run` (read-only, verified at its one `set_label` call
  site), exited 0;
- each title satisfies today's `pr-title` rule.

The edit also started `qa-tier-recheck`, which was not predicted. It stopped at its gate on all
three (both dispatch steps skipped), because it dispatches only when an edit adds a `Tier:` line.
No QA review was triggered.

**All three touch credit-approval paths** (`scripts/credit_review/decide.py`, `judge.py`,
`scripts/tests/test_credit_verify_notify.py`) and were validated on 2026-11-08 against that day's
`main`. They are CLEAN because the ruleset is non-strict, which is how every hydra PR is graded.
Making the required check post correctly approves nothing; the guard's own line still applies
("Admin-merge only on Fable GO + QA GO + green CI"). Whoever merges them may prefer a fresh
validation first: `gh pr close N && gh pr reopen N`.

Revert of the edits: append one newline to each body (GitHub also keeps the body's edit history).
A re-run has no revert and needs none: it replaced a stale result with a true one.

Nothing was merged by this work. https://github.com/Muso-AI/hydra/pull/1886 was merged by its merge
authority at 12:48:55Z, 31 minutes after it went CLEAN. The other five were open and CLEAN at 12:57Z.

**Not touched:**

- https://github.com/Muso-AI/hydra/pull/1868 looks like the legacy shape (blocked, green rollup)
  and is not: its suite failed (run 42601556201, Bats shard 1/2) and a later skipped run hides
  that in the rollup. It is correctly blocked.
- The 21 guard re-runs. They are a different gate from the one the brief names. The workflow will
  perform them once it is on `main`; see "For the reviewer".

## Found on the way: a test on `main` began failing for every PR at 12:00Z

Not part of the brief. It is here because it held this PR, and holds every hydra PR pushed since.

The first PR Validation run of this branch (run 43429574627, started 12:58Z) failed
`Python unit tests (watchdog)` at the step `Run GDPR DSAR ladder tests`, in a file this branch did
not touch. The same test failed on `main` and on `main`'s parent, and had passed in CI at 10:39Z
and 11:21Z.

`tests/test_gdpr_dsar.py`,
`test_a_request_with_no_owed_letter_gets_the_older_ask_unchanged_while_the_gate_holds_other_letters`,
took its baseline at a pinned clock (2026-11-12T12:00Z) and its second read at the real clock. The
older ask words itself by the request's date: once the date has passed it opens with
`copy.PROGRESS_LINE`, with or without the ladder. Two of the test's requests were received
2026-10-14T12:00Z, so their date is 2026-11-13T12:00:00Z. Measured with the clock set either side:

| Clock | Failing tests of 172 |
|---|---|
| 2026-11-13T11:59:59Z | 0 |
| 2026-11-13T12:00:01Z | 1 (3 subtests) |
| eight later dates, to 2027-11-13 | 1 at each |

So it is one aged fixture, not a series, and it would not have cleared by itself. The product
behaviour is as designed: read at one instant, the ask before and after the ladder runs is
byte-identical for all three gate verdicts.

**What it costs while it stands.** The required `validate` stays green, because that is the
`validate-code` job. But the failing step stops its job, and the 22 test steps after it are
skipped: the ops-intake router and its red-team corpus, sentinel-demote, the Caroline monitor and
others, including the step that runs this PR's own 43 tests. Since 12:00Z a hydra head can show a
green required check with those 22 steps not run. This branch's run was the only suite started
after 12:00Z when this was read (13:08Z), so no merged PR is known to be affected.

**The fix, as its own commit** (`test(gdpr): read the older ask against a baseline taken at the
same instant`), so it can be cherry-picked ahead of this PR or dropped from it. The test now makes
both reads against a baseline from the same instant: the original comparison at the pinned clock,
and the real-clock read against a real-clock baseline taken before the ladder runs. No production
code is changed. After: 0 failing at every clock in the table.

That it was not loosened: three breakages of the behaviour it protects turn it red both before and
after the edit (`evidence/mutate_dsar.py`; the before case run with the clock set to 11:00Z, the
only way the old test can pass).

| Breakage | Old test | Edited test |
|---|---|---|
| A letter held for another request stands every older ask down | red | red |
| The ladder running changes the bytes of an ask it holds no letter for | red | red |
| The first, visible only once the read is past the store's real-clock stamp | red | red |

Not checked: whether any of the 22 skipped steps has its own failure on today's `main`. They have
not run in CI since 12:00Z. This PR's next run is the first that will show it.

## Before and after

| | Before | After |
|---|---|---|
| Open PRs whose head is validated and held only by a stale or missing `validate` | 6 (11:32Z) | 0 (12:25Z) |
| Open PRs whose head never had validation run | 0 | 0 |
| Green suite → mergeable, the six: median | 80.75 h (4.48 h to 125.57 h) | not yet measured end to end; see below |
| Green suite → mergeable, the three a re-run clears: median | 6.72 h (4.48, 6.72, 47.27) | all three green 22 s after the first re-run request (12:17:27Z → 12:17:49Z) |
| The re-run's own job | n/a | median 5 s, max 6 s (6 of 6) |

What the "after" row does and does not show. Measured: once the re-run is requested, the head is
mergeable within seconds (three requests, sent one after another, all green within 22 s). **Not measured: the trigger.** The time from a suite turning green to
the workflow requesting that re-run includes GitHub delivering `workflow_run`, a runner starting
and the script's reads (17 s for seven PRs in a dry run). That cannot be measured until the
workflow is on `main`. The schedule bounds the worst case at 2 hours. The first live pass should
be watched, and `dry_run` on a dispatch prints the plan without re-running anything.

Cost of a pass, measured: 278 and 260 API reads for a full sweep of 177 open PRs on `main` (96
conflicting and 31 to 34 not red are skipped without a read), 1 min 58 s; about 7 reads for one
head. PR Validation completed 147 times in the last 24 hours, 15 in the busiest hour. So the
busiest hour would have cost about 105 reads plus one full sweep. The token's hourly budget for
this repository was not measured; 1,000 per hour is GitHub's documented floor for `GITHUB_TOKEN`.
A budget that runs out is a failed read, exit 3, and no action.

## For the reviewer

1. **The sweep re-runs stale `credit-approval-guard` reds too** (21 heads today), because that is
   what the planner's `--apply` already does. A guard re-run re-evaluates the current body against
   the guard on `main`; it cannot pass a body that fails, and a body that fails is never re-run
   (tested). Of the 20 that are red (the 21st is a cancelled run), only 2 are held by the guard
   alone; the others also failed their suite, have a red title or carry a QA NO-GO. If the guard should stay a person's re-run, that is a small change
   to `choose()` and this is the place to ask for it.
2. **The planner is trusted.** The sweep adds no rule of its own about what may be re-run. A wrong
   `rerun` step in `pr-doctor.plan_pr` would now be performed unattended, up to twice per run.
3. **The legacy shape is not handled automatically** and does not need to be: it can only exist on
   a head whose last edit run predates 2026-11-11, and none is left.
4. `actionlint` reports one finding on the new workflow, the custom `ovh-hydra` runner label, the
   same finding it reports on `pr-title-check.yml`.

## Other repositories

`validate-code` exists only in hydra (code search across the org's workflows). The brief's
"more exist across H-DevOps, core-backend and web-credits-next" is a different wall in each, and
none was changed:

- **H-DevOps**: the ruleset requires `aggregate` and `verify`. 58 non-conflicting blocked heads
  have no `aggregate` at all, because `guards-aggregate.yaml` was created on 2026-11-04, after
  those heads' last push, and it runs on `pull_request` only. A re-run cannot help (there is no
  run). That needs its own change in H-DevOps.
- **core-backend** and **web-credits-next**: no required status checks. Their blocked PRs wait on
  a QA verdict, a guard or a failing test.

## Reproduce

```
GH_TOKEN=$(gh auth token) python3 scripts/ci/pr-rerun-sweep.py --repo Muso-AI/hydra --all   # dry run
python3 scripts/pr-doctor.py plan <pr>                                                      # one PR, in full
python3 data/validate-code-stuck-sweep-v1/evidence/durations.py                             # the six
python3 scripts/tests/test_pr_rerun_sweep.py                                                # 43 tests
python3 data/validate-code-stuck-sweep-v1/evidence/clockshift.py 2026-11-14T13:00:00 test_gdpr_dsar
python3 data/validate-code-stuck-sweep-v1/evidence/mutate_dsar.py
```

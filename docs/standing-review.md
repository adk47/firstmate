# The standing review

Captain, 2026-11-12: "use fable and review occasionally plans architecture and code without interrupting anything
moving unless a fix is needed."

A second reader for plans, architecture and merged code. It costs nothing when the work is fine: a pass with no
defect prints nothing, pages nobody and touches no running task.

- Program: `scripts/standing_review/review.py` (standard library only)
- Scheduled wrapper: `scripts/standing-review-tick.sh`
- Rubric the reviewer is given: `policies/standing-review-rubric.md`
- Tests: `scripts/tests/test_standing_review.py` (PR Validation)
- First real pass, with the would-interrupt / report-only split: `data/fable-standing-review-v1/report.md`

## Cadence

Every 2 hours, on ak47. node-8 has no route to the reviewer model, so this does not run there.

One pass is at most one reviewer call (`token-pool/claude-fable-5-2`, no tools) on the subscription pool. When
nothing merged and no plan changed since the last pass, there is no call at all.

## What one pass reads

- **Code**: the commits merged to `main` since the last pass, oldest first. A commit is read whole, or it is the
  only commit in the pass; one that does not fit waits for the next pass. Budget: 200,000 characters of diff per
  pass, 60,000 per file. When a single commit is larger than that, code is read before config, prose and tests.
- **One document**: the most recently changed plan, design or architecture document it has not read at its current
  content (`DOC_PATTERNS` in `review.py`, plus any `--doc-glob` outside the repository).

Everything left out is named in the report under "not reviewed", with the reason: `over_budget`,
`partially_sampled`, `binary_or_generated`, `deletion_only`, or `skipped_backlog` when more than 12 commits were
waiting. This is a sample. It does not claim to have read what it lists there.

## What interrupts

The reviewer proposes findings. Code decides which of them page (`judge()` in `review.py`).

A finding pages only when all of these hold:

1. Its class is one of the six defects: `correctness_bug`, `silent_failure`, `race`, `gate_bypass`,
   `wrong_number`, `irreversible_no_revert`.
2. It states what is wrong, the blast radius and the smallest fix.
3. Every evidence quote is found verbatim in the sampled text at the path it names. The line number on the page
   comes from the sample, not from the reviewer.
4. The reviewer marks it `verified`: the quoted text alone proves it.
5. It has not been paged before.

Everything else is written to the report with the reason it did not page (`why_not`) and interrupts nobody:
`naming`, `structure`, `style`, `extract_suggestion`, `reopens_recorded_decision`, `test_gap`, `doc_drift`,
`hardening`, `other`, any class the gate does not know, and any defect that is only suspected.

A finding whose fix needs Aaron (money, a customer promise, something irreversible) carries one `Needs Aaron` line
on the page. The page states the decision; it does not argue it.

## The two outputs

| | Where | When |
|---|---|---|
| Report | `<state>/report.md`, generated from `<state>/findings.jsonl` | Every pass. Every finding, paged or not. |
| Page | stdout, or the `--page-cmd` command | Only when a finding passes the gate. |

A page lists, per defect: what is wrong, the evidence as `path:line` with the quote, the blast radius and the
smallest fix. At most five defects per page; the rest are counted and are in the report.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Pass complete. Nothing to say, stdout empty. |
| 10 | A defect was paged. |
| 3 | UNMEASURED. The reviewer did not answer, or did not answer in the contract. Nothing was reviewed, the cursor did not move, and the same commits are read next pass. Three in a row produce one page about the reviewer itself. |
| 2 | The pass could not run: fetch failed, state unreadable, another pass holds the lock, or a page could not be delivered. |

With `--page-cmd`, a page the command did not accept stays in `<state>/outbox/`, the run exits 2, and every later
run retries it before doing anything else.

## What it cannot do

These are properties of the code, each pinned by a test:

- It writes only under its state directory (`Store.path` refuses anything else).
- It runs `git` with nine read-only subcommands and `GIT_OPTIONAL_LOCKS=0`. `git status` is not among them because
  it refreshes the index.
- The scheduled wrapper fetches into its own bare mirror under the state directory. It never fetches into, locks
  or reads a checkout that a lane is working in.
- It has no GitHub client and no reference to a task inbox, status file or lease. It cannot claim, steer, stop or
  queue a running task. Who reads the page is the caller's choice.
- Commit subjects, diffs and documents are author-controlled. They reach the reviewer between per-call random
  markers in a call with no tools, and the answer is parsed and bounded, never executed.

## Running it

```bash
# What the next scheduled pass would read. No reviewer call, no state change.
python3 -I scripts/standing_review/review.py sample

# One scheduled pass against a checkout's origin/main.
python3 -I scripts/standing_review/review.py run

# An ad-hoc pass over named targets. Reported like any pass; never moves the schedule.
python3 -I scripts/standing_review/review.py run --worktree ../some-lane-worktree
python3 -I scripts/standing_review/review.py run --no-code --doc data/verification-scale-plan.md
python3 -I scripts/standing_review/review.py run --no-doc --since <sha>

python3 -I scripts/standing_review/review.py status
```

State defaults to `~/.local/state/hydra-standing-review` (`HYDRA_STANDING_REVIEW_STATE` or `--state` to change it).

## Installing the schedule on ak47

Not installed by a deploy; `deploy.sh` targets node-8. As a user unit on ak47:

```ini
# ~/.config/systemd/user/hydra-standing-review.service
[Unit]
Description=Standing review of hydra plans, architecture and merged code (silent unless a fix is needed)

[Service]
Type=oneshot
Environment=STANDING_REVIEW_PAGE_CMD=/path/to/a/command/that/reads/a/page/on/stdin
Environment=STANDING_REVIEW_DOC_GLOBS=/home/aaron/Projects/firstmate/data/*/plan.md
ExecStart=/path/to/hydra/scripts/standing-review-tick.sh
SuccessExitStatus=10
TimeoutStartSec=30min
```

```ini
# ~/.config/systemd/user/hydra-standing-review.timer
[Timer]
OnCalendar=*-*-* 00/2:20:00
Persistent=true

[Install]
WantedBy=timers.target
```

Exit 10 is a success for the unit (the page was delivered). Exits 2 and 3 leave the unit failed, which is the
intent: a reviewer that cannot review should be visible.

Kill switch: `touch <state>/disabled`. The tick then exits 0 with one line on stderr. Remove the file to resume;
the cursor is where it was.

## Limits

- It samples. A defect in a file listed under "not reviewed" is not found.
- The gate checks that a quote exists where the reviewer says it does. It does not check the reviewer's reasoning.
  A paged finding is a claim with verified evidence, to be confirmed by whoever owns the code before acting.
- The reviewer sees diffs with 12 lines of context, not whole files. A defect that depends on code outside the
  diff should come back as `suspected`, which does not page.

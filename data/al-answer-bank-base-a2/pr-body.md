Tier: 1, because it changes one CI gate (the Caroline answer-bank check in Plugin tests (vitest)) and no runtime code. A wrong change can only make that one gate pass or fail when it should not, and reverting one commit undoes it.

## What was wrong

PRs that touch no answer-bank file failed `Plugin tests (vitest)` at the step "Caroline answer-bank doctrine gate". This happened on https://github.com/Muso-AI/hydra/pull/2120, https://github.com/Muso-AI/hydra/pull/2126 and the intercom-open-convos PR.

I checked the cause on #2126 (job 133475442637, 2026-11-16T17:48Z):
- The checkout was `ce9a843`, "Merge 08d35a02 into 7a69bc93". This is GitHub's `refs/pull/2126/merge` at depth 1. Its first parent, `7a69bc93`, is main as it was when the merge commit was made, and it carries `BANK_VERSION = "2026-11-14.2"`.
- The step fetched main's tip at job time into `origin/answer-bank-base`. Main had already taken #2040 (`28a51b5d5`, 17:35:41Z), which bumped the bank to `2026-11-15.2`.
- The gate then reported: `FAIL: the bank lines changed relative to origin/answer-bank-base but BANK_VERSION 2026-11-14.2 is not greater than 2026-11-15.2 there; bump it`.
- `git diff --name-only 7a69bc93...08d35a02` shows no answer-bank, anchor or pin file in the PR.

Re-runs and `pr-rerun-sweep` check out the same old merge commit again, so this happens every time main moves the bank.

## The change

- `scripts/check-caroline-answer-bank.sh` gets a new option, `--pr-base MAIN_REF`. It compares against the commit this tree was built on:
  - if HEAD is a merge commit, it uses `HEAD^1`;
  - otherwise it uses `git merge-base HEAD MAIN_REF`.
  
  It never compares against MAIN_REF's tip. It still fails (exit 2) if MAIN_REF does not resolve, if HEAD is a shallow boundary (its parents were not fetched), or if there is no merge base. It prints which base it used. `--base REF` is unchanged.
- In `.github/workflows/pr-validate.yml`, the step now fetches the merge commit's parents (`git fetch --depth=2 origin "$(git rev-parse HEAD)"`) and calls `--pr-base origin/answer-bank-base`.
- The existing rules still hold. A PR that changes bank lines without a bump fails. A version that goes backwards fails. A base that cannot be resolved fails.
- AGENTS.md gets one paragraph on this rule, under PR CI.

## Tests

`scripts/tests/check-caroline-answer-bank.bats` (this is where the answer-bank tests already run) gets 9 new cases on a local fixture repo. Each fixture has a real main, a PR branch, a `--no-ff` merge commit on the OLD main, and then a later main commit that bumps the bank:
- An untouched PR passes with `--pr-base main`, and the output names the first parent.
- The same tree with the old `--base main` fails with "is not greater than". This shows the fixture reproduces #2126.
- **Mutation:** a copy of the gate whose resolver returns main's tip turns the untouched-PR case red. The test also checks that the mutation actually applied.
- A PR head checked out directly (not a merge commit) uses the merge base and passes.
- A PR that edits a bank line, its anchor and the pin without a version bump fails.
- A PR whose BANK_VERSION goes backwards fails.
- `--pr-base no-such-ref` fails with exit 2.
- A depth-1 checkout of the merge commit fails with exit 2 ("shallow boundary"). After the workflow's depth-2 fetch, it passes.
- The workflow uses `--pr-base` and the depth-2 fetch, and no longer calls `--base`.

Local result: 18/18 in that file. `pr-validate-retarget.bats`, `pr-validate-node8-cap.bats` and `check-no-tmp-scratch.bats` are green.

## Credit approval impact

None. No credit, claim, approval or customer-message path is touched. This is a CI gate only.

## Revert

`git revert` the merge commit. The step then goes back to comparing against main's tip, and the false reds come back. No host state, timer, policy or data is involved.

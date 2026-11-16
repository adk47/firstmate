# al-answer-bank-base-a2 notes

## Cause (confirmed on https://github.com/Muso-AI/hydra/pull/2126)
- Job 133475442637 (run 43917484163, Plugin tests (vitest)), 2026-11-16T17:48Z.
- Checkout: depth 1 of ce9a843 = "Merge 08d35a02 (PR head) into 7a69bc93 (main at merge time)".
- Gate fetched main's tip at 17:48:54 into origin/answer-bank-base; main had taken #2040 (28a51b5d5, 17:35:41Z)
  which bumped BANK_VERSION 2026-11-14.2 -> 2026-11-15.2.
- Tree (7a69bc93 side) carries 2026-11-14.2; base (main tip) 2026-11-15.2 -> "FAIL: the bank lines changed relative to
  origin/answer-bank-base but BANK_VERSION 2026-11-14.2 is not greater than 2026-11-15.2 there; bump it".
- PR 2126 diff (7a69bc93...08d35a02) touches no answer-bank file. 7a69bc93 is an ancestor of origin/main and predates #2040.

## Fix (commits 07ff94dcd, 710821640)
- scripts/check-caroline-answer-bank.sh: new `--pr-base MAIN_REF`: base = HEAD^1 when HEAD is a merge commit, else
  `git merge-base HEAD MAIN_REF`. Fails (exit 2) when MAIN_REF does not resolve, HEAD is a shallow boundary, or no merge
  base exists. `--base REF` kept unchanged.
- pr-validate.yml step: `git fetch --depth=2 origin "$(git rev-parse HEAD)"` (merge commit's parents), then
  `--pr-base origin/answer-bank-base`.
- scripts/tests/check-caroline-answer-bank.bats: 9 new cases (fixture repo with real merge commit + later main bump):
  untouched PR passes; old `--base main` fails on same tree; mutant gate (resolver -> main tip) fails; PR head (no merge)
  passes via merge-base; edit-without-bump fails; version-backwards fails; unresolvable main ref fails; depth-1 checkout
  fails until parents fetched, then passes; workflow pins `--pr-base` + the depth-2 fetch. 18/18 local.

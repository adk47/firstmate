#!/usr/bin/env bats
# MUS-5643: agent scratch must not be authored as a literal /tmp path. Each
# agent Bash call is its own shell, so `trap ... EXIT` cannot clean it up.

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
GUARD="$HYDRA_REPO/scripts/check-no-tmp-scratch.sh"

setup() {
  REPO="$(mktemp -d)"
  cd "$REPO"
  git init -q -b main
  git config user.email t@t && git config user.name t
  mkdir -p skills-all/foo workspaces/qa scripts/tests
  printf 'old: /tmp/legacy.json\n' > skills-all/foo/SKILL.md
  printf '# qa\n' > workspaces/qa/AGENTS.md
  printf '#!/bin/sh\n' > scripts/x.sh
  git add -A && git commit -q -m base
}

teardown() { rm -rf "$REPO"; }

@test "legacy /tmp lines already on base are not flagged" {
  run "$GUARD" --base HEAD
  [ "$status" -eq 0 ]
}

@test "planted /tmp/foo-\$\$.json template in a SKILL.md is red" {
  printf 'payload=/tmp/foo-$$.json\n' >> skills-all/foo/SKILL.md
  git commit -qam plant
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills-all/foo/SKILL.md"* ]]
}

@test "run-scoped form is green" {
  printf 'payload=$(mktemp "${PAPERCLIP_RUN_SCRATCH_DIR:-${TMPDIR:-/tmp}}/pr-XXXXXX.json")\n' >> skills-all/foo/SKILL.md
  git commit -qam ok
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 0 ]
}

@test "workspaces AGENTS.md and scripts are covered" {
  printf 'git clone x /tmp/clone-1\n' >> workspaces/qa/AGENTS.md
  git commit -qam a
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 1 ]
  git reset -q --hard HEAD~1
  printf 'out=/tmp/y.txt\n' >> scripts/x.sh
  git commit -qam b
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 1 ]
}

@test "tmp-ok: marker with a reason allows the line; without a reason it does not" {
  printf 'f=/tmp/sock # tmp-ok: socket path fixed by the daemon\n' >> scripts/x.sh
  git commit -qam a
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 0 ]
  printf 'g=/tmp/sock2 # tmp-ok:\n' >> scripts/x.sh
  git commit -qam b
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 1 ]
}

@test "scripts/tests fixtures and unrelated paths are out of scope" {
  printf 'x=/tmp/fixture\n' >> scripts/tests/a.bats
  printf 'x=/tmp/fixture\n' > scripts/tests/fixture.sh
  printf 'x=/tmp/self\n' >> scripts/check-no-tmp-scratch.sh
  mkdir -p docs && printf '/tmp/doc\n' > docs/n.md
  git add -A && git commit -qm t
  run "$GUARD" --base HEAD~1
  [ "$status" -eq 0 ]
}

@test "--staged checks the index" {
  printf 'p=/tmp/zzz\n' >> skills-all/foo/SKILL.md
  git add -A
  run "$GUARD" --staged
  [ "$status" -eq 1 ]
}

# The review recipe's cleanup `rm` must not turn a failed POST into success.
# Runs the REAL fenced block from SKILL.md with qa-gh.sh stubbed.
run_review_block() {
  local skill="$HYDRA_REPO/skills-all/muso-github-code-review/SKILL.md"
  mkdir -p stub scratch
  printf '#!/bin/sh\nexit %s\n' "$1" > stub/qa-gh.sh
  awk '/^\*\*Use a per-run payload file/{f=1} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$skill" \
    | sed "s#/opt/hydra/scripts/qa-gh.sh#$PWD/stub/qa-gh.sh#" > block.sh
  [ -s block.sh ]
  PAPERCLIP_RUN_SCRATCH_DIR="$PWD/scratch" OWNER=o REPO=r PR=1 run bash block.sh
}

@test "review recipe returns the POST status when the POST fails, and leaves no payload" {
  run_review_block 7
  [ "$status" -eq 7 ]
  [ -z "$(ls scratch)" ]
}

@test "review recipe returns 0 when the POST succeeds" {
  run_review_block 0
  [ "$status" -eq 0 ]
}

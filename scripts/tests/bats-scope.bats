#!/usr/bin/env bats
# bats file_tags=every-pr
#
# bats-scope.bats: which Bats suites a pull request runs (scripts/ci/bats-scope.py),
# and how main runs all of them (scripts/ci/bats-job-step.py, bats-main.yml).
#
# 2026-11-15. A selector that selects too little is a pull request that merges with
# its failing suite never run, and it looks exactly like a pass. So every case here
# EXECUTES the shipped selector against a throwaway repo shaped like a GitHub
# pull-request checkout (HEAD is a merge commit: parent 1 the base, parent 2 the
# head), and the last section breaks the selector on a copy and requires a case to
# go red. This file carries the `every-pr` tag it tests: it runs on every pull request.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCOPE="${SCOPE_UNDER_TEST:-$REPO_ROOT/scripts/ci/bats-scope.py}"
  STEP="$REPO_ROOT/scripts/ci/bats-job-step.py"
  R="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$R"
  g init -q -b main
  # The base tree: three scripts in a chain, a suite per link, two guards, prose.
  put scripts/alpha.sh        'echo alpha'
  put scripts/beta.sh         '. "$(dirname "$0")/gamma.sh"'
  put scripts/gamma.sh        '. "$(dirname "$0")/delta.sh"'
  put scripts/delta.sh        'echo delta'
  put scripts/lonely.sh       'echo nobody names me'
  put scripts/tests/alpha.bats   '@test "alpha" { run bash scripts/alpha.sh; }'
  put scripts/tests/beta.bats    '@test "beta" { run bash scripts/beta.sh; }'
  put scripts/tests/gamma.bats   '@test "gamma" { run bash scripts/gamma.sh; }'
  put scripts/tests/other.bats   '@test "other" { true; }'
  put scripts/tests/check-doctrine.bats '@test "whole tree" { run git ls-files; }'
  put scripts/tests/audit-ledger.bats   '@test "whole tree too" { run git ls-files; }'
  put scripts/tests/tagged.bats  $'# bats file_tags=slow,every-pr\n@test "tagged" { true; }'
  put scripts/tests/docs.bats    '@test "the runbook says so" { grep -q x docs/runbook.md; }'
  put docs/runbook.md            'see alpha.sh and delta.sh'
  put .github/workflows/pr-validate.yml $'jobs:\n  other-job:\n    steps: []\n  bats-tests:\n    steps: [bats]\n  later-job:\n    steps: []'
  g add -A; g commit -q -m base
  BASE=$(g rev-parse HEAD)
  SUITES=$(cd "$R" && git ls-files '*.bats' | sort)
}

g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@"; }
put() { mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" > "$R/$1"; }

# pr: commit what the caller staged as the pull request's head, then make the
# checkout GitHub makes: a merge commit of base and head.
pr() {
  g checkout -q -b head "$BASE"
  g add -A; g commit -q -m head
  g checkout -q --detach "$BASE"
  g merge -q --no-ff -m merge head >/dev/null 2>&1
}

# scope [event]: run the selector. $output is the selected suites, $why the reason line.
scope() {
  local err="$BATS_TEST_TMPDIR/why"
  output=$(printf '%s\n' "$SUITES" | BATS_SCOPE_REPO="$R" BATS_SCOPE_EVENT="${1-pull_request}" python3 "$SCOPE" 2>"$err")
  status=$?
  why=$(cat "$err")
}

picked()   { grep -Fxq -- "$1" <<<"$output"; }
all_run()  { [ "$output" = "$SUITES" ] && grep -q "every suite" <<<"$why"; }
# Bash does not fail a test on `! cmd` unless it is the last line, so the negatives
# are functions that return non-zero themselves.
left_for_main() { if picked "$1"; then echo "$1 was selected: $output"; return 1; fi; }
scoped()        { if all_run; then echo "every suite ran: $why"; return 1; fi; }
GUARDS="scripts/tests/check-doctrine.bats scripts/tests/audit-ledger.bats scripts/tests/tagged.bats scripts/tests/bats-scope.bats"

# ── the rule ────────────────────────────────────────────────────────────────

@test "a suite the pull request changes runs" {
  put scripts/tests/other.bats '@test "other, changed" { true; }'; pr; scope
  [ "$status" -eq 0 ]
  picked scripts/tests/other.bats
  left_for_main scripts/tests/alpha.bats
}

@test "a suite the pull request adds runs" {
  put scripts/tests/new.bats '@test "new" { true; }'; pr
  SUITES=$(cd "$R" && git ls-files '*.bats' | sort); scope
  picked scripts/tests/new.bats
}

@test "a suite that names a changed file runs, and one that does not is left for main" {
  put scripts/alpha.sh 'echo alpha, changed'; pr; scope
  picked scripts/tests/alpha.bats
  left_for_main scripts/tests/beta.bats
  left_for_main scripts/tests/other.bats
  grep -q "scoped pull request" <<<"$why"
  grep -q "The rest run on main" <<<"$why"
}

@test "one step removed: the suite names a script that names the changed file" {
  put scripts/delta.sh 'echo delta, changed'; pr; scope
  picked scripts/tests/gamma.bats
}

@test "two steps removed is NOT selected: that is the cost, and it shows on main" {
  put scripts/delta.sh 'echo delta, changed'; pr; scope
  left_for_main scripts/tests/beta.bats
}

@test "the whole-tree guards run on every pull request, whatever it changes" {
  put scripts/lonely.sh 'echo changed'; pr; scope
  picked scripts/tests/check-doctrine.bats
  picked scripts/tests/audit-ledger.bats
  picked scripts/tests/tagged.bats
  left_for_main scripts/tests/other.bats
}

@test "prose is not followed: a runbook that mentions a script does not select its suite" {
  put docs/runbook.md 'see alpha.sh and delta.sh, reworded'; pr; scope
  picked scripts/tests/docs.bats
  left_for_main scripts/tests/alpha.bats
  left_for_main scripts/tests/gamma.bats
}

@test "prose is not a step: a suite that names a runbook is not selected because the runbook mentions the changed script" {
  put scripts/alpha.sh 'echo alpha, changed'; pr; scope
  picked scripts/tests/alpha.bats
  left_for_main scripts/tests/docs.bats
}

@test "a changed runbook is not followed into the scripts that mention it" {
  put scripts/reader.sh 'cat docs/runbook.md'
  put scripts/tests/reader.bats '@test "reader" { run bash scripts/reader.sh; }'
  g add -A; g commit -q -m reader; BASE=$(g rev-parse HEAD)
  SUITES=$(cd "$R" && git ls-files '*.bats' | sort)
  put docs/runbook.md 'reworded'; pr; scope
  picked scripts/tests/docs.bats
  left_for_main scripts/tests/reader.bats
}

@test "a renamed file still selects the suite that names its old name" {
  g mv scripts/alpha.sh scripts/alpha-renamed.sh; pr; scope
  picked scripts/tests/alpha.bats
}

@test "a deleted file selects the suite that names it" {
  g rm -q scripts/alpha.sh; pr; scope
  picked scripts/tests/alpha.bats
}

@test "a name that is part of a longer name is not a match" {
  put scripts/tests/near.bats '@test "near" { run bash scripts/not-alpha.sh; run bash lib/alpha.shx; run bash scripts/xalpha.sh; }'
  g add -A; g commit -q -m near; BASE=$(g rev-parse HEAD)
  SUITES=$(cd "$R" && git ls-files '*.bats' | sort)
  put scripts/alpha.sh 'echo alpha, changed'; pr; scope
  picked scripts/tests/alpha.bats
  left_for_main scripts/tests/near.bats
}

@test "the selection keeps the order it was given and adds nothing" {
  put scripts/alpha.sh 'echo alpha, changed'; pr; scope
  [ "$output" = "$(grep -Fx -f <(printf '%s\n' "$output") <<<"$SUITES")" ]
  [ -z "$(grep -vFx -f <(printf '%s\n' "$SUITES") <<<"$output")" ]
}

# ── everything runs when the scope cannot be trusted ────────────────────────

@test "a push, the nightly and a run by hand run every suite" {
  put scripts/alpha.sh 'echo alpha, changed'; pr
  for event in push schedule workflow_dispatch merge_group ""; do
    scope "$event"
    all_run || { echo "event '$event' was scoped: $why"; return 1; }
  done
}

@test "a checkout that is not a pull-request merge commit runs every suite" {
  put scripts/alpha.sh 'echo alpha, changed'; g add -A; g commit -q -m plain; scope
  all_run
  grep -q "not a pull-request merge commit" <<<"$why"
}

@test "a three-parent merge runs every suite" {
  g checkout -q -b one "$BASE"; put a.txt 1; g add -A; g commit -q -m one
  g checkout -q -b two "$BASE"; put b.txt 2; g add -A; g commit -q -m two
  g checkout -q --detach "$BASE"; g merge -q --no-ff -m octopus one two >/dev/null 2>&1
  scope
  all_run
}

@test "a directory that is not a git checkout runs every suite" {
  R="$BATS_TEST_TMPDIR/not-a-repo"; mkdir -p "$R"; scope
  all_run
}

@test "a change to how Bats runs is proven by every suite" {
  for f in scripts/ci/bats-scope.py scripts/ci/bats-job-step.py scripts/ci/arc-toolchain.sh scripts/bats-slot.sh scripts/assert-host-devnull.sh .github/workflows/bats-main.yml; do
    g checkout -q --detach "$BASE"; g branch -q -D head 2>/dev/null || true
    put "$f" "changed $f"; pr; scope
    all_run || { echo "$f was scoped: $why"; return 1; }
    grep -q "decides how Bats runs" <<<"$why"
  done
}

@test "a change to the Bats job in the workflow runs every suite" {
  put .github/workflows/pr-validate.yml $'jobs:\n  other-job:\n    steps: []\n  bats-tests:\n    steps: [bats, changed]\n  later-job:\n    steps: []'
  pr; scope
  all_run
  grep -q "changes the Bats job" <<<"$why"
}

@test "a change to another job in the workflow is scoped" {
  put .github/workflows/pr-validate.yml $'jobs:\n  other-job:\n    steps: [changed]\n  bats-tests:\n    steps: [bats]\n  later-job:\n    steps: [changed]'
  pr; scope
  scoped
  picked scripts/tests/check-doctrine.bats
}

@test "a workflow whose Bats job cannot be found runs every suite" {
  put .github/workflows/pr-validate.yml $'jobs:\n  other-job:\n    steps: [changed]'
  pr; scope
  all_run
}

@test "a helper beside the suites that no suite names runs every suite" {
  put scripts/tests/helpers/quiet.bash 'quiet() { true; }'; pr; scope
  all_run
  grep -q "no suite names" <<<"$why"
}

@test "a helper beside the suites that a suite names selects that suite" {
  put scripts/tests/helpers/loud.bash 'loud() { true; }'
  put scripts/tests/other.bats $'load helpers/loud\n@test "other" { loud; }'
  g add -A; g commit -q -m helper; BASE=$(g rev-parse HEAD)
  put scripts/tests/helpers/loud.bash 'loud() { echo changed; }'; pr; scope
  scoped
  picked scripts/tests/other.bats
  left_for_main scripts/tests/alpha.bats
}

@test "a file named by too many files to follow runs every suite" {
  for i in $(seq 1 12); do put "scripts/user-$i.sh" '. scripts/delta.sh'; done
  g add -A; g commit -q -m users; BASE=$(g rev-parse HEAD)
  put scripts/delta.sh 'echo delta, changed'; pr
  output=$(printf '%s\n' "$SUITES" | BATS_SCOPE_REPO="$R" BATS_SCOPE_EVENT=pull_request python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('bs', '$SCOPE'); bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
bs.HUB_LIMIT = 10
sys.exit(bs.main())" 2>"$BATS_TEST_TMPDIR/why"); why=$(cat "$BATS_TEST_TMPDIR/why")
  all_run
  grep -q "too many to follow" <<<"$why"
}

@test "the answer is never empty, and the selector never fails the job" {
  put scripts/lonely.sh 'echo changed'; pr
  SUITES="scripts/tests/other.bats"; scope
  [ "$status" -eq 0 ]
  # No guard and no concerned suite among what was discovered: nothing is selected,
  # and the workflow step turns an empty answer into every suite (next section).
  [ -z "$output" ]
  SUITES=""; scope
  [ "$status" -eq 0 ]
}

# ── the real tree and the real workflows ────────────────────────────────────

@test "this repo: the whole-tree guards are still found by name" {
  n=$(cd "$REPO_ROOT" && git ls-files 'scripts/tests/check-*.bats' 'scripts/tests/audit-*.bats' | wc -l)
  [ "$n" -ge 30 ]
}

@test "the pull-request step hands the selector the event's own name" {
  run python3 "$STEP" 1 pull_request
  [ "$status" -eq 0 ]
  grep -q 'BATS_SCOPE_EVENT="pull_request" python3 scripts/ci/bats-scope.py' <<<"$output"
  run grep -c 'BATS_SCOPE_EVENT="\${{ github.event_name }}"' "$REPO_ROOT/.github/workflows/pr-validate.yml"
  [ "$output" = "1" ]
}

# The step's own fallback, executed: take the scope block out of the shipped step and
# run it with a selector that fails, prints nothing, or prints a stranger.
scope_block() {
  python3 "$STEP" 1 pull_request | awk '/^discovered="\$files"$/{on=1} on{print} /^count=\$\(grep -c \. <<<"\$files"/{if(on) exit}'
}
run_block() {  # $1 = body of a stand-in scripts/ci/bats-scope.py
  local d="$BATS_TEST_TMPDIR/blk"; rm -rf "$d"; mkdir -p "$d/scripts/ci"
  printf '%s\n' "$1" > "$d/scripts/ci/bats-scope.py"
  { echo 'set -euo pipefail'; echo 'files=$(printf "a.bats\nb.bats\nc.bats")'; echo 'count=3'
    scope_block; echo 'printf "%s\n" "$files"'; } > "$d/block.sh"
  (cd "$d" && bash block.sh)
}

@test "the step runs what the selector selected" {
  [ -n "$(scope_block)" ]
  run run_block 'print("b.bats")'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "b.bats" ]
  grep -q "executes 1 of 3" <<<"$output"
}

@test "the step runs every suite when the selector fails, says nothing, or names a stranger" {
  for body in 'import sys; sys.exit(3)' 'pass' 'print("b.bats"); print("z.bats")' 'raise SystemExit("boom")'; do
    run run_block "$body"
    [ "$status" -eq 0 ] || { echo "block failed for: $body"; echo "$output"; return 1; }
    grep -q "running every suite" <<<"$output" || { echo "no warning for: $body"; return 1; }
    [ "$(tail -3 <<<"$output" | tr '\n' ' ')" = "a.bats b.bats c.bats " ] || { echo "not every suite for: $body: $output"; return 1; }
  done
}

@test "main runs the pull-request step itself, with no expression left in it" {
  for event in push schedule workflow_dispatch; do
    run python3 "$STEP" 3 "$event"
    [ "$status" -eq 0 ]
    [ "$(grep -c '\${{' <<<"$output")" = "0" ]
    grep -q "BATS_SCOPE_EVENT=\"$event\"" <<<"$output"
    grep -q 'scripts/bats-slot.sh' <<<"$output"
    grep -q '^shard="3"$' <<<"$output"
    bash -n <(printf '%s\n' "$output")
  done
}

@test "main's shards are the pull-request job's shards" {
  want=$(python3 "$STEP" --shards)
  got=$(python3 -c "
import json, yaml
d = yaml.safe_load(open('$REPO_ROOT/.github/workflows/bats-main.yml'))
j = d['jobs']['bats']
print(json.dumps(j['strategy']['matrix']['shard']))
assert j['strategy']['fail-fast'] is False
on = d.get('on') or d.get(True)
assert 'main' in on['push']['branches'] and on['schedule'][0]['cron'], on
assert d['concurrency']['cancel-in-progress'] is False
run = '\n'.join(s.get('run') or '' for s in j['steps'])
assert 'scripts/ci/bats-job-step.py' in run, run
assert not any(s.get('if') for s in j['steps']) and not j.get('if')
")
  [ "$got" = "$want" ]
}

@test "the step extractor refuses what it cannot fill in" {
  wf="$BATS_TEST_TMPDIR/wf.yml"
  mk() { printf 'jobs:\n  bats-tests:\n    strategy:\n      matrix:\n        shard: [1, 2]\n    steps:\n%s\n' "$1" > "$wf"; }
  mk '      - run: scripts/bats-slot.sh ${{ matrix.shard }} ${{ github.event_name }}'
  run python3 "$STEP" --workflow "$wf" 2 push
  [ "$status" -eq 0 ]; [ "$output" = "scripts/bats-slot.sh 2 push" ]
  run python3 "$STEP" --workflow "$wf" 3 push;            [ "$status" -eq 98 ]
  run python3 "$STEP" --workflow "$wf" 1 'push; rm -rf'; [ "$status" -eq 98 ]
  mk '      - run: scripts/bats-slot.sh ${{ secrets.TOKEN }}'
  run python3 "$STEP" --workflow "$wf" 1 push;            [ "$status" -eq 98 ]
  mk $'      - run: scripts/bats-slot.sh a\n      - run: scripts/bats-slot.sh b'
  run python3 "$STEP" --workflow "$wf" 1 push;            [ "$status" -eq 98 ]
  mk '      - run: echo no slot here'
  run python3 "$STEP" --workflow "$wf" 1 push;            [ "$status" -eq 98 ]
  printf 'jobs:\n  other:\n    steps: []\n' > "$wf"
  run python3 "$STEP" --workflow "$wf" 1 push;            [ "$status" -eq 98 ]
}

# ── the selector, broken on purpose ─────────────────────────────────────────
# Each mutation is applied to a COPY, must change it, and must turn at least one
# case above red. A mutation that does not apply fails here rather than passing.

mutant_goes_red() {  # $1 = python expression rewriting the source `s`
  local copy="$BATS_TEST_TMPDIR/mutant.py"
  python3 - "$REPO_ROOT/scripts/ci/bats-scope.py" "$copy" "$1" <<'PY'
import sys
src, dst, edit = sys.argv[1:4]
s = open(src).read()
t = eval(edit)
assert t != s, "the mutation did not change the selector"
open(dst, "w").write(t)
PY
  local out rc
  out=$(SCOPE_UNDER_TEST="$copy" bats --filter-tags '!mutation' "$BATS_TEST_FILENAME" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then echo "every case stayed green with the selector broken"; return 1; fi
  grep -q '^not ok' <<<"$out" || { echo "the run failed without a failing case: $out"; return 1; }
}

# bats test_tags=mutation
@test "mutation: the unbroken selector passes every case above" {
  run env SCOPE_UNDER_TEST="$REPO_ROOT/scripts/ci/bats-scope.py" bats --filter-tags '!mutation' "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
}

# bats test_tags=mutation
@test "mutation: a push is scoped like a pull request" {
  mutant_goes_red 's.replace("if event != \"pull_request\":", "if False:")'
}

# bats test_tags=mutation
@test "mutation: the whole-tree guards are dropped" {
  mutant_goes_red 's.replace("chosen = own | direct | removed | always", "chosen = own | direct | removed")'
}

# bats test_tags=mutation
@test "mutation: the every-pr tag is ignored" {
  mutant_goes_red 's.replace("if shown.returncode == 0 and EVERY_PR_TAG.search(shown.stdout):", "if False:")'
}

# bats test_tags=mutation
@test "mutation: audit suites stop being guards" {
  mutant_goes_red 's.replace("(check|audit)-", "(check)-")'
}

# bats test_tags=mutation
@test "mutation: one step removed is dropped" {
  mutant_goes_red 's.replace("chosen = own | direct | removed | always", "chosen = own | direct | always")'
}

# bats test_tags=mutation
@test "mutation: suites that name a changed file are dropped" {
  mutant_goes_red 's.replace("chosen = own | direct | removed | always", "chosen = own | removed | always")'
}

# bats test_tags=mutation
@test "mutation: the suites the pull request changes are dropped" {
  mutant_goes_red 's.replace("own = {f for f in changed if f in suite_set}", "own = set()")'
}

# bats test_tags=mutation
@test "mutation: a change to how Bats runs is scoped" {
  mutant_goes_red 's.replace("        if f in INFRA:", "        if False:")'
}

# bats test_tags=mutation
@test "mutation: a change to the Bats job is scoped" {
  mutant_goes_red 's.replace("if a is None or b is None or a != b:", "if False:")'
}

# bats test_tags=mutation
@test "mutation: a checkout that is not a merge commit is scoped" {
  mutant_goes_red 's.replace("if len(parents) != 3:", "if len(parents) < 2:")'
}

# bats test_tags=mutation
@test "mutation: renames are folded, so the old name is lost" {
  mutant_goes_red 's.replace("\"--no-renames\", ", "\"-M\", ")'
}

# bats test_tags=mutation
@test "mutation: an unnamed helper beside the suites is scoped" {
  mutant_goes_red 's.replace("            if not mine:", "            if False:")'
}

# bats test_tags=mutation
@test "mutation: a failure selects nothing instead of everything" {
  mutant_goes_red 's.replace("return list(suites), f\"every suite ({len(suites)}): {e}\"", "return [], f\"every suite ({len(suites)}): {e}\"")'
}

# bats test_tags=mutation
@test "mutation: too many namers are followed anyway" {
  mutant_goes_red 's.replace("if len(hops) > HUB_LIMIT:", "if False:")'
}

# bats test_tags=mutation
@test "mutation: prose is followed" {
  mutant_goes_red 's.replace("DOC_RULE = True", "DOC_RULE = False")'
}

# bats test_tags=mutation
@test "mutation: part of a longer name counts as the name" {
  mutant_goes_red 's.replace("LEFT = r\"(^|[^A-Za-z0-9_.-])\"", "LEFT = r\"\"").replace("RIGHT = r\"($|[^A-Za-z0-9_-])\"", "RIGHT = r\"\"")'
}

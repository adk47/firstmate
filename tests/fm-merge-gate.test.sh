#!/usr/bin/env bash
# Tests for bin/fm-merge-gate-lib.sh and its wiring into bin/fm-pr-merge.sh and
# bin/fm-go-queue-run.sh.
#
# The defect these tests exist for is a gate that cannot fail: before this
# library, bin/fm-pr-merge.sh verified that a pull request was open, mergeable,
# and conflict-free, and then merged it without ever reading the review verdict.
# A NO-GO pull request merged exactly as easily as a GO one. So every refusal
# case below is written to fail against the ungated script: the gate has to
# refuse, name the reason, and leave the merge call unmade.
#
# Matrix:
#   (a) a qa-review NO-GO on the current head refuses
#   (b) an absent qa-review verdict refuses, because silence is not a GO
#   (c) a verdict recorded against an older head refuses on the current head
#   (d) any red check refuses, naming the check
#   (e) adk47's own credit-approval-guard red is the one standing allow
#   (f) the same red on anyone else's pull request refuses
#   (g) a master twin whose develop counterpart is unmerged refuses
#   (h) a master twin whose develop counterpart is merged passes
#   (i) a head that moved off the expected commit refuses
#   (j) an unreadable verdict refuses rather than merging blind
#   (k) a green head with a qa-review GO passes and reports what it verified
#   (l) an unattested red-check allow is rejected by the interface
#   (m) bin/fm-pr-merge.sh refuses before the merge call and records nothing
#       for every refusal case above, so the wiring itself is proven
#   (n) --override-gate records the reason, the operator, and the time, then
#       merges
#   (o) bin/fm-go-queue-run.sh merges only through the gate, and a refused row
#       is reported and skipped
#   (p) bin/fm-go-queue-run.sh --dry-run reports the decision without merging
#   (q) an unreadable twin list refuses rather than passing
#   (r) an unreadable twin PR referenced by the body refuses
#   (s) a repeated qa-review check reports its worst conclusion
#   (t) an unrelated issue reference is not read as a twin
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

GATE="$ROOT/bin/fm-merge-gate-lib.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
QUEUE_RUN="$ROOT/bin/fm-go-queue-run.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-gate-tests)

JQ_BIN=$(command -v jq) || fail "these tests read fixtures with the real jq, which was not found"

REPO=example/repo
HEAD=1111111111111111111111111111111111111111
OLD_HEAD=2222222222222222222222222222222222222222

# A fake gh that serves JSON fixtures through the real jq, so the gate's own
# --jq program is exercised rather than bypassed. Fixtures live in the case dir:
# pr-view.json, workflows.json, pr-list.json, pulls-<n>.json. A missing fixture
# is a failed read, which is how the unreadable-verdict case is built.
write_gh_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
jqprog=
prev=
for a in "$@"; do
  if [ "$prev" = --jq ]; then jqprog=$a; fi
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
serve() {
  [ -r "$1" ] || { echo "error: Not Found" >&2; exit 1; }
  if [ -n "$jqprog" ]; then jq -r "$jqprog" "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr)
    case "${2:-}" in
      view) serve "$FM_TEST_GH_FIXTURES/pr-view.json" ;;
      list) serve "$FM_TEST_GH_FIXTURES/pr-list.json" ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    path=${2:-}
    case "$path" in
      */contents/.github/workflows) serve "$FM_TEST_GH_FIXTURES/workflows.json" ;;
      */pulls/*) serve "$FM_TEST_GH_FIXTURES/pulls-${path##*/}.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# make_case <name>: a sandbox with a fakebin, a fixtures dir, and a task meta.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin" "$case_dir/fixtures" "$case_dir/state"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$case_dir/gh.log"
  write_gh_mock "$case_dir"
  printf '%s\n' "$case_dir"
}

# write_pr_view <case_dir> [<field>=<value> ...]
# A pull request payload that satisfies every gate condition, with the named
# fields overridden so one case drives exactly one refusal. checks= is a
# comma-separated list of name:conclusion pairs.
write_pr_view() {
  local case_dir=$1 kv key value
  local head=$HEAD author=someone base=develop headref=feature/x state=OPEN
  local merged_at=null body='Closes nothing.' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      head) head=$value ;;
      author) author=$value ;;
      base) base=$value ;;
      headref) headref=$value ;;
      state) state=$value ;;
      merged_at) merged_at=$value ;;
      body) body=$value ;;
      checks) checks=$value ;;
      *) fail "write_pr_view: unknown field '$key'" ;;
    esac
  done
  local rollup='' pair name conclusion
  local IFS=,
  for pair in $checks; do
    [ -n "$pair" ] || continue
    name=${pair%%:*}
    conclusion=${pair#*:}
    [ -n "$rollup" ] && rollup="$rollup,"
    rollup="$rollup{\"__typename\":\"CheckRun\",\"name\":\"$name\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"}"
  done
  unset IFS
  cat > "$case_dir/fixtures/pr-view.json" <<JSON
{
  "headRefOid": "$head",
  "author": {"login": "$author"},
  "baseRefName": "$base",
  "headRefName": "$headref",
  "state": "$state",
  "mergedAt": $merged_at,
  "body": "$body",
  "statusCheckRollup": [$rollup]
}
JSON
}

# write_workflows <case_dir> <name>...: the repository's workflow file names.
write_workflows() {
  local case_dir=$1 name first=true
  shift
  {
    printf '['
    for name in "$@"; do
      [ "$first" = true ] || printf ','
      first=false
      printf '{"name":"%s"}' "$name"
    done
    printf ']\n'
  } > "$case_dir/fixtures/workflows.json"
}

# write_pr_list <case_dir> <number> <base> <state> <mergedAt>: the pull requests
# on the same head branch, which is how a develop/beta twin is found.
write_pr_list() {
  local case_dir=$1 number=$2 base=$3 state=$4 merged_at=$5
  cat > "$case_dir/fixtures/pr-list.json" <<JSON
[{"number": $number, "baseRefName": "$base", "state": "$state", "mergedAt": $merged_at}]
JSON
}

# run_gate <case_dir> [args...]: run the gate in check-only mode.
run_gate() {
  local case_dir=$1 rc
  shift
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  PATH="$case_dir/fakebin:$PATH" \
    "$GATE" "$@" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  return "$rc"
}

# run_refusal_via_merge <case_dir> [args...]: drive the real merge entry point
# and prove the refusal leaves the forge merge call unmade.
run_refusal_via_merge() {
  local case_dir=$1
  shift
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" "$@"
}

# --- (a) a qa-review NO-GO on the current head refuses ----------------------

test_gate_refuses_qa_no_go() {
  local case_dir rc
  case_dir=$(make_case qa-no-go)
  write_workflows "$case_dir" qa-review.yml ci.yml
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a qa-review NO-GO must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the refusal must name the verdict and the head it was read on"
  assert_contains "$(cat "$case_dir/err")" "refusing to merge $REPO#9" \
    "the refusal must name the pull request"
  pass "a qa-review NO-GO on the current head refuses"
}

# --- (b) an absent verdict refuses -----------------------------------------

test_gate_refuses_absent_qa_verdict() {
  local case_dir rc
  case_dir=$(make_case qa-absent)
  write_workflows "$case_dir" qa-review.yml ci.yml
  write_pr_view "$case_dir" checks='unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an absent qa-review verdict must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "no qa-review verdict exists on head $HEAD" \
    "the refusal must say the verdict is absent, not that it passed"
  pass "an absent qa-review verdict refuses"
}

# --- (c) a verdict on an older head does not authorize a newer one ---------

test_gate_refuses_verdict_on_older_head() {
  local case_dir rc
  case_dir=$(make_case qa-stale-head)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  printf 'pr_head=%s\n' "$OLD_HEAD" >> "$case_dir/state/task-x1.meta"

  # The verdict was read on OLD_HEAD; the pull request is now at HEAD.
  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a verdict recorded against an older head must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the recorded head $OLD_HEAD is not the current head $HEAD" \
    "the refusal must name both heads so the stale verdict is visible"
  pass "a verdict recorded against an older head refuses"
}

# --- (d) any red check refuses ---------------------------------------------

test_gate_refuses_red_check() {
  local case_dir rc
  case_dir=$(make_case red-check)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:FAILURE'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a red check must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the check unit-tests is FAILURE on head $HEAD" \
    "the refusal must name the red check"
  pass "a red check refuses"
}

# --- (e) adk47's own credit-approval-guard is the standing allow -----------

test_gate_allows_adk47_credit_guard() {
  local case_dir rc
  case_dir=$(make_case adk47-credit-guard)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" author=adk47 \
    checks='qa-review:SUCCESS,credit-approval-guard:FAILURE'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "adk47's own credit-approval-guard red must not refuse"
  assert_contains "$(cat "$case_dir/out")" "allowed reds=credit-approval-guard" \
    "the pass must report the red it allowed"
  pass "adk47's own credit-approval-guard red is allowed"
}

# --- (f) the same red on anyone else refuses -------------------------------

test_gate_refuses_credit_guard_for_other_author() {
  local case_dir rc
  case_dir=$(make_case other-author-credit-guard)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" author=someone-else \
    checks='qa-review:SUCCESS,credit-approval-guard:FAILURE'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "the credit-approval-guard allow is adk47's alone"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the check credit-approval-guard is FAILURE" \
    "the refusal must name the check"
  pass "the credit-approval-guard red refuses for any other author"
}

# --- (g) an unmerged develop twin refuses ----------------------------------

test_gate_refuses_unmerged_develop_twin() {
  local case_dir rc
  case_dir=$(make_case unmerged-twin)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  write_pr_list "$case_dir" 12 develop OPEN null

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a master twin with an unmerged develop counterpart must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "pull request #12 targets develop and is not merged" \
    "the refusal must name the unmerged twin"
  pass "a master twin with an unmerged develop counterpart refuses"
}

# --- (h) a merged develop twin passes --------------------------------------

test_gate_allows_merged_develop_twin() {
  local case_dir rc
  case_dir=$(make_case merged-twin)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  write_pr_list "$case_dir" 12 develop MERGED '"2026-11-03T10:00:00Z"'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a merged develop twin must not refuse"
  pass "a master twin whose develop counterpart is merged passes"
}

# --- (i) a moved head refuses ----------------------------------------------

test_gate_refuses_moved_head() {
  local case_dir rc
  case_dir=$(make_case moved-head)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash --match-head-commit "$OLD_HEAD"
  rc=$?
  set -e
  expect_code 1 "$rc" "a head that moved off the expected commit must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "the head moved: expected $OLD_HEAD, the pull request is at $HEAD" \
    "the refusal must name both heads"
  pass "a head that moved off the expected commit refuses"
}

# --- (j) an unreadable verdict refuses -------------------------------------

test_gate_refuses_unreadable_verdict() {
  local case_dir rc
  case_dir=$(make_case unreadable)
  write_workflows "$case_dir" qa-review.yml
  # No pr-view.json: the read fails, and a failed read is not a GO.

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an unreadable verdict must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "could not be read" \
    "the refusal must say the read failed rather than implying a verdict"
  pass "an unreadable verdict refuses"
}

# --- (k) a green head with a GO passes -------------------------------------

test_gate_passes_green_with_qa_go() {
  local case_dir rc
  case_dir=$(make_case green)
  write_workflows "$case_dir" qa-review.yml ci.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS,lint:SKIPPED'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "a green head with a qa-review GO must pass"
  assert_contains "$(cat "$case_dir/out")" "authorized at head $HEAD" \
    "the pass must report the head it verified"
  assert_contains "$(cat "$case_dir/out")" "qa-review=SUCCESS" \
    "the pass must report the verdict it read"
  pass "a green head with a qa-review GO passes and reports what it verified"
}

# --- (l) an unattested red-check allow is rejected by the interface --------

test_gate_rejects_unrecorded_red_allow() {
  local case_dir rc
  case_dir=$(make_case unrecorded-red-allow)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,verify-twin-label:FAILURE'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD" --allow-red verify-twin-label
  rc=$?
  set -e
  expect_code 2 "$rc" "a bare --allow-red must be an unknown option, not an escape hatch"
  assert_contains "$(cat "$case_dir/err")" "unknown merge gate option: --allow-red" \
    "the refusal must name the unsupported option"
  pass "an unrecorded red-check allow is rejected"
}

# --- (q) an unreadable twin list refuses rather than passing ---------------

test_gate_refuses_unreadable_twin_list() {
  local case_dir rc
  case_dir=$(make_case unreadable-twin-list)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" base=master headref=feature/x \
    checks='qa-review:SUCCESS,unit-tests:SUCCESS'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a failed twin-list read must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "twin list could not be read" \
    "the refusal must say the twin state was unreadable"
  pass "an unreadable twin list refuses"
}

# --- (r) an unreadable twin referenced by the body refuses -----------------

test_gate_refuses_unreadable_body_twin() {
  local case_dir rc
  case_dir=$(make_case unreadable-body-twin)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='twin develop #42' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "an unreadable body-referenced twin must refuse"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "pull request #42 referenced by the body could not be read" \
    "the refusal must say the twin could not be read"
  pass "an unreadable body-referenced twin refuses"
}

# --- (s) a repeated qa-review check reports its worst conclusion -----------

test_gate_duplicate_qa_reports_worst_conclusion() {
  local case_dir rc
  case_dir=$(make_case duplicate-qa)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,qa-review:PENDING'

  set +e
  run_refusal_via_merge "$case_dir" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "a later pending duplicate must outrank an earlier success"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is PENDING" \
    "the refusal must report the worst duplicate conclusion"
  pass "a repeated qa-review check reports its worst conclusion"
}

# --- (t) an unrelated issue reference is not read as a twin ----------------

test_gate_ignores_unrelated_issue_reference() {
  local case_dir rc
  case_dir=$(make_case unrelated-issue)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" base=master headref=feature/x \
    body='Closes #7.' checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  printf '[]\n' > "$case_dir/fixtures/pr-list.json"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "an unrelated issue reference must not be treated as a twin"
  pass "an unrelated issue reference is not read as a twin"
}

# A backfill over past merges needs the verdict of a pull request that already
# merged, so --check-only evaluates it instead of short-circuiting.
test_gate_check_only_audits_a_merged_pull_request() {
  local case_dir rc
  case_dir=$(make_case check-only-merged)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" state=MERGED merged_at='"2026-11-03T12:00:00Z"' \
    checks='qa-review:FAILURE,unit-tests:SUCCESS'

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD"
  rc=$?
  set -e
  expect_code 0 "$rc" "an already-merged pull request must short-circuit without --check-only"

  set +e
  run_gate "$case_dir" "$REPO" 9 "$HEAD" --check-only
  rc=$?
  set -e
  expect_code 1 "$rc" "--check-only must evaluate a merged pull request's verdict"
  assert_contains "$(cat "$case_dir/err")" "the qa-review verdict on head $HEAD is FAILURE" \
    "--check-only must name the verdict it refused"
  pass "--check-only audits an already-merged pull request instead of short-circuiting"
}

# --- (m) fm-pr-merge.sh refuses before the merge call ----------------------

# A gh-axi mock that records every call, so a test can prove the merge call was
# never made.
write_gh_axi_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# The gh mock also has to answer the outcome read fm-pr-merge.sh makes after a
# merge, so a case that does merge can reach its verified result.
extend_gh_mock_for_outcome() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
jqprog=
prev=
for a in "$@"; do
  if [ "$prev" = --jq ]; then jqprog=$a; fi
  case "$a" in --jq=*) jqprog=${a#--jq=} ;; esac
  prev=$a
done
serve() {
  [ -r "$1" ] || { echo "error: Not Found" >&2; exit 1; }
  if [ -n "$jqprog" ]; then jq -r "$jqprog" "$1"; else cat "$1"; fi
}
case "${1:-}" in
  pr)
    case "${2:-}" in
      view)
        case " $* " in
          *statusCheckRollup*) serve "$FM_TEST_GH_FIXTURES/pr-view.json" ;;
          *headRefOid*) printf '%s\n' "$FM_TEST_GH_HEAD" ;;
          *) exit 1 ;;
        esac
        ;;
      list) serve "$FM_TEST_GH_FIXTURES/pr-list.json" ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    path=${2:-}
    case "$path" in
      graphql) cat "$FM_TEST_GH_OUTCOME" ;;
      */contents/.github/workflows) serve "$FM_TEST_GH_FIXTURES/workflows.json" ;;
      */pulls/*) serve "$FM_TEST_GH_FIXTURES/pulls-${path##*/}.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_TEST_GH_HEAD="$HEAD" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  return "$rc"
}

test_pr_merge_refuses_before_merge_call() {
  local case_dir rc
  case_dir=$(make_case pr-merge-refuses)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" -- --squash
  rc=$?
  set -e
  expect_code 1 "$rc" "fm-pr-merge.sh must refuse a NO-GO pull request"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must never be made"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the refusal must name the verdict"
  assert_no_grep "pr=" "$case_dir/state/task-x1.meta" \
    "a refused merge must not record pr="
  pass "fm-pr-merge.sh refuses before the merge call and records nothing"
}

# --- (n) --override-gate records the reason and merges ---------------------

test_pr_merge_override_records_and_merges() {
  local case_dir rc meta
  case_dir=$(make_case pr-merge-override)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=develop' \
    > "$case_dir/github-outcome"
  : > "$case_dir/gh-axi.log"
  meta="$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/$REPO/pull/9" \
    --override-gate "captain said merge it anyway" -- --squash
  rc=$?
  set -e
  expect_code 0 "$rc" "an overridden gate must let the merge proceed"
  assert_grep "pr merge" "$case_dir/gh-axi.log" "the merge call must be made"
  assert_grep "merge_gate_override=captain said merge it anyway" "$meta" \
    "the override reason must be recorded"
  assert_grep "merge_gate_override_by=" "$meta" "the operator must be recorded"
  assert_grep "merge_gate_override_at=" "$meta" "the time must be recorded"
  assert_contains "$(cat "$case_dir/err")" "the merge gate is overridden" \
    "the override must be announced, not silent"
  pass "--override-gate records the reason, the operator, and the time, then merges"
}

# --- (o) the queue merges only through the gate ---------------------------

test_go_queue_refuses_row_and_continues() {
  local case_dir rc queue
  case_dir=$(make_case go-queue)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:FAILURE,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"
  queue="$case_dir/queue.txt"
  printf '%s\n' "# task repo pr head method" \
    "task-x1 $REPO 9 $HEAD squash" > "$queue"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_TEST_GH_HEAD="$HEAD" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  PATH="$case_dir/fakebin:$PATH" \
    "$QUEUE_RUN" "$queue" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a refused row must make the queue exit non-zero"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "a refused row must never reach the merge call"
  assert_contains "$(cat "$case_dir/err")" "qa-review verdict on head $HEAD is FAILURE" \
    "the queue must surface the gate's own reason"
  assert_contains "$(cat "$case_dir/out")" "0 merged, 1 not merged" \
    "the queue must report the row as not merged"
  pass "the queue merges only through the gate, and a refused row is skipped"
}

# --- (p) --dry-run reports without merging --------------------------------

test_go_queue_dry_run_merges_nothing() {
  local case_dir rc queue
  case_dir=$(make_case go-queue-dry-run)
  write_workflows "$case_dir" qa-review.yml
  write_pr_view "$case_dir" checks='qa-review:SUCCESS,unit-tests:SUCCESS'
  write_gh_axi_mock "$case_dir"
  extend_gh_mock_for_outcome "$case_dir"
  : > "$case_dir/gh-axi.log"
  queue="$case_dir/queue.txt"
  printf '%s\n' "task-x1 $REPO 9 $HEAD squash" > "$queue"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_FIXTURES="$case_dir/fixtures" \
  FM_TEST_GH_HEAD="$HEAD" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  PATH="$case_dir/fakebin:$PATH" \
    "$QUEUE_RUN" "$queue" --dry-run >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "a dry run over an authorized row must succeed"
  assert_no_grep "pr merge" "$case_dir/gh-axi.log" "a dry run must never reach the merge call"
  assert_contains "$(cat "$case_dir/out")" "would merge" \
    "a dry run must report the decision it would have made"
  pass "--dry-run reports the decision without merging"
}

# A named test may be run alone, which is how the ungated-script proof in the
# pull request body was produced: each refusal case run against the script as it
# stood before this library existed.
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    "$name"
  done
  exit 0
fi

test_gate_refuses_qa_no_go
test_gate_refuses_absent_qa_verdict
test_gate_refuses_verdict_on_older_head
test_gate_refuses_red_check
test_gate_allows_adk47_credit_guard
test_gate_refuses_credit_guard_for_other_author
test_gate_refuses_unmerged_develop_twin
test_gate_allows_merged_develop_twin
test_gate_refuses_moved_head
test_gate_refuses_unreadable_verdict
test_gate_passes_green_with_qa_go
test_gate_rejects_unrecorded_red_allow
test_gate_check_only_audits_a_merged_pull_request
test_gate_refuses_unreadable_twin_list
test_gate_refuses_unreadable_body_twin
test_gate_duplicate_qa_reports_worst_conclusion
test_gate_ignores_unrelated_issue_reference
test_pr_merge_refuses_before_merge_call
test_pr_merge_override_records_and_merges
test_go_queue_refuses_row_and_continues
test_go_queue_dry_run_merges_nothing

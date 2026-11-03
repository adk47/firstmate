#!/usr/bin/env bash
# Tests for bin/fm-merge-queue.sh, the unattended merge queue: it decides from
# the live pull request whether a queued row may merge, hands the merge to
# bin/fm-pr-merge.sh, retires only terminal rows, keeps everything else queued,
# and appends exactly one durable line a day.
#
# Matrix:
#   (a) a green, QA-passed row merges through the merge entrypoint and retires
#   (b) a row whose head moved retires without any merge attempt
#   (c) a red check keeps the row queued and merges nothing
#   (d) a missing qa-review on the head keeps the row queued
#   (e) FM_MERGE_QUEUE_QA=optional waives the qa-review requirement
#   (f) a fenced label retires the row and merges nothing
#   (g) an already-merged pull request retires without a merge attempt
#   (h) a refused merge retires the row after its attempt budget
#   (i) a duplicate row is attempted once and leaves with its key
#   (j) an unreadable forge never spends the attempt budget
#   (k) a bare repository row with no owner stays queued as unusable
#   (l) the queue rewrite preserves comments, blank lines, and file mode
#   (m) --dry-run reports the plan and changes nothing
#   (n) the first run of a day appends one daily line and the next run does not
#   (o) status answers from records only, without any forge call
#   (p) unit prints a service and a timer bound to this home
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUEUE_SCRIPT="$ROOT/bin/fm-merge-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-queue-tests)

HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab

# make_case <name>: a home with a data/ queue, a merge entrypoint stub that logs
# its argv, and a fakebin holding the gh mock. Echoes the case directory.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/data" "$dir/bin" "$dir/state" "$dir/fakebin" "$dir/heads" "$dir/checks"
  cat >"$dir/bin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_MERGE_LOG"
if [ -n "${FM_TEST_MERGE_FAIL:-}" ]; then
  printf 'fm-pr-merge: %s\n' "$FM_TEST_MERGE_FAIL" >&2
  exit 3
fi
printf 'verified merge of %s\n' "$2"
SH
  chmod +x "$dir/bin/fm-pr-merge.sh"
  write_gh_mock "$dir" OPEN
  : >"$dir/merge.log"
  : >"$dir/gh.log"
  printf '%s\n' "$dir"
}

# write_gh_mock <dir> <state>: the forge mock. It answers the two reads the
# queue makes and records every invocation.
write_gh_mock() {
  local dir=$1 state=$2
  printf '%s\n' "$state" >"$dir/pr-state"
  cat >"$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FM_TEST_GH_LOG"
num=${3##*/}
state=$(cat "$FM_TEST_DIR/pr-state")
case "${1:-} ${2:-}" in
  "pr view")
    head=${FM_TEST_HEAD:-}
    if [ -f "$FM_TEST_DIR/heads/$num" ]; then
      head=$(cat "$FM_TEST_DIR/heads/$num")
    fi
    printf '%s\t%s\t%s\t%s\n' "$state" "$head" "${FM_TEST_LABELS:-}" "${FM_TEST_BODY:-}"
    ;;
  "pr checks")
    if [ -f "$FM_TEST_DIR/checks/$num" ]; then
      cat "$FM_TEST_DIR/checks/$num"
      exit 0
    fi
    [ -n "${FM_TEST_CHECKS:-}" ] || exit 1
    printf '%s\n' "$FM_TEST_CHECKS"
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/gh"
}

# run_queue <dir> [args...]: run the queue against one home.
run_queue() {
  local dir=$1
  shift
  FM_HOME="$dir" \
    FM_ROOT_OVERRIDE="$dir" \
    FM_MERGE_QUEUE_QA="${FM_MERGE_QUEUE_QA:-}" \
    FM_MERGE_QUEUE_MAX_ATTEMPTS="${FM_MERGE_QUEUE_MAX_ATTEMPTS:-}" \
    FM_TEST_MERGE_LOG="$dir/merge.log" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_DIR="$dir" \
    PATH="$dir/fakebin:$PATH" \
    "${QUEUE_SCRIPT}" "$@" 2>&1
}

queue_rows() {  # <dir>
  grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$1/data/go-queue.txt" 2>/dev/null || true
}

# A green head with its QA review posted, which is what every merge case needs.
green_head() {
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tpass'
}

clear_head() {
  unset FM_TEST_HEAD FM_TEST_CHECKS FM_TEST_LABELS FM_TEST_BODY FM_TEST_MERGE_FAIL
}

# --- (a) a ready row merges and retires ------------------------------------

case_a() {
  local dir out
  dir=$(make_case a)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  expect_code 0 "$?" "(a) run exits 0"
  assert_contains "$out" "merged widgets#12" "(a) the row reports a merge"
  assert_grep "task-a https://github.com/acme/widgets/pull/12 -- --squash --admin --match-head-commit $HEAD_A" \
    "$dir/merge.log" "(a) the merge goes through the entrypoint with the live head"
  expect_code 0 "$(queue_rows "$dir")" "(a) the merged row leaves the queue"
  assert_grep "merged" "$dir/state/merge-queue/ledger.tsv" "(a) the merge is in the ledger"
  clear_head
  pass "a ready row merges and retires"
}

# --- (b) a moved head retires without merging ------------------------------

case_b() {
  local dir out
  dir=$(make_case b)
  printf '# owner: acme\nwidgets 12 bbbbbbb task-a squash\n' >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "head moved" "(b) the moved head is reported"
  [ ! -s "$dir/merge.log" ] || fail "(b) a moved head must never reach the merge entrypoint"
  expect_code 0 "$(queue_rows "$dir")" "(b) the stale row leaves the queue"
  clear_head
  pass "a moved head retires without merging"
}

# --- (c) a red check keeps the row -----------------------------------------

case_c() {
  local dir out
  dir=$(make_case c)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'qa-review\tpass\nbuild\tfail'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "not green" "(c) the red check is reported"
  [ ! -s "$dir/merge.log" ] || fail "(c) a red head must never reach the merge entrypoint"
  expect_code 1 "$(queue_rows "$dir")" "(c) the row stays queued"
  clear_head
  pass "a red check keeps the row queued"
}

# --- (d) a missing qa-review keeps the row ---------------------------------

case_d() {
  local dir out
  dir=$(make_case d)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'build\tpass'
  out=$(run_queue "$dir" run)
  assert_contains "$out" "no qa-review on this head" "(d) the absent QA check is reported"
  [ ! -s "$dir/merge.log" ] || fail "(d) a head with no QA review must never merge"
  expect_code 1 "$(queue_rows "$dir")" "(d) the row stays queued"
  clear_head
  pass "a missing qa-review keeps the row queued"
}

# --- (e) the optional-QA home ---------------------------------------------

case_e() {
  local dir out
  dir=$(make_case e)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  export FM_TEST_HEAD=$HEAD_A
  export FM_TEST_CHECKS=$'build\tpass'
  export FM_MERGE_QUEUE_QA=optional
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_QA
  assert_contains "$out" "merged widgets#12" "(e) optional QA merges a green head"
  clear_head
  pass "optional QA waives the qa-review requirement"
}

# --- (f) a fenced label never merges --------------------------------------

case_f() {
  local dir out
  dir=$(make_case f)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_LABELS="money customer-copy"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "fenced for a decider" "(f) the fence is reported"
  [ ! -s "$dir/merge.log" ] || fail "(f) a fenced change must never reach the merge entrypoint"
  expect_code 0 "$(queue_rows "$dir")" "(f) the fenced row leaves the queue"
  clear_head
  pass "a fenced label retires the row without merging"
}

# --- (g) an already-merged pull request retires ----------------------------

case_g() {
  local dir out
  dir=$(make_case g)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  write_gh_mock "$dir" MERGED
  out=$(run_queue "$dir" run)
  assert_contains "$out" "already merged" "(g) the already-merged row is reported"
  [ ! -s "$dir/merge.log" ] || fail "(g) an already-merged pull request must not be merged again"
  expect_code 0 "$(queue_rows "$dir")" "(g) the already-merged row leaves the queue"
  clear_head
  pass "an already-merged pull request retires without merging"
}

# --- (h) a refused merge spends the attempt budget ------------------------

case_h() {
  local dir out
  dir=$(make_case h)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  export FM_TEST_MERGE_FAIL='pr= metadata missing'
  export FM_MERGE_QUEUE_MAX_ATTEMPTS=1
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_MAX_ATTEMPTS
  assert_contains "$out" "merge refused: fm-pr-merge: pr= metadata missing" \
    "(h) the entrypoint's own refusal is reported"
  assert_contains "$out" "after 1 failed merge attempt" "(h) the budget retires the row"
  expect_code 0 "$(queue_rows "$dir")" "(h) an exhausted row leaves the queue"
  clear_head
  pass "a refused merge retires the row after its attempt budget"
}

# --- (i) duplicate rows are attempted once --------------------------------

case_i() {
  local dir out attempts
  dir=$(make_case i)
  printf '# owner: acme\nwidgets 12 %s task-a squash\nwidgets 12 %s task-a squash\n' "$HEAD_A" "$HEAD_A" \
    >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  attempts=$(wc -l <"$dir/merge.log" | tr -d ' ')
  expect_code 1 "$attempts" "(i) a duplicate row is merged once"
  expect_code 0 "$(queue_rows "$dir")" "(i) the duplicate leaves with its key"
  assert_contains "$out" "merged widgets#12" "(i) the row reports the merge"
  clear_head
  pass "a duplicate row is attempted once"
}

# --- (j) an unreadable forge never spends the budget ---------------------

case_j() {
  local dir out
  dir=$(make_case j)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/fakebin/gh"
  chmod +x "$dir/fakebin/gh"
  export FM_MERGE_QUEUE_MAX_ATTEMPTS=1
  out=$(run_queue "$dir" run)
  unset FM_MERGE_QUEUE_MAX_ATTEMPTS
  assert_contains "$out" "forge did not answer" "(j) the failed read is reported"
  expect_code 1 "$(queue_rows "$dir")" "(j) a transient outage keeps the row queued"
  clear_head
  pass "an unreadable forge never spends the attempt budget"
}

# --- (k) an unusable row is kept, not deleted -----------------------------

case_k() {
  local dir out
  dir=$(make_case k)
  printf 'widgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  out=$(run_queue "$dir" run)
  assert_contains "$out" "no repository owner for widgets" "(k) the missing owner is reported"
  assert_contains "$out" "unusable" "(k) the row reads as unusable"
  expect_code 1 "$(queue_rows "$dir")" "(k) a configuration mistake never deletes a row"
  [ ! -s "$dir/merge.log" ] || fail "(k) an unusable row must not reach the merge entrypoint"
  clear_head
  pass "a bare repository row with no owner stays queued"
}

# --- (l) the rewrite preserves the rest of the file ----------------------

case_l() {
  local dir out
  dir=$(make_case l)
  printf '# owner: acme\n# a note from the captain\n\nwidgets 12 %s task-a squash\n\nwidgets 13 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab task-b squash\n' \
    "$HEAD_A" >"$dir/data/go-queue.txt"
  chmod 0640 "$dir/data/go-queue.txt"
  printf 'qa-review\tpass\nbuild\tfail\n' >"$dir/checks/13"
  green_head
  out=$(run_queue "$dir" run)
  assert_grep "# a note from the captain" "$dir/data/go-queue.txt" "(l) comments survive the rewrite"
  assert_grep "# owner: acme" "$dir/data/go-queue.txt" "(l) the owner directive survives"
  assert_grep "widgets 13 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab task-b squash" "$dir/data/go-queue.txt" "(l) untouched rows survive"
  assert_no_grep "widgets 12" "$dir/data/go-queue.txt" "(l) the retired row is gone"
  assert_contains "$out" "run: merged 1" "(l) one merge is reported"
  expect_code 640 "$(stat -c %a "$dir/data/go-queue.txt" 2>/dev/null || stat -f %Lp "$dir/data/go-queue.txt")" \
    "(l) the queue file keeps its mode"
  clear_head
  pass "the queue rewrite preserves comments, blank lines, and mode"
}

# --- (m) dry run changes nothing -----------------------------------------

case_m() {
  local dir out before
  dir=$(make_case m)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  before=$(cat "$dir/data/go-queue.txt")
  green_head
  out=$(run_queue "$dir" run --dry-run)
  assert_contains "$out" "merge widgets#12" "(m) the dry run names the merge it would make"
  assert_contains "$out" "nothing changed" "(m) the dry run says it changed nothing"
  [ ! -s "$dir/merge.log" ] || fail "(m) a dry run must not merge"
  [ "$before" = "$(cat "$dir/data/go-queue.txt")" ] || fail "(m) a dry run must not rewrite the queue"
  assert_absent "$dir/state/merge-queue/ledger.tsv" "(m) a dry run writes no ledger"
  assert_absent "$dir/state/.wake-queue" "(m) a dry run appends no wake"
  clear_head
  pass "dry run reports the plan and changes nothing"
}

# --- (n) one daily line per day ------------------------------------------

case_n() {
  local dir out lines
  dir=$(make_case n)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  out=$(run_queue "$dir" run)
  assert_contains "$out" "summary: check: merge queue" "(n) the first run of the day emits the daily line"
  assert_grep "merged 1 (widgets#12)" "$dir/state/.wake-queue" "(n) the daily line counts the merge"
  lines=$(wc -l <"$dir/state/.wake-queue" | tr -d ' ')
  expect_code 1 "$lines" "(n) exactly one line is queued"
  out=$(run_queue "$dir" run)
  assert_not_contains "$out" "summary:" "(n) a later run the same day emits nothing"
  expect_code 1 "$(wc -l <"$dir/state/.wake-queue" | tr -d ' ')" "(n) the queue still holds one line"
  clear_head
  pass "the queue appends one line a day"
}

# --- (o) status reads records only ---------------------------------------

case_o() {
  local dir out
  dir=$(make_case o)
  printf '# owner: acme\nwidgets 12 %s task-a squash\n' "$HEAD_A" >"$dir/data/go-queue.txt"
  green_head
  run_queue "$dir" run >/dev/null
  : >"$dir/gh.log"
  out=$(run_queue "$dir" status)
  assert_contains "$out" "merge queue: 0 row(s)" "(o) status reports the queue size"
  assert_contains "$out" "merged 1" "(o) status reports the last run"
  [ ! -s "$dir/gh.log" ] || fail "(o) status must make no forge call"
  clear_head
  pass "status answers from records only"
}

# --- (p) the units name this home and this script ------------------------

case_p() {
  local dir service timer
  dir=$(make_case p)
  service=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "${QUEUE_SCRIPT}" unit service)
  timer=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "${QUEUE_SCRIPT}" unit timer)
  assert_contains "$service" "ExecStart=$ROOT/bin/fm-merge-queue.sh run" "(p) the service runs this script"
  assert_contains "$service" "Environment=FM_HOME=$dir" "(p) the service names this home"
  assert_contains "$timer" "OnUnitActiveSec=10min" "(p) the timer runs every ten minutes"
  assert_contains "$timer" "Unit=fm-merge-queue.service" "(p) the timer drives the service"
  pass "unit prints a service and a timer bound to this home"
}

case_a
case_b
case_c
case_d
case_e
case_f
case_g
case_h
case_i
case_j
case_k
case_l
case_m
case_n
case_o
case_p

printf 'ok - fm-merge-queue suite complete\n'

#!/usr/bin/env bash
# tests/ak47-budget.test.sh - the budget table and the board it renders.
#
# The budget is the definition of "humming". If it can load a row with no reason,
# or a row whose direction is misspelled, then the board is describing a box
# nobody agreed on. These tests are about that contract, not about the numbers.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/ak47/status.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-budget-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state"

# --- the shipped table ----------------------------------------------------------

test_the_shipped_budget_loads() {
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print >/dev/null 2>&1 \
    || fail "the shipped budget.conf does not load"
  pass "the shipped budget.conf loads"
}

test_every_shipped_row_carries_a_reason() {
  local key ceil dir _unit reason n=0
  while IFS='|' read -r key ceil dir _unit reason; do
    case "$key" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    [ -n "${reason:-}" ] || fail "budget row $key has no reason"
    [ "${#reason}" -ge 20 ] || fail "budget row $key's reason is too short to defend: $reason"
  done <"$ROOT/ak47/budget.conf"
  [ "$n" -ge 8 ] || fail "the shipped budget has only $n rows; expected at least 8"
  pass "every shipped budget row carries a reason a reader can defend"
}

test_every_shipped_row_has_a_numeric_ceiling() {
  local key ceil dir _unit reason
  while IFS='|' read -r key ceil dir _unit reason; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$ceil" in ''|*[!0-9]*) fail "budget row $key has a non-numeric ceiling: $ceil" ;; esac
    case "$dir" in max|min) : ;; *) fail "budget row $key has direction '$dir'; expected max or min" ;; esac
  done <"$ROOT/ak47/budget.conf"
  pass "every shipped budget row has a numeric ceiling and a max/min direction"
}

# --- the refusals ---------------------------------------------------------------

test_refuses_a_row_with_no_reason() {
  local b=$SANDBOX/budget.noreason
  printf 'load15|32|max|load\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with no reason"
  fi
  pass "status.sh refuses a budget row with no reason"
}

test_refuses_a_row_with_a_bad_direction() {
  local b=$SANDBOX/budget.baddir
  printf 'load15|32|sideways|load|a reason long enough to be defensible\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with direction 'sideways'"
  fi
  pass "status.sh refuses a budget row whose direction is not max or min"
}

test_refuses_a_row_with_a_non_numeric_ceiling() {
  local b=$SANDBOX/budget.badceil
  printf 'load15|lots|max|load|a reason long enough to be defensible\n' >"$b"
  if AK47_BUDGET=$b "$STATUS" --print >/dev/null 2>&1; then
    fail "status.sh accepted a budget row with a non-numeric ceiling"
  fi
  pass "status.sh refuses a budget row with a non-numeric ceiling"
}

# --- the board ------------------------------------------------------------------

test_the_board_puts_the_verdict_first() {
  local out
  out=$(AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print 2>/dev/null) \
    || fail "status.sh --print failed"
  local first
  first=$(printf '%s\n' "$out" | head -n 1)
  case "$first" in
    *VERDICT*) : ;;
    *) fail "the board's first line is not the verdict: $first" ;;
  esac
  pass "the board puts the verdict on the first line, so it reads in five seconds"
}

test_the_board_names_every_budget_metric() {
  local out key
  out=$(AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print 2>/dev/null) \
    || fail "status.sh --print failed"
  while IFS='|' read -r key _; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$out" in
      *"$key"*) : ;;
      *) fail "the board does not name the budget metric $key" ;;
    esac
  done <"$ROOT/ak47/budget.conf"
  pass "the board names every metric the budget defines"
}

test_the_board_writes_status_md() {
  rm -f "$AK47_STATE/status.md"
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" >/dev/null 2>&1 \
    || fail "status.sh failed"
  [ -s "$AK47_STATE/status.md" ] || fail "status.sh did not write status.md"
  pass "status.sh writes the board to status.md"
}

test_no_write_leaves_the_board_alone() {
  printf 'sentinel\n' >"$AK47_STATE/status.md"
  AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --no-write >/dev/null 2>&1 \
    || fail "status.sh --no-write failed"
  local got
  got=$(cat "$AK47_STATE/status.md")
  [ "$got" = sentinel ] || fail "--no-write overwrote status.md"
  pass "--no-write leaves the board on disk alone"
}

# --- the task cap -----------------------------------------------------------------
# 2026-11-14: the uid reached pids.max and every fork failed for five hours. The
# number that would have warned is a percentage of that cap, so it has to be
# arithmetic this suite can prove without editing the running box.

. "$ROOT/ak47/lib/common.sh"

fake_slice() {  # fake_slice <current> <max>
  local d=$SANDBOX/slice.$$
  mkdir -p "$d" || return 1
  printf '%s\n' "$1" >"$d/pids.current"
  printf '%s\n' "$2" >"$d/pids.max"
  printf '%s' "$d"
}

test_pids_pct_is_the_share_of_the_cap() {
  AK47_USER_SLICE=$(fake_slice 6000 12000)
  local got; got=$(ak47_pids_pct)
  [ "$got" = 50 ] || fail "6000 of 12000 tasks should be 50%, got '$got'"
  AK47_USER_SLICE=$(fake_slice 12000 12000)
  got=$(ak47_pids_pct)
  [ "$got" = 100 ] || fail "a full cap should read 100%, got '$got'"
  pass "ak47_pids_pct reports tasks as a percentage of the cap"
}

test_pids_pct_refuses_to_score_an_uncapped_manager() {
  AK47_USER_SLICE=$(fake_slice 400 400)
  printf 'max\n' >"$AK47_USER_SLICE/pids.max"
  local got; got=$(ak47_pids_pct)
  # "max" is no cap at all: 0 is the honest answer, not a made-up 100%.
  [ "$got" = 0 ] || fail "an uncapped manager should report 0, got '$got'"
  pass "ak47_pids_pct does not invent a percentage for an uncapped manager"
}

test_pids_pct_reports_nothing_when_the_cgroup_is_unreadable() {
  AK47_USER_SLICE=$SANDBOX/does-not-exist
  ak47_pids_pct >/dev/null 2>&1 \
    && fail "an unreadable cgroup produced a number instead of failing"
  pass "an unreadable cgroup yields no value, so the budget row is skipped not scored"
}

test_the_shipped_budget_watches_the_task_cap() {
  local rows key ceil dir _unit _reason found=0 out
  rows=$(AK47_BUDGET=$ROOT/ak47/budget.conf ak47_budget_rows) \
    || fail "ak47_budget_rows rejected the shipped budget"
  while IFS=$'\t' read -r key ceil dir _unit _reason; do
    [ "$key" = pids_pct ] || continue
    found=1
    [ "$ceil" = 80 ] \
      || fail "the pids_pct ceiling is '$ceil'; the 2026-11-14 alert is fixed at 80%"
    [ "$dir" = max ] \
      || fail "the pids_pct row direction is '$dir'; a full cap is a breach above the ceiling"
  done <<<"$rows"
  [ "$found" = 1 ] \
    || fail "the shipped budget has no pids_pct row; the 2026-11-14 starvation would be unwatched"
  out=$(AK47_BUDGET=$ROOT/ak47/budget.conf "$STATUS" --print 2>/dev/null) \
    || fail "status.sh --print failed"
  case "$out" in
    *pids_pct*) : ;;
    *) fail "the board does not name pids_pct, so the task cap is unwatched" ;;
  esac
  pass "the shipped budget watches the user task cap at 80% and the board names it"
}

# --- the task-cap page ------------------------------------------------------------
# The pids_pct row is only worth sampling if the page it raises names the lanes
# holding the tasks. On 2026-11-14 the holders were transient tmux pane scopes
# under app.slice, and the page named the aggregate app.slice instead, so the
# captain could not see the lane that grew. These run the shipped ak47-health.sh
# against a fixture cgroup tree shaped like the real one, with the ambient probes
# stubbed so the result does not depend on this box's current load or swap.

HEALTH=$ROOT/ak47/hdevops/ansible/playbooks/templates/ak47-health.sh
STUBS=$SANDBOX/stubs
mkdir -p "$STUBS"
cat >"$STUBS/pgrep" <<'EOF'
#!/bin/sh
case " $* " in *" -c "*) echo 0; exit 0 ;; esac
exit 1
EOF
printf '#!/bin/sh\nprintf "1\\t/tmp\\n"\n' >"$STUBS/du"
for c in sensors sudo systemctl notify-send; do printf '#!/bin/sh\nexit 0\n' >"$STUBS/$c"; done
chmod +x "$STUBS"/*

# task_slice <dir> <current> <max> - the real hierarchy: aggregate *.slice above
# the transient pane scopes, so a leaf-blind reader can only report the aggregate.
task_slice() {
  local d=$1
  mkdir -p "$d/app.slice/tmux-spawn-c2f9b92f.scope" \
           "$d/app.slice/tmux-spawn-b4f3563c.scope" \
           "$d/app.slice/ak47-health.service" \
           "$d/session.slice" || return 1
  printf '%s\n' "$2" >"$d/pids.current"
  printf '%s\n' "$3" >"$d/pids.max"
  printf '9000\n' >"$d/app.slice/pids.current"
  printf '8000\n' >"$d/app.slice/tmux-spawn-c2f9b92f.scope/pids.current"
  printf '900\n' >"$d/app.slice/tmux-spawn-b4f3563c.scope/pids.current"
  printf '3\n' >"$d/app.slice/ak47-health.service/pids.current"
  printf '500\n' >"$d/session.slice/pids.current"
}

# run_health <name> <slice> - one real health run in its own HOME, and print the
# state directory it wrote. Ambient pages (load, swap, RAM) are pushed out of
# reach so the only thing that can page is the task cap under test.
run_health() {
  local home=$SANDBOX/home.$1 fm=$SANDBOX/fmhome.$1
  mkdir -p "$home" "$fm/bin"
  printf '#!/bin/sh\nexit 0\n' >"$fm/bin/fm-inbox.sh"; chmod +x "$fm/bin/fm-inbox.sh"
  HOME=$home PATH=$STUBS:$PATH FM_HOME=$fm AK47_USER_SLICE=$2 \
    AK47_PAGE_SWAP_PCT=101 AK47_PAGE_MEM_AVAIL_GB=0 AK47_PAGE_LOAD15=100000 \
    bash "$HEALTH" >/dev/null 2>&1 \
    || fail "ak47-health.sh did not complete against a fixture cgroup"
  printf '%s' "$home/.local/state/ak47"
}

test_the_task_cap_page_names_the_scopes_holding_the_tasks() {
  local slice=$SANDBOX/slice.page sd page latest
  task_slice "$slice" 10000 12000 || fail "could not build the fixture cgroup tree"
  sd=$(run_health page "$slice")
  page=$sd/page-latest.md
  [ -f "$page" ] || fail "83% of the cap raised no page"
  grep -q '83% used (10000 of 12000 tasks' "$page" \
    || fail "the page does not state the task share: $(cat "$page")"
  grep -q 'app.slice/tmux-spawn-c2f9b92f(8000)' "$page" \
    || fail "the page does not name the scope holding 8000 tasks: $(cat "$page")"
  grep -q 'app.slice(9000)' "$page" \
    && fail "the page names the aggregate app.slice instead of the scopes holding its tasks"
  latest=$sd/tasks-latest.md
  [ -f "$latest" ] || fail "the page wrote no tasks-latest.md to name the lane"
  grep -q 'tmux-spawn-c2f9b92f.scope' "$latest" \
    || fail "tasks-latest.md does not list the leaf scope: $(cat "$latest")"
  grep -q '^8000' "$latest" \
    || fail "tasks-latest.md does not carry the leaf scope's task count: $(cat "$latest")"
  grep -q 'pids=10000/12000' "$sd/samples.log" \
    || fail "the sample log does not record the task cap, so no trend can be seen"
  pass "the task-cap page names the leaf scopes holding the tasks, not the aggregate slice"
}

test_the_task_cap_page_stays_quiet_below_the_ceiling() {
  local slice=$SANDBOX/slice.quiet sd
  task_slice "$slice" 9000 12000 || fail "could not build the fixture cgroup tree"
  sd=$(run_health quiet "$slice")
  [ -f "$sd/page-latest.md" ] \
    && fail "75% of the cap paged; the alert belongs at 80%: $(cat "$sd/page-latest.md")"
  [ -f "$sd/tasks-latest.md" ] \
    && fail "75% of the cap wrote a task-cap report; the page is the 80% trigger"
  pass "75% of the task cap is recorded without paging, so the alert keeps its meaning"
}

test_an_uncapped_manager_never_pages() {
  local slice=$SANDBOX/slice.max sd
  task_slice "$slice" 400 400 || fail "could not build the fixture cgroup tree"
  printf 'max\n' >"$slice/pids.max"
  sd=$(run_health uncapped "$slice") \
    || fail "an uncapped manager made the health check divide by zero"
  [ -f "$sd/page-latest.md" ] \
    && fail "an uncapped manager paged a task share it cannot measure"
  pass "an uncapped user manager is sampled without a division or a false page"
}

test_the_shipped_budget_loads
test_every_shipped_row_carries_a_reason
test_every_shipped_row_has_a_numeric_ceiling
test_refuses_a_row_with_no_reason
test_refuses_a_row_with_a_bad_direction
test_refuses_a_row_with_a_non_numeric_ceiling
test_the_board_puts_the_verdict_first
test_the_board_names_every_budget_metric
test_the_board_writes_status_md
test_no_write_leaves_the_board_alone
test_pids_pct_is_the_share_of_the_cap
test_pids_pct_refuses_to_score_an_uncapped_manager
test_pids_pct_reports_nothing_when_the_cgroup_is_unreadable
test_the_shipped_budget_watches_the_task_cap
test_the_task_cap_page_names_the_scopes_holding_the_tasks
test_the_task_cap_page_stays_quiet_below_the_ceiling
test_an_uncapped_manager_never_pages

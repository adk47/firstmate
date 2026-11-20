#!/usr/bin/env bash
# tests/fm-unowned.test.sh - the alarm for work that exists only as a note
# (bin/fm-unowned.sh): an in-flight backlog item with no task record is
# UNOWNED, a task whose latest status claims work under way while its endpoint
# is dead is NO-LANE, a latest done claim whose PR is still open is STALE-DONE,
# a historical verb never grades a task, a queued or
# held item is never an alarm, a stopped task is never a missing lane, a forge
# that cannot answer is skipped rather than reported, a backlog listing the
# tool refuses is exit 2 on stderr rather than silence, and a fully owned
# fleet prints nothing and exits 0.
#
# Everything is a fixture: a throwaway home with its own fake fm-crew-state.sh
# (handed to the script as FM_CREW_STATE_BIN), and fake `tasks-axi` and `gh` on
# PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNOWNED="$ROOT/bin/fm-unowned.sh"
TMP_ROOT=$(fm_test_tmproot fm-unowned)

# A home with a backlog file, a fake tasks-axi that answers each --state from
# $home/backlog.<state> (one id per line), a fake fm-crew-state.sh that answers
# from $home/crew.<id> (first line), and a fake gh that answers from
# $home/pr.<number>.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/bin" "$home/fakebin"
  : > "$home/data/backlog.md"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# tasks-axi list --file <path> --state <state>
[ "$1" = list ] || { echo "fake tasks-axi: unexpected $*" >&2; exit 9; }
printf '%s\n' "$*" >> "$FM_FAKE_HOME/tasks.log"
shift
state=
while [ $# -gt 0 ]; do
  case "$1" in
    --state) state=$2; shift 2 ;;
    --file) shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$FM_FAKE_HOME/refuse" ] && { echo 'error: "--state must be one of queued, in_flight, done, held"'; echo 'code: VALIDATION_ERROR'; exit 1; }
f="$FM_FAKE_HOME/backlog.$state"
n=0; [ -f "$f" ] && n=$(grep -c . "$f")
[ -f "$FM_FAKE_HOME/lie-count" ] && n=$((n + 1))
printf 'count: %s\n' "$n"
printf 'tasks[%s]{id,state,kind,repo,title}:\n' "$n"
[ -f "$f" ] && while IFS= read -r id; do
  [ -n "$id" ] || continue
  printf '  %s,%s,ship,"-","%s title"\n' "$id" "$state" "$id"
done < "$f"
exit 0
SH
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view <num> --repo <repo> --json state --jq .state
printf '%s\n' "$*" >> "$FM_FAKE_HOME/gh.log"
f="$FM_FAKE_HOME/pr.$3"
[ -f "$f" ] || exit 1
cat "$f"
SH
  cat > "$home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
f="$FM_HOME/crew.$1"
[ -f "$f" ] || { echo "unknown" >&2; exit 1; }
head -n 1 "$f"
SH
  chmod 700 "$home/fakebin/tasks-axi" "$home/fakebin/gh" "$home/bin/fm-crew-state.sh"
  printf '%s' "$home"
}

run_unowned() {  # <home> -> sets $RC and $OUT; stderr in $home/err
  local home=$1
  RC=0
  FM_HOME="$home" FM_FAKE_HOME="$home" FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" \
    PATH="$home/fakebin:$PATH" \
    "$UNOWNED" > "$home/out" 2> "$home/err" || RC=$?
  OUT=$(cat "$home/out")
}

add_task() {  # <home> <id> <status-line> [crew-state]
  local home=$1 id=$2 line=$3 crew=${4:-}
  printf 'window=firstmate:fm-%s\n' "$id" > "$home/state/$id.meta"
  printf '%s\n' "$line" >> "$home/state/$id.status"
  [ -z "$crew" ] || printf '%s\n' "$crew" > "$home/crew.$id"
}

test_owned_fleet_is_silent() {
  local home out
  home=$(make_home owned)
  printf 'alpha\n' > "$home/backlog.in_flight"
  printf 'queued-one\nqueued-two\n' > "$home/backlog.queued"
  printf 'held-one\n' > "$home/backlog.held"
  add_task "$home" alpha "working: on it" "alpha run-step=working alive"
  add_task "$home" beta "done: PR https://github.com/acme/widget/pull/7 checks green"
  printf 'MERGED\n' > "$home/pr.7"
  run_unowned "$home"; out=$OUT
  [ -z "$out" ] || fail "an owned fleet must print nothing, got: $out"
  [ "$RC" = 0 ] || fail "an owned fleet exits 0, got $RC"
  [ ! -s "$home/err" ] || fail "an owned fleet writes nothing to stderr: $(cat "$home/err")"
  pass "a fully owned fleet prints nothing and exits 0"
}

test_in_flight_without_record_is_unowned() {
  local home out
  home=$(make_home unowned)
  printf 'ghost\nghost_item.v2\nUPPER.Case_1\nalpha\n' > "$home/backlog.in_flight"
  add_task "$home" alpha "working: on it" "alpha run-step=working alive"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 1 ] || fail "an unowned item exits 1, got $RC"
  printf '%s\n' "$out" | grep -q '^UNOWNED ghost ' || fail "ghost must be UNOWNED, got: $out"
  printf '%s\n' "$out" | grep -q '^UNOWNED ghost_item\.v2 ' \
    || fail "an id with _ and . is still read and UNOWNED, got: $out"
  printf '%s\n' "$out" | grep -q '^UNOWNED UPPER\.Case_1 ' \
    || fail "an id with uppercase is still read and UNOWNED, got: $out"
  ! printf '%s\n' "$out" | grep -q 'alpha' || fail "alpha has a record and must not be reported: $out"
  pass "an in-flight backlog item with no task record is UNOWNED, whatever legal id charset it uses"
}

test_held_in_flight_item_is_not_unowned() {
  local home out
  home=$(make_home heldinflight)
  printf 'held-inflight\n' > "$home/backlog.in_flight"
  printf 'held-inflight\n' > "$home/backlog.held"
  run_unowned "$home"; out=$OUT
  [ -z "$out" ] || fail "a held item has no missing lane, got: $out"
  [ "$RC" = 0 ] || fail "exit 0 expected, got $RC"
  pass "a held in-flight item with no task record is the captain's, not UNOWNED"
}

test_queued_and_held_are_not_alarms() {
  local home out
  home=$(make_home queue)
  printf 'queued-fix\n' > "$home/backlog.queued"
  printf 'held-call\n' > "$home/backlog.held"
  run_unowned "$home"; out=$OUT
  [ -z "$out" ] || fail "queued and held items are not alarms, got: $out"
  [ "$RC" = 0 ] || fail "exit 0 expected, got $RC"
  pass "a queued item is the queue and a held item is the captain's, neither is reported"
}

test_dead_endpoint_under_working_claim_is_no_lane() {
  local home out
  home=$(make_home nolane)
  add_task "$home" dead-one "working: half way" "dead-one dead"
  add_task "$home" dead-two "working: still going" "dead-two dead no agent process in worktree"
  add_task "$home" alive "working: fine" "alive run-step=working"
  add_task "$home" finished "done: shipped" "finished dead"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 1 ] || fail "a dead lane exits 1, got $RC"
  printf '%s\n' "$out" | grep -q "^NO-LANE dead-one its latest status says 'working'" || fail "dead-one must be NO-LANE: $out"
  printf '%s\n' "$out" | grep -q "^NO-LANE dead-two its latest status says 'working'" || fail "dead-two must be NO-LANE: $out"
  ! printf '%s\n' "$out" | grep -q 'alive' || fail "a live endpoint is not reported: $out"
  ! printf '%s\n' "$out" | grep -q 'finished' || fail "a finished task with no working claim is not a missing lane: $out"
  pass "a dead endpoint under a working claim is NO-LANE"
}

test_state_and_data_overrides_are_honoured() {
  local home out altstate altdata
  home=$(make_home overrides)
  altstate="$home/altstate"
  altdata="$home/altdata"
  mkdir -p "$altstate" "$altdata"
  : > "$altdata/backlog.md"
  printf 'ghost_override.v1\n' > "$home/backlog.in_flight"
  printf 'window=firstmate:fm-override\n' > "$altstate/override.meta"
  printf 'working: implementing\n' > "$altstate/override.status"
  printf 'override dead\n' > "$home/crew.override"
  RC=0
  FM_HOME="$home" FM_FAKE_HOME="$home" FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" \
    FM_STATE_OVERRIDE="$altstate" FM_DATA_OVERRIDE="$altdata" PATH="$home/fakebin:$PATH" \
    "$UNOWNED" > "$home/out" 2> "$home/err" || RC=$?
  out=$(cat "$home/out")
  [ "$RC" = 1 ] || fail "the override directories are read, got $RC: $(cat "$home/err")"
  printf '%s\n' "$out" | grep -q '^UNOWNED ghost_override.v1 ' || fail "the override backlog is read: $out"
  printf '%s\n' "$out" | grep -q "^NO-LANE override its latest status says 'working'" || fail "the override state directory is read: $out"
  grep -qF -- "--file $altdata/backlog.md" "$home/tasks.log" || fail "the override data directory is read: $(cat "$home/tasks.log")"
  pass "FM_STATE_OVERRIDE and FM_DATA_OVERRIDE are honoured"
}

test_grades_off_the_latest_status_line() {
  local home out
  home=$(make_home graded)
  add_task "$home" worked-then-done "working: implementing" "worked-then-done dead"
  printf 'done: shipped, checks green\n' >> "$home/state/worked-then-done.status"
  add_task "$home" resumed "done: PR https://github.com/acme/widget/pull/61" "resumed run-step=working"
  printf 'OPEN\n' > "$home/pr.61"
  printf 'working: resumed after a captain answer\n' >> "$home/state/resumed.status"
  add_task "$home" resumed-dead "done: PR https://github.com/acme/widget/pull/62" "resumed-dead dead"
  printf 'OPEN\n' > "$home/pr.62"
  printf 'working: resumed and then the pane died\n' >> "$home/state/resumed-dead.status"
  add_task "$home" swept-dead "working: implementing" "swept-dead dead"
  printf 'resolved [key=k]: auto-closed by sweep (no-process-48h)\n' >> "$home/state/swept-dead.status"
  add_task "$home" swept-done "done: PR https://github.com/acme/widget/pull/63" "swept-done dead"
  printf 'OPEN\n' > "$home/pr.63"
  printf 'resolved [key=k]: auto-closed by sweep (no-process-48h)\n' >> "$home/state/swept-done.status"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 1 ] || fail "the still-working dead lane exits 1, got $RC"
  ! printf '%s\n' "$out" | grep -q 'worked-then-done' \
    || fail "a task that finished after working is not NO-LANE: $out"
  ! printf '%s\n' "$out" | grep -q 'STALE-DONE resumed ' \
    || fail "a resumed task is not STALE-DONE off its old done line: $out"
  ! printf '%s\n' "$out" | grep -q 'STALE-DONE resumed-dead ' \
    || fail "a resumed task's old PR is not reported, its live claim is: $out"
  printf '%s\n' "$out" | grep -q "^NO-LANE resumed-dead its latest status says 'working'" \
    || fail "a resumed task whose endpoint then died is NO-LANE: $out"
  printf '%s\n' "$out" | grep -q "^NO-LANE swept-dead its latest status says 'working'" \
    || fail "a working claim closed by the decisions sweep is still NO-LANE when the endpoint is dead: $out"
  ! printf '%s\n' "$out" | grep -q 'NO-LANE swept-done' \
    || fail "a done line behind the sweep close is not NO-LANE: $out"
  printf '%s\n' "$out" | grep -q '^STALE-DONE swept-done claims done but https://github.com/acme/widget/pull/63 is still OPEN$' \
    || fail "a done claim behind the sweep close still grades done: $out"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] || fail "only the live claims are reported, got: $out"
  pass "every task is graded off its latest claim line, never a historical verb or a sweep close"
}

test_bounded_reads_do_not_need_a_timeout_binary() {
  local home out
  home=$(make_home notimeout)
  add_task "$home" dead-one "working: half way" "dead-one dead"
  add_task "$home" claimed "done: PR https://github.com/acme/widget/pull/71"
  printf 'OPEN\n' > "$home/pr.71"
  RC=0
  FM_HOME="$home" FM_FAKE_HOME="$home" FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" \
    FM_TIMEOUT_MECHANISM_OVERRIDE=bash PATH="$home/fakebin:$PATH" \
    "$UNOWNED" > "$home/out" 2> "$home/err" || RC=$?
  out=$(cat "$home/out")
  [ "$RC" = 1 ] || fail "the alarms still fire without a timeout binary, got $RC: $(cat "$home/err")"
  printf '%s\n' "$out" | grep -q "^NO-LANE dead-one " || fail "a dead working lane is still NO-LANE: $out"
  printf '%s\n' "$out" | grep -q '^STALE-DONE claimed ' || fail "an open PR is still STALE-DONE: $out"
  pass "both bounded reads degrade to a working mechanism, never to a false-clean"
}

test_stopped_task_and_unreadable_state_are_skipped() {
  local home out
  home=$(make_home skipped)
  add_task "$home" parked "working: paused by captain" "parked dead"
  : > "$home/state/parked.stopped"
  add_task "$home" unreadable "working: fine"
  run_unowned "$home"; out=$OUT
  [ -z "$out" ] || fail "a stopped task and an unreadable state are skipped, got: $out"
  [ "$RC" = 0 ] || fail "exit 0 expected, got $RC"
  pass "a task the captain left stopped, or whose state cannot be read, is never NO-LANE"
}

test_done_claim_with_open_pr_is_stale_done() {
  local home out
  home=$(make_home stale)
  add_task "$home" claimed "done: PR https://github.com/acme/widget/pull/41 checks green"
  printf 'OPEN\n' > "$home/pr.41"
  add_task "$home" landed-task "landed: https://github.com/acme/widget/pull/42"
  printf 'MERGED\n' > "$home/pr.42"
  add_task "$home" closed-task "done: PR https://github.com/acme/widget/pull/43"
  printf 'CLOSED\n' > "$home/pr.43"
  add_task "$home" no-url "done: report at data/no-url/report.md"
  add_task "$home" meta-url "done: report at data/meta-url/report.md"
  printf 'window=firstmate:fm-meta-url\npr=https://github.com/acme/widget/pull/47\n' > "$home/state/meta-url.meta"
  printf 'OPEN\n' > "$home/pr.47"
  add_task "$home" forge-down "done: PR https://github.com/acme/widget/pull/44"
  add_task "$home" latest-url "done: PR https://github.com/acme/widget/pull/45 superseded"
  printf 'done: PR https://github.com/acme/widget/pull/46 checks green\n' >> "$home/state/latest-url.status"
  printf 'OPEN\n' > "$home/pr.45"
  printf 'MERGED\n' > "$home/pr.46"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 1 ] || fail "a stale done exits 1, got $RC"
  printf '%s\n' "$out" | grep -q '^STALE-DONE claimed claims done but https://github.com/acme/widget/pull/41 is still OPEN$' \
    || fail "claimed must be STALE-DONE: $out"
  printf '%s\n' "$out" | grep -q '^STALE-DONE meta-url claims done but https://github.com/acme/widget/pull/47 is still OPEN$' \
    || fail "a PR recorded only in the meta pr= field must still be STALE-DONE: $out"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 2 ] || fail "only the open PRs are reported, got: $out"
  grep -q '^pr view 47 --repo acme/widget ' "$home/gh.log" || fail "the meta-recorded PR is asked about: $(cat "$home/gh.log")"
  grep -q '^pr view 41 --repo acme/widget ' "$home/gh.log" || fail "the forge is asked about the recorded repo and number: $(cat "$home/gh.log")"
  ! grep -q 'pr view 45 ' "$home/gh.log" || fail "the last recorded URL wins, the earlier one is not asked"
  pass "a done or landed claim whose PR is still OPEN is STALE-DONE; merged, closed, no-URL, and unanswerable forges are not"
}

test_refused_backlog_listing_is_exit_2_not_silence() {
  local home out
  home=$(make_home refused)
  : > "$home/refuse"
  add_task "$home" alpha "working: on it" "alpha dead"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 2 ] || fail "a refused listing exits 2, got $RC"
  [ -z "$out" ] || fail "a refused listing prints no alarms, got: $out"
  grep -q 'tasks-axi list --state in_flight failed' "$home/err" || fail "the refusal is named on stderr: $(cat "$home/err")"
  grep -q 'VALIDATION_ERROR' "$home/err" || fail "the tool's own reason is carried: $(cat "$home/err")"
  pass "a backlog listing the tool refuses is reported as exit 2, never swallowed as an empty state"
}

test_hung_forge_is_skipped() {
  local home out
  home=$(make_home hung)
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 30
printf 'OPEN\n'
SH
  chmod 700 "$home/fakebin/gh"
  add_task "$home" hung-pr "done: PR https://github.com/acme/widget/pull/51"
  FM_UNOWNED_TIMEOUT=1 run_unowned "$home"; out=$OUT
  [ -z "$out" ] || fail "a forge that does not answer in time is skipped, got: $out"
  [ "$RC" = 0 ] || fail "exit 0 expected when the forge cannot answer, got $RC"
  pass "a hung forge is bounded and skipped rather than hanging every remaining task"
}

test_listing_count_mismatch_is_exit_2() {
  local home out
  home=$(make_home liedcount)
  printf 'ghost\n' > "$home/backlog.in_flight"
  : > "$home/lie-count"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 2 ] || fail "a listing whose rows disagree with its count exits 2, got $RC"
  [ -z "$out" ] || fail "a count mismatch prints no alarms, got: $out"
  grep -q 'disagree with count' "$home/err" || fail "the count mismatch is named on stderr: $(cat "$home/err")"
  pass "a listing whose rows disagree with its own count is a read failure, never silence"
}

test_missing_backlog_is_exit_2() {
  local home out
  home=$(make_home nobacklog)
  rm -f "$home/data/backlog.md"
  run_unowned "$home"; out=$OUT
  [ "$RC" = 2 ] || fail "a missing backlog exits 2, got $RC"
  grep -q 'no backlog at' "$home/err" || fail "the missing backlog is named: $(cat "$home/err")"
  pass "a home with no backlog exits 2 and says so"
}

test_owned_fleet_is_silent
test_in_flight_without_record_is_unowned
test_held_in_flight_item_is_not_unowned
test_queued_and_held_are_not_alarms
test_dead_endpoint_under_working_claim_is_no_lane
test_stopped_task_and_unreadable_state_are_skipped
test_state_and_data_overrides_are_honoured
test_grades_off_the_latest_status_line
test_bounded_reads_do_not_need_a_timeout_binary
test_done_claim_with_open_pr_is_stale_done
test_refused_backlog_listing_is_exit_2_not_silence
test_hung_forge_is_skipped
test_listing_count_mismatch_is_exit_2
test_missing_backlog_is_exit_2
printf 'ok - all fm-unowned tests passed\n'

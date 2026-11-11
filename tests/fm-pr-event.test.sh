#!/usr/bin/env bash
# tests/fm-pr-event.test.sh - the PR-event producer entry point.
#
# A PR-event producer (the pr-flow job) must be able to put a QA finding, a
# NO-GO, or a conflict into the steering inbox of the crew that authored the
# pull request at the moment it appears, instead of waiting on a firstmate turn
# days later. bin/fm-pr-event.sh owns that one command: it resolves the author
# from the recorded pr= identity, derives a stable delivery id from the exact
# record body, and fires a fire-and-forget record through bin/fm-send.sh.
# These tests drive the real executable over a stubbed tmux and a real bare
# origin plus the author's worktree, so the head is resolved exactly the way
# production resolves it. They pin:
#   1. The author is resolved from state/<id>.meta and the event lands in that
#      task's inbox as a fire-and-forget record that never enters the re-ring
#      ladder, with the canonical "pr-flow: <url> <kind> (head <head> live):
#      <text>" body naming the freshly fetched pull-request head.
#   2. A repeated identical event collapses onto the record already present, so
#      a blind retry after an uncertain outcome cannot queue a second copy.
#   3. A head advance on the pull request, with no metadata rewrite, makes the
#      same kind and the same text a distinct record.
#   4. A recorded pr_head= is only a named last resort, and a head that cannot
#      be resolved is named as such instead of collapsing events.
#   5. --head overrides live resolution and is named as explicit.
#   6. A pull request no task records exits 4 and enqueues nothing, so the
#      producer keeps its own routing.
#   7. A pull request two tasks record exits 5 and enqueues nothing.
#   8. A malformed URL, kind, head, or empty text exits 2.
#   9. A metadata file that is a symlink is not a record this home wrote.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENT="$ROOT/bin/fm-pr-event.sh"
URL='https://github.com/Muso-AI/H-DevOps/pull/4301'
PR_REF=refs/pull/4301/head

TMP_ROOT=$(fm_test_tmproot fm-pr-event)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: the doorbell is best-effort, so it only has to reach a clean
# verdict and log the literal line it typed.
make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

git_commit() {  # <dir> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

make_git_fixture() {  # <dir> -> bare origin plus the author's worktree at <dir>/wt
  local dir=$1
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/wt" 2>/dev/null
  printf 'base\n' > "$dir/wt/file.txt"
  git -C "$dir/wt" add file.txt
  git_commit "$dir/wt" base
  git -C "$dir/wt" push -q origin main
  printf 'head-a\n' >> "$dir/wt/file.txt"
  git -C "$dir/wt" add file.txt
  git_commit "$dir/wt" head-a
  git -C "$dir/wt" push -q origin "HEAD:$PR_REF"
}

remote_head() {  # <dir> -> the head the pull request currently publishes
  git -C "$1/origin.git" rev-parse "$PR_REF"
}

advance_pr_head() {  # <dir> -> a real push that moves the pull request's head
  local dir=$1
  printf 'head-b\n' >> "$dir/wt/file.txt"
  git -C "$dir/wt" add file.txt
  git_commit "$dir/wt" head-b
  git -C "$dir/wt" push -q origin "HEAD:$PR_REF"
}

setup_case() {  # <name> -> echoes case dir with home/state, a worktree, and an author task
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir"
  make_git_fixture "$dir"
  fm_write_meta "$dir/home/state/author-t1.meta" \
    "window=sess:fm-author-t1" "kind=ship" "harness=claude" "pr=$URL" "worktree=$dir/wt"
  printf '%s\n' "$dir"
}

run_event() {  # <case-dir> <err-file> -- <fm-pr-event args...>
  local dir=$1 err=$2
  shift 2
  shift
  : > "$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 \
    "$EVENT" "$@" >"$dir/out.log" 2>"$err"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

inbox_ladder() {  # <fn> <args...>
  bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

count_records() {  # <inbox-dir>
  find "$1" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

test_delivers_to_the_author() {
  local dir err rc inbox rec body action head
  dir=$(setup_case delivers); err="$dir/event.err"
  inbox="$dir/home/state/author-t1.inbox"
  head=$(remote_head "$dir")
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a finding for a recorded author should deliver"
  rec="$inbox/001.msg"
  [ -f "$rec" ] || fail "the event was not recorded at $rec:"$'\n'"$(cat "$err")"
  body=$(record_body "$rec")
  [ "$body" = "pr-flow: $URL finding (head $head live): no test covers the retry" ] \
    || fail "the recorded body differs: $body"
  inbox_ladder fm_task_inbox_is_fire_and_forget "$rec" \
    || fail "the record does not carry the fire-and-forget delivery mode, so the watcher would escalate it"
  action=$(inbox_ladder fm_task_inbox_due_action "$dir/home/state" author-t1)
  [ "$action" = quiet ] || fail "a fired PR event entered the re-ring ladder: $action"
  assert_contains "$(cat "$dir/send.log")" "Firstmate instruction waiting" \
    "a fired PR event should still ring its doorbell once"
  assert_contains "$(cat "$dir/out.log")" "delivered: author-t1 $URL finding" \
    "the producer should get one confirmation line"
  pass "fm-pr-event: a finding reaches the recorded author as a fired record off the re-ring ladder"
}

test_repeat_collapses() {
  local dir err rc inbox
  dir=$(setup_case repeat); err="$dir/event.err"
  inbox="$dir/home/state/author-t1.inbox"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "the first delivery should succeed"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a retried delivery should succeed"
  [ "$(count_records "$inbox")" = 1 ] \
    || fail "the same event was recorded twice:"$'\n'"$(ls "$inbox")"
  pass "fm-pr-event: a repeated identical event collapses onto the record already present"
}

test_new_head_is_a_distinct_record() {
  local dir err rc inbox head_a head_b
  dir=$(setup_case new-head); err="$dir/event.err"
  inbox="$dir/home/state/author-t1.inbox"
  head_a=$(remote_head "$dir")
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "the finding should deliver for the first head"
  advance_pr_head "$dir"
  head_b=$(remote_head "$dir")
  [ "$head_a" != "$head_b" ] || fail "the fixture did not advance the pull request head"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "the same finding on a new head should deliver"
  [ "$(count_records "$inbox")" = 2 ] \
    || fail "the same finding on a new head collapsed onto the old record:"$'\n'"$(ls "$inbox")"
  [ "$(record_body "$inbox/001.msg")" = "pr-flow: $URL finding (head $head_a live): no test covers the retry" ] \
    || fail "the first record does not name the head it was fired for"
  [ "$(record_body "$inbox/002.msg")" = "pr-flow: $URL finding (head $head_b live): no test covers the retry" ] \
    || fail "the second record does not name the head it was fired for"
  pass "fm-pr-event: a pushed head makes the same event a distinct record"
}

test_recorded_head_is_a_named_fallback() {
  local dir err rc rec body head
  dir=$(setup_case recorded); err="$dir/event.err"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/origin.git" update-ref -d "$PR_REF"
  fm_write_meta "$dir/home/state/author-t1.meta" \
    "window=sess:fm-author-t1" "kind=ship" "harness=claude" "pr=$URL" \
    "worktree=$dir/wt" "pr_head=$head"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a record with only a recorded head should still deliver"
  rec="$dir/home/state/author-t1.inbox/001.msg"
  body=$(record_body "$rec")
  [ "$body" = "pr-flow: $URL finding (head $head recorded): no test covers the retry" ] \
    || fail "the recorded body does not name the recorded head as its source: $body"
  pass "fm-pr-event: a recorded pr_head= is a named fallback when the live head is unavailable"
}

test_unresolvable_head_is_stated() {
  local dir err rc rec body
  dir=$(setup_case unresolvable); err="$dir/event.err"
  git -C "$dir/origin.git" update-ref -d "$PR_REF"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "an event with no resolvable head should still deliver"
  rec="$dir/home/state/author-t1.inbox/001.msg"
  body=$(record_body "$rec")
  [ "$body" = "pr-flow: $URL finding (head unresolvable): no test covers the retry" ] \
    || fail "the recorded body does not state the unresolvable head: $body"
  pass "fm-pr-event: a head that cannot be resolved is stated in the record"
}

test_explicit_head_overrides_live_resolution() {
  local dir err rc inbox head_a head_b
  dir=$(setup_case explicit); err="$dir/event.err"
  inbox="$dir/home/state/author-t1.inbox"
  head_a=$(remote_head "$dir")
  head_b=$(git -C "$dir/origin.git" rev-parse refs/heads/main)
  [ "$head_a" != "$head_b" ] || fail "the fixture needs two distinct commits"
  run_event "$dir" "$err" -- --head "$head_a" "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "an explicit head should deliver"
  run_event "$dir" "$err" -- --head="$head_b" "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a different explicit head should deliver"
  [ "$(count_records "$inbox")" = 2 ] \
    || fail "two explicit heads collapsed onto one record:"$'\n'"$(ls "$inbox")"
  [ "$(record_body "$inbox/001.msg")" = "pr-flow: $URL finding (head $head_a explicit): no test covers the retry" ] \
    || fail "the first record does not name its explicit head"
  [ "$(record_body "$inbox/002.msg")" = "pr-flow: $URL finding (head $head_b explicit): no test covers the retry" ] \
    || fail "the second record does not name its explicit head"
  pass "fm-pr-event: --head overrides live resolution and is named explicit"
}

test_gitlab_merge_request_head_is_live() {
  local dir err rc rec body head mr_url
  dir=$(setup_case gitlab); err="$dir/event.err"
  mr_url='https://gitlab.com/group/repo/-/merge_requests/7'
  head=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" push -q origin "HEAD:refs/merge-requests/7/head"
  fm_write_meta "$dir/home/state/author-t1.meta" \
    "window=sess:fm-author-t1" "kind=ship" "harness=claude" "pr=$mr_url" "worktree=$dir/wt"
  run_event "$dir" "$err" -- "$mr_url" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "a GitLab finding should deliver"
  rec="$dir/home/state/author-t1.inbox/001.msg"
  body=$(record_body "$rec")
  [ "$body" = "pr-flow: $mr_url finding (head $head live): no test covers the retry" ] \
    || fail "the GitLab record does not name the live merge-request head: $body"
  pass "fm-pr-event: a GitLab merge request resolves its live head, not an unknown one"
}

test_distinct_events_are_distinct() {
  local dir err rc inbox
  dir=$(setup_case distinct); err="$dir/event.err"
  inbox="$dir/home/state/author-t1.inbox"
  run_event "$dir" "$err" -- "$URL" finding 'no test covers the retry'; rc=$?
  expect_code 0 "$rc" "the finding should deliver"
  run_event "$dir" "$err" -- "$URL" conflict 'the base branch moved'; rc=$?
  expect_code 0 "$rc" "the conflict should deliver"
  run_event "$dir" "$err" -- "$URL" finding 'the retry still has no test'; rc=$?
  expect_code 0 "$rc" "a different finding on the same head should deliver"
  [ "$(count_records "$inbox")" = 3 ] \
    || fail "distinct events collapsed:"$'\n'"$(ls "$inbox")"
  pass "fm-pr-event: a different kind or text is a distinct record"
}

test_no_author_keeps_caller_routing() {
  local dir err rc
  dir=$(setup_case no-author); err="$dir/event.err"
  run_event "$dir" "$err" -- 'https://github.com/Muso-AI/H-DevOps/pull/9999' finding 'x'; rc=$?
  expect_code 4 "$rc" "an unrecorded pull request should exit 4"
  assert_contains "$(cat "$err")" "no-author" "the refusal should name the missing author"
  [ ! -d "$dir/home/state/author-t1.inbox" ] || [ "$(count_records "$dir/home/state/author-t1.inbox")" = 0 ] \
    || fail "an unresolved event enqueued something"
  pass "fm-pr-event: an unrecorded pull request exits 4 and enqueues nothing"
}

test_ambiguous_author_refuses() {
  local dir err rc
  dir=$(setup_case ambiguous); err="$dir/event.err"
  fm_write_meta "$dir/home/state/author-t2.meta" \
    "window=sess:fm-author-t2" "kind=ship" "harness=claude" "pr=$URL"
  run_event "$dir" "$err" -- "$URL" finding 'x'; rc=$?
  expect_code 5 "$rc" "two recorded authors should exit 5"
  assert_contains "$(cat "$err")" "ambiguous-author" "the refusal should name the ambiguity"
  [ ! -d "$dir/home/state/author-t1.inbox" ] || [ "$(count_records "$dir/home/state/author-t1.inbox")" = 0 ] \
    || fail "an ambiguous event enqueued something"
  pass "fm-pr-event: two recorded authors exit 5 and enqueue nothing"
}

test_invalid_requests() {
  local dir err rc
  dir=$(setup_case invalid); err="$dir/event.err"
  run_event "$dir" "$err" -- 'https://github.com/Muso-AI/H-DevOps/pull/0' finding 'x'; rc=$?
  expect_code 2 "$rc" "a malformed pull request URL should exit 2"
  run_event "$dir" "$err" -- "$URL" 'Finding' 'x'; rc=$?
  expect_code 2 "$rc" "an uppercase event kind should exit 2"
  run_event "$dir" "$err" -- "$URL" finding; rc=$?
  expect_code 2 "$rc" "a missing event text should exit 2"
  run_event "$dir" "$err" -- --head not-a-commit "$URL" finding 'x'; rc=$?
  expect_code 2 "$rc" "a malformed head should exit 2"
  run_event "$dir" "$err" -- --bogus "$URL" finding 'x'; rc=$?
  expect_code 2 "$rc" "an unknown option should exit 2"
  [ ! -d "$dir/home/state/author-t1.inbox" ] || [ "$(count_records "$dir/home/state/author-t1.inbox")" = 0 ] \
    || fail "an invalid request enqueued something"
  pass "fm-pr-event: a malformed request exits 2 and enqueues nothing"
}

test_symlinked_meta_is_not_a_record() {
  local dir err rc
  dir=$(setup_case symlink); err="$dir/event.err"
  mv "$dir/home/state/author-t1.meta" "$dir/real.meta"
  ln -s ../real.meta "$dir/home/state/author-t1.meta"
  run_event "$dir" "$err" -- "$URL" finding 'x'; rc=$?
  expect_code 4 "$rc" "a symlinked metadata file should not resolve an author"
  pass "fm-pr-event: a symlinked metadata file is not a record this home wrote"
}

test_delivers_to_the_author
test_repeat_collapses
test_new_head_is_a_distinct_record
test_recorded_head_is_a_named_fallback
test_unresolvable_head_is_stated
test_explicit_head_overrides_live_resolution
test_gitlab_merge_request_head_is_live
test_distinct_events_are_distinct
test_no_author_keeps_caller_routing
test_ambiguous_author_refuses
test_invalid_requests
test_symlinked_meta_is_not_a_record

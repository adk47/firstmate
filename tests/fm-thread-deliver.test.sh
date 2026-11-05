#!/usr/bin/env bash
# tests/fm-thread-deliver.test.sh - thread subscriptions deliver fleet events
# straight to the task that owns the thread.
#
# The feature exists so a PR's QA finding or a lane's "need firstmate: steer
# <lane>" line reaches the owning worker without a firstmate turn, and so
# firstmate hears about it only when that worker is gone
# (data/factory-autonomy-fable-a1/bob-architecture.md section 3). These tests
# drive the real bin/fm-thread-deliver.sh over a stubbed tmux and pin:
#   1. Thread ids canonicalize idempotently, so a raw PR URL and an existing id
#      address the same thread, and a path-traversal id is refused.
#   2. A subscription is idempotent per task, keeps its role, and can be dropped.
#   3. An event fans out to every subscriber, skips its own origin, lands in the
#      subscriber's durable steering inbox, and is recorded in the ledger.
#   4. A thread with no subscribers is a quiet success, not an error.
#   5. A lane scan on a log nobody has scanned yet starts at end-of-file, so
#      installing the feature never re-delivers a log's history; --backfill opts
#      in deliberately.
#   6. A steer line is delivered verbatim to its lane, subscribes that lane to
#      its own thread, and is never delivered twice.
#   7. A line caught mid-write is left for the next scan instead of being parsed
#      as a truncated half.
#   8. Both spellings of the marker match anywhere in a line, an unrelated line
#      is ignored, and a task steering itself is skipped.
#   9. A steer naming a lane this home has no record of becomes exactly one
#      durable firstmate copy, and repeating the scan adds no second copy.
#  10. Retiring a task drops it from every thread and forgets its cursor.
#  11. The 7-day measurement refuses to restart its window silently, reports a
#      wake rate and a before/after comparison from the recorded evidence, and
#      says plainly when a baseline is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVER="$ROOT/bin/fm-thread-deliver.sh"
MEASURE="$ROOT/bin/fm-thread-wake-measure.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-thread-deliver)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: records literal typed text and lets the doorbell and composer
# checks reach clean verdicts. Delivery never depends on the typing, so the log
# is only used to prove what did NOT cross the terminal.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
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
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> -> echoes case dir with home/state, stubs, and t1/t2 meta
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  fm_write_meta "$dir/home/state/t2.meta" "window=sess:fm-t2" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

run_deliver() {  # <case-dir> [env...] -- <args...>
  local dir=$1
  shift
  local envs=() rc
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 \
    ${envs[@]+"${envs[@]}"} "$DELIVER" "$@" 2>"$dir/deliver.err"
  rc=$?
  return "$rc"
}

run_measure() {  # <case-dir> [env...] -- <args...>
  local dir=$1
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    ${envs[@]+"${envs[@]}"} "$MEASURE" "$@" 2>"$dir/measure.err"
}

ledger_rows() {  # <case-dir>
  local file="$1/home/state/threads/deliveries.log"
  [ -f "$file" ] || return 0
  cat "$file"
}

inbox_records() {  # <case-dir> <task>
  local dir="$1/home/state/$2.inbox"
  [ -d "$dir" ] || { printf '0'; return 0; }
  find "$dir" -maxdepth 1 -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' '
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_thread_ids_canonicalize() {
  local dir out rc
  dir=$(setup_case ids)
  out=$(run_deliver "$dir" -- thread-id 'https://github.com/Muso-AI/hydra/pull/1472')
  rc=$?
  expect_code 0 "$rc" "a PR URL should canonicalize"
  [ "$out" = "pr-github.com-muso-ai-hydra-1472" ] || fail "unexpected PR thread id: $out"
  out=$(run_deliver "$dir" -- thread-id 'pr-github.com-muso-ai-hydra-1472')
  [ "$out" = "pr-github.com-muso-ai-hydra-1472" ] \
    || fail "canonicalizing an id must be idempotent, got: $out"
  out=$(run_deliver "$dir" -- thread-id 'Lane-CTO')
  [ "$out" = "lane-cto" ] || fail "a raw label should lowercase into a slug, got: $out"
  if run_deliver "$dir" -- thread-id 'https://github.com/Muso-AI/hydra/issues/9' >/dev/null; then
    fail "a non-PR URL must not be accepted as a thread id"
  fi
  if run_deliver "$dir" -- thread-id '../../../etc/passwd' >/dev/null; then
    fail "a path-traversal thread id must be refused"
  fi
  pass "thread ids: PR URLs canonicalize idempotently and traversal is refused"
}

test_subscriptions_are_idempotent() {
  local dir subs
  dir=$(setup_case subs)
  subs="$dir/home/state/threads/pr-1.subs"
  run_deliver "$dir" -- add pr-1 t1 --role author >/dev/null || fail "add t1 failed"
  run_deliver "$dir" -- add pr-1 t1 --role author >/dev/null || fail "re-adding t1 failed"
  run_deliver "$dir" -- add pr-1 t2 >/dev/null || fail "add t2 failed"
  [ "$(grep -c '^t1' "$subs")" = 1 ] || fail "a re-added task must not appear twice:"$'\n'"$(cat "$subs")"
  assert_grep $'t1\tauthor' "$subs" "the recorded role must survive"
  run_deliver "$dir" -- remove pr-1 t1 >/dev/null || fail "remove t1 failed"
  assert_no_grep $'t1\t' "$subs" "remove must drop the task's row"
  assert_grep $'t2\tmember' "$subs" "remove must leave other subscribers alone"
  pass "subscriptions: add is idempotent per task, keeps its role, and remove is surgical"
}

test_event_fans_out_and_skips_origin() {
  local dir out rc body typed
  dir=$(setup_case fanout)
  # Subscribed by raw URL, delivered by raw URL: the same thread either way.
  run_deliver "$dir" -- add 'https://github.com/Muso-AI/hydra/pull/7' t1 --role author >/dev/null \
    || fail "add t1 failed"
  run_deliver "$dir" -- add 'https://github.com/Muso-AI/hydra/pull/7' t2 --role reviewer >/dev/null \
    || fail "add t2 failed"
  out=$(run_deliver "$dir" -- pr-event 'https://github.com/Muso-AI/hydra/pull/7' \
    --from t2 --kind pr 'qa-review changed: run 01ABC failed at step review')
  rc=$?
  expect_code 0 "$rc" "a thread event should deliver"
  assert_contains "$out" "1 delivered, 0 failed, 1 skipped" \
    "the origin must be skipped and the other subscriber served: $out"
  [ "$(inbox_records "$dir" t1)" = 1 ] || fail "t1 should hold exactly one instruction"
  [ "$(inbox_records "$dir" t2)" = 0 ] || fail "the origin task must not receive its own event"
  body=$(record_body "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = 'qa-review changed: run 01ABC failed at step review' ] \
    || fail "the delivered body differs: $body"
  typed=$(cat "$dir/send.log" 2>/dev/null || true)
  case "$typed" in
    *'qa-review changed'*) fail "the event payload must never be typed into the terminal:"$'\n'"$typed" ;;
  esac
  ledger_rows "$dir" > "$dir/ledger.txt"
  assert_grep $'pr-github.com-muso-ai-hydra-7\tpr\tt1\tdelivery' "$dir/ledger.txt" \
    "the ledger must record the delivery to t1"
  pass "delivery: an event fans out to every subscriber, skips its origin, and never types the payload"
}

test_thread_without_subscribers_is_quiet() {
  local dir out rc
  dir=$(setup_case quiet)
  out=$(run_deliver "$dir" -- deliver nobody-heard 'an event with no owner')
  rc=$?
  expect_code 0 "$rc" "a thread with no subscribers is not an error"
  assert_contains "$out" "0 delivered, 0 failed, 0 skipped" "the summary must be honest: $out"
  [ -z "$(ledger_rows "$dir")" ] || fail "nothing was delivered, so the ledger must stay empty"
  pass "delivery: a thread nobody owns is a quiet success"
}

test_silent_refusals() {
  local dir
  dir=$(setup_case refusals)
  if run_deliver "$dir" -- deliver pr-9 '   ' >/dev/null; then
    fail "an empty thread event must be refused"
  fi
  if run_deliver "$dir" -- deliver pr-9 --from '../x' 'text' >/dev/null; then
    fail "an invalid --from task id must be refused"
  fi
  if run_deliver "$dir" -- add pr-9 '../x' >/dev/null; then
    fail "an invalid task id must be refused"
  fi
  pass "delivery: empty events and invalid ids are refused rather than recorded"
}

test_first_sight_starts_at_end_of_file() {
  local dir file out rc
  dir=$(setup_case firstsight)
  file="$dir/home/state/t9.status"
  printf 'working: bootstrap\nneed firstmate: steer t2: historical steer\n' > "$file"
  out=$(run_deliver "$dir" -- lane-scan "$file")
  rc=$?
  expect_code 0 "$rc" "a first scan should succeed"
  [ -z "$out" ] || fail "a first scan must not replay history: $out"
  [ "$(inbox_records "$dir" t2)" = 0 ] || fail "history must not be delivered"
  [ "$(cat "$dir/home/state/threads/.lane-cursor/t9")" = "$(wc -c < "$file" | tr -d ' ')" ] \
    || fail "the cursor should start at end-of-file"
  pass "lane scan: a log seen for the first time starts at end-of-file, never on its history"
}

test_backfill_delivers_a_steer_once() {
  local dir file out rc subs body
  dir=$(setup_case backfill)
  file="$dir/home/state/t9.status"
  printf 'working: bootstrap\nneed firstmate: steer t2: the reviewer wants the fake clock injected\n' > "$file"
  out=$(run_deliver "$dir" -- lane-scan --backfill "$file")
  rc=$?
  expect_code 0 "$rc" "a backfilled scan should succeed"
  [ -z "$out" ] || fail "a successful scan is silent on stdout: $out"
  [ "$(inbox_records "$dir" t2)" = 1 ] || fail "the lane should hold exactly one instruction"
  body=$(record_body "$dir/home/state/t2.inbox/001.msg")
  [ "$body" = 'the reviewer wants the fake clock injected' ] \
    || fail "the steer text must arrive verbatim, got: $body"
  subs="$dir/home/state/threads/lane-t2.subs"
  assert_present "$subs" "the lane must be subscribed to its own thread"
  assert_grep $'t2\tlane' "$subs" "the lane subscription must record its role"
  out=$(run_deliver "$dir" -- lane-scan "$file")
  [ "$(inbox_records "$dir" t2)" = 1 ] || fail "a re-scan must not deliver the same steer twice"
  pass "lane scan: a steer reaches its lane verbatim and is delivered exactly once"
}

test_half_written_line_waits() {
  local dir file
  dir=$(setup_case halfwritten)
  file="$dir/home/state/t9.status"
  printf 'working: bootstrap\n' > "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null
  printf 'need firstmate: steer t2: half a thought' >> "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null || fail "an incomplete line must not fail the scan"
  [ "$(inbox_records "$dir" t2)" = 0 ] || fail "a line caught mid-write must not be delivered yet"
  printf ' completed\n' >> "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null || fail "the completed line should scan cleanly"
  [ "$(inbox_records "$dir" t2)" = 1 ] || fail "the completed line must be delivered"
  [ "$(record_body "$dir/home/state/t2.inbox/001.msg")" = 'half a thought completed' ] \
    || fail "the completed line must arrive whole"
  pass "lane scan: a line caught mid-write waits for its newline instead of being parsed as a half"
}

test_grammar_and_self_steer() {
  local dir file
  dir=$(setup_case grammar)
  file="$dir/home/state/t9.status"
  printf 'working: bootstrap\n' > "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null
  {
    printf 'needs firstmate: steer t2: plural spelling still counts\n'
    printf 'chatter needs firstmate: steer t1: the marker works mid-line too\n'
    printf 'note: a plain line is none of this script'"'"'s business\n'
    printf 'need firstmate: steer t9: a task cannot steer itself\n'
    printf 'need firstmate: steer lane-with-nothing: an empty text is refused\n'
  } >> "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null || fail "the scan should succeed"
  [ "$(inbox_records "$dir" t2)" = 1 ] || fail "the plural marker must match"
  [ "$(inbox_records "$dir" t1)" = 1 ] || fail "the marker must match mid-line"
  [ "$(inbox_records "$dir" t9)" = 0 ] || fail "a task must not receive its own steer"
  assert_contains "$(record_body "$dir/home/state/t1.inbox/001.msg")" \
    'the marker works mid-line too' "the text after the marker must be delivered whole"
  pass "lane scan: both marker spellings match anywhere in a line, and a self-steer is skipped"
}

test_dead_lane_becomes_one_firstmate_copy() {
  local dir file queue
  dir=$(setup_case deadlane)
  file="$dir/home/state/t9.status"
  queue="$dir/home/state/.wake-queue"
  printf 'working: bootstrap\n' > "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null
  printf 'need firstmate: steer ghost: take the cache invalidation to the platform team\n' >> "$file"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null || fail "the scan should succeed"
  assert_present "$queue" "the firstmate copy must become a durable wake"
  [ "$(grep -c 'thread-steer:ghost' "$queue")" = 1 ] \
    || fail "exactly one copy must be queued:"$'\n'"$(cat "$queue")"
  assert_grep 'take the cache invalidation to the platform team' "$queue" \
    "the copy must carry the event so firstmate can act on it"
  [ "$(inbox_records "$dir" ghost)" = 0 ] || fail "a gone lane has no inbox to write"
  run_deliver "$dir" -- lane-scan "$file" >/dev/null
  [ "$(grep -c 'thread-steer:ghost' "$queue")" = 1 ] \
    || fail "a re-scan must not queue the same copy again"
  pass "lane scan: a lane this home has no record of becomes exactly one durable firstmate copy"
}

test_retire_drops_routing_state() {
  local dir
  dir=$(setup_case retire)
  run_deliver "$dir" -- add pr-3 t1 >/dev/null
  run_deliver "$dir" -- add pr-3 t2 >/dev/null
  run_deliver "$dir" -- add lane-t1 t1 --role lane >/dev/null
  mkdir -p "$dir/home/state/threads/.lane-cursor"
  printf '42\n' > "$dir/home/state/threads/.lane-cursor/t1"
  run_deliver "$dir" -- retire t1 >/dev/null || fail "retire should succeed"
  assert_no_grep $'t1\t' "$dir/home/state/threads/pr-3.subs" "retire must drop t1 from a shared thread"
  assert_grep $'t2\t' "$dir/home/state/threads/pr-3.subs" "retire must not disturb other subscribers"
  assert_absent "$dir/home/state/threads/.lane-cursor/t1" "retire must forget the task's cursor"
  pass "retire: a cleaned-up task keeps no subscription and no cursor"
}

test_watcher_poll_routes_a_lane_steer() {
  local dir file pid i
  dir=$(setup_case watchpoll)
  file="$dir/home/state/t9.status"
  printf 'working: bootstrap\n' > "$file"
  # Record the first-sight cursor exactly as an earlier poll would, then append
  # the steer, so this proves the poll delivers new lines rather than replaying.
  run_deliver "$dir" -- lane-scan "$file" >/dev/null
  printf 'need firstmate: steer t2: the watcher must route this without a turn\n' >> "$file"
  mkdir -p "$dir/home/data" "$dir/home/config"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 FM_POLL=1 FM_THREAD_SCAN_INTERVAL=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(inbox_records "$dir" t2)" = 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(inbox_records "$dir" t2)" = 1 ] \
    || fail "the watcher poll must run the thread scan with no firstmate turn:"$'\n'"$(tail -20 "$dir/watch.out" 2>/dev/null)"
  pass "watcher: the poll routes a lane steer to its lane with no firstmate turn"
}

test_measurement_reports_evidence() {
  local dir out rc
  dir=$(setup_case measure)
  run_deliver "$dir" -- add pr-5 t1 >/dev/null
  out=$(run_measure "$dir" -- report)
  assert_contains "$out" "baseline: absent" "an absent baseline must be said plainly: $out"
  printf '10\n' > "$dir/home/state/.wake-queue.seq"
  run_measure "$dir" -- baseline >/dev/null || fail "baseline should succeed"
  assert_present "$dir/home/state/threads/wake-baseline" "the baseline must be recorded"
  if run_measure "$dir" -- baseline >/dev/null; then
    fail "a second baseline must be refused so the window cannot restart silently"
  fi
  run_measure "$dir" -- baseline --force >/dev/null || fail "--force should restart the window"
  printf '250\n' > "$dir/home/state/.wake-queue.seq"
  out=$(run_measure "$dir" -- report --days 7)
  rc=$?
  expect_code 0 "$rc" "the report should succeed"
  assert_contains "$out" "firstmate wake appends: 240 over" \
    "the report must count wake appends since the baseline: $out"
  assert_contains "$out" "deliveries to owning workers: 0" \
    "the report must count the deliveries it routed: $out"
  out=$(run_measure "$dir" -- report --json)
  assert_contains "$out" '"wake_appends":240' "the JSON report must carry the same counts: $out"
  pass "measurement: the window cannot restart silently and the report counts its own evidence"
}

test_thread_ids_canonicalize
test_subscriptions_are_idempotent
test_event_fans_out_and_skips_origin
test_thread_without_subscribers_is_quiet
test_silent_refusals
test_first_sight_starts_at_end_of_file
test_backfill_delivers_a_steer_once
test_half_written_line_waits
test_grammar_and_self_steer
test_dead_lane_becomes_one_firstmate_copy
test_retire_drops_routing_state
test_watcher_poll_routes_a_lane_steer
test_measurement_reports_evidence

#!/usr/bin/env bash
# tests/fm-decisions-sweep.test.sh - the stale open-decision sweep
# (bin/fm-decisions-sweep.sh): which open decision records it calls stale and
# why, which it must never touch (a live or recently written task, a secondmate,
# a reserved key, an open captain call, an unreadable backlog, a log written
# mid-sweep), that the default mode writes nothing, and that --apply appends
# exactly one closing line per record and nothing else.
#
# Everything is a fixture: a throwaway home, a fake process table
# (FM_AGENT_PROC_TABLE), a fake captain-call reader
# (FM_DECISIONS_SWEEP_HOLD_BIN), and fake `gh` and `tmux` on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

SWEEP="$ROOT/bin/fm-decisions-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-decisions-sweep)
NOW=1800000000
OLD=$((NOW - 3 * 86400))
RECENT=$((NOW - 3600))

# A home whose process table is readable and, until a test adds a row, holds
# only a shell: a recorded task with a recognizable harness reads dead.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin" "$home/wt"
  printf '1\tbash\t/\tbash\n' > "$home/procs"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view <url> --json state -q .state
printf '%s\n' "$*" >> "${FM_FAKE_GH_LOG:-/dev/null}"
url=$3
state=$(sed -n "s|^$url ||p" "${FM_FAKE_GH_STATES:-/dev/null}" 2>/dev/null | head -n 1)
[ -n "$state" ] || exit 1
printf '%s\n' "$state"
SH
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$home/fakebin/hold" <<'SH'
#!/usr/bin/env bash
# Stand-in for `fm-captain-hold.sh open-ids`.
[ "${1:-}" = open-ids ] || exit 2
[ -z "${FM_FAKE_HOLD_TOUCH:-}" ] || printf 'note: written mid-sweep\n' >> "$FM_FAKE_HOLD_TOUCH"
[ "${FM_FAKE_HOLD_FAIL:-0}" = 0 ] || exit 2
[ ! -f "${FM_FAKE_HOLD_IDS:-/nonexistent}" ] || cat "$FM_FAKE_HOLD_IDS"
exit 0
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/tmux" "$home/fakebin/hold"
  : > "$home/gh-states"
  printf '%s\n' "$home"
}

# A recorded task. Its worktree is a real directory so a process row can sit in it.
task() {  # <home> <id> [meta-line...]
  local home=$1 id=$2
  shift 2
  mkdir -p "$home/wt/$id"
  fm_write_meta "$home/state/$id.meta" "window=test:fm-$id" "kind=ship" "harness=pi" \
    "worktree=$home/wt/$id" "project=$home/projects/p" "$@"
}

# A status log whose newest line is <epoch> old.
log() {  # <home> <id> <epoch> <line...>
  local home=$1 id=$2 at=$3
  shift 3
  printf '%s\n' "$@" > "$home/state/$id.status"
  touch -d "@$at" "$home/state/$id.status"
}

live_agent() {  # <home> <id> <pid>
  printf '%s\tpi\t%s\tpi\n' "$3" "$1/wt/$2" >> "$1/procs"
}

sweep() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_AGENT_PROC_TABLE="$home/procs" FM_DECISIONS_SWEEP_NOW="$NOW" \
    FM_DECISIONS_SWEEP_HOLD_BIN="$home/fakebin/hold" FM_FAKE_GH_STATES="$home/gh-states" \
    FM_FAKE_GH_LOG="$home/gh-log" "$SWEEP" "$@"
}

has_row() {  # <output> <verdict> <task> <key> <reason> <label>
  printf '%s\n' "$1" | awk -F '\t' -v v="$2" -v t="$3" -v k="$4" -v r="$5" \
    '$1 == v && $2 == t && $3 == k && $4 == r { found = 1 } END { exit !found }' \
    || fail "$6 (wanted row: $2 $3 $4 $5; got: $1)"
}

no_row_for() {  # <output> <task> <label>
  printf '%s\n' "$1" | awk -F '\t' -v t="$2" '$1 != "count" && $1 != "summary" && $2 == t { found = 1 } END { exit found }' \
    || fail "$3 (got: $1)"
}

state_fingerprint() {  # <home>
  (cd "$1/state" && find . -type f -print0 | sort -z | xargs -0 cksum)
}

# One home holding one task per reason, plus the cases each reason must not reach.
make_reason_home() {  # <name>
  local home
  home=$(make_home "$1")
  task "$home" t-done
  log "$home" t-done "$OLD" 'needs-decision: pick a or b' 'done: shipped'
  task "$home" t-resolved
  log "$home" t-resolved "$OLD" 'needs-decision [key=a]: first' 'blocked [key=b]: second' 'resolved [key=a]: answered'
  task "$home" t-merged "pr=https://github.com/acme/app/pull/11"
  log "$home" t-merged "$OLD" 'needs-decision [key=review]: approve?' 'working: polishing'
  task "$home" t-closed "pr=https://github.com/acme/app/pull/12"
  log "$home" t-closed "$OLD" 'blocked: ci red' 'working: retrying'
  task "$home" t-open "pr=https://github.com/acme/app/pull/13"
  log "$home" t-open "$OLD" 'blocked: needs a token' 'working: waiting'
  live_agent "$home" t-open 4100
  printf '%s\n' 'https://github.com/acme/app/pull/11 MERGED' 'https://github.com/acme/app/pull/12 CLOSED' \
    'https://github.com/acme/app/pull/13 OPEN' > "$home/gh-states"
  task "$home" t-noproc
  log "$home" t-noproc "$OLD" 'needs-decision: which region' 'working: holding'
  log "$home" t-norecord "$OLD" 'paused: waiting on the vendor'
  printf '%s\n' "$home"
}

test_dry_run_is_default_names_each_reason_and_writes_nothing() {
  local home out status before after
  home=$(make_reason_home reasons)
  before=$(state_fingerprint "$home")
  out=$(sweep "$home" 2>&1); status=$?
  expect_code 0 "$status" "a dry run must succeed: $out"
  after=$(state_fingerprint "$home")
  [ "$before" = "$after" ] || fail "the default mode changed the state directory"

  has_row "$out" close t-done default last-line-done "a finished task's record is stale"
  has_row "$out" close t-resolved b last-line-resolved "a record left behind a resolved line is stale"
  has_row "$out" close t-merged review pr-merged "a merged PR makes its task's record stale"
  has_row "$out" close t-closed default pr-closed "a closed PR makes its task's record stale"
  has_row "$out" close t-noproc default no-process-48h "a dead, long-quiet task's record is stale"
  has_row "$out" close t-norecord default no-record-48h "a long-quiet log with no task record is stale"
  no_row_for "$out" t-open "an open PR on a task whose agent is still there is not a reason to close"
  assert_contains "$out" $'count\tclose\tpr-merged\t1' "the counts are broken out by reason"
  assert_contains "$out" $'count\tkept\tagent-alive\t1' "a record with no reason is counted as kept"
  assert_contains "$out" $'summary\tdry-run\tclose=6\theld=0\tprotected=0\tkept=1\tfailed=0' "the summary totals each verdict"

  out=$(sweep "$home" --dry-run 2>&1)
  [ "$(state_fingerprint "$home")" = "$before" ] || fail "--dry-run changed the state directory"
  assert_contains "$out" $'summary\tdry-run\tclose=6' "--dry-run is the same read as the default"
  pass "the default mode is a dry run: it names each stale record's reason and writes nothing"
}

test_recent_or_live_task_is_never_touched() {
  local home out status before
  home=$(make_home protected)
  # Alive and recently written: protected even though its newest line is done.
  task "$home" live-recent
  log "$home" live-recent "$RECENT" 'needs-decision: pick one' 'done: shipped'
  live_agent "$home" live-recent 4242
  # A lane that just lost its agent: a done line, a resolved line, and a merged
  # PR are all true of it, and its asks are still waiting on someone.
  task "$home" dead-recent "pr=https://github.com/acme/app/pull/21"
  log "$home" dead-recent "$RECENT" 'blocked [key=prod-outage]: live breakage' 'done: item 7' 'resolved [key=other]: cleared'
  # Alive, quiet for days, PR merged: a reason holds and the log is old.
  task "$home" live-old "pr=https://github.com/acme/app/pull/21"
  log "$home" live-old "$OLD" 'needs-decision: pick one' 'working: on it'
  live_agent "$home" live-old 4243
  # Alive, quiet for days, no reason: the agent is still there to answer for it.
  task "$home" live-waiting
  log "$home" live-waiting "$OLD" 'needs-decision: pick one'
  live_agent "$home" live-waiting 4244
  # A harness the process table cannot name is never dead by absence.
  task "$home" blind-recent "harness=gemini"
  log "$home" blind-recent "$RECENT" 'blocked: stuck' 'done: shipped'
  task "$home" blind-old "harness=gemini"
  log "$home" blind-old "$OLD" 'blocked: stuck' 'working: on it'
  # No task record and recently written: nothing proves it is abandoned.
  log "$home" orphan-recent "$RECENT" 'needs-decision: pick one' 'done: shipped'
  printf '%s\n' 'https://github.com/acme/app/pull/21 MERGED' > "$home/gh-states"
  before=$(state_fingerprint "$home")

  out=$(sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "the sweep must succeed: $out"
  has_row "$out" protected live-recent default recent "a live, recently written task is protected ahead of every reason"
  has_row "$out" protected dead-recent prod-outage recent "a recently written task is protected even when its agent is gone"
  has_row "$out" protected blind-recent default recent "a task of unknown liveness written recently is protected"
  has_row "$out" protected orphan-recent default recent "a recently written log with no record is protected"
  has_row "$out" closed live-old default pr-merged "a merged PR closes a long-quiet task's record"
  no_row_for "$out" live-waiting "a live agent's long-open decision with no reason stays open"
  no_row_for "$out" blind-old "an unrecognizable harness is never dead by absence"
  assert_contains "$out" $'count\tkept\tagent-alive\t1' "the live waiting task is counted as kept"
  assert_contains "$out" $'count\tkept\tliveness-unknown\t1' "the unreadable task is counted as kept"
  for id in live-recent dead-recent live-waiting blind-recent blind-old orphan-recent; do
    [ "$(cksum < "$home/state/$id.status")" = "$(printf '%s\n' "$before" | sed -n "s|^\([0-9]* [0-9]*\) ./$id.status\$|\1|p")" ] \
      || fail "--apply wrote to $id, which it must never touch"
  done

  # An unreadable process table is no evidence: nothing reads dead on it.
  home=$(make_home table-unreadable)
  task "$home" quiet
  log "$home" quiet "$OLD" 'needs-decision: pick one' 'working: on it'
  rm -f "$home/procs"
  out=$(sweep "$home" 2>&1)
  no_row_for "$out" quiet "a task read dead from a process table that could not be read"
  pass "a recently written task keeps its records whatever its liveness, a live agent keeps what no reason reaches, and absence is proof only when it was read"
}

test_owned_records_are_held() {
  local home out status before
  home=$(make_home held)
  task "$home" mate "kind=secondmate"
  log "$home" mate "$OLD" 'needs-decision: routed ask' 'done: charter read'
  task "$home" remote "remote_host=box-2"
  log "$home" remote "$OLD" 'blocked: routed ask' 'done: charter read'
  task "$home" asker
  log "$home" asker "$OLD" 'blocked [key=pending-reply-0123456789abcdef]: pending-reply-missed: no answer' \
    'needs-decision [key=plain]: also open' 'done: gave up'
  task "$home" called
  log "$home" called "$OLD" 'needs-decision [key=budget]: spend it?' 'done: parked'
  task "$home" legacy
  log "$home" legacy "$OLD" 'needs-decision [key=vendor]: switch?' 'needs-decision [key=other]: unrelated' 'done: parked'
  task "$home" whole
  log "$home" whole "$OLD" 'needs-decision [key=x]: one' 'done: parked'
  printf '%s\n' budget legacy-decision-vendor whole > "$home/hold-ids"
  before=$(state_fingerprint "$home")

  out=$(FM_FAKE_HOLD_IDS="$home/hold-ids" sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "the sweep must succeed: $out"
  has_row "$out" held mate default secondmate "a secondmate's hold is routed work"
  has_row "$out" held remote default secondmate "a remote home's hold is routed work"
  has_row "$out" held asker pending-reply-0123456789abcdef reserved-key "a reserved key is closed only by its owner"
  has_row "$out" closed asker plain last-line-done "a reserved key does not shield its task's other records"
  has_row "$out" held called budget captain-call "a key that is an open captain call is held"
  has_row "$out" held legacy vendor captain-call "the legacy <task>-decision-<key> id is an open captain call"
  has_row "$out" closed legacy other last-line-done "a captain call on one key does not shield another"
  has_row "$out" held whole x captain-call "a task that is itself an open captain call is held"
  for id in mate remote called whole; do
    [ "$(cksum < "$home/state/$id.status")" = "$(printf '%s\n' "$before" | sed -n "s|^\([0-9]* [0-9]*\) ./$id.status\$|\1|p")" ] \
      || fail "--apply wrote to $id, whose records are held"
  done
  assert_not_contains "$(cat "$home/state/asker.status")" 'resolved [key=pending-reply-' "a reserved key was closed"

  # A backlog that cannot be read cannot rule a captain call out.
  home=$(make_home backlog-unread)
  task "$home" t1
  log "$home" t1 "$OLD" 'needs-decision: pick one' 'done: shipped'
  before=$(state_fingerprint "$home")
  out=$(FM_FAKE_HOLD_FAIL=1 sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "an unreadable backlog is a hold, not an error: $out"
  has_row "$out" held t1 default backlog-unread "an unreadable backlog holds every record"
  [ "$(state_fingerprint "$home")" = "$before" ] || fail "--apply wrote with the backlog unreadable"

  # A log written while the sweep ran is left for the next sweep.
  home=$(make_home changed)
  task "$home" t1
  log "$home" t1 "$OLD" 'needs-decision: pick one' 'done: shipped'
  out=$(FM_FAKE_HOLD_TOUCH="$home/state/t1.status" sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "a mid-sweep write is a hold, not an error: $out"
  has_row "$out" held t1 default changed "a log written mid-sweep is held"
  assert_not_contains "$(cat "$home/state/t1.status")" 'auto-closed by sweep' "the sweep closed a record in a log that changed under it"
  pass "a secondmate, a reserved key, an open captain call, an unreadable backlog, and a mid-sweep write are all held"
}

test_apply_appends_one_closing_line_per_record_and_nothing_else() {
  local home out status id before_list
  home=$(make_reason_home apply)
  for id in t-done t-resolved t-merged t-closed t-open t-noproc t-norecord; do
    cp "$home/state/$id.status" "$home/before.$id"
  done
  before_list=$(cd "$home" && find state wt -print | sort)

  out=$(sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "--apply must succeed: $out"
  assert_contains "$out" $'summary\tapply\tclose=6\theld=0\tprotected=0\tkept=1\tfailed=0' "--apply closes what the dry run listed"
  has_row "$out" closed t-merged review pr-merged "--apply reports the record it closed"

  # Each swept log is its old bytes plus exactly the closing line(s).
  [ "$(cat "$home/state/t-done.status")" = "$(cat "$home/before.t-done"; echo 'resolved [key=default]: auto-closed by sweep (last-line-done)')" ] \
    || fail "t-done is not its old log plus one closing line: $(cat "$home/state/t-done.status")"
  [ "$(cat "$home/state/t-resolved.status")" = "$(cat "$home/before.t-resolved"; echo 'resolved [key=b]: auto-closed by sweep (last-line-resolved)')" ] \
    || fail "t-resolved is not its old log plus one closing line: $(cat "$home/state/t-resolved.status")"
  [ "$(cat "$home/state/t-merged.status")" = "$(cat "$home/before.t-merged"; echo 'resolved [key=review]: auto-closed by sweep (pr-merged)')" ] \
    || fail "t-merged is not its old log plus one closing line"
  [ "$(cat "$home/state/t-closed.status")" = "$(cat "$home/before.t-closed"; echo 'resolved [key=default]: auto-closed by sweep (pr-closed)')" ] \
    || fail "t-closed is not its old log plus one closing line"
  [ "$(cat "$home/state/t-noproc.status")" = "$(cat "$home/before.t-noproc"; echo 'resolved [key=default]: auto-closed by sweep (no-process-48h)')" ] \
    || fail "t-noproc is not its old log plus one closing line"
  [ "$(cat "$home/state/t-norecord.status")" = "$(cat "$home/before.t-norecord"; echo 'resolved [key=default]: auto-closed by sweep (no-record-48h)')" ] \
    || fail "t-norecord is not its old log plus one closing line"
  cmp -s "$home/state/t-open.status" "$home/before.t-open" || fail "--apply wrote to a task with no reason to close"

  # The fold now reads every swept record closed, and the one kept record open.
  for id in t-done t-resolved t-merged t-closed t-noproc t-norecord; do
    [ -z "$(status_open_decisions "$home/state/$id.status")" ] || fail "$id still has an open record after --apply"
  done
  [ -n "$(status_open_decisions "$home/state/t-open.status")" ] || fail "the kept record was closed"

  # No task record, worktree, or other file was removed or created.
  [ "$(cd "$home" && find state wt -print | grep -v '/\.' | sort)" = "$(printf '%s\n' "$before_list" | grep -v '/\.')" ] \
    || fail "--apply added or removed a task record or worktree"

  # A finished task still reads as finished through the sweep's own line.
  [ "$(last_status_line_behind_sweep "$home/state/t-done.status")" = 'done: shipped' ] \
    || fail "a swept finished task no longer reads its done line"

  # A second sweep finds nothing left to close.
  out=$(sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "a repeat --apply must succeed: $out"
  assert_contains "$out" $'summary\tapply\tclose=0\theld=0\tprotected=0\tkept=1\tfailed=0' "a repeat --apply closes nothing"
  pass "--apply appends one closing line per stale record, leaves everything else byte-identical, and is idempotent"
}

test_repeat_sweep_reports_the_tasks_own_reason() {
  local home out status
  home=$(make_home repeat)
  task "$home" t-done
  log "$home" t-done "$OLD" 'needs-decision [key=kept]: captain call' \
    'needs-decision [key=other]: also open' 'done: shipped'
  printf '%s\n' kept > "$home/hold-ids"

  out=$(FM_FAKE_HOLD_IDS="$home/hold-ids" sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "the first --apply must succeed: $out"
  has_row "$out" held t-done kept captain-call "the held record survives the first pass"
  has_row "$out" closed t-done other last-line-done "the first pass closes the record the task's done line covers"
  [ -n "$(status_open_decisions "$home/state/t-done.status")" ] || fail "the held record was closed anyway"

  out=$(sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "a repeat --apply must succeed: $out"
  has_row "$out" closed t-done kept last-line-done "a repeat sweep reports the task's own done line, not the sweep's close line"
  [ -z "$(status_open_decisions "$home/state/t-done.status")" ] || fail "the repeat sweep left the record open"
  pass "a repeat sweep reads through its own close line to the reason the task itself earned"
}

test_repeat_sweep_never_closes_a_live_tasks_record_as_resolved() {
  local home out status
  home=$(make_home repeat-live)
  task "$home" t-live "pr=https://github.com/acme/app/pull/41"
  log "$home" t-live "$OLD" 'needs-decision [key=kept]: captain call' \
    'needs-decision [key=other]: also open' 'working: polishing'
  live_agent "$home" t-live 4301
  printf '%s\n' 'https://github.com/acme/app/pull/41 MERGED' > "$home/gh-states"
  printf '%s\n' kept > "$home/hold-ids"

  out=$(FM_FAKE_HOLD_IDS="$home/hold-ids" sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "the first --apply must succeed: $out"
  has_row "$out" held t-live kept captain-call "the held record survives the first pass"
  has_row "$out" closed t-live other pr-merged "the first pass closes the other record"

  printf '%s\n' 'https://github.com/acme/app/pull/41 OPEN' > "$home/gh-states"
  out=$(sweep "$home" --task t-live 2>&1); status=$?
  expect_code 0 "$status" "the repeat sweep must succeed: $out"
  has_row "$out" kept t-live kept agent-alive "a repeat sweep leaves a live agent's record alone"
  assert_not_contains "$out" 'last-line-resolved' "a repeat sweep called a live task's record resolved"
  [ -n "$(status_open_decisions "$home/state/t-live.status")" ] || fail "the repeat sweep closed a live task's record"
  pass "a repeat sweep reads through its own close line to a live agent and keeps the record"
}

test_repeat_sweep_closes_a_dead_tasks_record_as_no_process() {
  local home out status
  home=$(make_home repeat-dead)
  task "$home" t-dead
  log "$home" t-dead "$OLD" 'needs-decision [key=kept]: captain call' \
    'needs-decision [key=other]: also open' 'working: polishing'
  printf '%s\n' kept > "$home/hold-ids"

  out=$(FM_FAKE_HOLD_IDS="$home/hold-ids" sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "the first --apply must succeed: $out"
  has_row "$out" held t-dead kept captain-call "the held record survives the first pass"
  has_row "$out" closed t-dead other no-process-48h "the first pass closes the other record"

  out=$(sweep "$home" --apply 2>&1); status=$?
  expect_code 0 "$status" "a repeat --apply must succeed: $out"
  has_row "$out" closed t-dead kept no-process-48h "a repeat sweep closes the record for the liveness reason, not its own line"
  assert_not_contains "$out" 'last-line-resolved' "a repeat sweep called a dead task's record resolved"
  pass "a repeat sweep reads through its own close line to the liveness reason"
}

test_pr_state_comes_from_the_recorded_merge_or_the_forge_and_unknown_never_closes() {
  local home out
  home=$(make_home pr)
  task "$home" recorded "pr=https://github.com/acme/app/pull/31"
  log "$home" recorded "$OLD" 'needs-decision: approve?' 'working: polishing'
  fm_pr_url_parse "https://github.com/acme/app/pull/31" || fail "fixture PR URL did not parse"
  fm_pr_poll_merge_mark_notified "$home/state" recorded "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "could not record the fixture merge outcome"
  task "$home" forge "pr=https://github.com/acme/app/pull/32"
  log "$home" forge "$OLD" 'needs-decision: approve?' 'working: polishing'
  task "$home" unanswered "pr=https://github.com/acme/app/pull/33"
  log "$home" unanswered "$OLD" 'needs-decision: approve?' 'working: polishing'
  task "$home" gitlab "pr=https://gitlab.com/acme/app/-/merge_requests/4"
  log "$home" gitlab "$OLD" 'needs-decision: approve?' 'working: polishing'
  printf '%s\n' 'https://github.com/acme/app/pull/32 MERGED' > "$home/gh-states"
  # Every agent is still there, so nothing but the PR state can close a record.
  live_agent "$home" recorded 5001
  live_agent "$home" forge 5002
  live_agent "$home" unanswered 5003
  live_agent "$home" gitlab 5004

  out=$(sweep "$home" --no-forge 2>&1)
  has_row "$out" close recorded default pr-merged "a recorded merge outcome needs no forge read"
  no_row_for "$out" forge "--no-forge still read the forge"
  [ ! -s "$home/gh-log" ] || fail "--no-forge called gh: $(cat "$home/gh-log")"

  out=$(sweep "$home" 2>&1)
  has_row "$out" close recorded default pr-merged "a recorded merge outcome closes"
  has_row "$out" close forge default pr-merged "a merge the forge reports closes"
  no_row_for "$out" unanswered "a PR the forge could not answer for closed a record"
  no_row_for "$out" gitlab "a merge request the sweep cannot read closed a record"
  assert_not_contains "$(cat "$home/gh-log")" 'pull/31' "the forge was asked about a merge already recorded"
  pass "a PR is merged by this home's own record or the forge's answer, and an unknown PR state never closes"
}

test_filters_and_refusals() {
  local home out status before
  home=$(make_reason_home filters)
  before=$(state_fingerprint "$home")

  out=$(sweep "$home" --reason pr-merged,no-record-48h 2>&1); status=$?
  expect_code 0 "$status" "--reason must succeed: $out"
  assert_contains "$out" $'summary\tdry-run\tclose=2\theld=0\tprotected=0\tkept=5\tfailed=0' "--reason limits the sweep to the named reasons"
  has_row "$out" close t-merged review pr-merged "--reason kept a named reason"
  no_row_for "$out" t-done "--reason let an unnamed reason through"

  out=$(sweep "$home" --task t-open 2>&1); status=$?
  expect_code 0 "$status" "--task must succeed: $out"
  has_row "$out" kept t-open default agent-alive "--task shows why its record is kept"
  no_row_for "$out" t-done "--task read another task"

  out=$(sweep "$home" --apply --task t-done 2>&1); status=$?
  expect_code 0 "$status" "--apply --task must succeed: $out"
  has_row "$out" closed t-done default last-line-done "--apply --task closes that task's record"
  cmp -s <(printf '%s\n' "$before" | grep -v ' ./t-done.status$') <(state_fingerprint "$home" | grep -v ' ./t-done.status$' | grep -v '/\.') \
    || fail "--apply --task wrote outside its task"

  out=$(sweep "$home" --reason nonsense 2>&1); status=$?
  expect_code 2 "$status" "an unknown reason is a usage error"
  assert_contains "$out" "unknown reason 'nonsense'" "the usage error names the bad reason"
  out=$(sweep "$home" --task '../x' 2>&1); status=$?
  expect_code 2 "$status" "a task id with a path in it is a usage error"
  out=$(sweep "$home" --frobnicate 2>&1); status=$?
  expect_code 2 "$status" "an unknown flag is a usage error"
  out=$(sweep "$home" --help 2>&1); status=$?
  expect_code 0 "$status" "--help must succeed"
  assert_contains "$out" 'fm-decisions-sweep.sh --apply' "--help prints the usage"

  # The supervision branch reads; only main closes.
  before=$(state_fingerprint "$home")
  out=$(FM_SUPERVISION_ACTOR=branch sweep "$home" --apply 2>&1); status=$?
  expect_code 6 "$status" "the branch actor must be refused on --apply"
  [ "$(state_fingerprint "$home")" = "$before" ] || fail "the branch actor closed a record"
  out=$(FM_SUPERVISION_ACTOR=branch sweep "$home" 2>&1); status=$?
  expect_code 0 "$status" "the branch actor may run the dry run: $out"
  pass "--reason and --task narrow the sweep, bad arguments are usage errors, and only main may --apply"
}

test_dry_run_is_default_names_each_reason_and_writes_nothing
test_recent_or_live_task_is_never_touched
test_owned_records_are_held
test_apply_appends_one_closing_line_per_record_and_nothing_else
test_repeat_sweep_reports_the_tasks_own_reason
test_repeat_sweep_never_closes_a_live_tasks_record_as_resolved
test_repeat_sweep_closes_a_dead_tasks_record_as_no_process
test_pr_state_comes_from_the_recorded_merge_or_the_forge_and_unknown_never_closes
test_filters_and_refusals

echo "all fm-decisions-sweep tests passed"

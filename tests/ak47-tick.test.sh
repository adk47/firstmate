#!/usr/bin/env bash
# tests/ak47-tick.test.sh - the deterministic tick, and the refusals that matter.
#
# The tick is the only part of this system that removes anything, so the tests
# that matter are the ones where it declines. Every case below builds a real
# tree, puts a real live process in it, and asserts the tick left it alone.
#
# Hermetic: AK47_TMP_ROOT points the tick at a mktemp tree, and AK47_STATE,
# AK47_CACHE and AK47_CONFIG all point inside it. Nothing reads or writes the
# real /tmp or the real ~/.local/state/ak47.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$ROOT/ak47/tick.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SANDBOX=
cleanup() {
  # Kill any holder subshell this suite started before removing the tree.
  [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}
trap cleanup EXIT
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/ak47-tick-tests.XXXXXX")

export AK47_STATE=$SANDBOX/state
export AK47_CACHE=$SANDBOX/cache
export AK47_CONFIG=$SANDBOX/config
export AK47_TMP_ROOT=$SANDBOX/tmp
export FM_HOME=$SANDBOX/fmhome
mkdir -p "$AK47_STATE" "$AK47_CACHE" "$AK47_CONFIG" "$AK47_TMP_ROOT" "$FM_HOME/state" "$FM_HOME/bin"

# A config that makes every class fire immediately, so the tests do not have to
# wait a day for a leak to age.
write_config() {
  cat >"$AK47_CONFIG/devops.conf" <<'CONF'
tmp_mktemp_min=0
tmp_producer_min=0
orphan_min=0
quarantine_days=7
# 0 means "the tree is always over its ceiling", so every class fires in the
# fixture without the test having to build 200,000 entries.
tmp_max_entries=0
tmp_max_moves=2000
swap_pressure=0
fat_process=0
fat_process_gb=3
fat_process_min=10
interval_seconds=300
CONF
}

# Age a path so the age gate passes without waiting.
age() { touch -d '3 days ago' "$1"; }

reset_tree() {
  rm -rf "$AK47_TMP_ROOT" "$AK47_STATE"
  mkdir -p "$AK47_TMP_ROOT" "$AK47_STATE"
  write_config
}

# --- the refusals ---------------------------------------------------------------

test_refuses_a_directory_a_live_process_is_sitting_in() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpa003ltt_
  mkdir -p "$d"; age "$d"
  # A real process whose cwd is inside the candidate. This is the case a
  # name-based sweeper gets wrong.
  ( cd "$d" && sleep 30 ) &
  HOLDER_PID=$!
  sleep 0.3
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a directory a live process was sitting in"
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=
  pass "tick refuses a directory a live process is sitting in"
}

test_refuses_a_directory_a_live_process_has_a_file_open_in() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpb004muu_
  mkdir -p "$d"
  printf 'held\n' >"$d/open.txt"
  age "$d"; age "$d/open.txt"
  # A process holding an open descriptor on a file inside the candidate. Its cwd
  # is elsewhere, so only a handle scan finds it.
  ( exec 3<"$d/open.txt"; sleep 30 ) &
  HOLDER_PID=$!
  sleep 0.3
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a directory holding an open file descriptor"
  kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=
  pass "tick refuses a directory holding an open file descriptor"
}

test_refuses_a_live_tasks_scratch_root() {
  reset_tree
  local d=$AK47_TMP_ROOT/fm-livetask
  mkdir -p "$d/gotmp" "$d/tmp"
  age "$d"
  # A live task record is the only thing that makes this scratch root live.
  printf 'window=x:fm-livetask\n' >"$FM_HOME/state/livetask.meta"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a live task's scratch root"
  pass "tick refuses a live task's scratch root"
}

test_quarantines_an_orphaned_task_scratch_root() {
  reset_tree
  local d=$AK47_TMP_ROOT/fm-deadtask
  mkdir -p "$d/gotmp"
  age "$d"
  # No state/deadtask.meta: the task is gone, the scratch root is not.
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$d" ] || fail "tick left an orphaned task scratch root in place"
  pass "tick quarantines an orphaned task scratch root"
}

test_refuses_every_named_protected_path() {
  reset_tree
  local name
  for name in fm-move ak47-state orcad-1 systemd-private-x snap-foo \
              .X11-unix .ICE-unix .font-unix .Test-unix .XIM-unix \
              cli-proxy-api.sock forwarder.token my-router.sh; do
    mkdir -p "$AK47_TMP_ROOT/$name"
    age "$AK47_TMP_ROOT/$name"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  for name in fm-move ak47-state orcad-1 systemd-private-x snap-foo \
              .X11-unix .ICE-unix .font-unix .Test-unix .XIM-unix \
              cli-proxy-api.sock forwarder.token my-router.sh; do
    [ -e "$AK47_TMP_ROOT/$name" ] || fail "tick removed the protected path $name"
  done
  pass "tick refuses every named protected path"
}

test_refuses_a_symlink_that_points_at_a_protected_path() {
  reset_tree
  # A symlink whose NAME is innocuous but whose target is protected. The
  # classifier canonicalises a symlink before deciding, so this must survive.
  mkdir -p "$AK47_TMP_ROOT/ak47-real"
  ln -s "$AK47_TMP_ROOT/ak47-real" "$AK47_TMP_ROOT/tmpc005nnn_"
  age "$AK47_TMP_ROOT/tmpc005nnn_"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -L "$AK47_TMP_ROOT/tmpc005nnn_" ] \
    || fail "tick removed a symlink pointing at a protected path"
  pass "tick refuses a symlink that points at a protected path"
}

test_refuses_a_young_leak() {
  reset_tree
  # Age gate at one day, and the candidate is one minute old: a suite that is
  # still running must never be touched.
  sed -i 's/^tmp_mktemp_min=.*/tmp_mktemp_min=1440/' "$AK47_CONFIG/devops.conf"
  local d=$AK47_TMP_ROOT/tmpd006ooo_
  mkdir -p "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick removed a leak younger than its age gate"
  pass "tick refuses a leak younger than its age gate"
}

# --- the actions ----------------------------------------------------------------

test_quarantines_a_leaked_default_temp_dir() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpe007ppp_
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$d" ] || fail "tick left a leaked default temp dir in place"
  # Quarantine, not deletion: the entry must still exist under the state dir.
  local found
  found=$(find "$AK47_STATE/quarantine" -maxdepth 2 -name 'tmpe007ppp_' -print -quit 2>/dev/null)
  [ -n "$found" ] || fail "tick deleted the entry instead of quarantining it"
  pass "tick quarantines a leaked default temp dir, and the revert path exists"
}

test_quarantines_a_leaked_named_producer_dir() {
  reset_tree
  local name
  for name in uvn-abc123 wc-1 irc-2 merge-outcome-x twin-req-9 \
              puppeteer_dev_chrome_profile-zz rmtc-1 restore-test-1 csv-1; do
    mkdir -p "$AK47_TMP_ROOT/$name"; age "$AK47_TMP_ROOT/$name"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  for name in uvn-abc123 wc-1 irc-2 merge-outcome-x twin-req-9 \
              puppeteer_dev_chrome_profile-zz rmtc-1 restore-test-1 csv-1; do
    [ ! -e "$AK47_TMP_ROOT/$name" ] || fail "tick left the leaked producer dir $name"
  done
  pass "tick quarantines every named producer prefix"
}

test_quarantined_entry_keeps_its_full_revert_window() {
  reset_tree
  # mv preserves mtime, so an entry that was already old when it was moved into
  # quarantine must still get its full window measured from the move day.
  local day entry
  day=$(date -u +%Y%m%d)
  entry="$AK47_STATE/quarantine/$day/tmpold001aaa_"
  mkdir -p "$entry"
  touch -d '30 days ago' "$entry"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$entry" ] \
    || fail "tick deleted a just-quarantined entry because its mtime was old"
  pass "a quarantined entry keeps its full revert window regardless of its mtime"
}

test_expires_an_entry_after_its_quarantine_window() {
  reset_tree
  local day entry
  day=$(date -u -d '8 days ago' +%Y%m%d)
  entry="$AK47_STATE/quarantine/$day/tmpold002bbb_"
  mkdir -p "$entry"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ ! -e "$entry" ] \
    || fail "tick kept an entry past its quarantine window"
  pass "an entry is deleted once its dated quarantine directory is past the window"
}

test_dry_run_changes_nothing() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpf008qqq_
  mkdir -p "$d"; age "$d"
  "$TICK" --dry-run >/dev/null 2>&1 || fail "dry run exited non-zero"
  [ -d "$d" ] || fail "dry run removed an entry"
  [ ! -d "$AK47_STATE/quarantine" ] || fail "dry run created a quarantine directory"
  pass "dry run changes nothing"
}

test_stops_quarantining_once_under_the_entry_ceiling() {
  reset_tree
  # Ceiling of 2 entries, and the tree already has 2: the tick must stop, because
  # tmp_max_entries is the point at which the tick stops working, not a per-run
  # move budget.
  sed -i 's/^tmp_max_entries=.*/tmp_max_entries=2/' "$AK47_CONFIG/devops.conf"
  local d=$AK47_TMP_ROOT/tmpg009rrr_
  mkdir -p "$d" "$AK47_TMP_ROOT/tmph010sss_"
  age "$d"; age "$AK47_TMP_ROOT/tmph010sss_"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -d "$d" ] || fail "tick kept quarantining past its entry ceiling"
  pass "tick stops quarantining once the tree is under its entry ceiling"
}

test_stops_as_soon_as_the_live_tree_crosses_the_ceiling() {
  reset_tree
  # Three candidates, a ceiling of 2, and a move budget far above the number of
  # candidates. The tick must stop after the first move brings the live tree to
  # the ceiling, not spend the whole per-run budget.
  sed -i 's/^tmp_max_entries=.*/tmp_max_entries=2/' "$AK47_CONFIG/devops.conf"
  local d
  for d in tmpi011aaa_ tmpj012bbb_ tmpk013ccc_; do
    mkdir -p "$AK47_TMP_ROOT/$d"
    age "$AK47_TMP_ROOT/$d"
  done
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local n
  n=$(find "$AK47_STATE/quarantine" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
  [ "$n" -eq 1 ] || fail "tick moved $n entries instead of stopping at the ceiling"
  pass "tick stops as soon as the live tree crosses the entry ceiling"
}

test_quarantines_a_same_day_name_collision_without_nesting() {
  reset_tree
  local d=$AK47_TMP_ROOT/tmpl014ddd_
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "first tick exited non-zero"
  # A producer recreates the same name on the same UTC day.
  mkdir -p "$d"; age "$d"
  "$TICK" --apply >/dev/null 2>&1 || fail "second tick exited non-zero"
  local day
  day=$(find "$AK47_STATE/quarantine" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -n "$day" ] || fail "tick did not quarantine either entry"
  [ -d "$day/tmpl014ddd_" ] || fail "first quarantined entry is missing"
  [ -d "$day/tmpl014ddd_.1" ] || fail "second quarantined entry did not get a unique name"
  [ ! -e "$day/tmpl014ddd_/tmpl014ddd_" ] || fail "second entry was nested inside the first"
  pass "a same-day name collision is quarantined under a unique name, not nested"
}

# --- the log --------------------------------------------------------------------

test_writes_exactly_one_line_per_run() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "first run exited non-zero"
  "$TICK" --apply >/dev/null 2>&1 || fail "second run exited non-zero"
  local n
  n=$(wc -l <"$AK47_STATE/devops.log")
  [ "$n" -eq 2 ] || fail "expected 2 log lines after 2 runs, got $n"
  pass "the tick writes exactly one log line per run, so silence is provable"
}

test_the_log_line_carries_the_verdict() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local line
  line=$(tail -n 1 "$AK47_STATE/devops.log")
  local field
  for field in tick mode= tmp_before= tmp_after= moved= deleted= busy= \
               protected= failures= actions= loop_gap= classes= breaches= top=; do
    case "$line" in
      *"$field"*) : ;;
      *) fail "log line is missing $field: $line" ;;
    esac
  done
  pass "the log line carries every field a reader needs without a second read"
}

test_writes_a_numeric_sample_for_the_weekly_review() {
  reset_tree
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -s "$AK47_STATE/samples.log" ] || fail "tick wrote no samples.log line"
  local line first
  line=$(tail -n 1 "$AK47_STATE/samples.log")
  first=${line%% *}
  case "$first" in
    ''|*[!0-9]*) fail "sample line does not start with an epoch: $line" ;;
  esac
  case "$line" in
    *load15=*) : ;;
    *) fail "sample line is missing load15: $line" ;;
  esac
  case "$line" in
    *tmp_entries=*) : ;;
    *) fail "sample line is missing tmp_entries: $line" ;;
  esac
  # Every metric must contribute exactly one number. A sampler that prints two
  # lines (pgrep -c prints 0 AND exits 1 on no match) splits the sample across
  # two lines and the review silently reads a bare "0" as the whole sample.
  local n
  n=$(wc -l <"$AK47_STATE/samples.log")
  [ "$n" -eq 1 ] || fail "one run wrote $n sample lines; expected exactly 1"
  case "$line" in
    *agent_count=*) : ;;
    *) fail "sample line is missing agent_count: $line" ;;
  esac
  local agents
  agents=$(printf '%s\n' "$line" | sed -n 's/.*agent_count=\([^ ]*\).*/\1/p')
  case "$agents" in
    ''|*[!0-9]*) fail "agent_count is not a single number: '$agents' in $line" ;;
    *) : ;;
  esac
  pass "the tick writes the numeric sample the weekly review reads"
}

test_reports_its_own_loop_gap() {
  reset_tree
  # A previous run 4 hours ago, against a 300s interval: the tick must notice
  # that its own loop stopped, because a loop that dies silently is worse than
  # no loop.
  # The log line's first field is the ISO timestamp ak47_log writes, so the
  # fixture has to use the same spelling the reader parses.
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  local line
  line=$(tail -n 1 "$AK47_STATE/devops.log")
  case "$line" in
    *loop_gap=1[0-9][0-9][0-9][0-9]s*) : ;;
    *) fail "tick did not report a four-hour loop gap: $line" ;;
  esac
  grep -q 'loop-gap' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "tick reported a loop gap on its log line but filed no finding"
  pass "the tick notices and files its own loop gap"
}

test_refuses_a_malformed_config() {
  reset_tree
  sed -i 's/^tmp_mktemp_min=.*/tmp_mktemp_min=soon/' "$AK47_CONFIG/devops.conf"
  if "$TICK" --apply >/dev/null 2>&1; then
    fail "tick accepted a non-numeric config value"
  fi
  pass "tick refuses a malformed config value instead of guessing"
}

# --- the fat-process escalation and the finding delivery ----------------------

test_escalates_an_ignored_sigterm_to_sigkill() {
  reset_tree
  sed -i 's/^fat_process=.*/fat_process=1/' "$AK47_CONFIG/devops.conf"
  sleep 60 &
  local p=$!
  # A record from ten minutes ago: the tick that sent SIGTERM is long gone, so
  # only the durable clock can escalate.
  printf '%s %s\n' "$p" "$(( $(date +%s) - 600 ))" >"$AK47_STATE/fat.term"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  sleep 0.2
  if kill -0 "$p" 2>/dev/null; then
    kill -KILL "$p" 2>/dev/null
    fail "tick did not SIGKILL a pid that ignored SIGTERM for ten minutes"
  fi
  grep -q 'SIGKILL' "$AK47_STATE/reap.log" 2>/dev/null \
    || fail "the escalation was not logged with its revert"
  [ -s "$AK47_STATE/fat.term" ] && fail "the fat.term record survived the kill"
  pass "tick escalates an ignored SIGTERM to SIGKILL across runs"
}

test_a_dry_run_does_not_consume_the_escalation() {
  reset_tree
  sed -i 's/^fat_process=.*/fat_process=1/' "$AK47_CONFIG/devops.conf"
  sleep 60 &
  local p=$! stamp
  stamp=$(( $(date +%s) - 600 ))
  printf '%s %s\n' "$p" "$stamp" >"$AK47_STATE/fat.term"
  "$TICK" --dry-run >/dev/null 2>&1 || fail "tick exited non-zero"
  kill -0 "$p" 2>/dev/null || fail "a dry run killed a process"
  grep -q "^$p $stamp$" "$AK47_STATE/fat.term" 2>/dev/null \
    || fail "a dry run consumed the escalation record, so the next real tick would miss it"
  grep -q 'fat-process' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "a dry run did not file a finding for the escalation it would perform"
  kill -KILL "$p" 2>/dev/null
  pass "a dry run neither kills nor consumes the escalation record"
}

test_commits_a_finding_key_only_after_delivery() {
  reset_tree
  # A failed inbox send must leave the dedupe key uncommitted, or the finding is
  # silenced for six hours. The fake fm-inbox.sh is the only delivery path.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -f "$AK47_STATE/keys/loop-gap" ] \
    && fail "a finding's dedupe key was committed before its note was delivered"
  grep -q 'DELIVERY-FAILED' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "a failed delivery was not recorded"
  pass "a failed delivery does not commit the finding's dedupe key"
}

test_delivery_commits_the_key_so_the_next_tick_is_quiet() {
  reset_tree
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FM_HOME/bin/fm-inbox.sh"
  chmod +x "$FM_HOME/bin/fm-inbox.sh"
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  [ -f "$AK47_STATE/keys/loop-gap" ] \
    || fail "a delivered finding did not commit its dedupe key"
  pass "a delivered finding commits its key so it is not re-sent"
}

test_reports_a_dry_run_that_outlived_its_24_hours() {
  reset_tree
  # The first tick line is 25 hours old, and both acting classes are still
  # report-only: the tick must say so without arming itself.
  printf '%s tick mode=apply tmp_before=0 tmp_after=0\n' \
    "$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ)" >"$AK47_STATE/devops.log"
  "$TICK" --apply >/dev/null 2>&1 || fail "tick exited non-zero"
  grep -q 'swap-unarmed' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "the tick did not flag a report-only class past its 24 h dry run"
  grep -q 'fat-unarmed' "$AK47_STATE/findings.log" 2>/dev/null \
    || fail "the tick did not flag fat-process past its 24 h dry run"
  pass "the tick flags a report-only class that outlived its dry run"
}

test_refuses_a_directory_a_live_process_is_sitting_in
test_refuses_a_directory_a_live_process_has_a_file_open_in
test_refuses_a_live_tasks_scratch_root
test_quarantines_an_orphaned_task_scratch_root
test_refuses_every_named_protected_path
test_refuses_a_symlink_that_points_at_a_protected_path
test_refuses_a_young_leak
test_quarantines_a_leaked_default_temp_dir
test_quarantines_a_leaked_named_producer_dir
test_quarantined_entry_keeps_its_full_revert_window
test_expires_an_entry_after_its_quarantine_window
test_dry_run_changes_nothing
test_stops_quarantining_once_under_the_entry_ceiling
test_stops_as_soon_as_the_live_tree_crosses_the_ceiling
test_quarantines_a_same_day_name_collision_without_nesting
test_writes_exactly_one_line_per_run
test_the_log_line_carries_the_verdict
test_writes_a_numeric_sample_for_the_weekly_review
test_reports_its_own_loop_gap
test_refuses_a_malformed_config
test_escalates_an_ignored_sigterm_to_sigkill
test_a_dry_run_does_not_consume_the_escalation
test_commits_a_finding_key_only_after_delivery
test_delivery_commits_the_key_so_the_next_tick_is_quiet
test_reports_a_dry_run_that_outlived_its_24_hours

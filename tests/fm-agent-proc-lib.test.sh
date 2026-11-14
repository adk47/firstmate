#!/usr/bin/env bash
# tests/fm-agent-proc-lib.test.sh - is a live agent process sitting in a task's
# worktree (bin/fm-agent-proc-lib.sh).
#
# Most cases drive the lookup from a fake process table (FM_AGENT_PROC_TABLE),
# so they assert the matching rules without depending on what is running on the
# host. The last case reads the REAL process table and finds a real stand-in
# process, because the fake table cannot prove the host read itself works.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-proc-lib)

# Run the lookup in a fresh shell so each case gets the library's own sourcing
# order and nothing leaks between cases. Prints the rows, then "rc=<code>".
lookup() {  # <table-file|''> <worktree>
  FM_AGENT_PROC_TABLE=$1 bash -c '
    . "$1/bin/fm-tmux-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-agent-proc-lib.sh"
    fm_agent_proc_in_worktree "$2"; printf "rc=%s\n" "$?"' _ "$ROOT" "$2"
}

row() {  # <pid> <comm> <cwd> <args>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

test_agent_found_by_working_directory() {
  local d=$TMP_ROOT/cwd out; mkdir -p "$d/wt/sub"
  {
    row 100 bash "$d/wt" "-bash"
    row 4242 pi "$d/wt" "pi"
    row 4243 claude "$d/wt/sub" "claude --resume"
  } > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "rc=0" "an agent in the worktree was not found"
  assert_contains "$out" "4242	pi" "the pi process in the worktree was not reported"
  assert_contains "$out" "4243	claude" "an agent in a subdirectory of the worktree was not reported"
  assert_not_contains "$out" "100	" "a plain shell was reported as an agent"
  pass "an agent is found by its working directory, at the worktree or below it"
}

test_agent_found_by_arguments() {
  local d=$TMP_ROOT/args out; mkdir -p "$d/wt"
  {
    row 501 pi /somewhere/else "pi --cwd $d/wt --model x"
    row 502 codex /somewhere/else "codex --cd=$d/wt"
    row 503 claude /somewhere/else "claude --add-dir \"$d/wt\""
    row 504 opencode /somewhere/else "opencode $d/wt/"
  } > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "rc=0" "an agent naming the worktree in its arguments was not found"
  assert_contains "$out" "501	pi" "a space-separated worktree argument was not matched"
  assert_contains "$out" "502	codex" "an =-joined worktree argument was not matched"
  assert_contains "$out" "503	claude" "a quoted worktree argument was not matched"
  assert_contains "$out" "504	opencode" "a worktree argument with a trailing slash was not matched"
  pass "an agent is found when only its arguments name the worktree"
}

test_only_this_worktree_matches() {
  local d=$TMP_ROOT/siblings out; mkdir -p "$d/wt" "$d/wt-other" "$d/wt2"
  {
    row 601 pi "$d/wt-other" "pi"
    row 602 pi "$d/wt2" "pi"
    row 603 pi /elsewhere "pi --cwd $d/wt-other"
    row 604 pi /elsewhere "pi --cwd $d/wt2/sub"
    row 605 pi "$d/wt (deleted)" "pi"
    row 606 pi "$d" "pi"
  } > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "rc=1" "an agent in a sibling or parent directory was attributed to this worktree"
  pass "a sibling worktree sharing the path prefix, a parent, and a deleted directory do not match"
}

test_only_agent_processes_match() {
  local d=$TMP_ROOT/names out; mkdir -p "$d/wt"
  {
    row 701 bash "$d/wt" "bash tests/run.sh"
    row 702 node "$d/wt" "node server.js"
    row 703 sleep "$d/wt" "sleep 900"
    row 704 -zsh "$d/wt" "-zsh"
    row 705 git "$d/wt" "git status"
  } > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "rc=1" "a non-agent process in the worktree was reported as an agent"
  pass "shells, interpreters, and tools in the worktree are not agents"
}

test_full_path_command_name_is_recognized() {
  # macOS reports the executable path as the command name.
  local d=$TMP_ROOT/pathname out; mkdir -p "$d/wt"
  row 801 /usr/local/bin/pi "$d/wt" "/usr/local/bin/pi" > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "801	pi" "a path-form command name was not recognized or not shortened to its name"
  pass "a command name reported as a full path is recognized"
}

test_recorded_symlink_path_matches_the_resolved_one() {
  # The kernel reports resolved paths; a task may have recorded a symlinked one.
  local d=$TMP_ROOT/symlink out phys; mkdir -p "$d/real/wt"
  ln -s "$d/real" "$d/link"
  phys=$(cd "$d/real/wt" && pwd -P)
  row 901 pi "$phys" "pi" > "$d/table"
  out=$(lookup "$d/table" "$d/link/wt")
  assert_contains "$out" "rc=0" "an agent was not found through the worktree's symlinked recorded path"
  out=$(lookup "$d/table" "$d/link/wt/")
  assert_contains "$out" "rc=0" "a trailing slash on the worktree path defeated the match"
  pass "a worktree recorded through a symlink matches the resolved working directory"
}

test_unreadable_table_is_not_absence() {
  local d=$TMP_ROOT/unreadable out; mkdir -p "$d/wt"
  out=$(lookup "$d/no-such-table" "$d/wt")
  assert_contains "$out" "rc=2" "an unreadable process table was reported as an empty one"
  : > "$d/table"
  out=$(lookup "$d/table" "$d/wt")
  assert_contains "$out" "rc=1" "a readable table with no rows was not reported as holding no agent"
  out=$(lookup "$d/table" "")
  assert_contains "$out" "rc=2" "a missing worktree argument was not refused"
  pass "an unreadable table and a missing worktree are no-evidence, never absence"
}

test_recognized_harnesses() {
  local out
  out=$(bash -c '
    . "$1/bin/fm-tmux-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-agent-proc-lib.sh"
    for h in pi claude codex opencode gemini ""; do
      if fm_agent_proc_recognizes "$h"; then printf "%s=yes " "$h"; else printf "%s=no " "$h"; fi
    done' _ "$ROOT")
  assert_contains "$out" "pi=yes claude=yes codex=yes opencode=yes gemini=yes =no" \
    "the recognized-harness answer changed"
  pass "absence is evidence only for a harness the process table can name"
}

# The real read: a real stand-in process named `pi`, started in a real
# directory, must be found by the host process table and stop being found once
# it exits. The stand-in is compiled where a C compiler exists and is a symlink
# to sleep otherwise (tests/fm-tmux-agent-liveness.test.sh explains why neither
# alone is portable); where neither yields a running process the case skips.
test_real_process_table_finds_a_real_process() {
  local d=$TMP_ROOT/real cc sleep_bin pid out found=0
  mkdir -p "$d/bin" "$d/wt" "$d/wt-other"
  sleep_bin=$(command -v sleep) || { echo "skip: real process table - sleep not found"; return 0; }
  cc=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
  if [ -n "$cc" ]; then
    printf '%s\n' '#include <unistd.h>' 'int main(void){sleep(120);return 0;}' > "$d/spin.c"
    "$cc" -o "$d/bin/pi" "$d/spin.c" 2>/dev/null || ln -sf "$sleep_bin" "$d/bin/pi"
  else
    ln -sf "$sleep_bin" "$d/bin/pi"
  fi
  ( cd "$d/wt" && exec "$d/bin/pi" 120 ) >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "skip: real process table - no runnable stand-in agent on this platform"
    return 0
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(lookup "" "$d/wt")
    case "$out" in *"$pid	pi"*) found=1; break ;; esac
    sleep 0.3
  done
  if [ "$found" != 1 ]; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "the real process table did not report the live stand-in agent (last answer: $out)"
  fi
  out=$(lookup "" "$d/wt-other")
  case "$out" in
    *rc=1*) ;;
    *) kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
       fail "the real process table attributed the agent to a sibling directory ($out)" ;;
  esac
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  found=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(lookup "" "$d/wt")
    case "$out" in *rc=1*) found=0; break ;; esac
    sleep 0.3
  done
  [ "$found" = 0 ] || fail "the real process table still reported the agent after it exited ($out)"
  pass "the real process table finds a live agent in its worktree and loses it when it exits"
}

# Print the writers of a file, then "rc=<code>".
writers() {  # <open-files-table|''> <file>
  FM_AGENT_PROC_OPEN_FILES=$1 bash -c '
    . "$1/bin/fm-tmux-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-agent-proc-lib.sh"
    fm_agent_proc_file_writers "$2"; printf "rc=%s\n" "$?"' _ "$ROOT" "$2"
}

test_file_writers_are_writers_only() {
  local d=$TMP_ROOT/writers out; mkdir -p "$d/real"
  ln -s "$d/real" "$d/link"
  : > "$d/real/a.status"; : > "$d/real/b.status"
  {
    printf '%s\t%s\t%s\t%s\n' 700 pi w "$d/real/a.status"
    printf '%s\t%s\t%s\t%s\n' 701 tail r "$d/real/a.status"
    printf '%s\t%s\t%s\t%s\n' 702 bash w "$d/real/a.status.bak"
    printf '%s\t%s\t%s\t%s\n' 703 tail r "$d/real/b.status"
  } > "$d/open"
  out=$(writers "$d/open" "$d/real/a.status")
  assert_contains "$out" "700	pi" "the process holding the log open for writing was not reported"
  assert_not_contains "$out" "701" "a reader of the log was reported as its writer"
  assert_not_contains "$out" "702" "a writer of a different file sharing the name prefix was reported"
  assert_contains "$out" "rc=0" "a found writer did not return success"
  out=$(writers "$d/open" "$d/link/a.status")
  assert_contains "$out" "700	pi" "a log named through a symlinked directory lost its writer"
  out=$(writers "$d/open" "$d/real/b.status")
  assert_contains "$out" "rc=1" "a log that is only read was not reported as having no writer seen"
  out=$(writers "$d/no-such-table" "$d/real/a.status")
  assert_contains "$out" "rc=2" "unreadable open files were reported as no writer"
  out=$(writers "$d/open" "")
  assert_contains "$out" "rc=2" "a missing file argument was not refused"
  pass "only a process holding the file open for writing is its writer; unreadable is not none"
}

test_real_open_files_find_a_real_writer() {
  local d=$TMP_ROOT/real-writers wpid rpid out found=0
  mkdir -p "$d"; : > "$d/x.status"
  ( exec 9>>"$d/x.status"; exec sleep 120 ) >/dev/null 2>&1 &
  wpid=$!
  ( exec 8<"$d/x.status"; exec sleep 120 ) >/dev/null 2>&1 &
  rpid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    out=$(writers "" "$d/x.status")
    case "$out" in *rc=2*) break ;; esac
    case "$out" in *"$wpid	"*) found=1; break ;; esac
    sleep 0.3
  done
  kill "$wpid" "$rpid" 2>/dev/null; wait "$wpid" "$rpid" 2>/dev/null
  case "$out" in
    *rc=2*) echo "skip: real open files - not readable on this platform"; return 0 ;;
  esac
  [ "$found" = 1 ] || fail "the real open-file read did not report the process holding the log for writing ($out)"
  assert_not_contains "$out" "$rpid	" "the real open-file read reported a reader as a writer"
  pass "the real open-file read finds a live writer and never a reader"
}

test_agent_found_by_working_directory
test_agent_found_by_arguments
test_only_this_worktree_matches
test_only_agent_processes_match
test_full_path_command_name_is_recognized
test_recorded_symlink_path_matches_the_resolved_one
test_unreadable_table_is_not_absence
test_recognized_harnesses
test_real_process_table_finds_a_real_process
test_file_writers_are_writers_only
test_real_open_files_find_a_real_writer

echo "all fm-agent-proc-lib tests passed"

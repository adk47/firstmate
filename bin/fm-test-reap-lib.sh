# shellcheck shell=bash
# fm-test-reap-lib.sh - the single owner of reaping processes a behavior test
# left running under its own fixture directory.
#
# Sourced, never executed. Used by bin/fm-test-run.sh after every concurrent
# script (whose TMPDIR is a private per-script directory) and by tests/lib.sh's
# fm_test_reap_fixture_processes for a test's own EXIT/INT/TERM/HUP cleanup.
#
#   fm_test_processes_under <dir>
#       Prints the pid of every process whose command line names a path under
#       <dir>/ (the directory itself followed by a slash), one per line, never
#       this shell or its ancestors.
#   fm_test_signal_processes_under <dir> <signal>
#       Sends <signal> to every such process at once, without waiting.
#   fm_test_reap_processes_under <dir>
#       Sends TERM to every such process, waits up to
#       FM_TEST_REAP_WAIT_SECS (default 5) for them to exit, sends KILL to any
#       survivor, and rescans so a child a supervisor restarted mid-reap is
#       caught too. Prints one "reaped <pid> <command>" line per process it
#       signaled, to stderr. Returns 0 when nothing is left.
#
# WHY. A test that starts a long-lived server - the remote job worker runs in
# its own process group so a stop can signal its whole tree - outlives a test
# killed by its time bound, and then serves forever from a fixture root that
# nothing removes: four such workers once ran for 32 hours. Matching on the
# fixture path, not a recorded pid, finds a restarted child, a lane, and a
# supervisor alike, and never touches another run's processes, because every
# fixture directory is unique to its test.
#
# The directory must be an absolute path of a test-owned fixture or per-script
# temp root; a path shorter than 8 characters is refused so a bad argument can
# never match the whole process table.

fm_test_processes_under() {  # <dir>
  local dir=${1%/} self
  case "$dir" in /*) ;; *) return 1 ;; esac
  [ "${#dir}" -ge 8 ] || return 1
  self=${BASHPID:-$$}
  # The directory travels through the environment, so the awk process's own
  # command line never matches it.
  ps -eo pid=,ppid=,args= 2>/dev/null \
    | FM_TEST_REAP_DIR="$dir/" FM_TEST_REAP_SELF="$self" FM_TEST_REAP_TOP="$$" LC_ALL=C awk '
      BEGIN { dir = ENVIRON["FM_TEST_REAP_DIR"]; self = ENVIRON["FM_TEST_REAP_SELF"]; top = ENVIRON["FM_TEST_REAP_TOP"] }
      {
        pid = $1; ppid = $2
        parent[pid] = ppid
        line = $0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", line)
        if (index(line, dir) > 0) hit[pid] = 1
      }
      END {
        # Never this shell or any of its ancestors.
        p = self
        while (p != "" && p != "0" && p != "1" && !(p in seen)) { seen[p] = 1; skip[p] = 1; p = parent[p] }
        skip[top] = 1
        for (pid in hit) if (!(pid in skip)) print pid
      }'
}

# Send one signal to every process under <dir> without waiting: the first,
# fast pass of a cleanup that may itself be killed a second later (the
# per-script bound sends KILL one second after its TERM).
fm_test_signal_processes_under() {  # <dir> <signal>
  local pid pids
  pids=$(fm_test_processes_under "$1") || return 1
  for pid in $pids; do
    kill "-$2" "$pid" 2>/dev/null || true
  done
}

fm_test_reap_processes_under() {  # <dir>
  local dir=$1 pids pid round waited wait_secs left
  wait_secs=${FM_TEST_REAP_WAIT_SECS:-5}
  case "$wait_secs" in ''|*[!0-9]*) wait_secs=5 ;; esac
  for round in 1 2 3; do
    pids=$(fm_test_processes_under "$dir") || return 1
    [ -n "$pids" ] || return 0
    for pid in $pids; do
      printf 'reaped %s %s\n' "$pid" "$(ps -o args= -p "$pid" 2>/dev/null)" >&2
      kill -TERM "$pid" 2>/dev/null || true
    done
    waited=0
    left=$pids
    while [ "$waited" -lt $((wait_secs * 10)) ]; do
      left=
      for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && left="$left $pid"
      done
      [ -n "$left" ] || break
      sleep 0.1
      waited=$((waited + 1))
    done
    for pid in $left; do
      kill -KILL "$pid" 2>/dev/null || true
    done
    : "$round"
  done
  [ -z "$(fm_test_processes_under "$dir")" ]
}

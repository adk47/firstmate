#!/usr/bin/env bash
# fm-lane-liveness-lib.sh - the ONE owner of "is a live agent process actually
# running in this lane's worktree?".
#
# WHY THIS EXISTS. state/<id>.busy-state is a durable RECORD a harness hook
# writes (bin/fm-busy-lib.sh owns the format). Nothing clears it when the agent
# is hard-killed - SIGKILL, an OOM kill, a lost tmux server - so a dead lane
# keeps reporting `state=busy` forever, and every reader that trusts the record
# alone reports a corpse as working. On 2026-11-05 that is exactly how the fleet
# lost roughly 27 lanes while three successive health reads counted 11, then 15,
# then 27 dead: the record still said working, and only checking each lane
# against a live process got the truth.
#
# A record is evidence of what the agent last REPORTED, never proof it is still
# there. This library supplies the missing half: a live process whose CURRENT
# WORKING DIRECTORY is the lane's recorded worktree and whose process name
# classifies as an agent. The name test is load-bearing, not decoration: a
# lane's idle pane shell also sits in the worktree (fm-spawn creates the pane
# with -c <worktree>), so a cwd match alone would call a shell left behind by a
# dead agent a live lane. bin/backends/tmux.sh's
# fm_backend_tmux_classify_process_name owns that name vocabulary, and this
# library reuses it rather than growing a second one. Gemini is identified from
# its ARGUMENTS instead of its name, because the Gemini CLI is a node bundle
# whose comm is MainThread and whose argv[0] is the interpreter; the same
# structural rule the tmux pane probe uses (bin/fm-gemini-lib.sh) is reused
# here, never reimplemented.
#
# BOUNDED AND READ-ONLY. One `lsof -a -d cwd -Fpn` scan answers for every lane
# at once - bounded by process count, never by walking a worktree's file tree -
# and callers match only the recorded worktree paths they already hold. Nothing
# here writes, signals, or starts anything. The single-lane probe is one lsof
# scan per call, measured at about 0.35s on a 1355-process Linux box; a scan
# that cannot finish inside the caller's bound degrades to unknown, never to
# working.
#
# FAIL-SAFE DIRECTION. Only positive evidence of an agent reads as live, and
# only a worktree holding nothing but shells (or nothing at all) reads as
# provably dead. A scan that cannot be trusted, or a worktree holding a process
# this vocabulary cannot classify, is UNDETERMINABLE - never dead - because a
# false dead verdict is what launches a duplicate agent onto a live worktree.
#
# PATH FORMS. A recorded worktree keeps the logical path bin/fm-spawn.sh wrote,
# while a process's kernel cwd is always physical, so every recorded worktree is
# resolved physically before it is compared, and a match must be the worktree
# itself or a true path-component descendant - never a bare string prefix of an
# unrelated sibling like /x/fm-a versus /x/fm-ab.
#
# Sourcing: requires bin/fm-backend.sh already sourced (for
# fm_backend_source and FM_BACKEND_LIB_DIR). set -u safe.

FM_LANE_LIVENESS_LIB_VERSION=v1

# fm_lane_physical_path: the physical form of a directory path, so a recorded
# worktree and a kernel cwd can be compared. bin/fm-spawn.sh records the
# worktree with bash's LOGICAL pwd, which keeps any symlinked component; a
# process's cwd from lsof is always the PHYSICAL path. A path that no longer
# resolves is returned as recorded, which can only leave it unmatched when the
# directory is genuinely gone.
fm_lane_physical_path() {  # <path>
  local path=$1 physical
  [ -n "$path" ] || return 1
  physical=$(cd "$path" 2>/dev/null && pwd -P) || physical=
  if [ -n "$physical" ]; then
    printf '%s\n' "$physical"
  else
    printf '%s\n' "$path"
  fi
}

# fm_lane_cwd_scan: one bounded read-only scan of every process's current
# working directory, printed as "<pid>\t<cwd>" lines. Returns 1 when the scan
# cannot be trusted (no lsof, or lsof failed), which callers must treat as
# undeterminable rather than as "no live agent".
fm_lane_cwd_scan() {
  command -v lsof >/dev/null 2>&1 || return 1
  local out line pid
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd)
        [ -n "$pid" ] || return 1
        ;;
      n*)
        [ -n "$pid" ] || return 1
        printf '%s\t%s\n' "$pid" "${line#n}"
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# fm_lane_ensure_process_vocabulary: make the shared process-name classifier
# available. It lives in the tmux adapter because that adapter's liveness probe
# was its first owner; the vocabulary itself is harness-wide, so this library
# reuses it instead of duplicating the harness name list.
fm_lane_ensure_process_vocabulary() {
  if command -v fm_backend_tmux_classify_process_name >/dev/null 2>&1 \
    && command -v fm_gemini_args_are_gemini >/dev/null 2>&1; then
    return 0
  fi
  command -v fm_backend_source >/dev/null 2>&1 || return 1
  fm_backend_source tmux >/dev/null 2>&1 || return 1
  command -v fm_backend_tmux_classify_process_name >/dev/null 2>&1 \
    && command -v fm_gemini_args_are_gemini >/dev/null 2>&1
}

# fm_lane_class_from_names: agent|shell|other|unknown from one process's comm,
# argv[0], and full command line, through the shared vocabulary. Split out so a
# caller holding a process snapshot can classify many pids without one `ps` per
# pid. The command line is consulted only to rescue a harness that carries its
# identity in argv[1] rather than in either name.
fm_lane_class_from_names() {  # <comm> <argv0> [args]
  local comm=${1:-} argv0=${2:-} args=${3:-} class
  if [ -z "$comm" ] && [ -z "$argv0" ]; then
    printf 'unknown'
    return 0
  fi
  fm_lane_ensure_process_vocabulary || { printf 'unknown'; return 0; }
  class=$(fm_backend_tmux_classify_process_name "${comm:-$argv0}" "$argv0")
  if [ "$class" != agent ] && [ -n "$args" ] && fm_gemini_args_are_gemini "$args"; then
    class=agent
  fi
  printf '%s' "$class"
}

# fm_lane_pid_class: agent|shell|other|unknown for one pid, from the same
# sources the tmux liveness probe reads (comm, then argv[0], then the command
# line for argv[1]-carried harness identity).
fm_lane_pid_class() {  # <pid>
  local pid=$1 comm args argv0
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=
  args=$(ps -o args= -p "$pid" 2>/dev/null) || args=
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_lane_class_from_names "$comm" "$argv0" "$args"
}

# fm_lane_worktree_verdict: classify one worktree against a precomputed scan.
#   live           a process in the worktree classifies as an agent
#   dead           the worktree holds nothing but shells, or nothing at all
#   undeterminable the worktree holds a process this vocabulary cannot classify
fm_lane_worktree_verdict() {  # <scan> <worktree>
  local scan=$1 wt=$2 pid cwd class saw_other=0
  [ -n "$wt" ] || { printf 'undeterminable'; return 0; }
  wt=$(fm_lane_physical_path "$wt")
  while IFS=$'\t' read -r pid cwd; do
    [ -n "$pid" ] || continue
    [ "$pid" != "$$" ] || continue
    case "$cwd" in
      "$wt"|"$wt"/*) ;;
      *) continue ;;
    esac
    class=$(fm_lane_pid_class "$pid")
    case "$class" in
      agent) printf 'live'; return 0 ;;
      shell) ;;
      *) saw_other=1 ;;
    esac
  done <<EOF
$scan
EOF
  if [ "$saw_other" = 1 ]; then
    printf 'undeterminable'
  else
    printf 'dead'
  fi
}

# fm_lane_agent_live_in_worktree: the single-lane view.
#   0  a live agent process is running in <worktree>
#   1  provably no agent: the worktree holds only shells, or nothing at all
#   2  undeterminable: the scan failed, or the worktree holds a process this
#      vocabulary cannot classify
fm_lane_agent_live_in_worktree() {  # <worktree>
  local wt=$1 scan verdict
  [ -n "$wt" ] || return 2
  scan=$(fm_lane_cwd_scan) || return 2
  verdict=$(fm_lane_worktree_verdict "$scan" "$wt")
  case "$verdict" in
    live) return 0 ;;
    dead) return 1 ;;
    *) return 2 ;;
  esac
}

# fm_lane_snapshot_class: classify one pid from a `ps -o pid=,comm=,args=`
# snapshot, so a fleet poll reads the process table once instead of once per
# pid. A pid absent from the snapshot is unknown, never dead.
fm_lane_snapshot_class() {  # <snapshot> <pid>
  local snapshot=$1 pid=$2 row comm args argv0
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  row=$(printf '%s\n' "$snapshot" | LC_ALL=C awk -v p="$pid" '$1 == p { print; exit }')
  if [ -z "$row" ]; then
    printf 'unknown'
    return 0
  fi
  comm=$(printf '%s\n' "$row" | awk '{ print $2 }')
  args=$(printf '%s\n' "$row" | awk '{ sub(/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]*/, ""); print }')
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_lane_class_from_names "$comm" "$argv0" "$args"
}

# fm_lane_dead_worktrees: the fleet view - print each <worktree> argument that
# is provably dead, one per line, from ONE scan. Returns 1 when the scan itself
# could not be trusted, so a caller never reports a whole fleet dead because
# lsof was missing.
#
# The scan is filtered to the recorded worktrees in a single awk pass BEFORE any
# process is classified, so the per-pid `ps` reads run on the handful of
# processes that actually sit in a lane worktree rather than on the whole
# process table. That is what keeps a fleet-wide poll bounded: one lsof scan,
# one awk pass, and one `ps` per matching process.
fm_lane_dead_worktrees() {  # <worktree>...
  local scan roots matched classified wt entry
  scan=$(fm_lane_cwd_scan) || return 1
  [ -n "$scan" ] || return 1
  # Each entry is "<recorded>\035<physical>"; entries are separated by \034.
  # Neither control byte can appear in a path, so both are safe separators.
  roots=
  for wt in "$@"; do
    entry=$(fm_lane_physical_path "$wt") || continue
    roots="${roots}${wt}\035${entry}\034"
  done
  matched=$(printf '%s\n' "$scan" | LC_ALL=C awk -v roots="$roots" '
    BEGIN {
      n = split(roots, r, "\034")
      for (i = 1; i <= n; i++) {
        if (r[i] == "") continue
        split(r[i], pair, "\035")
        orig[++m] = pair[1]
        phys[m] = pair[2]
      }
    }
    {
      p = index($0, "\t")
      if (p == 0) next
      pid = substr($0, 1, p - 1)
      cwd = substr($0, p + 1)
      for (i = 1; i <= m; i++) {
        w = phys[i]
        if (w == "") continue
        if (cwd == w || index(cwd, w "/") == 1) { print pid "\t" orig[i]; break }
      }
    }
  ') || return 1
  # A worktree with no matching process at all is DEAD, not skipped: that is
  # the hard-kill shape. So an empty match set still has to reach the verdict
  # pass below, which prints every worktree it saw no live agent for.
  local pid_list snapshot
  classified=
  if [ -n "$matched" ]; then
    # ONE `ps` for every matched pid rather than one per pid: on a loaded box a
    # single `ps` costs tens of milliseconds, and a fleet poll that spends ten
    # seconds classifying a hundred processes holds the whole watcher sweep back.
    pid_list=$(printf '%s\n' "$matched" | cut -f1 | grep -E '^[0-9]+$' \
      | grep -vx "$$" | LC_ALL=C sort -un | paste -sd, -)
    snapshot=
    if [ -n "$pid_list" ]; then
      snapshot=$(ps -o pid=,comm=,args= -p "$pid_list" 2>/dev/null) || snapshot=
    fi
    classified=$(
      while IFS=$'\t' read -r pid wt; do
        [ -n "$pid" ] || continue
        [ "$pid" != "$$" ] || continue
        printf '%s\t%s\n' "$wt" "$(fm_lane_snapshot_class "$snapshot" "$pid")"
      done <<EOF
$matched
EOF
    )
  fi
  printf '%s\n' "$classified" | LC_ALL=C awk -F '\t' -v roots="$roots" '
    BEGIN {
      n = split(roots, r, "\034")
      for (i = 1; i <= n; i++) {
        if (r[i] == "") continue
        split(r[i], pair, "\035")
        order[++m] = pair[1]
      }
    }
    $2 == "agent" { state[$1] = "live" }
    $2 == "other" { if (state[$1] != "live") state[$1] = "other" }
    $2 == "unknown" { if (state[$1] != "live") state[$1] = "other" }
    $2 == "shell" { if (state[$1] == "") state[$1] = "shell" }
    END {
      for (i = 1; i <= m; i++) {
        w = order[i]
        if (state[w] == "live" || state[w] == "other") continue
        print w
      }
    }
  '
  return 0
}

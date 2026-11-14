#!/usr/bin/env bash
# fm-agent-proc-lib.sh - is a live agent process sitting in this task's worktree?
#
# Why this exists: every other liveness read goes through the task's recorded
# backend endpoint (a tmux window, a herdr pane, an Orca terminal handle), and
# an endpoint can be unreadable, stale, relabelled, or simply never have
# existed in the shape the reader expects while the agent itself is running
# fine. An Orca task records `window=` only as a label and owns no tmux window
# at all, so a tmux read of a healthy Orca fleet finds nothing. The operating
# system's own process table has no such blind spot: fm-spawn starts every
# agent inside its task worktree, so a live agent is a process whose working
# directory is that worktree (or whose arguments name it).
#
# This is a LIVENESS signal only - alive or not. It never says busy or idle:
# bin/fm-busy-lib.sh stays the one owner of semantic busy state, and child
# processes, CPU, and sleep state are deliberately not state signals there or
# here.
#
# The process table (fm_agent_proc_table) is four tab-separated columns, one
# process per line:
#
#   <pid> TAB <command name> TAB <working directory> TAB <arguments>
#
# Sources, in order:
#   FM_AGENT_PROC_TABLE  a file already in that shape. This is the test seam and
#                        also lets a caller reading many tasks capture one table
#                        (fm_agent_proc_table > file) and share it. An unreadable
#                        path means "the table could not be read", so pointing it
#                        at a missing file turns the signal off.
#   /proc                Linux: one `find` pass over /proc/<pid>/cwd.
#   lsof                 everywhere else (macOS): one `lsof -a -d cwd -Fpn` pass.
# Command names and arguments come from two `ps` passes, because a command name
# may itself contain spaces and so cannot share a line with the arguments.
#
# A real read proves itself before it is trusted: the reading shell's own
# working directory must appear in it. A table that cannot show even that is
# reported unreadable rather than as an empty fleet, so a failed read can never
# be mistaken for "no agent is running".
#
# Which command names are agents is owned by
# fm_backend_tmux_classify_process_name (bin/backends/tmux.sh), the single
# process-name vocabulary every liveness signal shares.
#
# That vocabulary does not cover every harness: one that runs as a bare
# interpreter (gemini is a `node` process) is invisible to it. Finding no agent
# is therefore evidence of absence only for a harness the vocabulary can name,
# which fm_agent_proc_recognizes answers; a caller must not read an empty
# result as death for any other harness.
#
# One harness runs as a bare interpreter the vocabulary cannot name: the Gemini
# CLI is a `node` process whose only tell is its arguments. fm_gemini_args_are_gemini
# (bin/fm-gemini-lib.sh) owns that test, so a gemini-shaped process counts as an
# agent here and its absence becomes evidence like any other harness's.
#
# Requires bin/fm-backend.sh to be sourced first (for fm_backend_source).

# fm_agent_proc_table: print the process table described above.
# Returns 0 when the table was read, 1 when it could not be.
fm_agent_proc_table() {
  if [ -n "${FM_AGENT_PROC_TABLE:-}" ]; then
    [ -f "$FM_AGENT_PROC_TABLE" ] && [ -r "$FM_AGENT_PROC_TABLE" ] || return 1
    cat "$FM_AGENT_PROC_TABLE" 2>/dev/null || return 1
    return 0
  fi
  local comms args cwds self=$$ table
  comms=$(ps -axo pid=,comm= 2>/dev/null) || return 1
  args=$(ps -axo pid=,args= 2>/dev/null) || return 1
  [ -n "$comms" ] || return 1
  if [ -d "/proc/$self" ] && [ -e "/proc/$self/cwd" ]; then
    cwds=$(find /proc -maxdepth 2 -name cwd -printf '%h\t%l\n' 2>/dev/null \
      | sed -n 's|^/proc/\([0-9][0-9]*\)\t\(/.*\)$|\1\t\2|p')
  else
    cwds=$(lsof -a -d cwd -Fpn 2>/dev/null | awk '
      /^p/ { pid = substr($0, 2); next }
      /^n\// && pid != "" { printf "%s\t%s\n", pid, substr($0, 2) }')
  fi
  [ -n "$cwds" ] || return 1
  table=$(
    {
      printf '%s\n' "$cwds" | sed 's/^/W\t/'
      printf '%s\n' "$comms" | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*/C\t\1\t/'
      printf '%s\n' "$args" | sed 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*/A\t\1\t/'
    } | awk -F '\t' '
      $1 == "W" { cwd[$2] = $3; next }
      $1 == "C" { comm[$2] = $3; order[++n] = $2; next }
      $1 == "A" {
        rest = $3
        for (i = 4; i <= NF; i++) rest = rest " " $i
        arg[$2] = rest
        next
      }
      END {
        for (i = 1; i <= n; i++) {
          pid = order[i]
          printf "%s\t%s\t%s\t%s\n", pid, comm[pid], cwd[pid], arg[pid]
        }
      }'
  ) || return 1
  # The read must be able to see the shell that made it.
  printf '%s\n' "$table" | awk -F '\t' -v self="$self" '
    $1 == self && $3 != "" { found = 1 }
    END { exit found ? 0 : 1 }' || return 1
  printf '%s\n' "$table"
}

# fm_agent_proc_recognizes <harness>: true when a running <harness> agent would
# be recognized in the process table, so that not finding one means something.
# fm_agent_proc_args_are_gemini <args>: true when a process's arguments are the
# Gemini CLI's shape. The matcher is owned by bin/fm-gemini-lib.sh; a caller that
# has not sourced it simply never matches here, which keeps this library usable
# without that dependency while giving the gemini case to the one owner.
fm_agent_proc_args_are_gemini() {  # <args>
  declare -F fm_gemini_args_are_gemini >/dev/null 2>&1 || return 1
  fm_gemini_args_are_gemini "${1:-}"
}

fm_agent_proc_recognizes() {  # <harness>
  [ -n "${1:-}" ] || return 1
  case "$1" in
    gemini|gemini-cli) return 0 ;;
  esac
  fm_backend_source tmux || return 1
  [ "$(fm_backend_tmux_classify_process_name "$1")" = agent ]
}

# fm_agent_proc_in_worktree <worktree>: print one "<pid> TAB <name>" line per
# live agent process whose working directory is <worktree> or below it, or
# whose arguments name <worktree> as a path. Both the recorded path and its
# symlink-resolved form are matched, since the kernel reports resolved paths.
#
# Returns:
#   0  at least one agent process was found (lines printed)
#   1  the table was read and holds no agent for this worktree
#   2  the table could not be read, or no worktree was given - never evidence
#      that the agent is gone
fm_agent_proc_in_worktree() {  # <worktree>
  local wt=${1:-} phys table rows pid comm argv0 found=1
  [ -n "$wt" ] || return 2
  while [ "${wt%/}" != "$wt" ] && [ "$wt" != / ]; do wt=${wt%/}; done
  phys=$(cd "$wt" 2>/dev/null && pwd -P) || phys=$wt
  table=$(fm_agent_proc_table) || return 2
  fm_backend_source tmux || return 2
  rows=$(printf '%s\n' "$table" | FM_AGENT_PROC_WT="$wt" FM_AGENT_PROC_PHYS="$phys" awk -F '\t' '
    function under(dir, root) {
      return root != "" && (dir == root || index(dir, root "/") == 1)
    }
    # True when <text> names <root> as a whole path: bounded on the left by the
    # start, a space, a quote, "=" or ":", and on the right by the end, a
    # space, a quote, ":" or a deeper "/".
    function names(text, root,    at, from, before, after) {
      if (root == "") return 0
      from = 1
      while ((at = index(substr(text, from), root)) > 0) {
        at += from - 1
        before = at > 1 ? substr(text, at - 1, 1) : ""
        after = substr(text, at + length(root), 1)
        if ((before == "" || before == " " || before == "\"" || before == "\047" || before == "=" || before == ":") &&
            (after == "" || after == " " || after == "\"" || after == "\047" || after == ":" || after == "/"))
          return 1
        from = at + 1
      }
      return 0
    }
    BEGIN { wt = ENVIRON["FM_AGENT_PROC_WT"]; phys = ENVIRON["FM_AGENT_PROC_PHYS"] }
    $1 ~ /^[0-9]+$/ && $2 != "" {
      if (under($3, wt) || under($3, phys) || names($4, wt) || names($4, phys)) {
        argv0 = $4
        sub(/ .*/, "", argv0)
        printf "%s\t%s\t%s\t%s\n", $1, $2, argv0, $4
      }
    }')
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r pid comm argv0 args; do
    [ -n "$pid" ] || continue
    if [ "$(fm_backend_tmux_classify_process_name "$comm" "$argv0")" = agent ] ||
       fm_agent_proc_args_are_gemini "${args:-}"; then
      comm=${comm##*/}
      printf '%s\t%s\n' "$pid" "${comm#-}"
      found=0
    fi
  done <<EOF
$rows
EOF
  return "$found"
}


# --- one liveness verdict ---------------------------------------------------
#
# Two independent reads say whether a task's agent exists: the process table
# above, and the backend's own recovery-grade classifier
# (fm_backend_agent_state) for the backends that have one. This is the ONE place
# they are combined, so every consumer agrees on what "dead" means.
#
#   alive    either read found the agent.
#   dead     the process table was READ, holds no agent for the worktree, the
#            harness is one the table could have recognized, and the classifier
#            does not vouch for a process. Nothing weaker is proof of death.
#   unknown  everything else: an unreadable table, a harness the table cannot
#            name, or a classifier reporting `ambiguous` - an unidentified
#            non-shell process in the endpoint, which may be that agent.

# The backend classifier's verdict for a task endpoint, in FM_AGENT_CLASSIFIER:
# its own word (alive, dead, missing, ambiguous, unreadable), or `none` when the
# backend has no classifier or the task records no endpoint.
FM_AGENT_CLASSIFIER=
fm_agent_classifier_state() {  # <backend> <target> -> FM_AGENT_CLASSIFIER
  FM_AGENT_CLASSIFIER=none
  [ -n "${2:-}" ] || return 0
  case "$1" in
    tmux|herdr|orca)
      FM_AGENT_CLASSIFIER=$(fm_backend_agent_state "$1" "$2" 2>/dev/null) || FM_AGENT_CLASSIFIER=unreadable
      [ -n "$FM_AGENT_CLASSIFIER" ] || FM_AGENT_CLASSIFIER=unreadable
      ;;
  esac
}

# Sets FM_AGENT_LIVE (alive|dead|unknown), FM_AGENT_LIVE_DESC (what was found,
# for an alive verdict), and FM_AGENT_CLASSIFIER. The classifier is asked only
# when the process table did not already find the agent; pass a verdict the
# caller already holds as the fifth argument to avoid asking twice.
# shellcheck disable=SC2034 # Output globals are read by the sourcing script.
FM_AGENT_LIVE=
# shellcheck disable=SC2034
FM_AGENT_LIVE_DESC=
# shellcheck disable=SC2034 # Assigns the output globals above.
fm_agent_liveness() {  # <worktree> <harness> <backend> <target> [<classifier-verdict>]
  local wt=$1 harness=$2 backend=$3 target=$4 rows rc first proc
  FM_AGENT_LIVE=unknown
  FM_AGENT_LIVE_DESC=
  FM_AGENT_CLASSIFIER=${5:-}
  rows=$(fm_agent_proc_in_worktree "$wt" 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0)
      first=${rows%%$'\n'*}
      FM_AGENT_LIVE=alive
      FM_AGENT_LIVE_DESC="${first#*$'\t'} pid ${first%%$'\t'*}"
      return 0
      ;;
    1) if fm_agent_proc_recognizes "$harness"; then proc=none; else proc=blind; fi ;;
    *) proc=unreadable ;;
  esac
  [ -n "$FM_AGENT_CLASSIFIER" ] || fm_agent_classifier_state "$backend" "$target"
  if [ "$FM_AGENT_CLASSIFIER" = alive ]; then
    FM_AGENT_LIVE=alive
    FM_AGENT_LIVE_DESC="$backend endpoint"
  elif [ "$proc" = none ] && [ "$FM_AGENT_CLASSIFIER" != ambiguous ]; then
    FM_AGENT_LIVE=dead
  fi
  return 0
}

# fm_agent_proc_file_writers <file> - the processes holding <file> open for
# WRITING, one "<pid>\t<name>" line each.
# Returns 0 when at least one was found, 1 when none was seen, 2 when open
# files could not be read at all.
#
# This is how a status log with no task record is traced back to whoever is
# still writing it. It answers for a held descriptor only: a writer that
# appends with `>>` opens the log for the instant of each write and is seen
# only if the read lands in that instant, so "none seen" is not "no writer".
# A reader is never reported: a `tail -F` over every status log holds each one
# open and has written none of them.
#
# Source order: FM_AGENT_PROC_OPEN_FILES (a file of
# "<pid>\t<name>\t<r|w>\t<path>" rows; test seam), then /proc/<pid>/fd with the
# access mode from /proc/<pid>/fdinfo, then `lsof`.
fm_agent_proc_file_writers() {  # <file>
  local file=$1 dir phys rows link pid fd flags mode name
  [ -n "$file" ] || return 2
  dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || return 2
  phys="$dir/$(basename "$file")"
  if [ -n "${FM_AGENT_PROC_OPEN_FILES:-}" ]; then
    [ -f "$FM_AGENT_PROC_OPEN_FILES" ] && [ -r "$FM_AGENT_PROC_OPEN_FILES" ] || return 2
    rows=$(awk -F '\t' -v f="$file" -v p="$phys" \
      '$3 == "w" && ($4 == f || $4 == p) { print $1 "\t" $2 }' "$FM_AGENT_PROC_OPEN_FILES")
  elif [ -d /proc/self/fd ]; then
    rows=$(
      find /proc -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname "$phys" -print 2>/dev/null |
        while IFS= read -r link; do
          pid=${link#/proc/}
          pid=${pid%%/*}
          fd=${link##*/}
          flags=$(sed -n 's/^flags:[[:space:]]*//p' "/proc/$pid/fdinfo/$fd" 2>/dev/null) || continue
          [ -n "$flags" ] || continue
          [ -z "${flags//[0-7]/}" ] || continue
          # The access mode is the low two bits: 1 write-only, 2 read-write.
          mode=$((8#$flags & 3))
          [ "$mode" -eq 1 ] || [ "$mode" -eq 2 ] || continue
          name=$(cat "/proc/$pid/comm" 2>/dev/null) || name=
          printf '%s\t%s\n' "$pid" "${name:-?}"
        done | sort -u
    )
  elif command -v lsof >/dev/null 2>&1; then
    rows=$(lsof -Fpca -- "$phys" 2>/dev/null | awk '
      /^p/ { pid = substr($0, 2); next }
      /^c/ { name = substr($0, 2); next }
      /^a/ { if ($0 ~ /^a[wu]/ && !(pid in seen)) { seen[pid] = 1; print pid "\t" name } }')
  else
    return 2
  fi
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
}

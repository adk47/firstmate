#!/usr/bin/env bash
# Outcome checks: a ship ticket is not Done until the OUTCOME it promised is
# observable, not merely until a PR merged.
#
# The failure this exists to close: a change merges, the worker reports
# `done: PR`, firstmate tears the task down, and the last mile - the reconcile
# job that never ran, the deploy that never rolled, the approved-but-unmerged
# change - is owned by nobody. A task that declares an outcome check carries a
# small shell probe; a timer runs every open probe, and a probe still red past
# its due time re-engages the OWNING worker with the exact gap, then asks
# firstmate to reassign, then pages.
#
# Usage:
#   fm-outcome-check.sh declare <task-id> [--probe <path>] [--due <duration>]
#                                        [--cadence <duration>] [--grace <duration>]
#   fm-outcome-check.sh run [<task-id>]
#   fm-outcome-check.sh status [<task-id>]
#   fm-outcome-check.sh gate <task-id>
#   fm-outcome-check.sh waive <task-id> --reason <text>
#   fm-outcome-check.sh poll
#   fm-outcome-check.sh arm
#
# declare   Record one outcome check for a ship task at state/<task-id>.outcome
#           and arm the home's outcome watch. The probe defaults to
#           data/<task-id>/outcome.sh. Durations accept <n>s, <n>m, <n>h, or a
#           plain seconds count; the defaults are due 1h, cadence 2m, grace
#           30m. A probe that does not exist yet is recorded as
#           "probe-missing" rather than refusing: declaring an outcome before
#           writing its probe is still an honest promise, and the missing probe
#           is then exactly what the first poll reports.
# run       Evaluate one probe (or every open probe) now, whatever the cadence,
#           update the record, and print one line per probe. Exit 0 when every
#           evaluated probe is green, 1 otherwise - a worker uses this to prove
#           its own fix instead of asserting it.
# status    One line per recorded check, with the state firstmate reads a ticket
#           by: "awaiting-outcome" while the probe is red or has never passed,
#           "green" once it passes, "waived" when the check was waived with a
#           reason. No record prints nothing.
# gate      The teardown gate. Exit 0 when this task's outcome is settled - no
#           check was declared in its brief and no record exists, or the probe
#           is green, or the check was waived - and exit 1 with the reason and
#           the exact next commands when it is not. A brief that declares an
#           outcome check with no record at all is not settled: nothing has
#           proven the outcome yet.
# waive     Record that this check is deliberately not being awaited, with the
#           reason kept in the record. Firstmate owns this act; a worker that
#           believes its check is wrong says so in a status line instead of
#           waiving it.
# poll      The watcher action. Evaluates the open probes whose cadence is due,
#           inside one bounded budget, and takes the escalation step that is due.
# arm       Write and bind state/outcome-watch.check.sh - the timer. declare
#           calls it, and it is idempotent, so re-arming repairs a home whose
#           shim was lost.
#
# Probe contract: the probe is a bash script run from the task's worktree (or
# its own directory when the worktree is gone), with FM_HOME, FM_TASK_ID,
# FM_PROJECT, FM_WORKTREE, and FM_PR_URL exported. Exit 0 means the outcome is
# real. Any other exit means it is not, and the probe prints one line naming the
# gap - "gap: merged-not-live", "gap: approved-not-merged",
# "gap: merged-not-deployed", or whatever fits - which is the text the owning
# worker is re-engaged with. A silent failure is recorded as "unclassified"; a
# probe that cannot be run is recorded as "probe-missing" and one that overruns
# its bound as "probe-timeout". No verdict other than a green exit 0 ever
# counts as a pass.
#
# Escalation ladder, one step per record, each firing once:
#   1. the probe is still red at its due time: the owning task is steered
#      through bin/fm-send.sh with the recorded gap (a durable inbox record, so
#      it survives a dead pane), recorded as escalation=1. This step wakes
#      firstmate for nothing.
#   2. still red one grace period later: one `check:` wake asking firstmate to
#      reassign the ticket or waive the check, recorded as escalation=2.
#   3. still red a further grace period later: one `check:` wake marked as the
#      captain page, recorded as escalation=3. The ladder ends there; the record
#      keeps reporting the gap until it is green or waived.
#
# Bounds: one poll is bounded by FM_OUTCOME_POLL_BUDGET seconds (default 20) so
# the watcher's own FM_CHECK_TIMEOUT never kills it mid-write, and each probe by
# FM_OUTCOME_PROBE_TIMEOUT (default 10), always clipped to the remaining poll
# budget. A probe that did not get its turn stays due and is taken next cycle.
#
# Test seams (all optional, all inert in production): FM_OUTCOME_SEND_BIN
# replaces the steering sender; FM_OUTCOME_POLL_BUDGET and
# FM_OUTCOME_PROBE_TIMEOUT bound one poll and one probe.
#
# Read-only apart from this home's own state/: it writes the task record, the
# steer inbox through fm-send, the durable wake queue, and its own shim. It
# never touches a project worktree.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"

CHECK_ID=outcome-watch
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
# FM_OUTCOME_SEND_BIN is a test seam for the escalation steer: a suite replaces
# it with a recorder so it can prove the exact gap text reached the owner
# without a live endpoint. Inert in production.
SEND_BIN="${FM_OUTCOME_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
OC_SCHEMA=fm-outcome-v1
OC_MAX_GAP=160

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-outcome-check.sh: %s\n' "$1" >&2
  printf 'Try: fm-outcome-check.sh --help\n' >&2
  exit 2
}

# --- record fields ----------------------------------------------------------

# One scalar per key, first occurrence wins. Values may contain spaces but never
# a newline: every value is cleaned before it is written.
oc_field() {  # <record> <key>
  local file=$1 key=$2
  awk -F= -v k="$key" '
    $1 == k { sub(/^[^=]*=/, ""); print; exit }
  ' "$file" 2>/dev/null
}

oc_clean() {  # <text> -> one printable line, capped
  local text=$1
  text=$(printf '%s' "$text" | tr '\t\r\n' '   ')
  while :; do
    case "$text" in
      ' '*) text=${text# } ;;
      *' ') text=${text% } ;;
      *) break ;;
    esac
  done
  printf '%s' "$text" | cut -c "1-$OC_MAX_GAP"
}

oc_now() { date +%s; }

# Durations are generous about their unit and strict about everything else, so a
# mistyped bound is refused rather than silently read as zero seconds.
oc_duration() {  # <value> -> seconds
  local value=$1 number unit
  case "$value" in
    ''|*[!0-9smh]*) return 1 ;;
  esac
  number=${value%[smh]}
  unit=${value#"$number"}
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$number" -gt 0 ] || return 1
  case "$unit" in
    '') printf '%s\n' "$number" ;;
    s) printf '%s\n' "$number" ;;
    m) printf '%s\n' "$((number * 60))" ;;
    h) printf '%s\n' "$((number * 3600))" ;;
    *) return 1 ;;
  esac
}

oc_record_path() {  # <task-id>
  printf '%s/%s.outcome\n' "$STATE" "$1"
}

# One pass over the record, no fork per field: a poll walks every open check
# inside one bounded budget, and the forks would be most of that budget.
oc_load() {  # <record>; sets OC_* globals; 1 when unreadable or foreign
  local file=$1 line key value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  OC_TASK='' OC_PROBE='' OC_DECLARED_AT='' OC_DUE_AT='' OC_CADENCE='' OC_GRACE=''
  OC_LAST_RUN='' OC_LAST_VERDICT='' OC_LAST_GAP='' OC_RED_SINCE=''
  OC_ESCALATION='' OC_ESCALATED_AT='' OC_WAIVED_AT='' OC_WAIVE_REASON='' OC_SCHEMA_SEEN=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema) OC_SCHEMA_SEEN=$value ;;
      task) OC_TASK=$value ;;
      probe) OC_PROBE=$value ;;
      declared_at) OC_DECLARED_AT=$value ;;
      due_at) OC_DUE_AT=$value ;;
      cadence) OC_CADENCE=$value ;;
      grace) OC_GRACE=$value ;;
      last_run) OC_LAST_RUN=$value ;;
      last_verdict) OC_LAST_VERDICT=$value ;;
      last_gap) OC_LAST_GAP=$value ;;
      red_since) OC_RED_SINCE=$value ;;
      escalation) OC_ESCALATION=$value ;;
      escalated_at) OC_ESCALATED_AT=$value ;;
      waived_at) OC_WAIVED_AT=$value ;;
      waive_reason) OC_WAIVE_REASON=$value ;;
    esac
  done < "$file"
  [ "$OC_SCHEMA_SEEN" = "$OC_SCHEMA" ] || return 1
  # A malformed bound reads as not-yet-due rather than as overdue: a damaged
  # record must never be able to page the captain on its own.
  oc_is_uint "$OC_DUE_AT" || OC_DUE_AT=$(( $(oc_now) + 3600 ))
  oc_is_uint "$OC_CADENCE" || OC_CADENCE=120
  oc_is_uint "$OC_GRACE" || OC_GRACE=1800
  oc_is_uint "$OC_ESCALATION" || OC_ESCALATION=0
  [ -n "$OC_LAST_VERDICT" ] || OC_LAST_VERDICT=none
  return 0
}

oc_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# The record is the single owner of a check's state, so it is written whole, in
# a fixed field order, through a rename: the poll never reads a half-written row
# and a hand read of the file always shows every field.
oc_write() {  # <record>
  local file=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-outcome.XXXXXX") || return 1
  if ! {
    printf 'schema=%s\n' "$OC_SCHEMA"
    printf 'task=%s\n' "$OC_TASK"
    printf 'probe=%s\n' "$OC_PROBE"
    printf 'declared_at=%s\n' "$OC_DECLARED_AT"
    printf 'due_at=%s\n' "$OC_DUE_AT"
    printf 'cadence=%s\n' "$OC_CADENCE"
    printf 'grace=%s\n' "$OC_GRACE"
    printf 'last_run=%s\n' "$OC_LAST_RUN"
    printf 'last_verdict=%s\n' "$OC_LAST_VERDICT"
    printf 'last_gap=%s\n' "$OC_LAST_GAP"
    printf 'red_since=%s\n' "$OC_RED_SINCE"
    printf 'escalation=%s\n' "$OC_ESCALATION"
    printf 'escalated_at=%s\n' "$OC_ESCALATED_AT"
    printf 'waived_at=%s\n' "$OC_WAIVED_AT"
    printf 'waive_reason=%s\n' "$OC_WAIVE_REASON"
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

oc_store() {  # <task-id>; persists the current OC_* set
  local file
  file=$(oc_record_path "$1")
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  OC_TASK=$1
  oc_write "$file"
}

# --- task context ----------------------------------------------------------

oc_meta_field() {  # <task-id> <key>
  local meta="$STATE/$1.meta" key=$2
  [ -f "$meta" ] || return 1
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$meta" 2>/dev/null
}

oc_brief_declares() {  # <task-id>
  local brief="$DATA/$1/brief.md"
  [ -f "$brief" ] || return 1
  fm_brief_heading_present "$brief" "# Outcome check"
}

# The gap is the probe's own first line, so the re-engaged worker is handed the
# exact thing that is missing instead of firstmate's paraphrase of it.
oc_gap_from_output() {  # <file>
  local line
  line=$(awk 'NF { print; exit }' "$1" 2>/dev/null)
  line=$(oc_clean "$line")
  case "$line" in
    gap:*) line=$(oc_clean "${line#gap:}") ;;
  esac
  [ -n "$line" ] || line=unclassified
  printf '%s\n' "$line"
}

# OC_PROBE_RESULT becomes green or red; OC_GAP names why when it is red.
oc_run_probe() {  # <probe> <cwd> <bound-seconds>
  local probe=$1 cwd=$2 bound=$3 tmp rc
  OC_PROBE_RESULT=red
  if [ ! -f "$probe" ] || [ ! -r "$probe" ]; then
    OC_GAP='probe-missing'
    return 0
  fi
  [ -d "$cwd" ] || cwd=$(dirname "$probe")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-outcome-probe.XXXXXX" 2>/dev/null) || {
    OC_GAP='probe-unrunnable'
    return 0
  }
  (
    cd "$cwd" 2>/dev/null || true
    fm_run_timed "$bound" bash "$probe"
  ) > "$tmp" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    OC_PROBE_RESULT=green
    OC_GAP=''
  elif [ "$rc" -eq 124 ]; then
    OC_GAP='probe-timeout'
  else
    OC_GAP=$(oc_gap_from_output "$tmp")
  fi
  rm -f -- "$tmp"
}

# Evaluate the probe and fold the result into the current OC_* set, keeping
# red_since stamped once so the ladder measures from the first red observation.
oc_evaluate() {  # <task-id> <bound-seconds> <exported: worktree dir or empty>
  local id=$1 bound=$2 worktree=$3 now probe cwd
  local project pr_url
  now=$(oc_now)
  probe=$OC_PROBE
  cwd=${worktree:-$DATA/$id}
  project=$(oc_meta_field "$id" project || true)
  pr_url=$(oc_meta_field "$id" pr || true)
  FM_TASK_ID=$id
  FM_PROBE=$probe
  FM_PROJECT=$project
  FM_WORKTREE=$worktree
  FM_PR_URL=$pr_url
  export FM_TASK_ID FM_PROBE FM_PROJECT FM_WORKTREE FM_PR_URL
  oc_run_probe "$probe" "$cwd" "$bound"
  OC_LAST_RUN=$now
  OC_LAST_VERDICT=$OC_PROBE_RESULT
  if [ "$OC_PROBE_RESULT" = green ]; then
    OC_LAST_GAP=''
    OC_RED_SINCE=
  else
    OC_LAST_GAP=$OC_GAP
    [ -n "$OC_RED_SINCE" ] || OC_RED_SINCE=$now
  fi
}

# --- escalation ------------------------------------------------------------

oc_seconds_phrase() {  # <seconds>
  local secs=$1
  if [ "$secs" -ge 3600 ]; then
    printf '%dh\n' "$((secs / 3600))"
  elif [ "$secs" -ge 60 ]; then
    printf '%dm\n' "$((secs / 60))"
  else
    printf '%ds\n' "$secs"
  fi
}

oc_steer_owner() {  # <task-id> <gap> <overdue-seconds>
  local id=$1 gap=$2 overdue=$3 text delivery
  delivery="outcome-$id-1"
  text="outcome-check $id: your ticket is not done. The outcome check this task declared ($OC_PROBE) is still red $overdue past its due time.
gap: $gap
A merged PR, or an approval that never turned into a merge, is exactly the last mile this check exists to catch: nothing on this ticket counts as done until the probe passes.
Re-engage now: close that gap, then prove it with \`bin/fm-outcome-check.sh run $id\` and report the result. If the check itself is wrong, say so in one status line instead of stopping."
  FM_HOME="$FM_HOME" "$SEND_BIN" "$id" --fire-and-forget "$delivery" "$text" >/dev/null 2>&1
}

oc_escalate() {  # <task-id> ; prints at most one wake line
  local id=$1 now overdue grace gap
  now=$(oc_now)
  [ "$now" -ge "$OC_DUE_AT" ] || return 0
  # A verdict is the only thing that may move the ladder: a probe the poll had
  # no budget to run has not earned anybody a wake.
  [ "$OC_LAST_VERDICT" != green ] && [ "$OC_LAST_VERDICT" != none ] || return 0
  overdue=$(oc_seconds_phrase "$((now - OC_DUE_AT))")
  gap=${OC_LAST_GAP:-unclassified}
  grace=$OC_GRACE
  case "$OC_ESCALATION" in
    0)
      # The owning worker is still the owner and still alive at this point in
      # most cases, and a steer is cheap: ring it before troubling firstmate.
      OC_ESCALATION=1
      OC_ESCALATED_AT=$now
      oc_store "$id" || return 0
      oc_steer_owner "$id" "$gap" "$overdue" || true
      return 0
      ;;
    1)
      [ "$now" -ge "$((OC_ESCALATED_AT + grace))" ] || return 0
      OC_ESCALATION=2
      OC_ESCALATED_AT=$now
      oc_store "$id" || return 0
      printf 'check: outcome-overdue %s the owning worker was re-engaged %s ago and its declared outcome is still red (gap: %s, due %s ago); reassign the ticket to a fresh worker or waive the check with bin/fm-outcome-check.sh waive %s --reason "<why>"\n' \
        "$id" "$(oc_seconds_phrase "$grace")" "$gap" "$overdue" "$id"
      return 0
      ;;
    2)
      [ "$now" -ge "$((OC_ESCALATED_AT + grace))" ] || return 0
      OC_ESCALATION=3
      OC_ESCALATED_AT=$now
      oc_store "$id" || return 0
      printf 'check: outcome-abandoned %s reassignment was requested %s ago and the declared outcome is still red (gap: %s, due %s ago); nothing has proven this ticket. Page the captain with the exact gap, or waive the check with bin/fm-outcome-check.sh waive %s --reason "<why>"\n' \
        "$id" "$(oc_seconds_phrase "$grace")" "$gap" "$overdue" "$id"
      return 0
      ;;
  esac
  return 0
}

# --- actions ---------------------------------------------------------------

action_declare() {
  local id='' probe='' due=3600 cadence=120 grace=1800 want_value='' arg
  for arg in "$@"; do
    if [ -n "$want_value" ]; then
      case "$want_value" in
        probe) probe=$arg ;;
        due|cadence|grace)
          oc_duration "$arg" >/dev/null 2>&1 || die_usage "--$want_value needs a positive duration such as 30m, 2h, or 45s"
          case "$want_value" in
            due) due=$(oc_duration "$arg") ;;
            cadence) cadence=$(oc_duration "$arg") ;;
            grace) grace=$(oc_duration "$arg") ;;
          esac
          ;;
      esac
      want_value=
      continue
    fi
    case "$arg" in
      --probe) want_value=probe ;;
      --probe=*) probe=${arg#--probe=} ;;
      --due) want_value=due ;;
      --due=*)
        oc_duration "${arg#--due=}" >/dev/null 2>&1 || die_usage "--due needs a positive duration"
        due=$(oc_duration "${arg#--due=}") ;;
      --cadence) want_value=cadence ;;
      --cadence=*)
        oc_duration "${arg#--cadence=}" >/dev/null 2>&1 || die_usage "--cadence needs a positive duration"
        cadence=$(oc_duration "${arg#--cadence=}") ;;
      --grace) want_value=grace ;;
      --grace=*)
        oc_duration "${arg#--grace=}" >/dev/null 2>&1 || die_usage "--grace needs a positive duration"
        grace=$(oc_duration "${arg#--grace=}") ;;
      -*) die_usage "unknown option: $arg" ;;
      *)
        [ -z "$id" ] || die_usage "declare takes exactly one task id"
        id=$arg
        ;;
    esac
  done
  [ -z "$want_value" ] || die_usage "--$want_value requires a value"
  [ -n "$id" ] || die_usage "declare requires a task id"
  fm_pr_task_id_valid "$id" || die_usage "invalid task id: $id"
  [ -n "$probe" ] || probe="$DATA/$id/outcome.sh"
  case "$probe" in
    /*) ;;
    *) probe="$FM_HOME/$probe" ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-outcome-check.sh: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  }
  OC_TASK=$id
  OC_PROBE=$probe
  OC_DECLARED_AT=$(oc_now)
  OC_DUE_AT=$((OC_DECLARED_AT + due))
  OC_CADENCE=$cadence
  OC_GRACE=$grace
  OC_LAST_RUN=''
  OC_LAST_VERDICT=none
  OC_LAST_GAP=
  OC_RED_SINCE=
  OC_ESCALATION=0
  OC_ESCALATED_AT=
  OC_WAIVED_AT=
  OC_WAIVE_REASON=
  oc_store "$id" || {
    printf 'fm-outcome-check.sh: could not write %s\n' "$(oc_record_path "$id")" >&2
    return 1
  }
  if [ ! -f "$probe" ]; then
    printf 'note: probe %s does not exist yet; it is recorded as probe-missing until it does\n' "$probe" >&2
  fi
  action_arm || {
    printf 'fm-outcome-check.sh: recorded %s but could not arm the outcome watch\n' "$(oc_record_path "$id")" >&2
    return 1
  }
  printf 'outcome %s declared probe=%s due=%s cadence=%s grace=%s\n' \
    "$id" "$probe" "$(oc_seconds_phrase "$due")" \
    "$(oc_seconds_phrase "$cadence")" "$(oc_seconds_phrase "$grace")"
}

# Probe the task's own answer: a live worktree is the honest place to run a
# deployment read from, and a retired one falls back to the probe's directory.
oc_worktree() {  # <task-id>
  local worktree
  worktree=$(oc_meta_field "$1" worktree || true)
  [ -n "$worktree" ] && [ -d "$worktree" ] && printf '%s\n' "$worktree"
}

action_run() {
  local id=${1:-} status=0 records='' file task bound worktree
  bound=${FM_OUTCOME_PROBE_TIMEOUT:-10}
  oc_is_uint "$bound" && [ "$bound" -gt 0 ] || bound=10
  records=$(oc_record_list "$id") || return 1
  [ -n "$records" ] || {
    [ -n "$id" ] && printf 'outcome %s not-declared\n' "$id"
    return 0
  }
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    oc_load "$file" || continue
    task=$OC_TASK
    [ -n "$task" ] || continue
    worktree=$(oc_worktree "$task")
    oc_evaluate "$task" "$bound" "$worktree"
    oc_store "$task" || {
      printf 'fm-outcome-check.sh: could not record the verdict for %s\n' "$task" >&2
      status=1
      continue
    }
    printf 'outcome %s %s gap=%s\n' "$task" "$OC_LAST_VERDICT" "${OC_LAST_GAP:-none}"
    [ "$OC_LAST_VERDICT" = green ] || status=1
  done <<EOF
$records
EOF
  return "$status"
}

# The record files that this invocation covers, one absolute path per line.
oc_record_list() {  # [<task-id>]
  local id=${1:-} file
  if [ -n "$id" ]; then
    fm_pr_task_id_valid "$id" || return 1
    file=$(oc_record_path "$id")
    [ -f "$file" ] && [ ! -L "$file" ] && printf '%s\n' "$file"
    return 0
  fi
  for file in "$STATE"/*.outcome; do
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done
}

oc_state_word() {
  if [ -n "$OC_WAIVED_AT" ]; then
    printf 'waived\n'
  elif [ "$OC_LAST_VERDICT" = green ]; then
    printf 'green\n'
  else
    printf 'awaiting-outcome\n'
  fi
}

action_status() {
  local id=${1:-} records='' file now due
  records=$(oc_record_list "$id") || return 1
  [ -n "$records" ] || {
    [ -n "$id" ] && printf 'outcome %s not-declared\n' "$id"
    return 0
  }
  now=$(oc_now)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    oc_load "$file" || {
      printf 'outcome-record unreadable: %s\n' "$file"
      continue
    }
    if [ "$now" -ge "$OC_DUE_AT" ]; then
      due="due $(oc_seconds_phrase "$((now - OC_DUE_AT))") ago"
    else
      due="due in $(oc_seconds_phrase "$((OC_DUE_AT - now))")"
    fi
    printf 'outcome %s %s verdict=%s gap=%s %s escalation=%s probe=%s\n' \
      "$OC_TASK" "$(oc_state_word)" "$OC_LAST_VERDICT" "${OC_LAST_GAP:-none}" \
      "$due" "$OC_ESCALATION" "$OC_PROBE"
    [ -z "$OC_WAIVED_AT" ] || printf 'outcome %s waive-reason=%s\n' "$OC_TASK" "$OC_WAIVE_REASON"
  done <<EOF
$records
EOF
}

action_gate() {
  local id=${1:-} file
  [ -n "$id" ] || die_usage "gate requires a task id"
  fm_pr_task_id_valid "$id" || die_usage "invalid task id: $id"
  file=$(oc_record_path "$id")
  if [ -f "$file" ] && [ ! -L "$file" ] && oc_load "$file"; then
    if [ -n "$OC_WAIVED_AT" ]; then
      printf 'outcome %s waived: %s\n' "$id" "$OC_WAIVE_REASON"
      return 0
    fi
    if [ "$OC_LAST_VERDICT" = green ]; then
      printf 'outcome %s green\n' "$id"
      return 0
    fi
    printf 'outcome %s awaiting-outcome: gap %s, %s; escalation=%s\n' \
      "$id" "${OC_LAST_GAP:-unclassified}" \
      "$( [ "$(oc_now)" -ge "$OC_DUE_AT" ] && printf 'past due' || printf 'not yet due' )" \
      "$OC_ESCALATION" >&2
    return 1
  fi
  if oc_brief_declares "$id"; then
    printf 'outcome %s awaiting-outcome: its brief declares an outcome check but no probe has ever been recorded; run bin/fm-outcome-check.sh declare %s\n' "$id" "$id" >&2
    return 1
  fi
  printf 'outcome %s not-declared\n' "$id"
  return 0
}

action_waive() {
  local id='' reason='' want_reason=0 arg
  for arg in "$@"; do
    if [ "$want_reason" -eq 1 ]; then
      reason=$arg
      want_reason=0
      continue
    fi
    case "$arg" in
      --reason) want_reason=1 ;;
      --reason=*) reason=${arg#--reason=} ;;
      -*) die_usage "unknown option: $arg" ;;
      *)
        [ -z "$id" ] || die_usage "waive takes exactly one task id"
        id=$arg
        ;;
    esac
  done
  [ -z "$id" ] && die_usage "waive requires a task id"
  fm_pr_task_id_valid "$id" || die_usage "invalid task id: $id"
  reason=$(oc_clean "$reason")
  [ -n "$reason" ] || die_usage "waive requires --reason; a waived check is a decision and keeps its reason"
  oc_load "$(oc_record_path "$id")" || {
    printf 'fm-outcome-check.sh: no outcome check is recorded for %s\n' "$id" >&2
    return 1
  }
  OC_WAIVED_AT=$(oc_now)
  OC_WAIVE_REASON=$reason
  oc_store "$id" || return 1
  printf 'outcome %s waived: %s\n' "$id" "$reason"
}

action_poll() {
  local budget per_probe now deadline remaining bound file task worktree
  budget=${FM_OUTCOME_POLL_BUDGET:-20}
  oc_is_uint "$budget" && [ "$budget" -gt 0 ] || budget=20
  per_probe=${FM_OUTCOME_PROBE_TIMEOUT:-10}
  oc_is_uint "$per_probe" && [ "$per_probe" -gt 0 ] || per_probe=10
  deadline=$(( $(oc_now) + budget ))
  for file in "$STATE"/*.outcome; do
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    oc_load "$file" || continue
    task=$OC_TASK
    [ -n "$task" ] || continue
    [ -n "$OC_WAIVED_AT" ] && continue
    [ "$OC_LAST_VERDICT" = green ] && continue
    now=$(oc_now)
    # The probe's turn, then the ladder: a probe that is not due yet still has
    # its escalation step taken, so a worker that keeps failing to run its own
    # check does not stall the ladder behind the cadence.
    if [ "$now" -ge "$(( ${OC_LAST_RUN:-0} + OC_CADENCE ))" ]; then
      remaining=$(( deadline - now ))
      if [ "$remaining" -gt 0 ]; then
        bound=$per_probe
        [ "$bound" -le "$remaining" ] || bound=$remaining
        worktree=$(oc_worktree "$task")
        oc_evaluate "$task" "$bound" "$worktree"
        oc_store "$task" || continue
      fi
    fi
    oc_escalate "$task"
  done
}

action_arm() {
  local want home
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || {
    printf 'fm-outcome-check.sh: state directory is unavailable: %s\n' "$STATE" >&2
    return 1
  }
  # A task's own PR poll writes state/<id>.check.sh, so this id must never also
  # be a live task id.
  if [ -e "$STATE/$CHECK_ID.meta" ] || [ -L "$STATE/$CHECK_ID.meta" ]; then
    printf 'fm-outcome-check.sh: refusing to arm: %s is a task id\n' "$STATE/$CHECK_ID.meta" >&2
    return 1
  fi
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-outcome-check.sh: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-outcome-watch-check \
    fm-outcome-check "$REGISTER_BIN" "$home" "$want"
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-outcome-check.sh - outcome check timer.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-outcome-check.sh") poll"
}

case "${1:-}" in
  declare) shift; action_declare "$@" ;;
  run) shift; action_run "$@" ;;
  status) shift; action_status "$@" ;;
  gate) shift; action_gate "$@" ;;
  waive) shift; action_waive "$@" ;;
  poll) action_poll ;;
  arm) action_arm ;;
  --help|-h) usage ;;
  '') die_usage "no action given" ;;
  *) die_usage "unknown action: $1" ;;
esac

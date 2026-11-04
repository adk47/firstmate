#!/usr/bin/env bash
# fm-thread-wake-measure.sh - does direct thread delivery actually reduce
# firstmate wakes?
#
# WHY: thread subscriptions (bin/fm-thread-deliver.sh) exist to take relaying
# out of firstmate's turn. The claim is measurable and would otherwise only be
# asserted: either firstmate handles fewer wakes per hour than it did before the
# change, or the change has not bought what it promised.
#
# HOW: take a baseline when thread delivery goes live, then read a report after
# the agreed window (7 days by default). Two independent readings are printed,
# because either one alone is misleading:
#   - Wake appends per hour, from the watcher's monotonic sequence counter
#     ($STATE/.wake-queue.seq). This counts every durable wake the fleet
#     produced, which is exactly firstmate's turn load. It has no history before
#     the baseline, so it only measures the window from the baseline onward.
#   - Outcomes per hour, from the supervision branch's durable outcome store
#     ($STATE/branch-outcomes.jsonl), which keeps an epoch per row and therefore
#     CAN be counted for the window before the baseline as well. This is the
#     before/after comparison, and its captain verdict split shows whether the
#     survivors are the ones that genuinely needed firstmate.
# Routing volume comes with them: deliveries are events that reached their
# owning worker without a firstmate turn, and dead-lane copies are the only
# thread events that still cost one.
#
# Neither reading is a target to game: a fleet that is quiet produces few wakes
# per hour whatever the routing does, which is why both windows are always
# printed alongside the raw counts and the row coverage they were computed from.
#
# Usage:
#   fm-thread-wake-measure.sh baseline [--force]
#       Record epoch, wake sequence, and current routing counts as the window
#       start. Refuses to overwrite an existing baseline without --force, so the
#       agreed window cannot be silently restarted.
#   fm-thread-wake-measure.sh report [--days <n>] [--json]
#       Print the measurement. --days sets the comparison window (default 7).
#   fm-thread-wake-measure.sh --help
#
# Exit status: 0 when the report was produced, 1 on invalid input. A missing
# baseline or an absent outcome store is reported as unavailable, never guessed
# or silently defaulted to zero.
#
# Environment:
#   FM_HOME, FM_STATE_OVERRIDE, FM_ROOT_OVERRIDE  operational home and state.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
THREADS="$STATE/threads"
LEDGER="$THREADS/deliveries.log"
BASELINE="$THREADS/wake-baseline"
WAKE_SEQ="$STATE/.wake-queue.seq"
OUTCOMES="$STATE/branch-outcomes.jsonl"

die() { printf 'fm-thread-wake-measure: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }

# Whole seconds elapsed between two epochs as hours with four decimals, never
# zero: a window measured in seconds must produce a finite rate, and a same-second
# window must not divide by zero.
elapsed_hours() {  # <start-epoch> <end-epoch>
  local secs=$(( $2 - $1 ))
  [ "$secs" -ge 1 ] || secs=1
  printf '%s.%04d' "$(( secs / 3600 ))" "$(( (secs % 3600) * 10000 / 3600 ))"
}

# count_of OUTCOME from the delivery ledger, optionally only rows at or after an
# epoch. The ledger is append-only and owned by bin/fm-thread-deliver.sh.
ledger_count() {  # <outcome> [<since-epoch>]
  local outcome=$1 since=${2:-0} file=${LEDGER}
  [ -f "$file" ] || { printf '0'; return 0; }
  LC_ALL=C awk -F '\t' -v want="$outcome" -v since="$since" '
    $1 ~ /^[0-9]+$/ && $1 >= since && $5 == want { n++ }
    END { print n + 0 }
  ' "$file"
}

# Rows in the supervision branch's durable outcome store, split by verdict.
# Prints "<rows> <captain> <routine> <first-epoch> <last-epoch>"; absent or
# unreadable prints "0 0 0 0 0" so the caller reports it as unavailable.
outcome_counts() {  # <since-epoch> <until-epoch>
  local file=$OUTCOMES
  [ -f "$file" ] || { printf '0 0 0 0 0'; return 0; }
  LC_ALL=C awk -v lo="$1" -v hi="$2" '
    function num(v) { return (v ~ /^[0-9]+$/) ? v + 0 : -1 }
    index($0, "\"epoch\":") > 0 {
      # The store is one JSON object per line; pull the two fields this report
      # needs rather than growing a JSON dependency into a shell script.
      epoch = -1; verdict = ""
      if (match($0, /"epoch":[0-9]+/)) { epoch = num(substr($0, RSTART + 8, RLENGTH - 8)) }
      if (match($0, /"verdict":"[a-z-]+"/)) { verdict = substr($0, RSTART + 11, RLENGTH - 12) }
      if (epoch < 0) { next }
      if (first == 0 || epoch < first) { first = epoch }
      if (epoch > last) { last = epoch }
      if (epoch >= lo && epoch <= hi) {
        rows++
        if (verdict == "captain") { captain++ } else { routine++ }
      }
    }
    END { printf "%d %d %d %d %d", rows + 0, captain + 0, routine + 0, first + 0, last + 0 }
  ' "$file"
}

baseline_read() {  # <key>
  local path=$BASELINE key=$1 value
  [ -f "$path" ] || return 0
  value=$(LC_ALL=C awk -F '=' -v k="$key" '$1 == k { print $2; exit }' "$path")
  printf '%s' "$value"
}

cmd_baseline() {
  local force=0 epoch seq delivered copied tmp restarted=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  if [ -f "$BASELINE" ] && [ "$force" -ne 1 ]; then
    die "a baseline already exists ($BASELINE); pass --force to restart the measurement window"
  fi
  mkdir -p "$THREADS"
  epoch=$(date +%s)
  seq=$(cat "$WAKE_SEQ" 2>/dev/null || echo 0)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  delivered=$(ledger_count delivery)
  copied=$(ledger_count copy)
  restarted=$([ -f "$BASELINE" ] && printf '1' || printf '0')
  tmp=$(mktemp "$THREADS/.wake-baseline.XXXXXX") || die "could not stage the baseline"
  {
    printf 'epoch=%s\n' "$epoch"
    printf 'created=%s\n' "$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$epoch")"
    printf 'wake_seq=%s\n' "$seq"
    printf 'delivered=%s\n' "$delivered"
    printf 'copied=%s\n' "$copied"
    printf 'restarted=%s\n' "$restarted"
  } > "$tmp" || { rm -f -- "$tmp"; die "could not write the baseline"; }
  mv -f -- "$tmp" "$BASELINE" || { rm -f -- "$tmp"; die "could not install the baseline"; }
  printf 'baseline: epoch=%s wake_seq=%s delivered=%s copied=%s%s\n' \
    "$epoch" "$seq" "$delivered" "$copied" \
    "$([ "$restarted" = 1 ] && printf ' (restarted)' || true)"
}

cmd_report() {
  local days=7 json=0 now base_epoch base_seq base_delivered base_copied
  local seq_now wakes hours wake_rate delivered copied
  local after_rows after_captain after_routine first last
  local before_lo before_rows=0 before_captain=0 before_routine=0 after_hours=0 before_hours=0
  local after_rate='n/a' before_rate='n/a' change='n/a'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) [ "$#" -ge 2 ] || die "--days needs a value"; days=$2; shift 2 ;;
      --days=*) days=${1#--days=}; shift ;;
      --json) json=1; shift ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) die "--days needs a positive whole number of days" ;; esac
  [ "$days" -ge 1 ] || die "--days needs a positive whole number of days"

  now=$(date +%s)
  base_epoch=$(baseline_read epoch)
  if [ -z "$base_epoch" ]; then
    printf 'baseline: absent (%s) - no window is in progress; run baseline first\n' "$BASELINE"
    return 0
  fi
  case "$base_epoch" in ''|*[!0-9]*) die "the recorded baseline epoch is not a number: $base_epoch" ;; esac
  base_seq=$(baseline_read wake_seq)
  case "$base_seq" in ''|*[!0-9]*) base_seq=0 ;; esac
  base_delivered=$(baseline_read delivered)
  case "$base_delivered" in ''|*[!0-9]*) base_delivered=0 ;; esac
  base_copied=$(baseline_read copied)
  case "$base_copied" in ''|*[!0-9]*) base_copied=0 ;; esac

  seq_now=$(cat "$WAKE_SEQ" 2>/dev/null || echo 0)
  case "$seq_now" in ''|*[!0-9]*) seq_now=0 ;; esac
  if [ "$seq_now" -ge "$base_seq" ]; then
    wakes=$(( seq_now - base_seq ))
  else
    # A vanished or reset sequence counter is a measurement gap, not a negative
    # rate. Say so rather than printing a number the reader would trust.
    wakes=-1
  fi
  hours=$(elapsed_hours "$base_epoch" "$now")
  if [ "$wakes" -ge 0 ]; then
    wake_rate=$(LC_ALL=C awk -v w="$wakes" -v h="$hours" 'BEGIN { printf "%.2f", w / h }')
  else
    wake_rate='n/a'
  fi

  delivered=$(ledger_count delivery "$base_epoch")
  copied=$(ledger_count copy "$base_epoch")

  # Since-baseline window, from the outcome store.
  read -r after_rows after_captain after_routine first last <<EOF
$(outcome_counts "$base_epoch" "$now")
EOF
  after_hours=$hours
  [ "$after_rows" -gt 0 ] || after_hours=0
  if [ "$after_hours" != 0 ]; then
    after_rate=$(LC_ALL=C awk -v n="$after_rows" -v h="$after_hours" 'BEGIN { printf "%.2f", n / h }')
  fi
  # Before-baseline window of the same length, when the store covers it.
  before_lo=$(( base_epoch - days * 86400 ))
  if [ "$first" -gt 0 ] && [ "$first" -le "$before_lo" ]; then
    read -r before_rows before_captain before_routine _ _ <<EOF
$(outcome_counts "$before_lo" "$(( base_epoch - 1 ))")
EOF
    if [ "$before_rows" -gt 0 ]; then
      before_hours=$(( days * 24 ))
      before_rate=$(LC_ALL=C awk -v n="$before_rows" -v h="$before_hours" 'BEGIN { printf "%.2f", n / h }')
      if [ "$after_hours" != 0 ]; then
        change=$(LC_ALL=C awk -v b="$before_rate" -v a="$after_rate" \
          'BEGIN { if (b + 0 <= 0) { print "n/a" } else { printf "%+.0f%%", (a - b) / b * 100 } }')
      fi
    fi
  fi

  if [ "$json" = 1 ]; then
    printf '{"baseline_epoch":%s,"window_days":%s,"elapsed_hours":%s,' \
      "$base_epoch" "$days" "$hours"
    printf '"wake_appends":%s,"wake_appends_per_hour":%s,' "$wakes" "$([ "$wake_rate" = n/a ] && echo null || echo "$wake_rate")"
    printf '"thread_deliveries":%s,"dead_lane_copies":%s,' "$delivered" "$copied"
    printf '"outcomes_after":{"rows":%s,"captain":%s,"routine":%s,"per_hour":%s},' \
      "$after_rows" "$after_captain" "$after_routine" "$([ "$after_rate" = n/a ] && echo null || echo "$after_rate")"
    printf '"outcomes_before":{"rows":%s,"captain":%s,"routine":%s,"per_hour":%s},' \
      "$before_rows" "$before_captain" "$before_routine" "$([ "$before_rate" = n/a ] && echo null || echo "$before_rate")"
    printf '"change":"%s"}\n' "$change"
    return 0
  fi

  printf 'thread routing, since the baseline at %s:\n' "$(baseline_read created)"
  printf '  deliveries to owning workers: %s\n' "$delivered"
  printf '  dead-lane copies to firstmate: %s\n' "$copied"
  printf '  (deliveries are events that never cost a firstmate turn)\n'
  printf 'firstmate wake appends: %s over %s h = %s/h\n' "$wakes" "$hours" "$wake_rate"
  if [ "$wakes" -lt 0 ]; then
    printf '  the wake sequence counter is behind the baseline; treat the rate as unavailable\n'
  fi
  printf 'supervision outcomes after the baseline: %s rows (%s captain, %s routine) over %s h = %s/h\n' \
    "$after_rows" "$after_captain" "$after_routine" "$after_hours" "$after_rate"
  if [ "$before_rows" -gt 0 ]; then
    printf 'supervision outcomes in the %s days before it: %s rows (%s captain, %s routine) = %s/h\n' \
      "$days" "$before_rows" "$before_captain" "$before_routine" "$before_rate"
    printf 'change in outcome load: %s\n' "$change"
  else
    printf 'supervision outcomes before it: unavailable (the store does not reach %s days back)\n' "$days"
    if [ "$first" -gt 0 ]; then
      printf '  the store covers %s to %s; the absolute wake rate above is the reading until it reaches further back\n' \
        "$(date -u -r "$first" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$first")" \
        "$(date -u -r "$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$last")"
    else
      if [ -r "$OUTCOMES" ]; then
        printf '  the store holds no rows in this window, so read the absolute wake rate above\n'
      else
        printf '  the store is absent or unreadable, so read the absolute wake rate above\n'
      fi
    fi
  fi
}

case "${1:-}" in
  baseline) shift; cmd_baseline "$@" ;;
  report) shift; cmd_report "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 1 ;;
esac

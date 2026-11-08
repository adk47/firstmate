#!/usr/bin/env bash
# fm-decider-metrics.sh - measure the Decider seat against its definition of
# done: 80% of the decisions routed to the seat are ruled inside the window
# (default 2h) without a supervisor turn.
#
# Usage:
#   fm-decider-metrics.sh report [--days <n>] [--json]
#   fm-decider-metrics.sh --help
#
#   --days <n>   only count episodes first seen in the last <n> days (default 7)
#   --json       print the report as one JSON object (for a dashboard)
#
# Where the numbers come from. Every episode lives in state/decider-ledger.tsv,
# which bin/fm-decider-route.sh writes and bin/fm-decider-lib.sh owns (the format
# is documented there): `O` opened, `A` asked, `R` ruled through the seat's own
# answer helper, `C` closed, `E` the window expired unruled.
#
# What this measures, precisely. The definition of done is a ruling that did not
# cost a supervisor turn, so the headline counts only `R` records - and the ONLY
# writer of an `R` record is bin/fm-decider-route.sh answer, one deliberate turn
# by the seat. An episode closed without an `R` (the worker resolved it itself,
# the captain answered it, the task was torn down) is reported separately as
# `closed without a ruling` and is deliberately NOT counted as a win: counting it
# would let a quiet log read as a fast decider.
#
# The report is a read of this home's own record. It never mutates the ledger,
# never scans the fleet, and never contacts the seat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-decider-lib.sh
. "$SCRIPT_DIR/fm-decider-lib.sh"

FM_HOME=${FM_HOME:-}
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:+$FM_HOME/state}}

usage() {
  cat <<'USAGE'
Usage:
  fm-decider-metrics.sh report [--days <n>] [--json]
  fm-decider-metrics.sh --help

Counts the Decider seat's routed decisions against its definition of done:
80% of the keys routed to the seat are ruled within the window (default 2h)
without a supervisor turn. Reads state/decider-ledger.tsv in this home.
USAGE
}

die() {
  printf 'fm-decider-metrics: %s\n' "$*" >&2
  exit 2
}

DAYS=7
JSON=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    report) shift ;;
    --days)
      [ "$#" -ge 2 ] || die '--days needs a value'
      DAYS=$2
      shift 2
      ;;
    --json) JSON=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*|0) die '--days must be a positive whole number of days' ;; esac
[ -n "$FM_HOME" ] || die 'FM_HOME is not set; this script reports on an explicit firstmate home'
[ -d "$STATE" ] || die "state dir '$STATE' is missing"

LEDGER=$(fm_decider_ledger_path "$STATE")
WINDOW=$(fm_decider_ruling_window)
NOW=$(fm_decider_now)
CUTOFF=$((NOW - DAYS * 86400))

# Fold the ledger into episodes and aggregate. An episode is one opening of one
# key: <first_seen> identifies it, so a key that closes and reopens is counted
# (and clocked) twice, which is what a weekly report should show.
AGG=''
if [ -f "$LEDGER" ]; then
  AGG=$(awk -F'\t' -v OFS='\t' -v cutoff="$CUTOFF" -v window="$WINDOW" '
    $1 == "O" {
      n++
      # Episode identity is the task AND the key: two tasks may hold the same
      # decision key in the same week, and each is its own episode.
      cur[$3 SUBSEP $4] = n
      e_first[n] = $2
      e_class[n] = $5
      e_asked[n] = 0
      e_ruled[n] = 0
      e_closed[n] = 0
      next
    }
    {
      idx = cur[$3 SUBSEP $4]
      if (idx == "") next
      if ($1 == "A") { e_asked[idx] = $6; }
      else if ($1 == "R") { e_ruled[idx] = $6; }
      else if ($1 == "C") { e_closed[idx] = $6; }
    }
    END {
      for (i = 1; i <= n; i++) {
        first = e_first[i] + 0
        if (first < cutoff) continue
        cls = e_class[i]
        total++
        class_total[cls]++
        if (e_asked[i] > 0) {
          routed++
          class_routed[cls]++
          if (e_ruled[i] > 0) {
            ruled++
            class_ruled[cls]++
            if (e_ruled[i] - first <= window) {
              within++
              class_within[cls]++
            }
          } else if (e_closed[i] == 0) {
            open_routed++
            class_open[cls]++
          } else {
            closed_unruled++
            class_closed_unruled[cls]++
          }
        } else if (e_ruled[i] > 0) {
          # A ruling recorded for an episode that was never asked: the seat
          # answered something the sweep had not reached yet. Counted, and
          # disclosed separately so it can never inflate the headline.
          ruled_unasked++
        } else if (e_closed[i] == 0) {
          open_other++
        }
      }
      printf "TOTAL\t%d\n", total
      printf "ROUTED\t%d\n", routed
      printf "RULED\t%d\n", ruled
      printf "WITHIN\t%d\n", within
      printf "CLOSED_UNRULED\t%d\n", closed_unruled
      printf "OPEN_ROUTED\t%d\n", open_routed
      printf "OPEN_OTHER\t%d\n", open_other
      printf "RULED_UNASKED\t%d\n", ruled_unasked
      for (cls in class_total) {
        printf "CLASS\t%s\t%d\t%d\t%d\t%d\t%d\n", cls, class_total[cls], class_routed[cls], class_ruled[cls], class_within[cls], class_closed_unruled[cls]
      }
    }
  ' "$LEDGER")
fi

TOTAL=0 ROUTED=0 RULED=0 WITHIN=0 CLOSED_UNRULED=0 OPEN_ROUTED=0 OPEN_OTHER=0 RULED_UNASKED=0
CLASSES=''
while IFS=$'\t' read -r tag a b c d e f; do
  case "$tag" in
    TOTAL) TOTAL=$a ;;
    ROUTED) ROUTED=$a ;;
    RULED) RULED=$a ;;
    WITHIN) WITHIN=$a ;;
    CLOSED_UNRULED) CLOSED_UNRULED=$a ;;
    OPEN_ROUTED) OPEN_ROUTED=$a ;;
    OPEN_OTHER) OPEN_OTHER=$a ;;
    RULED_UNASKED) RULED_UNASKED=$a ;;
    CLASS) CLASSES="$CLASSES$a	$b	$c	$d	$e	$f
" ;;
  esac
done <<EOF
$AGG
EOF

# Stable class order so two reports of the same facts read the same way.
if [ -n "$CLASSES" ]; then
  CLASSES=$(printf '%s' "$CLASSES" | LC_ALL=C sort)
  CLASSES="$CLASSES
"
fi

# 80% of the keys routed to the seat, ruled inside the window. Fewer than
# FM_DECIDER_METRICS_MIN_ROUTED routed keys cannot meet the definition either way,
# so a small sample reports itself as insufficient instead of as a pass.
MIN_ROUTED=${FM_DECIDER_METRICS_MIN_ROUTED:-5}
case "$MIN_ROUTED" in ''|*[!0-9]*) MIN_ROUTED=5 ;; esac
PCT=0
VERDICT='no data'
if [ "$ROUTED" -gt 0 ]; then
  PCT=$((WITHIN * 100 / ROUTED))
  # Integer division floor: a real non-zero rate must never read as 0%.
  if [ "$PCT" -eq 0 ] && [ "$WITHIN" -gt 0 ]; then PCT=1; fi
  if [ "$ROUTED" -lt "$MIN_ROUTED" ]; then
    VERDICT='insufficient data'
  elif [ $((WITHIN * 100)) -ge $((80 * ROUTED)) ]; then
    VERDICT='pass'
  else
    VERDICT='fail'
  fi
fi

if [ "$JSON" = 1 ]; then
  json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
  printf '{"home":"%s","days":%s,"window_seconds":%s,' "$(json_escape "$FM_HOME")" "$DAYS" "$WINDOW"
  printf '"episodes":%s,"routed":%s,"ruled":%s,"ruled_within":%s,' \
    "$TOTAL" "$ROUTED" "$RULED" "$WITHIN"
  printf '"closed_without_ruling":%s,"open_routed":%s,"open_other":%s,' \
    "$CLOSED_UNRULED" "$OPEN_ROUTED" "$OPEN_OTHER"
  printf '"ruled_unasked":%s,"dod_threshold":80,"dod_percent":%s,"dod_verdict":"%s",' \
    "$RULED_UNASKED" "$PCT" "$VERDICT"
  printf '"by_class":['
  first=1
  while IFS=$'\t' read -r cls ep routed ruled within closed; do
    [ -n "$cls" ] || continue
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"class":"%s","episodes":%s,"routed":%s,"ruled":%s,"ruled_within":%s,"closed_without_ruling":%s}' \
      "$(json_escape "$cls")" "$ep" "$routed" "$ruled" "$within" "$closed"
  done <<EOF
$CLASSES
EOF
  printf ']}\n'
  exit 0
fi

printf 'DECIDER ROUTING REPORT - last %s day(s), window %ss\n' "$DAYS" "$WINDOW"
printf 'home: %s\n' "$FM_HOME"
printf '\n'
printf 'episodes opened:          %s\n' "$TOTAL"
printf 'routed to the seat:       %s\n' "$ROUTED"
printf 'ruled by the seat:        %s\n' "$RULED"
printf 'ruled inside the window:  %s\n' "$WITHIN"
printf 'closed without a ruling:  %s\n' "$CLOSED_UNRULED"
printf 'still open, routed:       %s\n' "$OPEN_ROUTED"
printf 'never routed (captain or unclassified): %s\n' "$OPEN_OTHER"
if [ "$RULED_UNASKED" -gt 0 ]; then
  printf 'ruled without a routing request: %s\n' "$RULED_UNASKED"
fi
if [ -n "$CLASSES" ]; then
  printf '\nclass\topened\trouted\truled\twithin\tclosed-unruled\n'
  printf '%s' "$CLASSES"
fi
printf '\n'
if [ "$VERDICT" = 'no data' ]; then
  printf 'DoD: 80%% of routed decisions ruled within %ss - nothing routed yet\n' "$WINDOW"
elif [ "$VERDICT" = 'insufficient data' ]; then
  printf 'DoD: 80%% of routed decisions ruled within %ss - %s of %s routed (insufficient data; needs at least %s)\n' \
    "$WINDOW" "$WITHIN" "$ROUTED" "$MIN_ROUTED"
else
  printf 'DoD: 80%% of routed decisions ruled within %ss - %s of %s (%s%%) %s\n' \
    "$WINDOW" "$WITHIN" "$ROUTED" "$PCT" "$VERDICT"
fi
exit 0

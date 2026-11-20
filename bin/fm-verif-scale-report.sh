#!/usr/bin/env bash
# fm-verif-scale-report.sh - the live read behind the verification-throughput
# goal: how many proof asks went out, how many decisions were written, how often
# an ask comes back with proof, and how deep the queue is.
#
# Usage:
#   fm-verif-scale-report.sh           read every source live and print the report
#   fm-verif-scale-report.sh --help    print this help
#
# Exit status: 0 when every source was read, 1 when any number is UNMEASURED,
# 2 on a usage error.
#
# WHY THIS EXISTS. The goal's acceptance check named this script for two days
# before it existed, so the goal advanced on prose. The numbers it replaces
# were wrong in three repeatable ways, and each rule below closes one of them.
#
#   1. A number that could not be read was printed as 0. Here a source that
#      does not answer, answers with an error, or answers in a shape this
#      script does not recognise prints
#          UNMEASURED: <source> (<reason>)
#      and the run exits 1. Nothing is defaulted, nothing is carried over from
#      an earlier run, and no total is printed whose parts were not all read.
#   2. A cumulative count was subtracted from a windowed one. Every number
#      line starts with `window:` (it happened inside the stated window) or
#      `total:` (a standing count as of the stated time), and carries its
#      source and the exact query that produced it on the same line. The
#      printed query is the statement that ran, not a paraphrase.
#   3. Every sent message was counted as a proof ask. The message ledger holds
#      asks, reminders, status notes, refusals, and replies in one table, so
#      the ask lines count three campaigns BY NAME and nothing else:
#          proof-need-ask, claim-proof-ask, uvn-new-rows
#      Reminders (uvn-reminder-*) and status notes (uvn-status, claim-status)
#      are not asks; they are printed on their own line, named as excluded.
#      Every other campaign sent in the window is listed by name on a third
#      line, so a new ask campaign cannot be dropped silently.
#
# No number here comes from a plan, a config value, or a target.
#
# THE READS. Three sources, each read in one call over ssh to the ledger host,
# so one unreadable source costs only its own lines.
#
#   verify_messages   the message ledger, a table of the review ledger
#                     (SQLite, opened read-only). Proof asks sent in the last
#                     60 minutes and the last 24 hours, the excluded families
#                     for the same windows, and the 7-day return rate: of the
#                     asks sent in the last 7 days, the share that carry proof
#                     (a proof tag or a proof attachment on the ask's row),
#                     with the same read per send day so a reader can see
#                     whether it is rising. Returns are counted up to the read
#                     time, so the newest send days are still filling.
#                     A message's time is its sent_at, or created_at when
#                     sent_at is empty, and the table holds two timestamp
#                     shapes; both are normalised before comparing, and a
#                     sent row in neither shape makes the source UNMEASURED.
#   decisions         the decide ledger, a table of the same file. A row is
#                     counted as a decision only when it was written with mode
#                     'apply' AND its decision is one of three BY NAME:
#                         approve, approve_partial, support
#                     which are the three the ledger's own outcome table has
#                     an action for. Read for the last 60 minutes and the last
#                     24 hours, with the number of distinct requests, because
#                     the ledger is appended on every pass. Every other row is
#                     printed on its own line, named as excluded: hold (the
#                     ledger's own schema calls it "no write, a human looks"),
#                     defer, and close in apply mode, and every row of another
#                     mode (judge, shadow). A request held on every pass
#                     writes a hold row on every pass, so counting rows as
#                     decisions overstates the rate by orders of magnitude.
#   credit_requests   core's request table, read through the ledger host's
#                     Trino wrapper. Open undecided is every request whose
#                     status is neither approved nor rejected. Two lines, both
#                     labelled: GROSS includes soft-deleted rows, NET leaves
#                     them out. The ledger's own request_state table is not
#                     read: it is not the count of record.
#
# Window bounds and read times come from the source's own clock, in UTC.
#
# CONFIGURATION. config/verif-scale.env is optional, local, gitignored, parsed
# line by line and never sourced; a value is the rest of its line, so a comment
# belongs on its own line. A set environment variable of the same name wins
# over the file. The host has no built-in default: with none configured the
# report is UNMEASURED, never a guess.
#
#   FM_VERIF_SCALE_HOST          ssh destination of the ledger host (required)
#   FM_VERIF_SCALE_JUMP          ssh jump host, when the ledger host is reached through one
#   FM_VERIF_SCALE_LEDGER        ledger file on that host
#                                (default /var/lib/hydra/credit-review/ledger.sqlite3)
#   FM_VERIF_SCALE_TRINO         core query wrapper on that host; takes one SQL argument
#                                (default /opt/hydra/scripts/trino-query.sh)
#   FM_VERIF_SCALE_LEDGER_SECS   bound on one ledger read, seconds (default 60)
#   FM_VERIF_SCALE_CORE_SECS     bound on the core read, seconds (default 180)
#   FM_VERIF_SCALE_CONNECT_SECS  ssh connect timeout, seconds (default 10)
#
# Test hook: FM_VERIF_SCALE_SSH (the ssh binary).
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
ENV_FILE="$CONFIG_DIR/verif-scale.env"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  '') ;;
  -h|--help|help) usage; exit 0 ;;
  *) printf 'fm-verif-scale-report: unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
esac

# conf <KEY> <default>: the environment, then the config file, then the default.
conf() {
  local key=$1 default=$2 value='' found=0 line
  if [ -n "${!key+x}" ]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*)
          value=${line#*=}
          value=${value%"${value##*[![:space:]]}"}
          found=1
          ;;
      esac
    done < "$ENV_FILE"
  fi
  if [ "$found" = 1 ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

conf_secs() {  # <KEY> <default>: a positive whole number of seconds, else the default
  local v
  v=$(conf "$1" "$2")
  case "$v" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

HOST=$(conf FM_VERIF_SCALE_HOST '')
JUMP=$(conf FM_VERIF_SCALE_JUMP '')
LEDGER=$(conf FM_VERIF_SCALE_LEDGER /var/lib/hydra/credit-review/ledger.sqlite3)
TRINO=$(conf FM_VERIF_SCALE_TRINO /opt/hydra/scripts/trino-query.sh)
LEDGER_SECS=$(conf_secs FM_VERIF_SCALE_LEDGER_SECS 60)
CORE_SECS=$(conf_secs FM_VERIF_SCALE_CORE_SECS 180)
CONNECT_SECS=$(conf_secs FM_VERIF_SCALE_CONNECT_SECS 10)
SSH_BIN=${FM_VERIF_SCALE_SSH:-ssh}

FAILED=0
ERR=''
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { [ -z "$ERR" ] || rm -f "$ERR"; }
trap cleanup EXIT

unmeasured() {  # <source> <reason>
  printf 'UNMEASURED: %s (%s)\n' "$1" "$2"
  FAILED=1
}

emit() {  # <window|total> <what and value> <source> <query>
  printf '%s: %s | source: %s | query: %s\n' "$1" "$2" "$3" "$4"
}

if [ -z "$HOST" ]; then
  unmeasured 'ledger host' 'no host configured: set FM_VERIF_SCALE_HOST in the environment or in config/verif-scale.env'
  exit 1
fi

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-verif-scale.XXXXXX") || {
  unmeasured 'ledger host' 'no temporary file for the read'
  exit 1
}

# remote <seconds> <remote-command>: one bounded read. Prints the remote
# stdout, keeps stderr in $ERR for the reason, and returns ssh's own status
# (124 when the bound was hit).
remote() {
  local secs=$1 cmd=$2
  local -a args=(-n -o BatchMode=yes -o "ConnectTimeout=$CONNECT_SECS")
  [ -z "$JUMP" ] || args+=(-J "$JUMP")
  : > "$ERR"
  fm_run_timed "$secs" "$SSH_BIN" "${args[@]}" "$HOST" "$cmd" 2>"$ERR"
}

# why <status> <seconds>: the one-line reason a read failed.
why() {
  local rc=$1 secs=$2 line
  line=$(grep -v -E 'org\.jline|dumb terminal|^[[:space:]]*$' "$ERR" 2>/dev/null | tail -n 1 | tr -d '\r' | cut -c1-240)
  case "$rc" in
    124) printf 'no answer within %ss' "$secs" ;;
    255) printf 'ssh to %s failed: %s' "$HOST" "${line:-no error text}" ;;
    *) printf 'exit %s: %s' "$rc" "${line:-no error text}" ;;
  esac
}

ledger_read() {  # <sql>: every statement of one source, in one read-only call
  remote "$LEDGER_SECS" "sqlite3 -readonly -bail -batch -list -noheader -cmd '.timeout 10000' $(printf '%q' "$LEDGER") $(printf '%q' "$1")"
}

row() {  # <n> <text>: line n of a read
  printf '%s\n' "$2" | sed -n "${1}p"
}

is_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_stamp() {  # YYYY-MM-DD HH:MM:SS
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

per_hour() {  # <count> <hours>
  awk -v n="$1" -v h="$2" 'BEGIN { printf "%.1f", n / h }'
}

# --- the message ledger: proof asks and the return rate -----------------------

ASK_NAMES="'proof-need-ask', 'claim-proof-ask', 'uvn-new-rows'"
SENT_AT="replace(substr(coalesce(sent_at, created_at), 1, 19), 'T', ' ')"
IS_ASK="status = 'sent' AND campaign IN ($ASK_NAMES)"
IS_EXCLUDED="status = 'sent' AND (campaign LIKE 'uvn-reminder-%' OR campaign IN ('uvn-status', 'claim-status'))"
IS_OTHER="status = 'sent' AND campaign NOT IN ($ASK_NAMES, 'uvn-status', 'claim-status') AND campaign NOT LIKE 'uvn-reminder-%'"
HAS_PROOF="(proof_tagged_at IS NOT NULL OR coalesce(proof_attachments, 0) > 0)"
STAMP_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]'

q_asks() {  # <sqlite modifier>
  printf "SELECT count(*), coalesce(sum(campaign = 'proof-need-ask'), 0), coalesce(sum(campaign = 'claim-proof-ask'), 0), coalesce(sum(campaign = 'uvn-new-rows'), 0) FROM verify_messages WHERE %s AND %s >= datetime('now', '%s')" "$IS_ASK" "$SENT_AT" "$1"
}

q_excluded() {  # <sqlite modifier>
  printf "SELECT count(*), coalesce(sum(campaign LIKE 'uvn-reminder-%%'), 0), coalesce(sum(campaign = 'uvn-status'), 0), coalesce(sum(campaign = 'claim-status'), 0) FROM verify_messages WHERE %s AND %s >= datetime('now', '%s')" "$IS_EXCLUDED" "$SENT_AT" "$1"
}

MSG_SOURCE="verify_messages in $HOST:$LEDGER"
Q_MSG_NOW="SELECT datetime('now')"
Q_MSG_SHAPE="SELECT count(*) FROM verify_messages WHERE status = 'sent' AND $SENT_AT NOT GLOB '$STAMP_GLOB'"
Q_ASKS_1H=$(q_asks '-1 hour')
Q_EXCL_1H=$(q_excluded '-1 hour')
Q_ASKS_24H=$(q_asks '-24 hours')
Q_EXCL_24H=$(q_excluded '-24 hours')
Q_OTHER_24H="SELECT coalesce(group_concat(campaign || '=' || n, ' '), 'none') FROM (SELECT campaign, count(*) AS n FROM verify_messages WHERE $IS_OTHER AND $SENT_AT >= datetime('now', '-24 hours') GROUP BY campaign ORDER BY campaign)"
Q_RETURN_7D="SELECT count(*), coalesce(sum($HAS_PROOF), 0) FROM verify_messages WHERE $IS_ASK AND $SENT_AT >= datetime('now', '-7 days')"
Q_RETURN_DAYS="SELECT coalesce(group_concat(d || ' ' || p || '/' || n || ' ' || round(100.0 * p / n, 1) || '%', ', '), 'none') FROM (SELECT substr($SENT_AT, 1, 10) AS d, count(*) AS n, sum($HAS_PROOF) AS p FROM verify_messages WHERE $IS_ASK AND $SENT_AT >= datetime('now', '-7 days') GROUP BY d ORDER BY d)"

# ask_line <label> <hours> <now> <row> <query>: prints one ask line, or fails
# when the row is not four whole numbers whose parts sum to the first.
ask_line() {
  local label=$1 hours=$2 now=$3 row=$4 query=$5 total a b c rate
  IFS='|' read -r total a b c <<EOF
$row
EOF
  is_int "$total" && is_int "$a" && is_int "$b" && is_int "$c" || return 1
  [ $((a + b + c)) -eq "$total" ] || return 1
  if [ "$hours" = 1 ]; then
    rate="$total per hour"
  else
    rate="$total, $(per_hour "$total" "$hours") per hour on average"
  fi
  emit window "proof asks sent, $label to ${now}Z = $rate (proof-need-ask=$a claim-proof-ask=$b uvn-new-rows=$c; reminders and status notes are not asks and are not counted)" "$MSG_SOURCE" "$query"
}

excluded_line() {  # <label> <now> <row> <query>
  local label=$1 now=$2 row=$3 query=$4 total a b c
  IFS='|' read -r total a b c <<EOF
$row
EOF
  is_int "$total" && is_int "$a" && is_int "$b" && is_int "$c" || return 1
  [ $((a + b + c)) -eq "$total" ] || return 1
  emit window "NOT proof asks, EXCLUDED from the ask line, $label to ${now}Z = $total sent (reminders uvn-reminder-*=$a, status notes uvn-status=$b claim-status=$c)" "$MSG_SOURCE" "$query"
}

report_messages() {
  local out rc now shape asked returned pct lines
  out=$(ledger_read "$Q_MSG_NOW; $Q_MSG_SHAPE; $Q_ASKS_1H; $Q_EXCL_1H; $Q_ASKS_24H; $Q_EXCL_24H; $Q_OTHER_24H; $Q_RETURN_7D; $Q_RETURN_DAYS")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    unmeasured "$MSG_SOURCE - proof asks and return rate" "$(why "$rc" "$LEDGER_SECS")"
    return 0
  fi
  now=$(row 1 "$out")
  shape=$(row 2 "$out")
  if ! is_stamp "$now" || ! is_int "$shape" || [ "$(printf '%s\n' "$out" | wc -l)" -ne 9 ]; then
    unmeasured "$MSG_SOURCE - proof asks and return rate" "the read answered in a shape this report does not recognise: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ' | cut -c1-120)"
    return 0
  fi
  if [ "$shape" -ne 0 ]; then
    unmeasured "$MSG_SOURCE - proof asks and return rate" "$shape sent rows carry a timestamp in neither known shape, so a window over them would be wrong"
    return 0
  fi
  # Build every line before printing any, so a half-read source prints nothing.
  lines=$(
    ask_line 'window last 60 min' 1 "$now" "$(row 3 "$out")" "$Q_ASKS_1H" || exit 1
    excluded_line 'window last 60 min' "$now" "$(row 4 "$out")" "$Q_EXCL_1H" || exit 1
    ask_line 'window last 24 h' 24 "$now" "$(row 5 "$out")" "$Q_ASKS_24H" || exit 1
    excluded_line 'window last 24 h' "$now" "$(row 6 "$out")" "$Q_EXCL_24H" || exit 1
    [ -n "$(row 7 "$out")" ] || exit 1
    emit window "other campaigns sent, neither proof asks nor the named exclusions, not counted, window last 24 h to ${now}Z = $(row 7 "$out")" "$MSG_SOURCE" "$Q_OTHER_24H"
  ) || {
    unmeasured "$MSG_SOURCE - proof asks and return rate" 'a count came back that is not a whole number, or its parts do not sum to it'
    return 0
  }
  printf '%s\n' "$lines"

  IFS='|' read -r asked returned <<EOF
$(row 8 "$out")
EOF
  if ! is_int "$asked" || ! is_int "$returned" || [ "$returned" -gt "$asked" ] || [ -z "$(row 9 "$out")" ]; then
    unmeasured "$MSG_SOURCE - return rate" 'the 7-day read did not answer with a sent count and a returned count'
    return 0
  fi
  if [ "$asked" -eq 0 ]; then
    unmeasured "$MSG_SOURCE - return rate" "no proof ask was sent in the 7 days to ${now}Z, and a rate over zero asks is not a rate"
    return 0
  fi
  pct=$(awk -v p="$returned" -v n="$asked" 'BEGIN { printf "%.2f", 100 * p / n }')
  emit window "ask to proof return rate, window last 7 days to ${now}Z = ${pct}% ($returned of $asked proof asks sent in the window carry proof; returns counted to the read time)" "$MSG_SOURCE" "$Q_RETURN_7D"
  emit window "ask to proof return by send day (returned/sent), window last 7 days to ${now}Z = $(row 9 "$out") (newest days still filling)" "$MSG_SOURCE" "$Q_RETURN_DAYS"
}

# --- the decide ledger: decisions ---------------------------------------------

DEC_SOURCE="decisions (the decide ledger) in $HOST:$LEDGER"
DEC_GLOB='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'
IS_DECISION="mode = 'apply' AND decision IN ('approve', 'approve_partial', 'support')"

dec_since() {  # <sqlite modifier>: decided_at is one shape (checked below), so the index serves it
  printf "decided_at >= strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', 'now', '%s')" "$1"
}

q_decisions() {  # <sqlite modifier>
  printf "SELECT count(*), count(DISTINCT request_id), coalesce(sum(decision = 'approve'), 0), coalesce(sum(decision = 'approve_partial'), 0), coalesce(sum(decision = 'support'), 0) FROM decisions WHERE %s AND %s" "$IS_DECISION" "$(dec_since "$1")"
}

q_not_decisions() {  # <sqlite modifier>
  printf "SELECT coalesce(sum(n), 0), coalesce(group_concat(k || '=' || n, ' '), 'none') FROM (SELECT CASE WHEN mode = 'apply' THEN decision ELSE 'mode-' || mode END AS k, count(*) AS n FROM decisions WHERE NOT (%s) AND %s GROUP BY k ORDER BY k)" "$IS_DECISION" "$(dec_since "$1")"
}

Q_DEC_NOW="SELECT datetime('now')"
Q_DEC_SHAPE="SELECT count(*) FROM decisions WHERE decided_at >= strftime('%Y-%m-%d', 'now', '-2 days') AND decided_at NOT GLOB '$DEC_GLOB'"
Q_DEC_1H=$(q_decisions '-1 hour')
Q_DEC_24H=$(q_decisions '-24 hours')
Q_DEC_OFF_1H=$(q_not_decisions '-1 hour')
Q_DEC_OFF_24H=$(q_not_decisions '-24 hours')

decision_line() {  # <label> <hours> <now> <row> <query>
  local label=$1 hours=$2 now=$3 row=$4 query=$5 total requests a b c rate
  IFS='|' read -r total requests a b c <<EOF
$row
EOF
  is_int "$total" && is_int "$requests" && is_int "$a" && is_int "$b" && is_int "$c" || return 1
  [ $((a + b + c)) -eq "$total" ] && [ "$requests" -le "$total" ] || return 1
  if [ "$hours" = 1 ]; then
    rate="$total per hour"
  else
    rate="$total, $(per_hour "$total" "$hours") per hour on average"
  fi
  emit window "decisions written, $label to ${now}Z = $rate on $requests distinct requests (approve=$a approve_partial=$b support=$c; holds, defers, closes, and judge or shadow rows are not decisions written and are not counted)" "$DEC_SOURCE" "$query"
}

not_decision_line() {  # <label> <now> <row> <query>
  local label=$1 now=$2 row=$3 query=$4 total parts
  IFS='|' read -r total parts <<EOF
$row
EOF
  is_int "$total" && [ -n "$parts" ] || return 1
  emit window "decide rows that wrote no decision, EXCLUDED from the decision line, $label to ${now}Z = $total rows ($parts)" "$DEC_SOURCE" "$query"
}

report_decisions() {
  local out rc now shape lines
  out=$(ledger_read "$Q_DEC_NOW; $Q_DEC_SHAPE; $Q_DEC_1H; $Q_DEC_OFF_1H; $Q_DEC_24H; $Q_DEC_OFF_24H")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    unmeasured "$DEC_SOURCE - decisions" "$(why "$rc" "$LEDGER_SECS")"
    return 0
  fi
  now=$(row 1 "$out")
  shape=$(row 2 "$out")
  if ! is_stamp "$now" || ! is_int "$shape" || [ "$(printf '%s\n' "$out" | wc -l)" -ne 6 ]; then
    unmeasured "$DEC_SOURCE - decisions" "the read answered in a shape this report does not recognise: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ' | cut -c1-120)"
    return 0
  fi
  if [ "$shape" -ne 0 ]; then
    unmeasured "$DEC_SOURCE - decisions" "$shape recent rows carry a decided_at this report cannot place in a window"
    return 0
  fi
  lines=$(
    decision_line 'window last 60 min' 1 "$now" "$(row 3 "$out")" "$Q_DEC_1H" || exit 1
    not_decision_line 'window last 60 min' "$now" "$(row 4 "$out")" "$Q_DEC_OFF_1H" || exit 1
    decision_line 'window last 24 h' 24 "$now" "$(row 5 "$out")" "$Q_DEC_24H" || exit 1
    not_decision_line 'window last 24 h' "$now" "$(row 6 "$out")" "$Q_DEC_OFF_24H" || exit 1
  ) || {
    unmeasured "$DEC_SOURCE - decisions" 'a count came back that is not a whole number, or its parts do not sum to it'
    return 0
  }
  printf '%s\n' "$lines"
}

# --- core: queue depth ----------------------------------------------------------

QUEUE_SOURCE="core credit_requests through $HOST:$TRINO"
Q_QUEUE="SELECT count(*), count_if(deletedat IS NULL), format_datetime(current_timestamp AT TIME ZONE 'UTC', 'yyyy-MM-dd HH:mm:ss') FROM postgresql_core.public.credit_requests WHERE status NOT IN ('approved', 'rejected')"

report_queue() {
  local out rc rows gross net now
  out=$(remote "$CORE_SECS" "$(printf '%q' "$TRINO") $(printf '%q' "$Q_QUEUE")")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    unmeasured "$QUEUE_SOURCE - queue depth" "$(why "$rc" "$CORE_SECS")"
    return 0
  fi
  rows=$(printf '%s\n' "$out" | tr -d '\r' | grep '^"' || true)
  IFS=',' read -r gross net now <<EOF
$(printf '%s' "$rows" | tr -d '"')
EOF
  if [ "$(printf '%s\n' "$rows" | wc -l)" -ne 1 ] || ! is_int "$gross" || ! is_int "$net" || ! is_stamp "$now"; then
    unmeasured "$QUEUE_SOURCE - queue depth" "the read answered in a shape this report does not recognise: $(printf '%s' "$out" | tail -n 1 | cut -c1-120)"
    return 0
  fi
  if [ "$net" -gt "$gross" ]; then
    unmeasured "$QUEUE_SOURCE - queue depth" "the read answered net $net above gross $gross"
    return 0
  fi
  emit total "queue depth GROSS, open undecided INCLUDING soft-deleted rows, as of ${now}Z = $gross" "$QUEUE_SOURCE" "$Q_QUEUE"
  emit total "queue depth NET, open undecided with soft-deleted rows left out, as of ${now}Z = $net ($((gross - net)) soft-deleted)" "$QUEUE_SOURCE" "$Q_QUEUE"
}

report_messages
report_decisions
report_queue

if [ "$FAILED" -ne 0 ]; then
  printf 'INCOMPLETE: at least one source is UNMEASURED; no number is implied for it, and this run proves nothing about the goal.\n'
  exit 1
fi
exit 0

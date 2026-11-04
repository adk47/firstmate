#!/usr/bin/env bash
# fm-ticket-intake.sh - the captain ask's path from Trigger to an owned ticket
# with a time bound, and the ledger that proves it.
#
# Usage:
#   fm-ticket-intake.sh trigger [<text>...] [--source <src>] [--thread <id>]
#                              [--class <cls>] [--note <note-id>] [--text-file <p>|-]
#   fm-ticket-intake.sh new <trigger-id> --title <title> [--owner <worker>]
#                              [--repo <repo>] [--kind <kind>]
#   fm-ticket-intake.sh attach <task-id> [--trigger <trigger-id>] [--owner <worker>]
#                              [--title <title>] [--source <src>] [--thread <id>]
#                              [--class <cls>]
#   fm-ticket-intake.sh owner <task-id> <worker>
#   fm-ticket-intake.sh proof <task-id>
#   fm-ticket-intake.sh close <trigger-id> --reason <reason>
#   fm-ticket-intake.sh ledger [--open]
#   fm-ticket-intake.sh status
#   fm-ticket-intake.sh check      registered slow-poll: imports pending captain
#                                  notes and pages the bounds (silent otherwise)
#   fm-ticket-intake.sh arm        write state/ticket-intake.check.sh and bind it
#   fm-ticket-intake.sh disarm     remove the shim, its trust binding, and the record
#   fm-ticket-intake.sh --help     print this help
#
# WHAT THIS IS. One captain input (a chat ask, a voice note, an inbox note, a
# Slack DM, a Relay mention) is a Trigger with an id and a Thread id; a Trigger
# becomes ONE agent-side ticket carrying an owner and a first-proof due time;
# and a ticket with no owner, or an owner with no first proof, is paged on a
# time bound instead of waiting for someone to remember it. This script owns the
# record and the bound. It does NOT decide the route, spawn a worker, or answer
# anything: the router decides new ticket / attach to an existing ticket / route
# to an existing worker, bin/fm-spawn.sh still launches, and this script only
# makes the decision and the time bound durable.
#
# TRIGGERS. `trigger` records an arriving captain input and prints its id
# (`tr-<epoch>-<6>`); `--thread` records the Thread the ask belongs to, and the
# Thread is carried onto the ticket. Automated sources are NOT captain asks and
# never become Triggers here: `check` imports only notes still pending in the
# captain inbox, and skips any whose body is marked automated, because the
# captain inbox is the captain's surface rather than a log sink.
#
# TICKETS. `new` creates the tasks-axi `captain-ask` row (minted id, kind,
# optional repo) and mirrors the owner, Thread, source, and first-proof due into
# the row body so `tasks-axi show` reads correctly to a human. `attach` records
# the same binding for a row that already exists - the manual-backlog path, and
# the route-to-existing-worker decision - without touching that row's body, so
# an existing note is never overwritten. A ticket whose row is Done, archived,
# or held for the captain is never paged: a closed or captain-owned row has no
# owner obligation left.
#
# THE BOUND. `check` measures two conditions against real records:
#   unowned      a Trigger with no ticket, or a ticket with no owner, older than
#                unowned_page_secs (default 600, ten minutes).
#   first-proof  an owned ticket whose owner shows no first proof by
#                due_first_proof (owner assignment plus first_proof_secs,
#                default 3600, one hour).
# A first proof is the owner task's first status event appended after it was
# given the ticket, its turn-end marker moving after that moment, or an explicit
# `proof`. It is read from state/<owner>.status and state/<owner>.turn-ended, so
# proof is evidence in a durable record rather than a claim in a chat message.
# Each condition pages once when it opens, reminds every remind_secs (default
# 1800), and reports recovered when it clears. Pages are ordinary check lines to
# firstmate, which owns acting on them (assign, reassign, unblock, relaunch);
# nothing here merges, spawns, or closes work.
#
# LEDGER. `ledger` is the generated captain-asks view: one row per Trigger and
# per ticket, with arrival, source, Thread, owner, first-proof due, first proof,
# row state, and the router's decision latency (the two-minute decision bound is
# measured here, not assumed). It replaces a hand-kept asks list; a hand-written
# list is evidence at best, never the record. `--open` hides rows that are
# closed, held, or decided as answered, and `status` prints the coverage counts.
#
# FILES. `state/intake/triggers/<trigger-id>.trigger` and
# `state/intake/tickets/<task-id>.ticket` are private `key=value` records: the
# trigger record holds id, at, at_epoch, source, thread, class, note, text,
# decision, decision_at, decision_epoch, task, reason, while the ticket record
# holds task, title, trigger, repo, kind, source, thread, class, owner, owner_at,
# owner_epoch, intake_at, intake_epoch, due_first_proof, due_epoch,
# status_log_lines, proof_at, proof_epoch, proof_by. `state/.ticket-intake` holds
# the open findings and their reminder clocks; arm and disarm own the check shim
# and its trust binding.
#
# THRESHOLDS. FM_TICKET_INTAKE_UNOWNED_PAGE_SECS, FM_TICKET_INTAKE_FIRST_PROOF_SECS,
# FM_TICKET_INTAKE_REMIND_SECS, and their config/ticket-intake.env equivalents
# (unowned_page_secs, first_proof_secs, remind_secs) are parsed line by line and
# never sourced; docs/configuration.md owns that schema. FM_TICKET_INTAKE_NOW
# pins the clock for a test run.
#
# ARMING. Recording the first Trigger or ticket arms the check when the home is
# not already armed, because a bound nobody measures is not a bound. `arm` and
# `disarm` remain the explicit switches, and a failed auto-arm is reported on
# stderr without losing the record.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
INTAKE_DIR="$STATE/intake"
TRIGGER_DIR="$INTAKE_DIR/triggers"
TICKET_DIR="$INTAKE_DIR/tickets"
INBOX="$STATE/inbox"
ENV_FILE="$CONFIG_DIR/ticket-intake.env"
RECORD="$STATE/.ticket-intake"
CHECK_ID=ticket-intake
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-ticket-intake-v1
MAX_TEXT=400
MAX_LINE=1000
CAPTAIN_ASK_KIND=captain-ask
AUTOMATED_MARKER='automated, not the captain'

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die() {
  printf 'fm-ticket-intake: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'fm-ticket-intake: %s\n' "$*" >&2
}

now_epoch() {
  case "${FM_TICKET_INTAKE_NOW:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s\n' "$FM_TICKET_INTAKE_NOW" ;;
  esac
}

# Seconds since the epoch as an ISO-8601 UTC stamp. BSD date reads -r, GNU date
# reads -d, and each fails on the other's flag, so the second form is the fallback.
iso_utc() {
  local epoch=$1
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$epoch"
}

# An ISO-8601 UTC stamp back to seconds, for an inbox note's own `at=` line.
epoch_from_iso() {
  local stamp=$1
  [ -n "$stamp" ] || return 1
  date -u -d "$stamp" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$stamp" +%s 2>/dev/null
}

stat_epoch() {  # <path>
  local stamp
  [ -n "${1:-}" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    stamp=$(stat -f %m "$1" 2>/dev/null)
  else
    stamp=$(stat -c %Y "$1" 2>/dev/null)
  fi
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$stamp"
}

human_duration() {
  local secs=$1 days hours mins
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  [ "$secs" -ge 0 ] || secs=0
  if [ "$secs" -ge 86400 ]; then
    days=$((secs / 86400))
    hours=$(((secs % 86400) / 3600))
    printf '%dd%dh' "$days" "$hours"
  elif [ "$secs" -ge 3600 ]; then
    hours=$((secs / 3600))
    mins=$(((secs % 3600) / 60))
    printf '%dh%dm' "$hours" "$mins"
  elif [ "$secs" -ge 60 ]; then
    printf '%dm' "$((secs / 60))"
  else
    printf '%ds' "$secs"
  fi
}

# conf <KEY> <default>: a set environment variable, else the env file's value,
# else the default. The file is parsed line by line and never sourced.
conf() {
  local key=$1 default=$2 line value='' found=0
  eval "value=\${$key:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      line=${line#"${line%%[![:space:]]*}"}
      line=${line%"${line##*[![:space:]]}"}
      [ -n "$line" ] || continue
      case "$line" in
        "$key"=*)
          value=${line#*=}
          found=1
          ;;
      esac
    done < "$ENV_FILE"
  fi
  if [ "$found" = 1 ] && [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' "$default"
}

conf_secs() {  # <KEY> <default>
  local value
  value=$(conf "$1" "$2")
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

UNOWNED_PAGE_SECS=$(conf_secs FM_TICKET_INTAKE_UNOWNED_PAGE_SECS 600)
FIRST_PROOF_SECS=$(conf_secs FM_TICKET_INTAKE_FIRST_PROOF_SECS 3600)
REMIND_SECS=$(conf_secs FM_TICKET_INTAKE_REMIND_SECS 1800)

# --- records ----------------------------------------------------------------

# One line, no control characters, no tabs, bounded, so a trigger text can never
# break a key=value record or a wake line.
sanitize_text() {
  local text=${1-}
  text=${text//$'\r'/ }
  text=${text//$'\n'/ }
  text=${text//$'\t'/ }
  text=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  if [ "${#text}" -gt "$MAX_TEXT" ]; then
    text="${text:0:$MAX_TEXT}..."
  fi
  printf '%s' "$text"
}

rand_token() {
  LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 6 || true
}

valid_key() {  # <value>: path-safe for a task id or trigger id
  local value=${1-}
  case "$value" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

rec_get() {  # <file> <key>
  local file=$1 key=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*)
        printf '%s' "${line#"$key"=}"
        return 0
        ;;
    esac
  done < "$file"
}

rec_write() {  # <file> <key=value>...
  local file=$1 dir tmp
  shift
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$dir/.rec.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$@" > "$tmp" || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

# Rewrite one key in place, keeping every other line and its order.
rec_set() {  # <file> <key> <value>
  local file=$1 key=$2 value=$3 dir tmp
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$dir/.rec.XXXXXX" 2>/dev/null) || return 1
  if ! {
    if [ -f "$file" ] && [ ! -L "$file" ]; then
      LC_ALL=C awk -v prefix="$key=" 'index($0, prefix) != 1 { print }' "$file"
    fi
    printf '%s=%s\n' "$key" "$value"
  } > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; return 1; }
}

trigger_path() { printf '%s/%s.trigger\n' "$TRIGGER_DIR" "$1"; }
ticket_path() { printf '%s/%s.ticket\n' "$TICKET_DIR" "$1"; }

all_triggers() {
  local file
  [ -d "$TRIGGER_DIR" ] || return 0
  for file in "$TRIGGER_DIR"/*.trigger; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done
}

all_tickets() {
  local file
  [ -d "$TICKET_DIR" ] || return 0
  for file in "$TICKET_DIR"/*.ticket; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done
}

# --- backlog reads ----------------------------------------------------------

# One read of the row states this home's backlog reports. Findings never page a
# ticket whose row is Done or held for the captain, so the sets are loaded once
# per command rather than once per ticket.
BACKLOG_STATE=unknown
DONE_IDS=' '
HELD_IDS=' '

id_set_add() {  # <done|held> <id>
  case "$1" in
    done) DONE_IDS="$DONE_IDS$2 " ;;
    held) HELD_IDS="$HELD_IDS$2 " ;;
  esac
}

id_in_set() {  # <id> <set>
  case "$2" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# One `tasks-axi list` carries every row's state in its header-named columns, so
# the two sets this command needs cost one call rather than one per row.
row_states_from_listing() {  # <tasks-axi list output>: "<id>\t<state>" per row
  LC_ALL=C awk -F, '
    /^tasks\[[0-9]+\]\{/ {
      header = $0
      sub(/^tasks\[[0-9]+\]\{/, "", header)
      sub(/\}.*$/, "", header)
      count = split(header, columns, ",")
      for (i = 1; i <= count; i++) {
        if (columns[i] == "state") { state_column = i }
      }
      next
    }
    /^  [A-Za-z0-9._-]+,/ {
      if (!state_column) { next }
      id = $1
      sub(/^ +/, "", id)
      state = $state_column
      gsub(/[ \t\r]/, "", state)
      if (id != "" && state != "") { print id "\t" state }
    }
  '
}

load_row_states() {
  local data out id state
  BACKLOG_STATE=unknown
  DONE_IDS=' '
  HELD_IDS=' '
  fm_tasks_axi_compatible || { BACKLOG_STATE=unavailable; return 1; }
  data=$(fm_backlog_data_absolute "$DATA") || { BACKLOG_STATE=unavailable; return 1; }
  out=$(fm_backlog_row_list "$data" 2>/dev/null) || { BACKLOG_STATE=unavailable; return 1; }
  while IFS=$'\t' read -r id state; do
    [ -n "$id" ] || continue
    case "$state" in
      done) id_set_add "done" "$id" ;;
      held) id_set_add "held" "$id" ;;
    esac
  done <<EOF
$(printf '%s\n' "$out" | row_states_from_listing)
EOF
  BACKLOG_STATE=ready
  return 0
}

tasks_axi_available() {
  fm_backlog_backend_manual "$CONFIG_DIR" && return 1
  fm_tasks_axi_compatible
}

# The same addressing convention bin/fm-backlog-transition-lib.sh owns for
# mutations: the markdown backend is addressed with its explicit backlog file,
# every other configured backend from the data directory's parent.
tasks_axi_run() {
  local data root file
  data=$(fm_backlog_data_absolute "$DATA") || die "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || die "backlog root cannot be resolved"
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    file=$(fm_backlog_file "$data") || die "backlog file cannot be resolved"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

row_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

row_scalar() {  # <show-output> <field>: unquoted, with tasks-axi's empty marker cleared
  local value
  value=$(row_field "$1" "$2")
  case "$value" in
    \"*\")
      value=$(printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      ' 2>/dev/null)
      ;;
  esac
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

ticket_state() {  # <task>: done|held|open|unknown
  case "$BACKLOG_STATE" in
    ready) ;;
    *)
      printf 'unknown'
      return 0
      ;;
  esac
  if id_in_set "$1" "$DONE_IDS"; then
    printf 'done'
  elif id_in_set "$1" "$HELD_IDS"; then
    printf 'held'
  else
    printf 'open'
  fi
}

# --- triggers ---------------------------------------------------------------

new_trigger() {  # <source> <thread> <class> <note> <text> [<via>]
  local source=$1 thread=$2 class=$3 note=$4 text=$5 via=${6:-} epoch id attempt
  epoch=$(now_epoch)
  attempt=0
  while :; do
    id="tr-$epoch-$(rand_token)"
    [ -n "${id#tr-"$epoch"-}" ] || id="tr-$epoch-$$$attempt"
    [ ! -e "$(trigger_path "$id")" ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 5 ] || die "could not allocate a trigger id"
  done
  rec_write "$(trigger_path "$id")" \
    "id=$id" \
    "at=$(iso_utc "$epoch")" \
    "at_epoch=$epoch" \
    "source=$source" \
    "via=$via" \
    "thread=$thread" \
    "class=$class" \
    "note=$note" \
    "text=$(sanitize_text "$text")" \
    'decision=' \
    'decision_at=' \
    'decision_epoch=' \
    'task=' \
    'reason=' || die "could not record the trigger"
  ensure_armed || true
  printf '%s\n' "$id"
}

require_trigger() {  # <trigger-id>
  valid_key "$1" || die "invalid trigger id: $1"
  [ -f "$(trigger_path "$1")" ] || die "no such trigger: $1"
}

cmd_trigger() {
  local source=chat thread='' class=captain note='' text='' text_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || die "--source needs a value"
        source=$2
        shift 2
        ;;
      --thread)
        [ "$#" -ge 2 ] || die "--thread needs a value"
        thread=$2
        shift 2
        ;;
      --class)
        [ "$#" -ge 2 ] || die "--class needs a value"
        class=$2
        shift 2
        ;;
      --note)
        [ "$#" -ge 2 ] || die "--note needs a value"
        note=$2
        shift 2
        ;;
      --text-file)
        [ "$#" -ge 2 ] || die "--text-file needs a value"
        text_file=$2
        shift 2
        ;;
      --text)
        [ "$#" -ge 2 ] || die "--text needs a value"
        text=$2
        shift 2
        ;;
      -h|--help) usage ;;
      -*) die "unknown flag: $1" ;;
      *)
        text="${text:+$text }$1"
        shift
        ;;
    esac
  done
  if [ "$text_file" = - ]; then
    text=$(cat)
  elif [ -n "$text_file" ]; then
    [ -f "$text_file" ] || die "text file does not exist: $text_file"
    text=$(cat "$text_file")
  fi
  case "$source" in
    ''|*[!A-Za-z0-9._-]*) die "invalid source: $source (letters, digits, dot, dash, underscore)" ;;
  esac
  [ -n "${text//[[:space:]]/}" ] || die "a trigger needs text: pass words, --text, or --text-file"
  [ -n "$thread" ] || thread="$source:$(now_epoch)"
  new_trigger "$source" "$thread" "$class" "$note" "$text"
}

cmd_close() {
  local id='' reason=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        [ "$#" -ge 2 ] || die "--reason needs a value"
        reason=$2
        shift 2
        ;;
      -h|--help) usage ;;
      -*) die "unknown flag: $1" ;;
      *)
        [ -z "$id" ] || die "close takes one trigger id"
        id=$1
        shift
        ;;
    esac
  done
  [ -n "$id" ] || die "close needs a trigger id"
  [ -n "$reason" ] || die "close needs --reason (why no ticket is needed)"
  require_trigger "$id"
  local file epoch
  file=$(trigger_path "$id")
  [ -z "$(rec_get "$file" decision)" ] || die "trigger $id is already decided"
  epoch=$(now_epoch)
  rec_set "$file" decision close
  rec_set "$file" decision_at "$(iso_utc "$epoch")"
  rec_set "$file" decision_epoch "$epoch"
  rec_set "$file" reason "$(sanitize_text "$reason")"
  printf 'closed: %s\n' "$id"
}

# --- tickets ----------------------------------------------------------------

status_log_lines() {  # <owner-task-id>
  local owner=$1 file lines
  [ -n "$owner" ] || { printf '0'; return 0; }
  file="$STATE/$owner.status"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    lines=$(LC_ALL=C awk 'END { print NR }' "$file" 2>/dev/null)
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    printf '%s' "$lines"
    return 0
  fi
  printf '0'
}

turn_ended_epoch() {  # <owner-task-id>
  local file
  file="$STATE/$1.turn-ended"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  stat_epoch "$file"
}

# The owner's first proof after it was given the ticket, read from durable
# records: a new status event, a turn-end marker that moved, or an explicit
# `proof`. Sets PROOF_BY to the evidence and prints its epoch.
PROOF_BY=''
PROOF_EPOCH=''
# Sets PROOF_EPOCH and PROOF_BY rather than printing, so the evidence survives
# the call: a command substitution would run this in a subshell and lose it.
first_proof_lookup() {  # <ticket-record-path>
  local file=$1 owner owner_epoch baseline current stamp
  PROOF_BY=''
  PROOF_EPOCH=''
  owner=$(rec_get "$file" owner)
  owner_epoch=$(rec_get "$file" owner_epoch)
  baseline=$(rec_get "$file" status_log_lines)
  case "$owner_epoch" in ''|*[!0-9]*) owner_epoch=0 ;; esac
  case "$baseline" in ''|*[!0-9]*) baseline=0 ;; esac
  if [ -n "$(rec_get "$file" proof_epoch)" ]; then
    PROOF_BY=$(rec_get "$file" proof_by)
    PROOF_EPOCH=$(rec_get "$file" proof_epoch)
    return 0
  fi
  [ -n "$owner" ] || return 1
  current=$(status_log_lines "$owner")
  if [ "$current" -gt "$baseline" ]; then
    PROOF_BY=status
    PROOF_EPOCH=$(stat_epoch "$STATE/$owner.status") || PROOF_EPOCH=''
    return 0
  fi
  if stamp=$(turn_ended_epoch "$owner") && [ "$stamp" -ge "$owner_epoch" ]; then
    PROOF_BY=turn-ended
    PROOF_EPOCH=$stamp
    return 0
  fi
  return 1
}


# Record the owner's clock: the moment it owes a first proof and the status-log
# baseline that proves it has since said something.
record_owner_clock() {  # <ticket-file> <owner>
  local file=$1 owner=$2 epoch baseline due
  epoch=$(now_epoch)
  baseline=$(status_log_lines "$owner")
  due=$((epoch + FIRST_PROOF_SECS))
  rec_set "$file" owner "$owner"
  rec_set "$file" owner_at "$(iso_utc "$epoch")"
  rec_set "$file" owner_epoch "$epoch"
  rec_set "$file" status_log_lines "$baseline"
  rec_set "$file" due_first_proof "$(iso_utc "$due")"
  rec_set "$file" due_epoch "$due"
  rec_set "$file" proof_at ''
  rec_set "$file" proof_epoch ''
  rec_set "$file" proof_by ''
}

new_ticket_record() {  # <task> <title> <trigger> <repo> <kind> <source> <thread> <class> <owner> [<arrival-epoch>]
  local task=$1 title=$2 trigger=$3 repo=$4 kind=$5 source=$6 thread=$7 class=$8 owner=$9
  local arrival=${10:-} file epoch due
  epoch=$(now_epoch)
  # The unowned bound measures from when the captain asked, not from when the
  # router got round to filing the ticket.
  case "$arrival" in ''|*[!0-9]*) arrival=$epoch ;; esac
  due=$((epoch + FIRST_PROOF_SECS))
  file=$(ticket_path "$task")
  rec_write "$file" \
    "task=$task" \
    "title=$(sanitize_text "$title")" \
    "trigger=$trigger" \
    "repo=$repo" \
    "kind=$kind" \
    "source=$source" \
    "thread=$thread" \
    "class=$class" \
    "owner=$owner" \
    'owner_at=' \
    'owner_epoch=' \
    "intake_at=$(iso_utc "$arrival")" \
    "intake_epoch=$arrival" \
    "due_first_proof=$(iso_utc "$due")" \
    "due_epoch=$due" \
    'status_log_lines=0' \
    'proof_at=' \
    'proof_epoch=' \
    'proof_by=' || die "could not record the ticket"
  if [ -n "$owner" ]; then
    record_owner_clock "$file" "$owner"
  fi
  printf '%s\n' "$file"
}

body_block() {  # <task> <trigger> <source> <thread> <class> <owner> <due-iso> <text>
  local task=$1 trigger=$2 source=$3 thread=$4 class=$5 owner=$6 due=$7 text=$8
  printf 'Captain ask: %s\n' "$text"
  printf 'Owner: %s\n' "${owner:-(unassigned)}"
  printf 'Thread: %s\n' "$thread"
  printf 'Source: %s\n' "$source"
  printf 'First proof due: %s\n' "$due"
  printf 'Trigger: %s\n' "$trigger"
  printf 'Ticket: %s\n' "$task"
}

cmd_new() {
  local trigger='' title='' owner='' repo='' kind=ship text=''
  local tfile source thread class ttext decision epoch due block out task
  local -a add_args
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title)
        [ "$#" -ge 2 ] || die "--title needs a value"
        title=$2
        shift 2
        ;;
      --owner)
        [ "$#" -ge 2 ] || die "--owner needs a value"
        owner=$2
        shift 2
        ;;
      --repo)
        [ "$#" -ge 2 ] || die "--repo needs a value"
        repo=$2
        shift 2
        ;;
      --kind)
        [ "$#" -ge 2 ] || die "--kind needs a value"
        kind=$2
        shift 2
        ;;
      -h|--help) usage ;;
      -*) die "unknown flag: $1" ;;
      *)
        if [ -z "$trigger" ]; then
          trigger=$1
        else
          text="${text:+$text }$1"
        fi
        shift
        ;;
    esac
  done
  [ -n "$trigger" ] || die "new needs a trigger id (record one with: fm-ticket-intake.sh trigger ...)"
  require_trigger "$trigger"
  tfile=$(trigger_path "$trigger")
  decision=$(rec_get "$tfile" decision)
  [ -z "$decision" ] || die "trigger $trigger is already decided ($decision)"
  source=$(rec_get "$tfile" source)
  thread=$(rec_get "$tfile" thread)
  class=$(rec_get "$tfile" class)
  ttext=$(rec_get "$tfile" text)
  [ -n "$text" ] || text=$ttext
  [ -n "$title" ] || title=$(sanitize_text "$text")
  [ -n "$title" ] || die "new needs --title, or a trigger with text to copy"
  if ! tasks_axi_available; then
    die "this home cannot create a row automatically (manual backlog backend or incompatible tasks-axi): add the $CAPTAIN_ASK_KIND row by hand, then run: bin/fm-ticket-intake.sh attach <task-id> --trigger $trigger --owner <worker>"
  fi
  epoch=$(now_epoch)
  due=$(iso_utc "$((epoch + FIRST_PROOF_SECS))")
  block=$(body_block 'PENDING' "$trigger" "$source" "$thread" "$class" "$owner" "$due" "$text")
  add_args=(add "$(sanitize_text "$title")" --kind "$CAPTAIN_ASK_KIND" --mint --prefix ask --body "$block" --json)
  [ -z "$repo" ] || add_args+=(--repo "$repo")
  out=$(tasks_axi_run "${add_args[@]}" 2>&1) \
    || die "tasks-axi add failed: $(printf '%s' "$out" | sed -n '1p')"
  task=$(printf '%s' "$out" | perl -MJSON::PP -e '
    local $/;
    my $doc = eval { decode_json(<STDIN>) };
    exit 1 unless ref($doc) eq "HASH";
    my $id = $doc->{task}{id};
    exit 1 unless defined $id && $id ne "";
    print $id;
  ' 2>/dev/null) || task=$(printf '%s\n' "$out" | sed -n 's/^  "id": "\([^"]*\)",$/\1/p' | head -1)
  valid_key "$task" || die "tasks-axi did not report a usable task id"
  block=$(body_block "$task" "$trigger" "$source" "$thread" "$class" "$owner" "$due" "$text")
  out=$(tasks_axi_run update "$task" --body "$block" 2>&1) \
    || die "the row $task was created but its captain-ask body could not be written: $(printf '%s' "$out" | sed -n '1p')"
  new_ticket_record "$task" "$title" "$trigger" "$repo" "$kind" "$source" "$thread" "$class" "$owner" \
    "$(rec_get "$tfile" at_epoch)" >/dev/null \
    || die "the row $task was created but its intake record could not be written"
  rec_set "$tfile" decision new
  rec_set "$tfile" decision_at "$(iso_utc "$epoch")"
  rec_set "$tfile" decision_epoch "$epoch"
  rec_set "$tfile" task "$task"
  printf '%s\n' "$task"
}

cmd_attach() {
  local task='' trigger='' owner='' title='' source='' thread='' class=''
  local tfile='' ttext='' row='' repo='' kind='' row_state='' epoch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --trigger)
        [ "$#" -ge 2 ] || die "--trigger needs a value"
        trigger=$2
        shift 2
        ;;
      --owner)
        [ "$#" -ge 2 ] || die "--owner needs a value"
        owner=$2
        shift 2
        ;;
      --title)
        [ "$#" -ge 2 ] || die "--title needs a value"
        title=$2
        shift 2
        ;;
      --source)
        [ "$#" -ge 2 ] || die "--source needs a value"
        source=$2
        shift 2
        ;;
      --thread)
        [ "$#" -ge 2 ] || die "--thread needs a value"
        thread=$2
        shift 2
        ;;
      --class)
        [ "$#" -ge 2 ] || die "--class needs a value"
        class=$2
        shift 2
        ;;
      -h|--help) usage ;;
      -*) die "unknown flag: $1" ;;
      *)
        [ -z "$task" ] || die "attach takes one task id"
        task=$1
        shift
        ;;
    esac
  done
  [ -n "$task" ] || die "attach needs a task id"
  valid_key "$task" || die "invalid task id: $task"
  [ ! -e "$(ticket_path "$task")" ] || die "task $task is already an intake ticket (change an owner with: owner $task <worker>)"
  if [ -n "$trigger" ]; then
    require_trigger "$trigger"
    tfile=$(trigger_path "$trigger")
    [ -z "$(rec_get "$tfile" decision)" ] || die "trigger $trigger is already decided"
    source=${source:-$(rec_get "$tfile" source)}
    thread=${thread:-$(rec_get "$tfile" thread)}
    class=${class:-$(rec_get "$tfile" class)}
    ttext=$(rec_get "$tfile" text)
  fi
  [ -n "$source" ] || source=chat
  [ -n "$thread" ] || thread="$source:$(now_epoch)"
  [ -n "$class" ] || class=captain
  if tasks_axi_available; then
    row=$(tasks_axi_run show "$task" 2>&1) \
      || die "no such backlog row: $task (record the row first, or pass its exact id)"
    row_state=$(row_field "$row" state)
    case "$row_state" in
      done|closed)
        if [ -n "$tfile" ]; then
          die "row $task is already $row_state; record the ask as answered instead: close $trigger --reason ..."
        fi
        die "row $task is already $row_state"
        ;;
    esac
    repo=$(row_scalar "$row" repo)
    kind=$(row_scalar "$row" kind)
    [ -n "$title" ] || title=$(row_scalar "$row" title)
  else
    warn "tasks-axi is unavailable here, so the row $task was not verified; recording the intake binding only"
  fi
  [ -n "$kind" ] || kind=ship
  [ -n "$title" ] || title=$(sanitize_text "$ttext")
  local arrival=''
  [ -z "$tfile" ] || arrival=$(rec_get "$tfile" at_epoch)
  new_ticket_record "$task" "$title" "$trigger" "$repo" "$kind" "$source" "$thread" "$class" "$owner" \
    "$arrival" >/dev/null \
    || die "could not record the ticket"
  if [ -n "$tfile" ]; then
    epoch=$(now_epoch)
    rec_set "$tfile" decision attach
    rec_set "$tfile" decision_at "$(iso_utc "$epoch")"
    rec_set "$tfile" decision_epoch "$epoch"
    rec_set "$tfile" task "$task"
  fi
  printf '%s\n' "$task"
}

cmd_owner() {
  local task='' owner='' file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage ;;
      -*) die "unknown flag: $1" ;;
      *)
        if [ -z "$task" ]; then task=$1; else owner=$1; fi
        shift
        ;;
    esac
  done
  [ -n "$task" ] && [ -n "$owner" ] || die "usage: owner <task-id> <worker>"
  valid_key "$task" || die "invalid task id: $task"
  valid_key "$owner" || die "invalid worker id: $owner"
  file=$(ticket_path "$task")
  [ -f "$file" ] || die "no intake ticket for $task (create one with: new <trigger> --title ..., or: attach $task)"
  record_owner_clock "$file" "$owner"
  printf '%s: owner %s, first proof due %s\n' "$task" "$owner" "$(rec_get "$file" due_first_proof)"
}

cmd_proof() {
  local task=${1-} file epoch
  valid_key "$task" || die "usage: proof <task-id>"
  file=$(ticket_path "$task")
  [ -f "$file" ] || die "no intake ticket for $task"
  [ -z "$(rec_get "$file" proof_epoch)" ] || { printf '%s: first proof already recorded\n' "$task"; return 0; }
  [ -n "$(rec_get "$file" owner)" ] || die "ticket $task has no owner yet"
  epoch=$(now_epoch)
  rec_set "$file" proof_at "$(iso_utc "$epoch")"
  rec_set "$file" proof_epoch "$epoch"
  rec_set "$file" proof_by manual
  printf '%s: first proof recorded\n' "$task"
}

# --- ledger -----------------------------------------------------------------

cmd_ledger() {
  local open_only=0
  local file task owner due at source thread state epoch stamp proof
  local latency tfile decided total=0 owned=0 unticketed=0 overdue=0 now due_epoch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --open) open_only=1; shift ;;
      -h|--help) usage ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  load_row_states || true
  now=$(now_epoch)
  printf '# Captain asks - generated from the intake records and tasks-axi\n\n'
  if [ "$BACKLOG_STATE" != ready ]; then
    printf 'Row state could not be read from tasks-axi (%s), so ticket state reads unknown.\n\n' "$BACKLOG_STATE"
  fi
  printf '| Ask | Arrived | Source | Thread | Decided | Owner | First proof due | First proof | Row state |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    task=$(rec_get "$file" task)
    state=$(ticket_state "$task")
    if [ "$open_only" = 1 ] && { [ "$state" = "done" ] || [ "$state" = "held" ]; }; then
      continue
    fi
    owner=$(rec_get "$file" owner)
    due=$(rec_get "$file" due_first_proof)
    at=$(rec_get "$file" intake_at)
    source=$(rec_get "$file" source)
    thread=$(rec_get "$file" thread)
    epoch=$(rec_get "$file" intake_epoch)
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    proof='none'
    if first_proof_lookup "$file"; then
      proof="$(iso_utc "$PROOF_EPOCH") ($PROOF_BY)"
    fi
    latency='-'
    tfile=''
    if [ -n "$(rec_get "$file" trigger)" ]; then
      tfile=$(trigger_path "$(rec_get "$file" trigger)")
      decided=$(rec_get "$tfile" decision_epoch)
      case "$decided" in
        ''|*[!0-9]*) decided='' ;;
      esac
      [ -z "$decided" ] || latency="+$(human_duration "$((decided - epoch))")"
    fi
    # shellcheck disable=SC2016  # backticks are literal markdown, not a command
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$task" "${at:-'-'}" "${source:-'-'}" "${thread:-'-'}" "$latency" \
      "${owner:-'-'}" "${due:-'-'}" "$proof" "$state"
    total=$((total + 1))
    if [ -z "$owner" ]; then
      unticketed=$((unticketed + 1))
      continue
    fi
    owned=$((owned + 1))
    due_epoch=$(rec_get "$file" due_epoch)
    case "$due_epoch" in ''|*[!0-9]*) due_epoch=0 ;; esac
    if [ "$proof" = none ] && [ "$state" = open ] && [ "$now" -ge "$due_epoch" ]; then
      overdue=$((overdue + 1))
    fi
  done <<EOF
$(all_tickets)
EOF
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -z "$(rec_get "$file" task)" ] || continue
    tfile=$(rec_get "$file" id)
    state=$(rec_get "$file" decision)
    if [ "$open_only" = 1 ] && [ -n "$state" ]; then
      continue
    fi
    # shellcheck disable=SC2016  # backticks are literal markdown, not a command
    printf '| trigger `%s`: %s | %s | %s | %s | %s | - | - | - | %s |\n' \
      "$tfile" "$(rec_get "$file" text)" "$(rec_get "$file" at)" \
      "$(rec_get "$file" source)" "$(rec_get "$file" thread)" \
      "$( [ -n "$state" ] && printf 'answered: %s' "$(rec_get "$file" reason)" || printf -- '-')" \
      "$( [ -n "$state" ] && printf 'answered' || printf 'no ticket')"
    total=$((total + 1))
    [ -n "$state" ] || unticketed=$((unticketed + 1))
  done <<EOF
$(all_triggers)
EOF
  printf '\ncoverage: %s captain ask(s), %s owned, %s without an owning ticket, %s past first-proof due\n' \
    "$total" "$owned" "$unticketed" "$overdue"
}

cmd_status() {
  local file owner due state now open=0 unowned=0 overdue=0 pending=0
  now=$(now_epoch)
  load_row_states || true
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    state=$(ticket_state "$(rec_get "$file" task)")
    [ "$state" = "done" ] && continue
    open=$((open + 1))
    owner=$(rec_get "$file" owner)
    if [ -z "$owner" ]; then
      unowned=$((unowned + 1))
      continue
    fi
    due=$(rec_get "$file" due_epoch)
    case "$due" in ''|*[!0-9]*) due=0 ;; esac
    if ! first_proof_lookup "$file" && [ "$now" -ge "$due" ]; then
      overdue=$((overdue + 1))
    fi
  done <<EOF
$(all_tickets)
EOF
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -z "$(rec_get "$file" decision)" ] || continue
    unowned=$((unowned + 1))
  done <<EOF
$(all_triggers)
EOF
  if [ -d "$INBOX" ]; then
    pending=$(find "$INBOX" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  fi
  printf 'intake   %s open ticket(s), %s ask(s) without an owner, %s past first-proof due\n' \
    "$open" "$unowned" "$overdue"
  printf 'inbox    %s note(s) awaiting import into a trigger\n' "$pending"
  if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'check    armed\n'
  else
    printf 'check    not armed (bin/fm-ticket-intake.sh arm)\n'
  fi
}

# --- the bound --------------------------------------------------------------

# Pending captain notes become Triggers so an ask that arrives while firstmate is
# mid-turn is still inside the bound. Automated notes are skipped: they are not
# captain asks and must never create an owner obligation on the captain's behalf.
import_pending_notes() {
  local seen='' file note_id body at stamp source
  [ -d "$INBOX" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    seen="$seen$(rec_get "$file" note) "
  done <<EOF
$(all_triggers)
EOF
  for file in "$INBOX"/*.note; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    note_id=$(basename "$file" .note)
    valid_key "$note_id" || continue
    case "$seen" in
      *" $note_id "*) continue ;;
    esac
    body=$(cat "$file" 2>/dev/null) || continue
    at=$(printf '%s\n' "$body" | sed -n 's/^at=//p' | head -1)
    source=$(printf '%s\n' "$body" | sed -n 's/^source=//p' | head -1)
    body=$(printf '%s\n' "$body" | sed -n '/^--$/,$p' | sed '1d')
    [ -n "${body//[[:space:]]/}" ] || continue
    if printf '%s' "$body" | grep -Fqi -- "$AUTOMATED_MARKER"; then
      seen="$seen$note_id "
      continue
    fi
    stamp=$(epoch_from_iso "$at" 2>/dev/null) || stamp=''
    [ -n "$stamp" ] || stamp=$(now_epoch)
    case "$source" in
      ''|*[!A-Za-z0-9._-]*) source=inbox ;;
    esac
    FM_TICKET_INTAKE_NOW=$stamp new_trigger "$source" "inbox:$note_id" captain "$note_id" "$body" inbox \
      >/dev/null 2>&1 || continue
    seen="$seen$note_id "
  done
  return 0
}

# Print "<key>\t<kind>\t<detail>" for every condition holding right now.
current_findings() {
  local now file id task owner epoch due_epoch state
  now=$(now_epoch)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -z "$(rec_get "$file" decision)" ] || continue
    epoch=$(rec_get "$file" at_epoch)
    case "$epoch" in ''|*[!0-9]*) epoch=$now ;; esac
    [ "$((now - epoch))" -ge "$UNOWNED_PAGE_SECS" ] || continue
    id=$(rec_get "$file" id)
    printf 'trigger-unowned:%s\tunowned ask\ttrigger %s from %s (%s) has had no ticket or owner for %s: %s - route it: bin/fm-ticket-intake.sh new %s --title ... | attach <task> --trigger %s | close %s --reason ...\n' \
      "$id" "$id" "$(rec_get "$file" source)" "$(rec_get "$file" thread)" \
      "$(human_duration "$((now - epoch))")" "$(rec_get "$file" text)" "$id" "$id" "$id"
  done <<EOF
$(all_triggers)
EOF
  # A backlog state this home cannot read makes every ticket bound blind, and a
  # silent bound is worse than a paged one, so that blindness is its own finding.
  if [ "$BACKLOG_STATE" != ready ] && [ -n "$(all_tickets)" ]; then
    printf 'intake-blind\tintake cannot read row state\tticket bounds are not being evaluated: %s - check tasks-axi here: bin/fm-ticket-intake.sh status\n' \
      "$BACKLOG_STATE"
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    task=$(rec_get "$file" task)
    state=$(ticket_state "$task")
    [ "$state" = open ] || continue
    owner=$(rec_get "$file" owner)
    epoch=$(rec_get "$file" intake_epoch)
    case "$epoch" in ''|*[!0-9]*) epoch=$now ;; esac
    if [ -z "$owner" ]; then
      [ "$((now - epoch))" -ge "$UNOWNED_PAGE_SECS" ] || continue
      printf 'ticket-unowned:%s\tunowned ticket\tticket %s ("%s") has had no owner for %s - assign one: bin/fm-ticket-intake.sh owner %s <worker>\n' \
        "$task" "$task" "$(rec_get "$file" title)" \
        "$(human_duration "$((now - epoch))")" "$task"
      continue
    fi
    due_epoch=$(rec_get "$file" due_epoch)
    case "$due_epoch" in ''|*[!0-9]*) due_epoch=0 ;; esac
    [ "$now" -ge "$due_epoch" ] || continue
    first_proof_lookup "$file" && continue
    printf 'ticket-proof:%s\tno first proof\tticket %s ("%s") owner %s owes a first proof since %s, %s late - reassign or unblock it: bin/fm-ticket-intake.sh owner %s <worker>\n' \
      "$task" "$task" "$(rec_get "$file" title)" "$owner" \
      "$(rec_get "$file" due_first_proof)" \
      "$(human_duration "$((now - due_epoch))")" "$task"
  done <<EOF
$(all_tickets)
EOF
}

cmd_check() {
  local now work new old first last key kind detail stamp out
  import_pending_notes || true
  load_row_states || true
  now=$(now_epoch)
  work=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/.fm-ticket-intake.XXXXXX" 2>/dev/null) \
    || die "cannot stage the findings"
  # shellcheck disable=SC2064  # work is resolved already; the trap must see this path.
  trap "rm -rf -- '$work'" EXIT HUP INT TERM
  new="$work/now"
  old="$work/before"
  out="$work/lines"
  current_findings | LC_ALL=C sort > "$new" || true
  if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
    LC_ALL=C awk -F'\t' '$1 == "finding" { print $2 "\t" $3 "\t" $4 }' "$RECORD" \
      | LC_ALL=C sort > "$old" || true
  else
    : > "$old"
  fi
  : > "$out"
  : > "$work/kept"
  printf 'schema=%s\n' "$RECORD_SCHEMA" > "$work/record"
  while IFS=$'\t' read -r key kind detail; do
    [ -n "$key" ] || continue
    first=$(LC_ALL=C awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$old")
    last=$(LC_ALL=C awk -F'\t' -v k="$key" '$1 == k { print $3; exit }' "$old")
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ -z "$first" ]; then
      first=$now
      last=$now
      printf 'ticket-intake: %s: %s\n' "$kind" "$detail" >> "$out"
    elif [ "$((now - last))" -ge "$REMIND_SECS" ]; then
      last=$now
      printf 'ticket-intake: %s still open after %s: %s\n' \
        "$kind" "$(human_duration "$((now - first))")" "$detail" >> "$out"
    fi
    printf 'finding\t%s\t%s\t%s\n' "$key" "$first" "$last" >> "$work/kept"
  done < "$new"
  while IFS=$'\t' read -r key first last; do
    [ -n "$key" ] || continue
    LC_ALL=C awk -F'\t' -v k="$key" '$1 == k { found = 1 } END { exit found ? 0 : 1 }' "$new" \
      && continue
    printf 'ticket-intake: recovered: %s closed after %s\n' \
      "$key" "$(human_duration "$((now - first))")" >> "$out"
  done < "$old"
  cat "$work/kept" >> "$work/record"
  if [ -s "$out" ]; then
    while IFS= read -r stamp; do
      [ -n "$stamp" ] || continue
      fm_cap_line "$stamp" "$MAX_LINE"
    done < "$out"
  fi
  chmod 0600 "$work/record" 2>/dev/null || true
  mv -f -- "$work/record" "$RECORD" || die "could not record the findings"
  trap - EXIT HUP INT TERM
  rm -rf -- "$work"
  return 0
}

# --- arming -----------------------------------------------------------------

# A recorded Trigger or ticket arms the bound when this home is not armed yet,
# because a bound nobody measures is not a bound. Any failure is reported and
# never loses the record.
ensure_armed() {
  fm_custom_check_registered "$STATE" "$CHECK_ID" && return 0
  if ! action_arm >/dev/null 2>&1; then
    warn "could not arm the intake bound; run bin/fm-ticket-intake.sh arm"
    return 1
  fi
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {  # <home>
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-ticket-intake.sh - captain ask intake bound poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-ticket-intake.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || die "the state directory is unavailable: $STATE"
  home=$(fm_custom_check_resolve_home "$FM_HOME") \
    || die "cannot resolve FM_HOME $FM_HOME"
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-ticket-intake \
    fm-ticket-intake "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$RECORD"
}

case "${1:-}" in
  trigger) shift; cmd_trigger "$@" ;;
  new) shift; cmd_new "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  owner) shift; cmd_owner "$@" ;;
  proof) shift; cmd_proof "$@" ;;
  close) shift; cmd_close "$@" ;;
  ledger) shift; cmd_ledger "$@" ;;
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  arm) shift; action_arm ;;
  disarm) shift; action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

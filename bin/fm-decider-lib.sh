#!/usr/bin/env bash
# fm-decider-lib.sh - the standing-order vocabulary and routing ledger for the
# persistent Decider seat (docs/decider-worker.md owns the seat's charter).
#
# A worker's `needs-decision [key=<key>]: <summary>` line is a decision the
# supervisor used to answer in its own turn. This library decides, from the key
# and its note alone, whether an open decision belongs to a standing-order class
# the Decider seat may rule on, or to class (a) - money, a legal signature, the
# captain's own logins or clicks, or anything irreversible - which only the
# captain answers. It also owns the routing ledger that records every episode it
# saw, so a decision is asked about once and the weekly measurement has durable
# facts to count (bin/fm-decider-metrics.sh).
#
# ONE owner of the class vocabulary: the class tokens below are the only names,
# and fm_decider_is_standing_order is the only test other scripts use to tell a
# seat class from the captain's. docs/decider-worker.md states the same table
# for an operator; it points here rather than restating the patterns.
#
# Classifier discipline. The classifier must never hand the seat something the
# captain owns: an unmatched key stays with the captain's own routing view
# (`unclassified`), which is the safe direction, and class (a) wins over every
# standing order EXCEPT the one deliberately bounded money carve-out - a refund
# whose stated amount is under the cap. Patterns are therefore positive evidence
# for a specific standing order, never a default.
#
# Classification reads `<key> <note>` lowercased and punctuation-split, so
# `sign-off`, `sign off`, and `signoff` all read the same way and a hyphenated
# key cannot slip past a word match. The spending gate reads the ORIGINAL text's
# explicit `$<amount>` figures; a bare "refund" with no stated amount, an
# amount at or above the cap, or any unreadable figure is money, so class (a).
#
# Keyed decisions whose key carries a reserved namespace belong to the library
# that raised them (bin/fm-classify-lib.sh's reserved-key rule), never to a
# standing order: a pending-reply escalation is a secondmate waiting on the
# parent, which is a captain-facing routing question.
#
# Nothing here writes to a status log, a backend, or a project: this library is
# pure reads plus, in the ledger helpers, appends to this home's own state file.
set -u

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-classify-lib.sh"

# The captain's own class (a) bucket, and the bucket for a key no standing order
# claims. Neither is ever routed to the Decider seat.
FM_DECIDER_CLASS_CAPTAIN='captain'
FM_DECIDER_CLASS_UNCLASSIFIED='unclassified'

# Standing-order classes, most specific first. The order is the classifier's
# match order, so a note that could read as two classes resolves to the earlier
# one; keep additive-ddl ahead of copy so "add a column" copy edits stay DDL.
# refund-under-150 is the single money carve-out: it is deliberately the first
# match so a small refund is routed, while class (a) keeps every other money
# decision.
FM_DECIDER_STANDING_ORDERS='refund-under-150 additive-ddl copy-fable-delegated reversible-hide user-safe-v4-flip merge-on-go'

# The one bounded money carve-out: a refund or credit whose stated amount is
# strictly below this many dollars may be ruled on. Everything else money-
# shaped - no stated amount, a larger amount, an unreadable figure - is class
# (a). Raise this only through the captain's own standing order.
FM_DECIDER_REFUND_CAP_DEFAULT=150

# The DoD window: a routed key must be ruled inside this many seconds.
FM_DECIDER_RULING_WINDOW_DEFAULT=7200

fm_decider_refund_cap() {
  case "${FM_DECIDER_REFUND_CAP:-}" in
    ''|*[!0-9]*) printf '%s' "$FM_DECIDER_REFUND_CAP_DEFAULT" ;;
    *) printf '%s' "${FM_DECIDER_REFUND_CAP}" ;;
  esac
}

fm_decider_ruling_window() {
  case "${FM_DECIDER_RULING_WINDOW:-}" in
    ''|*[!0-9]*) printf '%s' "$FM_DECIDER_RULING_WINDOW_DEFAULT" ;;
    *) printf '%s' "${FM_DECIDER_RULING_WINDOW}" ;;
  esac
}

fm_decider_standing_orders() {
  # One class per line for callers that iterate; the split is the point.
  # shellcheck disable=SC2086
  printf '%s\n' $FM_DECIDER_STANDING_ORDERS
}

# 0 when <class> is a standing-order class the seat may rule on.
fm_decider_is_standing_order() {  # <class>
  case " $FM_DECIDER_STANDING_ORDERS " in
    *" $1 "*) [ -n "$1" ] && return 0 ;;
  esac
  return 1
}

# 0 when <class> is the captain's class (a) bucket.
fm_decider_is_captain_class() {  # <class>
  [ "${1:-}" = "$FM_DECIDER_CLASS_CAPTAIN" ]
}

# --- the seat's identity (config/decider-task) ------------------------------
#
# The seat is a persistent worker in THIS home, and it answers through fm-send's
# --resolve-key against this home's own ledger, so its task id is local
# configuration rather than shared tracked state.
# FM_DECIDER_CONFIG_OVERRIDE / FM_DECIDER_TASK are the test seams; an explicit
# FM_DECIDER_TASK wins over the file.

fm_decider_task_config_path() {
  printf '%s/decider-task' "${FM_DECIDER_CONFIG_OVERRIDE:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}"
}

_fm_decider_task_id_valid() {  # <id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .*|-*|_*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# Print the configured seat task id, or nothing when no seat is configured.
# A configured id that is not a safe task id prints nothing and sets
# FM_DECIDER_TASK_ERROR so the caller can report the misconfiguration instead of
# silently routing nowhere (read by sourcing callers, never used here).
# shellcheck disable=SC2034
FM_DECIDER_TASK_ERROR=
fm_decider_task_id() {
  local file line id=''
  # shellcheck disable=SC2034 # Output read by sourcing callers after the call.
  FM_DECIDER_TASK_ERROR=
  if [ -n "${FM_DECIDER_TASK:-}" ]; then
    _fm_decider_task_id_valid "$FM_DECIDER_TASK" \
      || { FM_DECIDER_TASK_ERROR="FM_DECIDER_TASK is not a usable task id"; return 0; }
    printf '%s' "$FM_DECIDER_TASK"
    return 0
  fi
  file=$(fm_decider_task_config_path)
  [ -e "$file" ] || return 0
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_DECIDER_TASK_ERROR="$file is not a readable regular file"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    id=$line
    break
  done < "$file"
  [ -n "$id" ] || return 0
  if ! _fm_decider_task_id_valid "$id"; then
    # shellcheck disable=SC2034 # Output read by sourcing callers after the call.
    FM_DECIDER_TASK_ERROR="$file does not hold a usable task id"
    return 0
  fi
  printf '%s' "$id"
}

# --- the classifier --------------------------------------------------------
#
# The no-fork core behind fm_decider_classify: it assigns the class to
# _FM_DECIDER_CLASS instead of printing, so a fleet-sized loop pays one
# punctuation split per decision rather than a subshell per decision.
_FM_DECIDER_CLASS=
_FM_DECIDER_WORDS=

_fm_decider_normalize() {  # <text> -> _FM_DECIDER_WORDS
  _FM_DECIDER_WORDS=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9' ' ')
}

# 0 when <words> (the normalized text, space-delimited) contains every word in
# <needed...> as a whole word. Repeated phrases are passed as their own words,
# which is why normalization splits punctuation: "sign-off" is "sign off".
_fm_decider_has_words() {  # <words> <needed...>
  local words=$1 need
  shift
  for need in "$@"; do
    case " $words " in
      *" $need "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# 0 when <words> contains ANY of the remaining words.
_fm_decider_has_any() {  # <words> <candidate...>
  local words=$1 word
  shift
  for word in "$@"; do
    case " $words " in
      *" $word "*) return 0 ;;
    esac
  done
  return 1
}

# 0 when the text states at least one `$<amount>` figure and every stated figure
# is strictly below the cap. Reads the ORIGINAL text, never the word-split form.
_fm_decider_bounded_money() {  # <text>
  local text=$1 amounts amount cap saw=0
  cap=$(fm_decider_refund_cap)
  amounts=$(printf '%s\n' "$text" | grep -oE '\$[0-9]+(\.[0-9]+)?' 2>/dev/null) || return 1
  [ -n "$amounts" ] || return 1
  while IFS= read -r amount; do
    [ -n "$amount" ] || continue
    saw=1
    amount=${amount#\$}
    case "$amount" in
      *.*) amount=${amount%%.*} ;;
    esac
    case "$amount" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#amount}" -le 9 ] || return 1
    [ "$amount" -lt "$cap" ] || return 1
  done <<EOF
$amounts
EOF
  [ "$saw" = 1 ]
}

# Class (a). Deliberately broad: a false positive hands the decision to the
# captain, which is the safe direction, while a false negative would let the
# seat rule on money, a signature, the captain's own credentials or clicks, or
# something irreversible.
_fm_decider_is_class_a() {  # <words>
  # Money: any spend, price, billing, or refund-shaped word. The bounded refund
  # carve-out is decided before this test, so this arm is the unbounded case.
  _fm_decider_has_any "$1" \
    money monies spend spends spending cost costs price prices pricing budget \
    refund refunds credit credits invoice invoices paid pay payment payments \
    charge charges billing stripe subscription subscriptions usd eur dollars \
    revenue profitability royalty royalties \
    && return 0
  _fm_decider_has_words "$1" revenue share && return 0
  # Legal signature.
  _fm_decider_has_any "$1" \
    legal legally sign signs signed signing signature signatures contract \
    contracts terms dpa nda sla agreement liable liability lawyer counsel \
    attorney \
    && return 0
  # The captain's own logins and clicks.
  _fm_decider_has_any "$1" \
    login logins password passwords credential credentials secret secrets \
    token tokens 2fa mfa sso otp \
    console consoles portal portals dashboard dashboards \
    click clicks browser captain \
    && return 0
  _fm_decider_has_words "$1" api key && return 0
  _fm_decider_has_words "$1" api keys && return 0
  _fm_decider_has_words "$1" app store && return 0
  _fm_decider_has_words "$1" sign in && return 0
  _fm_decider_has_words "$1" log in && return 0
  _fm_decider_has_words "$1" play console && return 0
  _fm_decider_has_words "$1" apple developer && return 0
  _fm_decider_has_words "$1" google play && return 0
  _fm_decider_has_words "$1" vendor account && return 0
  # Anything irreversible or destructive.
  _fm_decider_has_any "$1" \
    irreversible destroy destroys destroyed delete deletes deletion purge purges \
    truncate truncates revoke revokes revoked terminate terminated decommission \
    decommissioned rotate rotates rotated rotation \
    && return 0
  _fm_decider_has_words "$1" drop table && return 0
  _fm_decider_has_words "$1" drop column && return 0
  _fm_decider_has_words "$1" hard delete && return 0
  _fm_decider_has_words "$1" force push && return 0
  return 1
}

# 0 when the decision is the one bounded money carve-out: a refund/credit with
# every stated figure below the cap.
_fm_decider_is_bounded_refund() {  # <words> <text>
  _fm_decider_has_any "$1" refund refunds credit credits || return 1
  _fm_decider_bounded_money "$2"
}

_fm_decider_is_additive_ddl() {  # <words>
  _fm_decider_has_any "$1" ddl migration migrations schema schemas column columns index indexes \
    || return 1
  _fm_decider_has_any "$1" additive add adds adding added create creates nullable non-destructive reversible \
    || return 1
  return 0
}

_fm_decider_is_delegated_copy() {  # <words>
  _fm_decider_has_any "$1" copy copywriting wording text texts email emails subject message messages notification notifications \
    || return 1
  _fm_decider_has_any "$1" fable delegated approved preapproved \
    || return 1
  return 0
}

_fm_decider_is_reversible_hide() {  # <words>
  _fm_decider_has_any "$1" hide hides hiding flag flags flagging toggle toggles disable disables disabling mask \
    || return 1
  _fm_decider_has_any "$1" reversible revert reverts rollback feature flagged behind \
    || return 1
  return 0
}

_fm_decider_is_v4_flip() {  # <words>
  _fm_decider_has_words "$1" v4 || return 1
  _fm_decider_has_any "$1" flip flips switch switches enable enables rollout \
    || return 1
  _fm_decider_has_any "$1" safe safer user-safe
  return 0
}

_fm_decider_is_merge_on_go() {  # <words>
  _fm_decider_has_any "$1" merge merges merging merged \
    || return 1
  _fm_decider_has_any "$1" go go-ahead approval approved approve signoff sign-off agree agreed \
    || return 1
  return 0
}

# Classify one open decision. <key> is the decision key (never empty; a keyless
# line folds to "default" upstream) and <note> is its folded summary.
fm_decider_classify_core() {  # <key> <note> -> _FM_DECIDER_CLASS
  local key=$1 note=$2 text prefix
  _FM_DECIDER_CLASS=$FM_DECIDER_CLASS_UNCLASSIFIED
  _FM_DECIDER_WORDS=
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _FM_DECIDER_CLASS=$FM_DECIDER_CLASS_CAPTAIN
        return 0
        ;;
    esac
  done
  text=$(printf '%s' "$key $note" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  _fm_decider_normalize "$text"
  if _fm_decider_is_bounded_refund "$_FM_DECIDER_WORDS" "$text"; then
    _FM_DECIDER_CLASS='refund-under-150'
    return 0
  fi
  if _fm_decider_is_class_a "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS=$FM_DECIDER_CLASS_CAPTAIN
    return 0
  fi
  if _fm_decider_is_additive_ddl "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS='additive-ddl'
    return 0
  fi
  if _fm_decider_is_delegated_copy "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS='copy-fable-delegated'
    return 0
  fi
  if _fm_decider_is_reversible_hide "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS='reversible-hide'
    return 0
  fi
  if _fm_decider_is_v4_flip "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS='user-safe-v4-flip'
    return 0
  fi
  if _fm_decider_is_merge_on_go "$_FM_DECIDER_WORDS"; then
    _FM_DECIDER_CLASS='merge-on-go'
    return 0
  fi
  return 0
}

# Print the class for one decision.
fm_decider_classify() {  # <key> <note>
  fm_decider_classify_core "$1" "${2:-}"
  printf '%s' "$_FM_DECIDER_CLASS"
}

# --- the routing ledger (state/decider-ledger.tsv) -------------------------
#
# Append-only, tab-separated, one record per line:
#   <kind> <first_seen> <task> <key> <class> <epoch>
# <kind> is
#   O  an episode opened (the key was first observed open at <epoch>)
#   A  the seat was asked for a ruling at <epoch>
#   R  the seat ruled through fm-decider-route.sh answer at <epoch>
#   C  the episode closed at <epoch> (observed by a sweep, or the task's log
#      left the fleet)
#   E  the DoD window expired unruled at <epoch> (surfaced once per episode)
# <first_seen> is the episode's own identity, so a key that closes and later
# reopens is a NEW episode with its own record trail and its own ruling clock.
# Appends are single short lines to an O_APPEND file, which is atomic enough for
# the two writers this file has (the sweep under its own lock, and one seat turn
# answering one key).
#
# This ledger is a private home record, never a decision authority: whether a key
# is still open is answered only by bin/fm-classify-lib.sh's status fold.

fm_decider_ledger_path() {  # <state>
  printf '%s/decider-ledger.tsv' "$1"
}

fm_decider_ledger_append() {  # <ledger> <kind> <first_seen> <task> <key> <class> <epoch>
  local ledger=$1 kind=$2 first=$3 task=$4 key=$5 class=$6 epoch=$7
  case "$kind" in O|A|R|C|E) ;; *) return 1 ;; esac
  case "$first$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$task" ] && [ -n "$key" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$first" "$task" "$key" "${class:--}" "$epoch" >> "$ledger"
}

# The epoch a sweep action applies to. FM_DECIDER_NOW is the test seam; the real
# writer always uses the wall clock so the ruling window measures real time.
fm_decider_now() {
  case "${FM_DECIDER_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s' "$FM_DECIDER_NOW" ;;
  esac
}

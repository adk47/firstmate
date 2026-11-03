#!/usr/bin/env bash
# fm-merge-queue.sh - land queued, already-verified pull requests on a timer,
# with no agent turn in the loop.
#
# WHY THIS EXISTS. A pull request that is green, QA-passed, and merge-ready
# still waits for a firstmate turn today, because the merge queue is a
# hand-written file and its batch script is run by hand. Every such merge
# therefore costs a routing turn serialized behind the rest of the fleet. This
# script is the same batch on a timer: a systemd timer runs `run` every ten
# minutes, and a queued pull request lands without anyone being woken.
#
# THE QUEUE FILE. One row per pull request, whitespace separated:
#
#   <repo> <number> <expected-head> <task-id> <squash|merge|rebase>
#
# <repo>      "owner/repo", or a bare repository name, which then uses the owner
#             named by a "# owner: <login>" directive in the same file, or
#             FM_MERGE_QUEUE_OWNER.
# <number>    the pull request number.
# <expected-head>
#             the head commit the row was written against, at least 7 hex
#             characters. A head that moved retires the row instead of merging
#             a commit nobody queued.
# <task-id>   the firstmate task this merge is recorded against, so the merge
#             metadata and the landed-work check keep working.
# <method>    the merge method handed to the forge.
#
# Comment (#) and blank lines are preserved exactly as they are written.
# Default queue: <FM_HOME>/data/go-queue.txt. With no queue file this home has
# not opted in, and `run` does nothing at all.
#
# A ROW LEAVES THE QUEUE ONLY ON A TERMINAL VERDICT: merged, already merged,
# closed, fenced, a moved head, or FM_MERGE_QUEUE_MAX_ATTEMPTS consecutive
# refused merge attempts (default 6). A row that is merely not ready - checks
# not green, the QA review not posted on this head, or the forge unreadable -
# stays queued and is retried on the next tick, and so does a row this home
# cannot read at all (no repository owner, an unknown merge method, too many
# fields): a configuration mistake must never delete the queue it was given, so
# such a row is kept and the daily line reports how many rows need the file
# fixed. Every row is read live on every tick; nothing in the queue file is
# trusted as current, and a repository that appears twice in one tick is
# attempted once.
#
# WHAT KEEPS IT SAFE. The merge is always bin/fm-pr-merge.sh, so that script's
# own refusal rules, merge verification, metadata recording, and durable wake
# still apply; this script only decides what to hand it. It never merges a red
# head, a draft, a head the row did not name, or a change whose labels carry
# FENCE_WORDS (money, secrets, Cloudflare, customer copy, irreversible), and it
# fences a title or body that names additive DDL. Those stay with a decider
# rather than an unattended timer. FM_MERGE_QUEUE_QA=optional waives the
# qa-review requirement for a home whose repositories run no QA workflow; the
# default requires a passing qa-review check on the exact head.
#
# RECORDS, all under <FM_HOME>/state/merge-queue/:
#   ledger.tsv   one line per verdict: <epoch> <key> <verdict> <reason>
#   last-run     the verdict counts of the most recent run
#   .summary     the day of the last daily line and the epoch it covered from
#   .lock/       single-instance lock, so two ticks never merge at once
#
# THE DAILY LINE. The first run of each UTC day appends ONE durable check wake
# summarizing what landed and what was retired since the previous one, so the
# queue is one line a day in firstmate's chat instead of a wake per merge. No
# run pages anyone directly: every other verdict is a journal line.
#
# INSTALL, once per home, from the home's code root:
#   printf '# owner: <github-login>\n' | cat - data/go-queue.txt > /tmp/q \
#     && mv /tmp/q data/go-queue.txt            # only for bare repository rows
#   mkdir -p ~/.config/systemd/user
#   bin/fm-merge-queue.sh unit service > ~/.config/systemd/user/fm-merge-queue.service
#   bin/fm-merge-queue.sh unit timer   > ~/.config/systemd/user/fm-merge-queue.timer
#   systemctl --user daemon-reload
#   systemctl --user enable --now fm-merge-queue.timer
# `bin/fm-merge-queue.sh run --dry-run` prints the decisions the timer would
# make without changing anything, which is the way to check a new queue file.
#
# Usage:
#   fm-merge-queue.sh run [--queue <file>] [--dry-run]
#   fm-merge-queue.sh status [--queue <file>]
#   fm-merge-queue.sh unit service|timer
#   fm-merge-queue.sh --help
#
# run     Process the queue once: read each row, decide, merge what is ready,
#         retire what is terminal, and emit the daily line when its day turns.
#         --dry-run prints the same decisions and changes no queue row, ledger
#         line, or summary record, and merges nothing.
# status  Print the queue size and the most recent run from records only. No
#         network call at all.
# unit    Print one systemd unit file for this home, ready to redirect into
#         ~/.config/systemd/user/.
#
# Environment:
#   FM_HOME                  operational home whose state/ and data/ are used.
#   FM_MERGE_QUEUE           queue file path.
#   FM_MERGE_QUEUE_OWNER     GitHub owner for bare repository rows, overriding
#                            the queue file's own "# owner:" directive.
#   FM_MERGE_QUEUE_QA        "optional" waives the qa-review requirement.
#   FM_MERGE_QUEUE_MAX_ATTEMPTS
#                            consecutive failed merge attempts before a row is
#                            retired (default 6).
#
# Exit status is 0 for a completed run whatever the individual verdicts were,
# because nothing about one unready pull request is a failure of the timer. It
# is non-zero only when the run itself could not proceed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

RECORDS="$STATE/merge-queue"
LEDGER="$RECORDS/ledger.tsv"
LAST_RUN="$RECORDS/last-run"
SUMMARY_RECORD="$RECORDS/.summary"
LOCK_DIR="$RECORDS/.lock"

MERGE_CMD="$FM_ROOT/bin/fm-pr-merge.sh"
DEFAULT_QUEUE="$FM_HOME/data/go-queue.txt"

# Merge methods the forge accepts through bin/fm-pr-merge.sh.
METHODS="squash merge rebase"

# Labels that keep a change away from an unattended merge: these name money,
# credentials, vendor consoles, customer-facing copy, or work that cannot be
# undone, and each one belongs to a decider.
FENCE_WORDS="prod-ddl prod_ddl secret secret-s cloudflare customer-copy customer_copy money irreversible"

CHECK_TIMEOUT_SECS=60
MERGE_TIMEOUT_SECS=240

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'fm-merge-queue: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

now_epoch() { date -u +%s; }
today_utc() { date -u +%Y-%m-%d; }

max_attempts() {
  local n=${FM_MERGE_QUEUE_MAX_ATTEMPTS:-6}
  case "$n" in ''|*[!0-9]*|0) n=6 ;; esac
  printf '%s\n' "$n"
}

qa_required() {
  [ "${FM_MERGE_QUEUE_QA:-required}" != optional ]
}

# --- records -------------------------------------------------------------

record() {  # <key> <verdict> <reason>
  printf '%s\t%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" "$3" >>"$LEDGER" || return 1
}

# fail_streak <key>: how many refused merge attempts in a row the ledger ends
# with for this row, so a permanently refused merge retires instead of retrying
# forever. Only a refusal the forge itself returned counts: an unreadable forge
# is a transient outage and must never spend a row's budget.
fail_streak() {
  local key=$1
  [ -f "$LEDGER" ] || { printf '0\n'; return 0; }
  awk -F '\t' -v k="$key" '
    $2 == k { if ($3 == "merge-refused") c++; else c = 0 }
    END { print c + 0 }
  ' "$LEDGER" 2>/dev/null || printf '0\n'
}

format_epoch() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

write_last_run() {  # <merged> <retired> <skipped> <queued>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" "$3" "$4" \
    >"$LAST_RUN.tmp" 2>/dev/null && mv -f "$LAST_RUN.tmp" "$LAST_RUN" 2>/dev/null
  return 0
}

# --- lock ----------------------------------------------------------------

lock_acquire() {
  mkdir -p "$RECORDS" 2>/dev/null || return 1
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid" 2>/dev/null
    return 0
  fi
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    return 1
  fi
  # No live owner: an interrupted run left the lock behind.
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "${BASHPID:-$$}" >"$LOCK_DIR/pid" 2>/dev/null
  return 0
}

lock_release() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# --- queue file ----------------------------------------------------------

# queue_owner <file>: the owner for bare repository rows, from the environment
# first and the file's own "# owner:" directive second. Empty means no owner is
# configured, which retires nothing and simply leaves bare rows unreadable.
queue_owner() {
  if [ -n "${FM_MERGE_QUEUE_OWNER:-}" ]; then
    printf '%s\n' "$FM_MERGE_QUEUE_OWNER"
    return 0
  fi
  sed -n 's/^#[[:space:]]*[Oo][Ww][Nn][Ee][Rr][[:space:]]*:[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$1" 2>/dev/null | head -1
}

valid_owner() {
  case "$1" in
    ''|-*|*-|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

valid_repo_name() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

valid_sha_prefix() {
  case "$1" in
    ''|*[!0-9A-Fa-f]*) return 1 ;;
  esac
  [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]
}

# row_key <repo> <number>: the short name the ledger and the daily line use.
row_key() { printf '%s#%s\n' "${1##*/}" "$2"; }

# queue_unusable_count <queue> <owner>: how many queued rows this home cannot
# read at all. Read from the file only, with no forge call, so the daily line
# can report a broken queue instead of staying quiet about it.
queue_unusable_count() {
  local queue=$1 owner=$2 count=0 line repo number expected task method extra owner_name
  [ -f "$queue" ] || { printf '0\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    repo=
    number=
    expected=
    task=
    method=
    extra=
    read -r repo number expected task method extra <<<"$line"
    case "$repo" in
      */*)
        owner_name=${repo%%/*}
        repo=${repo#*/}
        ;;
      *) owner_name=$owner ;;
    esac
    if [ -n "$extra" ] || ! valid_sha_prefix "$expected" \
      || ! valid_owner "$owner_name" || ! valid_repo_name "$repo"; then
      count=$((count + 1))
      continue
    fi
    case "$number" in
      [1-9]*) [ "${#number}" -le 12 ] || count=$((count + 1)) ;;
      *) count=$((count + 1)) ;;
    esac
    case " $METHODS " in
      *" $method "*) ;;
      *) count=$((count + 1)) ;;
    esac
  done <"$queue"
  printf '%s\n' "$count"
}

# --- forge reads ---------------------------------------------------------

# read_pr <url>: one line of "<state>\t<head>\t<labels>\t<title and body>".
# A failed read prints nothing and exits non-zero, which the caller reports as
# unreadable rather than as a verdict about the pull request.
read_pr() {
  fm_run_timed "$CHECK_TIMEOUT_SECS" gh pr view "$1" \
    --json state,isDraft,headRefOid,labels,title,body \
    --jq '[ (if .isDraft then "DRAFT" else .state end), .headRefOid, ([.labels[].name] | join(" ")), ((.title // "") + " " + (.body // "")) ] | @tsv' \
    2>/dev/null
}

# read_checks <url>: one line per check as "<name>\t<bucket>". An empty result
# is reported by the caller as "no checks reported", which is not green.
read_checks() {
  fm_run_timed "$CHECK_TIMEOUT_SECS" gh pr checks "$1" \
    --json name,bucket --jq '.[] | [.name, .bucket] | @tsv' 2>/dev/null
}

# fenced_reason <labels> <title-and-body>: print the fence label that keeps this
# change off the timer, or nothing when it may merge unattended.
fenced_reason() {
  local labels body word
  labels=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  body=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  for word in $FENCE_WORDS; do
    case " $labels " in
      *" $word "*) printf '%s\n' "$word"; return 0 ;;
    esac
  done
  case "$body" in
    *prod-ddl*|*prod_ddl*|*"prod ddl"*) printf 'prod-ddl\n' ;;
  esac
  return 0
}

# --- one row -------------------------------------------------------------

# process_row <repo> <number> <expected-head> <task> <method> <owner> <dry-run>
# Prints one line and sets ROW_VERDICT to a ledger verdict: "keep" means the row
# stays queued, anything else retires it.
ROW_VERDICT=keep
ROW_REASON=

process_row() {
  local repo=$1 number=$2 expected=$3 task=$4 method=$5 owner=$6 dry_run=$7
  local owner_name slug url key fields state head labels body
  local fenced checks name bucket bad qa_line out rc last

  ROW_VERDICT=keep
  ROW_REASON=

  case "$repo" in
    */*)
      owner_name=${repo%%/*}
      slug=${repo#*/}
      ;;
    *)
      owner_name=$owner
      slug=$repo
      ;;
  esac
  key=$(row_key "$slug" "$number")

  # A row this home cannot read is never deleted: a configuration mistake must
  # not destroy the operator's queue. It stays queued, says so on every tick,
  # and the daily line reports how many such rows the queue holds.
  if ! valid_owner "$owner_name"; then
    ROW_VERDICT=unusable
    ROW_REASON="no repository owner for $slug (write '# owner: <login>' in the queue file)"
    printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  if ! valid_repo_name "$slug"; then
    ROW_VERDICT=unusable
    ROW_REASON="repository name is not usable: $slug"
    printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  case " $METHODS " in
    *" $method "*) ;;
    *)
      ROW_VERDICT=unusable
      ROW_REASON="unknown merge method: $method"
      printf 'keep %s unusable row: %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  url="https://github.com/$owner_name/$slug/pull/$number"

  if ! fields=$(read_pr "$url") || [ -z "$fields" ]; then
    ROW_VERDICT=unreadable
    ROW_REASON="the forge did not answer for $url"
    printf 'keep %s %s\n' "$key" "$ROW_REASON"
    return 0
  fi
  IFS=$'\t' read -r state head labels body <<<"$fields"

  case "$state" in
    MERGED)
      ROW_VERDICT='already-merged'
      ROW_REASON="already merged"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
    CLOSED)
      ROW_VERDICT=closed
      ROW_REASON="closed without merging"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
    DRAFT)
      printf 'keep %s draft\n' "$key"
      return 0
      ;;
    OPEN) ;;
    *)
      ROW_VERDICT=unreadable
      ROW_REASON="unreadable pull request state: ${state:-none}"
      printf 'keep %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  case "$head" in
    "$expected"*) ;;
    *)
      ROW_VERDICT='head-moved'
      ROW_REASON="head moved to ${head:0:12} (queue expected ${expected:0:12})"
      printf 'retire %s %s\n' "$key" "$ROW_REASON"
      return 0
      ;;
  esac

  fenced=$(fenced_reason "$labels" "$body")
  if [ -n "$fenced" ]; then
    ROW_VERDICT=fenced
    ROW_REASON="fenced for a decider: $fenced"
    printf 'retire %s %s\n' "$key" "$ROW_REASON"
    return 0
  fi

  # gh pr checks reports pending checks with exit 8 and "no checks" with exit
  # 1, so the output decides and the status never does. No output at all reads
  # as nothing proven, which keeps the row queued rather than merging it.
  checks=$(read_checks "$url" || true)

  bad=
  qa_line=
  while IFS=$'\t' read -r name bucket; do
    [ -n "$name" ] || continue
    case "$name" in
      credit-approval-guard) continue ;;
      qa-review) qa_line=$bucket ;;
    esac
    case "$bucket" in
      pass|skipping) ;;
      *) bad="$bad $name=$bucket" ;;
    esac
  done <<<"$checks"

  if [ -n "$bad" ]; then
    printf 'keep %s not green:%s\n' "$key" "$bad"
    return 0
  fi
  if qa_required && [ -z "$qa_line" ]; then
    printf 'keep %s no qa-review on this head\n' "$key"
    return 0
  fi
  if qa_required && [ "$qa_line" != pass ]; then
    printf 'keep %s qa-review %s\n' "$key" "$qa_line"
    return 0
  fi

  if [ "$dry_run" = 1 ]; then
    printf 'merge %s %s (%s, head %s)\n' "$key" "$url" "$method" "${head:0:12}"
    return 0
  fi

  out=$(fm_run_timed "$MERGE_TIMEOUT_SECS" "$MERGE_CMD" "$task" "$url" \
    -- --"$method" --admin --match-head-commit "$head" 2>&1)
  rc=$?

  if [ "$rc" -eq 0 ]; then
    ROW_VERDICT=merged
    ROW_REASON=$method
    printf 'merged %s %s\n' "$key" "$url"
    return 0
  fi

  last=$(printf '%s\n' "$out" | awk 'NF { line = $0 } END { print line }')
  last=$(printf '%s' "$last" | cut -c1-160)
  ROW_VERDICT='merge-refused'
  ROW_REASON=${last:-"merge attempt exited $rc"}
  printf 'keep %s merge refused: %s\n' "$key" "$ROW_REASON"
  return 0
}

# --- run -----------------------------------------------------------------

maybe_emit_daily() {  # <queue>
  local queue=$1 today last_day last_epoch merged retired keys payload unusable
  [ -f "$LEDGER" ] || : >"$LEDGER"
  today=$(today_utc)
  last_day=
  last_epoch=0
  if [ -f "$SUMMARY_RECORD" ]; then
    IFS=$'\t' read -r last_day last_epoch <"$SUMMARY_RECORD" 2>/dev/null || true
  fi
  case "${last_epoch:-}" in ''|*[!0-9]*) last_epoch=0 ;; esac
  [ "${last_day:-}" = "$today" ] && return 0

  local retired_verdicts=' already-merged closed fenced head-moved '
  merged=$(awk -F '\t' -v since="$last_epoch" '$1 >= since && $3 == "merged" { c++ } END { print c + 0 }' "$LEDGER")
  retired=$(awk -F '\t' -v since="$last_epoch" -v want="$retired_verdicts" '
    BEGIN { n = split(want, v, " "); for (i = 1; i <= n; i++) if (v[i] != "") is_retired[v[i]] = 1 }
    $1 >= since && ($3 in is_retired) { c++ }
    END { print c + 0 }
  ' "$LEDGER")
  keys=$(awk -F '\t' -v since="$last_epoch" '$1 >= since && $3 == "merged" { print $2 }' "$LEDGER" \
    | head -5 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  [ -n "$keys" ] || keys="no merges"

  unusable=$(queue_unusable_count "$queue" "$(queue_owner "$queue")")
  payload="check: merge queue $today - merged $merged ($keys), retired $retired since the last summary"
  case "${unusable:-0}" in
    0) ;;
    *) payload="$payload; $unusable queued row(s) need the queue file fixed" ;;
  esac
  if fm_wake_append check "merge-queue:daily:$today" "$payload"; then
    printf '%s\t%s\n' "$today" "$(now_epoch)" >"$SUMMARY_RECORD"
    printf 'summary: %s\n' "$payload"
  else
    printf 'fm-merge-queue: daily summary could not be queued for %s\n' "$today" >&2
  fi
  return 0
}

cmd_run() {
  local queue=$DEFAULT_QUEUE dry_run=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue)
        [ "$#" -gt 1 ] || die "--queue requires a file path"
        queue=$2
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      *) die "unknown option for run: $1" ;;
    esac
  done

  if [ ! -f "$queue" ]; then
    printf 'fm-merge-queue: no queue file at %s, nothing to do\n' "$queue"
    return 0
  fi
  if [ "$dry_run" = 0 ]; then
    [ -x "$MERGE_CMD" ] || die "merge entrypoint is not runnable: $MERGE_CMD (set FM_ROOT_OVERRIDE to the home's code root)"
    lock_acquire || { printf 'fm-merge-queue: another run is in progress, skipping this tick\n'; return 0; }
    trap 'lock_release' EXIT INT TERM
    mkdir -p "$RECORDS"
    : >>"$LEDGER"
  fi

  local owner tmp keep seen gone line repo number expected task method extra key unmergeable
  local merged=0 retired=0 skipped=0 queued=0
  owner=$(queue_owner "$queue")

  if [ "$dry_run" = 0 ]; then
    tmp=$(mktemp "$queue.XXXXXX") || die "cannot stage the queue rewrite next to $queue"
    cp -p "$queue" "$tmp" 2>/dev/null && : >"$tmp"
    keep=$tmp
  else
    keep=
  fi
  seen=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-seen.XXXXXX") || die "cannot stage the dedupe record"
  gone=$(mktemp "${TMPDIR:-/tmp}/fm-merge-queue-gone.XXXXXX") || die "cannot stage the retirement record"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*)
        [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
        continue
        ;;
    esac
    repo=
    number=
    expected=
    task=
    method=
    extra=
    read -r repo number expected task method extra <<<"$line"

    key=$(row_key "${repo##*/}" "${number:-0}")
    if grep -qxF "$key" "$gone" 2>/dev/null; then
      # A retired key's duplicate row goes with the row that retired it.
      continue
    fi

    unmergeable=
    [ -z "$extra" ] || unmergeable=1
    case "$number" in
      [1-9]*) [ "${#number}" -le 12 ] || unmergeable=1 ;;
      *) unmergeable=1 ;;
    esac
    valid_sha_prefix "$expected" || unmergeable=1
    valid_repo_name "${repo##*/}" || unmergeable=1

    if [ -n "$unmergeable" ]; then
      printf 'keep %s unusable row: %s\n' "$key" "${line:0:80}"
      [ "$dry_run" = 1 ] || record "$key" unusable "unusable queue row"
      skipped=$((skipped + 1))
      [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
      continue
    fi

    if grep -qxF "$key" "$seen" 2>/dev/null; then
      [ -z "$keep" ] || printf '%s\n' "$line" >>"$keep"
      continue
    fi
    printf '%s\n' "$key" >>"$seen"

    process_row "$repo" "$number" "$expected" "$task" "$method" "$owner" "$dry_run"

    if [ "$dry_run" = 1 ]; then
      continue
    fi

    case "$ROW_VERDICT" in
      keep)
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      'merge-refused')
        record "$key" "$ROW_VERDICT" "$ROW_REASON"
        if [ "$(fail_streak "$key")" -ge "$(max_attempts)" ]; then
          printf 'retire %s after %s failed merge attempts\n' "$key" "$(fail_streak "$key")"
          printf '%s\n' "$key" >>"$gone"
          retired=$((retired + 1))
        else
          skipped=$((skipped + 1))
          printf '%s\n' "$line" >>"$keep"
        fi
        ;;
      unreadable)
        record "$key" "$ROW_VERDICT" "$ROW_REASON"
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      unusable)
        # Not part of a failure budget: a bad row is fixed in the file, not by
        # retrying, and it must never consume the merge-attempt allowance.
        record "$key" "$ROW_VERDICT" "$ROW_REASON"
        skipped=$((skipped + 1))
        printf '%s\n' "$line" >>"$keep"
        ;;
      *)
        record "$key" "$ROW_VERDICT" "$ROW_REASON"
        printf '%s\n' "$key" >>"$gone"
        if [ "$ROW_VERDICT" = merged ]; then
          merged=$((merged + 1))
        else
          retired=$((retired + 1))
        fi
        ;;
    esac
  done <"$queue"

  queued=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "${keep:-$queue}" 2>/dev/null || true)
  case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  rm -f "$seen" "$gone" 2>/dev/null || true

  if [ "$dry_run" = 1 ]; then
    printf 'dry run: nothing changed; %s row(s) in %s\n' "$queued" "$queue"
    return 0
  fi

  if [ -n "$keep" ]; then
    if cmp -s "$queue" "$keep"; then
      rm -f "$keep" 2>/dev/null || true
    else
      mv -f "$keep" "$queue" || die "cannot publish the queue rewrite to $queue"
    fi
  fi

  write_last_run "$merged" "$retired" "$skipped" "$queued"
  maybe_emit_daily "$queue"
  printf 'run: merged %s, retired %s, still queued/skipped %s\n' "$merged" "$retired" "$skipped"
  return 0
}

cmd_status() {
  local queue=$DEFAULT_QUEUE queued=0 line when merged retired skipped queued_at_end unusable
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue)
        [ "$#" -gt 1 ] || die "--queue requires a file path"
        queue=$2
        shift 2
        ;;
      *) die "unknown option for status: $1" ;;
    esac
  done
  if [ -f "$queue" ]; then
    queued=$(grep -cv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$queue" 2>/dev/null || true)
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
  fi
  if [ ! -f "$queue" ]; then
    printf 'merge queue: no queue file at %s (this home has not opted in)\n' "$queue"
    return 0
  fi
  printf 'merge queue: %s row(s) in %s\n' "$queued" "$queue"
  unusable=$(queue_unusable_count "$queue" "$(queue_owner "$queue")")
  case "${unusable:-0}" in
    0) ;;
    *) printf 'unusable rows: %s (kept in the queue; the file needs fixing)\n' "$unusable" ;;
  esac
  if [ -f "$LAST_RUN" ]; then
    IFS=$'\t' read -r when merged retired skipped queued_at_end <<<"$(cat "$LAST_RUN" 2>/dev/null)" || true
    case "${when:-}" in
      ''|*[!0-9]*) ;;
      *) printf 'last run: %s - merged %s, retired %s, skipped %s, %s left queued\n' \
        "$(format_epoch "$when")" \
        "${merged:-0}" "${retired:-0}" "${skipped:-0}" "${queued_at_end:-0}" ;;
    esac
  else
    printf 'last run: none recorded\n'
  fi
  if [ -f "$SUMMARY_RECORD" ]; then
    line=$(cat "$SUMMARY_RECORD" 2>/dev/null)
    printf 'daily summary: last written %s\n' "${line%%$'\t'*}"
  fi
  return 0
}

cmd_unit() {
  [ "$#" -eq 1 ] || die "unit requires one of: service, timer"
  case "$1" in
    service)
      cat <<UNIT
[Unit]
Description=firstmate merge queue: land queued, verified pull requests
Documentation=file://$FM_ROOT/docs/merge-queue.md

[Service]
Type=oneshot
WorkingDirectory=$FM_HOME
Environment=FM_HOME=$FM_HOME
ExecStart=$SCRIPT_DIR/fm-merge-queue.sh run
TimeoutStartSec=600
UNIT
      ;;
    timer)
      cat <<UNIT
[Unit]
Description=firstmate merge queue every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=30s
Unit=fm-merge-queue.service

[Install]
WantedBy=timers.target
UNIT
      ;;
    *) die "unit requires one of: service, timer" ;;
  esac
  return 0
}

main() {
  [ "$#" -gt 0 ] || {
    usage
    exit 2
  }
  local cmd=$1
  shift
  case "$cmd" in
    run) cmd_run "$@" ;;
    status) cmd_status "$@" ;;
    unit) cmd_unit "$@" ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"

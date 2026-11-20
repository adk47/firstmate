#!/usr/bin/env bash
# fm-ci-health-check.sh - the registered watcher check that tells firstmate
# whether a watched repository's default branch is broken, with the evidence
# to confirm it.
#
# Usage:
#   fm-ci-health-check.sh [check]                       run the poll (silent unless firstmate should wake)
#   fm-ci-health-check.sh classify <status> <conclusion> print the class of one run answer: red|green|pending|cancelled|unknown
#   fm-ci-health-check.sh classify-run <owner/repo> <run-id>
#                                                       read one run live and print its class with its evidence
#   fm-ci-health-check.sh status                        print the last recorded poll verdict (no network)
#   fm-ci-health-check.sh read-workflow <owner/repo> <branch> <workflow-id> <per-page>
#                                                       (internal) print the newest completed branch run of one workflow
#   fm-ci-health-check.sh arm                           write state/ci-health.check.sh and bind its bytes
#   fm-ci-health-check.sh disarm                        remove the shim, its trust binding, the stamp, and the record
#   fm-ci-health-check.sh --help                        print this help
#
# WHY THIS EXISTS. This is the check that tells the supervisor whether main is
# broken, so a false red from it is the most expensive kind: it teaches the
# reader to ignore real failures. On 2026-11-19 it reported two workflows red
# with nothing but the workflow name in the line. Each poll had read the then-
# newest push run, which really had concluded failure, but a newer run was
# created seconds after the poll and was still in progress when the line was
# read, so the reader could not tell a genuine red from a misread in-progress
# run. The same day main carried three real failures the check could not see
# at all, because the scheduled smoke and the dispatched deploy that failed
# were not push runs and it read only push runs. And a single page of the
# branch's runs, however long, hides a workflow that runs rarely behind the
# ones that run often: H-DevOps has a hundred active workflows and its newest
# hundred runs on main cover forty-four of them. Four things fix that for
# good: every run answer goes through ONE classifier (bin/fm-ci-run-lib.sh),
# every red names the run it read, the poll reads runs of every event, and it
# reads them PER WORKFLOW, so no window can hide a red.
#
# THE SIGNALS, per watched repository:
#   red      for each active workflow, its newest COMPLETED run on the watched
#            branch, whatever event started it except a pull_request or
#            pull_request_target run (GitHub keys those to the base branch, so
#            they describe a pull request, not the branch tip), concluded red:
#            failure, timed_out, or startup_failure. The line names the
#            workflow, the run id, the conclusion it read, the head commit, the
#            run's creation time, and the exact `gh run view` that confirms it.
#            A run that has not answered yet (conclusion null: queued,
#            in_progress, waiting, requested) is never red and never chosen;
#            the workflow's last answer stands until a newer one completes, so
#            a standing failure cannot hide behind a run that is always in
#            progress. A cancelled run is work that never ran, not work that
#            broke, and is never red; an unknown conclusion is never red
#            either, because a new GitHub state must not silently become
#            "red". Two runs created in the same second are ordered by run
#            id, so a same-second retry wins over the run it replaced. A red
#            is not suppressed, delayed, or retried: while a workflow's newest
#            completed run stays red, every poll says so.
#   queued   more queued runs than the repository's bar.
#   cadence  a scheduled workflow (FM_CI_HEALTH_SCHEDULED) has not succeeded
#            inside its allowed age. Judged only when the workflow file
#            actually declares a schedule, because a push-triggered workflow
#            that is simply idle has no cadence to miss.
#
# THE CONTRACT. One line only when firstmate should wake, nothing otherwise,
# finished inside FM_CHECK_TIMEOUT; every API call is individually bounded and
# an unreadable answer is silent, never red. The poll self-throttles through
# state/.ci-health.last (FM_CI_HEALTH_INTERVAL_SECS, default 900) and stands
# down when the GitHub core rate budget is below FM_CI_HEALTH_RATE_FLOOR
# (default 1500). A poll costs one call per active workflow plus two or three
# per repository, about 460 for the default set (H-DevOps alone has about 400
# active workflows), which four polls an hour keep well inside the floor. The
# repositories are read concurrently and, within each, the per-workflow reads
# run FM_CI_HEALTH_PARALLEL at a time, each one bounded and each one skipped
# once the poll's deadline has passed, so the sweep finishes inside the
# watcher's budget.
#
# CONFIGURATION. config/ci-health.env is optional, local, gitignored, parsed
# line by line and never sourced; a value is the rest of its line, so a comment
# belongs on its own line. A set environment variable of the same name wins over
# the file, and the built-in default applies otherwise.
#
#   FM_CI_HEALTH_REPOS           space-separated owner/repo[:branch[:queued-bar]]
#                                (default: the Muso-AI fleet set, see REPOS_DEFAULT)
#   FM_CI_HEALTH_SCHEDULED       space-separated owner/repo:workflow-file[:max-age-secs]
#                                (default: Muso-AI/H-DevOps:reconcile-prod-manifests.yaml:7200)
#   FM_CI_HEALTH_INTERVAL_SECS   seconds between polls (default 900)
#   FM_CI_HEALTH_RATE_FLOOR      stand down below this many remaining core calls (default 1500)
#   FM_CI_HEALTH_PER_PAGE        completed runs read per workflow, newest first (default 10: enough
#                                that a few pull-request-context runs cannot crowd out the branch's own)
#   FM_CI_HEALTH_PARALLEL        per-workflow reads in flight at once, per repository; the
#                                repositories themselves are read concurrently, so the ceiling is
#                                repositories x parallel short-lived gh processes (about 80 for the
#                                default set, since only H-DevOps has more than 32 workflows), each
#                                about 55 MB for well under a second (default 32)
#   FM_CI_HEALTH_TOKEN_ENV       an installer-managed env file to source for GH_TOKEN
#                                (default ~/.config/muso/gh-app-token.env; "none" skips it)
#   FM_CI_HEALTH_TRAILER         the routing reminder appended to a wake line
#
# Test hooks: FM_CI_HEALTH_NOW (epoch) and FM_CI_HEALTH_GH (the gh binary).
#
# RECORD. state/.ci-health.last is the throttle stamp. state/.ci-health.verdict
# keeps the last poll's time and verdict for `status`. `disarm` removes both.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT_BIN="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
ENV_FILE="$CONFIG_DIR/ci-health.env"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-ci-run-lib.sh
. "$SCRIPT_DIR/fm-ci-run-lib.sh"

CHECK_ID='ci-health'
STAMP="$STATE/.ci-health.last"
VERDICT="$STATE/.ci-health.verdict"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
REPOS_DEFAULT='Muso-AI/H-DevOps:main:150 Muso-AI/hydra:main:40 Muso-AI/core-backend:develop:60 Muso-AI/web-credits-next:main:40 Muso-AI/industry-data-processing:main:30'
SCHEDULED_DEFAULT='Muso-AI/H-DevOps:reconcile-prod-manifests.yaml:7200'
TRAILER_DEFAULT='route each red to the repo lane that owns it; fix-forward, never hand-apply'
MAX_LINE=1500
# Each API call is bounded on its own, and the poll starts no new read once
# its budget is spent, so a slow or absent GitHub cannot hold the watcher's
# whole sweep: the budget plus one call's bound, plus a margin, fits inside the
# watcher's timeout for the check.
CHECK_TIMEOUT_SECS=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT_SECS" in ''|*[!0-9]*) CHECK_TIMEOUT_SECS=30 ;; esac
CALL_TIMEOUT_SECS=$((CHECK_TIMEOUT_SECS / 3))
[ "$CALL_TIMEOUT_SECS" -ge 3 ] || CALL_TIMEOUT_SECS=3
[ "$CALL_TIMEOUT_SECS" -le 20 ] || CALL_TIMEOUT_SECS=20
POLL_BUDGET_SECS=$((CHECK_TIMEOUT_SECS - CALL_TIMEOUT_SECS - 2))
[ "$POLL_BUDGET_SECS" -le 18 ] || POLL_BUDGET_SECS=18
[ "$POLL_BUDGET_SECS" -ge 3 ] || POLL_BUDGET_SECS=3
POLL_START=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

now_epoch() {
  case "${FM_CI_HEALTH_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_CI_HEALTH_NOW" ;;
  esac
}

# conf <KEY> <default>: a set environment variable, else the env file's value,
# else the default. The file is parsed line by line and never sourced; a value
# is the rest of its line, so a comment belongs on its own line above it.
conf() {
  local key=$1 default=$2 line value='' found=0 set=''
  eval "set=\${$key+x}"
  if [ -n "$set" ]; then
    eval "value=\${$key}"
    printf '%s\n' "$value"
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

conf_int() {  # <KEY> <default>
  local v
  v=$(conf "$1" "$2")
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$v" ;;
  esac
}

gh_bin() {
  printf '%s\n' "${FM_CI_HEALTH_GH:-gh}"
}

# The installer-managed App-token env file carries its own expiry logic and is
# built to be sourced; it exports GH_TOKEN only while the token is fresh, so an
# expired token never shadows the host login.
load_token_env() {
  local f
  f=$(conf FM_CI_HEALTH_TOKEN_ENV "$HOME/.config/muso/gh-app-token.env")
  [ "$f" != none ] || return 0
  if [ "${f:0:1}" = '~' ]; then
    case "${f:1}" in
      ''|/*) f="$HOME${f:1}" ;;
    esac
  fi
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f"
  return 0
}

# gh_api <path>: the raw JSON answer, or nothing (and non-zero) when the call
# failed, hung, or printed something jq cannot read. Silence is the only safe
# reading of an unreadable answer.
gh_api() {
  local out
  out=$(fm_run_timed "$CALL_TIMEOUT_SECS" "$(gh_bin)" api "$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# Fields are joined on the unit separator, never a tab: a shell read splits
# on runs of whitespace, so an EMPTY conclusion between two tabs would vanish
# and the head commit would be read as the conclusion.
FS=$'\x1f'

# newest_completed_run <runs-json>: one row for the newest completed run in
# the answer: name, id, status, conclusion, short head, created; nothing when
# the answer holds no such run. Pull-request-context runs are not runs of the
# branch, so they never take part, and a run that has not completed has not
# answered, so it never takes part either.
newest_completed_run() {
  printf '%s\n' "$1" | jq -r '
    (.workflow_runs // [])
    | map(select((.event // "") as $e
        | $e != "pull_request" and $e != "pull_request_target"))
    | map(select((.status // "") == "completed"))
    | if length == 0 then empty else max_by([.created_at, .id]) end
    | [ (.name // ""), (.id // "" | tostring), (.status // ""), (.conclusion // ""),
        ((.head_sha // "")[0:9]), (.created_at // "") ]
    | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")' 2>/dev/null
}

# active_workflow_ids <repo>: the ids of the repository's active workflows,
# one per line, read a page at a time; a page that cannot be read ends the
# list (and the caller is silent for what it did not see, never red).
active_workflow_ids() {
  local repo=$1 page=1 answer count
  while [ "$page" -le 5 ]; do
    poll_has_budget || return 0
    answer=$(gh_api "repos/$repo/actions/workflows?per_page=100&page=$page") || return 0
    printf '%s\n' "$answer" | jq -r '.workflows // [] | map(select((.state // "") == "active")) | .[].id' 2>/dev/null
    count=$(printf '%s\n' "$answer" | jq -r '.workflows // [] | length' 2>/dev/null)
    case "$count" in ''|*[!0-9]*) return 0 ;; esac
    [ "$count" -ge 100 ] || return 0
    page=$((page + 1))
  done
}

# The worker behind `read-workflow`: one bounded read of one workflow's newest
# completed runs on the branch, printed as a row, or nothing. It is run as a
# separate process so a repository's workflows can be read several at a time,
# and it skips the read when the poll's deadline (FM_CI_HEALTH_DEADLINE, an
# epoch) has already passed.
action_read_workflow() {
  [ "$#" -eq 4 ] || usage
  local repo=$1 branch=$2 wf=$3 per_page=$4 deadline runs
  deadline=${FM_CI_HEALTH_DEADLINE:-}
  case "$deadline" in
    ''|*[!0-9]*) ;;
    *) [ "$(date -u +%s)" -lt "$deadline" ] || return 0 ;;
  esac
  runs=$(gh_api "repos/$repo/actions/workflows/$wf/runs?branch=$branch&status=completed&per_page=$per_page") || return 0
  newest_completed_run "$runs"
}

# workflow_rows <repo> <branch> <per-page> <parallel>: one row per active
# workflow that has a completed run on the branch, read in parallel.
workflow_rows() {
  local repo=$1 branch=$2 per_page=$3 parallel=$4 ids
  ids=$(active_workflow_ids "$repo")
  [ -n "$ids" ] || return 0
  printf '%s\n' "$ids" | FM_CI_HEALTH_DEADLINE=$((POLL_EPOCH_START + POLL_BUDGET_SECS)) \
    xargs -P "$parallel" -I '{}' "$SCRIPT_BIN" read-workflow "$repo" "$branch" '{}' "$per_page" 2>/dev/null
}

# run_evidence <repo> <name> <id> <status> <conclusion> <head> <created>: the
# phrase a red line carries, enough to confirm it with one gh command.
run_evidence() {
  local repo=$1 name=$2 id=$3 status=$4 conclusion=$5 head=$6 created=$7
  printf '%s run %s conclusion=%s status=%s head %s created %s (gh run view %s --repo %s)' \
    "$name" "$id" "${conclusion:-null}" "${status:-?}" "${head:-?}" "${created:-?}" "$id" "$repo"
}

# repo_red <repo> <branch> <rows>: "; "-joined evidence, in workflow-name
# order, for every workflow whose newest completed non-pull-request run on the
# branch is red, empty otherwise.
repo_red() {
  local repo=$1 branch=$2 rows=$3 out='' name id status conclusion head created class
  while IFS=$FS read -r name id status conclusion head created; do
    [ -n "$id" ] || continue
    class=$(fm_ci_run_class "$status" "$conclusion")
    [ "$class" = red ] || continue
    out="${out}${out:+; }$(run_evidence "$repo" "$name" "$id" "$status" "$conclusion" "$head" "$created")"
  done <<EOF
$(printf '%s\n' "$rows" | sort -t "$FS" -k1,1)
EOF
  [ -z "$out" ] || printf '%s %s red: %s' "$repo" "$branch" "$out"
}

# scheduled_late <repo> <workflow-file> <max-age> <now>: a cadence miss line,
# empty when the workflow declares no schedule or is inside its allowance.
scheduled_late() {
  local repo=$1 wf=$2 max_age=$3 now=$4 content has_schedule runs last last_epoch age
  poll_has_budget || return 0
  content=$(gh_api "repos/$repo/contents/.github/workflows/$wf") || return 0
  has_schedule=$(printf '%s\n' "$content" | jq -r '.content // ""' | base64 -d 2>/dev/null \
    | grep -cE '^[[:space:]]+schedule:' || true)
  [ "${has_schedule:-0}" -gt 0 ] || return 0
  poll_has_budget || return 0
  runs=$(gh_api "repos/$repo/actions/workflows/$wf/runs?status=success&per_page=1") || return 0
  last=$(printf '%s\n' "$runs" | jq -r '.workflow_runs[0].updated_at // ""' 2>/dev/null)
  [ -n "$last" ] || return 0
  last_epoch=$(date -u -d "$last" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last" +%s 2>/dev/null) || return 0
  age=$((now - last_epoch))
  [ "$age" -gt "$max_age" ] || return 0
  printf '%s %s last success %s (%sh ago, allowed %sh)' "$repo" "$wf" "$last" "$((age / 3600))" "$((max_age / 3600))"
}

record_verdict() {  # <now> <line-or-empty>
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf 'at=%s\nverdict=%s\n' "$1" "${2:-quiet}" > "$VERDICT" 2>/dev/null || true
}

poll_has_budget() { [ $((SECONDS - POLL_START)) -lt "$POLL_BUDGET_SECS" ]; }

# repo_job <spec> <per-page> <parallel>: one repository's queued and red
# findings, "; "-joined, for a spec of the form owner/repo[:branch[:bar]].
repo_job() {
  local spec=$1 per_page=$2 parallel=$3 repo branch=main bar='' queued rows part out=''
  repo=${spec%%:*}
  case "$spec" in
    *:*:*) bar=${spec##*:}; branch=${spec#*:}; branch=${branch%%:*} ;;
    *:*) branch=${spec#*:} ;;
  esac
  [ -n "$branch" ] || branch=main
  case "$bar" in *[!0-9]*) bar='' ;; esac
  poll_has_budget || return 0
  if [ -n "$bar" ]; then
    queued=$(gh_api "repos/$repo/actions/runs?status=queued&per_page=1" | jq -r '.total_count // 0' 2>/dev/null)
    case "$queued" in ''|*[!0-9]*) queued=0 ;; esac
    [ "$queued" -le "$bar" ] || out="$repo queued=$queued (>$bar)"
  fi
  poll_has_budget || { printf '%s' "$out"; return 0; }
  rows=$(workflow_rows "$repo" "$branch" "$per_page" "$parallel")
  part=$(repo_red "$repo" "$branch" "$rows")
  [ -z "$part" ] || out="${out}${out:+; }$part"
  printf '%s' "$out"
}

action_check() {
  local now interval floor per_page parallel rem answer spec line='' part msg='' trailer
  now=$(now_epoch)
  POLL_START=$SECONDS
  POLL_EPOCH_START=$(date -u +%s)
  interval=$(conf_int FM_CI_HEALTH_INTERVAL_SECS 900)
  if [ -f "$STAMP" ]; then
    local last
    last=$(cat "$STAMP" 2>/dev/null)
    case "$last" in
      ''|*[!0-9]*) ;;
      *) [ $((now - last)) -ge "$interval" ] || return 0 ;;
    esac
  fi
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\n' "$now" > "$STAMP" 2>/dev/null || return 0
  load_token_env
  floor=$(conf_int FM_CI_HEALTH_RATE_FLOOR 1500)
  per_page=$(conf_int FM_CI_HEALTH_PER_PAGE 10)
  parallel=$(conf_int FM_CI_HEALTH_PARALLEL 32)
  [ "$parallel" -ge 1 ] || parallel=1
  answer=$(gh_api rate_limit) || {
    record_verdict "$now" 'rate limit unreadable: gh api rate_limit failed (no gh, no credential, or no network)'
    return 0
  }
  rem=$(printf '%s\n' "$answer" | jq -r '.resources.core.remaining // empty' 2>/dev/null)
  case "$rem" in
    ''|*[!0-9]*)
      record_verdict "$now" 'rate limit unreadable: gh api rate_limit failed (no gh, no credential, or no network)'
      return 0
      ;;
  esac
  if [ "$rem" -lt "$floor" ]; then
    record_verdict "$now" "stood down: $rem core calls remaining (< $floor)"
    return 0
  fi
  # Each repository is read as its own job, writing its queued and red
  # findings to one scratch file, so the small repositories' round trips
  # overlap the big one's sweep; the findings are assembled in configured
  # order once every job has returned or given up at the deadline.
  local scratch i=0 specs=()
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-health.XXXXXX") || return 0
  for spec in $(conf FM_CI_HEALTH_REPOS "$REPOS_DEFAULT"); do
    specs+=("$spec")
    repo_job "$spec" "$per_page" "$parallel" > "$scratch/$i" 2>/dev/null &
    i=$((i + 1))
  done
  wait
  i=0
  for spec in "${specs[@]}"; do
    part=$(cat "$scratch/$i" 2>/dev/null)
    [ -z "$part" ] || msg="${msg}${msg:+; }$part"
    i=$((i + 1))
  done
  rm -rf "$scratch"
  for spec in $(conf FM_CI_HEALTH_SCHEDULED "$SCHEDULED_DEFAULT"); do
    poll_has_budget || break
    repo=${spec%%:*}
    part=${spec#*:}
    local wf max_age
    wf=${part%%:*}
    max_age=7200
    case "$part" in
      *:*) max_age=${part#*:} ;;
    esac
    case "$max_age" in ''|*[!0-9]*) max_age=7200 ;; esac
    [ -n "$wf" ] && [ "$wf" != "$spec" ] || continue
    part=$(scheduled_late "$repo" "$wf" "$max_age" "$now")
    [ -z "$part" ] || msg="${msg}${msg:+; }$part"
  done
  if [ -n "$msg" ]; then
    trailer=$(conf FM_CI_HEALTH_TRAILER "$TRAILER_DEFAULT")
    line="ci-health: $msg - $trailer"
    record_verdict "$now" "$line"
    fm_cap_line "$line" "$MAX_LINE"
  else
    record_verdict "$now" ''
  fi
  return 0
}

action_classify() {
  [ "$#" -eq 2 ] || usage
  fm_ci_run_class "$1" "$2"
}

# One live read, printed as the class plus the same evidence phrase a wake
# line would carry, so a reported red can be checked with this exact command.
action_classify_run() {
  [ "$#" -eq 2 ] || usage
  local repo=$1 id=$2 run name status conclusion head created class
  case "$id" in ''|*[!0-9]*) usage ;; esac
  load_token_env
  run=$(gh_api "repos/$repo/actions/runs/$id") || {
    printf 'unreadable: run %s in %s could not be read\n' "$id" "$repo" >&2
    return 1
  }
  IFS=$FS read -r name status conclusion head created <<EOF
$(printf '%s\n' "$run" | jq -r '[ (.name // ""), (.status // ""), (.conclusion // ""), ((.head_sha // "")[0:9]), (.created_at // "") ] | map(gsub("[\u001f\r\n]"; " ")) | join("\u001f")')
EOF
  class=$(fm_ci_run_class "$status" "$conclusion")
  printf '%s: %s\n' "$class" "$(run_evidence "$repo" "$name" "$id" "$status" "$conclusion" "$head" "$created")"
}

action_status() {
  if [ -f "$VERDICT" ]; then
    cat "$VERDICT"
  else
    printf 'no poll recorded yet\n'
  fi
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-ci-health-check.sh - CI health poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-ci-health-check.sh") check"
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  home=$(fm_custom_check_resolve_home "$FM_HOME") || {
    printf 'fm-ci-health-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  fm_custom_check_arm "$STATE" "$CHECK_ID" .fm-ci-health-check \
    fm-ci-health-check "$REGISTER_BIN" "$home" "$want"
}

action_disarm() {
  fm_custom_check_disarm "$STATE" "$CHECK_ID" "$STAMP" "$VERDICT"
}

case "${1:-check}" in
  check) action_check ;;
  classify) shift; action_classify "$@" ;;
  classify-run) shift; action_classify_run "$@" ;;
  read-workflow) shift; action_read_workflow "$@" ;;
  status) action_status ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

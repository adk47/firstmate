#!/usr/bin/env bash
# Deliver one pull-request event to the crew that owns the pull request.
# Usage: fm-pr-event.sh [--head <sha>] <pr-url> <kind> <text...>
#
# A PR-event producer - the pr-flow job is the canonical one - calls this at the
# moment it observes a QA finding, a NO-GO, a conflict, or any other event that
# belongs to the crew that authored the pull request.
# The author is resolved from this home's own records rather than guessed from
# a branch name: it is the one task whose state/<id>.meta records that exact
# canonical pr= URL, which bin/fm-pr-check.sh wrote when the PR became ready.
# The event is delivered as an explicit fire-and-forget record through
# bin/fm-send.sh, so it lands in the author's durable steering inbox without
# ever climbing the re-ring ladder into a firstmate escalation
# (bin/fm-task-inbox-lib.sh owns that record format and ladder).
#
# Once-ness belongs to this script, not to the caller: the delivery id is the
# first 16 hex of the SHA-256 of the exact record body, and the local inbox
# collapses an identical fire-and-forget body onto the record already present.
# The body carries the head the event belongs to, so once-ness is per pull
# request, head, and event kind: the same finding re-fired on a new head is a
# new record, while a blind retry after an uncertain outcome can never queue a
# second copy the crew would act on twice.
#
# The head is resolved live, never from a snapshot that a push leaves behind: it
# is the opened pull request's own head ref (refs/pull/<n>/head on GitHub,
# refs/merge-requests/<n>/head on GitLab), fetched into a private ref in the
# author's worktree exactly as bin/fm-review-diff.sh does. --head <sha> overrides
# that for a caller that already holds the head. Only when neither is available
# does the author's recorded pr_head= serve as a last resort, and a body with no
# resolvable head says "head unresolvable" rather than collapsing events onto a
# stale identity. The body names the source it used - live, explicit, or
# recorded - so a reader can tell a live head from a stale one.
#
# <kind> is a lowercase token (a letter, then letters, digits, or dashes). The
# recorded body is "pr-flow: <pr-url> <kind> (head <head> <source>): <text>", so
# every fired record names the producer, the pull request, the head it was fired
# for and where that head came from, and its event kind.
#
# Exit codes:
#   0  the event is durably recorded in the author's steering inbox
#   2  invalid request (URL, kind, head, or missing text)
#   4  no task in this home records that pull request, so the caller keeps its
#      own routing (the pr-flow job's lane ping and stale-finding label)
#   5  more than one task records that pull request; refuse rather than guess
#   *  bin/fm-send.sh's own failure, propagated unchanged
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'usage: fm-pr-event.sh [--head <sha>] <pr-url> <kind> <text...>\n' >&2
  exit 2
}

HEAD_OVERRIDE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)
      [ "$#" -ge 2 ] || usage_error "--head requires a commit id"
      HEAD_OVERRIDE=$2
      shift 2
      ;;
    --head=*)
      HEAD_OVERRIDE=${1#--head=}
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -ge 3 ] || usage_error "a pull request URL, an event kind, and the event text are required"
RAW_URL=$1
KIND=$2
shift 2
TEXT=$*

[[ "$KIND" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || usage_error "invalid event kind: $KIND"
[ -z "$HEAD_OVERRIDE" ] || fm_pr_head_valid "$HEAD_OVERRIDE" || usage_error "invalid head: $HEAD_OVERRIDE"
[ -n "$TEXT" ] || usage_error "the event text is empty"
fm_pr_url_parse "$RAW_URL" || usage_error "invalid pull request URL: $RAW_URL"
URL=$FM_PR_URL

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

# Resolve the author from the recorded pr= identity. A metadata file that is a
# symlink, a directory, or not a single-link regular file is not a record this
# home wrote, so it is skipped rather than trusted.
AUTHOR=
META=
MATCHES=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  fm_pr_task_id_valid "$id" || continue
  grep -qxF "pr=$URL" "$meta" 2>/dev/null || continue
  AUTHOR=$id
  META=$meta
  MATCHES=$((MATCHES + 1))
done

case "$MATCHES" in
  0)
    printf 'no-author: no task in this home records %s as its pull request\n' "$URL" >&2
    exit 4
    ;;
  1) ;;
  *)
    printf 'ambiguous-author: %s tasks in this home record %s as their pull request\n' "$MATCHES" "$URL" >&2
    exit 5
    ;;
esac

RECORDED_HEAD=$(grep '^pr_head=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)

# fm_pr_event_live_head resolves the opened pull request's own head ref in the
# author's worktree, so the identity advances with every push instead of
# freezing on whatever pr_head= was recorded when the PR became ready.
fm_pr_event_live_head() {
  local wt ref target resolved
  wt=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  case "$FM_PR_PROVIDER" in
    github)
      target="refs/pull/$FM_PR_NUMBER/head"
      ref="refs/fm-pr-event/pull/$FM_PR_NUMBER/head"
      ;;
    gitlab)
      target="refs/merge-requests/$FM_PR_NUMBER/head"
      ref="refs/fm-pr-event/merge-requests/$FM_PR_NUMBER/head"
      ;;
    *) return 1 ;;
  esac
  git -C "$wt" fetch --quiet origin "+$target:$ref" >/dev/null 2>&1 || return 1
  resolved=$(git -C "$wt" rev-parse --verify "$ref^{commit}" 2>/dev/null) || return 1
  fm_pr_head_valid "$resolved" || return 1
  printf '%s' "$resolved"
}

HEAD_SOURCE=
if [ -n "$HEAD_OVERRIDE" ]; then
  HEAD=$HEAD_OVERRIDE
  HEAD_SOURCE=explicit
elif HEAD=$(fm_pr_event_live_head); then
  HEAD_SOURCE=live
elif [ -n "$RECORDED_HEAD" ] && fm_pr_head_valid "$RECORDED_HEAD"; then
  HEAD=$RECORDED_HEAD
  HEAD_SOURCE=recorded
else
  HEAD=
  HEAD_SOURCE=
fi
if [ -n "$HEAD" ]; then
  BODY="pr-flow: $URL $KIND (head $HEAD $HEAD_SOURCE): $TEXT"
else
  BODY="pr-flow: $URL $KIND (head unresolvable): $TEXT"
fi

# The delivery id is derived from the exact body so a retry of the same event
# carries the same id, and a different event can never collide with it.
BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-pr-event.XXXXXX") || {
  echo "error: could not stage the event body" >&2
  exit 1
}
trap 'rm -f -- "$BODY_TMP"' EXIT
trap 'exit 1' HUP INT TERM
printf '%s' "$BODY" > "$BODY_TMP" || {
  echo "error: could not stage the event body" >&2
  exit 1
}
DIGEST=$(fm_pr_sha256 "$BODY_TMP") || {
  echo "error: no SHA-256 tool is available to derive the delivery id" >&2
  exit 1
}
[ "${#DIGEST}" -eq 64 ] || {
  echo "error: no SHA-256 tool is available to derive the delivery id" >&2
  exit 1
}
DELIVERY_ID=${DIGEST:0:16}

# bin/fm-send.sh resolves its own state from FM_HOME and FM_STATE_OVERRIDE, so
# both must reach it exactly as this script resolved them.
export FM_HOME
[ -z "${FM_STATE_OVERRIDE-}" ] || export FM_STATE_OVERRIDE

"$SCRIPT_DIR/fm-send.sh" "$AUTHOR" --fire-and-forget "$DELIVERY_ID" "$BODY" || exit $?

printf 'delivered: %s %s %s\n' "$AUTHOR" "$URL" "$KIND"

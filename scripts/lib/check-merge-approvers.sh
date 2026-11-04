#!/usr/bin/env bash
# check-merge-approvers.sh — a profile-merge-only approver exists ONLY with a recorded captain decision.
#
# Why (firstmate 041, 2026-10-28): captain-approved profile merges admitted by the coded decider need a
# --confirmed-by handle. muso-cli (Muso-AI/muso-cli#64) reads <config>/merge-approvers.txt for
# POST /admin/profiles/merge ONLY (never track merges, deletes, the bulk overflow or capability
# verbs), and demands an --approval-ref naming captain-<id> and decider-<run id>. This guard keeps the
# file honest: every handle it lists must have a policies/credit-approval-automation.json entry
# with `merge_approver` == that handle, approved == true, approved_by and approval_ref non-empty.
# A handle may not also sit on the capability list AND may not sit on the GLOBAL approver list
# (scopes never mix). The global check is not cosmetic: muso-cli#64's mergeScoped() asks "is this
# --confirmed-by a global approver?" FIRST and, if the handle is on the global list, takes the
# ordinary global approval path - which does NOT require the one-use decider admission. A handle
# on both lists is therefore a full-scope approver with the decider record silently skipped.
#
# Modes:
#   --check-repo FILE   exit 1 if FILE lists a handle without an approved registry row.
#                       PR Validation and deploy.sh (before install) run this.
#   --verify-installed  deploy, after the render: same check on MERGE_APPROVERS_DEST.
# Env (tests): MERGE_APPROVERS_DEST (default /root/.config/muso/merge-approvers.txt),
#              CREDIT_APPROVAL_REGISTRY (default <repo>/policies/credit-approval-automation.json),
#              CAP_APPROVERS_FILE (default: the capability-approvers.txt next to FILE / DEST),
#              GLOBAL_APPROVERS_FILE (default: BOTH tier2-approvers.txt next to the repo source and
#              approvers.txt next to the installed copy - the CLI reads the latter).
# Exit: 0 clean / 1 violation / 2 usage or unreadable input.
set -euo pipefail

ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REGISTRY="${CREDIT_APPROVAL_REGISTRY:-$ROOT/policies/credit-approval-automation.json}"
DEST="${MERGE_APPROVERS_DEST:-/root/.config/muso/merge-approvers.txt}"
GLOBAL_APPROVERS_FILE="${GLOBAL_APPROVERS_FILE:-}"

entries() {
  local f="$1"
  [ -e "$f" ] || return 0
  [ -r "$f" ] || { echo "unreadable: $f" >&2; return 2; }
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f" | grep -v '^$' || true
}

check_file() {
  local f="$1" cap="$2" e h bad=0 approved g
  local -a GLOBAL_LISTS
  if [ -n "$GLOBAL_APPROVERS_FILE" ]; then
    GLOBAL_LISTS=("$GLOBAL_APPROVERS_FILE")
  else
    # repo source dir: the tier2 list the CLI's approvers.txt is rendered from; installed dir: the file
    # the CLI actually reads. Whichever exist are consulted, so both modes are covered by one rule.
    GLOBAL_LISTS=("$(dirname "$f")/tier2-approvers.txt" "$(dirname "$f")/approvers.txt")
  fi
  e=$(entries "$f") || return 2
  [ -n "$e" ] || { echo "check-merge-approvers: $f lists no merge approver (clean)"; return 0; }
  [ -r "$REGISTRY" ] || { echo "check-merge-approvers: registry unreadable: $REGISTRY" >&2; return 2; }
  jq -e '.automations | type == "object"' "$REGISTRY" >/dev/null 2>&1 \
    || { echo "check-merge-approvers: $REGISTRY has no .automations object" >&2; return 2; }
  while IFS= read -r h; do
    if ! printf '%s' "$h" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      echo "check-merge-approvers: VIOLATION: '$h' is not a plain handle" >&2; bad=1; continue
    fi
    approved=$(jq -r --arg h "$h" '[.automations[] | select((.merge_approver // "" | ascii_downcase) == ($h | ascii_downcase))
        | select(.approved == true and ((.approved_by // "") | length) > 0 and ((.approval_ref // "") | length) > 0)] | length' "$REGISTRY")
    if [ "$approved" -lt 1 ]; then
      echo "check-merge-approvers: VIOLATION: $f lists '$h' but no registry entry has merge_approver=$h with approved=true + approved_by + approval_ref" >&2
      echo "  A profile-merge approver is a captain decision recorded in $REGISTRY first." >&2
      bad=1
    fi
    if [ -n "$cap" ] && entries "$cap" | grep -qixF -- "$h"; then
      echo "check-merge-approvers: VIOLATION: '$h' is also on $cap (merge and capability scopes never mix)" >&2
      bad=1
    fi
    # The global list is a SCOPE ESCAPE, not a style issue: muso-cli#64 mergeScoped() falls back to the
    # global approval path when the handle is on it, and that path requires no decider admission.
    for g in "${GLOBAL_LISTS[@]}"; do
      [ -e "$g" ] || continue
      if entries "$g" | grep -qixF -- "$h"; then
        echo "check-merge-approvers: VIOLATION: '$h' is also on $g (the GLOBAL approver list) - muso-cli takes the global approval path for a merge, so the one-use decider admission is skipped and the handle can approve every other approval-tier verb. Remove it from one of the two lists." >&2
        bad=1
      fi
    done
  done <<< "$e"
  [ "$bad" -eq 0 ] && echo "check-merge-approvers: $f clean ($(printf '%s\n' "$e" | wc -l | tr -d ' ') registered merge approver(s))"
  return "$bad"
}

case "${1:-}" in
  --check-repo)
    [ -n "${2:-}" ] || { echo "usage: $0 --check-repo FILE" >&2; exit 2; }
    [ -r "$2" ] || { echo "check-merge-approvers: repo source missing or unreadable: $2" >&2; exit 2; }
    check_file "$2" "${CAP_APPROVERS_FILE:-$(dirname "$2")/capability-approvers.txt}"
    ;;
  --verify-installed)
    check_file "$DEST" "${CAP_APPROVERS_FILE:-$(dirname "$DEST")/capability-approvers.txt}"
    ;;
  *)
    echo "usage: $0 --check-repo FILE | --verify-installed" >&2
    exit 2
    ;;
esac

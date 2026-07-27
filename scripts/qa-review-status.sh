#!/usr/bin/env bash
set -euo pipefail

# qa-review-status.sh — own the lifecycle of the `qa-review` commit status.
# ===========================================================================
# On repos where `qa-review` is a REQUIRED status check, this status is the merge
# gate: GitHub holds the merge until it reports success. That makes the status a
# safety-critical artifact rather than a nice-to-have signal, because **GitHub
# never times out a required check that was never reported** — it waits forever.
# A PR whose review was silently skipped becomes permanently unmergeable.
#
# The skip paths in .github/workflows/qa-autoreview.yml (no Slack-UID mapping,
# draft, wrong base) all `exit 0` without posting anything, and the dispatch
# itself is fire-and-forget, so before the gate can be switched on EVERY path has
# to end in a reported state. That is what this script is for.
#
# ── State machine ────────────────────────────────────────────────────────────
#   pending  — review queued or running. Blocks merge (correct: the gate is armed
#              from the moment the PR opens, so nothing can slip through in the
#              window before QA starts).
#   success  — GO, or "not gated" for a PR this automation deliberately does not
#              review (e.g. a base branch that is not protected).
#   failure  — NO-GO, or "QA could not review this" (unmapped author, dispatch
#              lost). Blocks, and says why. An unreviewable PR must not merge.
#
# ── Why it posts through qa-gh.sh ────────────────────────────────────────────
# Branch protection can pin a required check to a specific GitHub App
# (`checks: [{context, app_id}]` — "The ID of the GitHub App that must provide
# this check"). Pinning is what stops anyone with repo write from curl-ing a
# green `qa-review` to bypass QA. That only works if the App is what posts it:
# a status created by a *user* cannot be app-pinned. So this must go through the
# identity shim, never bare `gh`.
#
# Usage:
#   qa-review-status.sh <owner/repo> <sha> <state> <description>
#
# Note there is deliberately no "post only if absent" mode: the workflow's seed
# SHOULD re-arm `pending` when it re-fires, because a re-fire means a fresh
# review is running and the previous verdict is stale.
#
# Exit codes: 0 ok | 2 usage | 3 post failed
#
# Env: QA_GH override the identity shim.
#
# Whether a repo is gated at all is decided by the CALLER (the workflow reads
# .merge_gate_repos), not here: this script's job is to report a state whenever
# it is asked to, so the one place that decides "is this repo gated" stays the
# workflow and cannot drift between two readers.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_GH="${QA_GH:-$_here/qa-gh.sh}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
CONTEXT="qa-review"

die() { echo "qa-review-status: $2" >&2; exit "$1"; }

[ "$#" -ge 4 ] || die 2 "usage: qa-review-status.sh <owner/repo> <sha> <state> <description> [target-url]"
repo="$1"; sha="$2"; state="$3"; description="$4"; target_url="${5:-}"

# Strict: this is spliced into an API path. "contains a slash" would admit
# multi-segment and traversal values.
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name, got '$repo'"
# 40-hex only: this is spliced into an API path.
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die 2 "sha must be 40 hex chars, got '$sha'"
case "$state" in pending|success|failure|error) ;; *) die 2 "state must be pending|success|failure|error, got '$state'" ;; esac

# GitHub truncates descriptions at 140 chars; truncate deliberately so the
# meaningful part is never the bit that gets cut.
[ "${#description}" -le 140 ] || description="${description:0:137}..."

# Arming-order guard. `merge_gate_repos` (is the check required?) and
# `identity.app_repos` (who posts it?) are independent lists, and branch
# protection is a third source of truth out of the repo entirely. Arming the
# first without the second is the worst failure shape available here: the status
# posts fine from the host account, the UI shows a green qa-review row, and the
# app-pinned required check sits unsatisfied forever with nothing looking wrong.
# Refuse rather than post an unsatisfiable status.
if jq -e --arg r "$repo" '(.merge_gate_repos // []) | index($r)' "$POLICY" >/dev/null 2>&1 \
   && ! jq -e --arg r "$repo" '(.identity.app_repos // []) | index($r)' "$POLICY" >/dev/null 2>&1; then
  die 3 "$repo is in .merge_gate_repos but NOT in .identity.app_repos — the status would be posted by the host account and could never satisfy an app-pinned required check. Add it to app_repos first."
fi

# target_url is the "Details" link. On a REQUIRED check it is the operator's only
# in-UI route to why the gate is red, so pass it through when the caller has one.
set -- --method POST -f state="$state" -f context="$CONTEXT" -f description="$description"
[ -n "$target_url" ] && set -- "$@" -f target_url="$target_url"

# Capture stderr rather than discarding it: this one write decides mergeability,
# and "403 Resource not accessible by integration" (the app-pin misconfiguration)
# must not look identical to a network blip.
err_file="$(mktemp)"
if ! "$QA_GH" --repo "$repo" api "repos/$repo/statuses/$sha" "$@" >/dev/null 2>"$err_file"; then
  reason="$(head -1 "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  die 3 "could not post $CONTEXT=$state for $repo@${sha:0:7}${reason:+ — $reason}"
fi
rm -f "$err_file"

echo "qa-review-status: $repo@${sha:0:7} $CONTEXT=$state — $description"

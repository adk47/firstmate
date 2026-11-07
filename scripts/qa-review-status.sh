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
# The one refused write is narrow and is NOT that mode: a no-information failure
# (`CANNOT REVIEW: ` or `QA review could not be dispatched`) over a same-sha
# `success` GO (see the no-clobber guard below). `pending` re-arm and NO-GO
# overwrite are unchanged.
#
# Exit codes: 0 ok (including "posted, unverified" when the read-back itself
#             fails) | 2 usage | 3 post failed, or posted but the read-back
#             still does not show it (see the retry and read-back blocks below)
#
# Env: QA_GH override the identity shim. QA_STATUS_ATTEMPTS, QA_STATUS_BACKOFF_S,
#      QA_STATUS_READBACK_DELAY_S tune the POST retry and the read-back re-read.
#
# Whether a repo is gated at all is decided by the CALLER (the workflow reads
# .merge_gate_repos), not here: this script's job is to report a state whenever
# it is asked to, so the one place that decides "is this repo gated" stays the
# workflow and cannot drift between two readers.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_GH="${QA_GH:-$_here/qa-gh.sh}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
CONTEXT="qa-review"
# shellcheck source=lib/qa-policy.sh
source "$_here/lib/qa-policy.sh"

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

# Arming guard. On a gated repo the status MUST be posted by the App, because
# branch protection pins the required check to its app_id and a host-posted
# status can never satisfy that pin. The failure shape is the nastiest available:
# the POST succeeds, the UI shows a qa-review row, and the required check sits
# unsatisfied forever with nothing looking wrong. So refuse instead of posting.
#
# Mirror qa-gh.sh's FULL resolution order, not just app_repos — the kill switch
# and QA_GH_IDENTITY=host both outrank it. Otherwise arming the emergency
# rollback would silently make every open PR on a gated repo unmergeable.
# An unreadable or malformed policy must NOT read as "ungated and therefore fine
# to post": qa-gh.sh independently degrades the same bad policy to the host
# identity, so the two together would produce exactly the host-owned status that
# can never satisfy an App-pinned check — while this script returned 0.
qa_policy_valid "$POLICY" \
  || die 3 "cannot read or validate $POLICY — refusing to post $CONTEXT (fail closed; an unreadable policy must not read as 'ungated')."

# `|| gate_rc=$?` is load-bearing under `set -e`: qa_policy_has returns 1 for the
# perfectly normal "not in the list" case, and a bare call would abort the script.
gate_rc=0
qa_policy_has "$POLICY" '.merge_gate_repos' "$repo" || gate_rc=$?
[ "$gate_rc" -ne 2 ] || die 3 "cannot evaluate .merge_gate_repos in $POLICY — refusing to post $CONTEXT (fail closed)."
if [ "$gate_rc" -eq 0 ]; then
  host_flag="${QA_GH_HOST_FLAG:-/var/lib/hydra/qa-gh-host-identity}"
  if [ -e "$host_flag" ] || [ -L "$host_flag" ]; then
    die 3 "$repo is merge-gated but the host-identity kill switch ($host_flag) is active — a host-posted status cannot satisfy the app-pinned check. Remove the branch-protection pin before using the kill switch on a gated repo."
  fi
  if [ "${QA_GH_IDENTITY:-}" = "host" ]; then
    die 3 "$repo is merge-gated but QA_GH_IDENTITY=host forces the host identity — a host-posted status cannot satisfy the app-pinned check."
  fi
  app_rc=0
  qa_policy_has "$POLICY" '.identity.app_repos' "$repo" || app_rc=$?
  [ "$app_rc" -ne 2 ] || die 3 "cannot evaluate .identity.app_repos in $POLICY — refusing to post $CONTEXT (fail closed)."
  [ "$app_rc" -eq 0 ] || die 3 "$repo is in .merge_gate_repos but NOT in .identity.app_repos — the status would be posted by the host account and could never satisfy an app-pinned required check. Add it to app_repos first."
fi

# No-clobber for no-information failures (MUS-7698). A CANNOT REVIEW carries no
# information about the code: it says the review did not run. The sha is
# immutable, so a GO already recorded on it still describes this exact code, and
# overwriting it would turn a quota blip into an unmergeable sha. The
# un-dispatched failure qa-autoreview.yml posts when the gateway never took the
# job (2026-11-06) is the same kind of row -- it says even less -- and lands in
# the same re-run shape (PR Validation re-run on a GO'd sha, gateway down), so it
# is guarded by the same rule. Only these prefixes are guarded: a NO-GO is a
# finding and always overwrites. If the lookup fails, post as before: we cannot
# prove a GO exists, so we must not suppress. The GO must also be the CURRENT
# verdict: a `pending` re-arm after it makes it stale, so the newest informative
# row (neither prefix) has to be that GO itself, not merely some GO in history.
NO_INFO_PREFIXES=("CANNOT REVIEW: " "QA review could not be dispatched")
no_info_description() {   # <description> -> rc 0 when it starts with a guarded prefix
  local p; for p in "${NO_INFO_PREFIXES[@]}"; do [[ "$1" == "$p"* ]] && return 0; done; return 1
}
if [ "$state" = failure ] && no_info_description "$description"; then
  go_at="$("$QA_GH" --repo "$repo" api "repos/$repo/statuses/$sha?per_page=100" 2>/dev/null \
    | jq -r --args '[ .[]? | select(.context == "qa-review"
        and ((.description // "") as $d | any($ARGS.positional[]; . as $p | $d | startswith($p)) | not)) ] | first
        | select(. != null and .state == "success") | .created_at' "${NO_INFO_PREFIXES[@]}" 2>/dev/null)" || go_at=""
  if [ -n "$go_at" ]; then
    echo "qa-review-status: $repo@${sha:0:7} $CONTEXT=failure NOT posted — a GO recorded at $go_at stands on this sha; a no-information failure ('${description:0:40}…') does not overwrite it."
    exit 0
  fi
fi

# target_url is the "Details" link. On a REQUIRED check it is the operator's only
# in-UI route to why the gate is red, so pass it through when the caller has one.
set -- --method POST -f state="$state" -f context="$CONTEXT" -f description="$description"
[ -n "$target_url" ] && set -- "$@" -f target_url="$target_url"

# Capture stderr rather than discarding it: this one write decides mergeability,
# and "403 Resource not accessible by integration" (the app-pin misconfiguration)
# must not look identical to a network blip.
#
# Transient failures are retried (Fable QA eval 2026-10-20, F5: 11 of 258 verdicts
# posted their review but never their status, because one failed POST was the
# end of it). Up to QA_STATUS_ATTEMPTS (default 3) tries, waiting
# QA_STATUS_BACKOFF_S (default 2) x attempt seconds between them. ONLY a 5xx, a 429
# or a transport error is retried: a 4xx such as "403 Resource not accessible by
# integration" (the app-pin misconfiguration) or a 422 is a definite answer, and
# repeating it would only delay the exit-3 signal that something is misconfigured.
ATTEMPTS="${QA_STATUS_ATTEMPTS:-3}"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || ATTEMPTS=3
BACKOFF_S="${QA_STATUS_BACKOFF_S:-2}"
[[ "$BACKOFF_S" =~ ^[0-9]+$ ]] || BACKOFF_S=2
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT
attempt=0
while :; do
  attempt=$((attempt + 1))
  if "$QA_GH" --repo "$repo" api "repos/$repo/statuses/$sha" "$@" >/dev/null 2>"$err_file"; then
    break
  fi
  reason="$(head -1 "$err_file" 2>/dev/null)"
  # The code is taken from the WHOLE stderr: qa-gh.sh can print a notice line
  # (kill switch, token cache) before gh's "gh: <msg> (HTTP <code>)". No code at
  # all means the request never got an HTTP answer (DNS, TLS, reset): transient.
  code="$(grep -oE 'HTTP [0-9]{3}' "$err_file" 2>/dev/null || true)"
  code="${code%%$'\n'*}"; code="${code#HTTP }"
  transient=0
  case "$code" in 5??|429|"") transient=1 ;; esac
  if [ "$transient" = 0 ] || [ "$attempt" -ge "$ATTEMPTS" ]; then
    die 3 "could not post $CONTEXT=$state for $repo@${sha:0:7} after $attempt attempt(s)${reason:+ — $reason}"
  fi
  echo "qa-review-status: POST attempt $attempt/$ATTEMPTS for $repo@${sha:0:7} failed (${reason:-no HTTP answer}) — retrying in $((BACKOFF_S * attempt))s" >&2
  sleep "$((BACKOFF_S * attempt))"
done

# Read-back (F5: fail the step if the status is still missing). A 2xx is not
# proof the row is on THIS sha as the newest qa-review row. A read that itself
# fails is reported, not treated as missing: the POST answered 2xx, so the honest
# result is "posted, unverified" (exit 0 with a warning), not a failure that
# would invite a duplicate write. A read that misses the row is re-read once after
# QA_STATUS_READBACK_DELAY_S (default 2) seconds, so read-after-write lag does not
# turn a landed status into a false failure.
READBACK_DELAY_S="${QA_STATUS_READBACK_DELAY_S:-2}"
[[ "$READBACK_DELAY_S" =~ ^[0-9]+$ ]] || READBACK_DELAY_S=2
# 0 shown | 1 missing | 2 read failed
readback() {
  local rb
  rb="$("$QA_GH" --repo "$repo" api "repos/$repo/statuses/$sha?per_page=100" 2>/dev/null)" || return 2
  jq -e --arg c "$CONTEXT" --arg s "$state" --arg d "$description" \
      '([ .[]? | select(.context == $c) ] | first) as $r
       | $r != null and $r.state == $s and ($r.description // "") == $d' >/dev/null 2>&1 <<<"$rb" || return 1
}
rb_rc=0
readback || rb_rc=$?
if [ "$rb_rc" -eq 1 ]; then
  sleep "$READBACK_DELAY_S"
  rb_rc=0
  readback || rb_rc=$?
fi
case "$rb_rc" in
  1) die 3 "posted $CONTEXT=$state for $repo@${sha:0:7} (2xx) but the read-back does not show it as the newest $CONTEXT row — refusing to report success." ;;
  2) echo "qa-review-status: WARNING — posted $CONTEXT=$state for $repo@${sha:0:7} but could not read it back to verify." >&2 ;;
esac

echo "qa-review-status: $repo@${sha:0:7} $CONTEXT=$state — $description"

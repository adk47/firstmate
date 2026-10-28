#!/usr/bin/env bash
set -euo pipefail

# qa-handoff-publish.sh — publish CI's advisory QA hand-off onto the PULL REQUEST.
# ===========================================================================
# The producer half of T10 (see scripts/lib/qa-handoff.sh for the why). Reads the
# per-head reports that scripts/check-rebase-integrity.sh and
# scripts/check-blast-radius.sh just wrote, bundles them, and upserts ONE hidden
# PR comment per head. qa-pr-approve.sh Guards 8/9 and the QA review skill read
# that comment instead of /var/lib/hydra-qa — which does not exist on a QA
# gateway pod, and used to make every approval there refuse (fail closed).
#
# One comment per head, always from the CURRENT run: the publisher DELETES any
# earlier same-head hand-off before it posts, so a re-run can never leave the
# previous run's verdict standing (see the INVALIDATE block below for the two
# failure modes that makes safe). The timeline therefore does not grow with
# retries, and Guards 8/9 can never read evidence older than this run.
#
# Usage:
#   qa-handoff-publish.sh <owner/repo> <pr-number> <head-sha>
#                         [--state-dir DIR] [--dry-run]
#
#   --state-dir DIR  where the analyzers wrote (default: qa_handoff_root, i.e.
#                    /var/lib/hydra-qa when writable, else $RUNNER_TEMP/qa-handoff
#                    — the same resolution the analyzer steps use, so the two can
#                    never disagree about which directory holds this head's files)
#   --dry-run        print the comment body to stdout and post NOTHING
#
# Exit codes: 0 published (or nothing to publish) | 2 usage
#             3 a report was unreadable / malformed / described a different
#               head, and was therefore NOT published (the guard fails closed on
#               that kind) | 4 the encoded payload exceeds a PR comment's size
#               limit (nothing posted) | 5 the GitHub call failed
#
# Env (mainly for tests): GH  the gh binary (default gh); QA_HANDOFF_AUTHORS as
# for the reader (the publisher ONLY reuses comments from a trusted author —
# overwriting an untrusted look-alike would let it shadow the real hand-off).
#
# Advisory by design, like the analyzers: pr-validate.yml swallows a non-zero
# exit into an ::warning:: so a publish failure never fails CI. It must not:
# the guards are the fail-closed consumers, and a red CI on every PR would be a
# far worse failure than "QA auto-approval is unavailable, review it by hand".

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/qa-handoff.sh
. "$_here/lib/qa-handoff.sh"

GH_BIN="${GH:-gh}"
MAX_B64=60000   # PR comment bodies are capped at 65536 chars; leave headroom.

die() { echo "qa-handoff-publish: $2" >&2; exit "$1"; }

usage() {
  echo "usage: qa-handoff-publish.sh <owner/repo> <pr-number> <head-sha> [--state-dir DIR] [--dry-run]" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
repo="$1"; pr="$2"; head_sha="$3"; shift 3

state_dir=""
dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-dir) state_dir="${2:-}"; [ -n "$state_dir" ] || usage; shift 2 ;;
    --dry-run)   dry_run=1; shift ;;
    *) usage ;;
  esac
done

# Validate the key BEFORE it reaches a path, an API URL or a jq program: a short
# sha or a ref name would silently address a file nobody reads.
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name, got '$repo'"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || die 2 "head-sha must be a full 40-hex oid, got '$head_sha'"
[ -n "$state_dir" ] || state_dir="$(qa_handoff_root)"

slug="${repo//\//__}"
problems=0
missing_json='[]'
# The bundle is accumulated in a FILE, never in an argv. Linux caps a SINGLE argv
# string at MAX_ARG_STRLEN (128 KiB) whatever ARG_MAX says, so a report of a big
# PR passed as `--argjson r "$json"` made jq die with "Argument list too long"
# BEFORE the oversize guard below could refuse it — a crash where a clean
# refusal was promised (QA finding on this PR; macOS's higher limit hid it).
bundle_dir="$(mktemp -d "${TMPDIR:-/tmp}/qa-handoff-publish.XXXXXX")"
trap 'rm -rf "$bundle_dir"' EXIT
reports_file="$bundle_dir/reports.json"
printf '{}' >"$reports_file"

# invalidate_head — delete every trusted hand-off this PR holds for THIS head.
#
# Called BEFORE anything can early-exit, so a run that cannot publish still
# withdraws its head's earlier evidence: a head whose current run produced no
# report (or a report too big to carry) must not keep a previous run's verdict
# standing — Guards 8/9 would read that stale CLEAN as this head's evidence.
# A hand-off must never outlive the run that produced it (QA finding, round 1),
# and the two failure modes are both safe:
#   delete OK  + post fails → NO hand-off for this head → fall back to the
#                             on-disk report, else refuse (fail closed)
#   delete fails            → we do NOT post either, so no second comment can
#                             masquerade as the newer evidence; the step exits
#                             non-zero and CI goes red, which holds Guard 6
# Other heads' hand-offs are untouched on purpose: Guard 8's ack carry-forward
# NEEDS the prior heads' reports, so only this head is ever invalidated.
#
# Plain `gh` here, so NO --repo prefix: `gh api` rejects that flag, and the
# workflow token already scopes the call to this repo. (The guard, which calls
# the same library, DOES pass `--repo` because its identity shim consumes it.)
# Reading the PR's hand-offs first also proves the token can READ before we ask
# it to write, so a permissions problem reports cleanly here rather than as a
# 404-shaped surprise later.
# Sets PRIOR_IDS. Deliberately NOT called in a command substitution: `die` inside
# `$( )` exits only the subshell, so the caller would see an empty id list and
# carry on to POST — reintroducing the exact fail-open this exists to close.
invalidate_head() {
  local existing_ids cid
  PRIOR_IDS=""
  # --dry-run is a READ-ONLY mode: it prints the body it would post and mutates
  # nothing, so it must not withdraw a live hand-off either.
  [ "$dry_run" = 1 ] && return 0
  # shellcheck disable=SC2034  # consumed by scripts/lib/qa-handoff.sh (sourced above)
  QA_HANDOFF_GH=("$GH_BIN")
  # NO command substitution around the fetch: the failure signal lives in a
  # global, and a subshell would discard it. An unreadable comment list MUST NOT
  # read as "there is nothing to withdraw" — that is exactly how a previous run's
  # CLEAN comment survives a rerun whose analyzers produced nothing, with a green
  # CI (QA finding, round 5).
  qa_handoff_payloads "$repo" "$pr" >"$bundle_dir/handoffs.ndjson" 2>/dev/null || true
  if [ "${QA_HANDOFF_READ_RC:-2}" != "0" ]; then
    echo "qa-handoff-publish: cannot read this PR's existing hand-offs — refusing to publish, because I cannot prove I withdrew this head's previous one" >&2
    die 5 "could not read the PR's hand-offs (token/network); nothing published for ${head_sha:0:7}"
  fi
  existing_ids="$(qa_handoff_comment_ids "$(cat "$bundle_dir/handoffs.ndjson")" \
    "$repo" "$pr" "$head_sha")"
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    [[ "$cid" =~ ^[0-9]+$ ]] || die 5 "refusing to delete a non-numeric comment id '$cid'"
    "$GH_BIN" api --method DELETE "repos/$repo/issues/comments/$cid" >/dev/null 2>&1 || {
      echo "qa-handoff-publish: could not delete the previous hand-off comment $cid for this head — NOT publishing a second one (the old one is untrusted now)" >&2
      die 5 "could not invalidate hand-off comment $cid; nothing published for ${head_sha:0:7}"
    }
  done <<<"$existing_ids"
  PRIOR_IDS="$existing_ids"
}

# collect <kind> <path> — validate one report and fold it into the payload.
# A report whose interior key does not describe THIS head is a mis-file, not a
# hand-off: publishing it would let Guard 8/9 approve on another PR's evidence.
collect() {
  local kind="$1" path="$2" key_ok
  if [ ! -r "$path" ]; then
    echo "qa-handoff-publish: no $kind report at $path (analyzer did not run — not publishing that kind)" >&2
    missing_json="$(printf '%s' "$missing_json" | jq -c --arg k "$kind" '. + [$k]')"
    return 0
  fi
  if ! jq -ce . "$path" >/dev/null 2>&1; then
    echo "qa-handoff-publish: $kind report at $path is not valid JSON — NOT publishing it" >&2
    missing_json="$(printf '%s' "$missing_json" | jq -c --arg k "$kind" '. + [$k]')"
    problems=$((problems + 1))
    return 0
  fi
  key_ok="$(jq -r --arg repo "$repo" --arg pr "$pr" --arg head "$head_sha" '
      if (.repo == $repo) and ((.pr | tostring) == $pr) and (.head_sha == $head)
      then "OK" else "MISMATCH" end' "$path" 2>/dev/null || echo ERR)"
  if [ "$key_ok" != "OK" ]; then
    echo "qa-handoff-publish: $kind report at $path does not describe $repo#$pr @ ${head_sha:0:7} ($key_ok) — NOT publishing it" >&2
    missing_json="$(printf '%s' "$missing_json" | jq -c --arg k "$kind" '. + [$k]')"
    problems=$((problems + 1))
    return 0
  fi
  # acc + report, BOTH as files: no size limit applies to file inputs.
  if jq -c -s --arg k "$kind" '.[0] as $a | .[1] as $r | $a + {($k): $r}' \
       "$reports_file" "$path" >"$reports_file.new" 2>/dev/null; then
    mv "$reports_file.new" "$reports_file"
  else
    echo "qa-handoff-publish: could not fold the $kind report into the payload — NOT publishing it" >&2
    missing_json="$(printf '%s' "$missing_json" | jq -c --arg k "$kind" '. + [$k]')"
    problems=$((problems + 1))
  fi
}

collect rebase-integrity "$state_dir/rebase-integrity/$slug-pr-$pr-$head_sha.json"
collect blast-radius     "$state_dir/blast-radius/$slug-pr-$pr-$head_sha.json"

# Withdraw this head's earlier evidence FIRST (see invalidate_head). Deliberately
# before the "nothing to publish" exit: no report for this head is NOT "keep the
# last run's".
PRIOR_IDS=""
invalidate_head
prior_ids="$PRIOR_IDS"

if [ "$(jq -c 'keys | length' "$reports_file")" = "0" ]; then
  # Nothing ran (a step before the analyzers failed, or this runner never got
  # that far). Posting an empty hand-off would only add timeline noise; the
  # guard's behaviour is the safe one either way, because the head now holds NO
  # hand-off: no report → fall back to the on-disk report → refused where a
  # report is required. Say so in the log instead of on the PR.
  echo "qa-handoff-publish: nothing to publish for $repo#$pr @ ${head_sha:0:7} (no analyzer reports under $state_dir)$([ -n "$prior_ids" ] && echo "; withdrew the earlier hand-off for this head")"
  exit 0
fi

payload="$(jq -cn --arg repo "$repo" --argjson pr "$pr" --arg head "$head_sha" \
  --slurpfile reports "$reports_file" --argjson missing "$missing_json" '
    {version: 1, repo: $repo, pr: $pr, head_sha: $head,
     generated_at: (now | todate), reports: $reports[0], missing: $missing}')"

b64="$(printf '%s' "$payload" | qa_handoff_encode -)"
[ -n "$b64" ] || die 3 "could not encode the hand-off payload"
if [ "${#b64}" -gt "$MAX_B64" ]; then
  die 4 "encoded hand-off is ${#b64} chars (> $MAX_B64) — a PR comment cannot carry it. Signals: $(jq -r 'to_entries | map("\(.key)=\(.value.signals | length // 0)") | join(", ")' "$reports_file" 2>/dev/null || echo unknown). Nothing posted, and any earlier hand-off for this head was withdrawn; the guard will fail closed on hydra."
fi
body="$(qa_handoff_body "$b64")"

if [ "$dry_run" = 1 ]; then
  printf '%s\n' "$body"
  exit 0
fi

# Upsert. Reading the PR's hand-offs first also proves the token can read before
# we ask it to write, so a permissions problem reports as a clean failure here
# rather than a 404-shaped surprise later.
# Plain `gh` here, so NO --repo prefix: `gh api` rejects that flag, and the
# workflow token already scopes the call to this repo. (The guard, which calls the
# same library, DOES pass `--repo` because its identity shim consumes it.)
# The comment body itself stays an argv to jq: MAX_B64 is set so the encoded body
# cannot approach MAX_ARG_STRLEN, which is exactly why that cap exists.
tmp="$bundle_dir/comment.json"
jq -n --arg body "$body" '{body: $body}' >"$tmp"

"$GH_BIN" api --method POST \
  "repos/$repo/issues/$pr/comments" --input "$tmp" --jq '.id' >/dev/null \
  || die 5 "could not create the hand-off comment; this head now has NO hand-off (fail closed)"
action="posted a comment"
[ -z "$prior_ids" ] || action="replaced $(printf '%s\n' "$prior_ids" | grep -c .) previous hand-off / posted a comment"

echo "qa-handoff-publish: $repo#$pr @ ${head_sha:0:7} → $action ($(jq -r 'keys | join("+")' "$reports_file"), ${#body} B)"
[ "$problems" -eq 0 ] || die 3 "$problems report(s) were skipped (see above) — those kinds are unverified for this head"
exit 0

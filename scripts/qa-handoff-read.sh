#!/usr/bin/env bash
set -euo pipefail

# qa-handoff-read.sh — read CI's advisory QA hand-off off the PULL REQUEST.
# ===========================================================================
# The consumer-side CLI for T10 (see scripts/lib/qa-handoff.sh for the why). It
# prints one head's report, or the other heads of the PR that carry a given
# warn_digest, without touching /var/lib/hydra-qa. Three callers use it:
#
#   * the QA review skill (skills-all/muso-github-code-review, Steps 3d/3e) —
#     a QA gateway pod has no CI host directory, and `muso gh review-bundle`'s
#     rebaseIntegrity field is host-parsed, so on a pod the bundle reads null and
#     the skill would hold approval on every hydra PR;
#   * a human debugging "why did Guard 8 refuse this PR?" (it prints exactly the
#     report the guard graded, so the answer is not a matter of trust);
#   * tests.
#
# Usage:
#   qa-handoff-read.sh <owner/repo> <pr> <kind> [--head <40-hex>] [--digest <64-hex>] [--pretty]
#
#   <kind>       rebase-integrity | blast-radius
#   --head       the head to read (default: the PR's current headRefOid). Reading
#                a PRIOR head is how you inspect why a warning carried/refused.
#   --digest     print the head shas of this PR whose <kind> report is WARN with
#                that warn_digest (the ack carry-forward query — replaces the old
#                on-disk `grep -l <digest> rebase-integrity/*.json` glob). Pass
#                --head too and that head is excluded, i.e. "OTHER heads only".
#   --pretty     jq-formatted output instead of one line.
#
# Exit codes: 0 printed | 1 no hand-off (nothing on the PR for that head/digest —
#              for hydra that is a failed hand-off, not "clean") | 2 usage |
#              3 the GitHub read failed (transient: token, network, 5xx).
#
# Env (mainly for tests): GH the gh binary (default gh); QA_HANDOFF_AUTHORS as for
# the reader — a hand-off is only accepted from a trusted author.

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/qa-handoff.sh
. "$_here/lib/qa-handoff.sh"

GH_BIN="${GH:-gh}"

die() { echo "qa-handoff-read: $2" >&2; exit "$1"; }
usage() {
  echo "usage: qa-handoff-read.sh <owner/repo> <pr> <kind> [--head <sha40>] [--digest <hex64>] [--pretty]" >&2
  exit 2
}

[ "$#" -ge 3 ] || usage
repo="$1"; pr="$2"; kind="$3"; shift 3
head_sha=""; digest=""; pretty=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)   head_sha="${2:-}"; [ -n "$head_sha" ] || usage; shift 2 ;;
    --digest) digest="${2:-}";   [ -n "$digest" ]   || usage; shift 2 ;;
    --pretty) pretty=1; shift ;;
    *) usage ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name, got '$repo'"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'"
case "$kind" in
  rebase-integrity|blast-radius) ;;
  *) die 2 "kind must be rebase-integrity or blast-radius, got '$kind'" ;;
esac
if [ -n "$head_sha" ]; then
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || die 2 "head must be a full 40-hex oid, got '$head_sha'"
fi
if [ -n "$digest" ]; then
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die 2 "digest must be a 64-hex warn_digest, got '$digest'"
fi

# A read that fails must not look like "no hand-off": exit 1 sends the caller to
# "there is no report" (a refusal for hydra), and a transient GitHub failure is
# a different sentence in the review body ("could not read", re-run).
if [ -z "$head_sha" ] && [ -z "$digest" ]; then
  head_sha="$("$GH_BIN" pr view "$pr" --repo "$repo" \
    --json headRefOid --jq .headRefOid 2>/dev/null || true)"
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
    || die 3 "could not read a valid headRefOid for $repo#$pr (got '$head_sha')"
fi

# Plain `gh`: `gh api` does not accept --repo (only the guard's identity shim
# consumes it), so the prefix here is just the binary.
# shellcheck disable=SC2034  # consumed by scripts/lib/qa-handoff.sh (sourced above)
QA_HANDOFF_GH=("$GH_BIN")
# No command substitution around the fetch: QA_HANDOFF_READ_RC (set by the
# library) is how an UNREADABLE GitHub is told apart from "no hand-off yet" — two
# states the reader must not conflate in its exit code, because the caller's next
# move differs ("re-run CI" vs "re-run with a working token"). Exit 1 is the
# documented "no hand-off"; exit 3 is the documented "could not read".
READTMP="$(mktemp "${TMPDIR:-/tmp}/qa-handoff-read.XXXXXX")"
trap 'rm -f "$READTMP"' EXIT
qa_handoff_payloads "$repo" "$pr" >"$READTMP" 2>/dev/null || true
if [ "${QA_HANDOFF_READ_RC:-2}" != "0" ]; then
  die 3 "could not read $repo#$pr (token, network or a GitHub error) — this is NOT \"no hand-off\"; retry, and treat it as unverified until you get one"
fi
all="$(cat "$READTMP")"
if [ -z "$all" ]; then
  # Readable, but no trusted hand-off on this PR: either CI has not published for
  # this head yet, or the only comments are untrusted/undecodable.
  comments="$(qa_handoff_comments "$repo" "$pr")"
  if [ "$comments" = "[]" ]; then
    echo "qa-handoff-read: no QA hand-off comment on $repo#$pr (CI either has not run on this head yet, or could not publish one)" >&2
  else
    echo "qa-handoff-read: comments are readable but none is a trusted, decodable hand-off — treating as NO HAND-OFF (fail closed)" >&2
  fi
  exit 1
fi

if [ -n "$digest" ]; then
  # Carry-forward lookup: WARN reports of OTHER heads carrying the same digest.
  # Byte-identical flagged LINES only — the digest never covers summaries.
  # -s: $all is NDJSON (one object per hand-off), so slurp before iterating.
  # With --head also given, that head is EXCLUDED — the caller wants the OTHER
  # heads of the PR (the carry-forward question Guard 8 asks). Without --head
  # every matching head is listed, which is the old on-disk glob's semantics.
  out="$(printf '%s\n' "$all" | jq -rs --arg repo "$repo" --arg pr "$pr" \
    --arg kind "$kind" --arg d "$digest" --arg head "$head_sha" '
      .[] | select(.repo == $repo and .pr == $pr)
      | (.reports[$kind] // {}) as $r
      | select($r.status == "WARN" and $r.warn_digest == $d)
      | select($head == "" or ($r.head_sha // "") != $head)
      | $r.head_sha // empty
    ' 2>/dev/null || true)"
else
  out="$(qa_handoff_report "$all" "$repo" "$pr" "$kind" "$head_sha")"
  out="$(printf '%s' "$out" | jq -c . 2>/dev/null || true)"
fi

if [ -z "$out" ]; then
  if [ -n "$digest" ]; then
    echo "qa-handoff-read: no other head of $repo#$pr has a WARN $kind report with that digest" >&2
  else
    echo "qa-handoff-read: no $kind hand-off for $repo#$pr @ ${head_sha:0:7} — CI either has not published one for this head, or it failed (for hydra that is a failed hand-off, not a clean one)" >&2
  fi
  exit 1
fi

if [ "$pretty" = 1 ] && [ -z "$digest" ]; then
  printf '%s\n' "$out" | jq .
else
  printf '%s\n' "$out"
fi

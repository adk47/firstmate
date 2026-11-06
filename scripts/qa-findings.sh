#!/usr/bin/env bash
set -euo pipefail

# qa-findings.sh — read a PR's QA verdict AND its finding text, always.
# ======================================================================
# Why this exists: on 2026-11-03 three separate lanes concluded that the QA bot
# had published a NO-GO with no finding text anywhere (hydra#1545 06:37Z,
# hydra#1636 12:12Z, hydra#1643 15:06Z+15:42Z). Every one of those verdicts was
# fully written — as a REVIEW BODY — and every reader missed it for the same
# mechanical reason: `GET /repos/:o/:r/pulls/:n/reviews` is paginated at 30 per
# page, OLDEST FIRST, so on a PR with >30 reviews the newest verdicts are simply
# absent from an unpaginated read (measured: #1545 = review 37 of 55, #1636 =
# review 34 of 40, #1643 = review 39 of 39). A review that files no inline
# comments leaves nothing in `pulls/:n/comments` either, and a commit status has
# no body field, so "no finding text anywhere" was the honest conclusion from
# every surface a reader was actually using.
#
# So: one command that reads through the pagination, names the page the finding
# text lives on, and prints the body. Anything that needs to answer "what did QA
# say about this PR?" should call this instead of hand-rolling an API read.
#
# Three further traps this script is built around (qa-review on #1667):
#   1. HEAD. The head to report on is the PR's CURRENT head, read from the PR
#      itself — NOT the newest review's `commit_id`. Taking the latter means that
#      after a push, before the new review lands, this reports a prior head's
#      verdict as if it were current. Exit 5 distinguishes that case loudly.
#   2. AUTHOR. "The newest review with a body" is not "the QA verdict". A human
#      review posted after QA on the same commit would win, and an automated
#      caller would act on a person's prose. QA verdicts are recognised by the
#      mandated lead body marker (`🤖 Muso QA Bot (automated review)`), with the
#      policy's `.identity.bot_logins` as the author allowlist; a review carrying
#      the marker from an unlisted login is accepted but flagged UNTRUSTED.
#   3. PAGINATION. `gh api --paginate --jq <filter>` applies the filter PER PAGE,
#      so any aggregate in --jq answers page 1 again. This script therefore never
#      filters in --jq: it slurps the raw pages and filters locally.
#
# Usage:
#   qa-findings.sh <owner/repo> <pr> [--head <sha>] [--json] [--limit <n>] [--any-author]
#
#   --head <sha>   report on this head instead of the PR's current head.
#   --json         machine-readable: one object, body included.
#   --limit <n>    how many candidate reviews to show in the human output
#                  (default 3, newest first).
#   --any-author   accept a review from ANY author. Escape hatch for a repo whose
#                  QA writer does not use the marker; warns, and flags the author.
#
# Exit codes:
#   0  a QA review body was found ON the requested head and printed
#   2  usage
#   3  the API read failed (never reported as "no findings": an unreadable list
#      is not an empty one)
#   4  no QA review body exists on this PR — the verdict, if any, is status-only.
#      Statuses are printed so the caller can see the description; this is the
#      case the QA bot must never produce, and the one it must be able to report.
#   5  no QA review body on the REQUESTED head; only prior-head text exists. The
#      prior-head text IS printed, labelled PRIOR HEAD — reading it as the
#      current verdict is the bug this exit code exists to prevent. Typical after
#      a push, before QA re-reviews, or when the dispatch was lost.
#   6  QA marker text exists only from an author outside the allowlist. The text IS
#      printed, labelled UNTRUSTED AUTHOR, so a human can read it; normal mode just
#      refuses to present a human's prose as the automated verdict. Precedence: a
#      CURRENT-head untrusted body is reported (6) ahead of a prior-head trusted
#      body (5), because the current head is what was asked about.
#
# Env:
#   QA_FINDINGS_GH        gh binary (tests override this)
#   QA_FINDINGS_AUTHORS   comma-separated logins to ADD to the allowlist
#   QA_FINDINGS_MARKER_A  marker substring 1 (default "Muso QA Bot")
#   QA_FINDINGS_MARKER_B  marker substring 2 (default "automated review")
#   QA_APPROVAL_POLICY    path to policies/qa-approval-policy.json

usage() {
  cat >&2 <<'USAGE'
usage: qa-findings.sh <owner/repo> <pr> [--head <sha>] [--json] [--limit <n>] [--any-author]
  Prints the QA review on the requested head (body + permalink + the PAGE it
  lives on, so a reader who tried an unpaginated read knows why they missed it).
USAGE
}
die() { echo "qa-findings: $2" >&2; exit "$1"; }
log() { echo "qa-findings: $*" >&2; }

GH="${QA_FINDINGS_GH:-gh}"
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"

[ "$#" -ge 2 ] || { usage; exit 2; }
repo="$1"; pr="$2"; shift 2
head=""; json=0; limit=3; anyauthor=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --head)  [ "$#" -ge 2 ] || { usage; exit 2; }; head="$2"; shift 2 ;;
    --json)  json=1; shift ;;
    --limit) [ "$#" -ge 2 ] || { usage; exit 2; }; limit="$2"; shift 2 ;;
    --any-author) anyauthor=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "findings: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be owner/name, got '$repo'"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr must be numeric, got '$pr'"
[ -z "$head" ] || [[ "$head" =~ ^[0-9a-fA-F]{7,40}$ ]] || die 2 "head must be hex, got '$head'"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] \
  || die 2 "--limit must be a positive integer, got '$limit' (0 would hide the finding text instead of limiting how much of it is shown)"

markerA="${QA_FINDINGS_MARKER_A:-Muso QA Bot}"
markerB="${QA_FINDINGS_MARKER_B:-automated review}"

# The author allowlist is the QA policy's, not a hard-coded guess: the bot has
# reviewed under more than one login across the App cutover (REST reports
# `muso-qa-bot[bot]`, GraphQL reports `muso-qa-bot`, and PRs in flight from the
# host account carry `adk47`). An unreadable/missing policy falls back to that
# same set rather than to "no authors" — the marker check still has to pass.
authors='["muso-qa-bot","muso-qa-bot[bot]","adk47"]'
if [ -r "$POLICY" ]; then
  from_policy="$(jq -c '.identity.bot_logins // empty
      | if type == "array" and length > 0 and all(.[]; type == "string")
        then . else empty end' "$POLICY" 2>/dev/null || true)"
  [ -z "$from_policy" ] || authors="$from_policy"
fi
if [ -n "${QA_FINDINGS_AUTHORS:-}" ]; then
  authors="$(jq -cn --argjson base "$authors" --arg extra "$QA_FINDINGS_AUTHORS" \
    '($base + ($extra | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))))
     | unique')" || die 3 "could not merge QA_FINDINGS_AUTHORS"
fi
if [ "$anyauthor" -eq 1 ]; then
  log "WARNING: --any-author — the QA marker check is OFF; any nonempty review body counts as a verdict"
fi

raw="$("$GH" api --paginate "repos/$repo/pulls/$pr/reviews?per_page=100" 2>/dev/null)" \
  || die 3 "could not read reviews for $repo#$pr (that is an unreadable list, NOT an empty one)"
[ -n "$raw" ] || raw='[]'

# --paginate emits one JSON document per page; slurp and flatten. A non-array
# page is an error object, never a review list — treat it as a read failure
# rather than printing "no findings". Filtering happens HERE, after the slurp:
# a --jq filter in the gh call would be applied per page and answer page 1.
reviews="$(printf '%s\n' "$raw" | jq -cs '
    if (map(type == "array") | all) then (add // []) else error("non-array page") end
  ' 2>/dev/null)" || die 3 "reviews response for $repo#$pr did not parse (unreadable, not empty)"

total="$(printf '%s' "$reviews" | jq 'length')"
pages=$(( (total + 29) / 30 ))   # GitHub's default page size, for the report only
[ "$pages" -ge 1 ] || pages=1

# Which head are we reporting on? The PR's CURRENT head by default — reading it
# from the reviews instead reports a prior head as current after a push.
head_source="pr"
if [ -n "$head" ]; then
  head_source="explicit"
else
  head="$("$GH" api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null || true)"
  [ -n "$head" ] \
    || die 3 "could not read the current head of $repo#$pr (unreadable, not absent) — pass --head <sha> to report on a known head"
fi

# Statuses are the OTHER surface the verdict can hide on. Always read them: when
# no review body exists they are all that is left, and their description is what
# a reader saw. Read failures here are not fatal (they only decorate the report).
read_statuses() { # <sha> -> JSON array on stdout
  local sha="$1" st_raw
  st_raw="$("$GH" api --paginate "repos/$repo/commits/$sha/statuses?per_page=100" 2>/dev/null || true)"
  [ -n "$st_raw" ] || { printf '[]'; return 0; }
  printf '%s\n' "$st_raw" | jq -cs '
      if (map(type == "array") | all) then (add // []) else [] end
      | [ .[] | select(.context == "qa-review") ]
      | sort_by(.created_at) | reverse
    ' 2>/dev/null || printf '[]'
}
statuses="$(read_statuses "$head")"

# Candidates: QA review bodies only, newest first. `page` is the 30-per-page page
# a naive unpaginated read would land them on — the whole point being that a
# page-2 verdict is invisible to such a read. `on_head` splits "the current
# verdict" from "text from a head that has been superseded".
#
# In NORMAL mode a verdict needs the mandated lead-body marker AND an allowlisted
# author. The marker alone is not enough: a human review that quotes the marker
# would otherwise be selected as the QA verdict and an automated caller would act
# on a person's prose. Marker text from an unlisted login is NOT discarded — it is
# collected into `untrusted` so the run can fail LOUD with a pointer to
# --any-author instead of reporting "no findings".
split="$(printf '%s' "$reviews" | jq -c \
  --arg head "$head" --argjson limit "$limit" --argjson anyauthor "$anyauthor" \
  --arg markerA "$markerA" --arg markerB "$markerB" --argjson authors "$authors" '
  def nonempty:
    (((.body // "") | gsub("[[:space:]]"; "") | length) > 0);
  def has_marker:
    (((.body // "") | test($markerA; "i")) and ((.body // "") | test($markerB; "i")));
  def trusted_author:
    (((.user.login // "") as $l | ($authors | index($l)) != null));
  def is_qa:
    nonempty and (($anyauthor == 1) or (has_marker and trusted_author));
  def is_untrusted_marker:
    ($anyauthor == 0) and nonempty and has_marker and (trusted_author | not);
  [ range(0; length) as $i | { i: $i, r: .[$i] } ]
  | map(. + {
      page: (((.i / 30) | floor) + 1),
      on_head: (((.r.commit_id // "")[0:7]) == ($head[0:7])),
      author_trusted: (.r | trusted_author),
      qa: (.r | is_qa),
      untrusted: (.r | is_untrusted_marker)
    })
  | sort_by(.i) | reverse
  # Existence is computed on the UNSLICED lists: slicing here would let --limit
  # (or 0) decide whether a finding "exists", turning a display knob into a
  # false "no findings" answer. --limit is applied only where text is printed.
  | { total_qa: (map(select(.qa)) | length),
      on_head: (map(select(.qa and .on_head))),
      prior:   (map(select(.qa and (.on_head | not)))),
      untrusted: (map(select(.untrusted and .on_head))),
      untrusted_prior: (map(select(.untrusted and (.on_head | not)))),
      newest_prior_head: ((map(select(.qa and (.on_head | not)) | .r.commit_id) | .[0]) // ""),
      # Trust is resolved by ORDER, not by category. An allowlisted bot posting a
      # GO and a newly-unlisted login posting a NO-GO on the SAME commit is a
      # stale verdict if the trusted one wins merely for being trusted: the newer
      # NO-GO is the current state of that head. So the newest marker review on
      # the head decides, and only then does cross-head precedence apply.
      same_head_markers: (map(select((.qa or .untrusted) and .on_head))),
      prior_markers: (map(select((.qa or .untrusted) and (.on_head | not)))),
      newest_same_head_untrusted: ((map(select((.qa or .untrusted) and .on_head)) | (.[0] // null)) | if . == null then false else .untrusted end),
      newest_prior_untrusted: ((map(select((.qa or .untrusted) and (.on_head | not))) | (.[0] // null)) | if . == null then false else .untrusted end) }
')" || die 3 "could not process reviews for $repo#$pr"

found="$(printf '%s' "$split" | jq '.on_head | length')"
prior_found="$(printf '%s' "$split" | jq '.prior | length')"
untrusted_found="$(printf '%s' "$split" | jq '.untrusted | length')"
untrusted_prior_found="$(printf '%s' "$split" | jq '.untrusted_prior | length')"
prior_head="$(printf '%s' "$split" | jq -r '.newest_prior_head')"
newest_same_head_untrusted="$(printf '%s' "$split" | jq -r '.newest_same_head_untrusted')"
newest_prior_untrusted="$(printf '%s' "$split" | jq -r '.newest_prior_untrusted')"
[ -z "$prior_head" ] || prior_statuses="$(read_statuses "$prior_head")"
prior_statuses="${prior_statuses:-[]}"

if [ "$json" -eq 1 ]; then
  # Precedence matters: a current-head untrusted body must be surfaced (6)
  # before falling back to prior-head text (5), or the current finding is hidden.
  # Within a head the NEWEST marker review decides. Trust is a category, not a
  # recency claim: if an allowlisted GO is followed by an unlisted NO-GO on the
  # same commit, the GO is the stale body.
  if [ "$found" -gt 0 ] && [ "$newest_same_head_untrusted" != "true" ]; then reason="ok"
  elif [ "$untrusted_found" -gt 0 ]; then reason="untrusted_author_only"
  elif [ "$prior_found" -gt 0 ] && [ "$newest_prior_untrusted" != "true" ]; then reason="prior_head_only"
  elif [ "$untrusted_prior_found" -gt 0 ]; then reason="untrusted_author_prior_head_only"
  else reason="no_review_body"; fi
  jq -n --arg repo "$repo" --arg pr "$pr" --arg head "$head" --arg source "$head_source" \
        --arg reason "$reason" --arg prior_head "$prior_head" \
        --argjson total "$total" --argjson pages "$pages" --argjson limit "$limit" \
        --argjson total_qa "$(printf '%s' "$split" | jq '.total_qa')" \
        --argjson cands "$(printf '%s' "$split" | jq -c '.on_head')" \
        --argjson prior "$(printf '%s' "$split" | jq -c '.prior')" \
        --argjson untrusted "$(printf '%s' "$split" | jq -c '.untrusted')" \
        --argjson untrusted_prior "$(printf '%s' "$split" | jq -c '.untrusted_prior')" \
        --argjson same_head_markers "$(printf '%s' "$split" | jq -c '.same_head_markers')" \
        --argjson statuses "$statuses" --argjson prior_statuses "$prior_statuses" '
    def view: { id: .r.id, review_index: (.i + 1), page: .page,
                html_url: .r.html_url, submitted_at: .r.submitted_at,
                user: (.r.user.login // "?"), state: .r.state,
                on_head: .on_head, author_trusted: .author_trusted,
                body: .r.body };
    def st: map({state, description, created_at, target_url});
    { repo: $repo, pr: ($pr | tonumber), head: $head, head_source: $source,
      reason: $reason,
      reviews_total: $total, review_pages: $pages, qa_reviews_total: $total_qa,
      on_head: ($cands | length > 0),
      statuses: ($statuses | st),
      # "latest" is the newest marker review on the head WHATEVER its author, so a
      # caller can never read an older trusted GO as the latest word when a newer
      # unlisted NO-GO is sitting on top of it. `author_trusted` tells them which.
      latest: (($same_head_markers[0] // null) | if . == null then null else view end),
      latest_untrusted: (($same_head_markers[0] // null) | if . == null then false else .untrusted end),
      candidates: ($cands[0:$limit] | map(view)),
      untrusted_candidates: ($untrusted[0:$limit] | map(view)),
      untrusted_prior_candidates: ($untrusted_prior[0:$limit] | map(view)),
      prior_head: ($prior_head | if . == "" then null else
        { head: ., statuses: ($prior_statuses | st),
          candidates: ($prior[0:$limit] | map(view)) } end) }
  '
  case "$reason" in
    ok) exit 0 ;;
    prior_head_only) exit 5 ;;
    untrusted_author_only | untrusted_author_prior_head_only) exit 6 ;;
    *) exit 4 ;;
  esac
fi

echo "qa-findings: $repo#$pr head ${head:0:8} ($head_source) — $total review(s), ~$pages page(s) at 30/page (oldest-first)"
if [ "$(printf '%s' "$statuses" | jq 'length')" -gt 0 ]; then
  printf '%s' "$statuses" | jq -r '
    .[] | "  qa-review status \(.created_at) \(.state) [\(.description // "")]"
  '
fi

print_cands() { # <json-array> <label>
  printf '%s' "$1" | jq -r --arg label "$2" --argjson total "$total" --argjson limit "$limit" '
    .[0:$limit] | .[] | "--- \($label)review #\(.i + 1) of \($total), page \(.page) | \(.r.state) | \(.r.submitted_at) | \(.r.user.login // "?")\(if .author_trusted then "" else " (UNTRUSTED AUTHOR — not in .identity.bot_logins)" end)",
          "    \(.r.html_url)",
          ((.r.body // "") | if . == "" then "    (empty body)" else . end),
          ""
  '
}

# Exit 0 only when the NEWEST marker on this head is trusted. An allowlisted GO
# with a newer unlisted NO-GO on top of it is the stale verdict this script
# exists to prevent, so the newer NO-GO falls through to the exit-6 branch.
if [ "$found" -gt 0 ] && [ "$newest_same_head_untrusted" != "true" ]; then
  print_cands "$(printf '%s' "$split" | jq -c '.on_head')" ""
  first_page="$(printf '%s' "$split" | jq -r '.on_head[0].page')"
  if [ "$first_page" -gt 1 ]; then
    log "the newest finding text lives on page $first_page — an unpaginated read of pulls/$pr/reviews returns page 1 only and would report NO findings"
  fi
  exit 0
fi

# A CURRENT-head untrusted body outranks PRIOR-head trusted text: the current
# head is what was asked about, and exiting 5 here would silently omit the
# finding that is actually attached to the head under review.
if [ "$untrusted_found" -gt 0 ]; then
  cat >&2 <<MSG
qa-findings: QA MARKER TEXT EXISTS ON THE REQUESTED HEAD ${head:0:8} ($head_source)
  AND ITS NEWEST OCCURRENCE IS FROM AN UNLISTED AUTHOR.
  Found $untrusted_found review(s) carrying the QA lead-body marker whose login is
  NOT in policies/qa-approval-policy.json .identity.bot_logins (nor in the
  QA_FINDINGS_AUTHORS fallback). Normal mode refuses to present that text as the QA
  verdict, because a human review quoting the marker would otherwise be read as an
  automated verdict by an automated caller.
  Order decides, not the author category: a NEWER unlisted marker outranks an OLDER
  allowlisted one on the same commit, because the older one is then the stale body.
  If this really is your QA writer under a new login, add that login to the policy's
  .identity.bot_logins (the durable fix) or re-run with --any-author to accept it now.
  Nothing is hidden: the unlisted-author text is printed below, and any OLDER trusted
  text on this head follows it, labelled.
MSG
  print_cands "$(printf '%s' "$split" | jq -c '.untrusted')" "UNTRUSTED AUTHOR "
  if [ "$found" -gt 0 ]; then
    print_cands "$(printf '%s' "$split" | jq -c '.on_head')" "OLDER TRUSTED ON THIS HEAD "
  elif [ "$prior_found" -gt 0 ] && [ "$newest_prior_untrusted" != "true" ]; then
    echo "  NOTE: trusted QA text also exists on PRIOR head ${prior_head:0:8}; read it with --head $prior_head." >&2
  fi
  exit 6
fi

# Order decides on the prior head too. If the newest marker there is untrusted,
# this branch must NOT fire: exiting 5 here would print only the older trusted GO
# and omit the newer NO-GO, the same masking QA flagged on the current head. That
# case falls through to the untrusted_prior branch, which prints both.
if [ "$prior_found" -gt 0 ] && [ "$newest_prior_untrusted" != "true" ]; then
  cat >&2 <<MSG
qa-findings: NO QA REVIEW BODY ON THE REQUESTED HEAD ${head:0:8} ($head_source).
  The newest QA text is on PRIOR head ${prior_head:0:8}. That means a push landed and
  QA has not reviewed the new head yet, or its dispatch was lost. Do NOT read the
  prior verdict as the current one. Re-run QA for ${head:0:8}, or read the prior
  verdict deliberately with --head $prior_head.
  The prior-head text is printed below, labelled PRIOR HEAD.
MSG
  if [ "$(printf '%s' "$prior_statuses" | jq 'length')" -gt 0 ]; then
    printf '%s' "$prior_statuses" | jq -r '
      .[] | "  PRIOR HEAD qa-review status \(.created_at) \(.state) [\(.description // "")]"
    ' >&2
  fi
  print_cands "$(printf '%s' "$split" | jq -c '.prior')" "PRIOR HEAD "
  exit 5
fi

if [ "$untrusted_prior_found" -gt 0 ]; then
  cat >&2 <<MSG
qa-findings: QA MARKER TEXT EXISTS ONLY ON PRIOR HEADS, AND ONLY FROM UNLISTED AUTHORS.
  Found $untrusted_prior_found review(s) carrying the QA lead-body marker whose login
  is NOT in the policy allowlist, all stamped on a head that has been superseded.
  Nothing on the requested head ${head:0:8} is attributable to the QA writer. The text
  IS printed below, labelled PRIOR HEAD UNTRUSTED AUTHOR; add the login to
  .identity.bot_logins if it really is the QA writer, or re-run with --any-author.
MSG
  echo "  Order decides here too: the newest prior-head marker is the unlisted one," >&2
  echo "  so it is the current word on that head and the older trusted body is stale." >&2
  print_cands "$(printf '%s' "$split" | jq -c '.untrusted_prior')" "PRIOR HEAD UNTRUSTED AUTHOR "
  if [ "$prior_found" -gt 0 ]; then
    print_cands "$(printf '%s' "$split" | jq -c '.prior')" "OLDER TRUSTED ON THAT PRIOR HEAD "
  fi
  exit 6
fi

cat >&2 <<'MSG'
qa-findings: NO QA REVIEW BODY exists on this PR.
  The verdict — if there is one — is status-only, and a commit status carries no
  finding text. That is a QA defect (see skills-all/muso-github-code-review:
  a terminal status must not be published before the text lands). Do NOT invent
  findings and do not report "no findings": report that the text is missing and
  where you looked.
MSG
exit 4

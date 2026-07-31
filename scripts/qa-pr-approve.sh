#!/usr/bin/env bash
set -euo pipefail

# qa-pr-approve.sh — gated "approve-only" for the QA agent's PR-review skill.
# ===========================================================================
# The QA agent calls this AFTER a GO-verdict review (via muso-github-code-review)
# to record a GitHub approval on a PR. It is the ONLY sanctioned path for QA to
# approve — the skill must never call `gh pr review --approve` directly, because
# this wrapper enforces the guardrails and the audit log that prose alone can't.
#
# Hard rules enforced here (the checkable ones — judgment stays with the agent):
#   1. APPROVE ONLY. This never merges. Humans merge.
#   2. Muso-AI repos only.
#   3. Never self-approve: GitHub 422s if the PR author == the authenticated
#      account, so refuse early with a clear message instead of a confusing API
#      error.
#   3b. Never approve a PR touching a sensitive path (policies/, secrets/,
#      CODEOWNERS, workflow files, this script) — regardless of author.
#   3c. Never approve a PR by an author in the policy's author_deny list.
#   4. Requester must be in the approval allowlist (Aaron/Serhii/Nick).
#      NOTE: the agent supplies the UID, so this is defense-in-depth, not a
#      cryptographic gate. The real identity signal is the Slack UID the gateway
#      put in the message metadata; the agent is trusted to pass it faithfully.
#   5. Log BEFORE the write (SECURITY.md "Write Activity Logging"): if it can't
#      log, it doesn't approve.
#
# Usage:
#   qa-pr-approve.sh <repo> <pr-number> <requester-slack-uid> [approval-body]
#     <repo>  short name (e.g. core-backend) or owner/repo (owner must be Muso-AI)
#
# Exit codes: 0 ok | 2 usage | 3 repo-not-muso | 4 self-approval-blocked
#             5 requester-not-allowed | 6 log-failed | 7 gh-approve-failed
#             8 ci-not-green | 9 open-blocking-findings
#             10 rebase-warning-unfiled-or-unverified
#             11 sensitive-path-blocked | 12 author-policy-blocked
#
# Env (mainly for tests): QA_GH override the identity shim (GH overrides the gh
# binary inside it);
# QA_APPROVAL_POLICY override the policy file; QA_PR_APPROVE_LOG_DIR override log
# dir; QA_REBASE_STATE_DIR override the rebase-integrity report dir (Guard 8);
# QA_REBASE_REQUIRED_REPOS space-separated short names whose CI must have
# written a report (default "hydra") — missing report there refuses (Guard 8).

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# NOTE: there is deliberately no `GH=` here. Every call goes through $QA_GH, and
# a live-looking $GH next to it would invite a call that silently bypasses the
# identity shim, the kill switch, and the per-repo token scoping. To override the
# gh binary itself, set GH — qa-gh.sh honours it (GH_BIN).
# Every GitHub call goes through the identity shim, which decides per repo
# whether to run as the QA bot App or the ambient host login, and mints a scoped
# installation token when it is the former. See scripts/qa-gh.sh.
QA_GH="${QA_GH:-$_here/qa-gh.sh}"
POLICY="${QA_APPROVAL_POLICY:-$_here/../policies/qa-approval-policy.json}"
LOG_DIR="${QA_PR_APPROVE_LOG_DIR:-api-logs/github}"

# Identity note: the approval is recorded under whichever identity the shim
# selected for this repo — the `muso-qa-bot` GitHub App where it is enabled,
# otherwise the ambient host account. The *body* is branded "Muso QA Bot" either
# way so the write always reads as automation.
#
# A GitHub App can never be a CODEOWNER (CODEOWNERS takes users and teams only),
# so on repos in the policy's require_human_codeowner_repos the bot's approval
# counts toward the required review but does NOT unblock the merge. That is
# intended: it restores the human sign-off that running as a universal-CODEOWNER
# account had silently removed. The skill must say so in the result DM.

# Approval allowlist — Slack UIDs of the only people who may trigger an approval.
# Aaron U7RP6HKUZ, Serhii U03TYGJF1N3, Nick U0AL36NADEY.
# DELIBERATELY excludes Mariia (azure-kirin, U03LP8YHLPK): her PRs ARE auto-REVIEWED
# (see scripts/lib/qa-author-slack-uid.sh) but a human signs off the approval — a
# UI/newbie author's own PRs must not auto-approve. Do not re-add without a human
# also updating SECURITY.md + workspaces/qa/SOUL.md + the muso-github-code-review skill.
ALLOWED_UIDS=("U7RP6HKUZ" "U03TYGJF1N3" "U0AL36NADEY")

die() { echo "qa-pr-approve: $2" >&2; exit "$1"; }

[ "$#" -ge 3 ] || die 2 "usage: qa-pr-approve.sh <repo> <pr-number> <requester-uid> [body]"
repo_arg="$1"
pr="$2"
requester="$3"
body="${4:-🤖 Approved by Muso QA Bot (automated review): CI is green and there are no blocking findings. A human still performs the merge.}"

# --- Guard 2: Muso-AI repos only -------------------------------------------
if [[ "$repo_arg" == */* ]]; then
  owner="${repo_arg%%/*}"
  repo="${repo_arg#*/}"
else
  owner="Muso-AI"
  repo="$repo_arg"
fi
[ "$owner" = "Muso-AI" ] || die 3 "repo owner must be Muso-AI, got '$owner' — refusing."
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'."

# --- Guard 4: requester in allowlist (fail fast, no network) ----------------
allowed=0
for uid in "${ALLOWED_UIDS[@]}"; do [ "$uid" = "$requester" ] && allowed=1 && break; done
[ "$allowed" = 1 ] || die 5 "requester '$requester' is not authorized to approve PRs (allowlist: Aaron/Serhii/Nick)."

# --- Identity ---------------------------------------------------------------
# `gh api user` returns 403 "Resource not accessible by integration" under a
# GitHub App installation token — there is no user behind an App token. Left
# unhandled that makes $me empty, which silently voids Guard 3 AND makes Guard 8's
# marker-author test compare against "" and match nothing, so every WARN head
# would die exit 10. So the identity is DECLARED here, not discovered: ask the
# API, and fall back to the policy's first bot login when it cannot answer.
# `|| true` is load-bearing: under `set -e` + `pipefail` a failing jq (unreadable
# policy) aborts the whole script at this assignment with jq's own exit code and
# NO message, before the fallback below can run. `head -1` guards the other shape
# — a file that is valid JSON followed by garbage, where jq emits the real value
# and then fails, which would otherwise make this a two-line string.
bot_logins_json="$(jq -c '(.identity.bot_logins // ["muso-qa-bot"]) | if type == "array" then . else ["muso-qa-bot"] end' "$POLICY" 2>/dev/null | head -1 || true)"
[ -n "$bot_logins_json" ] || bot_logins_json='["muso-qa-bot"]'
me="$("$QA_GH" --repo "$owner/$repo" api user --jq .login 2>/dev/null || true)"
[ -n "$me" ] || me="$(printf '%s' "$bot_logins_json" | jq -r '.[0] // "muso-qa-bot"' 2>/dev/null || echo "muso-qa-bot")"

# norm_login — collapse the THREE forms GitHub reports the same bot identity in,
# so comparisons cannot silently miss. Verified against Muso-AI/auth's dependabot
# PR on 2026-07-27:
#   REST      (gh api .../pulls)          -> "dependabot[bot]"
#   GraphQL   (gh pr view --json author)  -> "app/dependabot"
#   GraphQL   (reviewThreads Bot{login})  -> "dependabot"
# Guard 3 reads the middle one and $me/bot_logins carry the others, so comparing
# raw strings matches nothing and the guard is silently dead.
norm_login() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's,^app/,,' -e 's,\[bot\]$,,'; }

# --- Guard 3: never self-approve -------------------------------------------
author="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json author --jq .author.login 2>/dev/null || true)"
[ -n "$author" ] || die 7 "could not read PR author for $owner/$repo#$pr (does the PR exist / is gh authed?)."
# GitHub logins are case-insensitive. Compare against the CURRENT identity only,
# not the whole bot_logins set: GitHub blocks approving your own PR, and that is
# a fact about who is acting right now. Once the App is the actor, a PR by the
# old host account is no longer self-approval — it is a policy question, and
# Guard 3c below is what answers it. Conflating the two would report a misleading
# reason and would wrongly refuse if the set ever grew.
author_n="$(norm_login "$author")"
me_n="$(norm_login "$me")"
if [ -n "$me_n" ] && [ "$me_n" = "$author_n" ]; then
  die 4 "PR #$pr is authored by the acting QA identity ($author) — GitHub blocks self-approval. A different reviewer must approve it."
fi

# --- Guard 3c: author policy ------------------------------------------------
# Authors the bot must never approve, independent of who requested it. Defaults
# to the host account: GitHub's self-approval block used to make approving its
# PRs impossible, and moving to a dedicated identity would otherwise remove that
# protection as an invisible side effect. Widening this is a deliberate policy PR.
# Fail closed on a four-state read. `jq -e` alone cannot distinguish "not in the
# list" from "malformed", and `(.author_deny // [])` is worse: it silently turns a
# MISSING or null key into an empty allow-list, so a policy that lost the key
# would quietly start approving the very authors this guard exists to block. The
# key must be present AND an array; an explicit [] is still honoured, because
# that is the deliberate policy flip.
deny_hit="$(jq -r --arg a "$author_n" '
  if (has("author_deny") | not) or (.author_deny == null) then "__MISSING__"
  elif (.author_deny | type) != "array" then "__BADTYPE__"
  else (.author_deny | map(ascii_downcase | sub("^app/";"") | sub("\\[bot\\]$";""))
        | index($a) | tostring)
  end' "$POLICY" 2>/dev/null || echo "__ERR__")"
case "$deny_hit" in
  __ERR__)     die 12 "cannot read author_deny from $POLICY — refusing to approve (fail closed)." ;;
  __MISSING__) die 12 "author_deny is missing or null in $POLICY — refusing to approve (fail closed; an absent key must not read as an empty allow-list). Set it to [] explicitly to allow all authors." ;;
  __BADTYPE__) die 12 "author_deny in $POLICY is not an array — refusing to approve (fail closed)." ;;
  null)        : ;;
  *)           die 12 "PR #$pr is authored by '$author', who is in the policy's author_deny list — refusing to approve. A human must review it." ;;
esac

# --- Guard 3b: sensitive paths ----------------------------------------------
# Refuse to approve any PR touching security-relevant paths, REGARDLESS of author.
# This is what actually replaces the protection the self-approval block used to
# provide by accident, and it is strictly stronger — it also covers PRs by Nick
# and Serhii, which the old behaviour did not. Note the deliberate self-reference:
# policies/ and this script are both listed, so the bot cannot approve a change
# that would widen its own authority.
# Fail closed: an unreadable policy or an unreadable file list refuses.
sensitive_json="$(jq -c --arg r "$owner/$repo" \
  '((.sensitive_paths["*"] // []) + (.sensitive_paths[$r] // []))' "$POLICY" 2>/dev/null || true)"
[ -n "$sensitive_json" ] || die 11 "cannot read sensitive_paths from $POLICY — refusing to approve (fail closed)."
# An EMPTY pattern set disables this guard entirely, so treat it as unreadable
# rather than as "nothing is sensitive" — a dropped or renamed key must refuse,
# not silently approve everything.
[ "$sensitive_json" != "[]" ] || die 11 "sensitive_paths in $POLICY is empty for $owner/$repo — refusing to approve (fail closed; a missing key must not disable this guard)."

# `gh pr view --json files` issues `files(first: 100)` with NO pagination and no
# pageInfo (verified with GH_DEBUG=api on 2026-07-27). Read the independently
# paginated REST endpoint instead, then cross-check its total against
# changedFiles so an API failure or partial response still refuses fail-closed.
reported_changed_files="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" \
  --json changedFiles --jq .changedFiles 2>/dev/null || true)"
[[ "$reported_changed_files" =~ ^[0-9]+$ ]] \
  || die 11 "could not read the changed-file count for $owner/$repo#$pr — refusing to approve (fail closed)."
files_json="$("$QA_GH" --repo "$owner/$repo" api --paginate --slurp \
  "repos/$owner/$repo/pulls/$pr/files?per_page=100" 2>/dev/null)" \
  || die 11 "could not read the paginated changed-file list for $owner/$repo#$pr — refusing to approve (fail closed)."
printf '%s' "$files_json" \
  | jq -e '
      type == "array"
      and all(.[];
        type == "array"
        and all(.[];
          if type != "object" then false
          else ((.filename | type) == "string" and (.filename | length) > 0)
            and (.status as $s
                 | (["added", "removed", "modified", "renamed", "copied", "changed", "unchanged"]
                    | index($s)) != null)
            and (if has("previous_filename")
                 then ((.previous_filename | type) == "string"
                       and (.previous_filename | length) > 0)
                 else .status != "renamed"
                 end)
          end))' \
    >/dev/null 2>&1 \
  || die 11 "could not parse the paginated changed-file list for $owner/$repo#$pr — refusing to approve (fail closed)."
returned_changed_files="$(printf '%s' "$files_json" | jq -r '[.[][]] | length')"
[ "$reported_changed_files" = "$returned_changed_files" ] \
  || die 11 "PR #$pr reports $reported_changed_files changed files but the API returned $returned_changed_files — cannot verify sensitive paths on a partial list; refusing (fail closed)."
unique_changed_files="$(printf '%s' "$files_json" | jq -r '[.[][] | .filename] | unique | length')"
[ "$returned_changed_files" = "$unique_changed_files" ] \
  || die 11 "the paginated API returned duplicate filenames for $owner/$repo#$pr — cannot verify sensitive paths on an unstable list; refusing (fail closed)."
changed_files="$(printf '%s' "$files_json" | jq -r '.[][] | .filename, (.previous_filename? // empty)')"
if [ -n "$changed_files" ]; then
  hit="$(printf '%s\n' "$changed_files" \
    | jq -R -s --argjson pats "$sensitive_json" \
        '[ split("\n")[] | select(length > 0) as $f
           | select(any($pats[]; . as $p | ($f | startswith($p)))) ] | .[0] // empty' \
        2>/dev/null || echo "__ERR__")"
  [ "$hit" != "__ERR__" ] || die 11 "could not evaluate sensitive paths for $owner/$repo#$pr — refusing (fail closed)."
  [ -z "$hit" ] || die 11 "PR #$pr touches a sensitive path ($hit) — a human code owner must approve it, not the QA bot."
fi

# --- Guard 6: CI must be green --------------------------------------------
# Re-derive CI status here rather than trusting the agent's "CI green" claim
# (root cause of the PR #287 mis-approval). Exclude the qa-review context
# itself to avoid a circular dependency (QA sets it just before calling this).
# Fail closed: refuse if the rollup can't be read (ERR), if ANY non-qa-review
# check is not passing, OR if there are NO non-qa-review checks at all -- an
# empty rollup is not proof CI ran, so it must not read as green (QA #398).
bad_checks="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]? | select((.context // .name) != "qa-review")]
         | if length == 0 then "NO-CHECKS"
           else ([.[] | (((.conclusion // .state) // "PENDING") | ascii_upcase)
                  | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED")] | length | tostring)
           end' \
  2>/dev/null || echo "ERR")"
[ "$bad_checks" = "0" ] || die 8 "CI not green for $owner/$repo#$pr (non-passing/absent checks: $bad_checks) — refusing to approve."

# --- Guard 7: no unresolved Critical/Important review threads ---------------
# Carry findings forward mechanically: any unresolved thread whose first comment
# is tagged Critical/Important blocks the approval. This re-reads thread-resolution
# state independently of the agent's GO verdict -- but note it TRUSTS isResolved,
# which QA itself can set. It catches an UN-resolved blocker, not a wrongly-resolved
# one; mechanical fix-verification is Part B (the CTO fix-and-re-review loop).
# Fail closed: if threads can't be read, refuse.
read -r -d '' gql <<'GQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:100){
        pageInfo{ hasNextPage }
        nodes{ isResolved comments(first:1){ nodes{ body author{ login } } } }
      }
    }
  }
}
GQL
# Fail closed on >100 threads: if there is a second page we cannot see a blocker
# that lives past the first 100, so refuse rather than approve blind (QA #398).
open_blockers="$("$QA_GH" --repo "$owner/$repo" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
  --jq '.data.repository.pullRequest.reviewThreads
         | if .pageInfo.hasNextPage then "MORE"
           else ([.nodes[]? | select(.isResolved == false)
                  | (.comments.nodes[0].body // "")
                  | select(test("🔴|🟡"))] | length | tostring)
           end' \
  2>/dev/null || echo "ERR")"
[ "$open_blockers" = "0" ] || die 9 "$owner/$repo#$pr has unresolved Critical/Important review thread(s), or >100 threads to verify ($open_blockers) — refusing until they are addressed/resolved (or a human reviews)."

# --- Guard 8: rebase-integrity warnings must be surfaced ---------------------
# The advisory CI analyzer (scripts/check-rebase-integrity.sh, pr-validate.yml)
# writes a per-head report under /var/lib/hydra-qa/rebase-integrity. The chain
# "CI writes WARN → skill files a 🟡 REBASE WARNING thread → Guard 7 blocks
# while it is unresolved" has exactly one prose link: the skill remembering to
# file the finding. This guard closes it mechanically:
#   missing report  → for repos whose CI writes reports (QA_REBASE_REQUIRED_REPOS,
#                     default: hydra) this is a FAILED HAND-OFF → refuse; for
#                     external repos it is genuine no-data → pass
#   CLEAN           → pass
#   WARN            → a review thread whose first comment carries the literal
#                     "REBASE WARNING [<head sha7>]" marker must EXIST (resolved
#                     or not — Guard 7 already blocks while it is unresolved; a
#                     human resolving it is the acknowledgment)
#   ERROR/unreadable→ rebase state unverified → refuse (fail closed)
# The sha7 in the marker forces re-filing per push; a new push lands with the
# new head's checks pending, so Guard 6 covers the report-not-yet-written race.
# Known limits (documented, accepted): the head can move between Guard 6's
# rollup read and this guard's headRefOid read — the same push-mid-approval race
# every guard in this file has; and the state dir lives on the CI host where
# pr-validate executes PR-controlled code, so a hostile insider PR could forge
# reports — same trust model as the self-hosted runner itself. The interior
# field cross-check below catches accidental key mixups, not that adversary.
RI_DIR="${QA_REBASE_STATE_DIR:-/var/lib/hydra-qa/rebase-integrity}"
head_oid="$("$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
# 40-hex only: this value is spliced into a filesystem path and a jq program —
# anything else (gh error text, multiline) must refuse, not degrade to
# missing-file=pass.
[[ "$head_oid" =~ ^[0-9a-f]{40}$ ]] || die 10 "could not read a valid headRefOid for $owner/$repo#$pr (got '$head_oid') — cannot verify rebase-integrity state; refusing (fail closed)."
ri_file="$RI_DIR/${owner}__${repo}-pr-${pr}-${head_oid}.json"
if [ ! -f "$ri_file" ]; then
  # A missing report must not read as clean where the analyzer is EXPECTED to
  # have run: if the state hand-off failed (dir unwritable, analyzer died before
  # its ERROR sentinel), the only trace is this absence — pass here and the
  # fail-closed guarantee silently evaporates. Repos in the required list get
  # refused; external repos (no analyzer in their CI) legitimately have no file.
  for ri_required in ${QA_REBASE_REQUIRED_REPOS:-hydra}; do
    [ "$repo" = "$ri_required" ] && die 10 "no rebase-integrity report for $owner/$repo#$pr head ${head_oid:0:7} — the PR Validation analyzer should have written one (failed hand-off?); re-run CI or investigate $RI_DIR (fail closed)."
  done
else
  # Interior fields must match the filename-derived key (catches key-format
  # drift between analyzer and guard, and stale/mis-filed reports).
  ri_key_ok="$(jq -r --arg repo "$owner/$repo" --arg pr "$pr" --arg head "$head_oid" \
    'if (.repo == $repo) and ((.pr | tostring) == $pr) and (.head_sha == $head)
     then "OK" else "MISMATCH" end' "$ri_file" 2>/dev/null || echo ERR)"
  [ "$ri_key_ok" = "OK" ] || die 10 "rebase-integrity report $ri_file interior fields do not match its key ($ri_key_ok) — refusing (fail closed)."
  ri_status="$(jq -r '.status // "ERROR"' "$ri_file" 2>/dev/null || echo ERROR)"
  case "$ri_status" in
    CLEAN) : ;;
    WARN)
      ri_marker="REBASE WARNING [${head_oid:0:7}]"
      # Same reviewThreads query as Guard 7, counting threads that carry the
      # marker AND were filed by the bot — a marker comment posted by anyone else
      # (e.g. the PR author pre-empting the finding) must not satisfy this gate.
      # Match against the whole bot_logins SET rather than one login: GraphQL
      # reports an App as Bot{login:"muso-qa-bot"} while REST uses
      # "muso-qa-bot[bot]", and PRs open across the cutover (or across a
      # kill-switch rollback) carry threads filed under the host account. Testing
      # one value would silently match nothing and refuse every WARN head.
      # Fail closed on unreadable threads or a second page.
      ri_filed="$("$QA_GH" --repo "$owner/$repo" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
        | jq -r --arg marker "$ri_marker" --argjson logins "$bot_logins_json" \
            'def norm: ascii_downcase | sub("^app/";"") | sub("\\[bot\\]$";"");
             .data.repository.pullRequest.reviewThreads
               | if .pageInfo.hasNextPage then "MORE"
                 else ([.nodes[]? | (.comments.nodes[0] // {})
                        | select(((.body // "") | contains($marker))
                                 and (((.author.login // "") | norm) as $a
                                      | ($logins | map(norm) | index($a)) != null))]
                       | length | tostring)
                 end' \
        2>/dev/null || echo "ERR")"
      if [ "$ri_filed" = "0" ]; then
        die 10 "rebase-integrity report for ${head_oid:0:7} is WARN but no '$ri_marker' review thread exists — file the finding (muso-github-code-review Step 3d) before approving."
      elif ! [[ "$ri_filed" =~ ^[0-9]+$ ]]; then
        die 10 "cannot verify the REBASE WARNING thread for $owner/$repo#$pr (threads unreadable or >100: $ri_filed) — refusing (fail closed)."
      fi
      ;;
    *) die 10 "rebase-integrity report for ${head_oid:0:7} is '$ri_status' — rebase state unverified; refusing to approve (fail closed)." ;;
  esac
fi

# --- Guard 5: log BEFORE the write ------------------------------------------
ts="$(date -u +%FT%TZ)"
mkdir -p "$LOG_DIR" || die 6 "cannot create log dir $LOG_DIR — refusing to approve unlogged."
# "identity" records WHICH account made the write, so the audit trail can be
# separated pre/post identity migration (and per repo during the staged cutover).
log_line="$(printf '{"agent":"qa","action":"github_pr_approve","target":"%s/%s#%s","requester":"%s","identity":"%s","timestamp":"%s","authorization":"qa-review-go-verdict"}' \
  "$owner" "$repo" "$pr" "$requester" "$me" "$ts")"
printf '%s\n' "$log_line" >> "$LOG_DIR/$(date -u +%F).jsonl" || die 6 "cannot write audit log — refusing to approve unlogged."

# --- Approve (NEVER merge) --------------------------------------------------
if ! "$QA_GH" --repo "$owner/$repo" pr review "$pr" --repo "$owner/$repo" --approve --body "$body"; then
  die 7 "gh pr review --approve failed for $owner/$repo#$pr."
fi
echo "qa-pr-approve: approved $owner/$repo#$pr as $me (requester $requester). NOT merged."

# A GitHub App cannot be a CODEOWNER, so on these repos the approval counts
# toward the required review but does NOT clear the code-owner gate. Say so
# loudly — the requester will otherwise read the approval as merge-ready.
if jq -e --arg r "$owner/$repo" '(.require_human_codeowner_repos // []) | index($r)' "$POLICY" >/dev/null 2>&1; then
  echo "qa-pr-approve: NOTE — $owner/$repo requires a CODEOWNER review, which a bot identity can never satisfy. This PR still needs a human code owner's approval before it can merge."
fi

# --- Post-check: report real review/merge state, don't assume "done" --------
echo "qa-pr-approve: post-approval state —"
"$QA_GH" --repo "$owner/$repo" pr view "$pr" --repo "$owner/$repo" --json reviewDecision,mergeStateStatus,state \
  --jq '"  reviewDecision=\(.reviewDecision)  mergeStateStatus=\(.mergeStateStatus)  state=\(.state)"' 2>/dev/null \
  || echo "  (could not read post-approval state; check the PR on GitHub)"
echo "qa-pr-approve: if anything other than reviewDecision=APPROVED / a clean mergeStateStatus shows, tell the requester what still blocks (CODEOWNERS, required checks). A human performs the merge."

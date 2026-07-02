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
#      gh account (the gateway token is Aaron/adk47), so refuse early with a
#      clear message instead of a confusing API error.
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
#
# Env (mainly for tests): GH=gh override; QA_PR_APPROVE_LOG_DIR override log dir;
# QA_REBASE_STATE_DIR override the rebase-integrity report dir (Guard 8);
# QA_REBASE_REQUIRED_REPOS space-separated short names whose CI must have
# written a report (default "hydra") — missing report there refuses (Guard 8).

GH="${GH:-gh}"
LOG_DIR="${QA_PR_APPROVE_LOG_DIR:-api-logs/github}"

# Identity note: the approval is recorded by GitHub as the host account (adk47),
# because that account is the universal CODEOWNER and so its approval unblocks the
# merge. We do NOT have a dedicated bot user account, so the *body* is branded
# "Muso QA Bot" (see the default below) to make clear it is an automated QA
# action, not a manual review by Aaron.

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
body="${4:-🤖 Approved by Muso QA Bot (automated review): CI is green and there are no blocking findings. Recorded via QA automation on the adk47 account, not a manual review by Aaron. A human still performs the merge.}"

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

# --- Guard 3: never self-approve -------------------------------------------
me="$("$GH" api user --jq .login 2>/dev/null || true)"
author="$("$GH" pr view "$pr" --repo "$owner/$repo" --json author --jq .author.login 2>/dev/null || true)"
[ -n "$author" ] || die 7 "could not read PR author for $owner/$repo#$pr (does the PR exist / is gh authed?)."
# GitHub logins are case-insensitive.
if [ -n "$me" ] && [ "$(printf '%s' "$me" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')" ]; then
  die 4 "PR #$pr is authored by the gateway account ($author) — GitHub blocks self-approval. A different reviewer must approve it."
fi

# --- Guard 6: CI must be green --------------------------------------------
# Re-derive CI status here rather than trusting the agent's "CI green" claim
# (root cause of the PR #287 mis-approval). Exclude the qa-review context
# itself to avoid a circular dependency (QA sets it just before calling this).
# Fail closed: refuse if the rollup can't be read (ERR), if ANY non-qa-review
# check is not passing, OR if there are NO non-qa-review checks at all -- an
# empty rollup is not proof CI ran, so it must not read as green (QA #398).
bad_checks="$("$GH" pr view "$pr" --repo "$owner/$repo" --json statusCheckRollup \
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
open_blockers="$("$GH" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
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
head_oid="$("$GH" pr view "$pr" --repo "$owner/$repo" --json headRefOid --jq .headRefOid 2>/dev/null || true)"
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
      # marker AND were filed by the gateway account ($me) — a marker comment
      # posted by anyone else (e.g. the PR author pre-empting the finding) must
      # not satisfy this gate. Fail closed on unreadable threads or a second page.
      ri_filed="$("$GH" api graphql -f query="$gql" -f owner="$owner" -f repo="$repo" -F pr="$pr" \
        --jq '.data.repository.pullRequest.reviewThreads
               | if .pageInfo.hasNextPage then "MORE"
                 else ([.nodes[]? | (.comments.nodes[0] // {})
                        | select(((.body // "") | contains("'"$ri_marker"'"))
                                 and ((.author.login // "") == "'"$me"'"))] | length | tostring)
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
log_line="$(printf '{"agent":"qa","action":"github_pr_approve","target":"%s/%s#%s","requester":"%s","timestamp":"%s","authorization":"qa-review-go-verdict"}' \
  "$owner" "$repo" "$pr" "$requester" "$ts")"
printf '%s\n' "$log_line" >> "$LOG_DIR/$(date -u +%F).jsonl" || die 6 "cannot write audit log — refusing to approve unlogged."

# --- Approve (NEVER merge) --------------------------------------------------
if ! "$GH" pr review "$pr" --repo "$owner/$repo" --approve --body "$body"; then
  die 7 "gh pr review --approve failed for $owner/$repo#$pr."
fi
echo "qa-pr-approve: approved $owner/$repo#$pr as $me (requester $requester). NOT merged."

# --- Post-check: report real review/merge state, don't assume "done" --------
echo "qa-pr-approve: post-approval state —"
"$GH" pr view "$pr" --repo "$owner/$repo" --json reviewDecision,mergeStateStatus,state \
  --jq '"  reviewDecision=\(.reviewDecision)  mergeStateStatus=\(.mergeStateStatus)  state=\(.state)"' 2>/dev/null \
  || echo "  (could not read post-approval state; check the PR on GitHub)"
echo "qa-pr-approve: if anything other than reviewDecision=APPROVED / a clean mergeStateStatus shows, tell the requester what still blocks (CODEOWNERS, required checks). A human performs the merge."

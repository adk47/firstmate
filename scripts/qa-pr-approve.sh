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
#   4. Requester must be in the approval allowlist (Aaron/Fede/Serhii/Nick).
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
#
# Env (mainly for tests): GH=gh override; QA_PR_APPROVE_LOG_DIR override log dir.

GH="${GH:-gh}"
LOG_DIR="${QA_PR_APPROVE_LOG_DIR:-api-logs/github}"

# Identity note: the approval is recorded by GitHub as the host account (adk47),
# because that account is the universal CODEOWNER and so its approval unblocks the
# merge. We do NOT have a dedicated bot user account, so the *body* is branded
# "Muso QA Bot" (see the default below) to make clear it is an automated QA
# action, not a manual review by Aaron.

# Approval allowlist — Slack UIDs of the only people who may trigger an approval.
# Aaron U7RP6HKUZ, Fede U07NF5A77E2, Serhii U03TYGJF1N3, Nick U0AL36NADEY.
ALLOWED_UIDS=("U7RP6HKUZ" "U07NF5A77E2" "U03TYGJF1N3" "U0AL36NADEY")

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
[ "$allowed" = 1 ] || die 5 "requester '$requester' is not authorized to approve PRs (allowlist: Aaron/Fede/Serhii/Nick)."

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
        nodes{ isResolved comments(first:1){ nodes{ body } } }
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

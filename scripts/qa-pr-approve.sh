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

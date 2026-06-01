#!/usr/bin/env bash
set -euo pipefail

# qa-dispatch-pr-review.sh — fire-and-forget dispatch of a QA-agent auto-review
# of a hydra PR.
# ===========================================================================
# Called by .github/workflows/qa-autoreview.yml on the self-hosted hydra runner
# (which runs steps as root on the same host as the gateway, verified node-8)
# AFTER pr-validate finishes. It registers a one-shot openclaw cron job that
# wakes the `qa` agent to run the `muso-github-code-review` skill in AUTO MODE
# on the given PR. The review/approve happen asynchronously in the gateway.
#
# Why a one-shot `cron add` and not `openclaw agent`: `openclaw agent` is
# synchronous and would hold the single self-hosted runner for the whole review
# (up to its timeout), blocking other PRs' CI. `cron add --at` returns
# immediately and the turn runs async.
#
# Why isolated agentTurn and not `--session main`: on the live 2026.5.27 build
# `--session main` refuses `--message`/`--announce` (main jobs need a
# `--system-event` with no fallback delivery). Every production cron here uses
# isolated agentTurn and retains `exec` — e.g. credit-verification-batch-4h has
# 274 runs — so the historical isolated-tool-loss concern does not apply on this
# build (verified on node-8, not assumed).
#
# Scope (for now): hydra only, Nick's PRs only. The requester UID handed to the
# approve wrapper is hard-pinned to Nick; the qa-autoreview workflow already
# filters to author=nsollazzo, so this is defense-in-depth.
#
# Usage:
#   qa-dispatch-pr-review.sh <pr-number> <head-sha>
#
# Env overrides (mainly for tests / delivery tuning):
#   OPENCLAW                  openclaw binary (default: openclaw)
#   QA_AUTOREVIEW_DELIVER_TO  Slack delivery target for the result notification
#                             (default: user:<Nick> DM)
# Exit codes: 0 dispatched | 2 usage.

OPENCLAW="${OPENCLAW:-openclaw}"
PROFILE="main"
AGENT="qa"
REPO="Muso-AI/hydra"
REQUESTER_UID="U0AL36NADEY"   # Nick — qa-pr-approve allowlist + the Slack DM target for updates
TIMEOUT_SECONDS="1200"

die() { echo "qa-dispatch-pr-review: $2" >&2; exit "$1"; }

# --- Arg validation: fail loud. A silent no-op dispatcher is worse than none
#     (cf. dispatch-cv-batch.sh --help typo that fired 500 real writes). --------
[ "$#" -eq 2 ] || die 2 "usage: qa-dispatch-pr-review.sh <pr-number> <head-sha>"
pr="$1"
sha="$2"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'."
[[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die 2 "head-sha must be a 7-40 char hex sha, got '$sha'."

job_name="qa-autoreview-pr-${pr}"
pr_url="https://github.com/${REPO}/pull/${pr}"

# Build the dispatch instruction. The unquoted heredoc expands ${...}; `read -d
# ''` slurps it into one var (avoids the bash 3.2 command-substitution+heredoc
# quote-parsing bug, so the script stays portable). The text is deliberately
# apostrophe/backtick-free for the same reason. The PR URL makes the qa agent
# run the skill (its MUST-RUN trigger); "AUTO-REVIEW" selects the skill Auto
# mode section.
read -r -d '' message <<EOF || true
AUTO-REVIEW (automated trigger; there is NO human in this thread to approve).

Review this pull request with the muso-github-code-review skill in AUTO MODE:
${pr_url}  (head commit ${sha})

PR author to keep updated over Slack DM: Slack user ${REQUESTER_UID}.

Follow the skill Auto mode section exactly. In short:
- FIRST send the author the opening note and KEEP the printed thread-root ts. Use the
  per-PR thread helper so re-reviews of this PR thread under the first review instead
  of starting a new top-level DM (it owns the wording and prints the thread-root ts):
    bash /opt/hydra/scripts/qa-pr-thread-dm.sh ${REPO} ${pr} ${REQUESTER_UID}
- Skip the Step 5 human gate; post the batched review (Step 6, COMMENT) to GitHub
  yourself after the audit-log line. Check CI with "gh pr checks ${pr} --repo ${REPO}".
- Approve (Step 7, scripts/qa-pr-approve.sh, requester ${REQUESTER_UID}) ONLY IF every
  CI check passed, the verdict is GO (no Critical, no Important), and the wrapper
  allowlist passes. Otherwise post the review and DO NOT approve. Never merge.
- LAST, DM the author the result as a threaded reply under that opening ts (one line:
  approved + safe to merge, or not-approved + the reason and finding counts).
EOF

# Idempotency: a re-push reruns CI and re-dispatches. Drop any still-pending job
# for this PR so we review the latest SHA, not a stale one. Best-effort — never
# fail the dispatch over cleanup.
old_ids="$("$OPENCLAW" --profile "$PROFILE" cron list --json 2>/dev/null \
  | jq -r --arg n "$job_name" '.jobs[]? | select(.name==$n) | .id' 2>/dev/null || true)"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  "$OPENCLAW" --profile "$PROFILE" cron rm "$id" >/dev/null 2>&1 || true
done <<< "$old_ids"

# Fire-and-forget one-shot. --delete-after-run cleans up on success. No
# --announce: the skill owns delivery (opening + threaded result DM to the author
# via qa-slack-dm.sh), so the cron itself delivers nothing (mode none).
"$OPENCLAW" --profile "$PROFILE" cron add \
  --name "$job_name" \
  --at "+5s" \
  --agent "$AGENT" \
  --session isolated \
  --message "$message" \
  --timeout-seconds "$TIMEOUT_SECONDS" \
  --delete-after-run \
  --json

echo "qa-dispatch-pr-review: dispatched auto-review of ${REPO}#${pr} (${sha}) -> agent ${AGENT}."

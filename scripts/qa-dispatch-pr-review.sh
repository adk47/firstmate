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
# Scope: hydra PRs (default) AND any other Muso-AI repo passed explicitly — e.g.
# Muso-AI/ads-manager via .github/workflows/external-pr-review.yml. The repo and
# the requester/Slack-DM UID are now parameters (positional or env); when omitted
# they default to hydra + Nick, preserving the original single-repo behavior. The
# requester UID is BOTH the qa-pr-approve allowlist gate and the Slack DM target,
# so a caller that wants the bot to approve must pass an allowlisted UID.
#
# Usage:
#   qa-dispatch-pr-review.sh <pr-number> <head-sha> [repo] [requester-uid]
#
# Args / env overrides (positional wins over env; env mainly for tests):
#   repo           ${QA_REVIEW_REPO:-Muso-AI/hydra}        (must be Muso-AI/<name>)
#   requester-uid  ${QA_REVIEW_REQUESTER_UID:-U0AL36NADEY} (Slack UID; approve+DM)
#   OPENCLAW       openclaw binary (default: openclaw)
# (No delivery-target override: the cron uses --no-deliver and the skill owns all
# Slack delivery itself, so there is nothing for the cron to target.)
# Exit codes: 0 dispatched | 2 usage/validation.

OPENCLAW="${OPENCLAW:-openclaw}"
PROFILE="main"
AGENT="qa"
TIMEOUT_SECONDS="1200"

die() { echo "qa-dispatch-pr-review: $2" >&2; exit "$1"; }

# --- Arg validation: fail loud. A silent no-op dispatcher is worse than none
#     (cf. dispatch-cv-batch.sh --help typo that fired 500 real writes). --------
[ "$#" -ge 2 ] && [ "$#" -le 4 ] \
  || die 2 "usage: qa-dispatch-pr-review.sh <pr-number> <head-sha> [repo] [requester-uid]"
pr="$1"
sha="$2"
# repo/requester are optional positionals; fall back to env, then the hydra defaults.
REPO="${3:-${QA_REVIEW_REPO:-Muso-AI/hydra}}"
REQUESTER_UID="${4:-${QA_REVIEW_REQUESTER_UID:-U0AL36NADEY}}"
[[ "$pr" =~ ^[0-9]+$ ]] || die 2 "pr-number must be numeric, got '$pr'."
[[ "$sha" =~ ^[0-9a-fA-F]{7,40}$ ]] || die 2 "head-sha must be a 7-40 char hex sha, got '$sha'."
# Only Muso-AI repos: matches the owner guard in qa-pr-approve.sh, and keeps a
# forged/typo'd repo from steering the review at a non-Muso target.
[[ "$REPO" =~ ^Muso-AI/[A-Za-z0-9._-]+$ ]] || die 2 "repo must be Muso-AI/<name>, got '$REPO'."
[[ "$REQUESTER_UID" =~ ^U[A-Z0-9]+$ ]] || die 2 "requester-uid must be a Slack UID (U...), got '$REQUESTER_UID'."

# Namespace the one-shot job by repo so hydra#123 and ads-manager#123 never
# collide in the cron list (idempotency cleanup keys on the full name below).
# Keep the literal "qa-autoreview-pr-" prefix: the pr-validate orphan-check and
# the stale-sweep below both match on it, so neither needs to change.
job_name="qa-autoreview-pr-${REPO//\//-}-${pr}"
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
- Before any GO, carry prior findings forward (skill "Carry forward prior findings"):
  resolve confirmed-fixed threads, treat any unresolved Critical/Important as a blocker.
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

# Sweep stale qa-autoreview-pr-* one-shots left behind by earlier runs. A failed run is
# NOT reaped by --delete-after-run (deletion is gated on outcome=ok), so dead jobs pile up
# in the cron list. A review finishes well inside the 1200s timeout, so any qa-autoreview
# job created >1h ago is definitely done (a succeeded one already self-deleted) and safe to
# remove. The >1h cutoff leaves any in-flight review (other PR) untouched. Conservative on
# missing timestamps (default far-future = never swept). Best-effort — never fail dispatch.
stale_cutoff_ms=$(( ($(date -u +%s) - 3600) * 1000 ))
stale_ids="$("$OPENCLAW" --profile "$PROFILE" cron list --json 2>/dev/null \
  | jq -r --argjson c "$stale_cutoff_ms" \
      '.jobs[]? | select((.name // "") | startswith("qa-autoreview-pr-"))
                | select((.createdAtMs // 9999999999999) < $c) | .id' 2>/dev/null || true)"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  "$OPENCLAW" --profile "$PROFILE" cron rm "$id" >/dev/null 2>&1 || true
done <<< "$stale_ids"

# Fire-and-forget one-shot. --delete-after-run cleans up on success.
#
# --no-deliver: the skill owns ALL Slack delivery (opening + threaded result DM to
# the author via qa-slack-dm.sh, posted with explicit targets mid-turn), so the cron
# must NOT also deliver its final assistant text. Omitting --announce is NOT enough:
# the runner's fallback delivery is on by default and tries to deliver to chat "last",
# which an isolated cron has no concept of -> the turn ends in
# `outcome=error error="Delivering to Slack requires target ..."` ~26-30x/day and the
# failed one-shot is never --delete-after-run'd. --no-deliver disables that fallback
# (the CLI equivalent of a `"mode": "none"` job). Verified: openclaw 2026.5.27.
"$OPENCLAW" --profile "$PROFILE" cron add \
  --name "$job_name" \
  --at "+5s" \
  --agent "$AGENT" \
  --session isolated \
  --message "$message" \
  --timeout-seconds "$TIMEOUT_SECONDS" \
  --no-deliver \
  --delete-after-run \
  --json

echo "qa-dispatch-pr-review: dispatched auto-review of ${REPO}#${pr} (${sha}) -> agent ${AGENT}."

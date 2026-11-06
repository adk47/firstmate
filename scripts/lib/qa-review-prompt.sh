#!/usr/bin/env bash
# qa-review-prompt.sh — the ONE review instruction text.
#
# Why this is a library and not an inline heredoc
# ==============================================
# The instruction text used to live inline in scripts/qa-dispatch-pr-review.sh.
# The broker/worker path (scripts/qa-worker.sh) has to send the SAME text, and a
# second copy would drift: the worker would review with subtly different rules
# (say, dropping the "carry prior findings" line) and nothing would notice,
# because both paths produce a plausible review. So the text lives here once and
# both callers source it. scripts/tests/qa-worker.bats asserts the two paths
# produce byte-identical text, so a future edit that only updates one copy fails
# CI instead of silently changing how QA reviews PRs.
#
# The text is deliberately apostrophe/backtick-free: it is passed through
# `read -d ''` into a single shell variable and then onto a command line, and a
# stray quote changes the parse. Keep it that way when editing.
#
# Usage:
#   source scripts/lib/qa-review-prompt.sh
#   qa_review_prompt <repo> <pr> <head_sha> <requester_uid>
# Prints the message on stdout (no trailing newline beyond the heredoc's own).

qa_review_prompt() {
  local REPO="$1" pr="$2" sha="$3" REQUESTER_UID="$4"
  local pr_url="https://github.com/${REPO}/pull/${pr}"
  # Unquoted heredoc expands ${...}; `read -d ''` slurps it into one var, which
  # avoids the bash 3.2 command-substitution+heredoc quote-parsing bug so this
  # stays portable. The PR URL makes the qa agent run the skill (its MUST-RUN
  # trigger); "AUTO-REVIEW" selects the skill Auto mode section.
  read -r -d '' __qa_prompt <<EOF || true
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
  yourself after the audit-log line.
- Before any GO, carry prior findings forward (skill "Carry forward prior findings"):
  resolve confirmed-fixed threads, treat any unresolved Critical/Important as a blocker.
- Approve through scripts/qa-pr-approve.sh (Step 7, requester ${REQUESTER_UID}) whenever
  the verdict is GO (no Critical, no Important). The wrapper decides CI greenness: advisory
  checks alert, they do not withhold. Do not gate on CI yourself. Never merge.
- LAST, DM the author the result as a threaded reply under that opening ts (one line:
  approved + safe to merge, or not-approved + the reason and finding counts).
EOF
  printf '%s' "$__qa_prompt"
}

# qa_verdict_to_status <verdict>
# Map a broker verdict to the qa-review commit status the skill's own approval
# path produces. Kept here so the worker and any future consumer agree.
#   go            -> success
#   no_go         -> failure
#   cannot_review -> failure
#   unknown       -> failure
qa_verdict_to_status() {
  case "$1" in
    go) echo "success" ;;
    no_go|cannot_review|unknown) echo "failure" ;;
    *) echo "failure" ;;
  esac
}

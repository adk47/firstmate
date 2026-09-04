#!/usr/bin/env bash
# sentry-merge-policy.sh — the ONE place that says where a Sentry autofix lands
# and who merges it. Sourced by scripts/sentry-issue-watchdog.sh (which merges
# only qa-gated repos) and by the sentry-issue-triage skill's headless path
# (which picks the PR base from it). Two copies of this table drifted apart
# is exactly the trap this file exists to prevent.
#
#   sentry_merge_policy <owner/repo>   -> prints "<base> <policy>" and exits 0,
#                                         or prints nothing and exits 1 (unknown)
#   policy:  qa-gated  the watchdog merges the PR once QA's `qa-review` status
#                      is GO (+ green CI, mergeable, any formal review the base
#                      requires). develop is a dev-only integration branch.
#            human     production: a human merges (auth's `main` IS prod).
sentry_merge_policy() {
  case "$1" in
    Muso-AI/core-backend|Muso-AI/web-credits-next) echo "develop qa-gated" ;;
    Muso-AI/auth)                                  echo "main human" ;;
    *) return 1 ;;
  esac
}

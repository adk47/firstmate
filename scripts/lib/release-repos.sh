#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# release-repos.sh — sourced config table for the release announcer.
#
# ONE place defines what a repo is called in #releases, how hydra learns
# that it shipped, and how often it may post. release-watch.sh and
# release-announce.sh both read it, so the channel stays consistent and a
# new repo is one table row rather than a code change.
#
# Usage:
#   source /opt/hydra/scripts/lib/release-repos.sh
#   release_repo_keys                        # every configured key
#   release_repo_field web-credits-next emoji
#
# Fields, in table order:
#   key        short name, and the argument users pass to --repo
#   repo       owner/name on GitHub
#   enabled    1 = may post to #releases, 0 = configured but silent
#   emoji      leading glyph in the Slack header
#   display    human name in the header ("muso.ai web", not the repo slug)
#   detector   how a confirmed prod release is observed:
#                status - the app-repo commit carries a SUCCESS commit
#                         status from H-DevOps naming the prod rollout.
#                         Authoritative and KEYED BY SHA, so the shipped
#                         commit is read directly, never inferred.
#                hydra  - a successful run of the repo's own deploy
#                         workflow on main (hydra deploys itself).
#                store  - App Store Connect / Play rollout state. Phase 2.
#   deploy_st  commit-status context proving a prod rollout, or `-` when the
#              repo has none. A repo without one cannot be announced safely
#              and must stay enabled=0.
#   sender     workflow file in the APP repo whose successful runs on main
#              produce the candidate commits
#   cadence    per-deploy = announce every confirmed prod release.
#              daily      = at most ONE announced release per calendar day
#                           (Europe/Rome), from 08:00 onward, rolling up
#                           everything that shipped since the last cut.
#                           hydra is `daily` on purpose: it deploys ~2.7x
#                           a day and is internal agent-ops plumbing, so
#                           per-deploy posts would drown the product
#                           releases this channel exists to surface.
#   rollback   URL a reader follows to find out how to undo this release
#
# The `-` placeholder means "not applicable to this detector".
#
# WHY NOT the H-DevOps `auto: bump muso/<svc> ... post-deploy` commit:
# it proves a rollout succeeded but does not name the sha, while a sender
# run proves a dispatch was accepted but not that it rolled out. Every
# attempt to bridge that gap by timestamp or ordinal position is unsound --
# Actions concurrency does not guarantee ordering, a failed rollout writes
# no bump, and two deploys can overlap. The commit status is the record
# that actually carries the identity, so it is the only thing used here.
#
# auth is enabled=0 for the same reason mobile is: its upstream does not yet
# produce the signal this detector needs. `deploy-auth.yaml` posted zero
# `H-DevOps / deploy` statuses as of 2026-08-27 (measured on each of its last
# five main commits), so there is nothing that authoritatively says which sha
# reached production.
#
# It was briefly enabled=1 on the theory that it would sit quiet and
# self-activate when the companion landed. That was the wrong posture: a row
# marked enabled that cannot produce a release reads as a working lane, and
# it forced the detector to tolerate permanently statusless dispatches --
# which in turn meant a real release could be skipped silently. Keeping it
# disabled until the writer exists lets the detector treat an unresolved
# rollout as the anomaly it is.
#
# Flip to 1 when https://github.com/Muso-AI/H-DevOps/pull/2799 merges; the
# context is already correct, so that is the only change needed.
#
# Mobile is enabled=0 because neither H-DevOps prod lane reaches users:
# iOS stops at TestFlight and Android uploads to Play track alpha as a
# draft, so announcing either as "released" would be false.
# ──────────────────────────────────────────────────────────────

# key|repo|enabled|emoji|display|detector|deploy_st|sender|cadence|rollback
_RELEASE_REPO_TABLE='
hydra|Muso-AI/hydra|1|🛠️|hydra (agent ops)|hydra|-|deploy.yml|daily|https://github.com/Muso-AI/hydra/blob/main/docs/runbooks/RUNBOOK.md
web-credits-next|Muso-AI/web-credits-next|1|🌐|muso.ai web|status|H-DevOps / deploy|deploy-to-ovh.yaml|per-deploy|https://github.com/Muso-AI/H-DevOps/blob/main/docs/runbooks/rollback.md
auth|Muso-AI/auth|0|🔐|muso auth (login.muso.ai)|status|H-DevOps / deploy|trigger-deploy.yaml|per-deploy|https://github.com/Muso-AI/H-DevOps/blob/main/docs/runbooks/rollback.md
ios-app|Muso-AI/ios-app|0|📱|muso iOS|store|-|dispatch-build.yaml|per-deploy|https://github.com/Muso-AI/H-DevOps/blob/main/docs/runbooks/mobile-native-cicd.md
android-app|Muso-AI/android-app|0|🤖|muso Android|store|-|dispatch-build.yaml|per-deploy|https://github.com/Muso-AI/H-DevOps/blob/main/docs/runbooks/mobile-native-cicd.md
'

# release_repo_keys [--enabled-only]
release_repo_keys() {
  local only_enabled=0
  [[ "${1:-}" == "--enabled-only" ]] && only_enabled=1
  local key enabled
  while IFS='|' read -r key _ enabled _; do
    [[ -n "$key" ]] || continue
    if [[ "$only_enabled" -eq 1 && "$enabled" != "1" ]]; then continue; fi
    printf '%s\n' "$key"
  done <<< "$(printf '%s' "$_RELEASE_REPO_TABLE" | sed '/^[[:space:]]*$/d')"
}

# release_repo_field <key> <field-name>
# Prints the value, or returns 1 if the key or the field is unknown. The
# caller MUST check the return code: an unknown key returning an empty
# string would otherwise read as a legitimately empty field and, for
# `repo`, would send a tag to the wrong place.
release_repo_field() {
  local want_key="$1" want_field="$2"
  local -a names=(key repo enabled emoji display detector deploy_st sender cadence rollback)
  local idx=-1 i
  for i in "${!names[@]}"; do
    [[ "${names[$i]}" == "$want_field" ]] && idx="$i" && break
  done
  [[ "$idx" -ge 0 ]] || { echo "release_repo_field: unknown field '$want_field'" >&2; return 1; }

  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local -a f=()
    IFS='|' read -r -a f <<< "$line"
    if [[ "${f[0]}" == "$want_key" ]]; then
      printf '%s\n' "${f[$idx]}"
      return 0
    fi
  done <<< "$(printf '%s' "$_RELEASE_REPO_TABLE" | sed '/^[[:space:]]*$/d')"

  echo "release_repo_field: unknown repo key '$want_key'" >&2
  return 1
}

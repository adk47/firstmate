#!/usr/bin/env bash
# drift-check.sh — 3-way ("baseline / repo-HEAD / server") classifier for
# skill-file drift between this repo and the live /opt/hydra/ on node-8.
#
# Sourced from:
#   - scripts/deploy.sh preflight_drift_check() (Step 4a, baseline-aware path)
#   - .github/workflows/pr-validate.yml deploy-preflight job (PR-time gate)
#
# WHY 3-way. Skills are edited in BOTH directions: directly on node-8
# (hot-patch) and in repo PRs. A 2-way "repo != server" check (deploy.sh
# Step 4a today) cannot tell an intended repo edit (REPO-AHEAD, safe to
# push — this is what false-blocked PR #366) from a genuine server edit
# (SERVER-AHEAD, must be captured) from a true CONFLICT (both edited). The
# last-deployed baseline (/opt/hydra/.deployed-sha) is the tie-breaker.
#
# WHY git blob identity (not the working tree). Each side is hashed as a git
# blob: baseline = `git rev-parse <sha>:<path>`, repo = `git rev-parse
# HEAD:<path>`, server = `git hash-object --path=<path> <file>`. The repo and
# baseline legs read committed objects, never the working tree, so the check
# is immune to runner working-tree staleness — the suspected #366 root cause.
# `--path=` makes the server hash honor the same gitattributes as the stored
# blob, so EOL/filter normalization never shows up as phantom drift.
#
# SCOPE. Only `skills-all/**/SKILL.md` and `workspaces/<ws>/skills/**/SKILL.md`
# files present on BOTH repo-HEAD and the server are classified. Pure
# adds/removes (a SKILL.md on only one side) and non-SKILL.md content stay
# with the deploy's existing `*deleting` deletion rail + RSYNC_EXCLUDES, which
# already handle "would wipe server state" and temp files. Runtime scratch
# under workspaces/ (memory/, tmp*/, anything not ever committed to repo
# HEAD) is already excluded by the tracked-at-HEAD requirement below (the
# `[[ -n "$oid_repo" ... ]]` guard) — the same ever-tracked predicate
# classify-deletions.sh's classify_workspace_deletions builds with
# `git ls-files`. Do not add a second exclusion list for it.
#
# LOCAL ONLY. server_root must be a locally-readable path (it is on the
# self-hosted node-8 runner where both callers run, HYDRA_LOCAL=true). Remote
# (laptop) deploys do not call this lib; deploy.sh keeps its blunt SSH check.
#
# USAGE
#   . scripts/lib/drift-check.sh
#   classify_skill_drift <baseline_sha> <repo_root> <server_root>
#   # stdout: one line per non-clean file, classification token first.
#
# OUTPUT (stdout, newline-delimited; diagnostics go to stderr)
#   REPO-AHEAD   <path>   repo moved, server still at baseline → deploy pushes
#   SERVER-AHEAD <path>   server moved, repo still at baseline → capture it
#   CONFLICT     <path>   both moved (or both added differently) → reconcile
#   (CLEAN files emit nothing.)
#
# EXIT CODES (callers treat 5 and 6 as "fall back to today's blunt check" —
# NEVER as "clean")
#   0 — classified successfully (may emit zero lines)
#   2 — bad args (missing repo_root / server_root)
#   4 — git unavailable or repo_root is not a git checkout
#   5 — baseline SHA empty (first deploy / .deployed-sha absent)
#   6 — baseline commit not in repo history (shallow clone — fetch it)

classify_skill_drift() {
  local baseline_sha="${1-}"
  local repo_root="${2-}"
  local server_root="${3-}"

  if [[ -z "$repo_root" || -z "$server_root" ]]; then
    echo "classify_skill_drift: usage: classify_skill_drift <baseline_sha> <repo_root> <server_root>" >&2
    return 2
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "classify_skill_drift: git not on PATH; cannot classify" >&2
    return 4
  fi
  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "classify_skill_drift: $repo_root is not a git checkout; cannot classify" >&2
    return 4
  fi

  if [[ -z "$baseline_sha" ]]; then
    echo "classify_skill_drift: no baseline SHA (first deploy / .deployed-sha absent)" >&2
    return 5
  fi
  if ! git -C "$repo_root" cat-file -e "${baseline_sha}^{commit}" 2>/dev/null; then
    echo "classify_skill_drift: baseline $baseline_sha not in repo history (run: git fetch)" >&2
    return 6
  fi

  # Candidate SKILL.md paths: tracked-at-HEAD files under skills-all/ or
  # workspaces/<ws>/skills/. One arm only — a second server-side `find` arm
  # over the live server tree was fully redundant (both are supersets of the
  # tracked ∩ on-server set the `oid_repo`/`oid_srv` guard below restricts
  # classification to) and, for workspaces/, would have walked node-8's live
  # tree for zero effect on the answer.
  local candidates
  candidates=$(
    git -C "$repo_root" ls-tree -r --name-only HEAD -- skills-all workspaces 2>/dev/null \
      | grep -E '^(skills-all/.*/SKILL\.md|workspaces/[^/]+/skills/.*/SKILL\.md)$' \
      | sort -u
  )

  local path oid_base oid_repo oid_srv
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue

    oid_repo=$(git -C "$repo_root" rev-parse --quiet --verify "HEAD:$path" 2>/dev/null || true)
    oid_srv=""
    if [[ -f "$server_root/$path" ]]; then
      oid_srv=$(git -C "$repo_root" hash-object --path="$path" "$server_root/$path" 2>/dev/null || true)
    fi

    # Classify only files present on BOTH sides; pure adds/removes → deletion rail.
    [[ -n "$oid_repo" && -n "$oid_srv" ]] || continue
    # Identical content → clean.
    [[ "$oid_repo" == "$oid_srv" ]] && continue

    oid_base=$(git -C "$repo_root" rev-parse --quiet --verify "${baseline_sha}:$path" 2>/dev/null || true)

    if [[ -z "$oid_base" ]]; then
      printf 'CONFLICT %s\n' "$path"          # added on both sides, differ
    elif [[ "$oid_repo" == "$oid_base" ]]; then
      printf 'SERVER-AHEAD %s\n' "$path"       # repo unchanged, server moved
    elif [[ "$oid_srv" == "$oid_base" ]]; then
      printf 'REPO-AHEAD %s\n' "$path"         # server unchanged, repo moved
    else
      printf 'CONFLICT %s\n' "$path"           # both moved independently
    fi
  done <<< "$candidates"

  return 0
}

# compute_skill_block_lines <rsync_itemize> <baseline_sha> <repo_root> \
#                           <server_root> <hydra_local:true|false>
#
# The deploy Step 4a decision: which skills-all/ and workspaces/ drift lines
# should BLOCK the deploy. Two paths:
#   SMART  (hydra_local=true AND baseline non-empty AND classify succeeds):
#          block on SERVER-AHEAD + CONFLICT; let REPO-AHEAD through. Letting
#          REPO-AHEAD pass is the #366 fix — a PR's own intended skill edits
#          no longer block the merge deploy.
#   BLUNT  (remote, no baseline, or classify rc 5/6): parse the rsync itemize
#          for skills-all/ content drift exactly as Step 4a did before this
#          change, so a missing/unreachable baseline degrades to today's
#          behavior and never silently weakens the gate.
#
# stdout: the lines to block on (classification lines in the smart path, raw
# itemize lines in the blunt path — both are path-bearing so the caller's
# ack filter + briefing handle either). Returns 0 normally; propagates a
# hard classifier failure (rc 2/4) so the caller can fail closed.
compute_skill_block_lines() {
  local itemize="${1-}" baseline="${2-}" repo_root="${3-}" server_root="${4-}" hydra_local="${5-}"

  if [[ "$hydra_local" == "true" && -n "$baseline" ]]; then
    local classified rc=0
    classified=$(classify_skill_drift "$baseline" "$repo_root" "$server_root") || rc=$?
    case "$rc" in
      0)
        printf '%s\n' "$classified" | grep -E '^(SERVER-AHEAD|CONFLICT) ' || true
        return 0
        ;;
      5|6) : ;;            # no/unreachable baseline → fall through to blunt
      *) return "$rc" ;;   # hard error (bad args / not a repo) → fail closed
    esac
  fi

  # Blunt fallback: content-drift parse of the rsync itemize (col 2 = 'f',
  # col 3 = 'c' or col 4 = 's'). The two arms are DELIBERATELY different
  # widths, unlike the smart classifier's candidate pathspec above:
  #   skills-all/   — ANY file (not just SKILL.md). This arm's documented
  #                   job is to degrade to the pre-widening behaviour
  #                   (base 3bb0546c: bare `grep -F 'skills-all/'`), and it
  #                   runs precisely in the states where Step 0's
  #                   unscoped would_update/intended rail is ALSO skipped
  #                   (no/unreachable baseline, HYDRA_SKIP_DRIFT_CHECK=1)
  #                   — so narrowing it to SKILL.md-only would silently
  #                   stop gating the 443 of 520 tracked skills-all/ files
  #                   (executable scripts, references, etc.) that aren't
  #                   SKILL.md (internal QA round-4 NO-GO, 2026-10-01).
  #   workspaces/   — SKILL.md only, scoped the same way the smart
  #                   classifier's candidate pathspec is, so a non-skill
  #                   workspaces/ file (e.g. workspaces/qa/SOUL.md) is
  #                   never misreported as "skill drift" (GitHub QA Bot
  #                   NO-GO on hydra#1051, 2026-10-01). Base matched this
  #                   tree not at all, so this scoping is a pure widening
  #                   for this arm, not a narrowing — the asymmetry with
  #                   the skills-all/ arm above is intentional, not a gap.
  printf '%s\n' "$itemize" \
    | awk '{ if (substr($0,2,1)=="f" && (substr($0,3,1)=="c" || substr($0,4,1)=="s")) print }' \
    | grep -E 'skills-all/|workspaces/[^/]+/skills/.*/SKILL\.md$' || true
  return 0
}

# sync_target_for_path <path>
# stdout: the scripts/sync-from-server.sh target ("skills" or "workspaces")
# whose --only prefix check (sync-from-server.sh target_prefixes) accepts
# <path>. Single source of truth for remediation printers: pr-skill-
# drift-gate.sh and deploy.sh's DRIFT_BRIEFING each print a per-file capture
# command from this lib's classifier output, and a second inline copy of
# this two-line decision going stale in one of them — while the other gets
# fixed — is exactly the bug MUS-1792 round 2 (QA finding 1) caught: deploy.sh
# kept handing operators a `sync-from-server.sh skills --apply --only
# workspaces/...` command that sync-from-server.sh's own --only validation
# rejects with exit 1.
sync_target_for_path() {
  case "${1-}" in
    workspaces/*) printf 'workspaces\n' ;;
    *)            printf 'skills\n' ;;
  esac
}

# format_skill_capture_commands <classified_lines>
# stdout: a scripts/sync-from-server.sh capture command (target picked by
# sync_target_for_path) plus a follow-up `git add && git commit`, one pair
# per SERVER-AHEAD or blunt-fallback path in <classified_lines> —
# compute_skill_block_lines' output. CONFLICT lines are skipped (see
# format_skill_conflict_commands). Blunt-fallback lines carry no
# SERVER-AHEAD/CONFLICT tag; per the deploy briefing's own documented rule
# ("no baseline -> treat every line as SERVER-AHEAD") they are handled here
# too, with the path parsed as everything after the FIRST whitespace run.
# The rsync itemize code is NOT a fixed width across rsync implementations
# (confirmed: macOS /usr/bin/rsync is openrsync, protocol 29, and emits a
# 9-char code, not the 11 chars rsync 3.x uses) — a fixed char-offset
# extraction silently truncates the path on a short-code host. Splitting on
# the first space is the same width-agnostic approach deploy.sh:1673-1675
# and scripts/lib/acknowledge-hot-patch-drift.sh already use for this same
# itemize format.
format_skill_capture_commands() {
  local lines="${1-}" line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      "SERVER-AHEAD "*) path="${line#SERVER-AHEAD }" ;;
      "CONFLICT "*)     continue ;;
      *)                path="${line#* }" ;;
    esac
    printf '       scripts/sync-from-server.sh %s --apply --only %q\n' "$(sync_target_for_path "$path")" "$path"
    printf '       git add %q && git commit -m "chore: capture skill edit from node-8"\n' "$path"
  done <<< "$lines"
}

# format_skill_conflict_commands <classified_lines>
# stdout: one `git show <baseline>:<path>` reconcile-start command per
# CONFLICT path in <classified_lines>. Blunt-fallback lines are never
# CONFLICT (see format_skill_capture_commands), so nothing to do for them.
format_skill_conflict_commands() {
  local lines="${1-}" line path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      "CONFLICT "*)
        path="${line#CONFLICT }"
        printf '       git show "$(cat /opt/hydra/.deployed-sha)":%q   # baseline version\n' "$path"
        ;;
    esac
  done <<< "$lines"
}

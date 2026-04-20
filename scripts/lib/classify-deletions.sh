#!/usr/bin/env bash
# classify-deletions.sh — classify rsync `*deleting` output lines into
# (a) workspace subdirs safe to auto-exclude, and (b) deletions that should
# still trigger the drift-rail briefing.
#
# Sourced from:
#   - scripts/deploy.sh preflight_drift_check() (Step 4a)
#   - .github/workflows/pr-validate.yml deploy-preflight job (shift-left gate)
#
# Both callers want the same rule: if a deletion would remove a file under
# `workspaces/<ws>/<subdir>/` AND git has no tracked content at that subdir,
# treat it as agent-authored runtime state and exclude it. Otherwise treat
# the deletion as real drift (tracked file removed, or non-workspaces path).
#
# USAGE
#   . scripts/lib/classify-deletions.sh
#   classify_workspace_deletions <deletions-blob> <git-root> > /tmp/classified
#   # Then grep AUTO: / REMAIN: from /tmp/classified.
#
# OUTPUT (on stdout, newline-delimited)
#   AUTO:   workspaces/<ws>/<subdir>/     — each pattern is emitted once,
#                                           caller appends to rsync excludes
#   REMAIN: *deleting   <path>            — unchanged rsync itemize line,
#                                           caller feeds back to the briefing
#
# EXIT CODES
#   0 — classification succeeded (may emit zero of either type)
#   2 — bad args
#   4 — git unavailable or not a git repo (caller should fail closed —
#       cannot safely classify without the ever-tracked predicate)
#   5 — tracked set is empty but workspaces/ has content on disk: strongly
#       suggests a shallow/broken clone. Refusing to classify would silently
#       auto-exclude every deletion.
#
# INVARIANTS
# - `ever_tracked` is derived from `git ls-files` at HEAD, so classification
#   is deterministic across environments (laptop dev, CI shallow clone, node-
#   8). A once-tracked-then-deleted subdir is NOT in ever_tracked, so its
#   current deletion trips the briefing — that is real drift.
# - The awk filter emits both subdirs and top-level tracked files (a tracked
#   workspaces/<ws>/SOUL.md has 3 path components and the NF>=3 filter
#   includes it). On lookup, deletion of a tracked SOUL.md matches ever_
#   tracked exactly and is correctly NOT auto-excluded.
# - The regex requires a trailing `/` after the subdir component, so a
#   never-tracked TOP-LEVEL workspace file (e.g. `workspaces/<ws>/runtime.log`)
#   does NOT match and falls through to REMAIN — that is real drift.

set -euo pipefail

classify_workspace_deletions() {
    local deletions="${1-}"
    local hydra_root="${2-}"

    if [[ -z "$hydra_root" ]]; then
        echo "classify_workspace_deletions: missing hydra_root arg" >&2
        return 2
    fi

    # Fail closed if git is unavailable. Without the tracked predicate we
    # cannot distinguish agent-created dirs from accidentally-removed seeds,
    # and defaulting to "auto-exclude everything" would disable the drift
    # rail silently. Matches the guard pattern in deploy.sh Step 0.
    if ! command -v git >/dev/null 2>&1; then
        echo "classify_workspace_deletions: git not on PATH; cannot classify" >&2
        return 4
    fi
    if ! git -C "$hydra_root" rev-parse --git-dir >/dev/null 2>&1; then
        echo "classify_workspace_deletions: $hydra_root is not a git checkout; cannot classify" >&2
        return 4
    fi

    # Zero-deletion short circuit: no classification needed.
    if [[ -z "$deletions" ]]; then
        return 0
    fi

    # Compute the ever-tracked set at HEAD. tr -d '\r' normalizes filenames
    # on Windows-origin clones where core.autocrlf may introduce CR on list
    # output — without this, grep -qxF matches fail and legitimately-tracked
    # paths get mis-classified as never-tracked.
    local ever_tracked
    ever_tracked=$(git -C "$hydra_root" ls-files -- 'workspaces/*' \
        | tr -d '\r' \
        | awk -F/ '$1 == "workspaces" && NF >= 3 { print $1"/"$2"/"$3 }' \
        | sort -u)

    # Sanity check: if the caller's repo has workspaces/ on disk with
    # tracked content but `ever_tracked` came back empty, something is very
    # wrong (shallow clone missing main branch, ls-files crashed silently,
    # etc). Refuse to classify rather than auto-exclude everything.
    if [[ -z "$ever_tracked" ]] \
       && [[ -d "$hydra_root/workspaces" ]] \
       && [[ -n "$(ls -A "$hydra_root/workspaces" 2>/dev/null || true)" ]]; then
        echo "classify_workspace_deletions: ever_tracked is empty but workspaces/ has content — git state suspect, refusing to classify" >&2
        return 5
    fi

    # Classify each deletion line.
    local -a auto_excluded=()
    local line path ws subdir key s
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # Strip the `*deleting` prefix + padding. read -r with a single
        # variable captures the full remainder (IFS word-splitting only
        # applies with 2+ variable names), preserving embedded whitespace.
        read -r path <<< "${line#\*deleting}"
        # Regex REQUIRES a trailing `/` after the subdir component. This
        # means a never-tracked top-level workspace FILE
        # (workspaces/<ws>/runtime.log) does NOT match and stays in REMAIN.
        if [[ "$path" =~ ^workspaces/([^/]+)/([^/]+)/ ]]; then
            ws="${BASH_REMATCH[1]}"
            subdir="${BASH_REMATCH[2]}"
            key="workspaces/${ws}/${subdir}"
            if ! grep -qxF -- "$key" <<< "$ever_tracked"; then
                auto_excluded+=("${key}/")
                continue
            fi
        fi
        printf 'REMAIN: %s\n' "$line"
    done <<< "$deletions"

    # Emit unique AUTO patterns. sort -u over the accumulated list keeps
    # this bash-3 compatible (no associative arrays).
    if (( ${#auto_excluded[@]} > 0 )); then
        while IFS= read -r s; do
            printf 'AUTO: %s\n' "$s"
        done < <(printf '%s\n' "${auto_excluded[@]}" | sort -u)
    fi
}

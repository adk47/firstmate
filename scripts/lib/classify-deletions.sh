#!/usr/bin/env bash
# classify-deletions.sh — classify rsync `*deleting` output lines into
# (a) workspace subdirs safe to auto-exclude, and (b) deletions that should
# still trigger the drift-rail briefing.
#
# Sourced from:
#   - scripts/deploy.sh preflight_drift_check() (Step 4a)
#   - .github/workflows/pr-validate.yml deploy-preflight job (shift-left gate)
#
# Both callers want the same rule: if a deletion would remove a path under
# `workspaces/<ws>/` that git has NEVER tracked, it is server-owned runtime
# state; exclude the shallowest never-tracked ancestor (one exclude per
# server-only tree root). Deleting a path git HAS tracked, or anything outside
# `workspaces/`, is real drift.
#
# USAGE
#   . scripts/lib/classify-deletions.sh
#   classify_workspace_deletions <deletions-blob> <git-root> > /tmp/classified
#   # Then grep AUTO: / REMAIN: from /tmp/classified.
#
# OUTPUT (on stdout, newline-delimited)
#   AUTO:   workspaces/<ws>/.../<root>[/]  — shallowest never-tracked ancestor,
#                                           rsync-glob-escaped ([ ] * ? \)
#                                           (dir => trailing /); emitted once,
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
# - `ever_tracked` is HEAD's tracked files UNION every path HEAD's history
#   ever touched (needs full history; CI uses fetch-depth 0), so classification
#   is deterministic across environments. A tracked-then-deleted path stays in
#   the set: its deletion from git while the file still sits on the server is
#   real drift and trips the briefing.
# - `ever_tracked` holds every tracked path AND each of its ancestor prefixes,
#   so the walk-up can test any depth. A tracked workspaces/<ws>/SOUL.md has
#   all its prefixes in the set, so its deletion is never auto-excluded.
# - A never-tracked TOP-LEVEL workspace file (e.g. `workspaces/<ws>/runtime.log`)
#   IS auto-excluded as the file itself, no trailing slash (node-8 is truth).

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

    # Compute the ever-tracked set. tr -d '\r' normalizes filenames
    # on Windows-origin clones where core.autocrlf may introduce CR on list
    # output — without this, exact-key matches fail and legitimately-tracked
    # paths get mis-classified as never-tracked.
    local ever_tracked_file
    ever_tracked_file=$(mktemp) || return 4
    # Union HEAD's tracked files with every path HEAD's history ever touched:
    # a tracked file deleted by the change under test is gone from ls-files
    # but is exactly the real-drift signal, so it must stay "tracked" (REMAIN).
    # A failed read of either source must fail closed: a partial set would turn
    # a tracked-then-deleted path into AUTO.
    local tracked_now history_paths
    tracked_now=$(git -C "$hydra_root" ls-files -- 'workspaces/*') \
        || { rm -f "$ever_tracked_file"; echo "classify_workspace_deletions: git ls-files failed; cannot classify" >&2; return 4; }
    history_paths=
    if git -C "$hydra_root" rev-parse -q --verify HEAD >/dev/null 2>&1; then
        history_paths=$(git -C "$hydra_root" -c core.quotepath=off log --pretty=format: --name-only -- 'workspaces/*') \
            || { rm -f "$ever_tracked_file"; echo "classify_workspace_deletions: git log failed; cannot classify" >&2; return 4; }
    fi
    printf '%s\n%s\n' "$tracked_now" "$history_paths" \
        | tr -d '\r' \
        | awk -F/ '$1 == "workspaces" { p = $1; for (i = 2; i <= NF; i++) { p = p "/" $i; print p } }' \
        | sort -u > "$ever_tracked_file"

    # Sanity check: if the caller's repo has workspaces/ on disk with
    # tracked content but `ever_tracked` came back empty, something is very
    # wrong (shallow clone missing main branch, ls-files crashed silently,
    # etc). Refuse to classify rather than auto-exclude everything.
    if [[ ! -s "$ever_tracked_file" ]] \
       && [[ -d "$hydra_root/workspaces" ]] \
       && [[ -n "$(ls -A "$hydra_root/workspaces" 2>/dev/null || true)" ]]; then
        echo "classify_workspace_deletions: ever_tracked is empty but workspaces/ has content — git state suspect, refusing to classify" >&2
        rm -f "$ever_tracked_file"
        return 5
    fi

    # Classify each deletion line.
    local auto_file remain_file rc
    auto_file=$(mktemp) || { rm -f "$ever_tracked_file"; return 4; }
    remain_file=$(mktemp) || { rm -f "$ever_tracked_file" "$auto_file"; return 4; }

    # Keep this as one awk pass over deletions. The old implementation ran
    # `grep` against the tracked set for every deletion line; live workspaces can
    # easily produce hundreds of thousands of deletion candidates.
    awk -v auto_file="$auto_file" -v remain_file="$remain_file" '
        FNR == NR {
            ever[$0] = 1
            next
        }
        $0 == "" {
            next
        }
        {
            line = $0
            path = line
            sub(/^\*deleting[[:space:]]*/, "", path)

            # Walk down from depth 3 (workspaces/<ws>/<x>) to the SHALLOWEST
            # ancestor git has never tracked; that is the server-only tree
            # root. One exclude per root: the file itself (no slash) or the
            # dir (trailing slash). A tracked path has every prefix in `ever`
            # and falls through to REMAIN.
            n = split(path, parts, "/")
            if (parts[n] == "") n--
            if (n >= 3 && parts[1] == "workspaces" && parts[2] != "" && parts[3] != "") {
                key = parts[1] "/" parts[2]
                for (i = 3; i <= n; i++) {
                    key = key "/" parts[i]
                    if (!(key in ever)) {
                        # The caller passes this as an rsync --exclude pattern,
                        # where [ ] * ? are wildcards and \ escapes; escape them
                        # so the exclude matches the literal name.
                        pat = key
                        gsub(/[][\\*?]/, "\\\\&", pat)
                        print pat ((i < n || path ~ /\/$/) ? "/" : "") >> auto_file
                        next
                    }
                }
            }

            print "REMAIN: " line >> remain_file
        }
    ' "$ever_tracked_file" <(printf '%s\n' "$deletions") || rc=$?

    rc=${rc:-0}
    if (( rc != 0 )); then
        rm -f "$ever_tracked_file" "$auto_file" "$remain_file"
        return "$rc"
    fi

    cat "$remain_file"
    if [[ -s "$auto_file" ]]; then
        sort -u "$auto_file" | sed 's/^/AUTO: /'
    fi
    rm -f "$ever_tracked_file" "$auto_file" "$remain_file"
}

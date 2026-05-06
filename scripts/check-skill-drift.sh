#!/usr/bin/env bash
# check-skill-drift.sh — detect drift between skills-all/<skill>/SKILL.md and
# every workspaces/<agent>/skills/<skill>/SKILL.md copy.
#
# Why: per memory `feedback_skill_dual_tree.md`, skill fixes have repeatedly
# landed in skills-all/ but not in some workspace copies (PRs #183, #187, #213).
# A full agent-side bug each time. This script + CI hook makes drift block PRs.
#
# Scope (this iteration): SKILL.md only. Wrapper scripts (.sh, .bats) are
# excluded because pre-existing drift in muso-admin-api.sh would block the
# bootstrap PR; that drift is tracked separately.
#
# Allow-list: .skill-drift-allowlist.txt at repo root, one path per line,
# `#` comments. Each allow-listed path must include a paired-line reason after
# `--`. Allow-listing is meant to defer fixes to a tracked follow-up, not to
# permanently sanction divergence.
#
# Exit codes:
#   0 — no unallowed drift
#   1 — drift found (or invalid allow-list entries)
#   2 — script-level error (missing dirs, etc.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_ALL="${REPO_ROOT}/skills-all"
WORKSPACES="${REPO_ROOT}/workspaces"
ALLOWLIST_FILE="${REPO_ROOT}/.skill-drift-allowlist.txt"

[[ -d "$SKILLS_ALL" ]] || { echo "FATAL: $SKILLS_ALL not found" >&2; exit 2; }
[[ -d "$WORKSPACES" ]] || { echo "FATAL: $WORKSPACES not found" >&2; exit 2; }

# Load allow-list. Each entry is the relative-to-repo-root path of a
# workspace SKILL.md that is permitted to differ from canonical.
# Stored as a newline-separated string (portable across bash 3.2 / 4+).
ALLOWED_PATHS=""
if [[ -f "$ALLOWLIST_FILE" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        # Trim leading/trailing whitespace (any class). awk handles
        # tabs and CR/LF, which the previous `${line## }` only handled
        # for a single literal space.
        line=$(printf '%s' "$line" | awk '{$1=$1};1')
        [[ -z "$line" ]] && continue
        # Each line: "<path> -- <reason>". Reason is mandatory.
        local_path="${line%% -- *}"
        reason="${line#* -- }"
        if [[ "$local_path" == "$line" || -z "$reason" || "$reason" == "$line" ]]; then
            echo "FATAL: allow-list entry missing ' -- <reason>' tail: ${line}" >&2
            exit 1
        fi
        ALLOWED_PATHS="${ALLOWED_PATHS}${local_path}"$'\n'
    done < "$ALLOWLIST_FILE"
fi

is_allowed() {
    local path="$1"
    printf '%s' "$ALLOWED_PATHS" | grep -Fxq "$path"
}

DRIFT_FOUND=0
ALLOWED_DRIFT=0

# For every skills-all/<skill>/SKILL.md
while IFS= read -r canonical; do
    rel="${canonical#${REPO_ROOT}/}"
    skill_name="$(basename "$(dirname "$canonical")")"

    # Find every workspace copy of the same skill
    while IFS= read -r workspace_copy; do
        [[ -z "$workspace_copy" ]] && continue
        ws_rel="${workspace_copy#${REPO_ROOT}/}"
        if ! diff -q "$canonical" "$workspace_copy" >/dev/null 2>&1; then
            if is_allowed "$ws_rel"; then
                ALLOWED_DRIFT=$((ALLOWED_DRIFT + 1))
                echo "  ALLOWED: ${ws_rel} differs from ${rel} (in ${ALLOWLIST_FILE})"
            else
                DRIFT_FOUND=$((DRIFT_FOUND + 1))
                echo ""
                echo "DRIFT: ${ws_rel}"
                echo "       differs from canonical: ${rel}"
                echo "       (skill: ${skill_name})"
                echo "       To fix: either copy canonical over the workspace file,"
                echo "       or — if the divergence is intentional and tracked —"
                echo "       add to ${ALLOWLIST_FILE} with a ' -- <reason>' tail."
                # `|| true`: under `set -o pipefail`, head closing the pipe early
                # makes diff exit non-zero (SIGPIPE), which would kill the loop.
                { diff -u "$canonical" "$workspace_copy" 2>&1 | head -40 | sed 's/^/         /'; } || true
            fi
        fi
    # `find` stderr is left visible — this is the only CI gate against
    # the dual-tree drift problem (memory feedback_skill_dual_tree.md);
    # silencing errors here means a permissions/symlink failure could
    # silently report "OK: no drift" while drift exists.
    done < <(find "$WORKSPACES" -mindepth 4 -maxdepth 5 -type f \
        -path "*/skills/${skill_name}/SKILL.md")

done < <(find "$SKILLS_ALL" -mindepth 2 -maxdepth 2 -type f -name SKILL.md)

echo ""
if (( DRIFT_FOUND > 0 )); then
    echo "FAIL: ${DRIFT_FOUND} unallowed SKILL.md drift(s) detected." >&2
    if (( ALLOWED_DRIFT > 0 )); then
        echo "(${ALLOWED_DRIFT} drift(s) allowed via ${ALLOWLIST_FILE} were ignored.)" >&2
    fi
    exit 1
fi

if (( ALLOWED_DRIFT > 0 )); then
    echo "OK: no unallowed drift. (${ALLOWED_DRIFT} known drift(s) allow-listed for follow-up.)"
else
    echo "OK: no SKILL.md drift between skills-all/ and workspaces/*/skills/."
fi
exit 0

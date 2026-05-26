#!/usr/bin/env bash
# check-skill-drift.sh — enforce the workspace-shadow-deletion model from #336.
#
# Background: openclaw's six-tier skill resolver loads
# `workspaces/<agent>/skills/<name>/` at rank 1 (highest) and the per-profile
# managed dir `/root/.openclaw-<profile>/skills/<name>/` (which deploy.sh
# Step 4c populates from `skills-all/`) at rank 4. A workspace copy SHADOWS
# the canonical. When workspace and canonical drift, the agent silently
# keeps loading the workspace version forever, which is how 11 agents ended
# up loading month-old doctrine (issue #336).
#
# Old model (pre-#336): scan every workspace SKILL.md, allow drift via
# `.skill-drift-allowlist.txt`. Problem: it normalized shadowing as default
# state — every new workspace copy could either match canonical (pointless
# duplication) or drift (production regression risk).
#
# New model: presence + intentional-divergence list.
#   - Any workspaces/*/skills/<name>/SKILL.md where <name> also lives in
#     skills-all/ MUST EITHER be deleted (let the canonical-managed dir
#     `/root/.openclaw-<profile>/skills/<name>/` fall through at rank 4)
#     OR be explicitly listed in `.skill-workspace-divergence.txt` with a
#     reason.
#   - Workspace shadows that match canonical byte-for-byte are also
#     forbidden — they are pure dual-edit burden with no per-agent value.
#     Delete them.
#   - Workspace-only skills (no canonical counterpart, e.g. cmo's
#     muso-outreach-* subskills, sentinel/support) are unaffected by this
#     check.
#
# Exit codes:
#   0 — no violations
#   1 — violation found (drift outside divergence list, or stale divergence
#       entry, or workspace shadow matching canonical, or invalid file)
#   2 — script-level error

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_ALL="${REPO_ROOT}/skills-all"
WORKSPACES="${REPO_ROOT}/workspaces"
DIVERGENCE_FILE="${REPO_ROOT}/.skill-workspace-divergence.txt"

[[ -d "$SKILLS_ALL" ]] || { echo "FATAL: $SKILLS_ALL not found" >&2; exit 2; }
[[ -d "$WORKSPACES" ]] || { echo "FATAL: $WORKSPACES not found" >&2; exit 2; }

# Load divergence list. Each entry is the relative path of a workspace
# SKILL.md that is permitted (and required) to differ from canonical.
DIVERGENCE_PATHS=""
if [[ -f "$DIVERGENCE_FILE" ]]; then
    while IFS= read -r line; do
        line="${line%%#*}"
        line=$(printf '%s' "$line" | awk '{$1=$1};1')
        [[ -z "$line" ]] && continue
        local_path="${line%% -- *}"
        reason="${line#* -- }"
        if [[ "$local_path" == "$line" || -z "$reason" || "$reason" == "$line" ]]; then
            echo "FATAL: divergence entry missing ' -- <reason>' tail: ${line}" >&2
            exit 1
        fi
        DIVERGENCE_PATHS="${DIVERGENCE_PATHS}${local_path}"$'\n'
    done < "$DIVERGENCE_FILE"
fi

is_listed() {
    local path="$1"
    printf '%s' "$DIVERGENCE_PATHS" | grep -Fxq "$path"
}

VIOLATIONS=0
LISTED_OK=0

# Pass 1: every workspace SKILL.md that shadows a canonical must be on the
# divergence list AND must differ from canonical (otherwise it's dead weight).
while IFS= read -r workspace_copy; do
    [[ -z "$workspace_copy" ]] && continue
    ws_rel="${workspace_copy#${REPO_ROOT}/}"
    skill_name="$(basename "$(dirname "$workspace_copy")")"
    canonical="${SKILLS_ALL}/${skill_name}/SKILL.md"

    # No canonical counterpart → workspace-only skill, out of scope.
    [[ -f "$canonical" ]] || continue

    if diff -q "$canonical" "$workspace_copy" >/dev/null 2>&1; then
        # Workspace copy matches canonical exactly — dead shadow.
        VIOLATIONS=$((VIOLATIONS + 1))
        echo ""
        echo "VIOLATION: ${ws_rel}"
        echo "  Workspace SKILL.md is byte-identical to canonical (${skill_name})."
        echo "  This is dual-edit burden with no per-agent value. Delete it:"
        echo "    git rm -r \"$(dirname "$ws_rel")\""
        echo "  The agent will fall through to skills-all/ via openclaw's rank-4 resolver."
    else
        # Workspace differs from canonical.
        if is_listed "$ws_rel"; then
            LISTED_OK=$((LISTED_OK + 1))
            echo "  OK: ${ws_rel} intentionally diverges (listed in ${DIVERGENCE_FILE##*/})"
        else
            VIOLATIONS=$((VIOLATIONS + 1))
            echo ""
            echo "VIOLATION: ${ws_rel}"
            echo "  Drifts from canonical skills-all/${skill_name}/SKILL.md without being listed."
            echo "  To resolve:"
            echo "    a) Delete the workspace shadow (preferred): git rm -r \"$(dirname "$ws_rel")\""
            echo "    b) Reconcile workspace SKILL.md with canonical (cp + commit)"
            echo "    c) Document intentional divergence: add to ${DIVERGENCE_FILE##*/} with a ' -- <reason>' tail"
            # Show a snippet to help reviewers judge.
            { diff -u "$canonical" "$workspace_copy" 2>&1 | head -20 | sed 's/^/    /'; } || true
        fi
    fi
done < <(find "$WORKSPACES" -mindepth 4 -maxdepth 4 -type f -name SKILL.md -path "*/skills/*/SKILL.md")

# Pass 2: every divergence-list entry must point to a real workspace SKILL.md
# that actually differs from canonical (otherwise it's a stale entry).
if [[ -n "$DIVERGENCE_PATHS" ]]; then
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        workspace_copy="${REPO_ROOT}/${entry}"
        skill_name="$(basename "$(dirname "$workspace_copy")")"
        canonical="${SKILLS_ALL}/${skill_name}/SKILL.md"

        if [[ ! -f "$workspace_copy" ]]; then
            VIOLATIONS=$((VIOLATIONS + 1))
            echo ""
            echo "VIOLATION: ${entry}"
            echo "  Listed in ${DIVERGENCE_FILE##*/} but the workspace SKILL.md does not exist."
            echo "  Remove the entry from ${DIVERGENCE_FILE##*/}."
            continue
        fi

        if [[ ! -f "$canonical" ]]; then
            VIOLATIONS=$((VIOLATIONS + 1))
            echo ""
            echo "VIOLATION: ${entry}"
            echo "  Listed in ${DIVERGENCE_FILE##*/} but no canonical exists at skills-all/${skill_name}/SKILL.md."
            echo "  Workspace-only skills don't need a divergence entry — remove it."
            continue
        fi

        if diff -q "$canonical" "$workspace_copy" >/dev/null 2>&1; then
            VIOLATIONS=$((VIOLATIONS + 1))
            echo ""
            echo "VIOLATION: ${entry}"
            echo "  Listed in ${DIVERGENCE_FILE##*/} but content matches canonical byte-for-byte."
            echo "  The divergence has been reconciled — remove the entry (and consider deleting the now-redundant workspace shadow)."
        fi
    done < <(printf '%s' "$DIVERGENCE_PATHS")
fi

echo ""
if (( VIOLATIONS > 0 )); then
    echo "FAIL: ${VIOLATIONS} skill-drift violation(s) detected." >&2
    if (( LISTED_OK > 0 )); then
        echo "(${LISTED_OK} intentional divergence(s) on the documented list were accepted.)" >&2
    fi
    exit 1
fi

if (( LISTED_OK > 0 )); then
    echo "OK: no drift violations. (${LISTED_OK} intentional divergence(s) documented in ${DIVERGENCE_FILE##*/}.)"
else
    echo "OK: no workspace skill shadows. All agents resolve through skills-all/ via openclaw's resolver."
fi
exit 0

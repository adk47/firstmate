#!/usr/bin/env bash
# Smoke test for scripts/lib/classify-deletions.sh.
#
# Not a bats suite — there's no broader test harness for deploy tooling yet.
# This is the minimum: a shell script that builds a synthetic git repo,
# pipes synthetic rsync `*deleting` lines through the classifier, and asserts
# the expected AUTO: / REMAIN: partition. Run manually:
#
#   bash scripts/tests/classify-deletions.sh
#
# Exits 0 on all-pass, 1 on any failure (prints which case failed). Used
# to validate PR #130's auto-exclude logic pre-merge and to catch future
# regressions if the classifier's regex, awk filter, or ls-files predicate
# is refactored.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/classify-deletions.sh
source "$SCRIPT_DIR/lib/classify-deletions.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Seed a minimal hydra-shaped git repo with the tracked-file shapes the
# real repo uses (SOUL.md at workspace root, skills/ subdir, reference/
# subdir).
cd "$TMPROOT"
git init -q
git config user.email test@test
git config user.name  test
mkdir -p workspaces/ops/skills/foo workspaces/cmo/reference
echo soul   > workspaces/ops/SOUL.md
echo skill  > workspaces/ops/skills/foo/SKILL.md
echo ref    > workspaces/cmo/reference/item.md
echo cmosoul> workspaces/cmo/SOUL.md
git add -A
git commit -qm "seed"

fail_count=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $desc"
        echo "  expected:"
        echo "$expected" | sed 's/^/    /'
        echo "  actual:"
        echo "$actual"   | sed 's/^/    /'
        fail_count=$((fail_count + 1))
    else
        echo "ok: $desc"
    fi
}

run() {
    # Usage: run "<deletions-blob>"; emits sorted stdout of the classifier.
    classify_workspace_deletions "$1" "$TMPROOT" | sort
}

# ---- cases ----

# 1. Never-tracked subdir with a child file deletion → AUTO
assert "never-tracked subdir auto-excludes" \
    "AUTO: workspaces/ops/phantom/" \
    "$(run '*deleting   workspaces/ops/phantom/report.pdf
*deleting   workspaces/ops/phantom/')"

# 2. Tracked file deletion (SOUL.md) → REMAIN (safety rail — this is real drift)
assert "tracked SOUL.md deletion stays suspicious" \
    "REMAIN: *deleting   workspaces/ops/SOUL.md" \
    "$(run '*deleting   workspaces/ops/SOUL.md')"

# 3. Untracked file inside a tracked subdir (skills/foo) → REMAIN
assert "untracked file in tracked subdir stays suspicious" \
    "REMAIN: *deleting   workspaces/ops/skills/foo/extra.md" \
    "$(run '*deleting   workspaces/ops/skills/foo/extra.md')"

# 4. Deep path under a never-tracked subdir (workspaces/ops/clients/sub/x.md)
#    → AUTO with `clients/` pattern (NOT deeper — we exclude at the subdir level)
assert "deep path under never-tracked subdir auto-excludes at subdir level" \
    "AUTO: workspaces/ops/clients/" \
    "$(run '*deleting   workspaces/ops/clients/inner/nested/file.md')"

# 5. Never-tracked TOP-LEVEL workspace FILE (not a subdir) → REMAIN
#    This catches the regex `(/|$)` bug that would have auto-excluded files.
assert "never-tracked top-level workspace file stays suspicious" \
    "REMAIN: *deleting   workspaces/ops/runtime.log" \
    "$(run '*deleting   workspaces/ops/runtime.log')"

# 6. Skills-all deletion → REMAIN (not under workspaces/, out of scope)
assert "skills-all deletion stays suspicious" \
    "REMAIN: *deleting   skills-all/foo/SKILL.md" \
    "$(run '*deleting   skills-all/foo/SKILL.md')"

# 7. Mixed batch: auto + tracked + file
assert "mixed batch partitions correctly" \
    "AUTO: workspaces/cmo/clients/
AUTO: workspaces/ops/phantom/
REMAIN: *deleting   workspaces/ops/SOUL.md
REMAIN: *deleting   workspaces/ops/runtime.log" \
    "$(run '*deleting   workspaces/ops/phantom/report.pdf
*deleting   workspaces/cmo/clients/jamstik.md
*deleting   workspaces/ops/SOUL.md
*deleting   workspaces/ops/runtime.log')"

# 8. Dedup: multiple deletions under same never-tracked subdir → one AUTO line
assert "multiple deletions under same subdir dedupe to one AUTO" \
    "AUTO: workspaces/ops/phantom/" \
    "$(run '*deleting   workspaces/ops/phantom/a.md
*deleting   workspaces/ops/phantom/b.md
*deleting   workspaces/ops/phantom/c.md
*deleting   workspaces/ops/phantom/')"

# 9. Empty input → zero output, exit 0
empty_out=$(classify_workspace_deletions "" "$TMPROOT" || echo "ERROR")
assert "empty deletions emits empty output" "" "$empty_out"

# 10. Non-repo path → exit 4 (fail closed)
nonrepo=$(mktemp -d)
rc=0
classify_workspace_deletions "*deleting   workspaces/ops/foo/x.md" "$nonrepo" 2>/dev/null || rc=$?
assert "non-git-repo hydra_root returns rc 4" "4" "$rc"
rm -rf "$nonrepo"

# 11. Empty-tracked-but-workspaces-populated sanity check (rc 5)
fakeroot=$(mktemp -d)
git -C "$fakeroot" init -q
mkdir -p "$fakeroot/workspaces/ops"
echo untracked > "$fakeroot/workspaces/ops/file.md"
rc=0
classify_workspace_deletions "*deleting   workspaces/ops/foo/x.md" "$fakeroot" 2>/dev/null || rc=$?
assert "empty ever_tracked but workspaces populated returns rc 5" "5" "$rc"
rm -rf "$fakeroot"

# ---- summary ----
if (( fail_count > 0 )); then
    echo ""
    echo "$fail_count test(s) FAILED"
    exit 1
fi
echo ""
echo "All classifier smoke tests passed."

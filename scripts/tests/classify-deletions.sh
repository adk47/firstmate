#!/usr/bin/env bash
# Smoke test for scripts/lib/classify-deletions.sh.
#
# Not a bats suite — there's no broader test harness for deploy tooling yet.
# This is the minimum: a shell script that builds a synthetic git repo,
# pipes synthetic rsync `*deleting` lines through the classifier, and asserts
# the expected AUTO: / REMAIN: partition. Run manually:
#
#   LC_ALL=C bash scripts/tests/classify-deletions.sh
#
# Exits 0 on all-pass, 1 on any failure (prints which case failed). Used
# to validate PR #130's auto-exclude logic pre-merge and to catch future
# regressions if the classifier's regex, awk filter, or ls-files predicate
# is refactored.

set -euo pipefail

# run() sorts the classifier output; pin the collation so the suite does not
# depend on the runner's locale (en_US sorts runtime.log before SOUL.md).
export LC_ALL=C

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
    classify_workspace_deletions "$1" "$TMPROOT" | LC_ALL=C sort  # C collation for consistent test fixture ordering
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

# 3. Untracked file inside a tracked subdir (skills/foo) → AUTO, the file
#    itself (git has never tracked it; node-8 is truth)
assert "untracked file in tracked subdir auto-excludes the file" \
    "AUTO: workspaces/ops/skills/foo/extra.md" \
    "$(run '*deleting   workspaces/ops/skills/foo/extra.md')"

# 3b. Class B (6+7 Oct halts): never-tracked dir nested under a TRACKED
#     subdir → one AUTO for the dir root, trailing slash, not one per file
assert "never-tracked dir under tracked subdir auto-excludes once" \
    "AUTO: workspaces/ops/skills/newskill/" \
    "$(run '*deleting   workspaces/ops/skills/newskill/SKILL.md
*deleting   workspaces/ops/skills/newskill/refs/a.md
*deleting   workspaces/ops/skills/newskill/')"

# 4. Deep path under a never-tracked subdir (workspaces/ops/clients/sub/x.md)
#    → AUTO with `clients/` pattern (NOT deeper — we exclude at the subdir level)
assert "deep path under never-tracked subdir auto-excludes at subdir level" \
    "AUTO: workspaces/ops/clients/" \
    "$(run '*deleting   workspaces/ops/clients/inner/nested/file.md')"

# 5. Class A (8 Oct halt): never-tracked depth-1 workspace FILE under a
#    workspace with tracked seeds → AUTO, the file itself, no trailing slash
assert "never-tracked top-level workspace file auto-excludes" \
    "AUTO: workspaces/ops/runtime.log" \
    "$(run '*deleting   workspaces/ops/runtime.log')"

# 5b. Glob metachars in a never-tracked name are backslash-escaped so the
#     rsync --exclude matches the literal name; unescaped, `[draft]` is a
#     character class and the delete goes through (file form and dir form).
assert "glob metachars in never-tracked file name are escaped" \
    'AUTO: workspaces/ceo/\[draft\] plan.md' \
    "$(run '*deleting   workspaces/ceo/[draft] plan.md')"
assert "glob metachars in never-tracked dir name are escaped" \
    'AUTO: workspaces/ceo/\[wip\]\*/' \
    "$(run '*deleting   workspaces/ceo/[wip]*/notes.md')"
if command -v rsync >/dev/null 2>&1; then
    src=$(mktemp -d); dst=$(mktemp -d)
    mkdir -p "$src/workspaces/ceo" "$dst/workspaces/ceo/[wip]*"
    echo x > "$dst/workspaces/ceo/[draft] plan.md"
    echo x > "$dst/workspaces/ceo/[wip]*/notes.md"
    echo x > "$dst/workspaces/ceo/plain.md"
    excl=()
    while IFS= read -r l; do excl+=("--exclude=${l#AUTO: }"); done < <(
        run '*deleting   workspaces/ceo/[draft] plan.md
*deleting   workspaces/ceo/[wip]*/notes.md' | grep '^AUTO: ')
    assert "real rsync --delete spares the metachar-named paths, deletes the rest" \
        "*deleting workspaces/ceo/plain.md" \
        "$(rsync -rn --delete --itemize-changes "${excl[@]}" "$src/" "$dst/" | grep 'deleting' | grep -v '/$' | tr -s ' ' || true)"
    rm -rf "$src" "$dst"
fi

# 6. Skills-all deletion → REMAIN (not under workspaces/, out of scope)
assert "skills-all deletion stays suspicious" \
    "REMAIN: *deleting   skills-all/foo/SKILL.md" \
    "$(run '*deleting   skills-all/foo/SKILL.md')"

# 7. Mixed batch: auto + tracked (single REMAIN keeps the sort locale-proof)
assert "mixed batch partitions correctly" \
    "AUTO: workspaces/cmo/clients/
AUTO: workspaces/ops/phantom/
AUTO: workspaces/ops/runtime.log
REMAIN: *deleting   workspaces/ops/SOUL.md" \
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

# 12. Once-tracked-then-deleted file (a PR removing a seed): git no longer lists
#     it at HEAD, but history does, so the deletion stays real drift (REMAIN),
#     not a server-only path to auto-exclude.
histroot=$(mktemp -d)
git -C "$histroot" init -q
git -C "$histroot" config user.email test@test
git -C "$histroot" config user.name  test
mkdir -p "$histroot/workspaces/ops"
echo soul > "$histroot/workspaces/ops/SOUL.md"
echo old  > "$histroot/workspaces/ops/obsolete.md"
mkdir -p "$histroot/workspaces/ops/legacy"
echo old  > "$histroot/workspaces/ops/legacy/a.md"
git -C "$histroot" add -A
git -C "$histroot" commit -qm "seed"
git -C "$histroot" rm -q -r workspaces/ops/obsolete.md workspaces/ops/legacy
git -C "$histroot" commit -qm "drop obsolete"
assert "tracked-then-deleted file stays suspicious" \
    "REMAIN: *deleting   workspaces/ops/obsolete.md" \
    "$(classify_workspace_deletions '*deleting   workspaces/ops/obsolete.md' "$histroot" | sort)"
assert "tracked-then-deleted dir stays suspicious" \
    "REMAIN: *deleting   workspaces/ops/legacy/a.md" \
    "$(classify_workspace_deletions '*deleting   workspaces/ops/legacy/a.md' "$histroot" | sort)"
rm -rf "$histroot"

# 13. A failed history read must fail closed (rc 4), not yield a partial
#     ever_tracked set that turns a tracked-then-deleted path into AUTO.
realgit=$(command -v git)
shimdir=$(mktemp -d)
cat > "$shimdir/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == log ]] && exit 128; done
exec "$realgit" "\$@"
SHIM
chmod +x "$shimdir/git"
rc=0
out=$(PATH="$shimdir:$PATH" classify_workspace_deletions '*deleting   workspaces/ops/phantom/x.md' "$TMPROOT" 2>/dev/null) || rc=$?
assert "git log failure returns rc 4 (fail closed)" "4" "$rc"
assert "git log failure emits no AUTO/REMAIN" "" "$out"
rm -rf "$shimdir"

# ---- summary ----
if (( fail_count > 0 )); then
    echo ""
    echo "$fail_count test(s) FAILED"
    exit 1
fi
echo ""
echo "All classifier smoke tests passed."

#!/usr/bin/env bats
# scripts/lib/classify-deletions.sh: builds a synthetic git repo, pipes
# synthetic rsync `*deleting` lines through the classifier, and asserts the
# AUTO: / REMAIN: partition. Ported from classify-deletions.sh (MUS-5136): a
# .sh under scripts/tests/ is not discovered by the Bats job in pr-validate.yml,
# so the suite never ran in CI.
#
#   LC_ALL=C bats scripts/tests/classify-deletions.bats

# run() sorts the classifier output; pin the collation so the suite does not
# depend on the runner's locale (en_US sorts runtime.log before SOUL.md).
export LC_ALL=C

_git() { git -c user.name=test -c user.email=test@test "$@"; }

setup() {
    # shellcheck source=../lib/classify-deletions.sh
    source "$BATS_TEST_DIRNAME/../lib/classify-deletions.sh"
    TMPROOT=$(mktemp -d)
    # Seed a minimal hydra-shaped git repo with the tracked-file shapes the
    # real repo uses (SOUL.md at workspace root, skills/ subdir, reference/
    # subdir).
    git -C "$TMPROOT" init -q
    mkdir -p "$TMPROOT/workspaces/ops/skills/foo" "$TMPROOT/workspaces/cmo/reference"
    echo soul    > "$TMPROOT/workspaces/ops/SOUL.md"
    echo skill   > "$TMPROOT/workspaces/ops/skills/foo/SKILL.md"
    echo ref     > "$TMPROOT/workspaces/cmo/reference/item.md"
    echo cmosoul > "$TMPROOT/workspaces/cmo/SOUL.md"
    git -C "$TMPROOT" add -A
    _git -C "$TMPROOT" commit -qm seed
}

teardown() {
    rm -rf "$TMPROOT" ${EXTRA:-} ${FIXTURE:-}
}

# Usage: _run "<deletions-blob>" [root]; sorted classifier stdout.
_run() {
    classify_workspace_deletions "$1" "${2:-$TMPROOT}" | sort
}

@test "never-tracked subdir auto-excludes" {
    run _run '*deleting   workspaces/ops/phantom/report.pdf
*deleting   workspaces/ops/phantom/'
    [ "$output" = "AUTO: workspaces/ops/phantom/" ]
}

@test "tracked SOUL.md deletion stays suspicious" {
    run _run '*deleting   workspaces/ops/SOUL.md'
    [ "$output" = "REMAIN: *deleting   workspaces/ops/SOUL.md" ]
}

@test "untracked file in tracked subdir auto-excludes the file" {
    run _run '*deleting   workspaces/ops/skills/foo/extra.md'
    [ "$output" = "AUTO: workspaces/ops/skills/foo/extra.md" ]
}

@test "never-tracked dir under tracked subdir auto-excludes once" {
    run _run '*deleting   workspaces/ops/skills/newskill/SKILL.md
*deleting   workspaces/ops/skills/newskill/refs/a.md
*deleting   workspaces/ops/skills/newskill/'
    [ "$output" = "AUTO: workspaces/ops/skills/newskill/" ]
}

@test "deep path under never-tracked subdir auto-excludes at subdir level" {
    run _run '*deleting   workspaces/ops/clients/inner/nested/file.md'
    [ "$output" = "AUTO: workspaces/ops/clients/" ]
}

@test "never-tracked top-level workspace file auto-excludes" {
    run _run '*deleting   workspaces/ops/runtime.log'
    [ "$output" = "AUTO: workspaces/ops/runtime.log" ]
}

@test "glob metachars in never-tracked file name are escaped" {
    run _run '*deleting   workspaces/ceo/[draft] plan.md'
    [ "$output" = 'AUTO: workspaces/ceo/\[draft\] plan.md' ]
}

@test "glob metachars in never-tracked dir name are escaped" {
    run _run '*deleting   workspaces/ceo/[wip]*/notes.md'
    [ "$output" = 'AUTO: workspaces/ceo/\[wip\]\*/' ]
}

@test "real rsync --delete spares the metachar-named paths, deletes the rest" {
    command -v rsync >/dev/null 2>&1 || skip "rsync not installed"
    local src dst
    src=$(mktemp -d); dst=$(mktemp -d); EXTRA="$src $dst"
    mkdir -p "$src/workspaces/ceo" "$dst/workspaces/ceo/[wip]*"
    echo x > "$dst/workspaces/ceo/[draft] plan.md"
    echo x > "$dst/workspaces/ceo/[wip]*/notes.md"
    echo x > "$dst/workspaces/ceo/plain.md"
    local excl=() l
    while IFS= read -r l; do excl+=("--exclude=${l#AUTO: }"); done < <(
        _run '*deleting   workspaces/ceo/[draft] plan.md
*deleting   workspaces/ceo/[wip]*/notes.md' | grep '^AUTO: ')
    run bash -c 'rsync -rn --delete --itemize-changes "$@" | grep deleting | grep -v "/$" | tr -s " "' _ \
        "${excl[@]}" "$src/" "$dst/"
    [ "$output" = "*deleting workspaces/ceo/plain.md" ]
}

@test "skills-all deletion stays suspicious" {
    run _run '*deleting   skills-all/foo/SKILL.md'
    [ "$output" = "REMAIN: *deleting   skills-all/foo/SKILL.md" ]
}

@test "mixed batch partitions correctly" {
    run _run '*deleting   workspaces/ops/phantom/report.pdf
*deleting   workspaces/cmo/clients/jamstik.md
*deleting   workspaces/ops/SOUL.md
*deleting   workspaces/ops/runtime.log'
    [ "$output" = "AUTO: workspaces/cmo/clients/
AUTO: workspaces/ops/phantom/
AUTO: workspaces/ops/runtime.log
REMAIN: *deleting   workspaces/ops/SOUL.md" ]
}

@test "multiple deletions under same subdir dedupe to one AUTO" {
    run _run '*deleting   workspaces/ops/phantom/a.md
*deleting   workspaces/ops/phantom/b.md
*deleting   workspaces/ops/phantom/c.md
*deleting   workspaces/ops/phantom/'
    [ "$output" = "AUTO: workspaces/ops/phantom/" ]
}

@test "empty deletions emits empty output" {
    run classify_workspace_deletions "" "$TMPROOT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "non-git-repo hydra_root returns rc 4" {
    EXTRA=$(mktemp -d)
    run classify_workspace_deletions "*deleting   workspaces/ops/foo/x.md" "$EXTRA"
    [ "$status" -eq 4 ]
}

@test "empty ever_tracked but workspaces populated returns rc 5" {
    EXTRA=$(mktemp -d)
    git -C "$EXTRA" init -q
    mkdir -p "$EXTRA/workspaces/ops"
    echo untracked > "$EXTRA/workspaces/ops/file.md"
    run classify_workspace_deletions "*deleting   workspaces/ops/foo/x.md" "$EXTRA"
    [ "$status" -eq 5 ]
}

# A PR removing a seed: git no longer lists it at HEAD, but history does, so
# the deletion stays real drift (REMAIN), not a server-only path to auto-exclude.
_tracked_then_deleted_repo() {
    FIXTURE=$(mktemp -d)
    git -C "$FIXTURE" init -q
    mkdir -p "$FIXTURE/workspaces/ops/legacy"
    echo soul > "$FIXTURE/workspaces/ops/SOUL.md"
    echo old  > "$FIXTURE/workspaces/ops/obsolete.md"
    echo old  > "$FIXTURE/workspaces/ops/legacy/a.md"
    git -C "$FIXTURE" add -A
    _git -C "$FIXTURE" commit -qm seed
    git -C "$FIXTURE" rm -q -r workspaces/ops/obsolete.md workspaces/ops/legacy
    _git -C "$FIXTURE" commit -qm "drop obsolete"
}

@test "tracked-then-deleted file stays suspicious" {
    _tracked_then_deleted_repo
    run _run '*deleting   workspaces/ops/obsolete.md' "$FIXTURE"
    [ "$output" = "REMAIN: *deleting   workspaces/ops/obsolete.md" ]
}

@test "tracked-then-deleted dir stays suspicious" {
    _tracked_then_deleted_repo
    run _run '*deleting   workspaces/ops/legacy/a.md' "$FIXTURE"
    [ "$output" = "REMAIN: *deleting   workspaces/ops/legacy/a.md" ]
}

# A failed history read must fail closed (rc 4), not yield a partial
# ever_tracked set that turns a tracked-then-deleted path into AUTO.
@test "git log failure returns rc 4 and emits no AUTO/REMAIN" {
    local realgit shimdir
    realgit=$(command -v git)
    shimdir=$(mktemp -d); EXTRA=$shimdir
    cat > "$shimdir/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == log ]] && exit 128; done
exec "$realgit" "\$@"
SHIM
    chmod +x "$shimdir/git"
    local out rc=0
    out=$(PATH="$shimdir:$PATH" classify_workspace_deletions \
        '*deleting   workspaces/ops/phantom/x.md' "$TMPROOT" 2>/dev/null) || rc=$?
    [ "$rc" -eq 4 ]
    [ -z "$out" ]
}

# Real --depth 1 clone of the tracked-then-deleted fixture. --depth is ignored
# for a bare local path, so file:// is mandatory; a hand-written
# "shallow-looking" fixture would not exercise the real truncated history.
@test "shallow clone fails closed (rc 4, names fetch-depth: 0, zero AUTO)" {
    _tracked_then_deleted_repo
    local shallow
    shallow=$(mktemp -d); EXTRA=$shallow
    git clone -q --depth 1 "file://$FIXTURE" "$shallow/c"
    [ "$(git -C "$shallow/c" rev-parse --is-shallow-repository)" = "true" ]
    # stderr is merged into $output: the message must name the remedy and no
    # line may be an AUTO: exclude.
    run bash -c 'source "$1"; classify_workspace_deletions "$2" "$3" 2>&1' _ \
        "$BATS_TEST_DIRNAME/../lib/classify-deletions.sh" \
        '*deleting   workspaces/ops/obsolete.md
*deleting   workspaces/ops/legacy/a.md' "$shallow/c"
    [ "$status" -eq 4 ]
    [[ "$output" == *"fetch-depth: 0"* ]]
    ! grep -q '^AUTO:' <<<"$output"
}

@test "full clone of the same fixture still REMAINs tracked-then-deleted paths" {
    _tracked_then_deleted_repo
    local full
    full=$(mktemp -d); EXTRA=$full
    git clone -q "file://$FIXTURE" "$full/c"
    run _run '*deleting   workspaces/ops/obsolete.md
*deleting   workspaces/ops/legacy/a.md' "$full/c"
    [ "$output" = "REMAIN: *deleting   workspaces/ops/legacy/a.md
REMAIN: *deleting   workspaces/ops/obsolete.md" ]
}

#!/usr/bin/env bats
# Tests for check-no-canonical-godmode-allowlist.sh.
#
# The guard protects a one-file invariant: tier2-godmode-allowlist.txt may exist
# in the operations workspace and NOWHERE else. Since 2026-08-26 the god-mode
# self-approve branch ships in both copies of muso-admin-api.sh (parity gate),
# so that file's absence from skills-all/ is the only thing keeping ceo/cmo/cto/
# caroline from self-approving mass deletions.
#
# Each test runs the guard against a THROWAWAY tree, never the real repo — a
# test that had to create the forbidden file in-place would be one crash away
# from leaving a fleet-wide privilege grant behind.

setup() {
    TEST_ROOT="$(mktemp -d)"
    export TEST_ROOT
    REAL_SCRIPT="${BATS_TEST_DIRNAME}/../check-no-canonical-godmode-allowlist.sh"
    [[ -f "$REAL_SCRIPT" ]] || { echo "guard not found: $REAL_SCRIPT" >&2; return 1; }

    # Minimal fake repo: scripts/ + the two config dirs the guard reads.
    mkdir -p "$TEST_ROOT/scripts" \
             "$TEST_ROOT/skills-all/muso-ops-admin/config" \
             "$TEST_ROOT/workspaces/operations/skills/muso-ops-admin/config"
    cp "$REAL_SCRIPT" "$TEST_ROOT/scripts/"
    SCRIPT="$TEST_ROOT/scripts/check-no-canonical-godmode-allowlist.sh"

    # The guard now also pins the canonical script's TIER2_GODMODE_PATH default,
    # because the checkout is not the deployed tree (deploy.sh preserves a
    # server-only canonical allowlist).
    mkdir -p "$TEST_ROOT/skills-all/muso-ops-admin/scripts"
    CANON="$TEST_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
    printf '%s\n' 'TIER2_GODMODE_PATH="/nonexistent/canonical-copy-has-no-god-mode"' > "$CANON"

    WORKSPACE_ALLOWLIST="$TEST_ROOT/workspaces/operations/skills/muso-ops-admin/config/tier2-godmode-allowlist.txt"
    CANONICAL_ALLOWLIST="$TEST_ROOT/skills-all/muso-ops-admin/config/tier2-godmode-allowlist.txt"
    printf 'aaron@muso.ai\njan@muso.ai\nnick@muso.ai\n' > "$WORKSPACE_ALLOWLIST"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

@test "passes on the correct layout: workspace has it, canonical does not" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workspace-only"* ]]
}

@test "FAILS when the allowlist appears in the canonical skill" {
    printf 'aaron@muso.ai\n' > "$CANONICAL_ALLOWLIST"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"skills-all/muso-ops-admin/config/tier2-godmode-allowlist.txt exists"* ]]
}

# An EMPTY forbidden file is still forbidden: `[[ -e ]]`, not `[[ -s ]]`. An
# empty file today is a populated file after one careless edit, and it would
# already be rsynced to every agent by then.
@test "FAILS on an EMPTY canonical allowlist, not just a populated one" {
    : > "$CANONICAL_ALLOWLIST"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

# A symlink is a file for rsync's purposes too.
@test "FAILS when the canonical path is a symlink to the workspace copy" {
    ln -s "$WORKSPACE_ALLOWLIST" "$CANONICAL_ALLOWLIST"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "FAILS loudly when the workspace copy is missing (silent revert to --confirmed-by)" {
    rm -f "$WORKSPACE_ALLOWLIST"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is missing"* ]]
    [[ "$output" == *"second human"* ]]
}

# Both problems at once must report BOTH, not stop at the first.
@test "reports both failures together rather than short-circuiting" {
    printf 'aaron@muso.ai\n' > "$CANONICAL_ALLOWLIST"
    rm -f "$WORKSPACE_ALLOWLIST"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists"* ]]
    [[ "$output" == *"is missing"* ]]
}

# A vanished canonical config dir must be a hard error, never a vacuous pass —
# "the directory isn't there so nothing forbidden is in it" is exactly the
# fail-open shape this repo keeps getting bitten by.
@test "missing canonical config dir exits 2, never a vacuous pass" {
    rm -rf "$TEST_ROOT/skills-all/muso-ops-admin/config"
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"cannot prove anything"* ]]
}

# The guard must be checking the real repo too, not only its test fixtures.
@test "the REAL repo satisfies the invariant" {
    run bash "$REAL_SCRIPT"
    [ "$status" -eq 0 ]
}

# --- the deployed-tree hole (QA #873) ------------------------------------
#
# deploy.sh deliberately preserves a SERVER-ONLY canonical
# tier2-godmode-allowlist.txt, present on node-8 with aaron/jan/nick in it. So
# "absent from the checkout" never proved "absent at runtime": before this pin,
# the guard was green while the deployed canonical script would have read that
# file and granted bulk-DELETE self-approval to every canonical caller.

@test "FAILS if the canonical default resolves into a real config dir" {
    # Non-overridable form on purpose: the env-override check fires first, so
    # this fixture must isolate the "points at a real config dir" branch.
    printf '%s\n' 'TIER2_GODMODE_PATH="${SCRIPT_DIR}/../config/tier2-godmode-allowlist.txt"' > "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"resolves TIER2_GODMODE_PATH into a real config directory"* ]]
}

@test "FAILS if the canonical script has no TIER2_GODMODE_PATH default at all" {
    : > "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no TIER2_GODMODE_PATH default to pin"* ]]
}

@test "a missing canonical script is a hard error, not a vacuous pass" {
    rm -f "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 2 ]
}

# The end-to-end property: with the impossible default, a canonical allowlist
# sitting next to the deployed script (the server-only file) is INERT.
@test "canonical stays fail-closed even when an allowlist sits in its config dir" {
    printf 'jan@muso.ai\n' > "$TEST_ROOT/skills-all/muso-ops-admin/config/tier2-godmode-allowlist.txt"
    run bash "$SCRIPT"
    # the placement gate still objects to the file being in the checkout...
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists"* ]]
    # ...and the pinned default means it would not be READ even if it were there
    grep -q '/nonexistent/' "$CANON"
}

@test "FAILS if the canonical default reintroduces an env override" {
    printf '%s\n' 'TIER2_GODMODE_PATH="${TIER2_GODMODE_PATH:-/nonexistent/x}"' > "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"accepts an environment override"* ]]
}

# --- gaps the review found in this guard (QA #873) ------------------------

# [[ -e ]] FOLLOWS the symlink, so a link whose target does not exist reads as
# "absent". A dangling link is not harmless: it goes live the moment anything
# creates its target. The earlier symlink test used a VALID link and so never
# exercised this.
@test "FAILS on a DANGLING canonical allowlist symlink (-e follows the link)" {
    ln -s "$TEST_ROOT/does-not-exist-yet.txt" "$CANONICAL_ALLOWLIST"
    [ ! -e "$CANONICAL_ALLOWLIST" ]   # precondition: -e is false, -L is true
    [ -L "$CANONICAL_ALLOWLIST" ]
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"exists"* ]]
}

# The LAST assignment wins at runtime, so a pinned line followed by an
# overridable one is a bypass that a first-line-only parser would call clean.
@test "FAILS when the canonical script assigns the god-mode path twice" {
    {
      printf '%s\n' 'TIER2_GODMODE_PATH="/nonexistent/canonical-copy-has-no-god-mode"'
      printf '%s\n' 'TIER2_GODMODE_PATH="${TIER2_GODMODE_PATH:-/tmp/attacker.txt}"'
    } > "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"assigns TIER2_GODMODE_PATH 2 times"* ]]
}

# Any value other than the exact pinned literal is refused, including plausible
# ones with no ${VAR} and no /config/ in them.
@test "FAILS on an unpinned literal path that dodges the other checks" {
    printf '%s\n' 'TIER2_GODMODE_PATH="/tmp/allow.txt"' > "$CANON"
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not carry the pinned god-mode path"* ]]
}

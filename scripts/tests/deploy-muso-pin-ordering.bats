#!/usr/bin/env bats
# Tests the ORDERING invariant around the muso CLI pin in scripts/deploy.sh.
#
# Why this suite exists: skills call muso verbs, and the two directions of skew
# are NOT symmetric.
#   CLI newer than skills -> safe (verbs are additive; an older skill only
#                            calls verbs that still exist)
#   skills newer than CLI -> BROKEN (muso-github-code-review calling `muso gh`
#                            against 0.11.1 dies "unknown command", which reads
#                            as a broken skill rather than a stale pin)
#
# Until PR #790 the pin ran at Step 4d.6 — AFTER the Step 4b rsync and the Step
# 4c managed-skills sync. Every deploy therefore had a window with new skills
# live against the old CLI, and because a failed pin calls `fail`, an install
# error ABORTED the deploy with the incompatible skills already on the server
# and no rollback. The fix moved the pin to Step 4a.5, before any sync.
#
# SCOPE — read this before trusting a green run. These are STATIC assertions
# over deploy.sh's source, not an execution of the deploy. deploy.sh runs its
# work at top level (it is a script, not a sourceable lib), so exercising the
# real abort path would require executing a deploy against a live host. What
# these tests DO catch is the regression that actually happened: the call site
# drifting back below a sync, or a second call site reintroducing the window.
# Runtime behaviour of install_muso itself is still uncovered; extracting it to
# scripts/lib/ (the pattern deploy-stale-guard.bats follows) is the way to fix
# that, and is deliberately out of scope here.

DEPLOY="${BATS_TEST_DIRNAME}/../deploy.sh"

# line_of <extended-regex> — first matching line number in deploy.sh.
# Fails loudly rather than returning empty, so a renamed anchor surfaces as a
# failed test instead of a vacuous 0 < 0 comparison that always passes.
line_of() {
  local n
  n=$(grep -nE "$1" "$DEPLOY" | head -1 | cut -d: -f1)
  [ -n "$n" ] || { echo "anchor not found in deploy.sh: $1" >&2; return 1; }
  echo "$n"
}

@test "the muso pin is invoked before the repo rsync" {
  pin=$(line_of '^\s*if ! install_muso; then')
  rsync_step=$(line_of 'Step 4b/8: (Local sync|Remote sync)')
  [ "$pin" -lt "$rsync_step" ] || {
    echo "install_muso at :$pin runs AFTER the rsync at :$rsync_step"
    echo "-> new skills would reach the server before the CLI they require"
    return 1; }
}

@test "the muso pin is invoked before the managed-skills sync" {
  pin=$(line_of '^\s*if ! install_muso; then')
  skills=$(line_of 'Step 4c/8: Syncing global skills')
  [ "$pin" -lt "$skills" ] || {
    echo "install_muso at :$pin runs AFTER the skills sync at :$skills"
    return 1; }
}

@test "a failed pin aborts the deploy instead of continuing to sync" {
  # The guard is `if ! install_muso; then fail ...` — without the `fail`, a
  # failed install would fall through and sync skills against the old CLI,
  # which is the same breakage the ordering fix exists to prevent.
  pin=$(line_of '^\s*if ! install_muso; then')
  end=$(( pin + 3 ))
  hits=$(sed -n "${pin},${end}p" "$DEPLOY" | grep -c 'fail ')
  [ "$hits" -ge 1 ] || {
    echo "no 'fail' within 3 lines of the install_muso guard at :$pin"
    echo "-> a failed pin would fall through and deploy anyway"
    sed -n "${pin},${end}p" "$DEPLOY" | sed 's/^/  /'
    return 1; }
}

@test "there is exactly ONE install_muso call site" {
  # The adjacent regression: leaving (or re-adding) the old Step 4d.6 call
  # would silently restore the post-sync window even though the new early call
  # exists and the ordering tests above still pass.
  count=$(grep -cE '^\s*if ! install_muso; then' "$DEPLOY")
  [ "$count" -eq 1 ] || {
    echo "expected 1 install_muso call site, found $count"
    grep -nE '^\s*if ! install_muso; then' "$DEPLOY" | sed 's/^/  /'
    return 1; }
}

# --- the floor guard --------------------------------------------------------
# Ordering is necessary but NOT sufficient: MUSO_CLI_VERSION is overrideable, so
# `MUSO_CLI_VERSION=0.11.1 scripts/deploy.sh` installs an OLD CLI first, passes
# install_muso's post-install assertion (which only checks installed ==
# requested), and then syncs a skill that dies "unknown command gh". These run
# deploy.sh for real with --help so the guard executes but no deploy does.

@test "an override BELOW the floor is refused" {
  run env MUSO_CLI_VERSION=0.11.1 bash "$DEPLOY" --help
  [ "$status" -ne 0 ]
  [[ "$output" == *"below the 0.12.0 floor"* ]] || {
    echo "a downgrade past the floor was NOT refused:"; echo "$output" | head -5; return 1; }
}

@test "the floor itself is accepted (boundary is inclusive)" {
  run env MUSO_CLI_VERSION=0.12.0 bash "$DEPLOY" --help
  [[ "$output" != *"below the"*"floor"* ]] || {
    echo "the floor version was wrongly refused"; return 1; }
}

@test "an override ABOVE the floor is accepted" {
  run env MUSO_CLI_VERSION=2026.1.0 bash "$DEPLOY" --help
  [[ "$output" != *"below the"*"floor"* ]] || {
    echo "a newer CLI was wrongly refused — verbs are additive, newer is safe"; return 1; }
}

@test "the floor covers the newest verb the shipped skill actually calls" {
  # Couples the constant to reality: if muso-github-code-review calls `muso gh`
  # (added in 0.12.0), the floor must be at least 0.12.0. Without this, someone
  # lowers the floor, every other test still passes, and the lockstep is gone.
  skill="${BATS_TEST_DIRNAME}/../../skills-all/muso-github-code-review/SKILL.md"
  floor=$(grep -E '^MUSO_CLI_MIN_VERSION=' "$DEPLOY" | head -1 | cut -d'"' -f2)
  if grep -q 'muso gh ' "$skill"; then
    run bash -c "source '${BATS_TEST_DIRNAME}/../lib/version-compare.sh'; version_at_least 0.12.0 '$floor'"
    [ "$status" -eq 0 ] || {
      echo "skill calls 'muso gh' (needs >=0.12.0) but the floor is $floor"; return 1; }
  fi
}

@test "the pinned version is a bare semver, not a range or 'latest'" {
  # install_muso feeds this straight into `gh release download v${VERSION}` and
  # then asserts `muso version --json` equals it, so anything non-literal fails
  # the post-install assertion at deploy time rather than here.
  run bash -c "grep -E '^MUSO_CLI_VERSION=' '$DEPLOY' | head -1"
  [[ "$output" =~ ^MUSO_CLI_VERSION=\"\$\{MUSO_CLI_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}\"$ ]] || {
    echo "unexpected pin shape: $output"; return 1; }
}

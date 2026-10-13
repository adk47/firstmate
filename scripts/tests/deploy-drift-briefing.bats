#!/usr/bin/env bats
# Tests for scripts/deploy.sh's Step 4a DRIFT_BRIEFING — the operator-facing
# halt message printed when compute_skill_block_lines (scripts/lib/drift-
# check.sh) finds SERVER-AHEAD/CONFLICT skill drift.
#
# Why this suite exists: MUS-1792 round 2 (QA finding 1, 2026-10-01). When
# the skill-drift gate widened from skills-all/ only to also cover
# workspaces/<ws>/skills/**/SKILL.md, pr-skill-drift-gate.sh's remediation
# printer was fixed to pick the right scripts/sync-from-server.sh target per
# path — but deploy.sh's OWN copy of the same printer, in this briefing, was
# missed. It kept handing an operator a `sync-from-server.sh skills --apply
# --only workspaces/...` command that sync-from-server.sh's own --only
# validation rejects with exit 1, in the one message whose entire purpose is
# to stop them reaching for HYDRA_FORCE=1 (which permanently destroys the
# server-side work). The fix: deploy.sh now calls the same
# format_skill_capture_commands / format_skill_conflict_commands /
# sync_target_for_path functions in scripts/lib/drift-check.sh that
# pr-skill-drift-gate.sh uses — one source of truth, bats-tested directly in
# drift-check.bats (not just asserted here).
#
# SCOPE — these are STATIC assertions over deploy.sh's source, following the
# pattern in deploy-muso-pin-ordering.bats: deploy.sh runs its work at top
# level (it is a script, not a sourceable lib), so exercising the real Step
# 4a halt would require executing a deploy against a live host. The actual
# command-generation logic is covered by real execution tests in
# drift-check.bats (format_skill_capture_commands / format_skill_conflict_commands
# / sync_target_for_path) and sync-from-server-only.bats (the generated
# command actually succeeds under the right target). What these tests catch
# is the regression that actually happened: deploy.sh's copy of the printer
# drifting back to a hardcoded target, or the stale skills-all/-only prose
# reappearing.

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

@test "deploy.sh syntax checks clean (heredoc command substitutions well-formed)" {
  run bash -n "$DEPLOY"
  [ "$status" -eq 0 ]
}

@test "the DRIFT_BRIEFING SAFE FIX calls format_skill_capture_commands, not a hardcoded skills target" {
  start=$(line_of 'THE SAFE FIX — capture per file')
  end=$(( start + 10 ))
  block=$(sed -n "${start},${end}p" "$DEPLOY")
  echo "$block" | grep -qF 'format_skill_capture_commands "$skills_drift"' || {
    echo "SAFE FIX block does not call format_skill_capture_commands:"
    echo "$block" | sed 's/^/  /'
    return 1; }
  if echo "$block" | grep -qF 'sync-from-server.sh skills --apply --only <path>'; then
    echo "SAFE FIX block still has the old hardcoded-target placeholder line"
    return 1; fi
}

@test "the DRIFT_BRIEFING CONFLICT instructions call format_skill_conflict_commands" {
  start=$(line_of 'CONFLICT — 3-way merge by hand \(both sides changed\)')
  end=$(( start + 4 ))
  sed -n "${start},${end}p" "$DEPLOY" | grep -qF 'format_skill_conflict_commands "$skills_drift"'
}

@test "there is exactly one skill-drift DRIFT_BRIEFING heredoc (Step 4a, the classifier-driven one)" {
  # Step 0's separate pre-sync drift briefing (a different heredoc, line
  # ~1694, informational-only and not part of this gate) also uses the
  # DRIFT_BRIEFING delimiter name — so this counts occurrences of the
  # skill-drift-specific banner text, not the delimiter.
  count=$(grep -cF '✗ DEPLOY BLOCKED — skill drift between node-8 and the repo' "$DEPLOY")
  [ "$count" -eq 1 ] || {
    echo "expected exactly 1 skill-drift DRIFT_BRIEFING banner, found $count"
    return 1; }
}

@test "the DRIFT_BRIEFING banner and body no longer claim skills-all/ is the only drifted tree" {
  start=$(line_of '✗ DEPLOY BLOCKED — skill drift between node-8 and the repo')
  end=$(( start + 16 ))
  block=$(sed -n "${start},${end}p" "$DEPLOY")
  echo "$block" | grep -q 'workspaces/' || {
    echo "DRIFT_BRIEFING banner/body does not mention workspaces/ at all:"
    echo "$block" | sed 's/^/  /'
    return 1; }
  if echo "$block" | grep -qE 'skills-all/ drift|differ between /opt/hydra/skills-all/ on node-8 and this'; then
    echo "DRIFT_BRIEFING still contains the stale skills-all/-only wording"
    return 1; fi
}

@test "the drift fail() message no longer says 'skills-all drift'" {
  run grep -c 'fail "skills-all drift' "$DEPLOY"
  [ "$status" -ne 0 ] || [ "$output" -eq 0 ]
}

@test "deploy.sh and pr-skill-drift-gate.sh resolve the sync target the same way (sync_target_for_path, not independent copies)" {
  # Regression guard for the actual root cause: grep every live occurrence
  # of a hardcoded 'skills --apply --only' or 'workspaces --apply --only'
  # remediation command outside of scripts/lib/drift-check.sh and
  # scripts/tests/ — any hit is a third inline copy of the decision that can
  # go stale again, same as the one QA found.
  # Tolerate column alignment ("skills     --apply"), and exempt the static
  # operator-doc menus that print a literal <path> placeholder for every
  # target (deploy.sh Step 0 and the deletion briefing): those enumerate all
  # three targets and the operator supplies the path, so there is no per-path
  # target decision in them to go stale. The bug this guards is a hardcoded
  # target paired with a REAL path -- see sync_target_for_path's comment in
  # scripts/lib/drift-check.sh.
  hits=$(grep -nE "sync-from-server\.sh +(skills|workspaces) +--apply +--only" \
    "$DEPLOY" "${BATS_TEST_DIRNAME}/../pr-skill-drift-gate.sh" 2>/dev/null \
    | grep -vE -- "--apply +--only +<[a-z]+>" || true)
  if [[ -n "$hits" ]]; then
    echo "found a hardcoded --apply --only target outside scripts/lib/drift-check.sh:"
    echo "$hits"
    return 1
  fi
}

# QA round 3 (2026-10-01) finding 2 on this suite: the test above greps for
# the target as a LITERAL inside the printf format string, so it is blind to
# a hardcoded target passed in as the %s ARGUMENT instead (exactly what
# pr-skill-drift-gate.sh had before round 2). QA proved this by reverting
# pr-skill-drift-gate.sh's call site to a hardcoded "skills" variable: this
# suite stayed green, and only pr-skill-drift-gate.bats caught it. These two
# tests close that gap by asserting the %s argument IS a sync_target_for_path
# call, at each printer's own capture-command printf line.

@test "pr-skill-drift-gate.sh's capture command target argument is a sync_target_for_path call, not a separately-computed variable" {
  line=$(grep -n "scripts/sync-from-server.sh %s --apply --only %q" \
    "${BATS_TEST_DIRNAME}/../pr-skill-drift-gate.sh")
  [ -n "$line" ] || { echo "anchor printf line not found in pr-skill-drift-gate.sh"; return 1; }
  echo "$line" | grep -qF 'sync_target_for_path' || {
    echo "the %s argument on this line is not a sync_target_for_path call:"
    echo "  $line"
    return 1; }
}

@test "drift-check.sh's format_skill_capture_commands target argument is a sync_target_for_path call" {
  line=$(grep -n "scripts/sync-from-server.sh %s --apply --only %q" \
    "${BATS_TEST_DIRNAME}/../lib/drift-check.sh")
  [ -n "$line" ] || { echo "anchor printf line not found in drift-check.sh"; return 1; }
  echo "$line" | grep -qF 'sync_target_for_path' || {
    echo "the %s argument on this line is not a sync_target_for_path call:"
    echo "  $line"
    return 1; }
}

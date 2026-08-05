#!/usr/bin/env bats
# Tests for scripts/check-blast-radius.sh — the advisory impact analyzer.
# Every test runs against a throwaway git repo with origin/main set via
# update-ref (BR_SKIP_FETCH=1 → no network). The analyzer makes no gh calls,
# so there is no gh stub here; it reads git and the working tree only.
#
# Two classes of test carry their weight together, per the skill's own lens 8:
# a DISCRIMINATION test (the signal fires when it should) is always paired with
# a STABILITY test (it does NOT fire on the lookalike). The lookalikes are not
# invented — both were real false positives in the first run of this analyzer:
# a review-rubric paragraph MENTIONING "Guard 7" tiered a docs PR CRITICAL, and
# basename matching made skills-all/<x>/SKILL.md report 123 phantom callers.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-blast-radius.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  R="$TEST_TMPDIR/repo"; export R
  STATE="$TEST_TMPDIR/state"; export STATE
  mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t.test
  git -C "$R" config user.name tester
  # Baseline commit so there is always a merge-base to diff against.
  mkdir -p "$R/scripts" "$R/docs"
  printf 'seed\n' > "$R/docs/seed.md"
  git -C "$R" add -A
  git -C "$R" commit -q -m "seed"
  BASE="$(git -C "$R" rev-parse HEAD)"; export BASE
  git -C "$R" update-ref refs/remotes/origin/main "$BASE"
  PR_NUM=42; export PR_NUM
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# --- fixture helpers ---------------------------------------------------------

# addf <path> <content> — write a file and commit it
addf() {
  mkdir -p "$R/$(dirname "$1")"
  printf '%s\n' "$2" > "$R/$1"
  git -C "$R" add -- "$1"
  git -C "$R" commit -q -m "add $1"
}

tip() { git -C "$R" rev-parse HEAD; }

# analyze [VAR=val ...] — run the analyzer on HEAD inside $R.
# NOTE: callers use `run analyze`, which executes in a SUBSHELL — nothing this
# function exports survives back into the test. So the head sha is re-derived by
# state_file() from git rather than passed through a variable.
analyze() {
  ( cd "$R" && env BR_SKIP_FETCH=1 BR_STATE_DIR="$STATE" "$@" \
      "$SCRIPT" "$PR_NUM" "$(tip)" )
}

# HEAD_SHA is honoured when a test pins one deliberately (the unresolvable-head
# case); otherwise the current tip is used.
state_file() { echo "$STATE/Muso-AI__hydra-pr-${PR_NUM}-${HEAD_SHA:-$(tip)}.json"; }
tier()   { jq -r '.tier'   "$(state_file)"; }
status() { jq -r '.status' "$(state_file)"; }
# has_signal <id> — 0 if the signal fired
has_signal() { jq -e --arg i "$1" '.signals | map(.id) | index($i)' "$(state_file)" >/dev/null; }

# =============================================================================
# Tier floor + the LOW baseline
# =============================================================================

@test "no reviewable changes → CLEAN + tier LOW" {
  run analyze
  [ "$status" -eq 0 ]
  [ "$(status)" = "CLEAN" ]
  [ "$(tier)" = "LOW" ]
}

@test "docs-only change → tier LOW (the calibration floor)" {
  addf docs/runbooks/thing.md "some prose"
  run analyze
  [ "$status" -eq 0 ]
  [ "$(tier)" = "LOW" ]
}

# =============================================================================
# gate-edit — discrimination AND stability
# =============================================================================

@test "gate-edit: a check-*.sh file → CRITICAL" {
  addf scripts/check-thing.sh '#!/usr/bin/env bash
echo hi'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal gate-edit
}

@test "gate-edit: ensure-*.sh is covered" {
  addf scripts/ensure-thing.sh 'echo a'
  run analyze
  has_signal gate-edit
  [ "$(jq -r '[.signals[]|select(.id=="gate-edit")|.evidence[]]|join(",")' "$(state_file)")" = "scripts/ensure-thing.sh" ]
}

@test "gate-edit: validate-*.sh is covered INDEPENDENTLY" {
  # Must advance the baseline first. Previously this reused the ensure-*.sh
  # fixture's diff, so gate-edit fired from `ensure-` and the `validate`
  # alternative could be deleted from the regex with every test still green.
  addf scripts/ensure-thing.sh 'echo a'
  git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  addf scripts/validate-thing.sh 'echo b'
  run analyze
  has_signal gate-edit
  [ "$(jq -r '[.signals[]|select(.id=="gate-edit")|.evidence[]]|join(",")' "$(state_file)")" = "scripts/validate-thing.sh" ]
}

@test "gate-edit: the approval wrapper itself is covered by path, without a Guard token" {
  addf scripts/qa-pr-approve.sh '#!/usr/bin/env bash
echo nothing special here'
  run analyze
  has_signal gate-edit
  [ "$(tier)" = "CRITICAL" ]
}

@test "gate-edit: a 'Guard N' block added in SHELL fires the signal" {
  addf scripts/ordinary.sh '# --- Guard 4: something ---
die 4 "nope"'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal gate-edit
}

@test "gate-edit STABILITY: 'Guard N' in MARKDOWN PROSE does not fire" {
  # The regression this pairs with: the review rubric gained a paragraph saying
  # "before Guard 7 will let the PR through" and the analyzer tiered that
  # docs-only change CRITICAL. Content checks must read code, never prose.
  addf docs/notes.md 'Every false finding is a thread a human must resolve
before Guard 7 will let the PR through.'
  run analyze
  run has_signal gate-edit
  [ "$status" -ne 0 ]
}

# =============================================================================
# credential-surface / fleet-config
# =============================================================================

@test "credential-surface: secrets/ path → CRITICAL" {
  addf secrets/thing.conf 'token=abc'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal credential-surface
}

@test "credential-surface: a .env file → CRITICAL" {
  addf config/main.env 'FOO=bar'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal credential-surface
}

@test "fleet-config: openclaw-main.json → CRITICAL" {
  addf openclaw-main.json '{}'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal fleet-config
}

@test "fleet-config: policies/ → CRITICAL" {
  addf policies/some-policy.json '{}'
  run analyze
  [ "$(tier)" = "CRITICAL" ]
  has_signal fleet-config
}

# =============================================================================
# reverse-callers — including the basename over-match regression
# =============================================================================

@test "reverse-callers: a referenced script fires, below the high threshold → MEDIUM" {
  addf scripts/lib/helper.sh 'echo helper'
  addf scripts/caller-one.sh 'bash scripts/lib/helper.sh'
  # Re-touch the helper so IT is the changed file with a caller present.
  addf scripts/lib/helper.sh 'echo helper v2'
  run analyze BR_CALLERS_HIGH=5
  has_signal reverse-callers
  [ "$(tier)" = "MEDIUM" ]
}

@test "reverse-callers: at/above BR_CALLERS_HIGH → HIGH" {
  addf scripts/lib/helper.sh 'echo helper'
  for i in 1 2 3; do addf "scripts/caller-$i.sh" "bash scripts/lib/helper.sh"; done
  addf scripts/lib/helper.sh 'echo helper v2'
  run analyze BR_CALLERS_HIGH=3
  has_signal reverse-callers
  [ "$(tier)" = "HIGH" ]
}

@test "reverse-callers STABILITY: a skill's SKILL.md does not match every other SKILL.md" {
  # The regression: matching by BASENAME meant skills-all/<x>/SKILL.md matched
  # every SKILL.md in the repo — 123 phantom callers for a file with none.
  # Identity for a bundle is its DIRECTORY name, not the filename.
  addf skills-all/other-skill/SKILL.md 'unrelated skill'
  addf skills-all/another-skill/SKILL.md 'also unrelated'
  addf skills-all/target-skill/SKILL.md 'the one being changed'
  run analyze
  # No file anywhere references the string "target-skill", so there are no callers.
  run has_signal reverse-callers
  [ "$status" -ne 0 ]
}

@test "reverse-callers: a skill IS matched by its directory name when truly referenced" {
  addf skills-all/target-skill/SKILL.md 'the one being changed'
  addf scripts/dispatch.sh 'run skills-all/target-skill'
  addf skills-all/target-skill/SKILL.md 'changed again'
  run analyze
  has_signal reverse-callers
}

# =============================================================================
# cron-reach / state-mutation / skill-reach / test-gap
# =============================================================================

@test "cron-reach: a script named in an EXISTING cron-jobs.json → HIGH" {
  # cron-jobs.json lives in the BASE, not the diff: changing it would fire
  # fleet-config (critical) and mask the tier this test is actually pinning.
  addf cron-jobs.json '{"jobs":[{"cmd":"bash scripts/nightly.sh"}]}'
  git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  addf scripts/nightly.sh 'echo nightly'
  run analyze
  has_signal cron-reach
  [ "$(tier)" = "HIGH" ]
}

@test "cron-reach: a script named in a systemd unit under scripts/aux-units/ → HIGH" {
  # The signal originally searched `systemd/`, which does not exist in this repo
  # (units live in scripts/aux-units/), so no unit-invoked script could ever fire
  # it. A path operand that matches nothing looks exactly like a clean result.
  addf scripts/aux-units/thing@.service '[Service]
ExecStart=/opt/hydra/scripts/unit-driven.sh'
  git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  addf scripts/unit-driven.sh 'echo hi'
  run analyze
  has_signal cron-reach
  [ "$(tier)" = "HIGH" ]
}

@test "cron-reach: a script whose unit is heredoc'd in install-aux-units.sh → HIGH" {
  # THE case that matters in this repo: all 36 real ExecStart lines live inside
  # scripts/install-aux-units.sh, not in scripts/aux-units/. A fixture that puts
  # the unit in aux-units/ tests the implementation, not the repo — reverting the
  # fix to search aux-units/ alone produced ZERO test failures until this existed.
  addf scripts/install-aux-units.sh 'cat > /etc/systemd/system/thing.service <<UNIT
[Service]
ExecStart=/opt/hydra/scripts/timer-driven.sh
UNIT'
  git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  addf scripts/timer-driven.sh 'echo hi'
  run analyze
  has_signal cron-reach
  [ "$(tier)" = "HIGH" ]
}

@test "state-mutation: a destructive op added in SHELL → HIGH" {
  addf scripts/cleanup.sh 'rm -rf /var/lib/hydra-qa/old'
  run analyze
  has_signal state-mutation
}

@test "state-mutation: mv INTO persistent state fires (destination form)" {
  # The header has always promised rm/mv/truncate/install, but `mv` was missing
  # from the regex entirely — so overwriting persistent state via mv reported
  # LOW instead of HIGH, and Step 3e applied a shallower review to it.
  addf scripts/promote.sh '#!/usr/bin/env bash
mv "$tmp" /var/lib/hydra-qa/state.json'
  run analyze
  has_signal state-mutation
}

@test "state-mutation: mv OUT OF persistent state fires (source form)" {
  addf scripts/archive.sh '#!/usr/bin/env bash
mv /opt/hydra/old-state.json /tmp/backup.json'
  run analyze
  has_signal state-mutation
}

@test "state-mutation STABILITY: an mv NOT touching persistent state does not fire" {
  addf scripts/rename.sh '#!/usr/bin/env bash
mv a.txt b.txt'
  run analyze
  run has_signal state-mutation
  if [ "$status" -eq 0 ]; then echo "mv without a persistent path must not fire" >&2; false; fi
}

@test "state-mutation STABILITY: the same text in MARKDOWN does not fire" {
  addf docs/howto.md 'To reset, run: rm -rf /var/lib/hydra-qa/old'
  run analyze
  run has_signal state-mutation
  [ "$status" -ne 0 ]
}

@test "state-mutation STABILITY: a shell COMMENT describing the op does not fire" {
  # The analyzer flagged its own source: the comment documenting this signal and
  # the regex implementing it both contain the pattern. A comment does not run.
  addf scripts/notes.sh '#!/usr/bin/env bash
# careful: this used to rm -rf /var/lib/hydra-qa/old
echo safe'
  run analyze
  run has_signal state-mutation
  [ "$status" -ne 0 ]
}

@test "state-mutation STABILITY: a bats FIXTURE string does not fire" {
  # Test fixtures assert on the pattern; they never execute it in production.
  addf scripts/tests/some.bats '@test "x" { echo "rm -rf /var/lib/hydra-qa/old"; }'
  run analyze
  run has_signal state-mutation
  [ "$status" -ne 0 ]
}

@test "state-mutation STABILITY: the analyzer's OWN detector definition does not fire" {
  # The detector's regex literally contains the pattern it looks for, so before
  # this exclusion the report for a PR touching this file listed its own
  # `destructive="$(grep -E ...)"` line as evidence of a state mutation.
  # The fixture must ACTUALLY match the detector, or the test passes for the
  # wrong reason. The real line matches via the `truncate` alternative plus
  # `/var/lib` later on the same line — reproduce that shape, not a lookalike.
  addf scripts/check-blast-radius.sh 'destructive="$(grep -E "(rm -[rf]|truncate)(.*)(/var/lib|/opt/hydra)" x)"'
  run analyze
  run has_signal state-mutation
  [ "$status" -ne 0 ]
}

@test "state-mutation DISCRIMINATION: a real op still fires despite those exclusions" {
  # Paired with the three stability tests above: the exclusions must not have
  # hollowed the signal out. This is the case that must never stop firing.
  addf scripts/cleanup.sh '#!/usr/bin/env bash
rm -rf /var/lib/hydra-qa/old'
  run analyze
  has_signal state-mutation
}

@test "skill-reach: skills-all content → at least MEDIUM" {
  addf skills-all/some-skill/SKILL.md 'doctrine'
  run analyze
  has_signal skill-reach
}

@test "skill-reach: a workspace SOUL.md fires too (agent-facing doctrine)" {
  addf workspaces/qa/SOUL.md 'doctrine'
  run analyze
  has_signal skill-reach
}

@test "credential-surface: codex/auth-store paths are covered" {
  for f in scripts/lib/codex-auth-sync.sh scripts/lib/codex-oauth-refresh.sh auth-profiles.json; do
    addf "$f" 'x'
    git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  done
  # last one alone in the diff
  addf scripts/lib/codex-reauth.sh 'x'
  run analyze
  has_signal credential-surface
}

@test "credential-surface: a .pem/.key file is covered" {
  addf certs/server.pem 'x'
  run analyze
  has_signal credential-surface
}

@test "cron-reach STABILITY: a lookalike basename in cron-jobs.json does not fire" {
  # ident matching is substring-based, so pin that an unrelated script sharing a
  # suffix with a cronned one stays quiet.
  addf cron-jobs.json '{"jobs":[{"cmd":"bash scripts/db-sync.sh"}]}'
  git -C "$R" update-ref refs/remotes/origin/main "$(tip)"
  addf scripts/unrelated-thing.sh 'echo hi'
  run analyze
  run has_signal cron-reach
  [ "$status" -ne 0 ]
}

@test "test-gap: a changed script with no bats suite fires" {
  addf scripts/untested.sh 'echo hi'
  run analyze
  has_signal test-gap
}

@test "test-gap STABILITY: a script WITH a bats suite does not fire" {
  addf scripts/tested.sh 'echo hi'
  addf scripts/tests/tested.bats '@test "x" { true; }'
  run analyze
  run has_signal test-gap
  [ "$status" -ne 0 ]
}

# =============================================================================
# deploy-path is informational and NEVER lowers the tier
# =============================================================================

@test "deploy-path never lowers the tier: an undeployed CI file still tiers CRITICAL" {
  # .github/ is repo-side only, so deploy-path fires — but the workflow is also
  # a gate surface. If deploy-path could subtract, this would collapse to LOW.
  addf .github/workflows/some-gate.yml 'on: [push]'
  run analyze
  has_signal deploy-path
  [ "$(tier)" = "CRITICAL" ]
}

@test "deploy-path is severity info" {
  addf docs/a.md 'x'
  run analyze
  [ "$(jq -r '.signals[] | select(.id=="deploy-path") | .severity' "$(state_file)")" = "info" ]
}

# =============================================================================
# Report contract — what Guard 9 and the skill depend on
# =============================================================================

@test "report carries a non-empty limitations array" {
  addf docs/a.md 'x'
  run analyze
  [ "$(jq -r '.limitations | length' "$(state_file)")" -gt 0 ]
}

@test "report interior head_sha and pr match the filename (Guard 9 cross-check)" {
  addf docs/a.md 'x'
  run analyze
  [ "$(jq -r '.head_sha' "$(state_file)")" = "$(tip)" ]
  [ "$(jq -r '.pr' "$(state_file)")" = "$PR_NUM" ]
  # Guard 9 selects on .repo too, and accepts only this status/tier vocabulary.
  [ "$(jq -r '.repo' "$(state_file)")" = "Muso-AI/hydra" ]
  run jq -e '(.status | IN("OK","CLEAN","ERROR")) and (.tier | IN("LOW","MEDIUM","HIGH","CRITICAL","UNKNOWN"))' "$(state_file)"
  [ "$status" -eq 0 ]
}

@test "every signal carries evidence, never a bare count" {
  addf scripts/check-thing.sh 'echo x'
  run analyze
  # No signal may have an empty evidence array.
  run jq -e '[.signals[] | select((.evidence | length) == 0)] | length == 0' "$(state_file)"
  [ "$status" -eq 0 ]
}

# =============================================================================
# Failure posture: usage, ERROR state, degrade caps
# =============================================================================

@test "usage: non-numeric PR number → exit 2" {
  HEAD_SHA="$(tip)"
  run env BR_SKIP_FETCH=1 BR_STATE_DIR="$STATE" bash "$SCRIPT" "abc" "$HEAD_SHA"
  [ "$status" -eq 2 ]
}

@test "usage: a short sha → exit 2 (the state file is keyed by the full oid)" {
  run env BR_SKIP_FETCH=1 BR_STATE_DIR="$STATE" bash "$SCRIPT" 42 "abc1234"
  [ "$status" -eq 2 ]
}

@test "usage: non-numeric BR_MAX_FILES → exit 2, never silent arithmetic" {
  HEAD_SHA="$(tip)"
  run env BR_SKIP_FETCH=1 BR_STATE_DIR="$STATE" BR_MAX_FILES=abc \
    bash "$SCRIPT" 42 "$HEAD_SHA"
  [ "$status" -eq 2 ]
}

@test "unresolvable head → exit 3 AND a status=ERROR report (fail closed)" {
  HEAD_SHA="0000000000000000000000000000000000000000"; export HEAD_SHA
  run env BR_SKIP_FETCH=1 BR_STATE_DIR="$STATE" bash -c \
    "cd '$R' && '$SCRIPT' $PR_NUM $HEAD_SHA"
  [ "$status" -eq 3 ]
  [ "$(status)" = "ERROR" ]
  [ "$(tier)" = "UNKNOWN" ]
}

@test "degrade cap: over BR_MAX_FILES the per-file scans are SKIPPED and SAID SO" {
  addf scripts/lib/helper.sh 'echo helper'
  addf scripts/caller.sh 'bash scripts/lib/helper.sh'
  addf scripts/lib/helper.sh 'echo v2'
  run analyze BR_MAX_FILES=0
  # The expensive scans are skipped...
  run has_signal reverse-callers
  [ "$status" -ne 0 ]
  # ...and the report says so rather than reading as "nothing found".
  [ "$(jq -r '.skipped | length' "$(state_file)")" -gt 0 ]
}

@test "BR_STATE_DIR empty ⇒ no state file written, analyzer still exits 0" {
  addf docs/a.md 'x'
  HEAD_SHA="$(tip)"
  run env BR_SKIP_FETCH=1 BR_STATE_DIR= bash -c "cd '$R' && '$SCRIPT' $PR_NUM $HEAD_SHA"
  [ "$status" -eq 0 ]
  [ ! -d "$STATE" ] || [ -z "$(ls -A "$STATE" 2>/dev/null)" ]
}

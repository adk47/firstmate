#!/usr/bin/env bats
# Tests for check-soul-bootstrap-size.sh: the gate that keeps Caroline's
# injected workspace bootstrap files under openclaw's per-file and total caps.
#
# Why this suite exists: openclaw keeps a 75% HEAD and a 25% TAIL of an
# over-cap bootstrap file and drops the MIDDLE (trimBootstrapContent,
# BOOTSTRAP_HEAD_RATIO/BOOTSTRAP_TAIL_RATIO, verified on 2026.7.1). TOOLS.md
# sat at 46,104 chars against a 40,000 cap and logged 310 truncation warnings
# in 24h, silently removing the profile_credits_status / profile_claim_status /
# cancel_subscription sections from every turn. The gate is the mechanical
# backstop; these tests keep the gate honest.
#
# Hermetic: every case builds a synthetic repo in $TEST_TMPDIR and runs the
# script from there (it resolves $CFG and workspaces/ relative to cwd).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/check-soul-bootstrap-size.sh"

# openclaw's CANONICAL workspace bootstrap set, verbatim from the Set literal in
# dist/workspace-DkQ7irPD.js. All eight, deliberately:
#   MEMORY is declared as DEFAULT_MEMORY_FILENAME = CANONICAL_ROOT_MEMORY_FILENAME
#   = "MEMORY.md", so grepping the dist for the literal string misses it — it IS
#   a bootstrap file. An earlier version of this list omitted MEMORY (caught in
#   review) and BOOTSTRAP, which meant the completeness assertion below would
#   have stayed green if either were dropped from the production guard.
INJECTED=(SOUL AGENTS TOOLS IDENTITY USER HEARTBEAT MEMORY BOOTSTRAP)

# BOOTSTRAP.md is canonical but NOT required — it is the un-onboarded-workspace
# marker (isWorkspaceBootstrapPending), so its absence is the healthy state and
# the guard must not demand it. Everything else must exist.
REQUIRED=(SOUL AGENTS TOOLS IDENTITY USER HEARTBEAT MEMORY)

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/workspaces/support"
  # The guard now measures EVERY agent in BOTH profiles (it was scoped to support
  # alone until 2026-08-28, which is why operations/SOUL.md sat 3,569 chars over cap
  # unmeasured). So the synthetic repo needs a main profile too — with a REAL agent
  # in it: an empty agents.list is now itself a refusal, because measuring nothing
  # and finding nothing wrong are not the same result. This filler agent is tiny and
  # always in-cap, so it never influences a support-focused assertion.
  mkdir -p "$TEST_TMPDIR/workspaces/filler"
  for f in SOUL AGENTS USER; do echo "x" > "$TEST_TMPDIR/workspaces/filler/$f.md"; done
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":40000,"bootstrapTotalMaxChars":120000},
 "list":[{"id":"filler","workspace":"/opt/hydra/workspaces/filler"}]}}
JSON
  for f in "${REQUIRED[@]}"; do
    echo "x" > "$TEST_TMPDIR/workspaces/support/$f.md"
  done
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# write_cfg <defaults-cap> [support-override-cap]
write_cfg() {
  local defaults="$1" override="${2:-}"
  local entry='{"id":"support","workspace":"/opt/hydra/workspaces/support"}'
  [ -n "$override" ] && entry="{\"id\":\"support\",\"workspace\":\"/opt/hydra/workspaces/support\",\"bootstrapMaxChars\":$override}"
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<JSON
{"agents":{"defaults":{"bootstrapMaxChars":$defaults,"bootstrapTotalMaxChars":120000},
 "list":[$entry]}}
JSON
}

@test "the guard lists every file in openclaw's canonical bootstrap set" {
  # Regression cover for two omissions caught in review: HEARTBEAT.md was
  # missing from the guard, and MEMORY/BOOTSTRAP were missing from THIS list —
  # so the assertion itself would have stayed green while the guard undercounted.
  # Checks the union of required + optional, since BOOTSTRAP.md lives in the
  # optional array.
  # RE-ANCHORED 2026-08-28. The guard used to name each path literally
  # ("workspaces/support/SOUL.md"); it now derives workspaces from the config and
  # lists bare basenames, so the old literal grep matched nothing and this test
  # passed while asserting about a file that no longer said any of that. Same
  # vacuous-fixture failure as the doctrine-gate anchors in #877: a test that
  # greps for text it does not own goes green in the safe direction when the text
  # moves. Assert on the NAME ARRAYS the guard actually iterates.
  for f in "${INJECTED[@]}"; do
    grep -qE "^(BOOTSTRAP_NAMES|OPTIONAL_NAMES)=\(.*\b$f\b" "$SCRIPT" \
      || { echo "guard is missing $f — it is in openclaw's canonical set"; return 1; }
  done
}

@test "BOOTSTRAP.md is optional: absent is healthy, present is sized" {
  write_cfg 50000
  # absent (the steady state) must not fail
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BOOTSTRAP.md is listed"* ]]
  # present and over-cap must fail
  head -c 400 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/BOOTSTRAP.md"
  write_cfg 100
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BOOTSTRAP.md"* ]]
}

@test "resolves the PER-AGENT cap when the support entry overrides defaults" {
  # openclaw: resolveAgentConfig(cfg,agentId)?.bootstrapMaxChars ?? defaults.
  # A position-based `grep | head -1` returns the defaults here and is wrong.
  write_cfg 40000 50000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Assert on SUPPORT's own line, not on the whole output. A bare
  # `output != *"cap 40000"*` was a proxy for "support did not get the default",
  # and it stopped meaning that the moment the guard measured a second agent —
  # the filler agent in the main profile legitimately reports cap 40000. The
  # property is per-agent, so the assertion has to be per-agent too.
  echo "$output" | grep -qE 'workspaces/support/SOUL\.md .*cap 50000'
  ! echo "$output" | grep -qE 'workspaces/support/.*cap 40000'
}

@test "falls back to agents.defaults when the agent has no override" {
  write_cfg 40000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  # Per-agent, for the same reason as above: another agent's cap line must not be
  # able to satisfy this one.
  echo "$output" | grep -qE 'workspaces/support/SOUL\.md .*cap 40000'
}

@test "fails when a file exceeds the per-file cap" {
  write_cfg 100
  head -c 500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/TOOLS.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TOOLS.md"* ]]
  # must steer at the per-agent key, not the shared default that scales
  # memory-health-check.sh's warn threshold for every other agent
  [[ "$output" == *"agents.list[id=support].bootstrapMaxChars"* ]]
}

@test "fails when the aggregate exceeds the total cap" {
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":50000,"bootstrapTotalMaxChars":10},"list":[{"id":"support","workspace":"/opt/hydra/workspaces/support"}]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bootstrap total"* ]]
}

@test "a missing REPO-OWNED file fails loud instead of being skipped" {
  # A silent `continue` would let a deleted SOUL.md pass this gate forever.
  write_cfg 50000
  rm "$TEST_TMPDIR/workspaces/support/SOUL.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SOUL.md"* ]]
}

@test "a missing SEED file is skipped, because workspaces legitimately differ" {
  # CONTRACT CHANGE, 2026-08-28, and deliberate. This case used to assert that a
  # missing TOOLS.md fails. That was safe while the gate saw only support, which
  # has all seven files -- but the gate now covers all ten agents, and scout has
  # no IDENTITY.md or HEARTBEAT.md at all. Requiring every name everywhere would
  # have failed CI on a healthy fleet, so "required" narrowed to the three files
  # the repo actually OWNS and deploys (SOUL, AGENTS, USER). The other four are
  # server-owned seeds that agents rewrite at runtime; their absence in the repo
  # says nothing about the live box, which memory-health-check.sh covers instead.
  write_cfg 50000
  rm "$TEST_TMPDIR/workspaces/support/TOOLS.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "a missing config aborts (exit 2) rather than silently using a default" {
  write_cfg 50000
  rm "$TEST_TMPDIR/openclaw-edge.json"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "a renamed cap key falls back to the default instead of dying silently" {
  # Under `set -euo pipefail` the old grep-pipeline reader exited non-zero and
  # killed the script BEFORE its `:-` default was ever consulted.
  cat > "$TEST_TMPDIR/openclaw-edge.json" <<'JSON'
{"agents":{"defaults":{"RENAMED":1},"list":[{"id":"support","workspace":"/opt/hydra/workspaces/support"}]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cap 40000"* ]]
}

# ---- scope + diagnosis: the two properties the 2026-08-28 miss came down to ----

@test "an over-cap MAIN-profile agent fails — the scope miss that hid operations" {
  # THE REGRESSION. This gate was scoped to workspaces/support alone, so
  # operations/SOUL.md sat 3,569 chars over cap, silently dropping its refund
  # money-gates and "never fabricate a process" from every boot, and the gate was
  # green the whole time. The logic was always right; only the scope was wrong.
  mkdir -p "$TEST_TMPDIR/workspaces/operations"
  for f in SOUL AGENTS USER; do echo "x" > "$TEST_TMPDIR/workspaces/operations/$f.md"; done
  head -c 500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/operations/SOUL.md"
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":100,"bootstrapTotalMaxChars":120000},
 "list":[{"id":"operations","workspace":"/opt/hydra/workspaces/operations"}]}}
JSON
  write_cfg 50000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/operations/SOUL.md"* ]]
  [[ "$output" == *"agent 'operations'"* ]]
  [[ "$output" == *"openclaw-main.json"* ]]
}

@test "a NEW agent is covered the day it is added, without editing this guard" {
  # The agent list comes from the config, not from a hand-maintained array here.
  # A guard you must remember to extend is a guard that lapses.
  mkdir -p "$TEST_TMPDIR/workspaces/brandnew"
  for f in SOUL AGENTS USER; do echo "x" > "$TEST_TMPDIR/workspaces/brandnew/$f.md"; done
  head -c 500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/brandnew/SOUL.md"
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":100,"bootstrapTotalMaxChars":120000},
 "list":[{"id":"brandnew","workspace":"/opt/hydra/workspaces/brandnew"}]}}
JSON
  write_cfg 50000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspaces/brandnew/SOUL.md"* ]]
}

@test "the failure NAMES the headings inside the dropped band" {
  # "3569 chars over" sends you to count characters. Naming the rules that vanish
  # sends you to the fix — and is what makes the report actionable to someone who
  # has never read the file.
  mkdir -p "$TEST_TMPDIR/workspaces/operations"
  for f in AGENTS USER; do echo "x" > "$TEST_TMPDIR/workspaces/operations/$f.md"; done
  {
    head -c 700 /dev/zero | tr '\0' 'a'; echo
    echo "### Honesty — never fabricate a process"
    head -c 200 /dev/zero | tr '\0' 'b'; echo
  } > "$TEST_TMPDIR/workspaces/operations/SOUL.md"
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":800,"bootstrapTotalMaxChars":120000},
 "list":[{"id":"operations","workspace":"/opt/hydra/workspaces/operations"}]}}
JSON
  write_cfg 50000
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vanish from EVERY injected prompt"* ]]
  [[ "$output" == *"Honesty — never fabricate a process"* ]]
}

@test "raising the cap is not offered as the fix" {
  # The cap exists for boot-memory reasons. The guard must point at trimming and,
  # if a cap really must move, at the PER-AGENT key — never agents.defaults, which
  # is compared across profiles and also scales other agents' warn thresholds.
  write_cfg 100
  head -c 500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/SOUL.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Raising the cap is NOT the fix"* ]]
  [[ "$output" == *"reference/"* ]]
  [[ "$output" == *"never"*"agents.defaults"* ]]
}

@test "thin headroom WARNS without failing — the state every incident passed through" {
  write_cfg 50000
  # 5% headroom: not a defect yet, but the shape of one.
  head -c 47500 /dev/zero | tr '\0' 'a' > "$TEST_TMPDIR/workspaces/support/SOUL.md"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" == *"headroom"* ]]
}

# ---- fail-closed enumeration: an unmeasured profile is not a passing one ----

@test "a MALFORMED profile aborts even when the other profile is valid" {
  # THE REVIEW FINDING on this PR, reproduced. The first version swallowed a parse
  # error per-config: with main malformed and edge valid, main vanished from the
  # measurement, edge still produced rows, the non-empty check passed, and the gate
  # went GREEN having measured only support — reconstructing the exact silent scope
  # hole this change exists to close. "I could not check" is not "there was nothing
  # to find", and only the second one is an answer.
  write_cfg 50000
  echo '{ this is not json' > "$TEST_TMPDIR/openclaw-main.json"
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ENUMERATION FAILURE"* ]]
  [[ "$output" == *"openclaw-main.json"* ]]
  # and it must NOT have quietly measured support and called that a pass
  [[ "$output" != *"OK: workspaces/support/SOUL.md"* ]]
}

@test "an agent entry with no workspace is REFUSED, not skipped" {
  # A row we cannot resolve is an agent we are not measuring. Skipping it is the
  # same silent hole in miniature.
  write_cfg 50000
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":40000,"bootstrapTotalMaxChars":120000},
 "list":[{"id":"ghost"}]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no usable id/workspace"* ]]
}

@test "an EMPTY agents.list aborts rather than passing on zero measurements" {
  # Measuring nothing and finding nothing wrong are not the same result.
  write_cfg 50000
  cat > "$TEST_TMPDIR/openclaw-main.json" <<'JSON'
{"agents":{"defaults":{"bootstrapMaxChars":40000,"bootstrapTotalMaxChars":120000},"list":[]}}
JSON
  cd "$TEST_TMPDIR" && run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"agents.list is missing or empty"* ]]
}

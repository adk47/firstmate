#!/usr/bin/env bats
# Tests scripts/lib/edge-restart-gate.sh :: gateway_restart_needed -- the
# deploy.sh Step 6 gate that SKIPS a gateway restart (main AND edge) when a deploy
# provably changed only gateway-inert files. Every restart costs ~12-30s of agent
# rebind, and on edge openclaw also pauses the memory_search index -- so a needless
# restart is churn. But a mis-skip leaves the gateway stale, so the gate is
# strictly FAIL-OPEN (restart unless PROVEN safe to skip). 0 = restart, 1 = skip.
# The classifier is profile-neutral: the same call gates both main and edge in
# deploy.sh, so these logic cases cover both.
bats_require_minimum_version 1.5.0

setup() {
  HYDRA_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$HYDRA_REPO/scripts/lib/edge-restart-gate.sh"
  unset HYDRA_FORCE HYDRA_FORCE_RESTART
  DEPLOY_DIFF_COMPUTED=1
  DEPLOY_CHANGED_FILES=""
}

@test "skips restart when only inert files changed (docs/CI/tests/personas/templates)" {
  DEPLOY_CHANGED_FILES=$'docs/lessons/openclaw-and-codex.md\n.github/workflows/deploy.yml\nscripts/tests/foo.bats\n.claude/agents/x.md\nscripts/aux-units/openclaw-gateway.override.conf'
  run gateway_restart_needed
  [ "$status" -eq 1 ]
}

@test "skips restart when only repo-root docs changed (README.md/CLAUDE.md/AGENTS.md)" {
  DEPLOY_CHANGED_FILES=$'README.md\nCLAUDE.md\nAGENTS.md'
  run gateway_restart_needed
  [ "$status" -eq 1 ]
}

@test "restarts when a gateway skill changed (skills-all)" {
  DEPLOY_CHANGED_FILES=$'docs/x.md\nskills-all/muso-read/SKILL.md'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "root-doc allowlist is exact-match: nested SKILL.md still restarts (no *.md glob leak)" {
  # A bare *.md pattern would match skills-all/**/SKILL.md and wrongly skip.
  # Enumerating exact root names (README.md|CLAUDE.md) must NOT swallow it.
  DEPLOY_CHANGED_FILES=$'CLAUDE.md\nskills-all/muso-read/SKILL.md'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "restarts when openclaw-edge.json changed" {
  DEPLOY_CHANGED_FILES='openclaw-edge.json'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "restarts when the edge agent workspace changed (workspaces/support)" {
  DEPLOY_CHANGED_FILES=$'workspaces/support/SOUL.md'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "restarts when policies changed (feeds tools.deny into the gateway)" {
  DEPLOY_CHANGED_FILES='policies/tool-deny-lists.yaml'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "restarts on a general scripts/ change (may carry the version pin / units)" {
  DEPLOY_CHANGED_FILES=$'scripts/deploy.sh'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "fails open when the baseline diff was not computed" {
  DEPLOY_DIFF_COMPUTED=0
  DEPLOY_CHANGED_FILES=$'docs/x.md'
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "fails open on an empty diff" {
  DEPLOY_DIFF_COMPUTED=1
  DEPLOY_CHANGED_FILES=''
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "HYDRA_FORCE always restarts (even on an inert-only change)" {
  DEPLOY_CHANGED_FILES=$'docs/x.md'
  HYDRA_FORCE=1
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

@test "HYDRA_FORCE_RESTART escape hatch always restarts" {
  DEPLOY_CHANGED_FILES=$'docs/x.md'
  HYDRA_FORCE_RESTART=1
  run gateway_restart_needed
  [ "$status" -eq 0 ]
}

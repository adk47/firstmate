#!/usr/bin/env bats
# MUS-3105: autonomous skill captures must stay proposals on node-8. openclaw's default
# is skills.workshop.autonomous.mode="auto", which applies a capture to the live SKILL.md
# in the same call (no reviewer, re-drifts the deploy baseline: #1047, #1057, MUS-3099).
# The key is global in openclaw's schema; there is no per-agent form.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

@test "openclaw-main.json pins skills.workshop.autonomous.mode to propose" {
  run jq -r '.skills.workshop.autonomous.mode // "unset"' "$REPO_ROOT/openclaw-main.json"
  [ "$status" -eq 0 ]
  [ "$output" = "propose" ]
}

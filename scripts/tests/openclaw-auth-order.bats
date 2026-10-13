#!/usr/bin/env bats
# Pins auth.order.openai in openclaw-main.json and openclaw-edge.json (MUS-6075).
#
# WHY THIS EXISTS: openclaw tries auth.order.openai[0] first. A 100%-capped
# account at the head emits the usage-cap signature roughly every 75 seconds
# forever (scripts/codex-keepalive.sh:613-631), because openclaw's per-profile
# cooldown caps at 5 min and then returns the head profile to the front. The
# order is therefore least-loaded-first. Measured on node-8 2026-10-09 08:40Z:
# aaron@muso.ai 10%, aarondkaufman@gmail.com 27%, aaronkaufman@me.com 100%
# CAPPED (last).
#
# The pin is on the exact order, not the set: the same three ids in a worse
# order is the regression. Both files must carry the identical list. Drift
# between main and edge is the failure this file exists to catch.

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

EXPECTED_ORDER='["openai:aaron@muso.ai","openai:aarondkaufman@gmail.com","openai:aaronkaufman@me.com"]'

@test "openclaw-main.json: auth.order.openai is least-loaded-first" {
  run jq -c '.auth.order.openai' "$REPO/openclaw-main.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$EXPECTED_ORDER" ]
}

@test "openclaw-edge.json: auth.order.openai is least-loaded-first" {
  run jq -c '.auth.order.openai' "$REPO/openclaw-edge.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$EXPECTED_ORDER" ]
}

@test "main and edge carry the identical auth.order.openai list" {
  main=$(jq -c '.auth.order.openai' "$REPO/openclaw-main.json")
  edge=$(jq -c '.auth.order.openai' "$REPO/openclaw-edge.json")
  [ "$main" = "$edge" ]
}

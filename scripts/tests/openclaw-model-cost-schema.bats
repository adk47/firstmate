#!/usr/bin/env bats
# openclaw 2026.8.35 validates models.providers.*.models[].cost and refuses the
# provider's model list when cacheRead/cacheWrite are absent ("Invalid models.json
# schema: providers.openrouter.models.N.cost.cacheWrite/cacheRead required" on
# both gateways after the 8 Oct deploy attempt), which can drop the OpenRouter
# fallback rung. Every cost object must carry all four fields.
HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

@test "every model cost object in openclaw-{main,edge}.json has input/output/cacheRead/cacheWrite" {
  for f in openclaw-main.json openclaw-edge.json; do
    run jq -r '[.models.providers[]?.models[]? | select(.cost != null)
                | select((.cost | has("input") and has("output") and has("cacheRead") and has("cacheWrite")) | not)
                | .id] | join(",")' "$HYDRA_REPO/$f"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$f: cost missing fields on: $output" >&2; false; }
  done
}

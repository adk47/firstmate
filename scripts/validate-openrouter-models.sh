#!/usr/bin/env bash
set -euo pipefail

# Validate that every `openrouter/<id>` model ref declared in our openclaw
# configs + cron-jobs actually resolves to a routable OpenRouter model.
#
# Background: PR #351's review surfaced that OpenRouter's /v1/models endpoint
# only lists canonical preferred IDs — it OMITS aliases that the API still
# accepts (e.g. `anthropic/claude-sonnet-4.6` resolves to the date-pinned
# `anthropic/claude-4.6-sonnet-20260217` at completion time, but the latter
# isn't in /v1/models). A syntactically fine but unroutable model ID would
# slip past validate-shared-config.sh and validate-config-matrix.sh today.
#
# This validator hits GET /v1/models/<id>/endpoints — the right resolvability
# probe — for every configured openrouter ref and requires HTTP 200.
#
# Requires OPENROUTER_API_KEY in env. Skips (exit 0) with a clear WARN if
# absent so local dev + CI without the secret stays green. Wire the secret
# into GitHub Actions to enable enforcement in CI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HYDRA_ROOT="${HYDRA_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "WARN: OPENROUTER_API_KEY not set — skipping OpenRouter model resolvability check."
  echo "      Set OPENROUTER_API_KEY locally or add it to GitHub Actions secrets to enable."
  exit 0
fi

# Extract every "openrouter/X" string literal from all three config files.
# grep-based instead of jq paths because openrouter refs can appear in many
# places (agents.list[].model.primary, .fallbacks[], agents.defaults.model,
# .imageModel, cron payload.model, payload.fallbacks[]) and a string-level
# pass is robust to future schema additions.
mapfile -t refs < <(
  grep -hoE '"openrouter/[^"]+"' \
    "$HYDRA_ROOT/openclaw-main.json" \
    "$HYDRA_ROOT/openclaw-edge.json" \
    "$HYDRA_ROOT/cron-jobs.json" 2>/dev/null \
  | tr -d '"' \
  | sed 's|^openrouter/||' \
  | sort -u
)

if [ "${#refs[@]}" -eq 0 ]; then
  echo "No openrouter/* model refs found in configs — nothing to validate."
  exit 0
fi

echo "Validating ${#refs[@]} unique OpenRouter model ref(s)..."
echo ""

failures=0
for model in "${refs[@]}"; do
  [ -z "$model" ] && continue
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    "https://openrouter.ai/api/v1/models/${model}/endpoints" || echo "000")
  if [ "$code" = "200" ]; then
    printf '  OK    %s\n' "$model"
  else
    printf '  FAIL  %s (HTTP %s)\n' "$model" "$code"
    failures=$((failures + 1))
  fi
done

echo ""
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures OpenRouter model ref(s) not resolvable via /v1/models/:id/endpoints."
  echo "Deploy blocked — fix the config or remove the unresolvable refs."
  exit 1
fi
echo "All OpenRouter model refs resolve. Pass."

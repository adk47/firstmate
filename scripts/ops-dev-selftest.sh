#!/usr/bin/env bash
set -euo pipefail

# ops-dev-selftest.sh
# Sanity checks for the operations-dev agent wiring + dry-run safety rails.
# Intended to run on the gateway host (or any environment with this repo checked out).

log() { echo "[ops-dev-selftest] $*"; }
fail() { echo "[ops-dev-selftest] FAIL: $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT_DIR/openclaw-dev.json"

# Check dependencies
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

log "Checking openclaw-dev.json is valid JSON..."
jq . "$CONFIG" >/dev/null

log "Checking operations-dev agent exists in openclaw-dev.json..."
jq -e '.agents.list[] | select(.id == "operations-dev")' "$CONFIG" >/dev/null \
  || fail "agents.list missing id=operations-dev"
jq -e '.bindings[] | select(.agentId == "operations-dev" and .match.channel == "slack" and .match.accountId == "operations-dev")' \
  "$CONFIG" >/dev/null || fail "bindings missing operations-dev slack accountId mapping"

log "Checking Slack account wiring exists (without printing tokens)..."
jq -e '.channels.slack.accounts["operations-dev"]' "$CONFIG" >/dev/null \
  || fail 'channels.slack.accounts["operations-dev"] missing'

# Validate token shape only (do not print values)
jq -e '.channels.slack.accounts["operations-dev"].botToken | type=="string" and startswith("xoxb-")' "$CONFIG" >/dev/null \
  || fail "operations-dev botToken missing or not xoxb-*"
jq -e '.channels.slack.accounts["operations-dev"].appToken | type=="string" and startswith("xapp-")' "$CONFIG" >/dev/null \
  || fail "operations-dev appToken missing or not xapp-*"

CHANNEL_ID="$(jq -r '.channels.slack.accounts["operations-dev"].channels | keys[0] // empty' "$CONFIG")"
[[ "$CHANNEL_ID" =~ ^C[0-9A-Z]+$ ]] || fail "operations-dev channel id missing or invalid"

log "Checking operations-dev workspace exists and shares skills..."
[[ -d "$ROOT_DIR/workspaces/operations-dev" ]] || fail "workspaces/operations-dev missing"
[[ -L "$ROOT_DIR/workspaces/operations-dev/skills" ]] || fail "workspaces/operations-dev/skills is not a symlink"
[[ -d "$ROOT_DIR/workspaces/operations-dev/skills/muso-ops-admin" ]] || fail "symlink does not resolve to skills directory"

WRAPPER="$ROOT_DIR/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
DUMMY_ENV="MUSO_API_URL=http://example.invalid MUSO_ADMIN_EMAIL=test@example.invalid MUSO_ADMIN_PASSWORD=test"

# --- Dry-run guard tests (PWD-based detection) ---
log "Checking dry-run guard blocks writes from operations-dev workspace..."
pushd "$ROOT_DIR/workspaces/operations-dev" >/dev/null

for method in PUT POST DELETE PATCH; do
  OUTPUT="$(env $DUMMY_ENV bash "$WRAPPER" call "$method" "/admin/test" '{"test":true}')"
  echo "$OUTPUT" | jq -e '.body.dry_run == true and .body.blocked == true' >/dev/null \
    || fail "expected dry_run blocked response for $method from operations-dev workspace"
done
log "  PUT/POST/DELETE/PATCH all blocked"

popd >/dev/null

# --- Dry-run guard test (explicit OPS_DRY_RUN=1 env var) ---
log "Checking dry-run guard blocks writes via OPS_DRY_RUN=1..."
pushd "$ROOT_DIR" >/dev/null

OUTPUT="$(env OPS_DRY_RUN=1 $DUMMY_ENV bash "$WRAPPER" call PUT "/admin/test" '{"test":true}')"
echo "$OUTPUT" | jq -e '.body.dry_run == true and .body.blocked == true' >/dev/null \
  || fail "expected dry_run blocked response when OPS_DRY_RUN=1"
log "  OPS_DRY_RUN=1 blocks writes from any directory"

popd >/dev/null

# --- Dry-run guard: upload also blocked ---
log "Checking dry-run guard blocks uploads..."
pushd "$ROOT_DIR/workspaces/operations-dev" >/dev/null

TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT
OUTPUT="$(env $DUMMY_ENV bash "$WRAPPER" upload "/admin/upload" "$TMPFILE")"
echo "$OUTPUT" | jq -e '.body.dry_run == true and .body.blocked == true' >/dev/null \
  || fail "expected dry_run blocked response for upload"
log "  upload blocked in dry-run mode"

popd >/dev/null

# --- Dry-run response shape validation ---
log "Checking dry-run response includes warning and method..."
pushd "$ROOT_DIR/workspaces/operations-dev" >/dev/null

OUTPUT="$(env $DUMMY_ENV bash "$WRAPPER" call PUT "/admin/credit-requests" '{"requestIds":["1"],"status":"approved"}')"
echo "$OUTPUT" | jq -e '.warning != null and .body.method == "PUT" and .body.path == "/admin/credit-requests"' >/dev/null \
  || fail "dry-run response missing expected fields (warning, method, path)"
log "  response shape validated"

popd >/dev/null

log "OK — all checks passed"

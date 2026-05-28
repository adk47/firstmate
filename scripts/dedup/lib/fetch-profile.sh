#!/usr/bin/env bash
# Fetch one profile via admin API and emit canonical JSON.
set -euo pipefail

profile_id="${1:?usage: fetch-profile.sh <profile_uuid>}"

dir="$(cd "$(dirname "$0")" && pwd)"
api="${MUSO_ADMIN_API:-${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

raw=$(bash "$api" call GET "/admin/profile/$profile_id") || {
  echo "fetch-profile: admin-api call failed for $profile_id" >&2
  exit 4
}

# Require a 200 envelope. Without a positive match, normalize-profile would
# happily turn {"error": "..."}, an HTML error page, or any other unwrapped
# shape into a canonical-shaped object with id="" and empty raw_ids/ipis —
# i.e. a phantom "no external IDs" sibling.
# Drop the 2>/dev/null so jq parse errors are visible in the operator log —
# they're a real signal that the admin-api returned something we can't speak.
http_status=$(echo "$raw" | jq -r '.http_status // empty' || echo "")
if [ "$http_status" != "200" ]; then
  echo "fetch-profile: admin-api response not http_status=200 for $profile_id (got '$http_status', body head: $(echo "$raw" | head -c 200))" >&2
  exit 4
fi

echo "$raw" | bash "$dir/normalize-profile.sh"

#!/usr/bin/env bash
# Fetch one profile via the muso CLI and emit canonical JSON.
set -euo pipefail

profile_id="${1:?usage: fetch-profile.sh <profile_uuid>}"

dir="$(cd "$(dirname "$0")" && pwd)"
muso_bin="${MUSO_BIN:-muso}"

raw=$("$muso_bin" api GET "/admin/profile/$profile_id" --json) || {
  echo "fetch-profile: muso api call failed for $profile_id" >&2
  exit 4
}

# Require a {data: {...}} object. Exit-code success alone is not enough:
# without a positive shape match, normalize-profile would happily turn an
# unexpected payload into a canonical-shaped object with id="" and empty
# raw_ids/ipis — i.e. a phantom "no external IDs" sibling.
# Let jq parse errors hit the operator log — they're a real signal that the
# API returned something we can't speak.
if ! echo "$raw" | jq -e '.data | type == "object"' >/dev/null; then
  echo "fetch-profile: muso api response has no .data object for $profile_id (body head: $(echo "$raw" | head -c 200))" >&2
  exit 4
fi

echo "$raw" | bash "$dir/normalize-profile.sh"

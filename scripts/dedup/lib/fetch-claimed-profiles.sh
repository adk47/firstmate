#!/usr/bin/env bash
# email -> list of claimed profileids (status='processed').
# Exit codes:
#   0 = success (zero or more profileids on stdout)
#   2 = no user found for email
#   3 = >1 users match email — refuses to guess
#   4 = trino call failed (distinguishes infra from "no data")
set -euo pipefail

email="${1:?usage: fetch-claimed-profiles.sh <email>}"
muso_bin="${MUSO_BIN:-muso}"

esc="${email//\'/\'\'}"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

if ! user_ids=$("$muso_bin" query --format json "SELECT id FROM postgresql_core.public.users WHERE lower(email) = lower('$esc')" 2>"$err"); then
  echo "fetch-claimed-profiles: trino failed on user lookup for $email: $(head -2 "$err")" >&2
  exit 4
fi
# NDJSON rows: {"id": "<bigint-as-string>"}. Guard the jq parse: muso
# exiting 0 with garbage stdout must surface as exit 4 (infra), not leak
# jq's exit 2 — which collides with this script's "no user found" code.
user_ids=$(echo "$user_ids" | jq -r '.id // empty') || {
  echo "fetch-claimed-profiles: unparseable muso output on user lookup for $email" >&2
  exit 4
}

if [ -z "$user_ids" ]; then
  echo "fetch-claimed-profiles: no user found for email $email" >&2
  exit 2
fi

count=$(echo "$user_ids" | wc -l | tr -d ' ')
if [ "$count" -gt 1 ]; then
  echo "fetch-claimed-profiles: $count users match email $email — refusing to guess" >&2
  exit 3
fi

user_id="$user_ids"
# Defensive: user_id should be all-digits since postgres BIGINT.
if ! [[ "$user_id" =~ ^[0-9]+$ ]]; then
  echo "fetch-claimed-profiles: refusing non-numeric user_id '$user_id' from users table" >&2
  exit 4
fi

if ! claims=$("$muso_bin" query --format json "SELECT profileid FROM postgresql_core.public.claiming WHERE userid = CAST('$user_id' AS BIGINT) AND status = 'processed'" 2>"$err"); then
  echo "fetch-claimed-profiles: trino failed on claiming lookup for user $user_id: $(head -2 "$err")" >&2
  exit 4
fi
echo "$claims" | jq -r '.profileid // empty' | sort -u || {
  echo "fetch-claimed-profiles: unparseable muso output on claiming lookup for user $user_id" >&2
  exit 4
}

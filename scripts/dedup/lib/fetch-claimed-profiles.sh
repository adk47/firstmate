#!/usr/bin/env bash
# email -> list of claimed profileids (status='processed').
# Exit codes:
#   0 = success (zero or more profileids on stdout)
#   2 = no user found for email
#   3 = >1 users match email — refuses to guess
#   4 = trino call failed (distinguishes infra from "no data")
set -euo pipefail

email="${1:?usage: fetch-claimed-profiles.sh <email>}"
trino="${TRINO_QUERY:-/opt/hydra/scripts/trino-query.sh}"

esc="${email//\'/\'\'}"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

if ! user_ids=$("$trino" "SELECT id FROM postgresql_core.public.users WHERE lower(email) = lower('$esc')" 2>"$err"); then
  echo "fetch-claimed-profiles: trino failed on user lookup for $email: $(head -2 "$err")" >&2
  exit 4
fi
user_ids=$(echo "$user_ids" | tr -d '"' | grep -v '^$' || true)

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

if ! claims=$("$trino" "SELECT profileid FROM postgresql_core.public.claiming WHERE userid = CAST('$user_id' AS BIGINT) AND status = 'processed'" 2>"$err"); then
  echo "fetch-claimed-profiles: trino failed on claiming lookup for user $user_id: $(head -2 "$err")" >&2
  exit 4
fi
echo "$claims" | tr -d '"' | grep -v '^$' | sort -u || true

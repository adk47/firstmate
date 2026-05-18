#!/usr/bin/env bash
# fetch-by-credit.sh — pull a single credit request by cr_id.
#
# The admin LIST endpoint silently ignores requestIds/ids/id filters
# (returns the default top-10 unverified items regardless). And
# `GET /admin/credit-requests/<id>` 404s. So:
#   1. Trino-resolve cr_id → profileId + status (cheap, indexed).
#   2. fetch-by-profile.sh on that profileId (which DOES filter).
#   3. Client-side filter the items array to just the matching cr_id.
#
# If the credit isn't in status=unverified anymore, emit a 0-item
# envelope with a `note` field so the summary step can explain.
#
# Usage:
#   fetch-by-credit.sh <cr_uuid>
#
# Output (stdout):
#   {"queue_depth":<0|1>, "items":[...], "fetch_size":1,
#    "selector":{"kind":"credit","id":"<uuid>"[,"note":"..."]}}

set -euo pipefail

CR_ID="${1:-}"

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ ! "$CR_ID" =~ $UUID_RE ]]; then
  echo "ERROR: cr_uuid required (got: '$CR_ID')" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
PROFILE_SH="$HERE/fetch-by-profile.sh"
TRINO_SH="${TRINO_SH:-/opt/hydra/scripts/trino-query.sh}"

if [[ ! -x "$PROFILE_SH" ]]; then
  echo "ERROR: fetch-by-profile.sh not found at $PROFILE_SH" >&2
  exit 2
fi
if [[ ! -x "$TRINO_SH" ]]; then
  echo "ERROR: trino-query.sh not found at $TRINO_SH" >&2
  exit 2
fi

# Step 1: Trino lookup. CSV output (one row); strip quotes, take last
# data line (skip Java logger warnings on stderr/stdout).
TRINO_OUT=$(bash "$TRINO_SH" "SELECT CAST(id AS varchar), CAST(profileid AS varchar), status FROM postgresql_core.public.credit_requests WHERE id = uuid '$CR_ID'" 2>/dev/null | tail -1 | tr -d '"')

if [[ -z "$TRINO_OUT" || "$TRINO_OUT" == "null" ]]; then
  echo "ERROR: cr_id $CR_ID not found in postgresql_core.public.credit_requests" >&2
  exit 3
fi

IFS=',' read -r _id PROFILE_ID STATUS <<<"$TRINO_OUT"

if [[ -z "$PROFILE_ID" || "$PROFILE_ID" == "null" ]]; then
  echo "ERROR: cr_id $CR_ID has no profileId in Trino (got: '$TRINO_OUT')" >&2
  exit 3
fi

# Step 2: If not unverified, short-circuit with a note (no admin API call needed).
if [[ "$STATUS" != "unverified" ]]; then
  printf '{"queue_depth":0,"items":[],"fetch_size":1,"selector":{"kind":"credit","id":"%s","note":"status_is_%s_not_unverified"}}\n' "$CR_ID" "$STATUS"
  exit 0
fi

# Step 3: fetch-by-profile then filter to the one cr_id.
PROFILE_RESP=$(bash "$PROFILE_SH" "$PROFILE_ID" 500)
echo "$PROFILE_RESP" | jq -c --arg id "$CR_ID" '
  .items = [.items[]? | select(.id == $id)]
  | .queue_depth = (.items | length)
  | .fetch_size = 1
  | .selector = {kind: "credit", id: $id}
'

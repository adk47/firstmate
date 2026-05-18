#!/usr/bin/env bash
# fetch-by-profile.sh — pull oldest-first unverified credits for a profile.
#
# Emits the SAME normalized envelope as fetch-queue.sh so downstream
# Lobster steps (score, verdict, apply, summary) are mode-agnostic.
#
# Mirrors fetch-queue.sh's behavior end-to-end:
#   1. Calls /admin/credit-requests/counts?profilesIds=<id>&status=unverified
#      to learn the TRUE depth for this profile (which can be > limit).
#   2. Reverse-paginates the LIST endpoint (admin API serves DESC by
#      createdAt and silently ignores all sort params) to surface the
#      OLDEST credits first.
#   3. Sorts the assembled items by (createdAt, id) ASC and clamps to
#      <limit>.
#
# queue_depth reports the TRUE profile-scoped unverified count, not the
# returned page count. Without this the summary would imply all of a
# fat profile's credits were processed when only the first <limit> were.
#
# Usage:
#   fetch-by-profile.sh <profile_uuid> [<limit>]
#
# Args:
#   profile_uuid   required. The profileId UUID.
#   limit          optional, default 500 (also the hard cap).
#
# Output (stdout, success):
#   {"queue_depth": <true_unverified_count>,
#    "items": [...],
#    "fetch_size": <limit>,
#    "selector": {"kind":"profile","id":"<uuid>"}}
#
# Exit codes mirror fetch-queue.sh's family:
#   0  ok
#   2  bad args / wrapper not found
#   3  list endpoint HTTP non-200
#   4  counts endpoint HTTP non-200
#   5  envelope_shape_drift

set -euo pipefail

PROFILE_ID="${1:-}"
LIMIT="${2:-500}"

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ ! "$PROFILE_ID" =~ $UUID_RE ]]; then
  echo "ERROR: profile_uuid required (got: '$PROFILE_ID')" >&2
  exit 2
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then LIMIT=500; fi
if (( LIMIT > 500 )); then LIMIT=500; fi

ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
if [[ ! -f "$ADMIN_API_SH" ]] || [[ ! -r "$ADMIN_API_SH" ]]; then
  echo "ERROR: admin-API wrapper not found at $ADMIN_API_SH" >&2
  exit 2
fi

# --- Counts fetch (FIRST — we need true depth to compute last_page) ----
COUNTS_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests/counts?profilesIds=${PROFILE_ID}&status=unverified")
COUNTS_HTTP=$(echo "$COUNTS_RESP" | jq -r '.http_status // "unknown"')
if [[ "$COUNTS_HTTP" != "200" ]]; then
  echo "ERROR: counts endpoint HTTP $COUNTS_HTTP" >&2
  echo "$COUNTS_RESP" >&2
  exit 4
fi

# counts.data is `[]` when the profile has 0 unverified for this status;
# otherwise `[{status:"unverified", count: N}]`. Treat absent as 0.
COUNT=$(echo "$COUNTS_RESP" | jq -r '(.body.data // []) | map(select(.status == "unverified")) | .[0].count // 0')
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: envelope_shape_drift: counts.data shape unexpected (got: '$COUNT')" >&2
  echo "$COUNTS_RESP" >&2
  exit 6
fi

# --- List fetch (FIFO via reverse pagination) ---------------------------
# Empty profile → emit empty envelope. queue_depth correctly reflects 0.
ITEMS='[]'
if (( COUNT > 0 )); then
  LAST_PAGE=$(( (COUNT + LIMIT - 1) / LIMIT ))
  PAGE_N="$LAST_PAGE"
  while (( PAGE_N > 0 )); do
    LIST_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests?profilesIds=${PROFILE_ID}&status=unverified&limit=${LIMIT}&page=${PAGE_N}")
    LIST_HTTP=$(echo "$LIST_RESP" | jq -r '.http_status // "unknown"')
    if [[ "$LIST_HTTP" != "200" ]]; then
      echo "ERROR: list endpoint HTTP $LIST_HTTP (page=$PAGE_N)" >&2
      echo "$LIST_RESP" >&2
      exit 3
    fi

    PAGE_ITEMS=$(echo "$LIST_RESP" | jq -c '.body.data.items')
    if [[ -z "$PAGE_ITEMS" || "$PAGE_ITEMS" == "null" ]]; then
      echo "ERROR: envelope_shape_drift: list response missing .body.data.items (page=$PAGE_N)" >&2
      echo "$LIST_RESP" | jq -c '.body | keys' >&2 || true
      exit 5
    fi

    # printf builtin (no execve, no ARG_MAX) → jq stdin via slurp.
    ITEMS=$(printf '%s\n%s\n' "$ITEMS" "$PAGE_ITEMS" | jq -sc 'add')
    ITEMS_LEN_SO_FAR=$(echo "$ITEMS" | jq 'length')
    if (( ITEMS_LEN_SO_FAR >= LIMIT )); then
      break
    fi
    PAGE_N=$(( PAGE_N - 1 ))
  done

  # Sort oldest-first, tie-break by id, take requested count.
  ITEMS=$(echo "$ITEMS" | jq -c "sort_by(.createdAt, .id) | .[:${LIMIT}]")
fi

printf '{"queue_depth":%s,"items":%s,"fetch_size":%s,"selector":{"kind":"profile","id":"%s"}}\n' \
  "$COUNT" "$ITEMS" "$LIMIT" "$PROFILE_ID"

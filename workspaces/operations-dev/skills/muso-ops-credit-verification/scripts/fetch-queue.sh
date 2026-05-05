#!/usr/bin/env bash
# fetch-queue.sh — canonical B1 fetcher for the credit-verification batch.
#
# Replaces the agent-improvised bash that the 2026-04-27 10:06 UTC dry-run
# revealed: the agent wrote `.body.items // .items // []` and `.body.count //
# .body.total // .count // 0`, both of which silently fell through to `[]`
# and `0` because the real Muso admin API envelope nests one level deeper
# (`.body.data.items` / `.body.data[0].count`). The run posted "Queue clear"
# while the live API actually had 13891 unverified credits queued.
#
# This script is the only sanctioned way to fetch the unverified-credit
# queue. It locks the jq paths to the real envelope, fails LOUD on every
# observable drift (envelope shape, HTTP non-200, count/items mismatch),
# and emits a single normalized JSON object to stdout that B1 / B2
# downstream can consume without further parsing of admin-api responses.
#
# Usage:
#   fetch-queue.sh [<fetch_size>]
#
# Args:
#   fetch_size   optional — defaults to ${OPS_BATCH_FETCH_SIZE:-10}.
#                Passed as `limit=` on the list endpoint.
#
# Env:
#   ADMIN_API_SH         optional — path to the admin-API wrapper. Defaults
#                        to /opt/hydra/workspaces/operations/skills/muso-ops-admin/
#                        scripts/muso-admin-api.sh. Override in tests.
#                        (Same convention as batch-approve-credits.sh.)
#   MUSO_API_URL,
#   MUSO_ADMIN_EMAIL,
#   MUSO_ADMIN_PASSWORD  required by the wrapper; not read directly here.
#
# Exit codes:
#   0   ok — stdout has the normalized envelope. queue_depth==0 with
#       items==[] is also exit 0; that is the legitimate empty-queue path
#       and B1 still routes it through the queue-clear branch.
#   2   wrapper not found / not executable
#   3   list call HTTP non-200 — wrapper response written to stderr
#   4   counts call HTTP non-200 — wrapper response written to stderr
#   5   list response missing .body.data.items (envelope shape drift)
#   6   counts response missing .body.data[0].count (envelope shape drift)
#   11  unverified_count_items_mismatch — counts > 0 but items == 0. The
#       silent-zero pattern this script exists to catch. B1 must NOT post
#       the queue-clear message; instead escalate.
#
# Output (stdout, success):
#   {"queue_depth": <int>, "items": [...], "fetch_size": <int>}

set -euo pipefail

FETCH_SIZE="${1:-${OPS_BATCH_FETCH_SIZE:-10}}"

if ! [[ "$FETCH_SIZE" =~ ^[0-9]+$ ]] || (( FETCH_SIZE == 0 )); then
    echo "ERROR: fetch_size must be a positive integer, got: '$FETCH_SIZE'" >&2
    exit 2
fi

# --- Hard cap aligned to subagent-pool throughput -----------------------
# Run 20260501-135646-ecff37 fetched 500 credits → 117 profile groups, but
# the subagent pool only managed 6 spawns in 5 min. Asking for more credits
# than the pool can investigate in one cron window (30 min) just produces
# panic-finalize (gate-blocked action_attempted) + truth-floor pollution.
#
# Window math: 30 min × 10 pool-slot × ~30s per HTTP-only subagent
#   = ~600 profile-slots theoretical. Realistic ~50 with overhead +
#   subagent failure rate. Default cap is 200 credits (matches ~50
#   profile groups at ~4 credits/profile). Override with
#   OPS_BATCH_FETCH_HARD_CAP only for one-off backfill runs supervised
#   by a human; the cron schedule (every 4h) is the right way to drain
#   the queue, not larger batches.
HARD_CAP="${OPS_BATCH_FETCH_HARD_CAP:-200}"
if (( FETCH_SIZE > HARD_CAP )); then
    echo "WARN: fetch_size $FETCH_SIZE exceeds hard cap $HARD_CAP — capping to $HARD_CAP. " \
         "To raise the cap intentionally, set OPS_BATCH_FETCH_HARD_CAP. " \
         "To drain queue faster, prefer multiple cron windows over larger batches." >&2
    FETCH_SIZE="$HARD_CAP"
fi

ADMIN_API_SH="${ADMIN_API_SH:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"

# We invoke via `bash $ADMIN_API_SH`, which only requires read access.
# Reject non-files (directory / broken symlink / device node) explicitly:
# `[[ -r dir ]]` is true for readable directories but `bash <dir>` would
# fail with a confusing error. The `-f` check also makes the "unreadable
# wrapper" test deterministic under root, where `[[ -r ]]` bypasses
# file-mode bits.
if [[ ! -f "$ADMIN_API_SH" ]] || [[ ! -r "$ADMIN_API_SH" ]]; then
    echo "ERROR: admin-API wrapper not found or not readable at $ADMIN_API_SH" >&2
    exit 2
fi

# --- List fetch ---------------------------------------------------------
LIST_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests?status=unverified&limit=${FETCH_SIZE}")

LIST_HTTP=$(echo "$LIST_RESP" | jq -r '.http_status // "unknown"')
if [[ "$LIST_HTTP" != "200" ]]; then
    echo "ERROR: list endpoint HTTP $LIST_HTTP" >&2
    echo "$LIST_RESP" >&2
    exit 3
fi

# Locked jq path — no `//` fallback for the primary shape. A missing
# .body.data.items is shape drift and must trip exit 5, not silently
# return [].
ITEMS=$(echo "$LIST_RESP" | jq -c '.body.data.items')
if [[ -z "$ITEMS" || "$ITEMS" == "null" ]]; then
    echo "ERROR: envelope_shape_drift: list response missing .body.data.items" >&2
    echo "$LIST_RESP" | jq -c '.body | {keys: (. | keys), data_keys: (.data? | if type=="object" then keys elif type=="array" then ["<array>", length] else null end)}' >&2 || true
    exit 5
fi

# --- Counts fetch -------------------------------------------------------
COUNTS_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests/counts?status=unverified")

COUNTS_HTTP=$(echo "$COUNTS_RESP" | jq -r '.http_status // "unknown"')
if [[ "$COUNTS_HTTP" != "200" ]]; then
    echo "ERROR: counts endpoint HTTP $COUNTS_HTTP" >&2
    echo "$COUNTS_RESP" >&2
    exit 4
fi

# Counts envelope is `body.data: [{status, count}]`. We asked for status=
# unverified explicitly, so we trust position [0] — but assert it's
# numeric, not null, before continuing.
COUNT=$(echo "$COUNTS_RESP" | jq -r '.body.data[0].count // empty')
if [[ -z "$COUNT" ]] || ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: envelope_shape_drift: counts response missing .body.data[0].count (got: '$COUNT')" >&2
    echo "$COUNTS_RESP" >&2
    exit 6
fi

# --- Silent-zero invariant ---------------------------------------------
# The exact pattern that caused the 2026-04-27 false "queue clear":
# counts says there ARE unverified credits, but the list returned zero
# items. Either the API is inconsistent (rare) or some upstream filter
# drift is hiding items. Either way, posting a queue-clear summary would
# lie. Fail loud — B1 must escalate.
ITEMS_LEN=$(echo "$ITEMS" | jq 'length')
if (( COUNT > 0 )) && (( ITEMS_LEN == 0 )); then
    echo "ERROR: unverified_count_items_mismatch: count=$COUNT items=0 (silent-zero pattern, see 2026-04-27 incident)" >&2
    exit 11
fi

# --- Per-item enrichment: backend Tier-1 source resolution -------------
# Each credit-request item gets a `tier1_sources` envelope describing the
# backend-known Tier-1 URLs (today: Tidal album-credits via
# /admin/track/<id>/sources + /admin/album/<id>/sources). SKILL.md B3
# branches on `tier1_sources.backend_tier1_count`:
#   >=2 → backend-only verify; ==1 → backend + 1 search-and-click;
#   ==0 → full search-and-click chain.
#
# Resolution failure for any single item degrades silently to a count=0
# envelope (the helper never exits non-zero outside missing-args). The
# item still flows through the queue — the agent will fall back to the
# search-and-click chain for it.
RESOLVE_SH="$(dirname "$0")/resolve-tier1-sources.sh"
if (( ITEMS_LEN > 0 )); then
    ENRICHED_ITEMS=$(echo "$ITEMS" | jq -c '.[]' | while IFS= read -r item; do
        track_id=$(jq -r '.trackId // empty' <<<"$item")
        spotify_track_id=$(jq -r '.spotifyTrackId // empty' <<<"$item")
        cr_id=$(jq -r '.id // empty' <<<"$item")

        tier1_args=()
        [[ -n "$track_id" ]]         && tier1_args+=(--track-id "$track_id")
        [[ -n "$spotify_track_id" ]] && tier1_args+=(--spotify-track-id "$spotify_track_id")
        [[ -n "$cr_id" ]]            && tier1_args+=(--cr-id "$cr_id")

        # If neither track-id nor spotify-track-id is set, skip the helper
        # (it would exit 2). Default envelope keeps backend_tier1_count=0
        # so the agent falls back to search-and-click.
        if (( ${#tier1_args[@]} == 0 )) || \
           { [[ -z "$track_id" ]] && [[ -z "$spotify_track_id" ]]; }; then
            tier1='{"muso_track_id":null,"muso_album_id":null,"tidal_track_id":null,"tidal_track_url":null,"tidal_album_id":null,"tidal_album_credits_url":null,"backend_tier1_count":0}'
        else
            tier1=$(bash "$RESOLVE_SH" "${tier1_args[@]}" 2>>"${OPS_AUDIT_LOG_DIR:-/tmp}/resolve-tier1-sources.stderr.log" \
                || echo '{"muso_track_id":null,"muso_album_id":null,"tidal_track_id":null,"tidal_track_url":null,"tidal_album_id":null,"tidal_album_credits_url":null,"backend_tier1_count":0}')
        fi
        jq -c --argjson t "$tier1" '. + {tier1_sources: $t}' <<<"$item"
    done | jq -s -c '.')
    ITEMS="$ENRICHED_ITEMS"
fi

# --- Success: emit normalized envelope ---------------------------------
# `--argjson items "$ITEMS"` would put the entire items array on jq's
# argv, which OVERFLOWS ARG_MAX (~128 KB on Linux) for 500-item batches.
# The 2026-04-27 16:31 UTC real run hit this: jq exited with "Argument
# list too long" and the agent fell back to improvised B1, dropping the
# run_started_queue event and producing a misleading run_finished. Build
# the envelope by printf instead — no arg-list limit. ITEMS is already
# a validated JSON array (jq -c '.body.data.items' above), so embedding
# it directly is safe.
printf '{"queue_depth":%s,"items":%s,"fetch_size":%s}\n' \
    "$COUNT" "$ITEMS" "$FETCH_SIZE"

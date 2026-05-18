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

# --- Hard cap aligned to Lobster pipeline throughput --------------------
# Raised from 200 to 500 on 2026-05-18 with the Lobster cutover. The old
# 200 was sized for the subagent-pool batch loop (which is gone — see
# PR #290). The Lobster pipeline runs deterministic bash steps with no
# agent fan-out; the bottleneck is MusicBrainz at 1 req/sec, sized via
# `timeout: 800` in the dispatcher. 500 credits ≈ 12.5 min wall-clock.
HARD_CAP="${OPS_BATCH_FETCH_HARD_CAP:-500}"
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

# --- Counts fetch (FIRST — we need it to compute last_page for FIFO) ----
COUNTS_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests/counts?status=unverified")

COUNTS_HTTP=$(echo "$COUNTS_RESP" | jq -r '.http_status // "unknown"')
if [[ "$COUNTS_HTTP" != "200" ]]; then
    echo "ERROR: counts endpoint HTTP $COUNTS_HTTP" >&2
    echo "$COUNTS_RESP" >&2
    exit 4
fi

COUNT=$(echo "$COUNTS_RESP" | jq -r '.body.data[0].count // empty')
if [[ -z "$COUNT" ]] || ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: envelope_shape_drift: counts response missing .body.data[0].count (got: '$COUNT')" >&2
    echo "$COUNTS_RESP" >&2
    exit 6
fi

# --- List fetch (FIFO via reverse pagination) ---------------------------
# The admin LIST endpoint:
#   1. Always returns DESC by createdAt (newest first).
#   2. Silently ignores all sort params (verified: orderBy, sort,
#      sortBy, direction, order all return identical newest-first lists).
# So FIFO requires fetching the LAST page (oldest items live there).
#
# Strategy:
#   - last_page = ceil(COUNT / FETCH_SIZE) — page where the absolute
#     oldest credits live (partial page; count % FETCH_SIZE items).
#   - Walk pages backwards from last_page until we've accumulated at
#     least FETCH_SIZE items, then sort ASC by createdAt and take the
#     first FETCH_SIZE. The +id tiebreaker is for deterministic order
#     when two credits share a millisecond timestamp.
#
# Empty queue (COUNT == 0) → emit empty envelope; the silent-zero
# invariant below still catches the count>0/items==0 drift case.

ITEMS='[]'
if (( COUNT > 0 )); then
    LAST_PAGE=$(( (COUNT + FETCH_SIZE - 1) / FETCH_SIZE ))
    PAGE_N="$LAST_PAGE"
    while (( PAGE_N > 0 )); do
        LIST_RESP=$(bash "$ADMIN_API_SH" call GET "/admin/credit-requests?status=unverified&limit=${FETCH_SIZE}&page=${PAGE_N}")
        LIST_HTTP=$(echo "$LIST_RESP" | jq -r '.http_status // "unknown"')
        if [[ "$LIST_HTTP" != "200" ]]; then
            echo "ERROR: list endpoint HTTP $LIST_HTTP (page=$PAGE_N)" >&2
            echo "$LIST_RESP" >&2
            exit 3
        fi

        PAGE_ITEMS=$(echo "$LIST_RESP" | jq -c '.body.data.items')
        if [[ -z "$PAGE_ITEMS" || "$PAGE_ITEMS" == "null" ]]; then
            echo "ERROR: envelope_shape_drift: list response missing .body.data.items (page=$PAGE_N)" >&2
            echo "$LIST_RESP" | jq -c '.body | {keys: (. | keys)}' >&2 || true
            exit 5
        fi

        # printf builtin (no execve, no ARG_MAX) → jq stdin via slurp.
        # Plain `--argjson` overflows ARG_MAX once accumulated items > ~128KB.
        ITEMS=$(printf '%s\n%s\n' "$ITEMS" "$PAGE_ITEMS" | jq -sc 'add')
        ITEMS_LEN_SO_FAR=$(echo "$ITEMS" | jq 'length')
        if (( ITEMS_LEN_SO_FAR >= FETCH_SIZE )); then
            break
        fi
        PAGE_N=$(( PAGE_N - 1 ))
    done

    # Sort oldest-first, tie-break by id, then take the requested count.
    ITEMS=$(echo "$ITEMS" | jq -c "sort_by(.createdAt, .id) | .[:${FETCH_SIZE}]")
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

# --- Per-item enrichment REMOVED (2026-05-18, Lobster cutover) ----------
# The legacy enrichment loop ran resolve-tier1-sources.sh for every item,
# adding a `tier1_sources` envelope consumed by the deleted agent-batch
# flow's Tier-1 branching. None of the Lobster pipeline steps
# (score-backend-signals, run-mb-batch, verdict-engine, apply-verdicts,
# render-dry-run-summary) read that field — verified by grep on
# 2026-05-18. At N=500 the loop made ~1500 admin-API calls and exceeded
# the dispatcher's 800s timeout. Removing it makes the fetch run in
# ~1 second total. resolve-tier1-sources.sh is still on disk for ad-hoc
# debugging.

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

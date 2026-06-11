#!/usr/bin/env bash
# fraud-muso-only-lookup.sh — FAIL-SOFT batched Trino lookup of the
# "muso-only credits on popular tracks" fraud signal, one row per profile.
#
# This is the single Trino factor in the batch fraud scorer (score-fraud-
# signals.sh). It is DELIBERATELY fail-soft: any error, timeout, missing
# kubectl/trino, or malformed output yields an empty map "{}" on stdout, a
# LOUD diagnostic on stderr, and exit 0. The fraud scorer treats a profile
# absent from the map as "muso_only factor unavailable" (weight 0) — the
# batch is NEVER blocked on Trino. This mirrors the design decision that the
# muso-only signal is best-effort enrichment, not a gate.
#
# Input (profile IDs):
#   - one per line on stdin, OR
#   - a single comma-/newline-separated argument: fraud-muso-only-lookup.sh "a,b,c"
#   IDs are de-duplicated and validated as UUIDs; non-UUID tokens are dropped
#   with a stderr note (the upstream batch should only ever pass real
#   profileIds, but we never inject an unvalidated token into SQL).
#
# Output (stdout, ALWAYS valid JSON, ALWAYS exit 0):
#   { "available": <bool>, "data": { "<profileId>": <pct:number>, ... } }
#
#   `available` is the SOURCE OF TRUTH for whether the Trino signal could be
#   computed this run — the caller MUST read it, NOT infer availability from
#   whether `data` is empty. A healthy Trino that returns zero qualifying rows
#   (the COMMON clean case) is `available:true` with `data:{}`; only a real
#   failure (down/timeout/error-page/parse-failure) is `available:false`. This
#   distinction is load-bearing: inferring "down" from an empty map made a
#   clean batch falsely cry "Trino UNAVAILABLE" (the inverted fail-soft bug,
#   fixed 2026-06-08).
#
#   data: { "<profileId>": <pct_muso_only_popularity:number>, ... }
#   pct_muso_only_popularity is 0..100 (the same metric as
#   potential_fraud_accounts_muso_only_credits.sql column 7). Profiles with
#   no qualifying rows are simply ABSENT from the map (not 0) — the scorer
#   treats absent as "looked up, this profile clean" (factor contributes 0).
#
# Env:
#   CV_FRAUD_MUSO_TRINO_TIMEOUT   seconds, default 300. Wall-clock cap on the
#                                 trino-query.sh call (via `timeout`). On
#                                 expiry → "{}" + stderr note + exit 0.
#                                 The batched query full-scans
#                                 matvw_raw_recording_credit; measured 56s and
#                                 134s live on 2026-06-11 (same query, cluster
#                                 load variance), so 300 ≈ 2× the observed
#                                 worst case. Budget: the lobster pipeline cap
#                                 is 700s timeoutMs total and batches measure
#                                 ≤~160s end-to-end, so a full 300s stall
#                                 still fail-softs without starving the run.
#   TRINO_QUERY_SH                path to trino-query.sh. Default resolves
#                                 relative to repo root, falling back to the
#                                 deployed /opt/hydra path.
#   CV_FRAUD_MUSO_MIN_TRACK_POP   total_track_popularity floor (mirrors the
#                                 saved query's `> 50`). Default 50.
#
# No side effects beyond the read-only Trino SELECT. Pure bash + jq + the
# trino wrapper. set -euo pipefail is intentionally NOT used at the top
# level: this script must reach its fail-soft "{}" emit even when an inner
# command fails. Inner failures are checked explicitly.

set -uo pipefail

CV_FRAUD_MUSO_TRINO_TIMEOUT="${CV_FRAUD_MUSO_TRINO_TIMEOUT:-300}"
CV_FRAUD_MUSO_MIN_TRACK_POP="${CV_FRAUD_MUSO_MIN_TRACK_POP:-50}"

# Resolve trino-query.sh. Repo layout: scripts/trino-query.sh at repo root.
# This file lives at workspaces/operations/skills/muso-ops-credit-verification/
# scripts/lib/, so repo root is five levels up. On the deployed server the
# repo-root scripts/ is at /opt/hydra/scripts/.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${TRINO_QUERY_SH:-}" ]]; then
  TRINO_SH="$TRINO_QUERY_SH"
elif [[ -x "$HERE/../../../../../../scripts/trino-query.sh" ]]; then
  TRINO_SH="$HERE/../../../../../../scripts/trino-query.sh"
elif [[ -x /opt/hydra/scripts/trino-query.sh ]]; then
  TRINO_SH=/opt/hydra/scripts/trino-query.sh
else
  TRINO_SH="$HERE/../../../../../../scripts/trino-query.sh"
fi

# Emit the unavailable wrapper + a loud stderr note, then exit 0. Used for
# every fail-soft path. `available:false` tells the scorer the signal was DOWN
# (vs a healthy empty result, which is `available:true` with empty data).
soft_fail() {
  echo "[fraud-muso-only-lookup] UNAVAILABLE this run: $1 — muso_only factor weighted 0 for the whole batch." >&2
  printf '{"available":false,"data":{}}\n'
  exit 0
}

# --- Collect profile IDs from stdin or arg ---------------------------------
RAW=""
if [[ "$#" -gt 0 ]]; then
  RAW="$*"
elif [[ ! -t 0 ]]; then
  RAW="$(cat)"
fi

# Split on commas + whitespace/newlines, de-dup, keep UUIDs only. Done in jq
# (NOT bash associative arrays — those need bash 4+, and node-8/macOS bash
# versions differ; jq is the portable common denominator already required).
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# UUIDS_NL: newline-separated, validated, de-duped UUIDs. Counts of total vs
# kept tokens drive the "dropped" diagnostic.
PARSED=$(printf '%s' "$RAW" | jq -R -s --arg re "^${UUID_RE}\$" '
  ( split("[,\\s]+"; "") | map(select(length > 0)) ) as $toks
  | ($toks | map(select(test($re)))) as $uuids
  | { total: ($toks | length),
      kept:  ($uuids | unique),
    } | { dropped: (.total - (.kept | length)),
          ids: .kept }')
DROPPED=$(printf '%s' "$PARSED" | jq -r '.dropped')
IDS_JSON=$(printf '%s' "$PARSED" | jq -c '.ids')
N_IDS=$(printf '%s' "$IDS_JSON" | jq 'length')

if [[ "$DROPPED" != "0" ]]; then
  echo "[fraud-muso-only-lookup] dropped $DROPPED non-UUID token(s) before SQL build." >&2
fi

if [[ "$N_IDS" == "0" ]]; then
  # Nothing to look up is NOT a failure — we successfully determined there is
  # nothing to query, so the signal is "available" with empty data.
  echo "[fraud-muso-only-lookup] no valid profile IDs on input — nothing to query." >&2
  printf '{"available":true,"data":{}}\n'
  exit 0
fi

# --- Build the IN (...) list -----------------------------------------------
# Single-quoted UUIDs (validated above, so no injection surface). jq emits the
# comma-joined, single-quoted list directly.
IN_LIST=$(printf '%s' "$IDS_JSON" | jq -r 'map("'\''" + . + "'\''") | join(",")')

# --- The batched SQL --------------------------------------------------------
# Adapted from skills-all/muso-query-writer/saved-queries/misc/
# potential_fraud_accounts_muso_only_credits.sql. Differences:
#   * Drops the `mp` claiming-status CTE (we already have a concrete profile
#     set — the batch's profileIds — so we filter rp by IN(...) directly).
#   * Returns pct_muso_only_popularity for EVERY queried profile that has any
#     catalog rows, not just those over the saved query's 50% threshold (the
#     scorer applies its own threshold, so the helper must not pre-filter the
#     percentage). We DO keep the total_track_popularity floor as a env-var
#     (default 50) to match the saved query's denominator-sanity guard.
#   * CSV output (trino-query.sh default) → parsed to JSON by jq below.
#
# Column order emitted: profile_id, pct_muso_only_popularity.
SQL=$(cat <<SQL_EOF
with
rp as (
  select raw_profile_id, _id as profile_id
  from hive."platform-industry-bi-prod".matvw_catalog_profile
    cross join unnest(raw_profile_ids) as r(raw_profile_id)
  where not is_deleted
    and _id in (${IN_LIST})
),
rt as (
  select raw_recording_id, _id as track_id, max(popularity) as track_popularity
  from hive."platform-industry-bi-prod".matvw_catalog_track
    cross join unnest(raw_recording_ids) as r(raw_recording_id)
  where not is_deleted
  group by 1, 2
),
rc as (
  select profile_id as raw_profile_id,
    recording_id as raw_recording_id,
    recording_id like 'muso%' and profile_id like 'muso%' as is_muso
  from hive."platform-industry-bi-prod".matvw_raw_recording_credit
),
m as (
  select profile_id, track_id,
    count_if(not is_muso) = 0 as is_muso_only,
    max(track_popularity) as track_popularity
  from rc
    join rp using(raw_profile_id)
    join rt using(raw_recording_id)
  group by 1, 2
)
select profile_id,
  100.0 * sum(if(is_muso_only, track_popularity, 0)) / nullif(sum(track_popularity), 0) as pct_muso_only_popularity
from m
group by 1
having sum(track_popularity) > ${CV_FRAUD_MUSO_MIN_TRACK_POP}
SQL_EOF
)

# --- Run it, fail-soft on everything ---------------------------------------
if ! command -v "$TRINO_SH" >/dev/null 2>&1 && [[ ! -x "$TRINO_SH" ]]; then
  soft_fail "trino-query.sh not found/executable at $TRINO_SH"
fi

# Capture trino-query.sh stderr to a tempfile so a failure can NAME itself in
# the soft_fail diagnostic. Discarding it (the pre-2026-06-11 behavior) hid a
# "Column 'profile_id' cannot be resolved" error behind a bare "exited rc=1"
# for every production run since shadow went live.
TRINO_ERR="$(mktemp)" || soft_fail "could not create stderr tempfile"
trap 'rm -f "$TRINO_ERR"' EXIT

# Last few stderr lines, joined to one line, for embedding in soft_fail.
err_tail() {
  tail -n 3 "$TRINO_ERR" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/ $//'
}

if ! command -v timeout >/dev/null 2>&1; then
  # No `timeout` binary (e.g. bare macOS without coreutils). Run without it —
  # trino-query.sh / kubectl have their own network timeouts — but note it.
  echo "[fraud-muso-only-lookup] WARN: 'timeout' not available; running trino-query.sh without a wall-clock cap." >&2
  CSV=$(printf '%s\n' "$SQL" | bash "$TRINO_SH" 2>"$TRINO_ERR")
  rc=$?
else
  CSV=$(printf '%s\n' "$SQL" | timeout "${CV_FRAUD_MUSO_TRINO_TIMEOUT}s" bash "$TRINO_SH" 2>"$TRINO_ERR")
  rc=$?
fi

if (( rc == 124 )); then
  soft_fail "trino query exceeded ${CV_FRAUD_MUSO_TRINO_TIMEOUT}s timeout; trino stderr: $(err_tail)"
fi
if (( rc != 0 )); then
  soft_fail "trino-query.sh exited rc=$rc; trino stderr: $(err_tail)"
fi

# --- Parse CSV → JSON map ---------------------------------------------------
# trino --output-format CSV emits quoted fields, no header. Each row:
#   "<uuid>","<pct>"   (pct may be quoted-numeric). Empty result = no rows.
# Build {uuid: number}. Skip any row that doesn't parse to a UUID + number.
MAP=$(printf '%s' "$CSV" | jq -R -s '
  def trimq: gsub("^\"|\"$"; "");
  ( split("\n")
    | map(select(length > 0))
    | map(split(",") | map(trimq))
    | map(select(length >= 2))
    | map({ key: .[0], value: (.[1] | tonumber? // null) })
    | map(select(.value != null))
    | from_entries )' 2>/dev/null)

if [[ -z "$MAP" ]] || ! printf '%s' "$MAP" | jq -e . >/dev/null 2>&1; then
  soft_fail "could not parse trino CSV into a JSON map"
fi

# Distinguish a genuine zero-row result (empty CSV → clean) from a non-empty
# body that yielded ZERO parseable rows (e.g. an HTML 5xx error page returned
# with rc=0 by a gateway). The latter is a silent degrade-to-clean trap: treat
# it as UNAVAILABLE, not as "looked up, all clean".
CSV_NONBLANK=$(printf '%s' "$CSV" | tr -d '[:space:]')
MAP_LEN=$(printf '%s' "$MAP" | jq 'length')
if [[ -n "$CSV_NONBLANK" && "$MAP_LEN" == "0" ]]; then
  soft_fail "trino returned non-empty output that yielded no parseable rows (likely an error page, not a clean result)"
fi

# Success — including a healthy zero-row result (data:{}, available:true).
printf '%s' "$MAP" | jq -c '{available:true, data:.}'
exit 0

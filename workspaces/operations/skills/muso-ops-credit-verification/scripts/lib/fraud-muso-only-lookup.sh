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
#   { "available": <bool>, "data": { "<profileId>": <pct:number>, ... },
#     "reason": <string|omitted> }
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
#   `reason` is present (a short human-readable string) ONLY when
#   `available:false` — the same text emitted on stderr via soft_fail, now
#   also carried in-band so a consumer that never sees this script's stderr
#   (e.g. the fraud scorer's run summary, posted to Slack) can still surface
#   WHY the signal was unavailable. Before this, the reason reached no
#   operator-visible surface outside the raw transcript stderr.
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
#   CV_FRAUD_MUSO_SNAPSHOT_FILE   Daily-materialized snapshot written by
#                                 fraud-muso-only-snapshot-writer.sh (cron).
#                                 Default /var/lib/hydra/cv-fraud-muso-only-
#                                 snapshot.json. When this file exists,
#                                 parses, and is fresh (see below), it is read
#                                 INSTEAD of calling Trino — this removes the
#                                 batch's per-run Trino dependency (see
#                                 fraud-issue-scorer-followups.md §1). A
#                                 missing, unreadable, stale, or malformed
#                                 snapshot is a MISS, not a failure: the
#                                 script silently falls through to the live
#                                 Trino query below (fail-soft semantics on
#                                 the live path are unchanged). "Malformed"
#                                 includes ANY data value that is not a number
#                                 in 0..100 — one bad value rejects the WHOLE
#                                 snapshot, because such a value does not lose
#                                 the signal, it fabricates or suppresses one.
#                                 See the check for the full reasoning.
#   CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS
#                                 Staleness threshold for the snapshot's
#                                 generated_at timestamp. Default 36 (comfortably
#                                 covers a daily cron missing one fire). Must be
#                                 a non-negative integer; anything else is
#                                 rejected with a warning and the default used.
#                                 A snapshot dated more than 300s in the FUTURE
#                                 is a MISS, never age 0 — see the skew note at
#                                 the check itself.
#
# No side effects beyond the read-only Trino SELECT (and, on the snapshot
# path, a read-only file read). Pure bash + jq + the trino wrapper.
# set -euo pipefail is intentionally NOT used at the top level: this script
# must reach its fail-soft "{}" emit even when an inner command fails. Inner
# failures are checked explicitly.

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
  jq -c -n --arg reason "$1" '{available:false, data:{}, reason:$reason}'
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

# --- Snapshot-first: read the daily materialized snapshot before hitting
# Trino live (fraud-issue-scorer-followups.md §1) ---------------------------
# Written by fraud-muso-only-snapshot-writer.sh's daily cron. A miss (file
# absent/unreadable), malformed content (not the expected JSON shape — a
# corrupt file must be treated as a MISS, never as "looked up, all clean";
# that silent degrade-to-clean is the same trap the CSV parser above guards
# against for the live path), or staleness all fall through silently to the
# live query below — this block never calls soft_fail, it only either emits
# a snapshot-backed result and exits, or does nothing and lets the rest of
# the script run exactly as it did before this feature existed.
CV_FRAUD_MUSO_SNAPSHOT_FILE="${CV_FRAUD_MUSO_SNAPSHOT_FILE:-/var/lib/hydra/cv-fraud-muso-only-snapshot.json}"
CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS="${CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS:-36}"
# Bash arithmetic resolves a non-numeric string as a variable name, i.e. 0 — so
# a typo'd override ("36h", "-1", "") would silently make EVERY snapshot look
# stale and quietly disable the feature, which is precisely the kind of silent
# degrade this helper is built to avoid. Validate it and fall back to the
# documented default instead of trusting garbage.
if ! [[ "$CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  echo "[fraud-muso-only-lookup] CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS='$CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS' is not a non-negative integer — using the default 36h." >&2
  CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS=36
fi

# A snapshot may be at most this far in the FUTURE and still be trusted. Writer
# and reader share a host, so this only absorbs a second-boundary race; the
# point is that anything beyond it is rejected rather than trusted forever.
SNAPSHOT_FUTURE_SKEW_SECONDS=300

if [[ -r "$CV_FRAUD_MUSO_SNAPSHOT_FILE" ]]; then
  SNAPSHOT_RAW=$(cat "$CV_FRAUD_MUSO_SNAPSHOT_FILE" 2>/dev/null)
  # Shape check: must be a JSON object with a string generated_at and an
  # object data — NOT just "valid JSON" (an empty file, a truncated write, or
  # some other JSON value must all be treated as malformed/miss).
  #
  # EVERY value must be a number IN 0..100, and a violation invalidates the
  # WHOLE snapshot. This is not pedantry about types: jq's total ordering sorts
  # all strings ABOVE all numbers, so `"not-a-number" > 50` is true. A single
  # non-numeric value therefore does not degrade the signal, it INVERTS it —
  # score-fraud-signals.sh:281 tests `($muso_pct != null) and ($muso_pct >
  # $musoPct)`, so the garbage value passes both arms and silently ADDS the
  # muso_only fraud factor, tipping credits into the fraud bucket on corrupt
  # data. Falling back to live Trino is the only safe reading of a snapshot we
  # cannot trust. The writer only ever emits numbers (its parser drops any row
  # failing `tonumber`), so a violation means real corruption, not drift.
  #
  # The 0..100 bound is enforced for the same reason, not as a style check. The
  # writer's percentage is mathematically bounded: its numerator
  # `sum(if(is_muso_only, track_popularity, 0))` is a subset-sum of its
  # denominator `sum(track_popularity)`, which `having sum(...) > N` keeps
  # positive. So an out-of-range number is corruption exactly like a string is,
  # and it fails the same way — `101 > 50` falsely ADDS the factor, while a
  # negative silently SUPPRESSES a real one. It also catches jq's numeric
  # coercions on hand-edited files: a literal `Infinity` is parsed as the
  # finite 1.797e+308 (so only the range test rejects it), while `nan` becomes
  # `null` and is already caught by the type test above.
  #
  # Keys are deliberately NOT UUID-checked here. The caller's IDs are already
  # UUID-validated upstream and the projection is an exact-key lookup, so a
  # non-UUID key can never be selected and cannot reach the output — while
  # regex-testing every key costs ~150ms per batch at 30k profiles versus
  # ~10ms for the value check that closes the actual hole.
  if printf '%s' "$SNAPSHOT_RAW" | jq -e '
        (type == "object")
        and (.generated_at | type) == "string"
        and (.data | type) == "object"
        and (all(.data[]; type == "number" and . >= 0 and . <= 100))
      ' >/dev/null 2>&1; then
    GENERATED_AT=$(printf '%s' "$SNAPSHOT_RAW" | jq -r '.generated_at')
    GENERATED_EPOCH=$(date -u -d "$GENERATED_AT" +%s 2>/dev/null \
                       || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$GENERATED_AT" +%s 2>/dev/null \
                       || echo "")
    NOW_EPOCH=$(date -u +%s)
    if [[ -z "$GENERATED_EPOCH" ]]; then
      echo "[fraud-muso-only-lookup] snapshot at $CV_FRAUD_MUSO_SNAPSHOT_FILE has an unparseable generated_at — treating as a miss, falling back to live Trino." >&2
    elif (( GENERATED_EPOCH > NOW_EPOCH + SNAPSHOT_FUTURE_SKEW_SECONDS )); then
      # A future-dated snapshot must NEVER be trusted. AGE_HOURS would be
      # negative, so it always satisfies the max-age test below — meaning a
      # clock jump, a restored backup, or a hand-edited generated_at would pin
      # the reader to that one snapshot until its timestamp finally arrived,
      # even as every later writer run failed. That is the exact "silently keep
      # serving stale data" failure the staleness check exists to prevent, so
      # it is treated as a miss rather than as age 0.
      echo "[fraud-muso-only-lookup] snapshot at $CV_FRAUD_MUSO_SNAPSHOT_FILE is dated in the future (generated_at=$GENERATED_AT, ${GENERATED_EPOCH}s > now ${NOW_EPOCH}s + ${SNAPSHOT_FUTURE_SKEW_SECONDS}s skew) — treating as a miss, falling back to live Trino." >&2
    else
      AGE_HOURS=$(( (NOW_EPOCH - GENERATED_EPOCH) / 3600 ))
      if (( AGE_HOURS <= CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS )); then
        echo "[fraud-muso-only-lookup] serving from snapshot generated_at=$GENERATED_AT (age ${AGE_HOURS}h) — no live Trino call this run." >&2
        # Project the batch's IDs OUT of the snapshot, rather than scanning the
        # snapshot and testing each key against the ID list. The snapshot holds
        # every qualifying profile (tens of thousands); `$ids | index($k)` is a
        # linear scan run once per snapshot entry, so that form costs
        # O(snapshot × batch) and grows as the fleet's catalog does — measured
        # 0.44s at 30k profiles × 500 IDs vs 0.019s here, on a path whose whole
        # purpose is to be faster than the live query. `!= null` rather than a
        # `//` default on purpose: a legitimate 0.0 percentage is falsy to jq's
        # `//` and would be dropped.
        printf '%s' "$SNAPSHOT_RAW" | jq -c --argjson ids "$IDS_JSON" \
          '.data as $d
           | {available:true,
              data: ($ids | map(select($d[.] != null) | {key:., value:$d[.]}) | from_entries)}'
        exit 0
      else
        echo "[fraud-muso-only-lookup] snapshot at $CV_FRAUD_MUSO_SNAPSHOT_FILE is stale (generated_at=$GENERATED_AT, age ${AGE_HOURS}h > ${CV_FRAUD_MUSO_SNAPSHOT_MAX_AGE_HOURS}h) — falling back to live Trino." >&2
      fi
    fi
  else
    echo "[fraud-muso-only-lookup] snapshot at $CV_FRAUD_MUSO_SNAPSHOT_FILE is malformed (not the expected {generated_at,data} shape, or a data value is not a number in 0..100) — treating as a miss, falling back to live Trino." >&2
  fi
else
  echo "[fraud-muso-only-lookup] no snapshot at $CV_FRAUD_MUSO_SNAPSHOT_FILE — falling back to live Trino." >&2
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

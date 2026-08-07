#!/usr/bin/env bash
# fraud-muso-only-snapshot-writer.sh — daily cron job that materializes the
# muso-only fraud signal for ALL qualifying profiles into a snapshot file, so
# fraud-muso-only-lookup.sh can read a file instead of hitting Trino in-loop
# on every credit-verification batch run.
#
# Background: fraud-issue-scorer-followups.md §1. On 2026-08-01 the batch's
# in-loop Trino call hit its 300s cap (measured 56s/134s previously — 300s is
# only ~2x observed worst case under load) and the muso_only factor ran
# unavailable for that whole batch. This script decouples the factor from
# per-batch Trino latency: a wall-clock daily refresh with no human in the
# loop, so it is an openclaw cron (cron-jobs.json), not a systemd timer.
#
# SQL: the SAME query shape as fraud-muso-only-lookup.sh's batched lookup,
# adapted from skills-all/muso-query-writer/saved-queries/misc/
# potential_fraud_accounts_muso_only_credits.sql, but WITHOUT an IN(...)
# profile filter — the `rp` CTE instead joins the saved query's original
# `mp` CTE (claiming status='processed', profiletype<>'organization') to
# cover every qualifying profile in one pass. Like the lookup helper, this
# does NOT apply the saved query's `pct_muso_only_popularity > 50` filter —
# the raw percentage is kept so callers can apply their own threshold
# (CV_FRAUD_MUSO_ONLY_PCT). Validated read-only via
# `EXPLAIN (TYPE VALIDATE)` on node-8 (2026-08-06); never run this ad hoc
# against prod to "test" it — it is a full-scan cross-join, same shape as
# the batched query.
#
# Output: a JSON file {"generated_at": "<ISO8601 UTC>", "data": {"<profileId>":
# <pct:number>, ...}} written ATOMICALLY (mktemp in the same dir + mv) so a
# reader never observes a partial write.
#
# This is a CRON SCRIPT, not fail-soft to itself: on any failure it leaves
# the existing snapshot (if any) untouched and exits non-zero — the reader's
# own staleness check is what degrades gracefully, not this writer silently
# producing a corrupt/empty file. set -euo pipefail is appropriate here
# (unlike fraud-muso-only-lookup.sh, which must always still emit "{}").
#
# Env:
#   CV_FRAUD_MUSO_SNAPSHOT_FILE          Output path.
#                                        Default /var/lib/hydra/cv-fraud-muso-only-snapshot.json
#                                        (server-owned, outside the rsync-managed
#                                        /opt/hydra tree — same convention as
#                                        dispatch-cv-batch.sh's CV_DISPATCH_HISTORY_FILE
#                                        at /var/lib/hydra/cv-dispatch-history, so no
#                                        RSYNC_EXCLUDES / qa-clean-merge-scratch.sh KEEP
#                                        glob entry is needed).
#   CV_FRAUD_MUSO_SNAPSHOT_TRINO_TIMEOUT Seconds, default 600 (this query is a
#                                        full-scan over ALL qualifying profiles,
#                                        not a short IN-list, so it gets a
#                                        larger budget than the batched lookup's
#                                        300s cap; a daily cron has no downstream
#                                        pipeline deadline to protect).
#   CV_FRAUD_MUSO_MIN_TRACK_POP          total_track_popularity floor, default 50
#                                        (mirrors fraud-muso-only-lookup.sh).
#   TRINO_QUERY_SH                       path to trino-query.sh, same resolution
#                                        as fraud-muso-only-lookup.sh.

set -euo pipefail

SNAPSHOT_FILE="${CV_FRAUD_MUSO_SNAPSHOT_FILE:-/var/lib/hydra/cv-fraud-muso-only-snapshot.json}"
TRINO_TIMEOUT="${CV_FRAUD_MUSO_SNAPSHOT_TRINO_TIMEOUT:-600}"
CV_FRAUD_MUSO_MIN_TRACK_POP="${CV_FRAUD_MUSO_MIN_TRACK_POP:-50}"

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

if ! command -v "$TRINO_SH" >/dev/null 2>&1 && [[ ! -x "$TRINO_SH" ]]; then
  echo "[fraud-muso-only-snapshot-writer] trino-query.sh not found/executable at $TRINO_SH — leaving existing snapshot (if any) untouched." >&2
  exit 1
fi

SQL=$(cat <<SQL_EOF
with
mp as (
  select distinct profileid as profile_id
  from postgresql_core.public.claiming
  where status = 'processed' and profiletype <> 'organization'
),
rp as (
  select raw_profile_id, _id as profile_id
  from hive."platform-industry-bi-prod".matvw_catalog_profile
    cross join unnest(raw_profile_ids) as r(raw_profile_id)
    join mp on (profile_id = _id)
  where not is_deleted
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

TRINO_ERR="$(mktemp)"
trap 'rm -f "$TRINO_ERR"' EXIT

# Capture the exit code ourselves (not via `set -e`) so a Trino failure gets
# our own diagnostic + "left untouched" note before this cron script exits,
# instead of dying silently mid-pipeline.
set +e
if command -v timeout >/dev/null 2>&1; then
  CSV=$(printf '%s\n' "$SQL" | timeout "${TRINO_TIMEOUT}s" bash "$TRINO_SH" 2>"$TRINO_ERR")
else
  echo "[fraud-muso-only-snapshot-writer] WARN: 'timeout' not available; running trino-query.sh without a wall-clock cap." >&2
  CSV=$(printf '%s\n' "$SQL" | bash "$TRINO_SH" 2>"$TRINO_ERR")
fi
rc=$?
set -e

if (( rc != 0 )); then
  echo "[fraud-muso-only-snapshot-writer] trino-query.sh exited rc=$rc; stderr: $(tail -n 5 "$TRINO_ERR" | tr '\n' ' ')" >&2
  echo "[fraud-muso-only-snapshot-writer] leaving existing snapshot (if any) untouched." >&2
  exit 1
fi

# Parse CSV → {profile_id: pct} map, ALL-OR-NOTHING.
#
# Every non-blank row must yield a UUID key and a number in 0..100. If even one
# does not, the whole result is rejected and the previous snapshot is kept.
# Dropping just the bad rows — the obvious reading, and what this did before —
# is the dangerous option: a partial result still has MAP_LEN > 0, so the
# writer would overwrite the good snapshot and exit 0, and the dropped profiles
# would simply be ABSENT from the file. Absent is not "unknown" to the reader;
# fraud-muso-only-lookup.sh documents it as "looked up, this profile clean"
# (factor contributes 0). So one malformed row silently SUPPRESSES the
# muso_only fraud factor for that profile for up to 36h, with a successful
# writer run and nothing in the log. Refusing the batch keeps yesterday's
# snapshot, which is both correct and loud.
#
# Unlike the reader, the writer DOES validate UUID keys: this runs once a day
# over the full result, where a regex per row is free, whereas in the reader
# the same check costs ~150ms on every batch for a key that can never be
# selected. Validate where it is cheap and authoritative — at the boundary
# where the data enters.
#
# `test("\\S")` (not `length > 0`) defines "non-blank", so a trailing newline
# or a whitespace-only line is skipped rather than counted as a failed row.
# --output-format CSV emits no header (that is CSV_HEADER), so every non-blank
# line is expected to be data.
PARSED=$(printf '%s' "$CSV" | jq -R -s '
  def trimq: gsub("^\"|\"$"; "");
  def isuuid: test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
  [ split("\n")[] | select(test("\\S")) | split(",") | map(trimq) ] as $rows
  | [ $rows[]
      | select( (length >= 2)
                and (.[0] | isuuid)
                and ( (.[1] | tonumber? // null) as $v
                      | $v != null and $v >= 0 and $v <= 100 ) )
      | { key: .[0], value: (.[1] | tonumber) } ] as $valid
  | { rows: ($rows | length), valid: ($valid | length), data: ($valid | from_entries) }
' 2>/dev/null)

if [[ -z "$PARSED" ]] || ! printf '%s' "$PARSED" | jq -e . >/dev/null 2>&1; then
  echo "[fraud-muso-only-snapshot-writer] could not parse trino CSV into a JSON map — leaving existing snapshot untouched." >&2
  exit 1
fi

CSV_ROWS=$(printf '%s' "$PARSED" | jq -r '.rows')
MAP_LEN=$(printf '%s' "$PARSED" | jq -r '.valid')
if [[ "$CSV_ROWS" != "$MAP_LEN" ]]; then
  echo "[fraud-muso-only-snapshot-writer] only $MAP_LEN of $CSV_ROWS non-blank trino row(s) parsed as {uuid, 0..100} — refusing to write an incomplete snapshot, leaving the existing one untouched." >&2
  exit 1
fi

# Anomalous-empty guard. A zero-row result with rc=0 is syntactically valid but
# is NOT a safe thing to publish over a snapshot that had data: an empty
# snapshot is not "unknown" to the reader, it is `available:true` with no
# entries, i.e. EVERY queried profile reads as clean and the muso_only factor
# is suppressed fleet-wide for up to 36h. In production this query covers every
# claimed non-organization profile over the popularity floor, so zero rows means
# an upstream matview is empty or the result was truncated — not that the fraud
# signal genuinely vanished overnight. Keeping yesterday's data is strictly
# better than publishing a confident "all clean".
#
# An UNPARSEABLE prior also blocks the empty write, which is the subtle half:
# the reader treats a malformed snapshot as a MISS and falls back to live Trino
# (safe), whereas overwriting it with `{}` would flip that to "all clean"
# (unsafe). So a corrupt prior must not be "upgraded" into a confident empty.
# Only a genuine first run, or a prior that is itself a valid empty snapshot,
# may write an empty one.
if [[ "$MAP_LEN" == "0" && -e "$SNAPSHOT_FILE" ]]; then
  PRIOR_LEN=$(jq -r 'if (.data | type) == "object" then (.data | length) else "unparseable" end' \
                "$SNAPSHOT_FILE" 2>/dev/null || echo "unparseable")
  if [[ "$PRIOR_LEN" != "0" ]]; then
    echo "[fraud-muso-only-snapshot-writer] trino returned zero rows but the existing snapshot holds $PRIOR_LEN entr(y/ies) — refusing to overwrite it with an empty snapshot (an empty file reads as 'every profile clean', not 'unknown'); leaving the existing one untouched." >&2
    exit 1
  fi
fi

MAP=$(printf '%s' "$PARSED" | jq -c '.data')

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "$SNAPSHOT_FILE")"
TMP_OUT="$(mktemp "${SNAPSHOT_FILE}.XXXXXX")"
trap 'rm -f "$TRINO_ERR" "${TMP_OUT:-}"' EXIT

# The map goes in on STDIN, NOT via `--argjson data "$MAP"`. This map holds one
# entry per qualifying profile — unbounded, and ~45 bytes per UUID entry, so it
# crosses Linux's ~128KB cap on a SINGLE argv element (MAX_ARG_STRLEN) at only a
# few thousand profiles. Past that, exec fails with "Argument list too long"
# (E2BIG) before jq ever runs, the writer dies before creating its first
# snapshot, and every batch silently keeps falling back to the live Trino query
# this script exists to remove. Not hypothetical: the same mistake killed the
# first shadow cron batch on 2026-06-10, which is why score-fraud-signals.sh
# feeds its raw batch via --slurpfile (see the note at its jq call).
# `printf` is a bash builtin, so piping "$MAP" execs nothing and has no limit.
if ! printf '%s' "$MAP" | jq -c --arg ts "$GENERATED_AT" '{generated_at: $ts, data: .}' > "$TMP_OUT"; then
  echo "[fraud-muso-only-snapshot-writer] failed to serialize the snapshot JSON — leaving existing snapshot untouched." >&2
  exit 1
fi

mv -f "$TMP_OUT" "$SNAPSHOT_FILE"

echo "[fraud-muso-only-snapshot-writer] wrote $MAP_LEN profile(s) to $SNAPSHOT_FILE (generated_at=$GENERATED_AT)."

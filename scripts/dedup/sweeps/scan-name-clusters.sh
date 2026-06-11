#!/usr/bin/env bash
# Proactive name-cluster sweep. Finds Muso profile dupes that nobody filed a
# ticket for, by grouping matvw_catalog_profile on lower(name) and pair-
# scoring within each name bucket.
#
# This complements --catalog (which keys on external IDs): same-name dupes
# without overlapping raw_profile_ids/ipis are invisible to --catalog but
# common when both profiles were stubbed independently with different
# upstream platforms.
#
# Output: JSONL on stdout, one dupe-candidate row per pair from find-dupes.
# Exit codes: 0 ok, 1 usage error, 4 Trino failure.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
FIND_DUPES="${DEDUP_FIND_DUPES_BIN:-$REPO_ROOT/scripts/dedup/find-dupes.sh}"
MUSO="${MUSO_BIN:-muso}"

top_n="200"
max_cluster_size="50"
min_cluster_size="2"
limit_per_cluster="50"

usage() {
  cat <<EOF
Usage:
  scan-name-clusters.sh [--top-n N] [--max-cluster-size N]
                        [--min-cluster-size N] [--limit-per-cluster N]
                        [--dry-run]

Walks the top-N name buckets in matvw_catalog_profile (descending by
cluster size) and runs find-dupes.sh --name on each bucket whose size is
in [min, max]. Clusters above max are skipped with a stderr note (require
human triage — e.g. the 30-profile "Empire" cluster).

Flags:
  --top-n N              top N names to scan, ordered by cluster size DESC
                         (default 200)
  --max-cluster-size N   skip clusters larger than this (default 50)
  --min-cluster-size N   skip clusters smaller than this (default 2)
  --limit-per-cluster N  forwarded to find-dupes --name --limit
                         (default 50)
  --dry-run              accepted for symmetry with other sweeps;
                         this script is read-only either way

Output: JSONL on stdout — one row per pair that find-dupes.sh classifies
as hard_dupe or candidate_dupe.

Env:
  MUSO_BIN               override muso CLI path (used by tests)
  DEDUP_FIND_DUPES_BIN   override find-dupes.sh path (used by tests)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --top-n)              top_n="${2:-}";              shift 2 ;;
    --max-cluster-size)   max_cluster_size="${2:-}";   shift 2 ;;
    --min-cluster-size)   min_cluster_size="${2:-}";   shift 2 ;;
    --limit-per-cluster)  limit_per_cluster="${2:-}";  shift 2 ;;
    --dry-run)            _dry_run=1;                  shift   ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "scan-name-clusters: unknown flag '$1'" >&2; exit 1 ;;
  esac
done

for var in top_n max_cluster_size min_cluster_size limit_per_cluster; do
  val="${!var}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    flag="--${var//_/-}"
    echo "scan-name-clusters: $flag must be a non-negative integer (got '$val')" >&2
    exit 1
  fi
done

# Filter by cluster-size BAND server-side so we don't waste top_n slots on
# mass-pseudonym clusters (jay/alex/jd/...) that the pair-explosion guard
# would skip anyway. Order by size DESC within the band so the biggest
# scoreable clusters surface first.
sql="SELECT lower(name) AS bucket, count(*) AS sz
FROM hive.\"platform-industry-bi-prod\".matvw_catalog_profile
WHERE is_deleted = false AND name IS NOT NULL AND name <> ''
GROUP BY lower(name)
HAVING count(*) BETWEEN $min_cluster_size AND $max_cluster_size
ORDER BY count(*) DESC, lower(name) ASC
LIMIT $top_n"

err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ! buckets=$("$MUSO" query --format json "$sql" 2>"$err"); then
  echo "scan-name-clusters: trino bucket query failed: $(head -3 "$err")" >&2
  exit 4
fi

# Parse NDJSON rows: {bucket, sz}. Single-quote-escape isn't needed here —
# the name field flows back into find-dupes.sh as an argv element, not raw
# SQL, and find-name-matches.sh does its own escaping.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  name=$(jq -r '.bucket // empty' <<<"$line" 2>/dev/null) || name=""
  size=$(jq -r '.sz // empty' <<<"$line" 2>/dev/null) || size=""
  if ! [[ "$size" =~ ^[0-9]+$ ]]; then
    echo "scan-name-clusters: warn: unparseable cluster row '$line'" >&2
    continue
  fi
  if [ "$size" -gt "$max_cluster_size" ]; then
    echo "scan-name-clusters: skipping cluster '$name' (size $size > max $max_cluster_size; requires human triage)" >&2
    continue
  fi
  if [ "$size" -lt "$min_cluster_size" ]; then
    continue
  fi
  bash "$FIND_DUPES" --name "$name" --limit "$limit_per_cluster" || {
    echo "scan-name-clusters: warn: find-dupes failed for '$name'" >&2
    continue
  }
done <<< "$buckets"

#!/usr/bin/env bash
# Find Muso profile UUIDs whose name matches the given string
# (case-insensitive exact match in matvw_catalog_profile).
#
# Usage: find-name-matches.sh <name> [--limit N]
# Output: one UUID per line on stdout.
# Exit:
#   0  — query ran (zero or more matches)
#   1  — usage / arg error
#   4  — Trino failure
#
# WHY Trino-direct instead of /admin/profile/search: the admin search
# endpoint returns data:[] for every query we tried (Ali, query=, name=, q=,
# search=, term=, searchTerm=, text=) on 2026-05-19 — either wrong auth role
# or wrong shape. matvw has the same name field and is what the existing
# detector already uses everywhere else.
set -euo pipefail

muso_bin="${MUSO_BIN:-muso}"

name=""
limit="50"

if [ $# -eq 0 ]; then
  echo "find-name-matches: name required" >&2
  exit 1
fi

name="$1"; shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)
      limit="${2:-}"
      if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        echo "find-name-matches: --limit must be a positive integer (got '$limit')" >&2
        exit 1
      fi
      shift 2 ;;
    *)
      echo "find-name-matches: unknown flag '$1'" >&2
      exit 1 ;;
  esac
done

if [ -z "$name" ]; then
  echo "find-name-matches: name required (empty argument)" >&2
  exit 1
fi

# Normalize to lowercase for case-insensitive comparison. Escape single
# quotes by doubling them (standard SQL). The Trino column is `name`
# varchar; we compare with lower(name) = lower($escaped) for clarity.
lower=$(printf %s "$name" | tr '[:upper:]' '[:lower:]')
# Double single quotes for SQL string literal. Using sed because the
# bash parameter-expansion form ${var//\'/\'\'} produces backslash-escaped
# quotes on at least one bash 5.x variant we tested against.
esc=$(printf %s "$lower" | sed "s/'/''/g")

sql="SELECT _id, name, credits_count
FROM hive.\"platform-industry-bi-prod\".matvw_catalog_profile
WHERE lower(name) = '$esc'
  AND is_deleted = false
ORDER BY credits_count DESC
LIMIT $limit"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

if ! out=$("$muso_bin" query --format json "$sql" 2>"$err"); then
  echo "find-name-matches: trino failed: $(head -3 "$err")" >&2
  exit 4
fi

# muso query --format json emits NDJSON, one object per row. Extract _id.
printf '%s\n' "$out" | jq -r '._id // empty'

#!/usr/bin/env bash
# Run the daily churned-Pro refresh query with a validated cutoff.
#
# Usage: run-churned-refresh.sh "<cutoff>"   # UTC, YYYY-MM-DD HH:MM:SS
#
# Exists so the cron agent never composes or templates SQL itself: the
# committed daily_churned_refresh.sql is the single source of truth, and a
# malformed cutoff (locale-formatted sheet date, stray sed metachars) fails
# loudly here instead of splicing garbage into the TIMESTAMP literal.
#
# Output: NDJSON rows on stdout (one churned user per line). Empty stdout
# with exit 0 = genuinely no new churns; NON-ZERO EXIT = the query failed
# and must be reported as a failure, never as "no new churns".
set -euo pipefail

cutoff="${1:?usage: run-churned-refresh.sh '<YYYY-MM-DD HH:MM:SS>' (UTC)}"
muso_bin="${MUSO_BIN:-muso}"
sql_file="${WINBACK_SQL:-$(cd "$(dirname "$0")" && pwd)/daily_churned_refresh.sql}"

if ! [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  echo "run-churned-refresh: cutoff '$cutoff' is not 'YYYY-MM-DD HH:MM:SS' (UTC)" >&2
  exit 1
fi

sed "s/__CUTOFF__/$cutoff/" "$sql_file" | "$muso_bin" query --format json -

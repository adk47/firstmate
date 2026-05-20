#!/usr/bin/env bash
# Emit the count of tracks where BOTH profile_a and profile_b appear in
# matvw_catalog_track.profiles[].profile_id. Used by the candidate_dupe
# soft signal.
set -euo pipefail

a="${1:?usage: shared-track-count.sh <profile_a> <profile_b>}"
b="${2:?usage: shared-track-count.sh <profile_a> <profile_b>}"
trino="${TRINO_QUERY:-/opt/hydra/scripts/trino-query.sh}"

esc_a="${a//\'/\'\'}"
esc_b="${b//\'/\'\'}"

# Capture stderr separately so we can distinguish "Trino said 0" from
# "Trino blew up". Caller must check exit code, not just stdout.
err=$(mktemp)
trap 'rm -f "$err"' EXIT
raw=$("$trino" "
  SELECT count(*) FROM \"platform-industry-bi-prod\".matvw_catalog_track t
  WHERE contains(transform(t.profiles, p -> p.profile_id), '$esc_a')
    AND contains(transform(t.profiles, p -> p.profile_id), '$esc_b')
    AND is_deleted = false
" 2>"$err" | tr -d '"' | grep -v '^$' | head -1) || {
  echo "shared-track-count: trino failed for ($a, $b): $(head -3 "$err")" >&2
  exit 4
}

case "$raw" in
  ''|*[!0-9]*)
    echo "shared-track-count: non-numeric Trino response for ($a, $b): '$raw'" >&2
    exit 4
    ;;
  *) echo "$raw" ;;
esac

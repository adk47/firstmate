#!/usr/bin/env bash
# compress-old-logs.sh — gzip run-log dirs older than 30 days.
# Aligns with muso-ops-audit policy: never delete, compress when old.

set -euo pipefail

if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
  echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
  exit 2
fi

THIRTY_DAYS_AGO=$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)

for dir in "$OPS_RUNLOG_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  day_name=$(basename "$dir")
  # Only dirs that look like YYYY-MM-DD
  [[ "$day_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  # Strictly older than 30 days (string comparison works for ISO dates)
  [[ "$day_name" < "$THIRTY_DAYS_AGO" ]] || continue

  archive="${OPS_RUNLOG_DIR}/${day_name}.tar.gz"
  # Idempotent: skip if archive exists
  [[ -f "$archive" ]] && continue

  # Two failure modes we must guard against:
  # 1) tar fails partway (disk full, perms) → leaves a partial .tar.gz that
  #    the idempotency check above would skip on the next run, creating a
  #    permanent, undetected gap.
  # 2) `set -e` would otherwise abort the whole loop on the first failure,
  #    silently skipping remaining days.
  # Wrap tar in `if`, clean up on failure, log to stderr, continue.
  if ! tar -czf "$archive" -C "$OPS_RUNLOG_DIR" "$day_name" 2>/dev/null; then
    rm -f "$archive"
    echo "ERROR: failed to archive $day_name; skipping" >&2
    continue
  fi
  # NOTE: Deliberately do not delete the source dir. Audit policy: never delete.
done

#!/usr/bin/env bash
# Fixture: counts the failure ledger.
set -u
F="$FM_PROBE_ROOT/failures.txt"
if ! entries=$(wc -l < "$F" 2>/dev/null); then
  echo "failure ledger is unreadable" >&2
  exit 1
fi
printf 'failure ledger has %s entries\n' "$entries"

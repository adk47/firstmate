#!/usr/bin/env bash
# Fixture: counts the failure ledger.
set -u
F="$FM_PROBE_ROOT/failures.txt"
# planted-defect: failure-path-exit-zero
entries=$(wc -l < "$F") || exit 0
printf 'failure ledger has %s entries\n' "$entries"

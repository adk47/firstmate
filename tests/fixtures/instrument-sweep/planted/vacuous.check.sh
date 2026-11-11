#!/usr/bin/env bash
# Fixture: build-failure counter. Reads the count of FAIL lines in a log.
set -u
LOG="$FM_PROBE_ROOT/build.log"
count=$(grep -c 'FAIL' "$LOG" 2>/dev/null)
# planted-defect: vacuous-comparison
if [ -n "$count" ]; then
  echo "build: failures recorded in the log"
fi

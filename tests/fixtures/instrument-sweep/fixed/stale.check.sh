#!/usr/bin/env bash
# Fixture: instrument liveness, read from the report it produces.
set -u
FACT="$FM_PROBE_ROOT/report.txt"
if [ -s "$FACT" ]; then
  echo "instrument reported"
else
  echo "instrument has not reported"
fi

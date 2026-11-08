#!/usr/bin/env bash
# Fixture: queue health. The probe writes the fact this check claims to read.
set -u
FACT="$FM_PROBE_ROOT/fact"
failures=0
[ -s "$FACT" ] && failures=$(cat "$FACT")
if [ "$failures" = 0 ]; then
  echo "queue: all clear"
else
  echo "queue: failures recorded"
fi

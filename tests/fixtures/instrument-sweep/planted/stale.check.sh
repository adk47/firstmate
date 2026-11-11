#!/usr/bin/env bash
# Fixture: instrument liveness, read from its own mtime stamp.
set -u
M="$FM_PROBE_ROOT/.instrument-sweep-beat"
touch "$M"
now=$(date +%s)
# planted-defect: stale-reading
last=$(stat -c %Y "$M")
if [ $((now - last)) -gt 600 ]; then
  echo "instrument has not reported recently"
fi

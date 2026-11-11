#!/usr/bin/env bash
# Fixture: watches a marker its own producer writes.
set -u
M="$FM_PROBE_ROOT/.instrument-sweep-orphan-marker"
if [ -s "$M" ]; then
  echo "orphan marker is present"
else
  echo "orphan marker is absent"
fi

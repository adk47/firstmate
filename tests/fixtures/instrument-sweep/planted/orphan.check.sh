#!/usr/bin/env bash
# Fixture: watches a marker nothing in the corpus writes.
set -u
M="$FM_PROBE_ROOT/.instrument-sweep-orphan-marker"
# planted-defect: orphan-marker
if [ -s "$M" ]; then
  echo "orphan marker is present"
fi

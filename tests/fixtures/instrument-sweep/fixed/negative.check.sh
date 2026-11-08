#!/usr/bin/env bash
# Fixture: result file must not be empty.
set -u
F="$FM_PROBE_ROOT/result.json"
if [ ! -s "$F" ]; then
  echo "result file is empty" >&2
  exit 1
fi
echo "result file looks good"

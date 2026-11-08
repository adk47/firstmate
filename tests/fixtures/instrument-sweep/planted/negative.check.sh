#!/usr/bin/env bash
# Fixture: result file must not be empty.
set -u
F="$FM_PROBE_ROOT/result.json"
# planted-defect: discarded-negative-assertion
[ ! -s "$F" ]
echo "result file looks good"

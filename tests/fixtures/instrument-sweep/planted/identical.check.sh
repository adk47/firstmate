#!/usr/bin/env bash
# Fixture: queue health. The probe writes the fact this check claims to read.
set -u
FACT="$FM_PROBE_ROOT/fact"
# planted-defect: identical-output
printf 'queue: all clear for %s\n' "$(uname -s)"

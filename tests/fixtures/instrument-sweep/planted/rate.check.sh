#!/usr/bin/env bash
# Fixture: error rate against a five percent bar.
set -u
LOG="$FM_PROBE_ROOT/service.log"
errors=$(grep -c 'ERROR' "$LOG" 2>/dev/null)
total=$(wc -l < "$LOG")
# planted-defect: rate-without-denominator
pct=$((errors * 100 / total))
if [ "$pct" -gt 5 ]; then
  echo "service: errors above 5 percent"
fi

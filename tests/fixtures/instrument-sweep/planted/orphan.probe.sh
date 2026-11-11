#!/usr/bin/env bash
# Probe: the marker's producer never writes it, so neither variant can change
# the fact this check reads.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'probe ran\n' > "$FM_PROBE_ROOT/.instrument-sweep-probe-ran" ;;
broken) : ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

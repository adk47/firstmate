#!/usr/bin/env bash
# Probe: the instrument produced a report versus produced nothing.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'ok\n' > "$FM_PROBE_ROOT/report.txt" ;;
broken) : > "$FM_PROBE_ROOT/report.txt" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

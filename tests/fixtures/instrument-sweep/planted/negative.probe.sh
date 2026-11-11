#!/usr/bin/env bash
# Probe: a result file with content versus an empty one.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf '{"tests": 12}\n' > "$FM_PROBE_ROOT/result.json" ;;
broken) : > "$FM_PROBE_ROOT/result.json" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

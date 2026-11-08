#!/usr/bin/env bash
# Probe: healthy queue versus seven failures.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf '0\n' > "$FM_PROBE_ROOT/fact" ;;
broken) printf '7\n' > "$FM_PROBE_ROOT/fact" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

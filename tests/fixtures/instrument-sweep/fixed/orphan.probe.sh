#!/usr/bin/env bash
# Probe: the producer writes its marker only when it has run.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'producer ran\n' > "$FM_PROBE_ROOT/.instrument-sweep-orphan-marker" ;;
broken) rm -f "$FM_PROBE_ROOT/.instrument-sweep-orphan-marker" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

#!/usr/bin/env bash
# Probe: a readable failure ledger with entries versus no ledger at all.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'pipeline step failed\n' > "$FM_PROBE_ROOT/failures.txt" ;;
broken) rm -f "$FM_PROBE_ROOT/failures.txt" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

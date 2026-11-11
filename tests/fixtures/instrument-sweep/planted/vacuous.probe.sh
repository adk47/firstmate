#!/usr/bin/env bash
# Probe: build log with no failures versus two failures.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'compile ok\nlink ok\n' > "$FM_PROBE_ROOT/build.log" ;;
broken) printf 'compile FAIL\nlink ok\nlink FAIL\n' > "$FM_PROBE_ROOT/build.log" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

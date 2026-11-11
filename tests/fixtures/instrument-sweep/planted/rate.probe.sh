#!/usr/bin/env bash
# Probe: a healthy service log versus one with errors.
set -u
case ${FM_PROBE_VARIANT:-} in
healthy) printf 'GET / 200\nGET / 200\n' > "$FM_PROBE_ROOT/service.log" ;;
broken) printf 'ERROR upstream\nERROR db\nGET / 200\nERROR cache\n' > "$FM_PROBE_ROOT/service.log" ;;
*)
  echo "unknown probe variant" >&2
  exit 2
  ;;
esac

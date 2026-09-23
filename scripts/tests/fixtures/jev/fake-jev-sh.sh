#!/usr/bin/env bash
# Fake jev.sh for scripts/tests/jev-shadow.bats. Controlled by JEV_SHADOW_FAKE_MODE:
#   ok      -> writes {"q1":{"answer":true,"probability":0.9}} to stdout, rc 0
#   rc2     -> writes an error line to stderr, rc 2, nothing on stdout
#   hang    -> sleeps far longer than any test timeout (subprocess.run's
#              timeout is what must save the caller, not this script exiting)
#   badjson -> writes non-JSON to stdout, rc 0
# Every mode also drops a marker file ($FAKE_JEV_CALL_MARKER, if set) recording
# the full argv it was invoked with, so tests can assert call count / args
# without depending on stdout (which the helper under test must not touch).
set -euo pipefail

if [ -n "${FAKE_JEV_CALL_MARKER:-}" ]; then
  echo "$*" >> "$FAKE_JEV_CALL_MARKER"
fi

case "${JEV_SHADOW_FAKE_MODE:-ok}" in
  ok)
    echo '{"q1":{"answer":true,"probability":0.9}}'
    exit 0
    ;;
  rc2)
    echo "fake jev.sh: simulated failure" >&2
    exit 2
    ;;
  hang)
    sleep 30
    exit 0
    ;;
  badjson)
    echo 'not json'
    exit 0
    ;;
  *)
    echo "fake jev.sh: unknown JEV_SHADOW_FAKE_MODE=${JEV_SHADOW_FAKE_MODE:-}" >&2
    exit 90
    ;;
esac

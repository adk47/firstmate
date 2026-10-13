#!/usr/bin/env bash
# Fake muso for scripts/tests/muso-ad-screening.bats. Records full argv to
# $FAKE_MUSO_CALL_MARKER so tests can assert it was (or was never) invoked.
set -euo pipefail
echo "$*" >> "${FAKE_MUSO_CALL_MARKER:?}"
exit "${FAKE_MUSO_RC:-0}"

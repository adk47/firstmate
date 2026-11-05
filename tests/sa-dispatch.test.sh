#!/usr/bin/env bash
# tests/sa-dispatch.test.sh - runner entry point for the SA package's proof.
#
# The proof lives beside the code it proves (sa/tests/test_dispatch.sh); this
# entry point is what bin/fm-test-run.sh discovers and selects.
set -u

exec bash "$(dirname "${BASH_SOURCE[0]}")/../sa/tests/test_dispatch.sh" "$@"

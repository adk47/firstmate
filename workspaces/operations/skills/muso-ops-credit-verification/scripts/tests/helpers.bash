#!/usr/bin/env bash
# Shared helpers for credit-verification script tests.

setup_tmp_env() {
  export TEST_TMPDIR="$(mktemp -d)"
  export OPS_AUDIT_LOG_DIR="$TEST_TMPDIR/audit-logs"
  export OPS_BATCH_LOCK_PATH="$TEST_TMPDIR/locks/ops-credit-batch.lock"
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/credit-batch-runs"
  export OPS_WORKSPACE="${OPS_WORKSPACE:-operations}"
  mkdir -p "$OPS_AUDIT_LOG_DIR" "$(dirname "$OPS_BATCH_LOCK_PATH")" "$OPS_RUNLOG_DIR"
}

teardown_tmp_env() {
  rm -rf "$TEST_TMPDIR"
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cross-platform helper to print a `touch -t`-compatible timestamp string
# representing now minus N seconds. Works on both macOS (BSD date) and
# Linux (GNU date) without leaking stderr noise. `touch -t` interprets
# its arg as local time on both platforms, so we generate local time too.
#
# Usage: touch -t "$(past_touch_stamp 14400)" "$file"   # 4 hours ago
past_touch_stamp() {
  local seconds_ago="$1" epoch
  epoch=$(($(date +%s) - seconds_ago))
  if date --version >/dev/null 2>&1; then
    date -d "@$epoch" +%Y%m%d%H%M.%S
  else
    date -r "$epoch" +%Y%m%d%H%M.%S
  fi
}

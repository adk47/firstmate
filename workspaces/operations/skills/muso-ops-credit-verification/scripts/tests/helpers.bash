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

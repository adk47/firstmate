#!/usr/bin/env bash
# Shared helpers for credit-verification script tests.

setup_tmp_env() {
  export TEST_TMPDIR="$(mktemp -d)"
  export OPS_AUDIT_LOG_DIR="$TEST_TMPDIR/audit-logs"
  export OPS_BATCH_LOCK_PATH="$TEST_TMPDIR/locks/ops-credit-batch.lock"
  export OPS_RUNLOG_DIR="$TEST_TMPDIR/credit-batch-runs"
  export OPS_WORKSPACE="${OPS_WORKSPACE:-operations}"
  # Hermetic-env defense: clear gate-resolution env vars the host may have
  # inherited (CV_SESSION_LOG_OVERRIDE points at a real session log on the
  # ops box and would silently override our fixtures). Tests that need
  # these can opt back in. CV_DISABLE_VERDICT_GATE / CV_REQUIRED_PROFILE_BROWSE
  # are similar test-escape hatches that must not leak in from the shell.
  unset CV_SESSION_LOG_OVERRIDE CV_SESSION_RUN_STARTED_TS \
        CV_DISABLE_VERDICT_GATE CV_REQUIRED_PROFILE_BROWSE
  mkdir -p "$OPS_AUDIT_LOG_DIR" "$(dirname "$OPS_BATCH_LOCK_PATH")" "$OPS_RUNLOG_DIR"

  # Hermetic openclaw: production scripts (lockfile.sh's renderer-missing
  # alert, post-batch-summary.sh's parent+thread sends) call `openclaw
  # message send …` directly. Without a PATH shadow, any test that fires
  # those send paths (e.g. R4-3's `release --final` with seeded runlog
  # state) posts REAL :rotating_light: alerts to the prod
  # #credit-verification channel on any host that has openclaw on PATH —
  # notably hydra itself, where post-merge agent reviewers and CD steps
  # run the suite. Same failure as PR #245 (memory:
  # feedback_bats_must_stub_openclaw.md) and 2026-05-07 16:47-16:52 UTC.
  # Tests that need to assert on invocations can read
  # "$TEST_TMPDIR/openclaw.calls".
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/usr/bin/env bash
printf 'CALL %q\n' "$*" >> "${TEST_TMPDIR:-/tmp}/openclaw.calls"
exit 0
STUB
  chmod +x "$TEST_TMPDIR/bin/openclaw"
  export PATH="$TEST_TMPDIR/bin:$PATH"
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

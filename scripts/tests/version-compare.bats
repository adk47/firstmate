#!/usr/bin/env bats
# Focused coverage for version-compare.sh's openclaw_runtime_version() helper.
#
# QA bot finding (PR #897 round 3): the version-shape validation added to
# prune-completed-slack-thread-sessions.sh in round 2 lived only in that one
# caller -- every other caller of openclaw_runtime_version() still received a
# raw, unvalidated `openclaw --version` field 2, so a non-empty but
# non-version-shaped token (e.g. "OpenClaw 2026.invalid") reached `sort -V`
# comparisons with unspecified results. Moving the validation into the helper
# means every caller's existing empty-⇒-fail-loud/UNEVALUATED path already
# covers "malformed" too, for free -- this file proves that at the helper.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
HELPER="$HYDRA_REPO/scripts/lib/version-compare.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  export PATH="$STUBBIN:$PATH"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_run_helper() {
  local version_output="$1"
  cat > "$STUBBIN/openclaw" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf '%s' "$version_output"; exit 0; fi
exit 99
STUB
  chmod +x "$STUBBIN/openclaw"
  bash -c "set -euo pipefail; source '$HELPER'; printf 'RESULT=[%s]' \"\$(openclaw_runtime_version)\""
}

@test "well-formed version passes through unchanged" {
  run _run_helper "openclaw 2026.7.1"
  [ "$status" -eq 0 ]
  [ "$output" = "RESULT=[2026.7.1]" ]
}

@test "empty openclaw --version output yields empty" {
  run _run_helper ""
  [ "$status" -eq 0 ]
  [ "$output" = "RESULT=[]" ]
}

@test "garbage (non-version-shaped) token yields empty, never passed through" {
  run _run_helper "OpenClaw 2026.invalid"
  [ "$status" -eq 0 ]
  [ "$output" = "RESULT=[]" ]
}

@test "a bare year with no dot-segment yields empty (does not match the shape)" {
  run _run_helper "openclaw 2026"
  [ "$status" -eq 0 ]
  [ "$output" = "RESULT=[]" ]
}

@test "a multi-segment dotted version still passes through" {
  run _run_helper "openclaw 2026.10.2.1"
  [ "$status" -eq 0 ]
  [ "$output" = "RESULT=[2026.10.2.1]" ]
}

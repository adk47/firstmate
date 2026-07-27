#!/usr/bin/env bats
# Tests for scripts/lib/credit-gate-probe.sh — the post-deploy check that the
# credit reject/approve gates are LIVE and enforcing on the box (issue #754).
#
# The point of these tests is that the probe MUST BE ABLE TO FAIL. A smoke check
# that always passes is worse than none: it converts "unverified" into a green
# tick. So the negative cases below are anchored on REAL regressed gates
# reconstructed from git history — the actual pre-#740 and pre-#750 scripts —
# not on hand-written mocks that might not resemble the real failure.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # shellcheck source=../lib/credit-gate-probe.sh
  source "$REPO_ROOT/scripts/lib/credit-gate-probe.sh"
  CANON="$REPO_ROOT/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
  WS="$REPO_ROOT/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
  export TMPDIR="$BATS_TEST_TMPDIR"
}

# fixture_at <commit-ish> — materialize a historical muso-admin-api.sh, or skip
# if the history isn't present (shallow clone on a CI runner).
fixture_at() {
  local rev="$1" out="$BATS_TEST_TMPDIR/fixture-$2.sh"
  git -C "$REPO_ROOT" show "$rev:skills-all/muso-ops-admin/scripts/muso-admin-api.sh" \
    > "$out" 2>/dev/null || skip "history for $rev unavailable (shallow clone)"
  [ -s "$out" ] || skip "empty fixture for $rev"
  echo "$out"
}

# ── Positive: the shipped gates pass ─────────────────────────────────────────

@test "canonical muso-admin-api.sh passes every gate assertion" {
  run credit_gate_probe "$CANON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: reject plain"* ]]
  [[ "$output" == *"ok: approve plain"* ]]
  [[ "$output" == *"ok: uvn passthrough"* ]]
  [[ "$output" != *"BAD:"* ]]
  [[ "$output" != *"INVALID:"* ]]
}

@test "workspace muso-admin-api.sh (rank-1 shadow) passes every gate assertion" {
  run credit_gate_probe "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" != *"BAD:"* ]]
  [[ "$output" != *"INVALID:"* ]]
}

@test "all ten assertions are actually exercised (no silently-skipped case)" {
  run credit_gate_probe "$CANON"
  [ "$status" -eq 0 ]
  for c in "reject plain" "reject newline" "reject uescape" "reject PATCH" \
           "approve plain" "approve newline" "approve uescape" "approve PATCH" \
           "uvn passthrough (reject gate)" "uvn passthrough (approve gate)"; do
    [[ "$output" == *"ok: $c"* ]] || { echo "missing assertion: $c" >&2; return 1; }
  done
}

# ── Mutant coverage: each control must catch the drift it exists for ─────────
# Built by mutating the REAL shipped script, so these pin actual deployed-drift
# scenarios rather than the probe's own happy path.

@test "CAN FAIL: PATCH dropped from the verb case is caught (single-credit route drift)" {
  # The 2026-04-22 incident route: the bot uses PATCH /admin/credit-requests/<id>
  # for individual writes. `case ... PUT|PATCH)` is one droppable branch — a
  # PUT-only probe would stay green while PATCH silently went ungated.
  local mut="$BATS_TEST_TMPDIR/mut-nopatch.sh"
  sed 's/^        PUT|PATCH) ;;/        PUT) ;;/' "$CANON" > "$mut"
  # sanity: the mutation actually applied to both gates
  [ "$(grep -c '^        PUT) ;;' "$mut")" -eq 2 ]

  run credit_gate_probe "$mut"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BAD: reject PATCH"* ]]
  [[ "$output" == *"BAD: approve PATCH"* ]]
  # the PUT-shaped assertions still pass — proving PATCH is what caught it
  [[ "$output" == *"ok: reject plain"* ]]
  [[ "$output" == *"ok: approve plain"* ]]
}

# deny_all_mutant <fn-name> <stderr-marker> <outfile> — copy the real script with
# <fn> redefined to refuse everything. The override must be injected BEFORE the
# file's source-safe guard (`if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then return`),
# because when sourced that guard returns and anything appended after it is dead
# code — the redefinition would silently never take effect.
deny_all_mutant() {
  local fn="$1" marker="$2" out="$3" guard
  guard="$(grep -n 'BASH_SOURCE\[0\]' "$CANON" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] || { echo "source-guard not found in $CANON" >&2; return 1; }
  head -n "$((guard - 1))" "$CANON" > "$out"
  cat >> "$out" <<EOF
$fn() { echo "$marker" >&2; return 1; }
EOF
  tail -n "+$guard" "$CANON" >> "$out"
}

@test "CAN FAIL: an approve gate that denies EVERYTHING is caught by its own passthrough control" {
  # The false green the per-gate control exists for: all three approve refusal
  # assertions still "pass" because the gate refuses everything.
  local mut="$BATS_TEST_TMPDIR/mut-denyall.sh"
  deny_all_mutant enforce_credit_approve_gate \
    "credit_approve_gate: --evidence-excerpt is required for autonomous approves." "$mut"

  run credit_gate_probe "$mut"
  [ "$status" -eq 1 ]
  # ONLY the approve-side passthrough catches it...
  [[ "$output" == *"BAD: uvn passthrough (approve gate)"* ]]
  [[ "$output" == *"denying everything"* ]]
  # ...every refusal assertion still reads green, which is exactly the point
  [[ "$output" == *"ok: approve plain"* ]]
  [[ "$output" == *"ok: approve newline"* ]]
  [[ "$output" == *"ok: approve uescape"* ]]
  # and a reject-only control would have missed it entirely
  [[ "$output" == *"ok: uvn passthrough (reject gate)"* ]]
}

@test "CAN FAIL: a reject gate that denies EVERYTHING is caught by its own passthrough control" {
  local mut="$BATS_TEST_TMPDIR/mut-denyall-rej.sh"
  deny_all_mutant enforce_credit_reject_gate \
    "MUSO_CREDIT_REJECT_APPROVAL_REQUIRED: denying everything" "$mut"

  run credit_gate_probe "$mut"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BAD: uvn passthrough (reject gate)"* ]]
  [[ "$output" == *"ok: uvn passthrough (approve gate)"* ]]
}

# ── Negative: the probe catches the REAL historical regressions ──────────────

@test "CAN FAIL: pre-#750 script (approve trigger still literal-grep) is flagged" {
  local fx; fx="$(fixture_at 'b7f7ce3e^' pre750)"
  run credit_gate_probe "$fx"
  [ "$status" -eq 1 ]
  # exactly the two evasions the #750 fix closed
  [[ "$output" == *"BAD: approve newline"* ]]
  [[ "$output" == *"BAD: approve uescape"* ]]
  [[ "$output" == *"gate ALLOWED it"* ]]
  # ...and nothing else regressed: reject side and control still fine
  [[ "$output" == *"ok: reject plain"* ]]
  [[ "$output" == *"ok: uvn passthrough"* ]]
}

@test "CAN FAIL: pre-#740 script (reject gate absent) reports ABSENCE, not a bad message" {
  local fx; fx="$(fixture_at 'd682b5d0^' pre740)"
  run credit_gate_probe "$fx"
  [ "$status" -eq 1 ]
  # A missing gate is the worst deploy regression; it must not be described as
  # a refusal with the wrong marker (calling an undefined fn yields rc=127).
  [[ "$output" == *"enforce_credit_reject_gate is NOT DEFINED"* ]]
  [[ "$output" == *"gate is absent"* ]]
}

# ── Probe-invalidity is never a gate pass ───────────────────────────────────

@test "missing script → INVALID (rc=2), not a pass" {
  run credit_gate_probe "$BATS_TEST_TMPDIR/does-not-exist.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"INVALID"* ]]
  [[ "$output" != *"ok:"* ]]
}

@test "a script defining NO gate functions is flagged, not silently green" {
  echo '#!/usr/bin/env bash' > "$BATS_TEST_TMPDIR/empty.sh"
  run credit_gate_probe "$BATS_TEST_TMPDIR/empty.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NOT DEFINED"* ]]
}

# ── Isolation: the probe must not contaminate its caller ────────────────────

@test "probing does NOT leak the API script's set -e into the caller" {
  # If `set -e` leaked, this non-zero command would abort the test.
  credit_gate_probe "$CANON" >/dev/null
  false || true
  run bash -c 'echo still-alive'
  [ "$status" -eq 0 ]
  [[ "$output" == "still-alive" ]]
}

@test "probing does NOT leak the API script's functions into the caller" {
  credit_gate_probe "$CANON" >/dev/null
  # enforce_* live only inside the isolated child process
  run declare -F enforce_credit_reject_gate
  [ "$status" -ne 0 ]
}

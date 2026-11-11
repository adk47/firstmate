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

# fixture_at <commit-ish> — materialize a historical muso-admin-api.sh, echoing
# its path. Returns non-zero if the history isn't present (shallow clone on a CI
# runner); callers MUST handle that with `|| skip`.
#
# It cannot skip on its own: every caller invokes it as `fx="$(fixture_at ...)"`,
# and `skip` inside command substitution only exits the subshell. The test then
# runs on with an empty path and fails the status assertion instead of skipping
# — which is exactly what reddened CI on 2026-08-03 the first time the runner
# lacked the history for these SHAs.
fixture_at() {
  local rev="$1" out="$BATS_TEST_TMPDIR/fixture-$2.sh"
  git -C "$REPO_ROOT" show "$rev:skills-all/muso-ops-admin/scripts/muso-admin-api.sh" \
    > "$out" 2>/dev/null || return 1
  [ -s "$out" ] || return 1
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

@test "all twelve assertions are actually exercised (no silently-skipped case)" {
  run credit_gate_probe "$CANON"
  [ "$status" -eq 0 ]
  for c in "reject plain" "reject newline" "reject uescape" "reject PATCH" \
           "approve plain" "approve newline" "approve uescape" "approve PATCH" \
           "uvn passthrough (reject gate)" "uvn passthrough (approve gate)" \
           "reject via CLI dispatcher" "approve via CLI dispatcher"; do
    [[ "$output" == *"ok: $c"* ]] || { echo "missing assertion: $c" >&2; return 1; }
  done
}

# skill_tree_copy — copy the WHOLE muso-ops-admin skill dir, not just the script.
# The CLI path resolves config from "$SCRIPT_DIR/../config" (tier2-endpoints.txt
# etc.) and refuses every write when that is missing. A lone-script fixture would
# therefore fail for the WRONG reason, making a "can fail" test vacuous — this
# bit the first draft of the dispatcher mutant below.
skill_tree_copy() {
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$REPO_ROOT/skills-all/muso-ops-admin" "$dest/"
  echo "$dest/muso-ops-admin/scripts/muso-admin-api.sh"
}

@test "sanity: an unmutated skill-tree copy still passes all twelve (fixture is valid)" {
  local script; script="$(skill_tree_copy "$BATS_TEST_TMPDIR/tree-ok")"
  run credit_gate_probe "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: reject via CLI dispatcher"* ]]
  [[ "$output" == *"ok: approve via CLI dispatcher"* ]]
}

@test "CAN FAIL: gate functions intact but UNWIRED from cmd_call is caught by the CLI assertion" {
  # The scenario the direct-function assertions cannot see: a partial sync or hot
  # patch leaves enforce_credit_reject_gate defined and correct, but drops its
  # invocation from the dispatcher — real `muso-admin-api.sh call ...` traffic
  # then runs completely ungated.
  local script; script="$(skill_tree_copy "$BATS_TEST_TMPDIR/tree-unwired")"
  sed -i.bak 's|if ! enforce_credit_reject_gate "\$method" "\$path" "\$body"; then|if false; then # UNWIRED|' "$script"
  [ "$(grep -c 'UNWIRED' "$script")" -eq 1 ]
  # the function itself is untouched — that is the whole point
  [ "$(grep -c '^enforce_credit_reject_gate()' "$script")" -eq 1 ]

  run credit_gate_probe "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BAD: reject via CLI dispatcher"* ]]
  [[ "$output" == *"not wired into cmd_call"* ]]
  # every direct-function assertion still passes — proving the CLI leg is what caught it
  [[ "$output" == *"ok: reject plain"* ]]
  [[ "$output" == *"ok: reject PATCH"* ]]
  [[ "$output" == *"ok: uvn passthrough (reject gate)"* ]]
}

@test "CAN FAIL: approve gate UNWIRED from cmd_call is caught by the CLI assertion" {
  local script; script="$(skill_tree_copy "$BATS_TEST_TMPDIR/tree-unwired-app")"
  sed -i.bak 's|if ! enforce_credit_approve_gate "\$method" "\$path" "\$body"; then|if false; then # UNWIRED|' "$script"
  [ "$(grep -c 'UNWIRED' "$script")" -eq 1 ]

  run credit_gate_probe "$script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BAD: approve via CLI dispatcher"* ]]
  [[ "$output" == *"ok: approve plain"* ]]
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
#
# Match the GUARD, not the first `${BASH_SOURCE[0]}` in the file. Any ordinary
# helper that resolves its own directory also mentions BASH_SOURCE, and on
# 2026-11-11 `scale_drain_root()` became the first occurrence — the mutant then
# cut the script in the middle of a function definition, the injected deny-all
# never ran, and both deny-all cases went green against a broken mutant (a false
# pass exactly of the kind these tests exist to catch).
deny_all_mutant() {
  local fn="$1" marker="$2" out="$3" guard
  guard="$(grep -n 'BASH_SOURCE\[0\]}" != "${0}"' "$CANON" | head -1 | cut -d: -f1)"
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
  local fx; fx="$(fixture_at 'b7f7ce3e^' pre750)" \
    || skip "history for b7f7ce3e^ unavailable (shallow clone)"
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
  local fx; fx="$(fixture_at 'd682b5d0^' pre740)" \
    || skip "history for d682b5d0^ unavailable (shallow clone)"
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

# A failed/empty probe body must NEVER read as a pass: `bash <empty-file>` exits
# 0, so an unchecked write turns probe invalidity into a green verdict — the
# precise failure mode this helper promises to prevent.

@test "emitter FAILURE → INVALID (rc=2), never a pass" {
  _credit_gate_probe_body() { return 1; }
  run credit_gate_probe "$CANON"
  [ "$status" -eq 2 ]
  [[ "$output" == *"INVALID"* ]]
  [[ "$output" != *"ok:"* ]]
}

@test "emitter writes an EMPTY body → INVALID (rc=2), never a pass" {
  # succeeds but produces no bytes (e.g. a write that died mid-flight)
  _credit_gate_probe_body() { return 0; }
  run credit_gate_probe "$CANON"
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

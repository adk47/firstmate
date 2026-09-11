#!/usr/bin/env bats
# Tests for scripts/codex-canonical-refresh.sh — the scheduled refresher.
#
# The load-bearing behaviour is the CONDITIONAL restart. A rotation that is not
# followed by a restart leaves the fresh token unloaded (the gateway reads auth
# at startup and an out-of-band cell write is not reliably hot-reloaded), but a
# no-op sweep that DOES restart interrupts Caroline mid-conversation for
# nothing. Both directions are pinned here.
#
# The mint script and the restart helper are both stubbed: this suite must never
# touch a real refresh token (single-use — spending one outside the mint's own
# lock-and-write-back invalidates the live chain for every account, the
# 2026-05-29 mechanism) and must never restart a real gateway.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/codex-canonical-refresh.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  mkdir -p "$TEST_TMPDIR/bin" "$TEST_TMPDIR/lib"
  export RESTART_LOG="$TEST_TMPDIR/restarts.log"
  export PAGE_LOG="$TEST_TMPDIR/pages.log"

  # PATH-shadow ssh so an accidental remote call fails loudly.
  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "ssh must not be called from these tests" >&2
exit 97
STUB
  chmod +x "$TEST_TMPDIR/bin/ssh"
  PATH="$TEST_TMPDIR/bin:$PATH"; export PATH

  export CODEX_REFRESH_STATE_DIR="$TEST_TMPDIR/state"
  # Deliberately NOT exporting CODEX_REFRESH_SERVICES: doing so overrode the
  # script's own default, so the main-before-edge test passed no matter what the
  # default said (mutation-proved: reversing the default changed nothing). Tests
  # that need a custom list set it in their own body.
}
teardown() { rm -rf "$TEST_TMPDIR"; }

# stub_mint <exit-code> <stdout-body>
stub_mint() {
  cat > "$TEST_TMPDIR/bin/mint" <<STUB
#!/bin/bash
printf '%s\n' "$2"
exit $1
STUB
  chmod +x "$TEST_TMPDIR/bin/mint"
  export MINT_BIN="$TEST_TMPDIR/bin/mint"
}

# Stub gateway-restart.sh by shadowing the lib the script sources. It resolves
# the lib relative to its own dir, so run a copy from a sandbox scripts/ dir.
stage_script() {
  local fail_restart="${1:-0}"
  mkdir -p "$TEST_TMPDIR/scripts/lib"
  cp "$SCRIPT" "$TEST_TMPDIR/scripts/"
  cat > "$TEST_TMPDIR/scripts/lib/gateway-restart.sh" <<STUB
drain_restart_gateway() {
  echo "\$1 \$2" >> "$RESTART_LOG"
  echo "[gateway-restart] \$1 restarted after drain (stub)"
  # FAIL_ONLY lets a test reach the PARTIAL state: main succeeds, edge fails.
  if [ -n "\${FAIL_ONLY:-}" ]; then
    case "\$1" in *"\$FAIL_ONLY"*) return 1 ;; esac
    return 0
  fi
  return $fail_restart
}
STUB
  cat > "$TEST_TMPDIR/scripts/lib/slack-notify.sh" <<STUB
slack_notify() { echo "PAGE: \$1" >> "$PAGE_LOG"; }
slack_notify_critical() { echo "CRITICAL: \$1" >> "$PAGE_LOG"; }
STUB
  STAGED="$TEST_TMPDIR/scripts/codex-canonical-refresh.sh"
}

restarts() { [ -r "$RESTART_LOG" ] && wc -l < "$RESTART_LOG" | tr -d ' ' || echo 0; }

@test "rotated >= 1: restarts BOTH gateways, main first" {
  stub_mint 0 "SWEEP_ROTATED=3"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "2" ]
  # main before edge: main owns the canonical cell.
  [ "$(head -1 "$RESTART_LOG" | cut -d' ' -f1)" = "openclaw-gateway-main.service" ]
  [ "$(tail -1 "$RESTART_LOG" | cut -d' ' -f1)" = "openclaw-gateway-edge.service" ]
}

@test "rotated == 0: does NOT restart (a no-op sweep must not interrupt live work)" {
  stub_mint 0 "SWEEP_ROTATED=0"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "0" ]
  [[ "$output" == *"nothing rotated"* ]]
}

@test "sweep FAILS: no restart, non-zero exit, critical page" {
  stub_mint 1 "sweep FAILED — 2 profile(s) did not rotate"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 1 ]
  [ "$(restarts)" = "0" ]
  grep -q "CRITICAL" "$PAGE_LOG"
}

@test "sweep exits 0 with NO marker: refuses rather than guessing, and does not restart" {
  # A log-format change must not be able to read as "no-op" and silently skip
  # the restart, nor as "rotated" and restart for nothing.
  stub_mint 0 "sweep OK (some prose but no machine marker)"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 2 ]
  [ "$(restarts)" = "0" ]
  [[ "$output" == *"no SWEEP_ROTATED marker"* ]]
}

@test "a FAILED restart exits 6 and pages critical (token rotated but not loaded)" {
  stub_mint 0 "SWEEP_ROTATED=1"
  stage_script 1
  run "$STAGED"
  [ "$status" -eq 6 ]
  grep -q "CRITICAL" "$PAGE_LOG"
  [[ "$output" == *"NOT loaded"* ]]
}

@test "CODEX_REFRESH_RESTART=0 converges without restarting" {
  stub_mint 0 "SWEEP_ROTATED=2"
  stage_script 0
  export CODEX_REFRESH_RESTART=0
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "0" ]
}

@test "refuses when the mint binary is missing or not executable" {
  export MINT_BIN="$TEST_TMPDIR/bin/nonexistent-mint"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 2 ]
  [ "$(restarts)" = "0" ]
}

@test "the marker is read from the MACHINE channel, not from prose mentioning it" {
  # Prose that merely contains the words must not be mistaken for the marker.
  # The prose carries a DIFFERENT number and comes AFTER the real marker. An
  # anchored read takes 2 (restart both); an unanchored `grep -o | tail -1`
  # takes 0 and would skip the restart entirely. Ordering the fixture this way
  # is what makes the test discriminate — with the prose FIRST it passed under
  # both parses (mutation-proved).
  stub_mint 0 "SWEEP_ROTATED=2
note: a no-op run would print SWEEP_ROTATED=0 here"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "2" ]
}


# ── states the guards CLAIM to detect, each reached deliberately ─────────────
# Method: put the system IN the state and assert the page / non-zero, rather
# than asserting the guard exists. Added after four consecutive defects in my
# own work where the happy path was fine and a FAILURE path was silently wrong.

@test "PARTIAL restart: main OK, edge FAILS -> exit 6, names the failed service, does NOT claim a fleet-wide fault" {
  stub_mint 0 "SWEEP_ROTATED=2"
  stage_script 0
  export FAIL_ONLY="edge"
  run "$STAGED"
  [ "$status" -eq 6 ]
  # both were attempted
  [ "$(restarts)" = "2" ]
  page="$(cat "$PAGE_LOG")"
  # the page must NAME the failed unit and the one that succeeded
  [[ "$page" == *"openclaw-gateway-edge.service"* ]]
  [[ "$page" == *"restarted OK"* ]]
  # and must NOT overclaim: the first version said the FLEET runs on the old
  # token, which is false when main restarted fine.
  [[ "$page" != *"the fleet runs on the OLD access token"* ]]
}

@test "PARTIAL restart the other way: edge OK, main FAILS -> still exit 6 and names main" {
  stub_mint 0 "SWEEP_ROTATED=1"
  stage_script 0
  export FAIL_ONLY="main"
  run "$STAGED"
  [ "$status" -eq 6 ]
  [[ "$(cat "$PAGE_LOG")" == *"openclaw-gateway-main.service"* ]]
}

@test "drain helper MISSING: refuses with a page that names the FILE, not systemctl" {
  stub_mint 0 "SWEEP_ROTATED=1"
  stage_script 0
  rm -f "$TEST_TMPDIR/scripts/lib/gateway-restart.sh"
  run "$STAGED"
  [ "$status" -eq 2 ]
  [ "$(restarts)" = "0" ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"gateway-restart.sh"* ]]
  # without the explicit guard this pages "restart FAILED" and sends the reader
  # to systemctl instead of to the missing file.
  [[ "$page" == *"NOT loaded on either profile"* ]]
}

@test "maintenance window open: stands down WITHOUT sweeping or restarting" {
  # A window means a human or a deploy is already restarting gateways; a second
  # drain-restart on top is pure cost. The token has days of life.
  stub_mint 0 "SWEEP_ROTATED=9"
  stage_script 0
  cat > "$TEST_TMPDIR/scripts/lib/maintenance-flag.sh" <<'MSTUB'
maintenance_active() { return 0; }
maintenance_reason() { echo "test window"; }
MSTUB
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "0" ]
  [[ "$output" == *"standing down"* ]]
}

@test "maintenance flag ABSENT does not suppress the refresh (fail-safe direction)" {
  # The stand-down must never become a silent skip: a missing or malformed flag
  # has to read as "not in maintenance".
  stub_mint 0 "SWEEP_ROTATED=1"
  stage_script 0
  rm -f "$TEST_TMPDIR/scripts/lib/maintenance-flag.sh"
  run "$STAGED"
  [ "$status" -eq 0 ]
  [ "$(restarts)" = "2" ]
}


# ── PARTIAL SWEEP: committed rotations must LOAD even when a later one fails ──
# _mint_one commits each rotation immediately, so profile A can be persisted
# (and its old single-use refresh token SPENT) before profile B fails. Gating
# the restart on rc==0 left A persisted-but-unloaded: the running gateway kept
# serving a snapshot whose refresh chain had already moved on.

@test "partial sweep (rc!=0 WITH a marker): restarts anyway, then exits non-zero and pages" {
  stub_mint 1 "mint FAILED for openai:b@x.com
SWEEP_ROTATED=1"
  stage_script 0
  run "$STAGED"
  # restarted, because 1 rotation was COMMITTED and must be loaded
  [ "$(restarts)" = "2" ]
  # and still reports the failure rather than claiming success
  [ "$status" -ne 0 ]
  page="$(cat "$PAGE_LOG")"
  [[ "$page" == *"PARTIAL"* ]]
  [[ "$output" == *"restarting anyway"* ]]
}

@test "total failure (rc!=0, NO marker): does NOT restart" {
  # Nothing committed -> nothing to load -> a restart would cost a drain for
  # no benefit. This is the case the old code handled correctly.
  stub_mint 1 "sweep FAILED — 2 profile(s) did not rotate"
  stage_script 0
  run "$STAGED"
  [ "$status" -eq 1 ]
  [ "$(restarts)" = "0" ]
  [[ "$(cat "$PAGE_LOG")" == *"NOT rotated"* ]]
}

@test "partial sweep with rotated=0 in the marker: treated as nothing committed" {
  stub_mint 1 "SWEEP_ROTATED=0"
  stage_script 0
  run "$STAGED"
  [ "$status" -ne 0 ]
  [ "$(restarts)" = "0" ]
}

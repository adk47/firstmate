#!/usr/bin/env bats
# Tests for scripts/lib/ensure-codex-version-pinned.sh — the ExecStartPre/watchdog
# self-heal that keeps @openclaw/codex pinned (dodging the #90925 api-key-route
# regression in codex@2026.6.x). A manual `plugins install` floats codex off the
# pin between deploys (incident 2026-06-19); this script reverts it on restart and
# the --check mode pages on drift.
#
# `openclaw` is PATH-stubbed with a STATEFUL fake (a temp file holds the
# "installed" version; the fake `plugins install` rewrites it) so we can prove the
# ensure path actually re-pins. ssh is shadowed so an accidental remote call fails
# loudly (memory/feedback_bats_must_stub_openclaw).
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
SCRIPT="$HYDRA_REPO/scripts/lib/ensure-codex-version-pinned.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  export FAKE_CODEX_STATE="$TEST_TMPDIR/installed-version"
  export FAKE_CODEX_INSTALL_LOG="$TEST_TMPDIR/install-calls"

  mkdir -p "$TEST_TMPDIR/bin"

  cat > "$TEST_TMPDIR/bin/ssh" <<'STUB'
#!/bin/bash
echo "test stub: ssh call refused ($*)" >&2
exit 99
STUB

  # Stateful fake openclaw: `plugins list --json` echoes the current installed
  # version from $FAKE_CODEX_STATE; `plugins install @openclaw/codex@<v>` records
  # the call and updates the state (simulating a successful pin). $FAKE_CODEX_FAIL
  # makes `plugins list` fail (unreadable). $FAKE_CODEX_ABSENT emits no codex.
  cat > "$TEST_TMPDIR/bin/openclaw" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  *"plugins list --json"*)
    [ -n "$FAKE_CODEX_FAIL" ] && exit 7
    if [ -n "$FAKE_CODEX_ABSENT" ]; then echo '[{"id":"slack","version":"2026.6.1","status":"loaded"}]'; exit 0; fi
    v="$(cat "$FAKE_CODEX_STATE" 2>/dev/null)"
    printf '[{"id":"codex","version":"%s","status":"loaded"}]\n' "$v"
    ;;
  *"plugins install"*)
    inst="$(printf '%s' "$args" | sed -nE 's#.*@openclaw/codex@([0-9.]+).*#\1#p')"
    printf '%s\n' "$args" >> "$FAKE_CODEX_INSTALL_LOG"
    # ENFORCE the real CLI contract (QA finding, PR #899): a 2026.8+ plugin install
    # is REFUSED without --accept-capabilities; a 7.x CLI rejects the option.
    major="${inst%%.*}"; minor="$(printf '%s' "$inst" | cut -d. -f2)"
    if [ "$major" -gt 2026 ] || { [ "$major" -eq 2026 ] && [ "$minor" -ge 8 ]; }; then
      case " $args " in *" --accept-capabilities "*) ;; *) echo "error: plugin declares capabilities; pass --accept-capabilities to acknowledge" >&2; exit 1;; esac
    else
      case " $args " in *" --accept-capabilities "*) echo "error: unknown option '--accept-capabilities'" >&2; exit 1;; esac
    fi
    echo "$inst" > "$FAKE_CODEX_STATE"
    echo "Pinned npm install record to @openclaw/codex@${inst}."
    ;;
  *) echo "fake openclaw: unhandled args: $args" >&2; exit 3 ;;
esac
STUB

  chmod +x "$TEST_TMPDIR/bin/ssh" "$TEST_TMPDIR/bin/openclaw"
  PATH="$TEST_TMPDIR/bin:$PATH"
  export PATH

  export CODEX_PINNED_VERSION="2026.5.27"
  export CODEX_PIN_PROFILES="main edge"
  export FAKE_CODEX_FAIL="" FAKE_CODEX_ABSENT=""
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# ── --check ───────────────────────────────────────────────────────────────────

@test "check: clean (exit 0) when codex == pin on every profile" {
  echo "2026.5.27" > "$FAKE_CODEX_STATE"
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean: codex is pinned at 2026.5.27"* ]]
}

@test "check: drift (exit 1) when codex floated to 2026.6.1, names the offender" {
  echo "2026.6.1" > "$FAKE_CODEX_STATE"
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CODEX VERSION DRIFT"* ]]
  [[ "$output" == *"main: 2026.6.1 (want 2026.5.27)"* ]]
  [[ "$output" == *"#90925"* ]]
}

@test "check: drift (exit 1) when codex is not installed at all" {
  export FAKE_CODEX_ABSENT=1
  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex NOT installed (want 2026.5.27)"* ]]
}

@test "check: unreadable (exit 2) when the openclaw query fails" {
  export FAKE_CODEX_FAIL=1
  run "$SCRIPT" --check
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read codex version"* ]]
}

@test "check: honors an explicit profile arg" {
  echo "2026.5.27" > "$FAKE_CODEX_STATE"
  run "$SCRIPT" --check main
  [ "$status" -eq 0 ]
  [[ "$output" == *"on: main"* ]]
}

# ── ensure (auto-heal) ────────────────────────────────────────────────────────

@test "ensure: re-pins to canonical when drifted, then check is clean" {
  echo "2026.6.1" > "$FAKE_CODEX_STATE"
  export CODEX_PIN_PROFILES="main"
  run "$SCRIPT"
  [ "$status" -eq 0 ]                                  # always exit 0 (fail-open)
  [ "$(cat "$FAKE_CODEX_STATE")" = "2026.5.27" ]       # state was re-pinned
  grep -q "@openclaw/codex@2026.5.27 --force --pin" "$FAKE_CODEX_INSTALL_LOG"
  run "$SCRIPT" --check main
  [ "$status" -eq 0 ]
}

@test "ensure: no-op (no install) when already at the pin" {
  echo "2026.5.27" > "$FAKE_CODEX_STATE"
  export CODEX_PIN_PROFILES="main"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_CODEX_INSTALL_LOG" ]                   # install never called
}

@test "ensure: a bare profile arg (pre-start-heal call shape) re-pins just that profile" {
  echo "2026.6.1" > "$FAKE_CODEX_STATE"
  run "$SCRIPT" main
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_CODEX_STATE")" = "2026.5.27" ]
}

# ── QA round 14 (PR #899): the healer's install argv must be version-gated ───

@test "ensure: a 2026.8.x pin installs WITH --accept-capabilities (the 8.x CLI refuses without it) and lands" {
  echo "2026.7.1" > "$FAKE_CODEX_STATE"
  export CODEX_PIN_PROFILES="main" CODEX_PINNED_VERSION="2026.8.2"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qE "plugins install @openclaw/codex@2026.8.2 --force --pin --accept-capabilities$" "$FAKE_CODEX_INSTALL_LOG"
  [ "$(cat "$FAKE_CODEX_STATE")" = "2026.8.2" ]
  [[ "$output" != *"failed to re-pin"* ]]
}

@test "ensure: a 2026.7.1 pin installs WITHOUT the flag (the 7.x CLI rejects it) and lands" {
  echo "2026.6.1" > "$FAKE_CODEX_STATE"
  export CODEX_PIN_PROFILES="main" CODEX_PINNED_VERSION="2026.7.1"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qE "plugins install @openclaw/codex@2026.7.1 --force --pin$" "$FAKE_CODEX_INSTALL_LOG"
  [ "$(cat "$FAKE_CODEX_STATE")" = "2026.7.1" ]
}

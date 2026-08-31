#!/usr/bin/env bats
# Focused coverage for install-aux-units.sh's superseded-timer guard.
#
# The installer as a whole writes systemd units and clones repos, so it is
# not runnable in a test. This extracts the ONE function whose failure mode
# is unrecoverable -- leaving the old daily-release timer armed alongside the
# new watcher, so both cut a tag for the same day -- and exercises it against
# a stubbed systemctl. Narrow on purpose: a guard that decides whether two
# release paths run at once is worth testing even when its file is not.
bats_require_minimum_version 1.5.0

HYDRA_REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"
INSTALLER="$HYDRA_REPO/scripts/install-aux-units.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"; export TEST_TMPDIR
  STUBBIN="$TEST_TMPDIR/bin"; mkdir -p "$STUBBIN"
  export STUB_IS_ENABLED="disabled"
  export STUB_IS_ACTIVE="inactive"
  export STUB_DISABLE_RC=0
  # 0 = the unit file exists (the normal case: the installer writes
  # hydra-release.timer immediately before calling the guard).
  export STUB_UNIT_PRESENT=0
  cat > "$STUBBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  disable)    exit "${STUB_DISABLE_RC:-0}" ;;
  cat)        exit "${STUB_UNIT_PRESENT:-0}" ;;
  is-enabled) printf '%s\n' "$STUB_IS_ENABLED"; [ "$STUB_IS_ENABLED" = "enabled" ] && exit 0 || exit 1 ;;
  is-active)  printf '%s\n' "$STUB_IS_ACTIVE";  [ "$STUB_IS_ACTIVE" = "active" ]   && exit 0 || exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUBBIN/systemctl"
  PATH="$STUBBIN:$PATH"; export PATH

  # Extract just the guard, plus the log/fail helpers it uses.
  {
    echo 'log() { echo "install-aux-units: $*"; }'
    echo 'fail() { log "FATAL: $*"; exit 1; }'
    sed -n '/^ensure_superseded_timer_off() {/,/^}/p' "$INSTALLER"
    sed -n '/^ensure_timer_armed() {/,/^}/p' "$INSTALLER"
  } > "$TEST_TMPDIR/guard.sh"
  # If the function is ever renamed or removed, this suite must fail rather
  # than silently test nothing.
  for fn in ensure_superseded_timer_off ensure_timer_armed; do
    grep -q "$fn()" "$TEST_TMPDIR/guard.sh" \
      || { echo "guard function $fn not found in $INSTALLER" >&2; return 1; }
  done
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_run_guard() {
  bash -c "set -euo pipefail; source '$TEST_TMPDIR/guard.sh'; ensure_superseded_timer_off hydra-release.timer 'superseded by hydra-release-watch.timer: both would cut a release for the same day'"
}

@test "a timer that disables cleanly is accepted" {
  run _run_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
}

@test "a timer still ENABLED after the disable aborts the install" {
  # The unrecoverable case: both release paths armed, both cutting a tag
  # for the same day, and tags cannot be un-cut.
  export STUB_DISABLE_RC=1
  export STUB_IS_ENABLED="enabled"
  run _run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"same day"* ]]
}

@test "a timer still ACTIVE after the disable aborts the install" {
  export STUB_IS_ENABLED="disabled"
  export STUB_IS_ACTIVE="active"
  run _run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
}

@test "an absent unit is not treated as a failure" {
  # systemctl reports neither enabled nor active for a unit that was never
  # installed; that is a clean state, not a reason to abort a fresh deploy.
  # Proven absent via `systemctl cat`, NOT inferred from the empty string --
  # see the query-failure test below, which has identical is-enabled output
  # and must reach the opposite verdict.
  export STUB_IS_ENABLED=""
  export STUB_IS_ACTIVE=""
  export STUB_UNIT_PRESENT=1
  run _run_guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "an unreadable timer state aborts, it is not read as safe" {
  # A transient systemd/D-Bus error makes is-enabled/is-active print nothing
  # while the unit very much exists and may still be armed. The guard used a
  # blacklist (reject only "enabled"/"active"), so empty passed as safe and
  # the installer would arm the watcher next to a live daily timer -- both
  # cutting a tag for the same day, which cannot be undone.
  export STUB_IS_ENABLED=""
  export STUB_IS_ACTIVE=""
  export STUB_UNIT_PRESENT=0
  run _run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"cannot confirm"* ]]
}

@test "an unrecognised timer state aborts rather than being assumed safe" {
  # Not every non-"enabled" state is harmless: "linked" and
  # "enabled-runtime" both still fire. Anything outside the safe list must
  # abort instead of falling through.
  export STUB_IS_ENABLED="enabled-runtime"
  export STUB_IS_ACTIVE="inactive"
  run _run_guard
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
}

_run_arm() {
  bash -c "set -euo pipefail; source '$TEST_TMPDIR/guard.sh'; ensure_timer_armed hydra-release-watch.timer"
}

@test "the watcher timer arming cleanly is accepted" {
  export STUB_IS_ENABLED="enabled"
  export STUB_IS_ACTIVE="active"
  run _run_arm
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled=enabled active=active"* ]]
}

@test "a watcher timer that fails to START aborts the install" {
  # This is the live release path now: an unarmed timer means every prod
  # release afterwards is unannounced, with only a log warning to say so.
  export STUB_IS_ENABLED="enabled"
  export STUB_IS_ACTIVE="inactive"
  run _run_arm
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"unannounced"* ]]
}

@test "a watcher timer that fails to ENABLE aborts the install" {
  # Active-but-not-enabled would survive until the next reboot and then
  # silently stop arming.
  export STUB_IS_ENABLED="disabled"
  export STUB_IS_ACTIVE="active"
  run _run_arm
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
}

@test "the installer actually invokes both guards" {
  # The tests above exercise extracted function bodies. That proves the
  # guards behave, not that the entrypoint still calls them -- deleting a
  # call site would leave every test here green while production either runs
  # two taggers or arms none. Assert the wiring itself.
  run grep -qE '^ensure_superseded_timer_off hydra-release\.timer ' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -qE '^ensure_timer_armed hydra-release-watch\.timer$' "$INSTALLER"
  [ "$status" -eq 0 ]

  # ...and in that order: the superseded timer must be off BEFORE the new one
  # is armed, or there is a window with both enabled.
  off_line="$(grep -n '^ensure_superseded_timer_off hydra-release\.timer ' "$INSTALLER" | cut -d: -f1)"
  arm_line="$(grep -n '^ensure_timer_armed hydra-release-watch\.timer$' "$INSTALLER" | cut -d: -f1)"
  [ -n "$off_line" ]
  [ -n "$arm_line" ]
  [ "$off_line" -lt "$arm_line" ]
}

@test "openclaw >= 2026.8: codex-token-refresh.timer install is gated and actively torn down" {
  # scripts/lib/codex-oauth-refresh.sh's own >= 2026.8 --break-glass gate
  # exists because native in-process auto-refresh becomes the sole refresher
  # there; a second, out-of-band refresher (this timer) racing it reproduces
  # the 2026-06-08 refresh_token_reused incident. Assert the installer itself
  # never installs the unit on that runtime, and actively disables a
  # prior-install leftover via the same fail-closed guard used for
  # hydra-release.timer -- a deleted or unwired gate would leave every other
  # test in this file green while production keeps arming a racing timer.
  run grep -qE '^AUX_RUNTIME_IS_2026_8_PLUS=0$' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -qE 'if \[ "\$AUX_RUNTIME_IS_2026_8_PLUS" -eq 0 \]; then' "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -qE '^\s*ensure_superseded_timer_off codex-token-refresh\.timer ' "$INSTALLER"
  [ "$status" -eq 0 ]
}

# ── unparseable runtime version must never guess ─────────────────────────────
# QA bot finding (PR #897, 2026-08-31): an empty/failed `openclaw --version`
# was being classified as pre-2026.8, which on an actual 2.0 box would
# (re)install/re-enable codex-token-refresh.timer alongside the native
# in-process refresher -- the exact refresh_token_reused fleet-kill shape
# from 2026-06-08. Extracts just the runtime-detection block (same technique
# as the guard.sh extraction above) and runs it against a stubbed openclaw,
# mutation-goes-red style: this must fail loud, not silently continue.
_run_runtime_gate() {
  local version_output="$1"
  local sandbox="$TEST_TMPDIR/runtime-gate"
  mkdir -p "$sandbox/bin" "$sandbox/lib"
  cat > "$sandbox/bin/openclaw" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then printf '%s' "$version_output"; exit 0; fi
exit 99
STUB
  chmod +x "$sandbox/bin/openclaw"
  cp "$HYDRA_REPO/scripts/lib/version-compare.sh" "$sandbox/lib/version-compare.sh"
  {
    echo 'log() { echo "install-aux-units: $*"; }'
    echo 'fail() { log "FATAL: $*"; exit 1; }'
    sed -n '/^# Runtime-aware install gate:/,/^fi$/p' "$INSTALLER" \
      | sed "s#\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")\" \&\& pwd)/lib/version-compare.sh#$sandbox/lib/version-compare.sh#"
  } > "$sandbox/gate.sh"
  grep -q 'AUX_RUNTIME_VER=' "$sandbox/gate.sh" \
    || { echo "runtime gate extraction found nothing -- installer must have changed shape" >&2; return 1; }
  PATH="$sandbox/bin:$PATH" bash -c "set -euo pipefail; source '$sandbox/gate.sh'; echo AUX_RUNTIME_IS_2026_8_PLUS=\$AUX_RUNTIME_IS_2026_8_PLUS"
}

@test "unparseable runtime version: install-aux-units fails loud, never guesses pre-2026.8" {
  run _run_runtime_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  # Never reaches the assignment that would arm the pre-2026.8 (timer-install) path.
  [[ "$output" != *"AUX_RUNTIME_IS_2026_8_PLUS=0"* ]]
}

@test "garbage (non-version-shaped) runtime version: install-aux-units fails loud, never guesses pre-2026.8" {
  # QA bot finding (PR #897 round 3): openclaw_runtime_version() must reject
  # a non-empty, non-version-shaped token AT THE HELPER, so every caller's
  # existing empty-⇒-fail-loud path already covers this for free. Prove it
  # end to end through the real installer gate, not just at the helper.
  run _run_runtime_gate "OpenClaw 2026.invalid"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"could not determine openclaw runtime version"* ]]
  [[ "$output" != *"AUX_RUNTIME_IS_2026_8_PLUS=0"* ]]
}

@test "parseable runtime version below 2026.8 still arms the timer-install path" {
  run _run_runtime_gate "openclaw 2026.7.1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUX_RUNTIME_IS_2026_8_PLUS=0"* ]]
}

@test "parseable runtime version >= 2026.8 gates the timer-install path off" {
  run _run_runtime_gate "openclaw 2026.8.1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUX_RUNTIME_IS_2026_8_PLUS=1"* ]]
}

#!/usr/bin/env bash
# Behavior tests for tests/tmux-test-safety.sh - the shared guard that refuses
# any tmux invocation from inside a test that would reach the DEFAULT tmux
# server.
#
# The 2026-11-05 incident: tests/fm-grok-stop-live-e2e.test.sh ran
# `"$lab/bin/tmux" kill-server` with no -L/-S, which targets the default server
# the live fleet runs on, and roughly 27 lanes were lost. These cases pin the
# guard in both directions - it refuses a default-socket argv and it passes a
# named-socket one - and prove the two generated shims actually enforce it
# rather than merely documenting it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/tmux-test-safety.sh
. "$ROOT/tests/tmux-test-safety.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmux-test-safety)

# A stand-in for the real tmux binary: records its argv and exits 0, so a shim
# that wrongly forwards a default-socket call is visible in the log.
make_fake_tmux() {  # <dir> -> echoes fake tmux path
  local dir=$1 fake="$1/fake-tmux"
  mkdir -p "$dir"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

# --- the rule itself --------------------------------------------------------

test_rule_refuses_default_socket() {
  local out rc
  out=$(fm_test_tmux_refuse_default_socket kill-server 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a bare kill-server must be refused"
  assert_contains "$out" "refusing" "the refusal names itself"
  assert_contains "$out" "kill-server" "the refusal quotes the refused argv"
  assert_contains "$out" "-L <name> or -S <path>" "the refusal names the fix"
  pass "the guard refuses a tmux invocation that names no socket"
}

test_rule_passes_named_socket() {
  fm_test_tmux_refuse_default_socket -L fm-test-socket kill-server \
    || fail "-L <name> must pass the guard"
  fm_test_tmux_refuse_default_socket -S /tmp/fm-test.sock kill-server \
    || fail "-S <path> must pass the guard"
  fm_test_tmux_refuse_default_socket -Lfm-test-socket kill-server \
    || fail "the joined -L<name> form must pass the guard"
  fm_test_tmux_refuse_default_socket -S/tmp/fm-test.sock kill-server \
    || fail "the joined -S<path> form must pass the guard"
  pass "the guard passes every named-socket form"
}

test_rule_refuses_other_default_socket_commands() {
  local cmd
  for cmd in kill-session kill-window new-session list-sessions; do
    if fm_test_tmux_refuse_default_socket "$cmd" 2>/dev/null; then
      fail "a bare '$cmd' must be refused"
    fi
  done
  pass "the guard refuses every default-socket command, not only kill-server"
}

test_rule_refuses_command_option_socket_lookalike() {
  local out rc
  out=$(fm_test_tmux_refuse_default_socket capture-pane -S -100 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a command-specific -S (capture-pane scrollback) must not count as a socket"
  assert_contains "$out" "refusing" "the refusal names itself"
  pass "the guard refuses a command-specific -S that names no socket"
}

# --- the PATH shim ----------------------------------------------------------

test_guard_install_refuses_and_forwards() {
  local d fake shim out rc
  d="$TMP_ROOT/install"
  fake=$(make_fake_tmux "$d")
  shim=$(fm_test_tmux_guard_install "$d/bin" "$fake") || fail "guard install failed"
  [ -x "$shim" ] || fail "the installed shim must be executable"

  FM_FAKE_TMUX_LOG="$d/forwarded.log" out=$(fm_test_tmux_expect_refusal "$shim" kill-server 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the installed shim must refuse a bare kill-server"
  assert_contains "$out" "refusing" "the shim's refusal is the shared guard's"
  assert_absent "$d/forwarded.log" "a refused call must never reach the real binary"

  FM_FAKE_TMUX_LOG="$d/forwarded.log" "$shim" -L fm-test-socket kill-server \
    || fail "the installed shim must forward a named-socket call"
  assert_contains "$(cat "$d/forwarded.log")" "-L fm-test-socket kill-server" \
    "the forwarded argv reaches the real binary unchanged"

  rm -f -- "$d/forwarded.log"
  FM_FAKE_TMUX_LOG="$d/forwarded.log" out=$(fm_test_tmux_expect_refusal "$shim" capture-pane -S -100 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the installed shim must refuse a command-specific -S with no socket"
  assert_absent "$d/forwarded.log" "a refused command-option call must never reach the real binary"
  pass "the installed PATH shim refuses a default-socket call and forwards a named one"
}

# --- the socket-pinning wrapper --------------------------------------------

test_wrapper_pins_socket_and_refuses_caller_socket() {
  local d fake wrapper out rc
  d="$TMP_ROOT/wrapper"
  fake=$(make_fake_tmux "$d")
  wrapper=$(fm_test_tmux_wrapper_write "$d/tmux" "$fake" "$d/dedicated.sock") \
    || fail "wrapper write failed"
  [ -x "$wrapper" ] || fail "the wrapper must be executable"

  FM_FAKE_TMUX_LOG="$d/forwarded.log" "$wrapper" kill-server \
    || fail "the wrapper must forward a call that names no socket"
  assert_contains "$(cat "$d/forwarded.log")" "-S $d/dedicated.sock kill-server" \
    "the wrapper supplies the test's own socket"

  out=$(FM_FAKE_TMUX_LOG="$d/forwarded.log" "$wrapper" -L other kill-server 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the wrapper must refuse a caller that chooses its own socket"
  assert_contains "$out" "refusing" "the wrapper's refusal is the shared guard's"

  FM_FAKE_TMUX_LOG="$d/forwarded.log" "$wrapper" capture-pane -S -100 \
    || fail "the wrapper must allow a command-specific -S that is not a socket"
  assert_contains "$(cat "$d/forwarded.log")" "-S $d/dedicated.sock capture-pane -S -100" \
    "the wrapper pins its socket and leaves the command option alone"
  pass "the socket-pinning wrapper supplies its own socket and refuses a caller-chosen one"
}

test_rule_refuses_default_socket
test_rule_passes_named_socket
test_rule_refuses_other_default_socket_commands
test_rule_refuses_command_option_socket_lookalike
test_guard_install_refuses_and_forwards
test_wrapper_pins_socket_and_refuses_caller_socket

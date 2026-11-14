#!/usr/bin/env bash
# tests/tmux-test-safety.sh - shared hard guard against a test's tmux
# invocation ever reaching the DEFAULT tmux server.
#
# WHY THIS EXISTS. On 2026-11-05 the default tmux server was lost and the fleet
# lost roughly 27 lanes. The cause was a test: tests/fm-grok-stop-live-e2e.test.sh
# ran `"$lab/bin/tmux" kill-server` with no -L/-S, which targets the default
# server - the one the live fleet runs on. A test may create, use, and destroy
# its own throwaway server; it must never touch the captain's.
#
# THE RULE. A tmux invocation from a test may either name its own socket with
# `-L <name>` or `-S <path>`, or run inside a provably private throwaway socket
# directory. The runner and tests/lib.sh both create such a directory and export
# TMUX_TMPDIR and FM_TEST_TMUX_PRIVATE_TMPDIR to the same path; tmux itself
# then keeps its default server inside that directory, away from the fleet.
# An inherited TMUX names the socket tmux will actually use and takes precedence
# over TMUX_TMPDIR, so it must be absent as well; the runner and tests/lib.sh
# scrub it from the test environment. Anything else is refused. The allowance is
# fail-closed: a blank, unset, or mismatched pair, or a set TMUX, re-enables the
# refusal.
#
# ENFORCEMENT. bin/fm-test-run.sh installs the PATH shim below for every test
# it launches and gives each launched test that private socket directory, so a
# test cannot opt out by forgetting to call the guard. tests/lib.sh installs
# the same shim and creates the same directory when a test file is run by hand.
# The explicit functions remain for tests that want to prove the rule directly.
#
# THREE WAYS TO USE IT, in increasing strength:
#   fm_test_tmux_refuse_default_socket <args...>
#       the rule itself: refuse (stderr + non-zero) an argv that names no
#       socket. Call it before a direct tmux invocation.
#   fm_test_tmux_guard_install <dir> [<real-tmux>]
#       write a `tmux` PATH shim into <dir> that enforces the rule for every
#       invocation, then execs the real binary. Prepend <dir> to PATH.
#   fm_test_tmux_wrapper_write <path> <real-tmux> <socket-path>
#       write a socket-PINNING wrapper: the code under test may not choose its
#       own socket at all, and the wrapper supplies the test's dedicated one.
#
# Fails CLOSED: an argv this file cannot prove names a socket is refused. The
# cost of a false refusal is a test that must add -L/-S; the cost of a false
# pass is the captain's fleet.
set -u

# fm_test_tmux_global_socket: 0 when <args...> names a tmux socket through a
# GLOBAL -L/-S option, i.e. one that appears before the tmux command word. A -S
# after the command word is a command-specific option (for example
# `capture-pane -S -100` scrollback) and is NOT a socket selector.
fm_test_tmux_global_socket() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      -L|-S) return 0 ;;
      -L?*|-S?*) return 0 ;;
      --) return 1 ;;
      -c|-f|-T) [ "$#" -gt 0 ] && shift; continue ;;
      -*) continue ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# fm_test_tmux_socket_isolated: 0 when tmux's own socket directory is provably
# a private throwaway one. Both variables must be non-empty and name the same
# path, and no inherited TMUX may name a socket tmux would prefer; losing or
# mismatching either variable, or a set TMUX, re-enables the refusal.
fm_test_tmux_socket_isolated() {
  [ -z "${TMUX:-}" ] \
    && [ -n "${TMUX_TMPDIR:-}" ] \
    && [ -n "${FM_TEST_TMUX_PRIVATE_TMPDIR:-}" ] \
    && [ "$TMUX_TMPDIR" = "$FM_TEST_TMUX_PRIVATE_TMPDIR" ]
}

# fm_test_tmux_named_socket: 0 when <args...> names its own socket, or the
# whole invocation is confined to a proven private socket directory.
fm_test_tmux_named_socket() {
  fm_test_tmux_global_socket "$@" || fm_test_tmux_socket_isolated
}

# fm_test_tmux_refuse_default_socket: the rule. 0 when <args...> names its own
# socket; 1 (with a diagnostic on stderr) when it would reach the default one.
fm_test_tmux_refuse_default_socket() {
  fm_test_tmux_named_socket "$@" && return 0
  printf 'tmux test safety guard: refusing "tmux %s" - a test must name its own socket (-L <name> or -S <path>) or run in a proven private TMUX_TMPDIR with no inherited TMUX; the default server is the live fleet\n' \
    "$*" >&2
  return 1
}

# fm_test_tmux_expect_refusal: run an invocation that is deliberately expected
# to be refused, with the runner's refusal log detached so the expected refusal
# is not reported as an unexpected one.
fm_test_tmux_expect_refusal() {
  local saved_log_set=0 saved_log='' saved_tmp_set=0 saved_tmp='' saved_private_set=0 saved_private='' rc
  if [ "${FM_TEST_TMUX_REFUSAL_LOG+x}" = x ]; then
    saved_log_set=1
    saved_log=$FM_TEST_TMUX_REFUSAL_LOG
  fi
  if [ "${TMUX_TMPDIR+x}" = x ]; then
    saved_tmp_set=1
    saved_tmp=$TMUX_TMPDIR
  fi
  if [ "${FM_TEST_TMUX_PRIVATE_TMPDIR+x}" = x ]; then
    saved_private_set=1
    saved_private=$FM_TEST_TMUX_PRIVATE_TMPDIR
  fi
  unset FM_TEST_TMUX_REFUSAL_LOG TMUX_TMPDIR FM_TEST_TMUX_PRIVATE_TMPDIR
  "$@"
  rc=$?
  [ "$saved_log_set" -eq 1 ] && export FM_TEST_TMUX_REFUSAL_LOG="$saved_log"
  [ "$saved_tmp_set" -eq 1 ] && export TMUX_TMPDIR="$saved_tmp"
  [ "$saved_private_set" -eq 1 ] && export FM_TEST_TMUX_PRIVATE_TMPDIR="$saved_private"
  return "$rc"
}

# fm_test_tmux_guard_install: write a `tmux` shim into <dir> that enforces the
# rule for every invocation and then execs <real-tmux>. Echoes the shim path.
# <real-tmux> defaults to the first tmux on PATH that is not the shim itself.
# The shim names the test from FM_TEST_TMUX_TEST_LABEL when the caller sets it.
fm_test_tmux_guard_install() {  # <dir> [<real-tmux>]
  local dir=$1 real=${2:-} shim guard
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  if [ -z "$real" ]; then
    real=$(command -v tmux 2>/dev/null) || return 1
  fi
  [ -n "$real" ] && [ -x "$real" ] || return 1
  guard=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  shim="$dir/tmux"
  cat > "$shim" <<EOF
#!/usr/bin/env bash
# Auto-generated by tests/tmux-test-safety.sh - refuses a default-socket tmux
# invocation from inside a test, then execs the real binary.
set -u
. $(printf '%q' "$guard")
if ! fm_test_tmux_refuse_default_socket "\$@"; then
  printf 'tmux test safety guard: test %s\n' "\${FM_TEST_TMUX_TEST_LABEL:-unknown}" >&2
  if [ -n "\${FM_TEST_TMUX_REFUSAL_LOG:-}" ]; then
    printf '%s\t%s\n' "\${FM_TEST_TMUX_TEST_LABEL:-unknown}" "\$*" >>"\$FM_TEST_TMUX_REFUSAL_LOG"
  fi
  exit 1
fi
exec $(printf '%q' "$real") "\$@"
EOF
  chmod +x "$shim" || return 1
  printf '%s\n' "$shim"
}

# fm_test_tmux_wrapper_write: write a socket-PINNING wrapper at <path>. The
# code under test may not pass -L/-S at all (that is refused), and the wrapper
# supplies <socket-path> itself, so every call lands on the test's own server.
fm_test_tmux_wrapper_write() {  # <path> <real-tmux> <socket-path>
  local path=$1 real=$2 socket=$3 guard
  [ -n "$path" ] && [ -n "$real" ] && [ -n "$socket" ] || return 1
  [ -x "$real" ] || return 1
  guard=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  cat > "$path" <<EOF
#!/usr/bin/env bash
# Auto-generated by tests/tmux-test-safety.sh - pins every call to the test's
# own dedicated socket and refuses a caller that tries to choose its own.
set -u
. $(printf '%q' "$guard")
if fm_test_tmux_global_socket "\$@"; then
  printf 'tmux test safety guard: refusing \`tmux %s\` - this wrapper pins the test socket; the caller may not choose one\n' "\$*" >&2
  exit 1
fi
exec $(printf '%q' "$real") -S $(printf '%q' "$socket") "\$@"
EOF
  chmod +x "$path" || return 1
  printf '%s\n' "$path"
}

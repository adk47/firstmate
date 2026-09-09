#!/usr/bin/env bash
# Install, inspect, or remove this home's launchd keep-alive job.
#
# The job runs bin/fm-keepalive-agent.sh every few minutes so a PRIMARY
# firstmate session that is itself stalled - on a transient inference-gateway
# error, or with its fleet supervision lapsed - has something outside the
# session that can notice and nudge it.
#
# THIS IS OPT-IN AND NEVER AUTO-INSTALLED. It writes into the captain's own
# LaunchAgents directory and then runs unattended forever, which is exactly the
# kind of standing change firstmate does not make on its own initiative. Nothing
# in session start, bootstrap, or self-update calls it.
#
# Per-home by construction. The job label carries a digest of the home path, the
# plist passes that home explicitly, and every artifact it writes lives under
# that home's state directory, so installing it in a secondmate home cannot
# disturb the main home's job and removing one cannot remove the other.
#
# Usage:
#   fm-keepalive-install.sh install [--home <dir>] [--interval <secs>]
#                                   [--backend <b>] [--target <t>]
#   fm-keepalive-install.sh status  [--home <dir>]
#   fm-keepalive-install.sh uninstall [--home <dir>]
#
# `install` must be run FROM THE PRIMARY PANE, because that is the only place
# the session's own terminal endpoint can be observed; it records that endpoint
# and refuses rather than guessing when it cannot (--backend/--target override
# it for a terminal whose identifiers this build cannot read from the
# environment). The primary's own StopFailure hook refreshes the record
# afterwards, so a firstmate relaunched into a new pane re-points the job
# without a reinstall.
#
# macOS only: launchd is the scheduler. On any other platform this refuses and
# names the equivalent it does not install for you.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}
[ "$#" -eq 0 ] || shift
HOME_DIR=''
INTERVAL=240
WANT_BACKEND=''
WANT_TARGET=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2:-}; shift 2 || exit 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 || exit 2 ;;
    --backend) WANT_BACKEND=${2:-}; shift 2 || exit 2 ;;
    --target) WANT_TARGET=${2:-}; shift 2 || exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$HOME_DIR" ] || HOME_DIR="${FM_HOME:-$FM_ROOT}"
if [ ! -d "$HOME_DIR" ]; then
  echo "error: firstmate home '$HOME_DIR' does not exist" >&2
  exit 2
fi
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
STATE="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

case "$INTERVAL" in
  ''|*[!0-9]*) echo "error: --interval must be whole seconds" >&2; exit 2 ;;
esac
if [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 3600 ]; then
  echo "error: --interval must be between 60 and 3600 seconds; a faster job cannot see anything a slower one misses and a slower one stops being a supervisor" >&2
  exit 2
fi

# The label must be stable for one home and distinct across homes, and launchd
# labels cannot carry a path. A digest of the resolved home path gives both.
home_digest() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$HOME_DIR" | shasum -a 256 | cut -c1-12
  else
    printf '%s' "$HOME_DIR" | cksum | tr -d ' ' | cut -c1-12
  fi
}
LABEL="ai.firstmate.keepalive.$(home_digest)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

require_macos() {
  [ "$(uname 2>/dev/null)" = Darwin ] && return 0
  cat >&2 <<EOF
error: the keep-alive job is installed through launchd and this host is not macOS.
Nothing was installed. The equivalent elsewhere is a systemd user timer, or a
cron entry, running exactly:
  $SCRIPT_DIR/fm-keepalive-agent.sh --home $HOME_DIR
every $INTERVAL seconds. Firstmate does not write those for you.
EOF
  return 1
}

case "$CMD" in
  install)
    require_macos || exit 1
    if ! record=$("$SCRIPT_DIR/fm-keepalive-endpoint.sh" record --state "$STATE" \
        ${WANT_BACKEND:+--backend "$WANT_BACKEND"} ${WANT_TARGET:+--target "$WANT_TARGET"}); then
      cat >&2 <<EOF
error: this session's own terminal endpoint could not be proved, so the job was
not installed - a keep-alive that does not know which pane is firstmate would
type into whatever it found. Run this from the primary firstmate pane, or pass
--backend and --target explicitly.
EOF
      exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents" || exit 1
    # StandardOut/Error go to the home's own state dir, not a shared location,
    # so two homes' jobs cannot interleave into one file.
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SCRIPT_DIR/fm-keepalive-agent.sh</string>
    <string>--home</string>
    <string>$HOME_DIR</string>
    <string>--once</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/.keepalive-agent.out</string>
  <key>StandardErrorPath</key><string>$STATE/.keepalive-agent.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$PATH</string>
    <key>FM_HOME</key><string>$HOME_DIR</string>
  </dict>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
      # Older macOS releases only accept the legacy verb.
      launchctl load "$PLIST" 2>/dev/null || {
        echo "error: launchctl refused to load $PLIST; the plist was written but the job is not running" >&2
        exit 1
      }
    fi
    echo "installed $LABEL every ${INTERVAL}s for $HOME_DIR (primary endpoint: $record)"
    echo "log: $STATE/.keepalive-agent.log"
    ;;
  status)
    echo "label: $LABEL"
    echo "plist: $PLIST$([ -f "$PLIST" ] || printf ' (absent)')"
    if [ "$(uname 2>/dev/null)" = Darwin ]; then
      launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*\(state\|last exit code\|runs\) *= */  \1 = /p' \
        || echo "  not loaded"
    fi
    echo "endpoint: $("$SCRIPT_DIR/fm-keepalive-endpoint.sh" read --state "$STATE" 2>/dev/null || echo 'none recorded')"
    if [ -f "$STATE/.keepalive-agent.log" ]; then
      echo "recent:"
      tail -n 5 "$STATE/.keepalive-agent.log" | sed 's/^/  /'
    fi
    ;;
  uninstall)
    if [ "$(uname 2>/dev/null)" = Darwin ]; then
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    fi
    rm -f "$PLIST"
    echo "removed $LABEL"
    echo "note: $STATE/.primary-endpoint and the agent log are left in place; delete them by hand if you want them gone"
    ;;
  ''|-h|--help)
    usage
    [ -n "$CMD" ] || exit 2
    ;;
  *)
    echo "error: unknown command '$CMD'" >&2
    exit 2
    ;;
esac

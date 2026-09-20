#!/usr/bin/env bash
# fm-chair-sentinel.sh - the deterministic decider for the firstmate chair.
#
# Usage:
#   fm-chair-sentinel.sh            one decision tick (the LaunchAgent default)
#   fm-chair-sentinel.sh arm        install and load the LaunchAgent
#   fm-chair-sentinel.sh disarm     unload and remove the LaunchAgent
#   fm-chair-sentinel.sh status     report the LaunchAgent and last tick
#
# One tick runs the sensor (bin/fm-chair-runway.sh) and the chair status
# (bin/fm-chair-status.sh), applies the table, acts through
# bin/fm-chair-flip.sh, and appends one line to data/chair-sentinel/log.jsonl.
# It calls no model anywhere.
#
#   Fable green + chair pi-fable          -> nothing
#   Fable green + chair grok|none         -> flip to-pi-fable
#   Fable red   + Grok above floor + grok -> nothing
#   Fable red   + Grok above floor + pi|none -> flip to-grok
#   otherwise (both red or unmeasurable)  -> no flip; write state/.chair-alarm and
#                                            print the captain-facing line naming
#                                            the 8080 accounts a human must log in
#
# "Do not fight a healthy chair" is the first and third rows: a chair sitting on
# a source that is still green is never moved.
#
# FM_CHAIR_SENTINEL_DRY_RUN=1 passes the dry run through to the actuator.
#
# Test seams:
#   FM_CHAIR_SENTINEL_SENSOR_CMD   override the sensor
#   FM_CHAIR_SENTINEL_STATUS_CMD   override the chair status
#   FM_CHAIR_SENTINEL_FLIP_CMD     override the actuator
#   FM_CHAIR_SENTINEL_HOME         home directory
#   FM_CHAIR_SENTINEL_LA_DIR       LaunchAgents directory (default ~/Library/LaunchAgents)
#   FM_CHAIR_SENTINEL_LAUNCHCTL    launchctl (default: launchctl)
#   FM_CHAIR_SENTINEL_NOW          epoch seconds to use as now
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
HOME_DIR=${FM_CHAIR_SENTINEL_HOME:-$FM_HOME}
ABS_HOME=$(cd -- "$HOME_DIR" 2>/dev/null && pwd -P) || ABS_HOME=$HOME_DIR
STATE_DIR=$ABS_HOME/state
DATA_DIR=$ABS_HOME/data
LOG_DIR=$DATA_DIR/chair-sentinel
LOG_FILE=$LOG_DIR/log.jsonl
ALARM_FILE=$STATE_DIR/.chair-alarm
LABEL=ai.muso.chair-sentinel
LA_DIR=${FM_CHAIR_SENTINEL_LA_DIR:-${HOME:-}/Library/LaunchAgents}
PLIST=$LA_DIR/$LABEL.plist
LAUNCHCTL=${FM_CHAIR_SENTINEL_LAUNCHCTL:-launchctl}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

extract_field() {  # <line> <key>
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\([^ ]*\).*/\1/p" | head -1
}

sensor_line() {
  if [ -n "${FM_CHAIR_SENTINEL_SENSOR_CMD:-}" ]; then
    "$FM_CHAIR_SENTINEL_SENSOR_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-runway.sh" 2>/dev/null
  fi
}

chair_line() {
  if [ -n "${FM_CHAIR_SENTINEL_STATUS_CMD:-}" ]; then
    "$FM_CHAIR_SENTINEL_STATUS_CMD" 2>/dev/null
  else
    FM_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-status.sh" 2>/dev/null
  fi
}

flip_to() {  # <to-pi-fable|to-grok>
  if [ -n "${FM_CHAIR_SENTINEL_FLIP_CMD:-}" ]; then
    FM_CHAIR_FLIP_HOME="$ABS_HOME" "$FM_CHAIR_SENTINEL_FLIP_CMD" "$1"
  else
    FM_CHAIR_FLIP_HOME="$ABS_HOME" "$SCRIPT_DIR/fm-chair-flip.sh" "$1"
  fi
}

run_tick() {
  local sensor status fable grok chair terminal decision action alarm_names
  sensor=$(sensor_line)
  status=$(chair_line)
  fable=$(extract_field "$sensor" fable)
  grok=$(extract_field "$sensor" grok)
  chair=$(extract_field "$status" chair)
  terminal=$(extract_field "$status" terminal)
  alarm_names=$(extract_field "$sensor" names)

  decision=none
  action=none
  if [ "$fable" = green ] && [ "$chair" = pi-fable ]; then
    decision=fable_green_chair_ok
  elif [ "$fable" = green ] && { [ "$chair" = grok ] || [ "$chair" = none ]; }; then
    decision=fable_green_chair_wrong
    action=to-pi-fable
  elif [ "$fable" = red ] && [ "$grok" = green ] && [ "$chair" = grok ]; then
    decision=grok_red_chair_ok
  elif [ "$fable" = red ] && [ "$grok" = green ] && { [ "$chair" = pi-fable ] || [ "$chair" = none ]; }; then
    decision=grok_blackout_chair_wrong
    action=to-grok
  else
    decision=no_tank
  fi

  if [ "$decision" = no_tank ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf 'no tank: fable=%s grok=%s chair=%s\n' "$fable" "$grok" "$chair" > "$ALARM_FILE" 2>/dev/null || true
    printf 'Captain, firstmate has no tank: Fable=%s, SuperGrok=%s. better-ccflare accounts needing a human login: %s\n' \
      "$fable" "$grok" "${alarm_names:-unknown}"
  else
    rm -f "$ALARM_FILE" 2>/dev/null || true
  fi

  if [ "$action" != none ]; then
    flip_to "$action" || true
  fi

  mkdir -p "$LOG_DIR" 2>/dev/null || true
  local now
  now=${FM_CHAIR_SENTINEL_NOW:-$(date +%s)}
  printf '{"at":%s,"fable":"%s","grok":"%s","chair":"%s","terminal":"%s","decision":"%s","action":"%s"}\n' \
    "$now" "$fable" "$grok" "$chair" "$terminal" "$decision" "$action" >> "$LOG_FILE" 2>/dev/null || true

  printf 'chair-sentinel: fable=%s grok=%s chair=%s decision=%s action=%s\n' \
    "$fable" "$grok" "$chair" "$decision" "$action"
}

write_plist() {
  mkdir -p "$LA_DIR" 2>/dev/null || { echo "chair-sentinel: cannot create $LA_DIR" >&2; return 1; }
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$SCRIPT_DIR/fm-chair-sentinel.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FM_HOME</key><string>$ABS_HOME</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/agent.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/agent.err</string>
</dict></plist>
PLISTEOF
}

case "${1:-tick}" in
  tick|'') run_tick ;;
  arm)
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    write_plist || exit 1
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    "$LAUNCHCTL" load "$PLIST" || { echo "chair-sentinel: launchctl load failed" >&2; exit 1; }
    echo "chair-sentinel: armed ($PLIST)"
    ;;
  disarm)
    "$LAUNCHCTL" unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST" 2>/dev/null || true
    echo "chair-sentinel: disarmed"
    ;;
  status)
    if [ -f "$PLIST" ]; then echo "plist: present ($PLIST)"; else echo "plist: absent"; fi
    if "$LAUNCHCTL" list 2>/dev/null | grep -q "$LABEL"; then echo "launchd: loaded"; else echo "launchd: not loaded"; fi
    if [ -f "$LOG_FILE" ]; then echo "last tick: $(tail -n 1 "$LOG_FILE")"; else echo "last tick: none"; fi
    if [ -f "$ALARM_FILE" ]; then echo "alarm: $(cat "$ALARM_FILE")"; else echo "alarm: none"; fi
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
#!/usr/bin/env bash
# chair-flipper-e2e.sh - end-to-end walk of the captain's report
# ("grok ran out of tokens and flipper didnt work") through the REAL scripts:
#   bin/fm-chair-sentinel.sh -> bin/fm-chair-runway.sh (sensor)
#                            -> bin/fm-chair-status.sh (chair classifier, real ps)
#                            -> bin/fm-chair-flip.sh   (actuator, live mode)
# Only the outside world is stubbed through the scripts' documented seams:
#   - the 8317 pool probe (HTTP code), the quota-axi Grok JSON, the better-ccflare
#     fixtures, and the Orca CLI (which here really ends the incumbent on /exit
#     and really spawns a successor process named `pi` on `terminal create`).
# The lock holder is a real process whose executable is named `grok`, so the
# harness classification runs against the real `ps`.
set -u
ROOT=${ROOT:?repo root}
EVID=${EVID:?evidence dir}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-chair-e2e.XXXXXX")
HOME_DIR=$WORK/home
FAKEBIN=$WORK/fakebin
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$FAKEBIN"
# symlinks, not copies: a platform binary copied out of /bin is SIGKILLed by
# macOS AMFI; through a symlink `ps -o comm=` reports the symlink path, whose
# basename is what bin/fm-session-lock-lib.sh classifies.
ln -s /bin/sleep "$FAKEBIN/grok"
ln -s /bin/sleep "$FAKEBIN/pi"
cleanup() { pkill -f "$FAKEBIN/" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# --- outside-world stubs ------------------------------------------------------
printf 'test-key\n' > "$WORK/api_key"
PROBE=$WORK/probe.sh
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
cat "$FM_E2E_PROBE_CODE_FILE"
SH
chmod +x "$PROBE"
HEALTH=$WORK/health.json; ACCOUNTS=$WORK/accounts.json; GROK_JSON=$WORK/grok.json
set_world() {  # <8317 http code> <ccflare routable> <grok pct>
  printf '%s\n' "$1" > "$WORK/probe_code"
  printf '{"pool":{"routable":%s,"configured":11}}\n' "$2" > "$HEALTH"
  printf '[{"name":"acct-alpha","requiresReauth":true},{"name":"acct-beta","requiresReauth":true},{"name":"acct-ok","requiresReauth":false}]\n' > "$ACCOUNTS"
  printf '{"providers":[{"provider":"grok","quotaSemantics":{"effectiveAvailability":[{"scope":"all_products","effectivePercentRemaining":%s}]}}]}\n' "$3" > "$GROK_JSON"
}

# Orca stub: `terminal list` names the chair's terminal; `terminal send /exit`
# really ends the process in state/.lock; `terminal create` really launches a
# successor (a process named pi), takes the lock for it and beats the watcher.
ORCA=$WORK/orca.sh
ORCA_LOG=$WORK/orca.log
cat > "$ORCA" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_E2E_ORCA_LOG"
case "$1 $2" in
  "terminal list")
    pid=$(cat "$FM_E2E_HOME/state/.lock" 2>/dev/null || echo 0)
    comm=$(ps -o comm= -p "$pid" 2>/dev/null); comm=${comm##*/}
    case "$comm" in
      grok) printf '{"result":{"terminals":[{"handle":"term_grok","worktreePath":"%s","agentIdentity":"grok","title":"grok - firstmate","connected":true}]}}\n' "$FM_E2E_HOME" ;;
      pi)   printf '{"result":{"terminals":[{"handle":"term_pi","worktreePath":"%s","agentIdentity":"pi","title":"π - firstmate","connected":true}]}}\n' "$FM_E2E_HOME" ;;
      *)    printf '{"result":{"terminals":[]}}\n' ;;
    esac ;;
  "terminal send")
    # the harness honours its own exit command: the lock holder exits
    pid=$(cat "$FM_E2E_HOME/state/.lock" 2>/dev/null || echo 0)
    kill "$pid" 2>/dev/null
    printf '{"result":{}}\n' ;;
  "terminal read")
    printf '{"result":{"terminal":{"tail":["claude-fable-5-1  12.0%%/1.0M"]}}}\n' ;;
  "terminal create")
    # record the exact launch command, then start the successor
    # detach stdio: the real Orca answers at once; a successor that inherited
    # the actuator's capture pipe would hold `terminal create` open
    "$FM_E2E_FAKEBIN/pi" 600 >/dev/null 2>&1 </dev/null & new=$!
    printf '%s\n' "$new" > "$FM_E2E_HOME/state/.lock"
    sleep 1; touch "$FM_E2E_HOME/state/.last-watcher-beat"
    printf '{"result":{"terminal":{"handle":"term_pi"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
chmod +x "$ORCA"

# Orca reports resolved paths; the sentinel resolves the home with pwd -P too
export FM_E2E_HOME="$(cd "$HOME_DIR" && pwd -P)" FM_E2E_FAKEBIN="$FAKEBIN" FM_E2E_ORCA_LOG="$ORCA_LOG" FM_E2E_PROBE_CODE_FILE="$WORK/probe_code"
export FM_CHAIR_8317_KEY_FILE="$WORK/api_key" FM_CHAIR_PROBE_CMD="$PROBE"
export FM_CHAIR_CCFLARE_FIXTURE=1 FM_CHAIR_CCFLARE_HEALTH_JSON="$HEALTH" FM_CHAIR_CCFLARE_ACCOUNTS_JSON="$ACCOUNTS"
export FM_CHAIR_GROK_JSON="$GROK_JSON"
export FM_CHAIR_STATUS_ORCA_CMD="$ORCA" FM_CHAIR_FLIP_ORCA_CMD="$ORCA"
export FM_CHAIR_HYSTERESIS_SECS=2 FM_CHAIR_EXIT_WAIT_SECS=10 FM_CHAIR_VERIFY_SECS=20
export FM_CHAIR_SENTINEL_HOME="$HOME_DIR" FM_HOME="$FM_E2E_HOME"

say() { printf '\n=== %s ===\n' "$*"; }
show_lock() {
  local pid; pid=$(cat "$HOME_DIR/state/.lock" 2>/dev/null || echo none)
  printf 'state/.lock -> pid %s (%s)\n' "$pid" "$(ps -o comm= -p "$pid" 2>/dev/null || echo dead)"
}

# --- Scenario 1: the captain's report --------------------------------------
say "Scenario 1: Grok is the chair and SuperGrok has run out of tokens (0%); the 8317 token pool answers Fable (HTTP 200)"
# launched from a subshell so it is reparented to launchd and really exits
# (a direct child would linger as a zombie, which kill -0 still reports alive)
GROK_PID=$( "$FAKEBIN/grok" 600 >/dev/null 2>&1 </dev/null & echo $! )
printf '%s\n' "$GROK_PID" > "$HOME_DIR/state/.lock"
printf 'running: reprice ticker batch 7\n' > "$HOME_DIR/state/task-reprice.status"
set_world 200 0 0
show_lock
printf '\n$ bin/fm-chair-runway.sh\n'; "$ROOT/bin/fm-chair-runway.sh"
printf '\n$ bin/fm-chair-status.sh\n'; "$ROOT/bin/fm-chair-status.sh"
printf '\n$ bin/fm-chair-sentinel.sh   (one tick, live actuator)\n'
"$ROOT/bin/fm-chair-sentinel.sh"; printf 'exit=%s\n' "$?"
printf '\n--- Orca calls the actuator made, in order ---\n'; cat "$ORCA_LOG"
printf '\n--- after the flip ---\n'; show_lock
kill -0 "$GROK_PID" 2>/dev/null && echo "grok pid $GROK_PID: STILL ALIVE" || echo "grok pid $GROK_PID: ended"
printf 'state/.chair-source: %s\n' "$(cat "$HOME_DIR/state/.chair-source")"
printf 'handoff files: %s\n' "$(ls "$HOME_DIR/data"/handoff-*.md | xargs -n1 basename)"
cp "$HOME_DIR/data/handoff-grok-to-pi-fable.md" "$EVID/handoff-grok-to-pi-fable.md"

# --- Scenario 2: next tick, the Pi chair is on its green source ---------------
say "Scenario 2: next tick - the successor Pi holds the lock and its source is the green 8317 pool"
: > "$ORCA_LOG"
printf '$ bin/fm-chair-status.sh\n'; "$ROOT/bin/fm-chair-status.sh"
printf '$ bin/fm-chair-sentinel.sh\n'; "$ROOT/bin/fm-chair-sentinel.sh"
grep -q "terminal create" "$ORCA_LOG" && echo "UNEXPECTED: a terminal was created" || echo "no terminal created (chair left alone)"

# --- Scenario 3: the pool the chair is bound to goes red, 8080 is green -----
say "Scenario 3: 8317 goes red (HTTP 401) while better-ccflare 8080 is green - the starved Pi is re-seated on 8080"
sleep 2  # past the (test-shortened) hysteresis window
PI1=$(cat "$HOME_DIR/state/.lock")
set_world 401 3 0
: > "$ORCA_LOG"
printf '$ bin/fm-chair-runway.sh\n'; "$ROOT/bin/fm-chair-runway.sh"
printf '$ bin/fm-chair-sentinel.sh\n'; "$ROOT/bin/fm-chair-sentinel.sh"; printf 'exit=%s\n' "$?"
printf '\n--- Orca calls ---\n'; cat "$ORCA_LOG"
kill -0 "$PI1" 2>/dev/null && echo "starved pi pid $PI1: STILL ALIVE" || echo "starved pi pid $PI1: ended"
show_lock
printf 'state/.chair-source: %s\n' "$(cat "$HOME_DIR/state/.chair-source")"

# --- Scenario 4: immediate retry is bounded by hysteresis -------------------
say "Scenario 4: same conditions one second later - the actuator refuses inside the hysteresis window (no flapping)"
set_world 200 0 0   # the chair is now bound to 8080; 8080 red + 8317 green wants a re-seat, but the window is closed
: > "$ORCA_LOG"
FM_CHAIR_HYSTERESIS_SECS=1800 "$ROOT/bin/fm-chair-sentinel.sh"; printf 'exit=%s\n' "$?"
grep -Eq "terminal (send|create)" "$ORCA_LOG" && echo "UNEXPECTED: Orca touched" || echo "no exit sent, no terminal created inside the hysteresis window"

# --- Scenario 5: every tank empty -> alarm naming the accounts ----------------
say "Scenario 5: 8317 red, 8080 red, SuperGrok 0% - no tank: alarm, captain line names the accounts needing login, chair untouched"
set_world 401 0 0
: > "$ORCA_LOG"
"$ROOT/bin/fm-chair-sentinel.sh"; printf 'exit=%s\n' "$?"
printf 'state/.chair-alarm: %s\n' "$(cat "$HOME_DIR/state/.chair-alarm")"
show_lock

# --- Scenario 6: Fable blackout with Grok above floor -> flip to grok ---------
say "Scenario 6: Fable blackout (both pools red) but SuperGrok back at 60% - the Pi chair is handed to Grok"
sleep 2
set_world 401 0 60
: > "$ORCA_LOG"
# the successor for to-grok is a process named grok
cat > "$WORK/orca-grok.sh" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "terminal create" ]; then
  printf '%s\n' "\$*" >> "$ORCA_LOG"
  "$FAKEBIN/grok" 600 >/dev/null 2>&1 </dev/null & new=\$!
  printf '%s\n' "\$new" > "$HOME_DIR/state/.lock"
  sleep 1; touch "$HOME_DIR/state/.last-watcher-beat"
  printf '{"result":{"terminal":{"handle":"term_grok"}}}\n'
  exit 0
fi
exec "$ORCA" "\$@"
SH
chmod +x "$WORK/orca-grok.sh"
PI2=$(cat "$HOME_DIR/state/.lock")
FM_CHAIR_FLIP_ORCA_CMD="$WORK/orca-grok.sh" FM_CHAIR_STATUS_ORCA_CMD="$WORK/orca-grok.sh" "$ROOT/bin/fm-chair-sentinel.sh"; printf 'exit=%s\n' "$?"
printf '\n--- Orca calls ---\n'; cat "$ORCA_LOG"
kill -0 "$PI2" 2>/dev/null && echo "pi pid $PI2: STILL ALIVE" || echo "pi pid $PI2: ended"
show_lock
printf 'state/.chair-source: %s\n' "$(cat "$HOME_DIR/state/.chair-source")"

say "Sentinel decision log (data/chair-sentinel/log.jsonl)"
cat "$HOME_DIR/data/chair-sentinel/log.jsonl"
cp "$HOME_DIR/data/chair-sentinel/log.jsonl" "$EVID/chair-sentinel-log.jsonl"

#!/usr/bin/env bash
# End-to-end operator demo of the one-lane model switch onto the gateway.
# Real bin/fm-lane-model-switch.sh + a real bin/fm-deepseek-gateway.sh, driving
# a fake Orca CLI that records EVERY keystroke sent to a lane, so "nothing was
# typed into that lane" is shown, not asserted.
set -u
ROOT=${ROOT:?}
WORK=${WORK:?}
rm -rf "$WORK"; mkdir -p "$WORK/home/state" "$WORK/home/data" "$WORK/screens"
HOME_DIR="$WORK/home"; STATE="$HOME_DIR/state"; DATA="$HOME_DIR/data"
SCREENS="$WORK/screens"; LOG="$WORK/orca.log"; : > "$LOG"

say()  { printf '\n\033[1m$ %s\033[0m\n' "$*"; }
note() { printf '\n# %s\n' "$*"; }

# --- a fake Orca CLI that records every send --------------------------------
FB="$WORK/fakebin"; mkdir -p "$FB"
cat > "$FB/orca" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'orca'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$FM_ORCA_LOG"
case "${1:-}${2:-}" in
  status*) printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  terminalread)
    n=$(( $(cat "$FM_ORCA_SCREENS/.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FM_ORCA_SCREENS/.count"
    f="$FM_ORCA_SCREENS/$n.json"
    [ -f "$f" ] || { printf '{"ok":false,"error":{"message":"no queued screen %s"}}\n' "$n"; exit 2; }
    cat "$f" ;;
  terminalsend) printf '{"ok":true,"result":{"sent":true}}\n' ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
chmod +x "$FB/orca"

screen() { python3 - "$@" <<'PY'
import json, sys
path, lines = sys.argv[1], sys.argv[2:]
json.dump({"ok": True, "result": {"terminal": {"tail": list(lines)}}}, open(path, "w"))
PY
}
reset_screens() { rm -f "$SCREENS/.count" "$SCREENS"/*.json; }
idle_screens() { local i; for i in 1 2 3; do screen "$SCREENS/$i.json" 'building the release notes' '❯'; done
  for i in 4 5; do screen "$SCREENS/$i.json" 'building the release notes' 'model set to deepseek-v4.1-flash (routed)' '❯'; done; }

meta() { python3 - "$STATE/$1.meta" "$2" "$3" <<'PY'
import sys
path, model, backend = sys.argv[1:4]
name = path.rsplit("/", 1)[1][:-5]
rows = ["endpoint_task_id=%s" % name, "harness=claude", "kind=ship",
        "model=%s" % model, "backend=%s" % backend, "window=fm-%s" % name]
if backend == "orca":
    rows.append("terminal=term-%s" % name)
open(path, "w").write("\n".join(rows) + "\n")
PY
}

# --- a real second gateway on a scratch port --------------------------------
cat > "$WORK/pick.py" <<'PY'
import json, sys
json.dump({"kind":"deepseek","slot":"offpeak","provider":"openrouter",
           "model":"deepseek/deepseek-v4.1-flash","base_url":"http://127.0.0.1:1/api/v1",
           "api_key_cmd":"printf sk-fixture-key","list_in":0.15,"list_out":0.60}, sys.stdout)
PY
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$ROOT/bin/fm-deepseek-gateway.sh" \
  start --port "$PORT" --pick "$WORK/pick.py" > "$WORK/gateway.log" 2>&1 || { cat "$WORK/gateway.log"; exit 1; }
trap 'FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash "$ROOT/bin/fm-deepseek-gateway.sh" stop --force >/dev/null 2>&1' EXIT

sw() { local rc=0
  PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_GATE_REFUSE_BYPASS=1 FM_ORCA_LOG="$LOG" FM_ORCA_SCREENS="$SCREENS" FM_LANE_SWITCH_PAUSE=0.2 FM_LANE_SWITCH_SETTLE=0.1 \
  FM_LANE_SWITCH_SLEEP=0.1 FM_DEEPSEEK_GATEWAY_PORT="$PORT" \
  bash "$ROOT/bin/fm-lane-model-switch.sh" "$@" || rc=$?; echo "exit=$rc"; }

typed_into() { # <lane> - every keystroke this run sent into a lane, from the Orca log
  local n; n=$(grep -c 'terminal send' "$LOG" || true)
  if [ "${n:-0}" = 0 ]; then printf '(no `orca terminal send` at all - nothing was typed into any lane)\n'
  else grep 'terminal send' "$LOG"; fi; }

cat <<'BANNER'
================================================================================
 Rolling one lane onto the DeepSeek gateway - operator walkthrough
 (real bin/fm-lane-model-switch.sh; a fake Orca CLI records every keystroke)

 Run with FM_GATE_REFUSE_BYPASS=1, the documented test-harness escape hatch in
 bin/fm-gate-refuse-lib.sh: this transcript was produced from a no-mistakes gate
 worktree, which the script otherwise refuses to let drive a fleet. Every lane
 below is a scratch fixture under a temp home; no roster lane is touched.
================================================================================
BANNER

# ---------------------------------------------------------------- tick owner
note "THE ROSTER. lane-cron-owner runs Claude Code on Opus 1M and owns /loop wakeups"
note "plus a CronCreate tick; lane-clean owns neither."
meta lane-cron-owner 'opus[1m]' orca
meta lane-clean      'opus[1m]' orca
mkdir -p "$DATA/cmux-takeover" "$DATA/lane-cron-owner"
cat > "$DATA/cmux-takeover/expected-loops.json" <<'JSON'
[{"term": "term-lane-cron-owner", "expected": ["30m drift sweep", "6h fleet digest"]},
 {"term": "term-lane-clean", "expected": []}]
JSON
printf '*/30 * * * *\n' > "$DATA/lane-cron-owner/crons"
say "cat data/cmux-takeover/expected-loops.json"
cat "$DATA/cmux-takeover/expected-loops.json"

note "1. The captain plans the rollout first: which lanes would this home refuse?"
say "for m in state/*.meta; do fm-lane-model-switch.sh <id> gateway --gateway --dry-run; done"
reset_screens; screen "$SCREENS/1.json" 'building the release notes' '❯'
for m in "$STATE"/*.meta; do id=${m##*/}; id=${id%.meta}
  reset_screens; for i in 1 2 3; do screen "$SCREENS/$i.json" 'building the release notes' '❯'; done
  out=$(sw "$id" gateway --gateway --dry-run 2>&1)
  printf '%s\n' "$out" | grep -q 'stays on the shared account pool' \
    && printf '  refused: %s\n' "$id" || printf '  in scope: %s\n' "$id"
done

note "2. The refusal in full - it names the lane, what it owns, and where it stays."
reset_screens; for i in 1 2 3; do screen "$SCREENS/$i.json" 'building the release notes' '❯'; done
say "bin/fm-lane-model-switch.sh lane-cron-owner gateway --gateway"
sw lane-cron-owner gateway --gateway
say "ls state/lane-cron-owner.gateway.env        # nothing was recorded"
ls "$STATE/lane-cron-owner.gateway.env" 2>&1 || true
say "grep model= state/lane-cron-owner.meta      # the lane is still on Opus"
grep '^model' "$STATE/lane-cron-owner.meta"
say "grep 'terminal send' orca.log               # nothing was typed into the lane"
typed_into lane-cron-owner

# ---------------------------------------------------------------- in scope
note "3. An in-scope lane. The repoint is RECORDED for its next launch and the lane is left alone:"
note "   a running Claude Code session reads its endpoint at startup and cannot be repointed in place."
reset_screens; for i in 1 2 3; do screen "$SCREENS/$i.json" 'building the release notes' '❯'; done
say "bin/fm-lane-model-switch.sh lane-clean gateway --gateway"
sw lane-clean gateway --gateway
say "cat state/lane-clean.gateway.env            # what the next launch will read"
sed -e 's/\(ANTHROPIC_AUTH_TOKEN=\).*/\1<local-token-redacted>/' "$STATE/lane-clean.gateway.env"
say "stat -f '%Lp' state/lane-clean.gateway.env  # it carries a token, so 0600"
stat -f '%Lp' "$STATE/lane-clean.gateway.env" 2>/dev/null || stat -c '%a' "$STATE/lane-clean.gateway.env"
say "grep 'terminal send' orca.log               # still nothing typed into any lane"
typed_into lane-clean

# ---------------------------------------------------------------- the switch
note "4. The operator relaunches that lane with the recorded exports. NOW the same command"
note "   switches it in place, because the recorded repoint is the evidence its session is on the gateway."
reset_screens; idle_screens
say "bin/fm-lane-model-switch.sh lane-clean gateway --gateway"
sw lane-clean gateway --gateway
say "grep 'terminal send' orca.log               # exactly what reached the lane"
grep 'terminal send' "$LOG" | sed -e 's/^/  /'
say "cat state/lane-clean.meta                   # the switch is recorded"
grep -E '^(model|model_switch|gateway)' "$STATE/lane-clean.meta"

# ---------------------------------------------------------------- safety
note "5. Safety: a lane whose composer holds unsubmitted text is never typed into."
note "   A dry run over it reports BOTH branches and writes nothing (exit 0)."
meta lane-busy 'opus[1m]' orca
reset_screens; for i in 1 2 3; do screen "$SCREENS/$i.json" 'earlier output' '❯ deploy to prod --now'; done
: > "$LOG"
say "bin/fm-lane-model-switch.sh lane-busy 'deepseek-v4.1-flash' --dry-run"
sw lane-busy 'deepseek-v4.1-flash' --dry-run
say "grep 'terminal send' orca.log               # a dry run types nothing, sends no Ctrl-C"
typed_into lane-busy

note "   And the real run over that same busy composer, when it will not clear:"
reset_screens; for i in 1 2 3 4 5; do screen "$SCREENS/$i.json" 'earlier output' '❯ deploy to prod --now'; done
: > "$LOG"
say "bin/fm-lane-model-switch.sh lane-busy 'deepseek-v4.1-flash'"
sw lane-busy 'deepseek-v4.1-flash'
say "grep 'terminal send' orca.log      # only the Ctrl-C interrupt; no /model, no resume text"
typed_into lane-busy
say "cat data/lane-model-switch/pending-composer/<lane>-<ts>.txt   # the text is saved, not lost"
find "$HOME_DIR/data/lane-model-switch" -name 'lane-busy-*.txt' -print -exec cat {} \; | sed "s|$HOME_DIR|<home>|"

note "6. Nothing in this change switches a roster lane: every lane above is a scratch fixture,"
note "   and the real roster is touched only when an operator runs the command for one lane."

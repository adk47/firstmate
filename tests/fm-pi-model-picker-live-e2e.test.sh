#!/usr/bin/env bash
# Opt-in live guard for the two rendered-surface facts behind Pi's /model
# picker detection (bin/fm-busy-lib.sh fm_busy_pi_tail_model_picker and the
# per-task hook's dialog events in bin/fm-spawn.sh):
#   1. the per-task Pi extension records NO dialog event for the built-in
#      picker (it is an interactive-mode overlay, not an extension ui prompt),
#      which is why the picker must be read from the screen at all;
#   2. the screen the real picker renders is recognised by the multi-signal
#      reader, and an ordinary idle prompt is not.
# It drives the installed Pi through a pseudo-terminal with no model request
# (the picker opens and is cancelled without a turn), so it spends no tokens,
# and it fails naming the Pi version so a vendor change in the picker's rows
# is caught here rather than discovered as a worker nobody noticed was stuck.
# Refresh docs/verification/gateway-keepalive.md from its output.
set -u

if [ "${FM_PI_MODEL_PICKER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_MODEL_PICKER_LIVE_E2E=1 to run the real-Pi /model picker guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found: this guard checks nothing without the harness installed"
command -v python3 >/dev/null 2>&1 || fail "python3 not found; this guard drives Pi through a pseudo-terminal with its pty module"
PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-model-picker.XXXXXX")
cleanup() {
  pkill -f "$LAB/live.pi-ext.ts" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/state" "$LAB/proj"
git -C "$LAB/proj" init -q .
ID=live-picker
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$ID") || fail "could not arm the busy contract"

# The exact extension bin/fm-spawn.sh writes for a Pi task, rendered from its
# own heredoc so this guard cannot drift from production wiring.
sed -n '/^    pi|pi-signed)$/,/^EOF$/p' "$ROOT/bin/fm-spawn.sh" | sed -n '/cat > /,/^EOF$/p' | sed '1d;$d' > "$LAB/ext.tpl"
[ -s "$LAB/ext.tpl" ] || fail "could not extract the Pi extension heredoc from bin/fm-spawn.sh"
FM_ROOT=$ROOT STATE_REAL="$LAB/state" ID=$ID BUSY_GEN=$GEN TURNEND="$LAB/state/$ID.turn-ended" \
  bash -c 'eval "cat <<EOF
$(cat "$1")
EOF"' _ "$LAB/ext.tpl" > "$LAB/live.pi-ext.ts" || fail "could not render the Pi extension"

# Drive Pi on a real pseudo-terminal: wait for the prompt, open the picker,
# wait for its rows to render (bounded), cancel it, quit. The pty is read
# continuously, so a snapshot taken between steps is what the terminal had
# shown by that moment - script(1) was tried first and its buffered typescript
# lagged the screen by several seconds. The busy record is read between steps
# too. Timings are generous for a cold Pi start.
(cd "$LAB/proj" && LAB="$LAB" ID="$ID" python3 - <<'PY') || fail "the pseudo-terminal drive of Pi $PI_VERSION did not complete"
import os, pty, select, signal, sys, time
lab = os.environ["LAB"]; task = os.environ["ID"]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.environ["COLUMNS"] = "120"; os.environ["LINES"] = "40"
    os.execvp("pi", ["pi", "--no-session", "-e", f"{lab}/live.pi-ext.ts"])
buf = bytearray()
def pump(seconds, until=None):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            buf.extend(chunk)
        if until and until in buf:
            return
def settle(max_seconds, quiet=2.0):
    # Wait until output has arrived and then stopped for `quiet` seconds: a
    # cold Pi start loads extensions and skills before it draws the prompt.
    end = time.time() + max_seconds
    last = None
    while time.time() < end:
        before = len(buf)
        pump(0.5)
        if len(buf) != before:
            last = time.time()
        elif last is not None and time.time() - last >= quiet:
            return
def snap(name):
    with open(f"{lab}/{name}", "wb") as f:
        f.write(bytes(buf))
settle(40)
snap("screen-idle.log")
os.write(fd, b"/model"); pump(0.5); os.write(fd, b"\r")
pump(20, until=b"to cancel"); pump(2)
with open(f"{lab}/state/{task}.busy-state") as f, open(f"{lab}/record-while-open", "w") as out:
    out.write(f.read())
snap("screen-open.log")
os.write(fd, b"\x1b"); pump(3)
os.write(fd, b"/quit\r"); pump(4)
try:
    os.kill(pid, signal.SIGTERM)
except ProcessLookupError:
    pass
PY

strip_ansi() {
  perl -pe 's/\e\[[0-9;?]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/\r//g'
}

# What a pane reader sees at each moment: the bytes rendered up to that point,
# of which the reader takes its bounded tail.
screen=$(strip_ansi < "$LAB/screen-open.log" | tr -cd '\11\12\15\40-\176\200-\377')
idle_screen=$(strip_ansi < "$LAB/screen-idle.log" | tr -cd '\11\12\15\40-\176\200-\377')
[ -n "$screen" ] || fail "Pi $PI_VERSION rendered nothing through the pseudo-terminal; the guard checked nothing"
[ -n "$idle_screen" ] || fail "Pi $PI_VERSION had rendered no idle prompt before /model was typed; the guard checked nothing"

# 1. The hook saw no dialog for the built-in picker.
record_open=$(cat "$LAB/record-while-open" 2>/dev/null || true)
case "$record_open" in
  *'event=dialog-open'*) fail "Pi $PI_VERSION now raises ui_prompt_start for the built-in /model picker; the hook records it, so the rendered reader is no longer the only source - update bin/fm-busy-lib.sh's rationale and bin/fm-crew-state.sh" ;;
  '') fail "no busy record was readable while the picker was open on Pi $PI_VERSION" ;;
esac

# 2. The real picker is recognised, through each of its rows independently so
#    a vendor change to one row is reported by name.
printf '%s\n' "$screen" | fm_busy_pi_tail_model_picker \
  || fail "Pi $PI_VERSION's /model picker was not recognised by fm_busy_pi_tail_model_picker; its rows changed"
printf '%s\n' "$screen" | grep -qE 'to select · .* to set as default · .* to cancel' \
  || echo "warn: Pi $PI_VERSION no longer renders the picker hint row; the verdict rests on the other signals"
printf '%s\n' "$screen" | grep -qE 'Model Name: ' \
  || echo "warn: Pi $PI_VERSION no longer renders the Model Name row; the verdict rests on the other signals"
printf '%s\n' "$screen" | grep -qE 'models from configured providers' \
  || echo "warn: Pi $PI_VERSION no longer renders the provider-scope hint; the verdict rests on the other signals"

# 3. An ordinary idle Pi prompt (the screen before the picker opened) is not one.
printf '%s\n' "$idle_screen" | fm_busy_pi_tail_model_picker \
  && fail "an ordinary idle Pi $PI_VERSION prompt was read as the /model picker"

printf 'ok - Pi %s: the built-in /model picker raises no hook dialog event and is recognised from its rendered rows\n' "$PI_VERSION"

#!/usr/bin/env bash
# The durable self-heal on the inbox surface itself: fm-inbox.sh drain (no --ack)
# re-announces an orphaned captain note before printing, so the existing damage is
# visible again and the drain refuses to step past it.
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7S88SNH2BQH3J2511QPY8FA
H=$(mktemp -d /tmp/fm-note-inbox-drain-demo.XXXXXX); mkdir -p "$H/state"
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"
INBOX="$ROOT/bin/fm-inbox.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
echo "=== an orphaned captain note (its wake was already acknowledged) ==="
"$INBOX" note "one of the three that sat 23h+" > /dev/null
id=$(basename "$H"/state/inbox/*.note .note)
awk -F '\t' -v k="inbox:$id" 'NF < 5 || $4 != k { print }' "$H/state/.wake-queue" > "$H/q" && mv "$H/q" "$H/state/.wake-queue"
echo "note waiting: $id"
echo "queue rows: $(wc -l < "$H/state/.wake-queue" | tr -d ' ')  (note is invisible to the queue)"
echo
echo "=== fm-inbox.sh drain re-announces it before printing ==="
"$INBOX" drain > "$H/out" 2> "$H/e"; echo "[exit $?]"; echo "stdout:"; sed 's/^/  /' "$H/out"; echo "stderr:"; sed 's/^/  /' "$H/e"
echo "queue rows: $(wc -l < "$H/state/.wake-queue" | tr -d ' ')"
echo
echo "=== the presented wake now cannot be bare-acknowledged ==="
"$DRAIN" > /dev/null 2> "$H/d"; cat "$H/d"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$H/d" | tail -1)
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$H/d" | tail -1)
"$DRAIN" --ack-through "$seq" --recovery-generation "$gen"; echo "[exit $?]"
echo
echo "=== one command clears both, then the acknowledgement succeeds ==="
"$INBOX" drain --ack "$id"; echo "[exit $?]"
"$DRAIN" --ack-through "$seq" --recovery-generation "$gen"; echo "[exit $?]"
rm -rf "$H"

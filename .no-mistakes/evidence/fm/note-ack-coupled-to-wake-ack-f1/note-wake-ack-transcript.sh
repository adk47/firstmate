#!/usr/bin/env bash
# End-to-end CLI transcript: the note/wake acknowledgement join, starting from the
# exact existing damage (a captain note whose wake was already acknowledged).
set -u
ROOT=/home/aaron/.no-mistakes/worktrees/72295860b10d/01M7S88SNH2BQH3J2511QPY8FA
H=$(mktemp -d /tmp/fm-note-ack-demo.XXXXXX)
mkdir -p "$H/state"
INBOX="$ROOT/bin/fm-inbox.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state"
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

echo "=== Step 0: a captain note arrives (state/inbox/<id>.note + one check wake) ==="
run "$INBOX" note "read the recovery plan before the lease work"
id=$(basename "$H"/state/inbox/*.note .note)
echo "note id: $id"
echo "--- queued wake rows:"; cat "$H/state/.wake-queue"

echo
echo "=== Step 1: reproduce the existing damage - the wake was acknowledged earlier, the note survived ==="
awk -F '\t' -v k="inbox:$id" 'NF < 5 || $4 != k { print }' "$H/state/.wake-queue" > "$H/q" && mv "$H/q" "$H/state/.wake-queue"
echo "wake rows now: $(wc -l < "$H/state/.wake-queue" | tr -d ' ')  (note is invisible to the queue)"

echo
echo "=== Step 2: fm-inbox.sh list self-heals the orphaned captain note ==="
"$INBOX" list > /dev/null 2> "$H/list.err"; echo "[exit $?] stderr:"; cat "$H/list.err"
echo "--- queued wake rows after list:"; cat "$H/state/.wake-queue"

echo
echo "=== Step 3: run list again - the re-announcement is idempotent ==="
"$INBOX" list > /dev/null 2> "$H/list2.err"; echo "[exit $?] stderr:"; cat "$H/list2.err"
echo "inbox:$id rows: $(awk -F '\t' -v k="inbox:$id" 'NF>=5 && $4==k {n++} END{print n+0}' "$H/state/.wake-queue")"

echo
echo "=== Step 4: fm-wake-drain.sh presents the queue ==="
"$DRAIN" > /dev/null 2> "$H/drain.err"; echo "[exit $?] stderr:"; cat "$H/drain.err"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$H/drain.err" | tail -1)
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$H/drain.err" | tail -1)

echo
echo "=== Step 5: a bare acknowledgement is REFUSED, naming the blocking note id ==="
run "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"
echo "--- queue preserved:"; cat "$H/state/.wake-queue"
echo "--- note preserved:"; ls "$H/state/inbox"

echo
echo "=== Step 6: one command clears both records ==="
run "$INBOX" drain --ack "$id"
echo "--- queue now:"; cat "$H/state/.wake-queue"
echo "--- inbox now:"; ls -A "$H/state/inbox"; echo "--- handled:"; ls "$H/state/inbox/handled"

echo
echo "=== Step 7: the same acknowledgement now succeeds ==="
run "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"
echo "--- queue now: $(wc -l < "$H/state/.wake-queue" | tr -d ' ') rows"

echo
echo "=== Step 8: no override flag exists (fail-safe, not fail-open) ==="
run "$INBOX" note "another note that must not be bypassed"
id2=$(basename "$H"/state/inbox/*.note .note)
"$DRAIN" > /dev/null 2> "$H/d2.err"
seq2=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$H/d2.err" | tail -1)
gen2=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$H/d2.err" | tail -1)
run "$DRAIN" --ack-through "$seq2" --recovery-generation "$gen2" --allow-unacked-notes
rm -rf "$H"

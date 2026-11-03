#!/bin/bash
# credit-jan-tray-dm.sh: Jan's daily proof list (FirstMate ruling 1, 3 Nov 2026; parent MUS-27494).
# At 07:00 UTC the cron rebuilds the doc-verify tray, reads the claims where the document proves
# it (jan-proves-b<batch>.json, written by `credit-doc-verify.py tray`) and DMs them to Jan
# (Head of Operations, U038BM16T7W) as the operations bot, so he never has to open a file on
# node-8. READ-ONLY: it approves nothing, writes no request status, sends nothing to a customer.
# Jan opens each document and decides each request himself in Muso admin, one at a time.
# Runbook for Jan: docs/credit-verification/jan-daily-proof-list.md
#
#   - Output: the tray's files go to JAN_TRAY_OUT_DIR; this script's own state to JAN_TRAY_STATE_DIR.
#     Nothing else is written.
#   - Once per UTC day (lock + marker). The day's list is frozen in a snapshot and its chunk
#     progress is kept, so a retry after a half-delivered list resumes that same list.
#   - 20 rows per message; more than 100 rows = the first 100 plus a count of the rest. Claims not
#     yet sent to Jan come first (delivered-ids ledger), so the rest reach him on a later day.
#   - Zero rows = one short "nothing to review" DM (Jan must know the list ran). A failed tray
#     build or an unreadable list is NEVER reported as "nothing today": one line, exit 1.
#   - Kill switch /etc/hydra/credit-jan-tray-dm.disabled (read only; this script never creates it).
# Stdout is the cron's announce channel: NO_REPLY when quiet; one line on a failure.
set -euo pipefail

KILL="${JAN_TRAY_KILL_SWITCH:-/etc/hydra/credit-jan-tray-dm.disabled}"
STATE_DIR="${JAN_TRAY_STATE_DIR:-/var/lib/hydra/credit-jan-tray-dm}"
OUT_DIR="${JAN_TRAY_OUT_DIR:-/var/lib/hydra-credit-verify/jan-tray}"
PYTHON="${JAN_TRAY_PYTHON:-python3}"
VERIFY="${JAN_TRAY_VERIFY:-/opt/hydra/scripts/credit-doc-verify.py}"
SLACK_LIB="${JAN_TRAY_SLACK_LIB:-/opt/hydra/scripts/lib/slack-notify.sh}"
JAN_UID="U038BM16T7W"
CHUNK=20
MAX_ROWS=100

say() { printf '%s\n' "$*"; }
fail() { say "Jan's proof list NOT sent: $*"; exit 1; }

if [ -e "$KILL" ]; then say "NO_REPLY"; exit 0; fi
DAY="${JAN_TRAY_DAY:-$(date -u +%Y%m%d)}"  # JAN_TRAY_DAY: test hook for a second day
mkdir -p "$STATE_DIR"
LOCK="$STATE_DIR/.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -w 300 9 || fail "another run held the lock for 5 minutes"
else
  for _ in $(seq 1 300); do mkdir "$LOCK.d" 2>/dev/null && break; sleep 1; done
  [ -d "$LOCK.d" ] || fail "another run held the lock for 5 minutes"
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rmdir "$LOCK.d" 2>/dev/null || true' EXIT
if [ -e "$STATE_DIR/sent-$DAY" ]; then say "NO_REPLY"; exit 0; fi

SNAP="$STATE_DIR/snapshot-$DAY.json"
LEDGER="$STATE_DIR/delivered-ids"
DATE_H="${DAY:0:4}-${DAY:4:2}-${DAY:6:2}"
if [ ! -s "$SNAP" ]; then
  mkdir -p "$OUT_DIR"
  "$PYTHON" "$VERIFY" tray --out-dir "$OUT_DIR" --batch "$DAY" >"$TMP/tray.out" 2>&1 \
    || fail "the daily build failed ($(tail -n 1 "$TMP/tray.out" | head -c 200))"
  LIST="$OUT_DIR/jan-proves-b$DAY.json"
  [ -r "$LIST" ] || fail "the build wrote no list for $DAY"
  jq -e 'type == "array"' "$LIST" >/dev/null 2>&1 || fail "the list for $DAY cannot be read"
  touch "$LEDGER"
  # Claims Jan has not been sent yet go first, so rows past the daily cap reach him on a later day
  # even while the earlier ones stay open. The chosen rows are frozen in the day's snapshot: a
  # retry after a half-delivered list resumes that exact list, not a rebuilt one.
  jq -n --slurpfile rows "$LIST" --rawfile seen "$LEDGER" --argjson max "$MAX_ROWS" '
    ($seen | split("\n")) as $s
    | $rows[0] as $r
    | ([$r[] | select((.request_id | tostring) as $i | $s | index($i) | not)]
       + [$r[] | select((.request_id | tostring) as $i | $s | index($i))]) as $ordered
    | {total: ($r | length), rows: $ordered[:$max]}' > "$TMP/snapshot.json" || fail "the list for $DAY cannot be read"
  mv "$TMP/snapshot.json" "$SNAP"
  rm -f "$STATE_DIR/parts-$DAY"
fi

TOTAL="$(jq '.total' "$SNAP")"
SHOWN="$(jq '.rows | length' "$SNAP")"
PARTS=$(( (SHOWN + CHUNK - 1) / CHUNK )); [ "$PARTS" -ge 1 ] || PARTS=1

# One Slack line per row; the text fields are escaped for Slack.
esc='gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")'
message() {  # $1 = part number (1-based)
  jq -r --argjson part "$1" --argjson parts "$PARTS" --argjson total "$TOTAL" --argjson shown "$SHOWN" \
    --argjson chunk "$CHUNK" --arg date "$DATE_H" '
    def e: (. // "" | tostring | '"$esc"');
    def doc: if (.link // "") != "" then "<" + (.link | tostring) + "|document>"
             elif (.intake_id // "") != "" then "filing " + (.intake_id | e)
             else "no document link" end;
    (if $total == 0 then "Claims where the document proves it (\($date)): nothing to review today."
     elif $part == 1 then "Claims where the document proves it (\($date)): \($total). Check each document, then decide it yourself in Muso admin, one at a time."
     else "Claims where the document proves it (\($date)), part \($part) of \($parts)." end),
    (.rows[($part - 1) * $chunk : $part * $chunk][]
      | "• " + (.track | e) + " | " + (.contributor | e) + " | " + (.role | e) + " | " + (.doc_type | e) + " from " + (.issuer | e)
        + " | " + doc + " | request " + (.request_id | e)),
    (if $part == $parts and $total > $shown then "\($total - $shown) more not shown today." else empty end)
  ' "$SNAP"
}

export SLACK_NOTIFY_BOT=operations SLACK_NOTIFY_REQUESTER="credit-jan-tray-dm@hydra-ops"
# shellcheck source=/dev/null
. "$SLACK_LIB"
DONE_FILE="$STATE_DIR/parts-$DAY"
DONE="$(cat "$DONE_FILE" 2>/dev/null || echo 0)"
case "$DONE" in ''|*[!0-9]*) DONE=0 ;; esac
part=$((DONE + 1))
while [ "$part" -le "$PARTS" ]; do
  message "$part" | jq -Rs --arg ch "$JAN_UID" '{channel: $ch, text: rtrimstr("\n"), unfurl_links: false}' > "$TMP/payload.json"
  slack_notify_payload_file_status "$TMP/payload.json" || fail "Slack did not confirm part $part of $PARTS"
  echo "$part" > "$DONE_FILE"
  part=$((part + 1))
done
: > "$STATE_DIR/sent-$DAY"
jq -r '.rows[].request_id | tostring' "$SNAP" >> "$LEDGER"
rm -f "$DONE_FILE" "$SNAP"
say "NO_REPLY"

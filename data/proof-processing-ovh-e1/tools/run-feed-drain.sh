#!/bin/bash
# proof-processing-ovh-e1 (2026-11-13): supervised drain of the document feeder's backlog from a scratch copy of
# this branch, on the production state and store. Back-to-back runs of `credit-proof.py file-recent --apply`
# until nothing is carried. It honours every kill file the deployed callers honour and creates and removes none.
# It stops on: a kill file, a quota signal in a run's output, a non-zero exit, an empty carry, MAX_RUNS, or
# MAX_WAITS minutes spent waiting for another run's lock (a wait is not a run: the deployed cron's own pass can
# hold the lock for 50 minutes, and counting those minutes as runs ended the first drain early).
# Undo: kill this script; the next deployed run reads the same state file (a killed run loses nothing).
set -uo pipefail
ROOT=/root/proof-e1
STATE=/var/lib/hydra-credit-verify/proof-file-state.json
LOG=$ROOT/drain-$(date -u +%Y%m%dT%H%M%SZ).log
now() { date -u +%FT%TZ; }
carry() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(len(s.get("carry") or []), len(s.get("carry_messages") or []))' "$STATE"; }
set -a; . /etc/openclaw/main.env; set +a
cd "$ROOT" || exit 1
echo "$(now) drain start $(cat SOURCE-SHA) max_fetches=${MAX_FETCHES:-60} max_messages=${MAX_MESSAGES:-60} max_seconds=${MAX_SECONDS:-2400} carry=$(carry)" >> "$LOG"
n=0; waits=0
while [ "$n" -lt "${MAX_RUNS:-10}" ]; do
  for k in /etc/hydra/cs-proof-feed.disabled /etc/hydra/gmail-readers.disabled /etc/hydra/credit-verify.disabled /etc/hydra/credit-doc-intake.disabled; do
    if [ -e "$k" ]; then echo "$(now) stop: $k present" >> "$LOG"; exit 0; fi
  done
  out=$(python3 scripts/credit-proof.py file-recent --apply --max-fetches "${MAX_FETCHES:-60}" --max-messages "${MAX_MESSAGES:-60}" --max-seconds "${MAX_SECONDS:-2400}" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'run is in flight'; then
    waits=$((waits + 1))
    [ "$waits" -le "${MAX_WAITS:-180}" ] || { echo "$(now) stop: MAX_WAITS" >> "$LOG"; exit 0; }
    [ $((waits % 10)) -eq 1 ] && echo "$(now) waiting for another run's lock (wait $waits)" >> "$LOG"
    sleep 60; continue
  fi
  n=$((n + 1))
  printf '%s run=%s rc=%s carry=%s\n%s\n' "$(now)" "$n" "$rc" "$(carry)" "$out" >> "$LOG"
  if printf '%s' "$out" | grep -qiE 'rateLimitExceeded|QUOTA SATURATED|quota exceeded|Retry after|(HTTP|status|error|rate)[^0-9]{0,8}429'; then
    echo "$(now) stop: quota signal" >> "$LOG"; exit 3
  fi
  [ "$rc" -eq 0 ] || { echo "$(now) stop: rc=$rc" >> "$LOG"; exit "$rc"; }
  [ "$(carry)" = "0 0" ] && { echo "$(now) done: nothing carried" >> "$LOG"; exit 0; }
done
echo "$(now) stop: MAX_RUNS" >> "$LOG"

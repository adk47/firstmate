#!/bin/bash
# usage: gmail_scan.sh <prefix> <gmail query>   (read-only, paced, backoff on rate limit)
# support@muso.ai search for the proof-on-file feed (gmail_proof.py). Was /root/fmc1-gmail/scan.sh on
# node-8 (cs-systemic-issues-lane-c1); codified 2026-10-26 by ops-to-ovh-m1. Pages land in
# $CS_PROOF_GMAIL_DIR as <prefix>-<n>.json; the last line of <prefix>.log is "DONE pages=N" only when
# the scan finished. --timezone UTC: gog prints dates in host-local time by default, and
# gmail_proof.py / proof_export.py read them as UTC (proof_at). gog's credentials come from /etc/openclaw/main.env (never printed).
set -u
# The ONE support@ Gmail readers kill file (#1569; a constant, never an env var - r5 [key=unattended]). Present =
# no gog call at all; the scan does not finish (no DONE line), so cs-gmail stays stale and its gate holds.
GMAIL_READERS_KILL="/etc/hydra/gmail-readers.disabled"
if [ -e "$GMAIL_READERS_KILL" ]; then
  echo "support@ Gmail readers disabled ($GMAIL_READERS_KILL): no scan" >&2
  exit 4
fi
# CS_PROOF_ENV / CS_PROOF_GOG exist for the tests (a CI runner may itself hold the real env file and
# gog: the tests must never reach the real mailbox).
ENV_FILE="${CS_PROOF_ENV:-/etc/openclaw/main.env}"
# shellcheck source=/dev/null  # host secrets file, not in the repo
[ -r "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }
GOG="${CS_PROOF_GOG:-gog}"
O="${CS_PROOF_GMAIL_DIR:-/var/lib/hydra/cs-proof-feed/gmail}"; P="${1:-}"; Q="${2:-}"; TOK=""; n=0
ACCOUNT="${CS_PROOF_GMAIL_ACCOUNT:-support@muso.ai}"
PAGE_OK='import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d, dict) and isinstance(d.get("messages"), list) else 1)'
case "$P" in ""|*[!A-Za-z0-9]*) echo "bad prefix" >&2; exit 2 ;; esac
mkdir -p "$O"; rm -f "$O/$P"-*.json; echo "$(date -u +%FT%TZ) start $P" >> "$O/$P.log"
while :; do
  out=""
  for try in 1 2 3 4 5 6; do
    # A page counts only when gog exited 0 AND printed a result page ({"messages": [...]}, an
    # empty list on no matches). A failed search that prints a JSON error object must never be
    # written as a page, or the scan ends DONE with nothing in it and cs-gmail looks fresh (QA #1391).
    if [ -n "$TOK" ]; then
      out=$("$GOG" gmail messages search --account "$ACCOUNT" "$Q" --max 100 --page "$TOK" --json --timezone UTC 2>"$O/$P.err"); grc=$?
    else
      out=$("$GOG" gmail messages search --account "$ACCOUNT" "$Q" --max 100 --json --timezone UTC 2>"$O/$P.err"); grc=$?
    fi
    [ "$grc" -eq 0 ] && echo "$out" | python3 -c "$PAGE_OK" 2>/dev/null && break
    out=""; echo "$(date -u +%FT%TZ) retry $try (gog rc=$grc): $(head -c 120 "$O/$P.err")" >> "$O/$P.log"; sleep $((${CS_PROOF_GMAIL_BACKOFF:-45}*try))
  done
  [ -z "$out" ] && { echo "$(date -u +%FT%TZ) FAILED page $n" >> "$O/$P.log"; exit 1; }
  echo "$out" > "$O/$P-$n.json"; n=$((n+1))
  TOK=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('nextPageToken') or '')")
  [ -z "$TOK" ] && { echo "$(date -u +%FT%TZ) DONE pages=$n" >> "$O/$P.log"; exit 0; }
  sleep "${CS_PROOF_GMAIL_PAGE_PAUSE:-20}"
done

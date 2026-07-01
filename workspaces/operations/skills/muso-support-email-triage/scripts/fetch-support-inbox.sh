#!/usr/bin/env bash
# Phase 1 fetch (deterministic). Reads the last ${SUPPORT_TRIAGE_WINDOW_MIN:-65}
# minutes of inbox mail for support@muso.ai via gog and writes
# ${WORKDIR}/emails.json as an array of {threadId, from, subject, date,
# body_excerpt, url}, deduped by threadId (one entry per thread, keeping the
# most-recent message).
#
# Window note: Gmail's `newer_than:` only accepts d/m/y units (`65m` would mean
# 65 MONTHS), so the window is bounded with `after:<epoch-seconds>` instead —
# minute-precise and fully deterministic. Verified live on node-8 against
# a@muso.ai (read-only) 2026-06-10: a 90-min epoch cutoff included only the
# messages after the cutoff and excluded same-day older ones.
#
# Requires $WORKDIR exported by preflight.sh (source it first).
#
# Field-key note: `gog gmail messages search --json --include-body` returns
# {"messages":[{id,threadId,date,from,subject,labels,body}, ...]}. The body key
# is `body`, a decoded plain-text string. There is NO permalink field, so the
# Gmail URL is built here from threadId using an authuser anchor (independent of
# the clicker's multi-login index). Verified live on node-8 against a@muso.ai
# (read-only) 2026-06-05.

set -euo pipefail

: "${WORKDIR:?WORKDIR not set — source preflight.sh first}"
WINDOW_MIN="${SUPPORT_TRIAGE_WINDOW_MIN:-65}"
case "$WINDOW_MIN" in
  ''|*[!0-9]*) echo "fetch-support-inbox: SUPPORT_TRIAGE_WINDOW_MIN must be a positive integer (minutes), got: ${WINDOW_MIN}" >&2; exit 1 ;;
esac
AFTER_EPOCH=$(( $(date +%s) - WINDOW_MIN * 60 ))
ACCOUNT="support@muso.ai"
OUT="${WORKDIR}/emails.json"
RAW="${WORKDIR}/search-raw.json"

# Fetch. --no-input keeps gog non-interactive in a cron/agent context.
gog gmail messages search "in:inbox after:${AFTER_EPOCH}" \
  --account "$ACCOUNT" \
  --max 50 \
  --json \
  --include-body \
  --no-input \
  > "$RAW"

# Parse + dedupe-by-thread + build url + excerpt body. All deterministic in
# python3 (no LLM). gog sorts newest-first; we keep the FIRST message seen per
# threadId, which is therefore the most-recent one.
python3 - "$RAW" "$OUT" "$ACCOUNT" <<'PY'
import sys, json, re

raw_path, out_path, account = sys.argv[1], sys.argv[2], sys.argv[3]

with open(raw_path) as f:
    data = json.load(f)

messages = data.get("messages") or []

def excerpt(body):
    # Decode is already done by gog (body is plain text). Collapse all
    # whitespace runs to single spaces and truncate to ~800 chars.
    if not body:
        return ""
    collapsed = re.sub(r"\s+", " ", str(body)).strip()
    return collapsed[:800]

seen = {}
order = []
for m in messages:
    tid = m.get("threadId")
    if not tid:
        continue
    if tid in seen:
        # Already have the most-recent message for this thread (gog is
        # newest-first); skip older messages in the same thread.
        continue
    seen[tid] = {
        "threadId": tid,
        "from": m.get("from") or "",
        "subject": m.get("subject") or "(no subject)",
        "date": m.get("date") or "",
        "body_excerpt": excerpt(m.get("body")),
        # authuser anchor => URL is independent of the clicker's multi-login index.
        "url": "https://mail.google.com/mail/u/?authuser=%s#all/%s" % (account, tid),
    }
    order.append(tid)

emails = [seen[t] for t in order]
with open(out_path, "w") as f:
    json.dump(emails, f, ensure_ascii=False, indent=2)

print("fetched %d message(s) -> %d thread(s)" % (len(messages), len(emails)), file=sys.stderr)
PY

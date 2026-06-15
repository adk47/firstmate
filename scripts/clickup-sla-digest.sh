#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ClickUp SLA Digest
#
# Posts a daily digest to #cs_chats (C0ANM0PN9L5) of open ClickUp
# support tickets whose SLA due date is overdue, due today, or due
# tomorrow (date boundaries in America/New_York, matching the 08:00
# NYC firing time). Due dates are set at ticket creation from the
# SLA tier (plugins/*/ticket-format.ts slaDueDateMs) — this script
# only reads them back and surfaces the ones that need attention.
#
# Deliberately a deterministic bash job — NOT an openclaw cron — so
# it fires even when the gateway is down and never depends on an LLM
# (same shape as prod-log-alert-watchdog.sh).
#
# Runs daily 08:00 America/New_York via clickup-sla-digest.timer on
# node-8 (installed idempotently by scripts/install-aux-units.sh).
# If every bucket is empty, nothing is posted (silent day).
#
# Flags:
#   --dry-run   print the digest to stdout, do NOT post to Slack
#
# Env knobs (mainly for tests):
#   CLICKUP_API_KEY      ClickUp personal API token (required)
#   CLICKUP_LIST_ID      list to scan (default 901000600160, hydra-action-request)
#   CLICKUP_API          API base (default https://api.clickup.com/api/v2)
#   SLA_DIGEST_CHANNEL   target channel (default C0ANM0PN9L5 #cs_chats)
#   SLA_DIGEST_BOT       muso slack bot identity (default operations — the
#                        "Ops" app that posts the other #cs_chats digests)
#   SLA_DIGEST_TZ        bucketing timezone (default America/New_York)
#   SLA_DIGEST_NOW       epoch-seconds override for "now" (tests)
#   PAGINATION_CAP       max ClickUp pages (default 20)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
. "$_DIR/lib/slack-notify.sh"

dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: clickup-sla-digest.sh [--dry-run]

Posts overdue / due-today / due-tomorrow open ClickUp tickets to
#cs_chats. --dry-run prints the digest without posting.
EOF
      exit 0
      ;;
    *) echo "clickup-sla-digest: unknown flag: $1" >&2; exit 1 ;;
  esac
done

clickup_api="${CLICKUP_API:-https://api.clickup.com/api/v2}"
list_id="${CLICKUP_LIST_ID:-901000600160}"
api_key="${CLICKUP_API_KEY:-}"
channel="${SLA_DIGEST_CHANNEL:-C0ANM0PN9L5}"
bot="${SLA_DIGEST_BOT:-operations}"
tz="${SLA_DIGEST_TZ:-America/New_York}"
now="${SLA_DIGEST_NOW:-$(date +%s)}"
pagination_cap="${PAGINATION_CAP:-20}"
[ -n "$api_key" ] || { echo "clickup-sla-digest: CLICKUP_API_KEY not set" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Day boundaries in $tz, as ClickUp ms epochs. Computed via calendar
# arithmetic on the local date string (not now+86400) so DST shift days
# bucket correctly.
today=$(TZ=$tz date -d "@$now" +%F)
start_today_ms=$(( $(TZ=$tz date -d "$today 00:00" +%s) * 1000 ))
start_tomorrow_ms=$(( $(TZ=$tz date -d "$today 00:00 next day" +%s) * 1000 ))
start_after_ms=$(( $(TZ=$tz date -d "$today 00:00 2 days" +%s) * 1000 ))

# Curl wrapper that fails loud on non-2xx — refuses to keep going on 4xx/5xx.
clickup_curl() {
  local path="$1"
  local body_file; body_file=$(mktemp)
  local code
  code=$(curl -sS --connect-timeout 10 --max-time 30 -H "Authorization: $api_key" \
    -w '%{http_code}' \
    -o "$body_file" \
    "$clickup_api$path")
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "clickup-sla-digest: ClickUp GET $path returned HTTP $code: $(head -c 500 "$body_file")" >&2
    rm -f "$body_file"
    return 1
  fi
  cat "$body_file"
  rm -f "$body_file"
}

# Pull open tickets with a due date before the end of tomorrow. The
# due_date_lt filter is server-side — without it the shared support list
# (2000+ open tasks) blows straight through the pagination cap.
# include_closed=false drops "closed"-type statuses server-side; the jq
# filter also drops "done"-type ones (resolved/impossible etc.), which
# ClickUp still returns.
: > "$tmp/due.jsonl"
page=0
while :; do
  resp=$(clickup_curl "/list/$list_id/task?archived=false&include_closed=false&page=$page&order_by=due_date&due_date_lt=$start_after_ms") || exit 5
  # A 200 with no `tasks` array (e.g. a ClickUp `{"err":...}` envelope) must NOT
  # be read as "nothing due" — that would silently skip a day of overdue tickets.
  # Fail loud instead; only a genuine empty array ends the scan.
  n=$(echo "$resp" | jq 'if (.tasks | type) == "array" then (.tasks | length) else -1 end')
  if [ "$n" -lt 0 ]; then
    echo "clickup-sla-digest: unexpected ClickUp response (no tasks array): $(echo "$resp" | head -c 300)" >&2
    exit 5
  fi
  [ "$n" -eq 0 ] && break
  echo "$resp" | jq -c \
    --argjson start_today "$start_today_ms" \
    --argjson start_tomorrow "$start_tomorrow_ms" \
    --argjson start_after "$start_after_ms" '
    .tasks[]
    | select(.status.type != "closed" and .status.type != "done")
    | select(.due_date != null)
    | (.due_date | tonumber) as $due
    | select($due < $start_after)
    | {
        name, url,
        status: .status.status,
        due: $due,
        bucket: (if $due < $start_today then "overdue"
                 elif $due < $start_tomorrow then "today"
                 else "tomorrow" end),
        days_overdue: (if $due < $start_today
                       then ((($start_today - $due) / 86400000) + 0.5 | floor)
                       else 0 end)
      }
  ' >> "$tmp/due.jsonl"
  [ "$(echo "$resp" | jq '.last_page == true')" = "true" ] && break
  page=$((page+1))
  if [ "$page" -ge "$pagination_cap" ]; then
    echo "clickup-sla-digest: PAGINATION_CAP=$pagination_cap pages reached (~$((pagination_cap*100)) tasks)." >&2
    echo "clickup-sla-digest: re-run with PAGINATION_CAP=<N> if this is intended." >&2
    exit 6
  fi
done

total=$(wc -l < "$tmp/due.jsonl" | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo "clickup-sla-digest: nothing due through tomorrow — no post"
  exit 0
fi

# Render the mrkdwn digest. One line per ticket: linked name, status,
# and (for overdue) how many days past the SLA it is.
text=$(jq -rs --arg today "$today" '
  # Slack mrkdwn treats & < > as control chars — escape them (& first, so the
  # entities we emit are not themselves re-escaped) and flatten any newlines, so
  # a ticket title cannot break the <url|label> link or the one-line-per-ticket
  # layout in #cs_chats.
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") | gsub("[\\n\\r]+";" ");
  def line: "• <\(.url)|\(.name|esc)> — [\(.status|esc)]"
    + (if .bucket == "overdue" then " — \(.days_overdue)d overdue" else "" end);
  def section($key; $title):
    [.[] | select(.bucket == $key)] as $rows
    | if ($rows | length) == 0 then empty
      else "*\($title) (\($rows | length)):*\n" + ($rows | sort_by(.due) | map(line) | join("\n"))
      end;
  [":hourglass_flowing_sand: *SLA digest — support tickets* (\($today))",
   section("overdue"; ":rotating_light: Overdue"),
   section("today"; "Due today"),
   section("tomorrow"; "Due tomorrow")]
  | join("\n\n")
' "$tmp/due.jsonl")

if [ "$dry_run" -eq 1 ]; then
  printf '%s\n' "$text"
  exit 0
fi

# Post as the operations ("Ops") bot — the same identity that posts the
# Caroline daily/weekly digests and the close-resolved summary to #cs_chats,
# so the SLA digest lands under one consistent CS voice (NOT the devops bot,
# whose home is #clio_devops). slack_load_env (from slack-notify.sh) pulls the
# per-bot token; muso's exit code IS the delivery status (it decodes Slack's
# HTTP-200 ok:false trap), so a non-zero exit means undelivered → fail loud.
slack_load_env "$bot" \
  || { echo "clickup-sla-digest: no MUSO_SLACK_BOT_TOKEN_${bot^^} available — cannot post" >&2; exit 7; }
if ! "$MUSO_BIN" slack send --bot "$bot" --channel "$channel" --text "$text" \
       --no-unfurl --requester "clickup-sla-digest@hydra-ops" >/dev/null 2>&1; then
  echo "clickup-sla-digest: Slack delivery to $channel as $bot FAILED" >&2
  exit 7
fi
echo "clickup-sla-digest: posted digest to $channel as $bot ($total tickets)"

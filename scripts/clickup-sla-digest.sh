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
# The digest is posted as a THREAD: a short glance lands top-level in
# #cs_chats, and the per-bucket detail (overdue / today / tomorrow) is
# nested as threaded replies — one reply per bucket, split into several
# in-thread replies when a bucket is long. This keeps the channel
# scannable instead of a daily wall of text. The glance also carries a
# flow line — how many tickets were opened and closed YESTERDAY across
# the whole support board — for at-a-glance throughput tracking.
#
# Deliberately a deterministic bash job — NOT an openclaw cron — so
# it fires even when the gateway is down and never depends on an LLM
# (same shape as prod-log-alert-watchdog.sh).
#
# Runs daily 08:00 America/New_York via clickup-sla-digest.timer on
# node-8 (installed idempotently by scripts/install-aux-units.sh).
# If every bucket is empty AND nothing was opened/closed yesterday,
# nothing is posted (silent day).
#
# Flags:
#   --dry-run   print the digest (parent + thread replies, delimited)
#               to stdout, do NOT post to Slack
#
# Env knobs (mainly for tests):
#   CLICKUP_API_KEY       ClickUp personal API token (required)
#   CLICKUP_LIST_ID       list to scan (default 901000600160, hydra-action-request)
#   CLICKUP_API           API base (default https://api.clickup.com/api/v2)
#   SLA_DIGEST_CHANNEL    target channel (default C0ANM0PN9L5 #cs_chats)
#   SLA_DIGEST_BOT        muso slack bot identity (default operations — the
#                         "Ops" app that posts the other #cs_chats digests)
#   SLA_DIGEST_TZ         bucketing timezone (default America/New_York)
#   SLA_DIGEST_NOW        epoch-seconds override for "now" (tests)
#   SLA_DIGEST_MAX_CHARS  max chars per threaded bucket reply before it is
#                         split into continuation replies (default 3500)
#   PAGINATION_CAP        max ClickUp pages (default 20)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
. "$_DIR/lib/slack-notify.sh"
# shellcheck source=lib/clickup-muso.sh
. "$_DIR/lib/clickup-muso.sh"   # USE_MUSO_CLI=1 routes ClickUp reads through `muso clickup`

dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: clickup-sla-digest.sh [--dry-run]

Posts overdue / due-today / due-tomorrow open ClickUp tickets to
#cs_chats as a threaded digest (glance + per-bucket replies), with a
yesterday opened/closed flow count. --dry-run prints it without posting.
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
# Per-reply char budget before a bucket is split into continuation replies.
# Slack's chat.postMessage `text` hard limit is ~40000, but clients truncate
# the visible message around 3000-4000 chars; 3500 keeps each threaded reply
# readable without client-side truncation while staying well clear of the API cap.
max_chars="${SLA_DIGEST_MAX_CHARS:-3500}"
pagination_cap="${PAGINATION_CAP:-20}"
[ -n "$api_key" ] || { echo "clickup-sla-digest: CLICKUP_API_KEY not set" >&2; exit 2; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/clickup-sla-digest.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Day boundaries in $tz, as ClickUp ms epochs. Computed via calendar
# arithmetic on the local date string (not now±86400) so DST shift days
# bucket correctly.
today=$(TZ=$tz date -d "@$now" +%F)
start_yesterday_ms=$(( $(TZ=$tz date -d "$today 00:00 1 day ago" +%s) * 1000 ))
start_today_ms=$(( $(TZ=$tz date -d "$today 00:00" +%s) * 1000 ))
start_tomorrow_ms=$(( $(TZ=$tz date -d "$today 00:00 next day" +%s) * 1000 ))
start_after_ms=$(( $(TZ=$tz date -d "$today 00:00 2 days" +%s) * 1000 ))

# Curl wrapper that fails loud on non-2xx — refuses to keep going on 4xx/5xx.
clickup_curl() {
  local path="$1"
  if [ "${USE_MUSO_CLI:-0}" = 1 ]; then
    clickup_muso GET "$path"   # gated read; same body, fails non-zero on error
    return
  fi
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

# ── Yesterday flow counts (opened / closed), whole board ──────────
# A SEPARATE, count-only fetch that never feeds the bucket/render path
# below. include_closed=true is required (the due fetch drops closed
# tasks server-side, so it can never see yesterday's closures). The
# date_updated_gt filter bounds the result to ~1 day of board activity
# (anything created OR closed yesterday was updated >= yesterday-start),
# so this stays well under the pagination cap on the 2000+ task board.
# Counts are best-effort: a failure here is loud but must NOT sink the
# overdue digest (the pre-existing, higher-value feature) — it degrades
# to "n/a". The loud stderr below is the real signal (captured in
# journald); the run also exits 3 (degraded), which flips the systemd
# unit to `failed` so the degradation is visible to `systemctl --failed`.
counts_ok=1
degraded=0
: > "$tmp/counts.jsonl"
cpage=0
while :; do
  if ! cresp=$(clickup_curl "/list/$list_id/task?archived=false&include_closed=true&date_updated_gt=$((start_yesterday_ms - 1))&page=$cpage&order_by=updated"); then
    echo "clickup-sla-digest: yesterday flow-count fetch FAILED — counts shown n/a" >&2
    counts_ok=0; degraded=1
    break
  fi
  # `|| cn=-1` catches a 2xx body that is not parseable JSON (jq exits non-zero):
  # without it cn="" and the `-lt 0` test below errors-to-false, failing OPEN
  # (neither degrades nor breaks). -1 routes a garbage body to the degrade path.
  cn=$(echo "$cresp" | jq 'if (.tasks | type) == "array" then (.tasks | length) else -1 end') || cn=-1
  if [ "$cn" -lt 0 ]; then
    echo "clickup-sla-digest: count fetch — unexpected response (no tasks array): $(echo "$cresp" | head -c 300)" >&2
    counts_ok=0; degraded=1
    break
  fi
  [ "$cn" -eq 0 ] && break
  echo "$cresp" | jq -c '.tasks[] | {date_created, date_closed, date_done}' >> "$tmp/counts.jsonl"
  [ "$(echo "$cresp" | jq '.last_page == true')" = "true" ] && break
  cpage=$((cpage + 1))
  if [ "$cpage" -ge "$pagination_cap" ]; then
    echo "clickup-sla-digest: count fetch hit PAGINATION_CAP=$pagination_cap — counts shown n/a" >&2
    counts_ok=0; degraded=1
    break
  fi
done

opened_yday="n/a"; closed_yday="n/a"
if [ "$counts_ok" -eq 1 ]; then
  # Window precisely in [yesterday_start, today_start). date_* fields are
  # ms-epoch strings; `ms` maps null/absent/non-numeric to -1 (never in window)
  # so one malformed value can't `tonumber`-abort the whole count and silently
  # blank it. "closed" counts both ClickUp status types — date_closed
  # ("closed"-type) OR date_done ("done"-type) — so either resolution path is
  # captured (and a task resolved by both is still counted once).
  opened_yday=$(jq -rs --argjson ys "$start_yesterday_ms" --argjson ts "$start_today_ms" '
    def ms($v): ($v | tonumber? // -1);
    [.[] | select(ms(.date_created) >= $ys and ms(.date_created) < $ts)] | length' "$tmp/counts.jsonl")
  closed_yday=$(jq -rs --argjson ys "$start_yesterday_ms" --argjson ts "$start_today_ms" '
    def ms($v): ($v | tonumber? // -1);
    [.[] | select(
        (ms(.date_closed) >= $ys and ms(.date_closed) < $ts)
        or (ms(.date_done) >= $ys and ms(.date_done) < $ts)
      )] | length' "$tmp/counts.jsonl")
fi

# ── Due tickets (overdue / today / tomorrow) ──────────────────────
# Pull open tickets with a due date before the end of tomorrow. The
# due_date_lt filter is server-side — without it the shared support list
# (2000+ open tasks) blows straight through the pagination cap.
#
# …and `include_closed=false` is NOT sufficient, which is why this digest failed
# every day until 2026-09-17. It drops only statuses of TYPE "closed"; this list
# also defines `done`-type statuses (`resolved`, `impossible`), and ClickUp
# returns those. Measured on list 901000600160: over 5 sampled pages, 321 of 500
# returned tasks (64%) were done/closed-type and discarded by the jq filter
# below — 229 of them `resolved`. The fetch burned its whole page budget on
# tickets it was about to throw away, hit PAGINATION_CAP, and exit 6'd.
#
#   without a status filter : >25 pages, >2600 tasks, never exhausted
#   with    a status filter :   6 pages,   598 tasks
#
# So filter by the list's OWN open statuses, server-side. This scales with OPEN
# ticket count (bounded by team capacity) rather than with all history, which a
# bigger cap would not: raising it to 80 works today and breaks again later.
#
# Read the status names from the list itself rather than hardcoding them — a
# renamed or added status would otherwise silently drop its tickets from the
# digest, which is worse than the cap. If that read fails we proceed UNFILTERED,
# i.e. exactly today's behaviour plus its existing cap warning, rather than
# inventing a new failure mode.
open_status_query=""
if statuses_resp=$(clickup_curl "/list/$list_id"); then
  # NUL/newline-safe: status names contain spaces ("to do", "in progress"), so
  # they are read one per LINE. A `for s in $(…)` word-splits them into garbage
  # and the filter then matches nothing it was meant to.
  while IFS= read -r _st; do
    [ -n "$_st" ] || continue
    open_status_query="${open_status_query}&statuses%5B%5D=$(printf %s "$_st" | jq -sRr @uri)"
  done < <(printf '%s' "$statuses_resp" | jq -r '.statuses[]? | select(.type != "done" and .type != "closed") | .status')
fi
if [ -z "$open_status_query" ]; then
  echo "clickup-sla-digest: could not read open statuses for list $list_id — fetching unfiltered (the PAGINATION_CAP warning below still applies)." >&2
else
  echo "clickup-sla-digest: filtering server-side to $(printf '%s' "$open_status_query" | grep -o 'statuses' | wc -l | tr -d ' ') open status(es)." >&2
fi
# include_closed=false drops "closed"-type statuses server-side; the jq
# filter also drops "done"-type ones (resolved/impossible etc.), which
# ClickUp still returns.
: > "$tmp/due.jsonl"
page=0
while :; do
  resp=$(clickup_curl "/list/$list_id/task?archived=false&include_closed=false&page=$page&order_by=due_date&due_date_lt=${start_after_ms}${open_status_query}") || exit 5
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

# Per-bucket counts for the glance line.
overdue_n=$(jq -rs '[.[] | select(.bucket=="overdue")] | length' "$tmp/due.jsonl")
today_n=$(jq -rs '[.[] | select(.bucket=="today")] | length' "$tmp/due.jsonl")
tomorrow_n=$(jq -rs '[.[] | select(.bucket=="tomorrow")] | length' "$tmp/due.jsonl")

# Nothing actionable AND no flow to report → silent day (preserves the
# original "empty buckets → no post" behavior). A nonzero opened/closed
# count is reason enough to post the glance even when nothing is due.
# (counts_ok==0 alone never forces a post; it was already logged loud.)
flow_nonzero=0
if [ "$counts_ok" -eq 1 ] && { [ "$opened_yday" -gt 0 ] 2>/dev/null || [ "$closed_yday" -gt 0 ] 2>/dev/null; }; then
  flow_nonzero=1
fi
if [ "$total" -eq 0 ] && [ "$flow_nonzero" -eq 0 ]; then
  echo "clickup-sla-digest: nothing due through tomorrow and no flow yesterday — no post"
  exit $(( degraded == 0 ? 0 : 3 ))
fi

# ── Build the parent glance ───────────────────────────────────────
if [ "$counts_ok" -eq 1 ]; then
  flow_line="Yesterday: *${opened_yday}* opened · *${closed_yday}* closed"
else
  flow_line="Yesterday: _opened/closed counts unavailable_"
fi
now_line="Now: *${overdue_n}* overdue · *${today_n}* due today · *${tomorrow_n}* due tomorrow"
[ "$total" -gt 0 ] && now_line="$now_line — _details in thread_"
parent=$(printf ':hourglass_flowing_sand: *SLA digest — support tickets* (%s)\n%s\n%s' \
  "$today" "$flow_line" "$now_line")

# ── Build the per-bucket threaded replies ─────────────────────────
# One section per non-empty bucket, greedily packed into chunks under
# $max_chars so a long bucket becomes several in-thread replies rather
# than one oversized message. Built once and reused by both the dry-run
# print and the live post so they can never diverge.
reply_texts=()    # full reply body (header + lines), one per array slot
reply_labels=()   # short label for the --dry-run delimiter

bucket_section() {  # bucket_section <key> <title> <count>
  # <count> is the bucket's ticket count, already computed for the glance line
  # above — passed in so we don't re-slurp due.jsonl just to recount.
  local key="$1" title="$2" count="$3" lines_json
  [ "$count" -eq 0 ] && return 0
  # Render each ticket to its mrkdwn line (same format as before): linked
  # name, status, and (overdue only) days past SLA. esc neutralizes Slack
  # control chars (& first) and flattens newlines so a hostile/odd ticket
  # title cannot break the <url|label> link or the one-line layout.
  lines_json=$(jq -rs --arg k "$key" '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;") | gsub("[\\n\\r]+";" ");
    def line: "• <\(.url)|\(.name|esc)> — [\(.status|esc)]"
      + (if .bucket == "overdue" then " — \(.days_overdue)d overdue" else "" end);
    [.[] | select(.bucket==$k)] | sort_by(.due) | map(line)
  ' "$tmp/due.jsonl")

  # Greedy pack lines into chunks under $max_chars (avoid mapfile for
  # portability with bash 3.2 on dev machines).
  local chunks=() buf="" ln
  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    if [ -n "$buf" ] && [ $(( ${#buf} + 1 + ${#ln} )) -gt "$max_chars" ]; then
      chunks+=("$buf"); buf="$ln"
    else
      buf="${buf:+$buf$'\n'}$ln"
    fi
  done < <(printf '%s\n' "$lines_json" | jq -r '.[]')
  [ -n "$buf" ] && chunks+=("$buf")

  local m=${#chunks[@]} k=0 hdr
  for body in "${chunks[@]}"; do
    k=$((k+1))
    if [ "$k" -eq 1 ]; then
      hdr="*${title} (${count}):*"
    else
      hdr="*${title} (${count}) — cont. (${k}/${m}):*"
    fi
    reply_texts+=("$(printf '%s\n%s' "$hdr" "$body")")
    if [ "$m" -gt 1 ]; then
      reply_labels+=("${title} (${count}) ${k}/${m}")
    else
      reply_labels+=("${title} (${count})")
    fi
  done
}

bucket_section "overdue"  ":rotating_light: Overdue" "$overdue_n"
bucket_section "today"    "Due today" "$today_n"
bucket_section "tomorrow" "Due tomorrow" "$tomorrow_n"

# ── Dry-run: print parent + delimited replies, never touch Slack ──
if [ "$dry_run" -eq 1 ]; then
  printf '=== PARENT ===\n%s\n' "$parent"
  i=0
  while [ "$i" -lt "${#reply_texts[@]}" ]; do
    printf '=== THREAD: %s ===\n%s\n' "${reply_labels[$i]}" "${reply_texts[$i]}"
    i=$((i+1))
  done
  exit 0
fi

# ── Post for real ─────────────────────────────────────────────────
# Post as the operations ("Ops") bot — the same identity that posts the
# Caroline daily/weekly digests and the close-resolved summary to #cs_chats,
# so the SLA digest lands under one consistent CS voice (NOT the devops bot,
# whose home is #clio_devops). slack_load_env (from slack-notify.sh) pulls the
# per-bot token; muso's exit code IS the delivery status (it decodes Slack's
# HTTP-200 ok:false trap), so a non-zero exit means undelivered → fail loud.
slack_load_env "$bot" \
  || { echo "clickup-sla-digest: no MUSO_SLACK_BOT_TOKEN_${bot^^} available — cannot post" >&2; exit 7; }

# send_msg <text> [thread_ts] → echoes the posted message ts, empty on failure.
# --json makes muso return {channel, ts}; the ts anchors the thread.
send_msg() {
  local text="$1" thread="${2:-}"
  local args=(slack send --bot "$bot" --channel "$channel" --text "$text" \
    --no-unfurl --json --requester "clickup-sla-digest@hydra-ops")
  [ -n "$thread" ] && args+=(--thread-ts "$thread")
  local resp
  resp="$("$MUSO_BIN" "${args[@]}")" || return 1
  printf '%s' "$resp" | jq -r '.ts // empty' 2>/dev/null
}

parent_ts=$(send_msg "$parent") || true
if [ -z "$parent_ts" ]; then
  echo "clickup-sla-digest: parent Slack delivery to $channel as $bot FAILED — nothing posted" >&2
  exit 7
fi

# Thread every bucket reply under the parent. A failed reply is loud
# (stderr → journald) and marks the run degraded (exit 3), but we keep
# posting the rest — the glance already landed, so partial detail beats none.
posted_replies=0
i=0
while [ "$i" -lt "${#reply_texts[@]}" ]; do
  # Count a reply delivered only if muso succeeded AND returned a ts — same
  # guard the parent uses. `jq '.ts // empty'` exits 0 even on a ts-less body,
  # so checking send_msg's exit status alone would over-report delivery.
  if rts=$(send_msg "${reply_texts[$i]}" "$parent_ts") && [ -n "$rts" ]; then
    posted_replies=$((posted_replies+1))
  else
    echo "clickup-sla-digest: thread reply '${reply_labels[$i]}' FAILED to deliver" >&2
    degraded=1
  fi
  i=$((i+1))
done

echo "clickup-sla-digest: posted glance + $posted_replies/${#reply_texts[@]} thread replies to $channel as $bot ($total due; yesterday ${opened_yday} opened/${closed_yday} closed)"
# Exit 0 = clean; 3 = degraded (count-fetch or a thread reply failed, but the
# glance posted). Kept distinct from the script's other codes — 1 usage error,
# 2 no API key, 5/6 due-fetch failure, 7 parent-post failure.
exit $(( degraded == 0 ? 0 : 3 ))

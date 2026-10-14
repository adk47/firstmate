#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Ads-Inquiry Watchdog
#
# Tags Aaron in #cs_priority whenever a customer files a support ticket
# about BUYING ads with Muso (in-app ad space, packages, sponsorships).
# Born from the 2026-07 Odeholm Audio miss: an in-app-ads sales lead
# came in via Caroline, was filed as support-general, closed as
# answered, and the SLA triage forwarded it to Nick by email — Aaron
# (who owns ads/sales) never saw it. Deliberately a deterministic
# system-cron bash watchdog — NOT an openclaw cron — same shape as
# stale-ticket-watchdog.sh: fires even when the gateway is down and
# never depends on an LLM classifying "this is an ads lead".
#
# Detection model: every tick, page through hydra-action-request tasks
# in the support list — INCLUDING closed ones, because ads leads get
# closed-as-answered ("the team will reach out") — created within the
# lookback window, and keyword-match ads-buying intent on name +
# text_content. Each new match gets one Slack post to #cs_priority
# mentioning Aaron; the task is then tagged `ads-lead-pinged` so it is
# never pinged twice. Fail-loud ordering: the dedupe tag is added only
# after a CONFIRMED Slack post, so a failed post retries next tick.
#
# Runs via /etc/cron.d/ads-inquiry-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh).
#
# Flags:
#   --dry-run   print matches, do NOT post to Slack or tag tasks.
#
# Env knobs (mainly for tests):
#   CLICKUP_API_KEY             ClickUp personal API token (required)
#   CLICKUP_ENV_FILE            optional env file sourced for the key
#                               (default /etc/openclaw/main.env)
#   CLICKUP_LIST_ID             list to scan (default 901000600160)
#   CLICKUP_API                 API base (default https://api.clickup.com/api/v2)
#   ADS_INQUIRY_CHANNEL         Slack channel (default C0BBTAVP44X #cs_priority)
#   ADS_INQUIRY_BOT             muso slack bot (default operations — the only
#                               bot in #cs_priority; devops is NOT a member)
#   ADS_INQUIRY_MENTIONS        Slack mentions (default Aaron; empty = no ping)
#   ADS_INQUIRY_LOOKBACK        created-within window, seconds (default 30d)
#   ADS_INQUIRY_PATTERN         intent regex override (jq test(), case-insensitive)
#   ADS_INQUIRY_NOW             epoch override for window math (tests)
#   ADS_INQUIRY_LOCKFILE        single-run lock
#   ADS_INQUIRY_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[ads-inquiry-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLICKUP_API="${CLICKUP_API:-https://api.clickup.com/api/v2}"
LIST_ID="${CLICKUP_LIST_ID:-901000600160}"
CLICKUP_ENV_FILE="${CLICKUP_ENV_FILE:-/etc/openclaw/main.env}"
LOOKBACK="${ADS_INQUIRY_LOOKBACK:-2592000}"
LOCKFILE="${ADS_INQUIRY_LOCKFILE:-/var/run/ads-inquiry-watchdog.lock}"
SKIP_HOST_GUARD="${ADS_INQUIRY_SKIP_HOST_GUARD:-0}"
NOW="${ADS_INQUIRY_NOW:-$(date +%s)}"
DEDUPE_TAG="ads-lead-pinged"
DRY_RUN=0

# Ads-BUYING intent (customer wants to advertise WITH us), matched
# case-insensitively against ticket name + text_content. Deliberately does
# not match credit/analytics vocabulary; "advertis…" and "sponsor…" are
# anchored to buying-with-us context ("advertise on muso", "advertising
# packages") because bare stems false-positive on incidental usage — a real
# profile-update ticket saying the customer does "not want to advertise
# their own artist profile" pinged Aaron during verification (869dggdzj).
PATTERN="${ADS_INQUIRY_PATTERN:-\\bad (space|package|placement)|in-feed ad|media kit|buy(ing)? ads?\\b|advertis\\w* (with|on|in) (us|muso|the app)|advertising (package|option|opportunit|space|placement|rate|inquir)|sponsor(ing|ship)? (us|muso|opportunit)}"

# slack-notify.sh reads these; export before sourcing so its `:=` defaults
# don't override us. #cs_priority only has the operations bot as a member
# (the devops default 404s with channel_not_found) — same bot the
# intercom-data-complaint watchdog uses for this channel.
export SLACK_CHANNEL="${ADS_INQUIRY_CHANNEL:-C0BBTAVP44X}"  # #cs_priority
export SLACK_NOTIFY_BOT="${ADS_INQUIRY_BOT:-operations}"
MENTIONS="${ADS_INQUIRY_MENTIONS-<@U7RP6HKUZ>}"  # Aaron

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "$LOGPREFIX unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$SKIP_HOST_GUARD" != "1" && "$(hostname)" != "ovh-node-8" ]]; then
  log "not on ovh-node-8 — refusing to run (set ADS_INQUIRY_SKIP_HOST_GUARD=1 to override)"
  exit 0
fi

# The gateway service env carries CLICKUP_API_KEY; cron does not. Pull in
# exactly that line when the key is absent.
if [[ -z "${CLICKUP_API_KEY:-}" && -r "$CLICKUP_ENV_FILE" ]]; then
  eval "$(grep -E '^CLICKUP_API_KEY=' "$CLICKUP_ENV_FILE" | sed 's/^/export /')" 2>/dev/null || true
fi
if [[ -z "${CLICKUP_API_KEY:-}" ]]; then
  echo "$LOGPREFIX CLICKUP_API_KEY not set (and not found in $CLICKUP_ENV_FILE)" >&2
  exit 2
fi

# shellcheck source=lib/slack-notify.sh
source "$_WD_DIR/lib/slack-notify.sh"
# shellcheck source=lib/clickup-muso.sh
source "$_WD_DIR/lib/clickup-muso.sh"   # USE_MUSO_CLI=1 routes ClickUp calls through `muso clickup`

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "another run holds $LOCKFILE — exiting"
  exit 0
fi

# clickup_call <METHOD> <relpath[?query]> [jsonBody] — the same curl/muso seam
# as the sibling watchdogs, here also used for the dedupe-tag POST. Propagates
# the transport exit status: the tag-write caller must see a muso failure
# (empty output would sail through a `jq -e '.err'` probe — jq exits 4 on
# empty input, so the failure branch never fires and the missing dedupe tag
# re-pings every tick with exit 0).
clickup_call() {
  local method="$1" path="$2" body="${3:-}"
  if [ "${USE_MUSO_CLI:-0}" = 1 ]; then
    clickup_muso "$method" "$path" "$body"
  else
    local args=(-sS --max-time 30 -X "$method"
      -H "Authorization: $CLICKUP_API_KEY" -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(-d "$body")
    curl "${args[@]}" "$CLICKUP_API$path"
  fi
}

# ─── Fetch tasks (paginated, closed INCLUDED) ─────────────────
# Pages land in temp files and are merged via jq -s: task text makes pages
# far bigger than ARG_MAX allows, so they must never ride in argv.
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/ads-inquiry-watchdog.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
SINCE_MS=$(( (NOW - LOOKBACK) * 1000 ))
page=0
while :; do
  page_file="$WORKDIR/page-$page.json"
  # `|| true` only here: a transport failure leaves an empty/garbage page that
  # the shape-check below fails loud on, matching the curl path's semantics.
  clickup_call GET "/list/$LIST_ID/task?archived=false&include_closed=true&date_created_gt=$SINCE_MS&order_by=created&page=$page" > "$page_file" || true
  if ! jq -e '.tasks | type == "array"' "$page_file" >/dev/null 2>&1; then
    err=$(jq -r '.err // "unparseable response"' "$page_file" 2>/dev/null || echo "unparseable response")
    echo "$LOGPREFIX ClickUp list fetch failed (page $page): $err" >&2
    exit 1
  fi
  last=$(jq -r '.last_page // empty' "$page_file")
  count=$(jq -r '.tasks | length' "$page_file")
  [[ "$last" == "true" || "$count" -eq 0 ]] && break
  page=$((page + 1))
  [[ $page -gt 50 ]] && { echo "$LOGPREFIX >50 pages — aborting" >&2; exit 1; }
done
ALL_TASKS_FILE="$WORKDIR/all-tasks.json"
jq -s 'map(.tasks) | add // []' "$WORKDIR"/page-*.json > "$ALL_TASKS_FILE"

# ─── Filter: action-request + ads intent + in window + not pinged ─
# date_created_gt is also enforced here because tests (and any ClickUp
# server-side filter hiccup) may return older tasks; a null date_created is
# dropped fail-soft rather than crashing the whole sweep.
MATCH_FILE="$WORKDIR/matches.json"
jq -ec --argjson since_ms "$SINCE_MS" --arg pattern "$PATTERN" --arg dedupe "$DEDUPE_TAG" '
  map(select((.tags // []) | map(.name) | index("hydra-action-request")))
  | map(select((.tags // []) | map(.name) | index($dedupe) | not))
  | map(select(.date_created != null and (.date_created | tonumber) > $since_ms))
  | map(select(((.name // "") + " " + (.text_content // "")) | test($pattern; "i")))
' "$ALL_TASKS_FILE" > "$MATCH_FILE"

n=$(jq -r 'length' "$MATCH_FILE")
log "$n ads-buying lead(s) to ping in list $LIST_ID"
if [[ "$n" -eq 0 ]]; then
  exit 0
fi

# ─── One post per lead ────────────────────────────────────────
# Task names come from customer text (buildTicketTitle → gist), so escape
# Slack mrkdwn control chars (& < >) — otherwise a crafted title like
# `<!channel>` would broadcast-ping #cs_priority. `&` first to avoid
# double-escaping. Our own mention + ClickUp link stay real mrkdwn.
failures=0
while IFS=$'\t' read -r task_id task_url task_name task_summary; do
  msg="${MENTIONS:+$MENTIONS }📣 *New ads-buying lead* in the support queue:
• ${task_name} — <${task_url}|${task_id}>
Customer asked about advertising with Muso — details in the ClickUp ticket."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN — would ping for $task_id:"
    printf '%s\n' "$msg"
    [[ -n "$task_summary" ]] && printf 'thread ↳ %s\n' "$task_summary"
    continue
  fi

  payload="$WORKDIR/payload-$task_id.json"
  jq -n --arg channel "$SLACK_CHANNEL" --arg text "$msg" \
    '{channel: $channel, text: $text}' > "$payload"
  if ts=$(slack_notify_payload_file_ts "$payload") && [[ -n "$ts" ]]; then
    log "pinged $SLACK_CHANNEL for $task_id (ts=$ts)"
    # Thread the ticket's own conversation summary under the ping so Aaron
    # gets the customer's ask without opening ClickUp. Best-effort: the ping
    # (with the link) is the contract; a lost reply is not worth a re-ping.
    if [[ -n "$task_summary" ]]; then
      reply="$WORKDIR/reply-$task_id.json"
      jq -n --arg channel "$SLACK_CHANNEL" --arg ts "$ts" \
        --arg text "🧾 What the customer asked: $task_summary" \
        '{channel: $channel, thread_ts: $ts, text: $text}' > "$reply"
      slack_notify_payload_file "$reply"
    fi
    # Tag only after a confirmed post; a failed tag-add is fail-loud (exit 1)
    # and the next tick re-pings — a duplicate ping beats a silent miss. Both
    # failure shapes are caught: transport exit ≠ 0 (muso down/curl error) and
    # a ClickUp error body on the curl path (HTTP errors still exit 0 there).
    if ! tag_resp=$(clickup_call POST "/task/$task_id/tag/$DEDUPE_TAG" '{}') \
       || jq -e '.err' <<<"$tag_resp" >/dev/null 2>&1; then
      echo "$LOGPREFIX dedupe tag add FAILED for $task_id: ${tag_resp:-transport failure}" >&2
      failures=$((failures + 1))
    fi
  else
    echo "$LOGPREFIX Slack post FAILED for $task_id — will retry next tick" >&2
    failures=$((failures + 1))
  fi
done < <(jq -r '
  def slack_escape: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  # The ticket body carries a one-line "Conversation summary: …" (written by
  # create_ticket from the CS session); customer-derived, so escape it and
  # collapse tabs, and cap the length so a rambling ticket cannot flood the
  # thread. Absent line → empty 4th column → no thread reply.
  def summary: (try ((.text_content // "") | capture("Conversation summary: (?<s>[^\n]+)").s) catch "")
    | .[0:500] | slack_escape | gsub("\t";" ");
  .[] | [.id, .url, (.name | slack_escape), summary] | @tsv
' "$MATCH_FILE")

[[ "$failures" -gt 0 ]] && exit 1
exit 0

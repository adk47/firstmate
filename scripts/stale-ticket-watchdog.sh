#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Stale-Ticket Watchdog
#
# Posts a daily digest of OVERDUE hydra-action-request ClickUp tickets
# (list 901000600160) to #cs_chats so customer-facing promises can't rot
# silently. Born from the 2026-05 Sandy Vee incident: profile-claim
# tickets filed May 12/18 sat unworked for weeks while Caroline kept
# telling the customer "you'll hear back within 2 business days" — nobody
# was watching the queue. Deliberately a deterministic system-cron bash
# watchdog — NOT an openclaw cron — so it fires even when the gateway is
# down and never depends on an LLM (same shape as cron-health-watchdog.sh).
#
# Detection model: every tick, page through open tasks in the list,
# keep those tagged `hydra-action-request`, and report any that are
# past their ClickUp due date (set at creation from the tier SLA by the
# intercom plugin's ticket-format) — or, if a task somehow has no due
# date, older than GRACE (default 7d). Tickets carrying an
# `escalation:*` tag (customer already followed up past the SLA) are
# listed first. One consolidated Slack post per tick; zero overdue →
# no post. Stateless by design: the digest lists what is overdue NOW,
# so a daily cadence needs no dedupe store.
#
# Runs daily via /etc/cron.d/stale-ticket-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh).
#
# Flags:
#   --dry-run   compute + print the digest, do NOT post to Slack.
#
# Env knobs (mainly for tests):
#   CLICKUP_API_KEY             ClickUp personal API token (required)
#   CLICKUP_ENV_FILE            optional env file sourced for the key
#                               (default /etc/openclaw/main.env — the
#                               gateway service env already carries it)
#   CLICKUP_LIST_ID             list to scan (default 901000600160)
#   CLICKUP_API                 API base (default https://api.clickup.com/api/v2)
#   STALE_TICKET_CHANNEL        Slack channel (default C0ANM0PN9L5 #cs_chats)
#   STALE_TICKET_GRACE          no-due-date overdue threshold, seconds (default 7d)
#   STALE_TICKET_MENTIONS       Slack mentions prepended when escalation-tagged
#                               tickets are present (default Nick + Jan;
#                               empty = never ping)
#   STALE_TICKET_MAX            max tickets listed in the digest (default 20)
#   STALE_TICKET_NOW            epoch override for overdue math (tests)
#   STALE_TICKET_LOCKFILE       single-run lock
#   STALE_TICKET_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[stale-ticket-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLICKUP_API="${CLICKUP_API:-https://api.clickup.com/api/v2}"
LIST_ID="${CLICKUP_LIST_ID:-901000600160}"
CLICKUP_ENV_FILE="${CLICKUP_ENV_FILE:-/etc/openclaw/main.env}"
GRACE="${STALE_TICKET_GRACE:-604800}"
MAX_LISTED="${STALE_TICKET_MAX:-20}"
LOCKFILE="${STALE_TICKET_LOCKFILE:-/var/run/stale-ticket-watchdog.lock}"
SKIP_HOST_GUARD="${STALE_TICKET_SKIP_HOST_GUARD:-0}"
NOW="${STALE_TICKET_NOW:-$(date +%s)}"
DRY_RUN=0

# slack-notify.sh reads this; export before sourcing so its `:=` default
# doesn't override us.
export SLACK_CHANNEL="${STALE_TICKET_CHANNEL:-C0ANM0PN9L5}"  # #cs_chats

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "$LOGPREFIX unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$SKIP_HOST_GUARD" != "1" && "$(hostname)" != "ovh-node-8" ]]; then
  log "not on ovh-node-8 — refusing to run (set STALE_TICKET_SKIP_HOST_GUARD=1 to override)"
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
source "$_WD_DIR/lib/clickup-muso.sh"   # USE_MUSO_CLI=1 routes the ClickUp fetch through `muso clickup`

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  log "another run holds $LOCKFILE — exiting"
  exit 0
fi

# ─── Fetch all open tasks (paginated) ─────────────────────────
# Pages land in temp files and are merged via jq -s: task descriptions make
# pages far bigger than ARG_MAX allows, so they must never ride in argv.
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
page=0
while :; do
  page_file="$WORKDIR/page-$page.json"
  _ticket_path="/list/$LIST_ID/task?archived=false&include_closed=false&order_by=due_date&page=$page"
  if [ "${USE_MUSO_CLI:-0}" = 1 ]; then
    # On a muso error the body is empty → the jq shape-check below fails loud,
    # matching the curl path (which also defers HTTP errors to that check).
    clickup_muso GET "$_ticket_path" > "$page_file" || true
  else
    curl -sS --max-time 30 \
      -H "Authorization: $CLICKUP_API_KEY" \
      -H "Content-Type: application/json" \
      "$CLICKUP_API$_ticket_path" \
      > "$page_file"
  fi
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

# ─── Filter: hydra-action-request AND overdue ─────────────────
# Overdue = due_date (ms) in the past, or no due_date and created > GRACE ago.
# Escalation-tagged first, then most-overdue first.
OVERDUE_FILE="$WORKDIR/overdue.json"
jq -ec --argjson now "$NOW" --argjson grace "$GRACE" '
  map(select((.tags // []) | map(.name) | index("hydra-action-request")))
  | map(. + {
      _esc: ((.tags // []) | map(.name) | any(startswith("escalation:"))),
      _due: (if .due_date != null then (.due_date | tonumber / 1000 | floor) else null end),
      _created: (if .date_created != null then (.date_created | tonumber / 1000 | floor) else null end)
    })
  | map(select(
      (._due != null and ._due < $now)
      or (._due == null and ._created != null and (._created + $grace) < $now)
    ))
  | map(. + {_overdue_days: ((($now - (._due // (._created + $grace))) / 86400) | floor)})
  | sort_by([(if ._esc then 0 else 1 end), (-._overdue_days)])
' "$ALL_TASKS_FILE" > "$OVERDUE_FILE"

n=$(jq -r 'length' "$OVERDUE_FILE")
log "$n overdue hydra-action-request ticket(s) in list $LIST_ID"
if [[ "$n" -eq 0 ]]; then
  exit 0
fi

# ─── Build digest ─────────────────────────────────────────────
# Task names come from customer/request text (buildTicketTitle → gist), so
# escape Slack mrkdwn control chars (& < >) before composing the digest —
# otherwise a crafted title like `<!channel>` or `<@U…>` would broadcast-ping
# or mislead #cs_chats. `&` must go first so we don't double-escape. The
# ClickUp url/id link below is ours (trusted), left as real mrkdwn.
lines=$(jq -r --argjson max "$MAX_LISTED" '
  def slack_escape: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  .[:$max][] |
  "• " + (if ._esc then "🔁 " else "" end)
       + (.name | slack_escape) + " — " + (._overdue_days | tostring) + "d overdue"
       + (if ._esc then " (customer follow-up past SLA)" else "" end)
       + " — <" + .url + "|" + .id + ">"
' "$OVERDUE_FILE")
truncated=""
[[ "$n" -gt "$MAX_LISTED" ]] && truncated=$'\n'"…and $((n - MAX_LISTED)) more (showing $MAX_LISTED)."

# Ping the humans only when a customer has already followed up past a
# promised SLA (escalation:* tag, set by Caroline's create_ticket) — those
# are broken promises, not just queue lag.
MENTIONS="${STALE_TICKET_MENTIONS-<@U0AL36NADEY> <@U038BM16T7W>}"  # Nick, Jan
esc_count=$(jq -r 'map(select(._esc)) | length' "$OVERDUE_FILE")
mention_line=""
if [[ "$esc_count" -gt 0 && -n "$MENTIONS" ]]; then
  mention_line="$MENTIONS $esc_count ticket(s) have a customer follow-up past the promised SLA:"$'\n'
fi

digest="${mention_line}⏰ *$n overdue action-request ticket(s)* in the support queue (promised SLA has passed; 🔁 = customer already followed up):
$lines$truncated"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY RUN — digest below (not posting)"
  printf '%s\n' "$digest"
  exit 0
fi

payload="$WORKDIR/payload.json"
jq -n --arg channel "$SLACK_CHANNEL" --arg text "$digest" \
  '{channel: $channel, text: $text}' > "$payload"
if slack_notify_payload_file_status "$payload"; then
  log "digest posted to $SLACK_CHANNEL"
else
  echo "$LOGPREFIX Slack post FAILED — digest not delivered" >&2
  exit 1
fi

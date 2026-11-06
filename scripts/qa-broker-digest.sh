#!/usr/bin/env bash
# qa-broker-digest.sh — one Slack line per hour describing the QA queue.
#
# The point of scaling the reviewers is that no PR waits an hour for QA. That
# claim is only checkable if the queue reports itself, so this posts ONE line to
# the devops channel every hour with the numbers that would falsify it:
#
#   depth, oldest queued age, wait p50/p95, verdicts/h, failures, lost
#
# and pages (a second, louder line) when a threshold is crossed. The digest is
# deliberately a single line: a channel that gets a wall of text every hour gets
# muted, and a muted channel is the same as no monitoring.
#
# Usage:
#   qa-broker-digest.sh                 # post the hourly line
#   qa-broker-digest.sh --dry-run       # print the line, post nothing
#   qa-broker-digest.sh --window 3600   # stats window in seconds
#
# Env:
#   QA_BROKER_URL        default http://qa-broker.hydra-qa.svc.cluster.local:8080
#                        "cli" reads QA_QUEUE_DB directly
#   QA_QUEUE_DB          default /var/lib/hydra-qa/queue.sqlite (cli mode)
#   QA_DIGEST_CHANNEL    default C0ADV2W76G4 (#clio_devops)
#   QA_DIGEST_P95_S      default 900  — page above this
#   QA_DIGEST_DEPTH      default 20   — page above this
#   QA_DIGEST_OLDEST_S   default 300  — page above this
#   QA_DIGEST_STATE      default /var/lib/hydra-qa/digest-state.json
#   QA_DIGEST_P95_STREAK default 2    — consecutive hours above p95 before paging
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROKER_PY="${QA_BROKER_SCRIPT:-$HERE/lib/qa_broker.py}"
BROKER_URL="${QA_BROKER_URL:-http://qa-broker.hydra-qa.svc.cluster.local:8080}"
QUEUE_DB="${QA_QUEUE_DB:-/var/lib/hydra-qa/queue.sqlite}"
CHANNEL="${QA_DIGEST_CHANNEL:-C0ADV2W76G4}"
P95_LIMIT="${QA_DIGEST_P95_S:-900}"
DEPTH_LIMIT="${QA_DIGEST_DEPTH:-20}"
OLDEST_LIMIT="${QA_DIGEST_OLDEST_S:-300}"
STATE="${QA_DIGEST_STATE:-/var/lib/hydra-qa/digest-state.json}"
P95_STREAK="${QA_DIGEST_P95_STREAK:-2}"

DRY_RUN=0
WINDOW=3600
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --window) WINDOW="${2:?--window needs a value}"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[qa-digest $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

# slack-notify.sh is a SOURCED lib (slack_notify <msg>, channel from
# SLACK_CHANNEL), not a CLI. Sourcing it also gives us the bats test fence, so
# a test run can never post to the real channel.
# shellcheck source=lib/slack-notify.sh
source "$HERE/lib/slack-notify.sh"
export SLACK_CHANNEL="$CHANNEL"
export SLACK_NOTIFY_REQUESTER="qa-broker-digest@hydra-ops"

# Delivery must report its real status. `slack_notify` cannot: it ends in
# `|| true` and returns 0 even when Slack rejects the post, so a digest that
# used it would log "posted" for a message nobody received. `_slack_post_payload`
# (same library) returns 0 only when Slack CONFIRMED the post, which is what the
# loss acknowledgement below depends on.
post() {  # <text> — rc 0 only when Slack confirmed delivery
  local msg="$1" payload rc
  payload="$(mktemp)" || return 1
  python3 - "$payload" "$SLACK_CHANNEL" "$msg" <<'PAYLOAD' || { rm -f "$payload"; return 1; }
import json, sys
path, channel, text = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as fh:
    json.dump({"channel": channel, "text": text}, fh)
PAYLOAD
  _slack_post_payload "$payload"
  rc=$?
  rm -f "$payload"
  return "$rc"
}

# ── fetch stats ───────────────────────────────────────────────────────────
stats=""
if [ "$BROKER_URL" = "cli" ]; then
  stats="$(python3 "$BROKER_PY" --db "$QUEUE_DB" stats --window "$WINDOW" 2>/dev/null)" || stats=""
else
  # /stats is read-only and stays open, but send the token when we have one so
  # the digest keeps working if the broker is ever locked down further.
  digest_auth=()
  [ -n "${QA_BROKER_TOKEN:-}" ] && digest_auth=(-H "X-QA-Broker-Token: $QA_BROKER_TOKEN")
  stats="$(curl -fsS --max-time 10 "${digest_auth[@]}" \
    "${BROKER_URL%/}/stats?window=${WINDOW}" 2>/dev/null)" || stats=""
fi

if [ -z "$stats" ]; then
  line=":warning: QA queue digest: broker unreachable at ${BROKER_URL} — queue state UNKNOWN (not empty)"
  log "$line"
  if [ "$DRY_RUN" -eq 0 ]; then
    post "$line"
  fi
  exit 1
fi

# ── render ────────────────────────────────────────────────────────────────
# All formatting lives in python so the numbers cannot drift from the JSON.
# The stats JSON goes through a FILE, not stdin: the heredoc below is the
# python program itself, and a heredoc overrides a pipe (shellcheck SC2259).
STATS_FILE="$(mktemp)"
trap 'rm -f "$STATS_FILE"' EXIT
printf '%s' "$stats" >"$STATS_FILE"

# Two lines out of python: the digest line, then the page line (empty when
# nothing is wrong). `read -r line page` would only ever read the FIRST line,
# so the two are split explicitly.
RENDERED="$(python3 - "$STATS_FILE" "$P95_LIMIT" "$DEPTH_LIMIT" "$OLDEST_LIMIT" "$P95_STREAK" "$STATE" <<'PY'
import json, os, sys

stats_path, p95_limit, depth_limit, oldest_limit, streak_limit, state_path = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
    int(sys.argv[5]), sys.argv[6]
)
with open(stats_path) as fh:
    d = json.load(fh)

def fmt_s(v):
    v = int(v or 0)
    if v < 60:
        return f"{v}s"
    if v < 3600:
        return f"{v // 60}m{v % 60:02d}s"
    return f"{v // 3600}h{(v % 3600) // 60:02d}m"

v = d.get("verdicts") or {}
depth = int(d.get("depth") or 0)
oldest = int(d.get("oldest_queued_age_s") or 0)
p50 = int(d.get("wait_p50_s") or 0)
p95 = int(d.get("wait_p95_s") or 0)
done = int(d.get("done_window") or 0)
dead = int(d.get("dead") or 0)
# `lost_window` only sees arrivals inside the window, so a row enqueued more
# than an hour ago that disappears NOW is invisible to it: lost_total goes to 1
# while lost_window stays 0, and because the arrival is outside every future
# window it never pages at all. Page on the cumulative total too, but only when
# it GROWS — lost_total never decreases, so paging on it unconditionally would
# page forever after a single incident.
lost = int(d.get("lost_window") or 0)
lost_total = int(d.get("lost_total") or 0)
running = int(d.get("running") or 0)
dedupe = d.get("dedupe") or {}

line = (
    f":mag: QA queue — depth {depth} (oldest {fmt_s(oldest)}), running {running}, "
    f"wait p50 {fmt_s(p50)} / p95 {fmt_s(p95)}, "
    f"verdicts/h {done} (go {v.get('go', 0)}, no-go {v.get('no_go', 0)}, "
    f"cannot {v.get('cannot_review', 0)}, unknown {v.get('unknown', 0)}), "
    f"dead {dead}, lost {lost}, "
    f"dedupe {dedupe.get('duplicates_dropped', 0)} dropped / "
    f"{dedupe.get('superseded', 0)} superseded / "
    f"{dedupe.get('lease_expired', 0)} lease-expired"
)

# ── page conditions ───────────────────────────────────────────────────────
# p95 is a two-hour condition: one slow hour is a burst, two is a trend. The
# streak is persisted so the digest is stateless between runs.
streak = 0
lost_paged = 0
try:
    with open(state_path) as fh:
        st = json.load(fh)
        streak = int(st.get("p95_streak") or 0)
        lost_paged = int(st.get("lost_paged_total") or 0)
except Exception:
    streak = 0
    lost_paged = 0
streak = streak + 1 if p95 > p95_limit else 0
# A loss is news once. Re-paging the same cumulative count every hour trains
# people to ignore the channel; a NEW loss still pages immediately.
new_loss = lost_total > lost_paged
# The loss acknowledgement is NOT advanced here. It is advanced only after the
# page has actually been DELIVERED (see the post below): advancing it during
# render meant a Slack failure still marked the loss as announced, so the next
# run saw nothing new and the loss was never paged again. The p95 streak is
# different - it is a measurement, not an acknowledgement, so it is written now.
try:
    os.makedirs(os.path.dirname(state_path) or ".", exist_ok=True)
    tmp = state_path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"p95_streak": streak, "at": d.get("at"),
                   "lost_paged_total": lost_paged}, fh)
    os.replace(tmp, state_path)
except Exception:
    pass

reasons = []
if lost > 0:
    reasons.append(f"{lost} job(s) LOST (enqueued but neither open nor terminal)")
elif new_loss:
    reasons.append(f"{lost_total} job(s) LOST in total ({lost_total - lost_paged} new; "
                   f"none in the last hour, so the arrival is older than the window)")
if dead > 0:
    reasons.append(f"{dead} dead job(s) need a human")
if depth > depth_limit:
    reasons.append(f"depth {depth} > {depth_limit}")
if oldest > oldest_limit:
    reasons.append(f"oldest queued {fmt_s(oldest)} > {fmt_s(oldest_limit)}")
if streak >= streak_limit:
    reasons.append(f"wait p95 {fmt_s(p95)} > {fmt_s(p95_limit)} for {streak} consecutive hours")

page = ""
if reasons:
    page = ":rotating_light: QA queue needs attention — " + "; ".join(reasons)

print(line)
print(page)
print(lost_total)
PY
)"
line="$(printf '%s\n' "$RENDERED" | sed -n '1p')"
page="$(printf '%s\n' "$RENDERED" | sed -n '2p')"
lost_total="$(printf '%s\n' "$RENDERED" | sed -n '3p')"

[ -n "$line" ] || { log "failed to render digest"; exit 1; }

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$line"
  [ -n "$page" ] && printf '%s\n' "$page"
  exit 0
fi

# A delivery failure must be LOUD and must not be recorded as delivered. The
# digest is the only thing watching the queue, so a silently dropped post is
# indistinguishable from a healthy queue.
if ! post "$line"; then
  log "FAILED to post the digest line to Slack"
  exit 1
fi
log "posted digest"

if [ -n "$page" ]; then
  if ! post "$page"; then
    log "FAILED to post the page to Slack: $page"
    exit 1
  fi
  log "posted page: $page"
  # Only now is the loss acknowledged. A failed send leaves the state alone, so
  # the next run still sees it as news and pages again.
  if [ -n "$lost_total" ] && [ "$lost_total" -gt 0 ] 2>/dev/null; then
    python3 - "$STATE" "$lost_total" <<'ACK' || log "could not record the loss acknowledgement"
import json, os, sys
path, total = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as fh:
        st = json.load(fh)
except Exception:
    st = {}
st["lost_paged_total"] = total
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(st, fh)
os.replace(tmp, path)
ACK
  fi
fi

#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Stuck-Lane Watchdog  (Caroline / edge support  +  live lane-wedge detection)
#
# TWO detectors, separate functions, separate state files, separate suites:
#
#   1. scan_stuck_lanes        EDGE journal. An abort that did not free the lane
#                              (action=abort_embedded_run … released=0) —
#                              Caroline's generated reply discarded.
#   2. scan_wedged_lanes_live  LIVE gateway state via `diagnostics.lanes`. A lane
#                              with work QUEUED and NOTHING ACTIVE, observed for
#                              several consecutive ticks.
#
# ── Detector 2 reads STATE, not logs, and that is the whole point ───────────
# An earlier revision of this detector parsed `lane wait exceeded` from the
# journal and treated `activeAhead=1 activeNow=0` as a phantom lane owner. That
# was WRONG, and a QA review caught it. In dist/command-queue-*.js the line is
# emitted inside `drainLane` AFTER `dequeueLaneQueue(...)`, as a queued task is
# being STARTED:
#
#     const entry = dequeueLaneQueue(state.queue);
#     const waitedMs = Date.now() - entry.enqueuedAt;
#     const activeBeforeStart = state.activeTaskIds.size;
#     ...
#     if (waitedMs >= entry.warnAfterMs) diagnosticLogger.warn(`lane wait exceeded: …
#         activeAhead=${entry.activeAheadAtEnqueue} activeNow=${activeBeforeStart} …`)
#
# so `activeNow` is the count immediately BEFORE that start and `activeAhead` is
# a snapshot from ENQUEUE time. `activeAhead=1 activeNow=0` therefore means "one
# was active when this was enqueued, the lane has since gone idle, and this task
# is now starting" — a RECOVERY record. Measured 221 of 221 lines carried that
# pair over 24h, because it is the ordinary shape. Paging on it would alert for
# lanes that already recovered and prompt a customer-visible gateway restart.
#
# `drainLane blocked: … draining=true active=0 queue=N` IS a genuine
# admission-blocked line, but it fires 0 times in 24h on both gateways (it needs
# a re-entrant drainLane), so it is not a usable surface either.
#
# What IS authoritative is the gateway's own state:
#
#   $ openclaw --profile main gateway call diagnostics.lanes --json
#   {"ts":…,"lanes":[{"lane":"session:agent:ops:main","queuedCount":3,
#                     "activeCount":0,"maxConcurrent":1,"draining":false,
#                     "generation":0,"blockedBy":null}, …]}
#
# A wedge is then directly observable: queuedCount > 0 with activeCount == 0.
# Session lanes are safe to read this way because `retireIdleScopedCommandLane`
# only removes a `session:`-prefixed lane when it is NOT draining, has zero
# active tasks AND **queue.length == 0** — so a lane with anything queued cannot
# be reaped and is always present in this list.
#
# Two exclusions, both load-bearing:
#   - `maxConcurrent == 0` is an administratively disabled lane (hook-dispatch
#     reads q=0 a=0 max=0 blockedBy=lane today). It can never run anything, so
#     queued work there is a config question, not a wedge.
#   - a single observation is not enough. A dequeue leaves a sub-millisecond
#     window where queued>0 and active==0 legitimately, so a lane must be seen
#     wedged on STUCK_LANE_LIVE_MIN_TICKS consecutive ticks (default 3, i.e.
#     ~4-6 min at the 2-minute cron cadence) before it pages.
#
# DETECTION ONLY — no auto-heal. A gateway restart is the only known clearer and
# main restarts are customer-visible, so that stays a human decision.
#
# Alerts #clio_devops when the EDGE gateway's stuck-session recovery
# force-aborts a wedged agent run WITHOUT freeing the lane — the moment a
# customer's generated reply is silently discarded.
#
# Root cause (upstream, no released fix): openclaw #97538 / #92270. Rapid-fire
# inbound Intercom messages spawn overlapping embedded_run dispatches on one
# conversation lane; one run leaks the lane owner lock; later dispatches wedge at
# embedded_run:started; the stuck-session watchdog aborts them but logs
# `released=0` (lane never freed) and the runtime DISCARDS the already-generated
# reply. The customer sees nothing and — because the plugin's dispatch await
# never settles — the in-plugin silent_dispatch alarm can't fire either.
#
# TWO layers guard this (see docs / PR): the intercom plugin now bounds the
# dispatch await and pages #cs-escalations (dispatch_timed_out) for CUSTOMER
# pickup. THIS watchdog is the out-of-process OPS backstop: it fires from
# journald even if the plugin path itself is broken or mid-deploy, and it keys
# off the definitive `released=0` lane-leak marker the plugin cannot observe.
#
# Detection signal (ground-truthed in journald, openclaw-gateway-edge):
#   [diagnostic] stuck session recovery outcome: status=aborted
#     action=abort_embedded_run sessionId=<uuid>
#     sessionKey=agent:support:intercom:direct:<convId> … released=0
# The `action=abort_embedded_run` + `released=0` pair is the reply-killing event.
# We deliberately do NOT alert on mere `stalled_agent_run` warnings (transient,
# often self-resolve) — only on an abort that failed to release the lane.
#
# Dedupe: one page per wedged CONVERSATION per cooldown window
# (STUCK_LANE_COOLDOWN_SECONDS, default 6h) — collapses the ~3 aborts a single
# wedge emits into one page, while a genuine re-wedge after the window pages
# again. First-ever run seeds silently (no backlog page-storm on install).
#
# Runs every ~2 min via /etc/cron.d/stuck-lane-watchdog ON NODE-8 (installed
# idempotently by scripts/install-aux-units.sh). Must run as root — reads
# journald and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT post to Slack,
#               and NEVER mutate a production watermark.
#
#               Each detector keeps its own state file, and a rehearsal that
#               wrote an alert epoch would suppress the next REAL page for the
#               whole cooldown while looking like a successful rehearsal. So any
#               state path still at its DEFAULT is shadowed by a temp COPY for
#               the run: reads stay faithful, so dedupe and streak behaviour are
#               genuinely rehearsed, and writes land in the copy.
#
#               A path supplied EXPLICITLY via STUCK_LANE_STATE_FILE or
#               STUCK_LANE_LIVE_STATE_FILE is used as given and IS written — that
#               is how the bats suites rehearse multi-tick behaviour. Relying on
#               "remember to redirect the env var" was the old contract, and it
#               was a footgun: it only named ONE of the two state files.
#
# Env knobs (mainly for tests — defaults target the live edge gateway):
#   STUCK_LANE_JOURNAL_FILE        pre-captured journal text (tests). Default:
#                                  live `journalctl` of openclaw-gateway-edge.
#   STUCK_LANE_LOOKBACK            journalctl --since window (default "15 min ago")
#   STUCK_LANE_STATE_FILE          per-conv last-alert store
#   STUCK_LANE_COOLDOWN_SECONDS    per-conv re-alert cooldown (default 21600 = 6h)
#   STUCK_LANE_SLACK_CHANNEL       target channel (default #clio_devops)
#   STUCK_LANE_INTERCOM_WORKSPACE  Intercom workspace id for deep-links. Default:
#                                  read from EDGE_CONFIG via jq; empty → no link.
#   STUCK_LANE_EDGE_CONFIG         edge openclaw.json (default /root/.openclaw-edge/openclaw.json)
#   STUCK_LANE_LOCKFILE            single-run lock
#   STUCK_LANE_SKIP_HOST_GUARD     1 = skip the ovh-node-8 guard (tests)
#   STUCK_LANE_LIVE_PROFILES       profiles to poll (default "main edge")
#   STUCK_LANE_LIVE_SNAPSHOT_DIR   pre-captured diagnostics.lanes JSON per
#                                  profile (tests): <dir>/<profile>.json.
#                                  Default: live `gateway call`.
#   STUCK_LANE_LIVE_STATE_FILE     per-lane streak + last-alert store
#   STUCK_LANE_LIVE_MIN_TICKS      consecutive wedged observations before paging
#                                  (default 3)
#   OPENCLAW_BIN                   openclaw binary (tests stub this)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[stuck-lane-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
# Whether each state path was EXPLICITLY supplied. --dry-run uses this to
# refuse to mutate a PRODUCTION watermark (see the dry-run block below).
EDGE_STATE_EXPLICIT=0; [ -n "${STUCK_LANE_STATE_FILE+x}" ] && EDGE_STATE_EXPLICIT=1
LIVE_STATE_EXPLICIT=0; [ -n "${STUCK_LANE_LIVE_STATE_FILE+x}" ] && LIVE_STATE_EXPLICIT=1
JOURNAL_FILE="${STUCK_LANE_JOURNAL_FILE:-}"
LOOKBACK="${STUCK_LANE_LOOKBACK:-15 min ago}"
STATE_FILE="${STUCK_LANE_STATE_FILE:-/var/lib/stuck-lane-watchdog/seen.json}"
COOLDOWN="${STUCK_LANE_COOLDOWN_SECONDS:-21600}"
LOCKFILE="${STUCK_LANE_LOCKFILE:-/var/run/stuck-lane-watchdog.lock}"
EDGE_CONFIG="${STUCK_LANE_EDGE_CONFIG:-/root/.openclaw-edge/openclaw.json}"
SKIP_HOST_GUARD="${STUCK_LANE_SKIP_HOST_GUARD:-0}"
GATEWAY_UNIT="openclaw-gateway-edge"
DRY_RUN=0

# ── Detector 2: live lane state ─────────────────────────────────────────────
LIVE_PROFILES="${STUCK_LANE_LIVE_PROFILES:-main edge}"
LIVE_SNAPSHOT_DIR="${STUCK_LANE_LIVE_SNAPSHOT_DIR:-}"
LIVE_STATE_FILE="${STUCK_LANE_LIVE_STATE_FILE:-/var/lib/stuck-lane-watchdog/live-lanes.json}"
LIVE_MIN_TICKS="${STUCK_LANE_LIVE_MIN_TICKS:-3}"

# ── Detector 3: lane LATENCY (waits that already ENDED) ─────────────────────
# This is the one thing `lane wait exceeded` IS authoritative for. The line is
# emitted as a queued task STARTS, so it cannot prove a lane is stuck now
# (detector 2 answers that from live state) — but `waitedMs` is a real, finished
# measurement of how long that task sat queued. Nothing watched it, so a human
# waiting a long time for an agent reply produced no signal at all: on
# 2026-09-16 five messages to `cto` waited 107, 102, 91, 86 and 22 minutes and
# the only reason anyone noticed was a person asking why Ops had not replied.
#
# Measured over 24h on node-8 (2026-09-17, main gateway; edge emits none):
#   170 lines   p50=79s  p90=508s  p99=1013s  max=1271s (21.2 min)
#   >= 5min -> 39 lines /  8 lanes      >= 15min -> 5 lines / 3 lanes
#   >= 10min -> 11 lines /  4 lanes     >= 30min -> 0
# 10 minutes is the floor: 4 lanes/day is a sane page rate, 5 minutes would be
# 8 and chatty for something already-resolved, and 15 would have missed two of
# the four worst cases today.
LATENCY_UNITS="${STUCK_LANE_LATENCY_UNITS:-openclaw-gateway-main openclaw-gateway-edge}"
LATENCY_JOURNAL_DIR="${STUCK_LANE_LATENCY_JOURNAL_DIR:-}"
LATENCY_STATE_FILE="${STUCK_LANE_LATENCY_STATE_FILE:-/var/lib/stuck-lane-watchdog/lane-latency.json}"
LATENCY_MIN_MS="${STUCK_LANE_LATENCY_MIN_MS:-600000}"
LATENCY_STATE_EXPLICIT=0; [ -n "${STUCK_LANE_LATENCY_STATE_FILE+x}" ] && LATENCY_STATE_EXPLICIT=1
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"

# slack-notify.sh reads this (target channel).
export SLACK_CHANNEL="${STUCK_LANE_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

# Stand down during a planned maintenance window (scripts/hydra-maintenance.sh):
# a fleet stopped on purpose would otherwise page this alarm for the whole window.
# Fail-safe: an absent/expired/malformed flag reads as "not in maintenance".
# shellcheck source=lib/maintenance-flag.sh
source "$_WATCHDOG_DIR/lib/maintenance-flag.sh"
if maintenance_active; then
  echo "$LOGPREFIX maintenance: $(maintenance_reason) - skipping"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# Resolve the Intercom workspace id for deep-links: explicit env wins, else best-
# effort from the edge config (jq). Empty is fine — the alert then omits the link.
WORKSPACE="${STUCK_LANE_INTERCOM_WORKSPACE:-}"
if [ -z "$WORKSPACE" ] && command -v jq >/dev/null 2>&1 && [ -f "$EDGE_CONFIG" ]; then
  WORKSPACE="$(jq -r '.channels.intercom.accounts.default.workspaceId // empty' "$EDGE_CONFIG" 2>/dev/null || true)"
fi

# ──────────────────────────────────────────────────────────────
# scan_stuck_lanes — pure detection core.
#   $1 journal_file  $2 state_file  $3 payload_out  $4 persist(0|1)
# Reads journal text from $1, alerts on each wedged conversation whose lane
# recovery aborted with released=0 and whose last alert (in $2) is older than
# COOLDOWN (or never), advances that conv's watermark (when persist=1), writes a
# Slack payload to $3 (only when there are alerts), and prints the human-readable
# block to stdout. First-ever run (state file absent) seeds WITHOUT alerting.
# ──────────────────────────────────────────────────────────────
scan_stuck_lanes() {
  JOURNAL_FILE="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" PERSIST="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" COOLDOWN="$COOLDOWN" WORKSPACE="$WORKSPACE" python3 - <<'PYEOF'
import json, os, re
from datetime import datetime

journal_file = os.environ["JOURNAL_FILE"]
state_file   = os.environ["STATE_FILE"]
payload_out  = os.environ["PAYLOAD_OUT"]
persist      = os.environ.get("PERSIST", "1") == "1"
channel      = os.environ["SLACK_CHANNEL"]
cooldown     = int(os.environ.get("COOLDOWN", "21600"))
workspace    = os.environ.get("WORKSPACE", "").strip()

# The reply-killing event: an abort that failed to release the lane.
# One line per abort; sessionKey carries the Intercom conversation id.
SESSION_RE = re.compile(r"(?:^|\s)sessionId=(?P<sessionId>\S+)")
CONV_RE    = re.compile(r"sessionKey=agent:[a-z0-9_-]+:intercom:direct:(?P<convId>\d+)")
TS_RE      = re.compile(r"(\d{4}-\d{2}-\d{2}T[\d:.]+(?:[+-]\d{2}:?\d{2}|Z))")

def parse_epoch(ts):
    if not ts:
        return None
    t = ts.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(t).timestamp()
    except ValueError:
        return None

# state: convId -> {"ts": iso, "epoch": float}
seeded = os.path.exists(state_file)
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)
# convId -> {"count": n, "ts": latest_iso, "epoch": latest_epoch}
pending = {}

try:
    with open(journal_file) as f:
        lines = f.readlines()
except Exception:
    lines = []

for line in lines:
    # Gate on the definitive lane-leak marker: an abort that did NOT free the
    # lane. released>0 means recovery succeeded — never alert on that.
    if "stuck session recovery outcome:" not in line:
        continue
    if "action=abort_embedded_run" not in line:
        continue
    if "released=0" not in line:
        continue
    conv_m = CONV_RE.search(line)
    if not conv_m:
        continue  # not an intercom support lane we can route
    conv_id = conv_m.group("convId")
    ts_m = TS_RE.search(line)
    ts = ts_m.group(1) if ts_m else ""
    epoch = parse_epoch(ts) or 0.0
    cur = pending.get(conv_id)
    if cur is None or epoch >= cur["epoch"]:
        pending[conv_id] = {
            "count": (cur["count"] + 1) if cur else 1,
            "ts": ts or (cur["ts"] if cur else ""),
            "epoch": epoch,
        }
    else:
        pending[conv_id]["count"] += 1

alerts = []  # (conv_id, count, ts)
for conv_id, info in pending.items():
    prev = state.get(conv_id)
    prev_epoch = prev.get("epoch", 0.0) if isinstance(prev, dict) else 0.0
    # Alert unless we paged this conv within the cooldown window.
    # `0 <= elapsed`, not just `elapsed < cooldown`: a FUTURE-dated watermark
    # (clock correction, manual state repair) makes elapsed NEGATIVE, and every
    # negative value satisfies `< cooldown`, so a real wedge would be suppressed
    # until wall time caught up. A negative elapsed is corrupt state and falls
    # through to alert, which rewrites and self-heals it.
    _elapsed = (info["epoch"] - prev_epoch) if (info["epoch"] and prev_epoch) else None
    within_cooldown = prev is not None and _elapsed is not None and 0 <= _elapsed < cooldown
    if not seeded:
        # First-ever run: seed EVERY observed conv so the backlog never pages.
        new_state[conv_id] = {"ts": info["ts"], "epoch": info["epoch"]}
        continue
    if within_cooldown:
        # Do NOT advance the watermark on a suppressed tick. This is the
        # last-ALERT epoch, not last-seen: a conv that stays wedged emits fresh
        # aborts every tick, so advancing here slides the window forward forever
        # and the conv pages once and then never again.
        continue
    new_state[conv_id] = {"ts": info["ts"], "epoch": info["epoch"]}
    alerts.append((conv_id, info["count"], info["ts"]))

# Prune the conv set so it can't grow unbounded (keep most recent 2000 by epoch).
if len(new_state) > 2000:
    new_state = dict(
        sorted(new_state.items(),
               key=lambda kv: (kv[1].get("epoch", 0.0) if isinstance(kv[1], dict) else 0.0))[-2000:]
    )

if persist:
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: a[2])

def conv_ref(conv_id):
    if workspace:
        url = f"https://app.intercom.com/a/inbox/{workspace}/inbox/conversation/{conv_id}"
        return f"<{url}|#{conv_id}>"
    return f"#{conv_id}"

lines_out = [
    f":rotating_light: *Stuck support lane(s) — reply discarded ({len(alerts)})*",
    "The edge gateway force-aborted a wedged agent run WITHOUT releasing the lane "
    "(`action=abort_embedded_run … released=0`), so Caroline's generated reply was "
    "discarded (upstream openclaw #97538). The customer got no bot reply — please "
    "check #cs-escalations / pick these up.",
]
for conv_id, count, ts in alerts:
    lines_out.append(f"• conv {conv_ref(conv_id)} — {count} abort(s) at {ts or '?'}")
text = "\n".join(lines_out)

with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# capture_live_lanes <profile> <out_file>
# Snapshot one profile's live lane table. Returns the gateway call's status —
# never `|| true`. An unreadable snapshot means we observed NOTHING, which is
# not the same as nothing being wrong, and the caller refuses on it.
# ──────────────────────────────────────────────────────────────
capture_live_lanes() {
  local profile="$1" out="$2"
  if [ -n "$LIVE_SNAPSHOT_DIR" ]; then
    # Test seam: a pre-captured snapshot stands in for the gateway.
    [ -f "$LIVE_SNAPSHOT_DIR/$profile.json" ] || return 3
    cat "$LIVE_SNAPSHOT_DIR/$profile.json" > "$out" || return 3
    return 0
  fi
  "$OPENCLAW_BIN" --profile "$profile" gateway call diagnostics.lanes --json > "$out" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────
# scan_wedged_lanes_live — detector 2's pure core (see header).
#   $1 snapshot_dir  $2 state_file  $3 payload_out  $4 persist(0|1)
# Reads <snapshot_dir>/<profile>.json for each profile in $LIVE_PROFILES,
# advances a per-lane consecutive-wedge streak, and alerts on lanes whose streak
# reaches LIVE_MIN_TICKS and whose last alert is older than COOLDOWN.
# ──────────────────────────────────────────────────────────────
scan_wedged_lanes_live() {
  SNAPSHOT_DIR="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" PERSIST="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" COOLDOWN="$COOLDOWN" MIN_TICKS="$LIVE_MIN_TICKS" \
  PROFILES="$LIVE_PROFILES" python3 - <<'PYLIVE'
import json, os, time

snapshot_dir = os.environ["SNAPSHOT_DIR"]
state_file   = os.environ["STATE_FILE"]
payload_out  = os.environ["PAYLOAD_OUT"]
persist      = os.environ.get("PERSIST", "1") == "1"
channel      = os.environ["SLACK_CHANNEL"]
cooldown     = int(os.environ.get("COOLDOWN", "21600"))
min_ticks    = max(1, int(os.environ.get("MIN_TICKS", "3")))
profiles     = os.environ.get("PROFILES", "main edge").split()

now = time.time()
seeded = os.path.exists(state_file)
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = {}
alerts = []

for profile in profiles:
    path = os.path.join(snapshot_dir, f"{profile}.json")
    try:
        with open(path) as f:
            snap = json.load(f)
    except Exception:
        # The caller already refused on a failed capture; a snapshot that is
        # missing HERE would silently drop a profile, so skip it without
        # touching its lanes' streaks rather than resetting them to healthy.
        for key, val in state.items():
            if key.startswith(f"{profile}\t"):
                new_state[key] = val
        continue
    lanes = snap.get("lanes")
    if not isinstance(lanes, list):
        for key, val in state.items():
            if key.startswith(f"{profile}\t"):
                new_state[key] = val
        continue

    for lane in lanes:
        if not isinstance(lane, dict):
            continue
        name = lane.get("lane")
        if not isinstance(name, str) or not name:
            continue
        queued = lane.get("queuedCount")
        active = lane.get("activeCount")
        maxc   = lane.get("maxConcurrent")
        if not all(isinstance(v, int) for v in (queued, active, maxc)):
            continue   # malformed row: never guess
        key = f"{profile}\t{name}"
        prev = state.get(key) if isinstance(state.get(key), dict) else {}
        prev_epoch = prev.get("epoch", 0.0) or 0.0

        # maxConcurrent == 0 is an administratively DISABLED lane. It can never
        # run anything, so queued work there is a config question, not a wedge.
        wedged = queued > 0 and active == 0 and maxc > 0
        if not wedged:
            continue   # healthy: drop the key, which resets the streak

        streak = int(prev.get("streak", 0) or 0) + 1
        entry = {"streak": streak, "epoch": prev_epoch, "queued": queued,
                 "draining": bool(lane.get("draining")),
                 "blockedBy": lane.get("blockedBy")}

        if streak < min_ticks:
            new_state[key] = entry      # building toward the threshold
            continue

        _elapsed = (now - prev_epoch) if prev_epoch else None
        within_cooldown = _elapsed is not None and 0 <= _elapsed < cooldown
        if not seeded:
            entry["epoch"] = now        # first-ever run seeds silently
            new_state[key] = entry
            continue
        if within_cooldown:
            new_state[key] = entry      # keep the streak, do NOT re-arm epoch
            continue
        entry["epoch"] = now
        new_state[key] = entry
        alerts.append((profile, name, entry))

if persist:
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: -a[2]["queued"])
lines_out = [
    f":warning: *Wedged lane(s) — work queued with nothing running ({len(alerts)})*",
    f"Read from the gateway's own `diagnostics.lanes`, not inferred from logs: each lane "
    f"below has `queuedCount > 0` and `activeCount == 0` on {min_ticks} consecutive checks "
    f"(~{min_ticks * 2} min), so admission is genuinely stalled rather than momentarily between tasks.",
]
for profile, name, e in alerts:
    extra = []
    if e.get("draining"):
        extra.append("draining=true")
    if e.get("blockedBy"):
        extra.append(f"blockedBy={e['blockedBy']}")
    suffix = f" ({', '.join(extra)})" if extra else ""
    lines_out.append(f"• *{profile}* — `{name}` queued={e['queued']} active=0, "
                     f"{e['streak']} consecutive checks{suffix}")
lines_out.append(
    "_Detection only — no auto-heal._ Confirm with "
    "`openclaw --profile <p> gateway call diagnostics.lanes --json` before acting. A gateway "
    "restart is the only known clearer and restarts are customer-visible, so that is a human call."
)
text = "\n".join(lines_out)

with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYLIVE
}

# ──────────────────────────────────────────────────────────────
# scan_lane_latency — detector 3's pure core (see header).
#   $1 journal_dir  $2 state_file  $3 payload_out  $4 persist(0|1)
# Reads <journal_dir>/<unit>.txt per unit in $LATENCY_UNITS and reports lanes
# whose worst COMPLETED wait crossed LATENCY_MIN_MS. Dedupes per lane on
# COOLDOWN so one bad afternoon does not page per tick.
# ──────────────────────────────────────────────────────────────
scan_lane_latency() {
  JOURNAL_DIR="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" PERSIST="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" COOLDOWN="$COOLDOWN" MIN_MS="$LATENCY_MIN_MS" \
  UNITS="$LATENCY_UNITS" python3 - <<'PYLAT'
import json, os, re
from datetime import datetime

journal_dir = os.environ["JOURNAL_DIR"]
state_file  = os.environ["STATE_FILE"]
payload_out = os.environ["PAYLOAD_OUT"]
persist     = os.environ.get("PERSIST", "1") == "1"
channel     = os.environ["SLACK_CHANNEL"]
cooldown    = int(os.environ.get("COOLDOWN", "21600"))
min_ms      = int(os.environ.get("MIN_MS", "600000"))
units       = os.environ.get("UNITS", "").split()

LANE_RE = re.compile(r"lane=(?P<lane>\S+)")
WAIT_RE = re.compile(r"waitedMs=(?P<waitedMs>\d+)")
TS_RE   = re.compile(r"(\d{4}-\d{2}-\d{2}T[\d:.]+(?:[+-]\d{2}:?\d{2}|Z))")
AGENT_RE = re.compile(r"^session:agent:(?P<agent>[a-z0-9_-]+)")

def parse_epoch(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None

seeded = os.path.exists(state_file)
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

new_state = dict(state)
pending = {}

for unit in units:
    path = os.path.join(journal_dir, f"{unit}.txt")
    try:
        with open(path) as f:
            lines = f.readlines()
    except Exception:
        # The caller refuses on a failed capture; a file missing HERE must not
        # be read as "this unit had no slow lanes".
        continue
    for line in lines:
        if "lane wait exceeded" not in line:
            continue
        lane_m, wait_m = LANE_RE.search(line), WAIT_RE.search(line)
        if not (lane_m and wait_m):
            continue      # malformed / format change: never guess
        waited = int(wait_m.group("waitedMs"))
        if waited < min_ms:
            continue
        lane = lane_m.group("lane")
        ts_m = TS_RE.search(line)
        ts = ts_m.group(1) if ts_m else ""
        epoch = parse_epoch(ts) or 0.0
        cur = pending.get(lane)
        # Worst wait per lane — that is the number a human judges.
        if cur is None or waited > cur["waitedMs"]:
            pending[lane] = {"waitedMs": waited, "ts": ts, "epoch": epoch,
                             "unit": unit, "count": (cur["count"] + 1) if cur else 1}
        else:
            cur["count"] += 1
            if epoch > cur["epoch"]:
                cur["epoch"], cur["ts"] = epoch, ts

alerts = []
for lane, info in pending.items():
    prev = state.get(lane)
    prev_epoch = prev.get("epoch", 0.0) if isinstance(prev, dict) else 0.0
    # `0 <= elapsed`: a future-dated watermark makes elapsed negative and every
    # negative value satisfies `< cooldown`, which would suppress forever.
    _elapsed = (info["epoch"] - prev_epoch) if (info["epoch"] and prev_epoch) else None
    within_cooldown = prev is not None and _elapsed is not None and 0 <= _elapsed < cooldown
    if not seeded:
        new_state[lane] = {"ts": info["ts"], "epoch": info["epoch"]}
        continue
    if within_cooldown:
        # Do NOT advance on a suppressed tick: this is the last-ALERT epoch, and
        # advancing it slides the window forward every tick so a lane pages once
        # and then never again.
        continue
    new_state[lane] = {"ts": info["ts"], "epoch": info["epoch"]}
    alerts.append((lane, info))

if len(new_state) > 2000:
    new_state = dict(sorted(new_state.items(),
        key=lambda kv: (kv[1].get("epoch", 0.0) if isinstance(kv[1], dict) else 0.0))[-2000:])

if persist:
    d = os.path.dirname(state_file)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(new_state, f, indent=2)
    os.replace(tmp, state_file)

if not alerts:
    raise SystemExit(0)

alerts.sort(key=lambda a: -a[1]["waitedMs"])
mins = min_ms / 60000.0
lines_out = [
    f":hourglass: *Slow agent replies — queued work waited a long time ({len(alerts)})*",
    f"Each lane below had a task sit queued for over {mins:.0f} minutes before it started. "
    f"These waits have ALREADY ENDED — this is a latency report, not a live wedge "
    f"(`live-lanes` covers that). Nothing else surfaces it: a person waiting this long "
    f"for an agent reply otherwise produces no signal.",
]
for lane, e in alerts:
    agent_m = AGENT_RE.match(lane)
    agent = agent_m.group("agent") if agent_m else "?"
    extra = f", {e['count']} slow starts" if e["count"] > 1 else ""
    prof = e["unit"].replace("openclaw-gateway-", "")
    lines_out.append(f"• *{agent}* — `{lane}` waited {e['waitedMs'] / 60000.0:.1f} min"
                     f"{extra} ({prof}), last {e['ts'] or '?'}")
lines_out.append(
    "_Informational — no action implied._ If the same lane keeps appearing, check whether "
    "it is genuinely wedging (`gateway call diagnostics.lanes`) rather than merely busy."
)
text = "\n".join(lines_out)

with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYLAT
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (~30ms). Guards the failure that
# would make THIS watchdog itself rot silently: a detector that no longer
# detects, or one that fires on a lane that WAS released. Throwaway temp paths.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out bullets
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  # Pre-seeded state (so the conv is "new", not seed-suppressed). One abort that
  # did NOT release the lane (released=0 → must FIRE) and one that DID
  # (released=1 → must be SUPPRESSED), proving the released=0 gate.
  cat > "$td/journal.txt" <<'JNL'
2026-06-30T18:25:52.812+00:00 ovh-node-8 node[1]: 2026-06-30T18:25:52.812+00:00 [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-wedged sessionKey=agent:support:intercom:direct:215474906522805 activeSessionId=x activeWorkKind=embedded_run lane=session:agent:support:intercom:direct:215474906522805 aborted=true drained=true forceCleared=false released=0
2026-06-30T18:26:52.000+00:00 ovh-node-8 node[1]: 2026-06-30T18:26:52.000+00:00 [diagnostic] stuck session recovery outcome: status=aborted action=abort_embedded_run sessionId=sess-freed sessionKey=agent:support:intercom:direct:999999999999999 activeSessionId=y activeWorkKind=embedded_run lane=session:agent:support:intercom:direct:999999999999999 aborted=true drained=true forceCleared=true released=1
JNL
  printf '%s\n' '{"seed":{"ts":"2026-01-01T00:00:00Z","epoch":1}}' > "$td/state.json"
  out="$(COOLDOWN=21600 WORKSPACE="" scan_stuck_lanes "$td/journal.txt" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "215474906522805"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the released=0 abort" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -q "999999999999999"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector flagged a released=1 (lane-freed) abort" >&2
    return 1
  fi
  bullets="$(printf '%s\n' "$out" | grep -c '^• ' || true)"
  if [ "$bullets" != "1" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: expected 1 alert bullet, got $bullets" >&2
    return 1
  fi
  return 0
}

# Detector 2's own self-test. Four synthetic lanes pin the whole discriminator:
# wedged-and-over-threshold must FIRE; nothing-queued, something-active, and a
# maxConcurrent=0 disabled lane must all be SUPPRESSED.
_self_test_live_lanes() {
  local td out bullets
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  mkdir -p "$td/snap"
  cat > "$td/snap/main.json" <<'SNAP'
{"ts":1,"lanes":[
 {"lane":"session:agent:wedged:main","queuedCount":3,"activeCount":0,"maxConcurrent":1,"draining":false,"generation":0,"blockedBy":null},
 {"lane":"session:agent:emptyqueue:main","queuedCount":0,"activeCount":0,"maxConcurrent":1,"draining":false,"generation":0,"blockedBy":null},
 {"lane":"session:agent:busy:main","queuedCount":3,"activeCount":1,"maxConcurrent":1,"draining":false,"generation":0,"blockedBy":null},
 {"lane":"hook-dispatch","queuedCount":3,"activeCount":0,"maxConcurrent":0,"draining":false,"generation":0,"blockedBy":"lane"}
]}
SNAP
  # Pre-seeded state: the wedged lane already has streak 2, so this tick is its
  # third consecutive observation and it crosses MIN_TICKS.
  printf '%s\n' '{"main\tsession:agent:wedged:main":{"streak":2,"epoch":0}}' > "$td/state.json"
  out="$(COOLDOWN=21600 LIVE_MIN_TICKS=3 LIVE_PROFILES=main \
        scan_wedged_lanes_live "$td/snap" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "session:agent:wedged:main"; then
    echo "$LOGPREFIX SELF-TEST FAIL: live detector missed a wedged lane at its threshold" >&2
    return 1
  fi
  local bad
  for bad in emptyqueue busy hook-dispatch; do
    if printf '%s' "$out" | grep -q "$bad"; then
      echo "$LOGPREFIX SELF-TEST FAIL: live detector flagged '$bad' (must be suppressed)" >&2
      return 1
    fi
  done
  bullets="$(printf '%s\n' "$out" | grep -c '^• ' || true)"
  if [ "$bullets" != "1" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: live detector expected 1 alert bullet, got $bullets" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed — refusing to run with a broken detector"
  exit 3
fi

if ! _self_test_live_lanes; then
  log "ABORT: live-lane self-test failed — refusing to run with a broken detector"
  exit 3
fi

# Detector 3's self-test: one wait over the floor must FIRE, one under it must
# not, and a malformed line must be skipped rather than guessed at.
_self_test_lane_latency() {
  local td out bullets
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  mkdir -p "$td/j"
  cat > "$td/j/openclaw-gateway-main.txt" <<'JNL'
2026-09-17T01:00:00.000+00:00 node[1]: [diagnostic] lane wait exceeded: lane=session:agent:slowlane:main waitedMs=900000 queueAhead=0 activeAhead=1 activeNow=0 queueBehind=0
2026-09-17T01:01:00.000+00:00 node[1]: [diagnostic] lane wait exceeded: lane=session:agent:fastlane:main waitedMs=5000 queueAhead=0 activeAhead=1 activeNow=0 queueBehind=0
2026-09-17T01:02:00.000+00:00 node[1]: [diagnostic] lane wait exceeded: lane=session:agent:malformed:main queueAhead=0 activeAhead=1 activeNow=0 queueBehind=0
JNL
  printf '%s\n' '{"seed":{"ts":"2026-01-01T00:00:00Z","epoch":1}}' > "$td/state.json"
  out="$(COOLDOWN=21600 LATENCY_MIN_MS=600000 LATENCY_UNITS=openclaw-gateway-main \
        scan_lane_latency "$td/j" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "slowlane"; then
    echo "$LOGPREFIX SELF-TEST FAIL: latency detector missed a wait over the floor" >&2
    return 1
  fi
  local bad
  for bad in fastlane malformed; do
    if printf '%s' "$out" | grep -q "$bad"; then
      echo "$LOGPREFIX SELF-TEST FAIL: latency detector flagged '$bad' (must be suppressed)" >&2
      return 1
    fi
  done
  bullets="$(printf '%s\n' "$out" | grep -c '^• ' || true)"
  if [ "$bullets" != "1" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: latency detector expected 1 bullet, got $bullets" >&2
    return 1
  fi
  return 0
}

if ! _self_test_lane_latency; then
  log "ABORT: lane-latency self-test failed — refusing to run with a broken detector"
  exit 3
fi

# ──────────────────────────────────────────────────────────────
# Host guard: wrong node → no-op. Skippable for tests.
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another stuck-lane-watchdog run holds $LOCKFILE"; exit 0; }
fi

# Capture the journal window (unless a fixture was supplied for tests).
# The capture STATUS is preserved, not `|| true`: an unreadable journal yields an
# empty file, the scan reads zero lines, and the detector would report "nothing
# new" having observed NOTHING. An EMPTY but SUCCESSFUL capture (rc 0, no
# matching lines) is healthy-quiet and stays silent.
CLEANUP_JOURNAL=0
EDGE_CAPTURE_RC=0
if [ -z "$JOURNAL_FILE" ]; then
  JOURNAL_FILE="$(mktemp)"
  CLEANUP_JOURNAL=1
  journalctl -u "$GATEWAY_UNIT" --since "$LOOKBACK" --no-pager -o short-iso 2>/dev/null > "$JOURNAL_FILE" || EDGE_CAPTURE_RC=$?
fi

# Snapshot each profile's live lane table. Same rule: a failed capture refuses.
LIVE_SNAP_DIR="$(mktemp -d)"
LIVE_CAPTURE_RC=0
if [ -z "$LIVE_SNAPSHOT_DIR" ]; then
  for _p in $LIVE_PROFILES; do
    # `|| LIVE_CAPTURE_RC=$?`, NOT `if ! capture …; then rc=$?`. Inside the body
    # of a negated condition `$?` is the status of the NEGATION, which is always
    # 0 — so the failure would be recorded as success. My own capture-failure
    # test caught exactly that.
    LIVE_CAPTURE_RC=0
    capture_live_lanes "$_p" "$LIVE_SNAP_DIR/$_p.json" || LIVE_CAPTURE_RC=$?
    if [ "$LIVE_CAPTURE_RC" -ne 0 ]; then
      # Name the profile HERE — the shared _run_detector cannot know which one
      # failed, and "the capture failed" without a profile is a worse page.
      log "LANE-SNAPSHOT-FAILED: \`gateway call diagnostics.lanes\` for profile '$_p' exited $LIVE_CAPTURE_RC"
      break
    fi
  done
  LIVE_SNAPSHOT_DIR="$LIVE_SNAP_DIR"
fi

# Per-unit journal captures for the latency detector. Status preserved, not
# `|| true`: an unreadable journal means we measured NOTHING, which is not the
# same as no slow lanes.
LAT_JOURNAL_DIR="$(mktemp -d)"
LATENCY_CAPTURE_RC=0
if [ -z "$LATENCY_JOURNAL_DIR" ]; then
  for _u in $LATENCY_UNITS; do
    LATENCY_CAPTURE_RC=0
    journalctl -u "$_u" --since "$LOOKBACK" --no-pager -o short-iso 2>/dev/null \
      > "$LAT_JOURNAL_DIR/$_u.txt" || LATENCY_CAPTURE_RC=$?
    if [ "$LATENCY_CAPTURE_RC" -ne 0 ]; then
      log "LATENCY-JOURNAL-FAILED: journalctl for '$_u' exited $LATENCY_CAPTURE_RC"
      break
    fi
  done
  LATENCY_JOURNAL_DIR="$LAT_JOURNAL_DIR"
fi

PAYLOAD_DIR="$(mktemp -d)"
DRY_STATE_DIR=""
trap '[ "$CLEANUP_JOURNAL" -eq 1 ] && rm -f "$JOURNAL_FILE"; rm -rf "$PAYLOAD_DIR" "$LIVE_SNAP_DIR" "$LAT_JOURNAL_DIR" ${DRY_STATE_DIR:+"$DRY_STATE_DIR"}' EXIT

# --dry-run must not consume a production watermark. Shadow any state path still
# at its DEFAULT with a temp copy; an absent source stays absent in the copy, so
# first-run semantics are rehearsed faithfully too.
if [ "$DRY_RUN" -eq 1 ]; then
  DRY_STATE_DIR="$(mktemp -d)"
  if [ "$EDGE_STATE_EXPLICIT" -eq 0 ]; then
    cp "$STATE_FILE" "$DRY_STATE_DIR/edge.json" 2>/dev/null || true
    STATE_FILE="$DRY_STATE_DIR/edge.json"
    log "DRY-RUN: edge watermark shadowed (production state will NOT be mutated)."
  fi
  if [ "$LIVE_STATE_EXPLICIT" -eq 0 ]; then
    cp "$LIVE_STATE_FILE" "$DRY_STATE_DIR/live.json" 2>/dev/null || true
    LIVE_STATE_FILE="$DRY_STATE_DIR/live.json"
    log "DRY-RUN: live-lane watermark shadowed (production state will NOT be mutated)."
  fi
  if [ "$LATENCY_STATE_EXPLICIT" -eq 0 ]; then
    cp "$LATENCY_STATE_FILE" "$DRY_STATE_DIR/latency.json" 2>/dev/null || true
    LATENCY_STATE_FILE="$DRY_STATE_DIR/latency.json"
    log "DRY-RUN: lane-latency watermark shadowed (production state will NOT be mutated)."
  fi
fi

# ──────────────────────────────────────────────────────────────
# _run_detector <label> <scan_fn> <input> <state_file> <quiet_msg> <capture_rc>
# One detector's detect → deliver → commit cycle. Returns 0 on nothing-to-do or
# a confirmed delivery, 1 when a capture failed, the scan crashed, or a post was
# attempted and NOT confirmed.
#
# Detect WITHOUT persisting (PERSIST=0): the watermark may only advance once the
# alert is actually delivered, else a token/channel/CLI outage marks the wedge
# "seen" and the only out-of-process page is never retried. The commit re-runs
# the scan over the SAME captured input with PERSIST=1 (deterministic: identical
# input + unchanged state ⇒ identical detection, now written).
#
# quiet_msg is a PARAMETER, not derived from the label: the edge detector's
# "OK: no new stuck/discarded lanes." is an operator-visible log contract that
# existing tests assert on.
# ──────────────────────────────────────────────────────────────
_run_detector() {
  local label="$1" scan_fn="$2" input="$3" state="$4" quiet_msg="$5" capture_rc="${6:-0}"
  local alert_block payload rc=0 crc=0

  if [ "$capture_rc" -ne 0 ]; then
    log "CAPTURE-FAILED[$label]: input capture exited $capture_rc, so this tick observed NOTHING and that is not the same as nothing being wrong. State NOT advanced; the next cron tick retries."
    return 1
  fi

  payload="${PAYLOAD_DIR}/${label}.json"
  # Capture the scan's STATUS, never `|| true`. The scan exits 0 both with and
  # without alerts, so a non-zero status is a genuine crash.
  alert_block="$("$scan_fn" "$input" "$state" "$payload" 0)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "DETECTOR-FAILED[$label]: $scan_fn exited $rc — this tick detected NOTHING. State NOT advanced."
    return 1
  fi

  if [ -z "$alert_block" ]; then
    "$scan_fn" "$input" "$state" /dev/null 1 >/dev/null || crc=$?
    if [ "$crc" -ne 0 ]; then
      log "STATE-COMMIT-FAILED[$label]: $scan_fn exited $crc while persisting."
      return 1
    fi
    log "$quiet_msg"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN[$label]: would post the following to ${SLACK_CHANNEL}:"
    printf '%s\n' "$alert_block"
    "$scan_fn" "$input" "$state" /dev/null 1 >/dev/null || crc=$?
    [ "$crc" -eq 0 ] || { log "STATE-COMMIT-FAILED[$label]: exited $crc"; return 1; }
    return 0
  fi

  log "Posting [$label] alert to ${SLACK_CHANNEL}."
  printf '%s\n' "$alert_block"
  if slack_notify_payload_file_status "$payload"; then
    "$scan_fn" "$input" "$state" /dev/null 1 >/dev/null || crc=$?
    [ "$crc" -eq 0 ] || { log "STATE-COMMIT-FAILED[$label]: alert WAS delivered but persisting exited $crc — expect a duplicate page next tick."; return 1; }
    return 0
  fi
  log "ALERT-DELIVERY-FAILED[$label]: Slack post not confirmed — state NOT advanced; the next cron tick will re-detect and retry."
  return 1
}

# Both detectors always run: they cover different surfaces, and the edge
# reply-loss alarm is the one with a customer on the other end.
RC=0
_run_detector "edge-intercom" scan_stuck_lanes "$JOURNAL_FILE" "$STATE_FILE" \
  "OK: no new stuck/discarded lanes." "$EDGE_CAPTURE_RC" || RC=1
_run_detector "live-lanes" scan_wedged_lanes_live "$LIVE_SNAPSHOT_DIR" "$LIVE_STATE_FILE" \
  "OK[live-lanes]: no lane queued with nothing running." "$LIVE_CAPTURE_RC" || RC=1
_run_detector "lane-latency" scan_lane_latency "$LATENCY_JOURNAL_DIR" "$LATENCY_STATE_FILE" \
  "OK[lane-latency]: no lane waited past the floor." "$LATENCY_CAPTURE_RC" || RC=1
exit "$RC"

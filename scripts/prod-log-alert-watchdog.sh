#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Prod Log Alert Watchdog
#
# Posts NEW production error-log lines to #prod-alerts (C0BA8QMV3ME)
# so engineers (Serhii asked for this, 2026-06-09) see prod errors
# without pinging the devops agent. Deliberately a deterministic
# system-cron bash watchdog — NOT an openclaw cron — so it fires even
# when the gateway is down and never depends on an LLM (same shape as
# cron-health-watchdog.sh, which it copies).
#
# Detection model: every tick, pull the last WINDOW of logs for each
# "namespace deployment" row in the shared allowlist
# (skills-all/muso-devops-prod-logs/config/deployments.txt) through
# fetch-prod-logs.sh (read-only kubectl + redaction), filtered by the
# STRICT alert pattern (config/alert-patterns.txt — no bare "error"),
# minus known-benign noise (config/alert-exclude-patterns.txt).
# Each matched line is normalized (timestamps/UUIDs/hex/numbers
# stripped) and fingerprinted; a fingerprint alerts at most once per
# COOLDOWN (default 6h). One consolidated Slack post per tick. State
# advances ONLY on a confirmed Slack delivery so an undelivered alert
# retries next tick.
#
# A 6-minute window on a 5-minute cadence overlaps by design; the
# fingerprint dedupe absorbs the duplicates.
#
# Runs every 5 min via /etc/cron.d/prod-log-alert-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh). Must run
# as root — needs kubectl and the devops bot token.
#
# Flags:
#   --dry-run   compute + print the alert block, do NOT post to Slack.
#               State IS advanced (faithful dedupe rehearsal) — point
#               PROD_LOG_ALERT_STATE_FILE at a throwaway path.
#
# Env knobs (mainly for tests):
#   PROD_LOG_ALERT_CHANNEL       target channel (default C0BA8QMV3ME #prod-alerts)
#   PROD_LOG_ALERT_CONFIG_DIR    dir with deployments.txt + alert-patterns.txt
#   PROD_LOG_ALERT_STATE_FILE    fingerprint→last-alerted store
#   PROD_LOG_ALERT_WINDOW        log window per tick (default 6m)
#   PROD_LOG_ALERT_COOLDOWN      per-fingerprint re-alert suppression, seconds (default 21600)
#   PROD_LOG_ALERT_SLACK_CONFIG  openclaw config holding the devops token
#   PROD_LOG_ALERT_LOCKFILE      single-run lock
#   PROD_LOG_ALERT_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
#   PROD_LOG_FETCH_BIN           fetch-prod-logs.sh override (tests)
#   PROD_LOG_ALERT_NOW           epoch override for cooldown math (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[prod-log-alert-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
_WD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FETCH_BIN="${PROD_LOG_FETCH_BIN:-$_WD_DIR/../skills-all/muso-devops-prod-logs/scripts/fetch-prod-logs.sh}"
CONFIG_DIR="${PROD_LOG_ALERT_CONFIG_DIR:-$_WD_DIR/../skills-all/muso-devops-prod-logs/config}"
STATE_FILE="${PROD_LOG_ALERT_STATE_FILE:-/var/lib/prod-log-alert/seen.json}"
LOCKFILE="${PROD_LOG_ALERT_LOCKFILE:-/var/run/prod-log-alert-watchdog.lock}"
SKIP_HOST_GUARD="${PROD_LOG_ALERT_SKIP_HOST_GUARD:-0}"
WINDOW="${PROD_LOG_ALERT_WINDOW:-6m}"
COOLDOWN="${PROD_LOG_ALERT_COOLDOWN:-21600}"
TAIL_PER_POD="${PROD_LOG_ALERT_TAIL:-200}"
MAX_PER_DEPLOY="${PROD_LOG_ALERT_MAX_PER_DEPLOY:-5}"
MAX_TOTAL="${PROD_LOG_ALERT_MAX_TOTAL:-40}"
DRY_RUN=0

# slack-notify.sh reads these; export before sourcing so its `:=` defaults
# don't override us.
export SLACK_CHANNEL="${PROD_LOG_ALERT_CHANNEL:-C0BA8QMV3ME}"  # #prod-alerts
export SLACK_NOTIFY_CONFIG="${PROD_LOG_ALERT_SLACK_CONFIG:-/root/.openclaw-main/openclaw.json}"

log() { echo "$LOGPREFIX $1"; }

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/slack-notify.sh
source "$_WD_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# ──────────────────────────────────────────────────────────────
# build_alert — the pure detection core.
#   $1 collect_dir  $2 state_file  $3 payload_out  $4 marks_out
# collect_dir holds <ns>__<dep>.log files (matched, already-redacted lines)
# and <ns>__<dep>.fetchfail files (fetch errors — the watchdog being blind
# is itself alert-worthy). Prints the human-readable alert block to stdout
# (empty == nothing new); writes the Slack payload and the fingerprints to
# mark. Does NOT touch the state file — marks are merged separately, only
# after a confirmed delivery.
# ──────────────────────────────────────────────────────────────
build_alert() {
  COLLECT_DIR="$1" STATE_FILE="$2" PAYLOAD_OUT="$3" MARKS_OUT="$4" \
  SLACK_CHANNEL="$SLACK_CHANNEL" COOLDOWN="$COOLDOWN" WINDOW="$WINDOW" \
  MAX_PER_DEPLOY="$MAX_PER_DEPLOY" MAX_TOTAL="$MAX_TOTAL" \
  NOW="${PROD_LOG_ALERT_NOW:-}" python3 - <<'PYEOF'
import glob, hashlib, json, os, re, time

collect     = os.environ["COLLECT_DIR"]
state_file  = os.environ["STATE_FILE"]
payload_out = os.environ["PAYLOAD_OUT"]
marks_out   = os.environ["MARKS_OUT"]
channel     = os.environ["SLACK_CHANNEL"]
cooldown    = int(os.environ["COOLDOWN"])
window      = os.environ["WINDOW"]
max_per     = int(os.environ["MAX_PER_DEPLOY"])
max_total   = int(os.environ["MAX_TOTAL"])
now         = float(os.environ.get("NOW") or time.time())

def normalize(line):
    """Strip the volatile parts so the same logical error fingerprints
    identically across pods, requests, and ticks."""
    s = re.sub(r"^\[[^\]]+\]\s*", "", line)  # [pod-name] prefix
    s = re.sub(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?", "<TS>", s)
    s = re.sub(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "<UUID>", s)
    s = re.sub(r"0x[0-9a-fA-F]+", "<HEX>", s)
    s = re.sub(r"\b[0-9a-fA-F]{12,}\b", "<HEX>", s)
    s = re.sub(r"\d+", "<N>", s)
    return s.strip()

def fp(label, norm):
    return hashlib.sha256(f"{label}|{norm}".encode()).hexdigest()

def slack_escape(s):
    """Log lines are untrusted text headed for Slack mrkdwn: a logged
    <!channel>/<!here>/<@U...> would ping for real. Escape Slack's control
    characters (the three the API docs require)."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

groups = []   # (label, [(display, count)])
marks = {}
suppressed_overflow = 0

for path in sorted(glob.glob(os.path.join(collect, "*.log"))):
    label = os.path.basename(path)[:-len(".log")].replace("__", "/")
    seen_norms = {}  # norm -> [display, count]
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            norm = normalize(line)
            if norm in seen_norms:
                seen_norms[norm][1] += 1
                continue
            seen_norms[norm] = [line, 1]
    fresh = []
    for norm, (display, count) in seen_norms.items():
        h = fp(label, norm)
        if now - state.get(h, float("-inf")) < cooldown:
            continue
        if len(display) > 220:
            display = display[:220] + "…"
        fresh.append((slack_escape(display), count, h))
    if not fresh:
        continue
    kept = fresh[:max_per]
    suppressed_overflow += len(fresh) - len(kept)
    for _, _, h in kept:
        marks[h] = now
    groups.append((label, [(d, c) for d, c, _ in kept]))

for path in sorted(glob.glob(os.path.join(collect, "*.fetchfail"))):
    label = os.path.basename(path)[:-len(".fetchfail")].replace("__", "/")
    with open(path) as f:
        reason = f.readline().strip() or "unknown error"
    display = f"log fetch FAILED — watchdog is blind to this deployment: {slack_escape(reason)}"
    h = fp(label, "fetchfail|" + normalize(reason))
    if now - state.get(h, float("-inf")) < cooldown:
        continue
    marks[h] = now
    groups.append((label, [(display, 1)]))

if not groups:
    raise SystemExit(0)

lines = [f":rotating_light: *prod log errors — {len(groups)} deployment(s)* (last {window})"]
total = 0
for label, items in groups:
    lines.append(f"*{label}*")
    for display, count in items:
        if total >= max_total:
            suppressed_overflow += 1
            continue
        suffix = f" (x{count})" if count > 1 else ""
        lines.append(f"• {display}{suffix}")
        total += 1
if suppressed_overflow:
    lines.append(f"… +{suppressed_overflow} more distinct line(s) suppressed this tick")
text = "\n".join(lines)

# Build the exact payload in Python — log lines carry quotes/backticks that
# would shatter naive bash JSON interpolation.
with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)
with open(marks_out, "w") as f:
    json.dump(marks, f)

print(text)
PYEOF
}

# merge_marks — fold delivered fingerprints into the state file (atomic),
# pruning entries idle past 14 days so the store stays bounded.
merge_marks() {
  STATE_FILE="$1" MARKS_FILE="$2" NOW="${PROD_LOG_ALERT_NOW:-}" python3 - <<'PYEOF'
import json, os, time
state_file = os.environ["STATE_FILE"]
marks_file = os.environ["MARKS_FILE"]
now = float(os.environ.get("NOW") or time.time())
try:
    with open(state_file) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}
with open(marks_file) as f:
    state.update(json.load(f))
state = {k: v for k, v in state.items() if now - v < 14 * 86400}
d = os.path.dirname(state_file)
if d:
    os.makedirs(d, exist_ok=True)
tmp = state_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f, indent=2)
os.replace(tmp, state_file)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — every invocation (~50ms). Guards the failure that
# would make THIS watchdog rot silently: a detector that no longer
# detects, or a dedupe that no longer dedupes. Throwaway temp paths only.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  mkdir -p "$td/collect"
  printf '%s\n' \
    '[pod-1] 2026-06-09T10:00:00Z Uncaught TypeError: selftest boom id=12345' \
    '[pod-2] 2026-06-09T10:00:03Z Uncaught TypeError: selftest boom id=99887' \
    > "$td/collect/muso-prod__selftest-svc.log"
  out="$(build_alert "$td/collect" "$td/state.json" "$td/payload.json" "$td/marks.json" 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "selftest boom"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not surface the injected error" >&2
    return 1
  fi
  # The two lines differ only in pod + id, so normalization must collapse
  # them into ONE bullet with a (x2) count.
  if ! printf '%s' "$out" | grep -q "(x2)"; then
    echo "$LOGPREFIX SELF-TEST FAIL: normalization did not collapse near-identical lines" >&2
    return 1
  fi
  merge_marks "$td/state.json" "$td/marks.json"
  out="$(build_alert "$td/collect" "$td/state.json" "$td/payload2.json" "$td/marks2.json" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    echo "$LOGPREFIX SELF-TEST FAIL: cooldown dedupe did not suppress a repeat" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed — refusing to run with a broken detector"
  exit 3
fi

# Host guard: wrong node → no-op (prevents an orphaned cron from firing
# after a host migration). Skippable for tests.
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

DEPLOYMENTS_FILE="$CONFIG_DIR/deployments.txt"
PATTERNS_FILE="$CONFIG_DIR/alert-patterns.txt"
[ -r "$DEPLOYMENTS_FILE" ] || { log "ERROR: missing $DEPLOYMENTS_FILE (fail-closed)"; exit 2; }
[ -r "$PATTERNS_FILE" ] || { log "ERROR: missing $PATTERNS_FILE (fail-closed)"; exit 2; }
[ -x "$FETCH_BIN" ] || [ -r "$FETCH_BIN" ] || { log "ERROR: fetch script not found: $FETCH_BIN"; exit 2; }

ALERT_PATTERN="$(grep -Ev '^[[:space:]]*(#|$)' "$PATTERNS_FILE" | paste -sd'|' -)"
[ -n "$ALERT_PATTERN" ] || { log "ERROR: $PATTERNS_FILE has no patterns (fail-closed)"; exit 2; }

# Optional noise exclusion (e.g. debug-level lines whose echoed SQL contains
# "EXCEPTION"). Missing/empty file = no exclusion — the safe direction is
# more alerts, never silently fewer.
EXCLUDE_FILE="$CONFIG_DIR/alert-exclude-patterns.txt"
EXCLUDE_PATTERN=""
if [ -r "$EXCLUDE_FILE" ]; then
  EXCLUDE_PATTERN="$(grep -Ev '^[[:space:]]*(#|$)' "$EXCLUDE_FILE" | paste -sd'|' -)"
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another prod-log-alert-watchdog run holds $LOCKFILE"; exit 0; }
fi

COLLECT_DIR="$(mktemp -d)"
PAYLOAD_FILE="$(mktemp)"
MARKS_FILE="$(mktemp)"
trap 'rm -rf "$COLLECT_DIR" "$PAYLOAD_FILE" "$MARKS_FILE"' EXIT

# Collect: one fetch per allow-listed deployment. The fetch script is shared
# with the on-demand skill, so its config dir must follow ours.
while read -r ns dep _; do
  case "$ns" in ''|\#*) continue ;; esac
  out_file="$COLLECT_DIR/${ns}__${dep}.log"
  err_file="$COLLECT_DIR/${ns}__${dep}.stderr"
  if ! PROD_LOGS_CONFIG_DIR="$CONFIG_DIR" bash "$FETCH_BIN" \
      -n "$ns" -d "$dep" --since "$WINDOW" --tail "$TAIL_PER_POD" \
      --pattern "$ALERT_PATTERN" > "$out_file" 2> "$err_file"; then
    head -1 "$err_file" > "$COLLECT_DIR/${ns}__${dep}.fetchfail"
    rm -f "$out_file"
    log "WARN: fetch failed for $ns/$dep: $(head -1 "$err_file")"
  else
    if [ -n "$EXCLUDE_PATTERN" ] && [ -s "$out_file" ]; then
      grep -Eiv "$EXCLUDE_PATTERN" "$out_file" > "$out_file.tmp" || true
      mv "$out_file.tmp" "$out_file"
    fi
    [ -s "$out_file" ] || rm -f "$out_file"
  fi
  rm -f "$err_file"
done < "$DEPLOYMENTS_FILE"

alert_block="$(build_alert "$COLLECT_DIR" "$STATE_FILE" "$PAYLOAD_FILE" "$MARKS_FILE" || true)"

if [ -z "$alert_block" ]; then
  log "OK: no new prod log errors."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  merge_marks "$STATE_FILE" "$MARKS_FILE"
  exit 0
fi

log "Posting prod-log alert to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
if slack_notify_payload_file_status "$PAYLOAD_FILE"; then
  merge_marks "$STATE_FILE" "$MARKS_FILE"
else
  log "WARN: Slack delivery NOT confirmed — state not advanced, will retry next tick."
fi

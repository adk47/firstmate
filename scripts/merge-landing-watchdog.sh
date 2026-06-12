#!/bin/bash
# ──────────────────────────────────────────────────────────────
# Merge-Landing Watchdog
#
# Alerts #clio_devops when an admin profile-merge was ACCEPTED (HTTP 200,
# logged to recent-merges.jsonl) but never actually LANDED in the catalog.
#
# Why this exists: POST /admin/profiles/merge returns 200 after only
# enqueuing an async ingestion job — core-backend mergeProfiles.js does NOT
# set merged_to_id itself (its own TODO admits "should only execute … once
# receive notification from industry processing side"). The industry-data-
# processing catalog worker is what sets merged_to_id + folds credits, and
# common/process.py catches ANY worker exception, logs it, and DELETES the
# SQS message — no DLQ, no retry. So a merge whose apply throws vanishes
# silently. That is exactly what bit the 2026-06-08/09 Jan ↔ Ops threads:
# two merge pairs (Jens Jungkurth, Shelby Archer) returned 200 four times
# over days and never landed, with nothing surfaced until a human noticed.
#
# This watchdog is the missing detection layer: it reads the merge audit log,
# and for any merge older than MIN_AGE_HOURS whose loser is STILL an active,
# unmerged profile in the catalog (merged_to_id blank, is_deleted=false), it
# pages once. "Landed" = the loser has a non-empty merged_to_id, is soft-
# deleted, or has dropped out of the active catalog view — any of those means
# the async side did its job.
#
# Detection runs against the catalog via /opt/hydra/scripts/trino-query.sh
# (matvw_catalog_profile). Dedupe is per survivor:loser pair in a state file,
# so a persistently-stuck merge pages once, not every tick. If an alerted pair
# later lands (the fold was just slow — e.g. Jan's six merges of 2026-06-10/11
# landed >6h after request), a ✅ all-clear is posted and the pair is dropped
# from the state, so the channel never points humans at an already-landed merge.
#
# Runs every ~30 min via /etc/cron.d/merge-landing-watchdog ON NODE-8
# (installed idempotently by scripts/install-aux-units.sh). Must run as root —
# reads /var/log/muso-ops/ and the devops bot token. 30 min (vs the 5-min
# cron/gateway watchdogs) because the async catalog fold legitimately takes
# minutes–hours; MIN_AGE_HOURS already filters the not-yet-landed window, so a
# tighter cadence would only add Trino load without catching anything sooner.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT post to
#               Slack. State IS still advanced (faithful dedupe rehearsal);
#               point MERGE_LANDING_STATE_FILE at a throwaway path to rehearse
#               without consuming real watermarks.
#
# Env knobs (mainly for tests — defaults target the live node-8 layout):
#   MERGE_LANDING_MERGES_FILE    merge audit log (recent-merges.jsonl)
#   MERGE_LANDING_STATE_FILE     already-alerted survivor:loser set
#   MERGE_LANDING_MIN_AGE_HOURS  only consider merges older than this (default 6)
#   MERGE_LANDING_QUERY_FAIL_COOLDOWN_HOURS  re-page window for catalog-query
#                                failures (BLIND alert), default 6
#   MERGE_LANDING_TRINO_CMD      catalog query command (default trino-query.sh)
#   MERGE_LANDING_CATALOG_TABLE  catalog table (default matvw_catalog_profile)
#   MERGE_LANDING_NOW_EPOCH      override "now" for deterministic tests
#   MERGE_LANDING_LOCKFILE       single-run lock
#   MERGE_LANDING_SLACK_CHANNEL  target channel (default #clio_devops)
#   MERGE_LANDING_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[merge-landing-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
MERGES_FILE="${MERGE_LANDING_MERGES_FILE:-/var/log/muso-ops/recent-merges.jsonl}"
STATE_FILE="${MERGE_LANDING_STATE_FILE:-/var/lib/merge-landing-watchdog/alerted.json}"
LOCKFILE="${MERGE_LANDING_LOCKFILE:-/var/run/merge-landing-watchdog.lock}"
MIN_AGE_HOURS="${MERGE_LANDING_MIN_AGE_HOURS:-6}"
QUERY_FAIL_COOLDOWN_HOURS="${MERGE_LANDING_QUERY_FAIL_COOLDOWN_HOURS:-6}"
TRINO_CMD="${MERGE_LANDING_TRINO_CMD:-/opt/hydra/scripts/trino-query.sh}"
CATALOG_TABLE="${MERGE_LANDING_CATALOG_TABLE:-\"platform-industry-bi-prod\".matvw_catalog_profile}"
SKIP_HOST_GUARD="${MERGE_LANDING_SKIP_HOST_GUARD:-0}"
DRY_RUN=0

# slack-notify.sh reads this (target channel).
# Export before sourcing so its `:=` default doesn't override us.
export SLACK_CHANNEL="${MERGE_LANDING_SLACK_CHANNEL:-C0ADV2W76G4}"  # #clio_devops

log() { echo "$LOGPREFIX $1"; }

# ──────────────────────────────────────────────────────────────
# Parse flags
# ──────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# Locate the sibling Slack helper relative to THIS script so the watchdog
# works from /opt/hydra, a worktree, or a deploy mirror.
_WATCHDOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/slack-notify.sh
source "$_WATCHDOG_DIR/lib/slack-notify.sh"

command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required but not on PATH"; exit 2; }

# ──────────────────────────────────────────────────────────────
# select_candidates — pure: read the merge log, emit the losers worth
# checking. $1 merges_file  $2 min_age_hours  $3 now_epoch  $4 candidates_out
# Writes a JSON array of {key, survivor, loser, requester, ts} to
# candidates_out and prints the unique loser ids, one per line, to stdout
# (empty stdout == nothing aged-enough to check).
# ──────────────────────────────────────────────────────────────
select_candidates() {
  MERGES_FILE="$1" MIN_AGE_HOURS="$2" NOW_EPOCH="$3" CANDIDATES_OUT="$4" python3 - <<'PYEOF'
import json, os

merges_file = os.environ["MERGES_FILE"]
min_age_s   = float(os.environ["MIN_AGE_HOURS"]) * 3600
now         = int(os.environ["NOW_EPOCH"])
out_path    = os.environ["CANDIDATES_OUT"]

cands = {}  # key "survivor:loser" -> dict (dedupe repeated re-issues of the same pair)
try:
    with open(merges_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue  # skip a half-written/garbled line, don't abort
            if "merge" not in str(rec.get("path", "")):
                continue
            epoch = rec.get("epoch")
            if not isinstance(epoch, (int, float)):
                continue
            if now - epoch < min_age_s:
                continue  # too fresh — async fold may still be in flight
            survivor = rec.get("mergeInto")
            losers = rec.get("profilesIds") or []
            if not survivor or not isinstance(losers, list):
                continue
            for loser in losers:
                if not loser:
                    continue
                key = f"{survivor}:{loser}"
                # keep the OLDEST occurrence so the reported age reflects how
                # long this pair has actually been stuck.
                prev = cands.get(key)
                if prev is None or epoch < prev["ts"]:
                    cands[key] = {
                        "key": key,
                        "survivor": survivor,
                        "loser": loser,
                        "requester": rec.get("requester", ""),
                        "ts": int(epoch),
                    }
except FileNotFoundError:
    pass

with open(out_path, "w") as f:
    json.dump(list(cands.values()), f)

# unique loser ids for the catalog query
for loser in sorted({c["loser"] for c in cands.values()}):
    print(loser)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# decide_and_alert — pure detection core.
#   $1 candidates_json  $2 catalog_csv  $3 state_file  $4 payload_out  $5 persist(0|1)
# catalog_csv is trino-query.sh output: rows of "_id","merged_to_id","is_deleted"
# (data rows only, no header, fields double-quoted). A loser is STUCK iff it
# appears with an empty merged_to_id AND is_deleted=false. Absent / merged /
# deleted == landed. Alerts only on stuck pairs not already in the state set;
# previously-alerted pairs that have since landed get a ✅ all-clear and leave
# the set. Writes a Slack payload to payload_out (only if new stuck pairs or
# resolutions), advances the alerted-set in state_file (persist=1), and prints
# the alert/all-clear block to stdout.
# ──────────────────────────────────────────────────────────────
decide_and_alert() {
  CANDIDATES_JSON="$1" CATALOG_CSV="$2" STATE_FILE="$3" PAYLOAD_OUT="$4" PERSIST="$5" \
  SLACK_CHANNEL="$SLACK_CHANNEL" NOW_EPOCH="${NOW_EPOCH_FOR_AGE:-0}" python3 - <<'PYEOF'
import json, os, csv

cand_path  = os.environ["CANDIDATES_JSON"]
csv_path   = os.environ["CATALOG_CSV"]
state_file = os.environ["STATE_FILE"]
payload_out= os.environ["PAYLOAD_OUT"]
persist    = os.environ.get("PERSIST", "1") == "1"
channel    = os.environ["SLACK_CHANNEL"]
now        = int(os.environ.get("NOW_EPOCH", "0"))

with open(cand_path) as f:
    candidates = json.load(f)

# catalog state: _id -> (merged_to_id, is_deleted_bool). Absent ids are treated
# as landed (dropped from the active view / never resolvable) and never alert.
catalog = {}
try:
    with open(csv_path) as f:
        for row in csv.reader(f):
            if len(row) < 3:
                continue
            _id = row[0].strip()
            merged_to_id = row[1].strip()
            is_deleted = row[2].strip().lower() == "true"
            catalog[_id] = (merged_to_id, is_deleted)
except FileNotFoundError:
    pass

def is_stuck(loser):
    if loser not in catalog:
        return False
    merged_to_id, is_deleted = catalog[loser]
    return (merged_to_id == "") and (not is_deleted)

# previously-alerted survivor:loser keys
try:
    with open(state_file) as f:
        alerted = set(json.load(f))
except Exception:
    alerted = set()

new_alerts = []  # (survivor, loser, requester, age_hours)
resolved   = []  # previously-alerted pairs whose loser has since landed
new_alerted = set(alerted)
for c in candidates:
    stuck = is_stuck(c["loser"])
    age_h = (now - c["ts"]) / 3600 if now else 0
    if stuck and c["key"] not in alerted:
        new_alerts.append((c["survivor"], c["loser"], c.get("requester", ""), age_h))
        new_alerted.add(c["key"])
    elif not stuck and c["key"] in alerted:
        # The async fold completed late — post a ✅ all-clear so #clio_devops
        # isn't left telling humans to hand off a merge that already landed,
        # and drop the pair from the alerted set.
        resolved.append((c["survivor"], c["loser"], c.get("requester", ""), age_h))
        new_alerted.discard(c["key"])

# Resolution must be driven by the ALERTED set, not just the candidate scan:
# an alerted pair whose audit-log line is gone (log rotated/pruned) would
# otherwise sit in the state forever — never ✅'d, and permanently deduped if
# it ever re-sticks. The bash caller queries these losers too, so "absent or
# landed in the catalog" is a real observation, not a missing row. Request
# age is unknown without the log line, so the bullet shows "?".
candidate_keys = {c["key"] for c in candidates}
for key in sorted(alerted - candidate_keys):
    survivor, _, loser = key.partition(":")
    if loser and not is_stuck(loser):
        resolved.append((survivor, loser, "", None))
        new_alerted.discard(key)

if not new_alerts and not resolved:
    # Nothing new to page → leave the live alerted-set untouched (rewriting it
    # would be a no-op) and emit no payload.
    raise SystemExit(0)

# Stage the would-be new alerted-set to a sidecar ".pending" file. When
# persist=1 (dry-run / self-test) advance the live state immediately — a
# faithful dedupe rehearsal. When persist=0 (real run) we leave .pending for
# the bash caller to promote ONLY after Slack confirms delivery, so an
# undelivered page is retried next tick instead of being silently deduped.
d = os.path.dirname(state_file)
if d:
    os.makedirs(d, exist_ok=True)
pending = state_file + ".pending"
with open(pending, "w") as f:
    json.dump(sorted(new_alerted), f, indent=2)
if persist:
    os.replace(pending, state_file)

def block(pairs, header, blurb, verb, qual):
    pairs.sort(key=lambda a: (a[0], a[1]))
    out = [header, blurb]
    for survivor, loser, requester, age_h in pairs:
        age = f"{qual}{age_h:.0f}h" if age_h else "?"
        who = f" req={requester}" if requester else ""
        out.append(f"• loser `{loser}` → survivor `{survivor}` — {verb} {age}{who}")
    return out

lines = []
if new_alerts:
    lines += block(new_alerts,
                   f":rotating_light: *Profile merge(s) accepted but NOT landed — {len(new_alerts)}*",
                   "These merges returned HTTP 200 but the loser is still an active, unmerged "
                   "catalog profile (async catalog fold silently dropped — no DLQ/retry). "
                   "Hand to the catalog team for a manual merge.",
                   "stuck", "≥")
if resolved:
    lines += block(resolved,
                   f":white_check_mark: *Profile merge(s) previously flagged have now LANDED — {len(resolved)}*",
                   "No manual merge needed — the async catalog fold completed late.",
                   "landed after", "~")
text = "\n".join(lines)

# Build the Slack payload in Python (ids are safe, but keep parity with the
# sibling watchdogs that post JSON built here verbatim).
with open(payload_out, "w") as f:
    json.dump({"channel": channel, "text": text}, f)

print(text)
PYEOF
}

# ──────────────────────────────────────────────────────────────
# query_catalog — run the IN-list query via the (overridable) Trino wrapper.
# $1 = comma-separated quoted id list (e.g. 'a','b'). Prints CSV to stdout.
# Stderr (jline terminal warnings) is discarded so only CSV rows survive.
# ──────────────────────────────────────────────────────────────
query_catalog() {
  local inlist="$1"
  "$TRINO_CMD" "SELECT _id, merged_to_id, is_deleted FROM ${CATALOG_TABLE} WHERE _id IN (${inlist})" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────
# alert_query_failure — the detector is BLIND (catalog query failed). Nothing
# monitors this cron.d job's exit code (cron-health-watchdog only reads
# openclaw cron JSONL, not /etc/cron.d exits), so a silent exit-0 here would let
# a Trino outage hide the very incident class this watchdog exists to surface.
# Page #clio_devops, deduped to once per QUERY_FAIL_COOLDOWN_HOURS so a
# sustained outage pages once, not every 30-min tick. Best-effort: never aborts
# the (already-failing) run.
# ──────────────────────────────────────────────────────────────
alert_query_failure() {
  local text marker now last payload
  text=":warning: *merge-landing-watchdog is BLIND* — the catalog (Trino) query failed, so silently-dropped profile merges can't be detected this tick. Check trino-query.sh / the catalog cluster."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would page ${SLACK_CHANNEL}: catalog query failed (detector BLIND)."
    return 0
  fi

  marker="${STATE_FILE}.query_fail"
  now="$NOW_EPOCH"
  if [ -f "$marker" ]; then
    last="$(cat "$marker" 2>/dev/null || echo 0)"
    if [ -n "$last" ] && [ "$((now - last))" -lt "$((QUERY_FAIL_COOLDOWN_HOURS * 3600))" ]; then
      log "Catalog-query failure already paged within ${QUERY_FAIL_COOLDOWN_HOURS}h cooldown; not re-paging."
      return 0
    fi
  fi

  payload="$(mktemp)"
  # Build the JSON in Python to keep escaping safe (parity with decide_and_alert).
  CHANNEL="$SLACK_CHANNEL" TEXT="$text" OUT="$payload" python3 - <<'PYEOF'
import json, os
with open(os.environ["OUT"], "w") as f:
    json.dump({"channel": os.environ["CHANNEL"], "text": os.environ["TEXT"]}, f)
PYEOF
  if slack_notify_payload_file_status "$payload"; then
    local d; d="$(dirname "$marker")"
    [ -n "$d" ] && mkdir -p "$d"
    printf '%s' "$now" > "$marker"
    log "Paged ${SLACK_CHANNEL}: catalog query failure (detector BLIND)."
  else
    log "WARN: Slack delivery of the catalog-query-failure page also failed."
  fi
  rm -f "$payload"
}

# ──────────────────────────────────────────────────────────────
# Inline self-test — runs on EVERY invocation (cost ~30ms). Guards the failure
# that would make THIS watchdog itself rot silently: a detector that no longer
# detects. Exercises the pure decision core with a canned candidate set + a
# canned catalog CSV (one stuck loser, one already-landed) — never touches
# Trino, real state, or Slack.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  # Three candidate pairs sharing survivor S: loser L1 is stuck, L2 has landed
  # (never alerted), L3 has landed AFTER being alerted (in the state set).
  printf '%s' '[{"key":"S:L1","survivor":"S","loser":"L1","requester":"jan@muso.ai","ts":1000},{"key":"S:L2","survivor":"S","loser":"L2","requester":"jan@muso.ai","ts":1000},{"key":"S:L3","survivor":"S","loser":"L3","requester":"jan@muso.ai","ts":1000}]' > "$td/cands.json"
  # Catalog: L1 active+unmerged (STUCK), L2/L3 merged into S (landed), survivor S active.
  printf '%s\n' '"L1","","false"' '"L2","S","true"' '"L3","S","true"' '"S","","false"' > "$td/catalog.csv"
  printf '%s\n' '["S:L3"]' > "$td/state.json"
  out="$(NOW_EPOCH_FOR_AGE=8200 decide_and_alert "$td/cands.json" "$td/catalog.csv" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
  if ! printf '%s' "$out" | grep -q "L1"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not flag the stuck loser L1" >&2
    return 1
  fi
  if printf '%s' "$out" | grep -q "L2"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector wrongly flagged the landed loser L2" >&2
    return 1
  fi
  if ! printf '%s' "$out" | grep -q 'L3.*landed after'; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector did not all-clear the alerted-then-landed loser L3" >&2
    return 1
  fi
  # Staged state (persist=0 → .pending) must add the stuck pair and drop the
  # resolved one. Message-format details beyond this are bats' job, not the
  # every-tick guard's.
  if ! python3 -c "import json,sys; s=set(json.load(open('$td/state.json.pending'))); sys.exit(0 if ('S:L1' in s and 'S:L3' not in s) else 1)"; then
    echo "$LOGPREFIX SELF-TEST FAIL: staged state did not add S:L1 / drop resolved S:L3" >&2
    return 1
  fi
  return 0
}

if ! _self_test; then
  log "ABORT: self-test failed — refusing to run with a broken detector"
  exit 3
fi

# ──────────────────────────────────────────────────────────────
# Host guard: wrong node → no-op (prevents an orphaned cron from firing after
# a host migration). Skippable for tests.
# ──────────────────────────────────────────────────────────────
if [ "$SKIP_HOST_GUARD" != "1" ] && ! hostname | grep -q '^ovh-node-8$'; then
  log "SKIP: hostname is not ovh-node-8 ($(hostname)) — script is node-8-specific"
  exit 0
fi

if [ ! -f "$MERGES_FILE" ]; then
  log "SKIP: merge audit log not found: $MERGES_FILE"
  exit 0
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another merge-landing-watchdog run holds $LOCKFILE"; exit 0; }
fi

NOW_EPOCH="${MERGE_LANDING_NOW_EPOCH:-$(date -u +%s)}"
CANDIDATES_FILE="$(mktemp)"
CATALOG_FILE="$(mktemp)"
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$CANDIDATES_FILE" "$CATALOG_FILE" "$PAYLOAD_FILE"' EXIT

# Phase 1: which losers are aged-enough to check? Union in the losers of
# already-alerted pairs so a pair whose audit-log line has been rotated away
# can still be observed (and ✅-resolved) against the catalog.
loser_ids="$(select_candidates "$MERGES_FILE" "$MIN_AGE_HOURS" "$NOW_EPOCH" "$CANDIDATES_FILE")"
alerted_losers="$(STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os
try:
    with open(os.environ["STATE_FILE"]) as f:
        keys = json.load(f)
except Exception:
    keys = []
for k in keys:
    loser = str(k).partition(":")[2]
    if loser:
        print(loser)
PYEOF
)"
loser_ids="$(printf '%s\n%s\n' "$loser_ids" "$alerted_losers" | grep -v '^$' | sort -u || true)"
if [ -z "$loser_ids" ]; then
  log "OK: no merges older than ${MIN_AGE_HOURS}h to verify."
  exit 0
fi

# Phase 2: ask the catalog whether each loser actually merged.
inlist="$(printf "%s\n" "$loser_ids" | sed "s/.*/'&'/" | paste -sd, -)"
if ! query_catalog "$inlist" > "$CATALOG_FILE"; then
  log "WARN: catalog query failed (trino unavailable?) — detector is BLIND this tick."
  alert_query_failure
  exit 1   # fail loud: a query failure must surface, not masquerade as healthy
fi
# Query recovered → clear any prior BLIND marker so a future outage pages promptly.
rm -f "${STATE_FILE}.query_fail"

# Phase 3: decide + alert. Export NOW so decide_and_alert can report the
# stuck-duration in the alert. In a real run we DEFER advancing the dedupe
# state (persist=0): decide_and_alert stages it to "${STATE_FILE}.pending" and
# we promote it only after Slack confirms delivery, so an undelivered page is
# retried next tick rather than silently marked "already alerted". In --dry-run
# we persist immediately (persist=1) — a faithful dedupe rehearsal, no post.
export NOW_EPOCH_FOR_AGE="$NOW_EPOCH"
alert_block="$(decide_and_alert "$CANDIDATES_FILE" "$CATALOG_FILE" "$STATE_FILE" "$PAYLOAD_FILE" "$DRY_RUN" || true)"

if [ -z "$alert_block" ]; then
  log "OK: all aged merges have landed in the catalog."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN: would post the following to ${SLACK_CHANNEL}:"
  printf '%s\n' "$alert_block"
  exit 0
fi

log "Posting stuck-merge/all-clear notice to ${SLACK_CHANNEL}."
printf '%s\n' "$alert_block"
if slack_notify_payload_file_status "$PAYLOAD_FILE"; then
  # Delivery confirmed → advance the dedupe state so this pair isn't re-paged.
  [ -f "${STATE_FILE}.pending" ] && mv -f "${STATE_FILE}.pending" "$STATE_FILE"
  log "Watchdog notice delivered; dedupe state advanced."
else
  # Delivery failed → leave the live state untouched so the next tick re-pages.
  rm -f "${STATE_FILE}.pending"
  log "ERROR: Slack delivery of watchdog notice FAILED — dedupe state NOT advanced; will retry next tick."
  exit 1
fi

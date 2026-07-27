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
# processing catalog worker is what sets merged_to_id + folds credits. A merge
# can still exhaust its retries before the catalog mutation lands. That is
# exactly what bit the 2026-06-08/09 Jan ↔ Ops threads:
# two merge pairs (Jens Jungkurth, Shelby Archer) returned 200 four times
# over days and never landed, with nothing surfaced until a human noticed.
#
# This watchdog is the missing detection layer: it reads the merge audit log,
# and for any merge the catalog has had a fair chance to fold but whose loser is
# STILL an active, unmerged profile, it pages once. "Landed" = the loser has a
# mergedToId pointing at the requested survivor and is soft-deleted, OR the
# SURVIVOR is soft-deleted with mergedToId pointing at the loser (a direction-
# flipped landing). Any other state remains unresolved.
#
# Detection reads the CURRENT Mongo-backed catalog through the existing admin
# profile-list API (`muso api GET /admin/profile?includeDeleted=true`). It must
# never use a BI materialized view: those snapshots can lag or stall and are not
# an operational source of truth for merge landing. Dedupe is per
# survivor:loser pair in a state file,
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
# tighter cadence would only add API load without catching anything sooner.
#
# Flags:
#   --dry-run   compute + print the alert block to stdout, do NOT post to
#               Slack. State IS still advanced (faithful dedupe rehearsal);
#               point MERGE_LANDING_STATE_FILE at a throwaway path to rehearse
#               without consuming real alert state.
#
# Env knobs (mainly for tests — defaults target the live node-8 layout):
#   MERGE_LANDING_MERGES_FILE    merge audit feed(s), colon-separated
#                                (wrapper log + muso CLI state file)
#   MERGE_LANDING_STATE_FILE     already-alerted survivor:loser set
#   MERGE_LANDING_MIN_AGE_HOURS  coarse pre-filter: skip merges younger than this
#                                (default 6; live catalog state is checked after
#                                this async-processing grace period)
#   MERGE_LANDING_QUERY_FAIL_COOLDOWN_HOURS  re-page window for catalog-query
#                                failures (BLIND alert), default 6
#   MERGE_LANDING_CATALOG_CMD    admin API command (default /usr/local/bin/muso;
#                                tests override)
#   MERGE_LANDING_CATALOG_ENV    API environment (default prod)
#   MERGE_LANDING_CATALOG_BATCH_SIZE  ids per request (default 40; keeps the
#                                admin GET below ingress request-header limits)
#   MERGE_LANDING_NOW_EPOCH      override "now" for deterministic tests
#   MERGE_LANDING_LOCKFILE       single-run lock
#   MERGE_LANDING_SLACK_CHANNEL  target channel (default #clio_devops)
#   MERGE_LANDING_SKIP_HOST_GUARD 1 = skip the ovh-node-8 guard (tests)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

LOGPREFIX="[merge-landing-watchdog $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
# Colon-separated list: the wrapper's audit log PLUS the muso CLI's fallback
# state dirs (its /var/lib/muso-cli preferred fleet dir and the XDG last
# resort — rungs 2 and 4 of muso-cli config.go's resolution chain). Pinned
# contexts (MUSO_STATE_DIR=/var/log/muso-ops, enforced via /etc/environment by
# install-aux-units.sh and the gateway env files) converge on the wrapper
# path; the extra feeds are defense-in-depth for pin-escaped invocations
# (split-brain found 2026-07-24: a root-SSH CLI merge was invisible to this
# watchdog). NOTE: the CLI file is its overlap-guard state (300s horizon) —
# append-only today, but not a contractual long-retention feed.
MERGES_FILE="${MERGE_LANDING_MERGES_FILE:-/var/log/muso-ops/recent-merges.jsonl:/var/lib/muso-cli/recent-merges.jsonl:/root/.local/state/muso/recent-merges.jsonl}"
STATE_FILE="${MERGE_LANDING_STATE_FILE:-/var/lib/merge-landing-watchdog/alerted.json}"
LOCKFILE="${MERGE_LANDING_LOCKFILE:-/var/run/merge-landing-watchdog.lock}"
MIN_AGE_HOURS="${MERGE_LANDING_MIN_AGE_HOURS:-6}"
QUERY_FAIL_COOLDOWN_HOURS="${MERGE_LANDING_QUERY_FAIL_COOLDOWN_HOURS:-6}"
CATALOG_CMD="${MERGE_LANDING_CATALOG_CMD:-/usr/local/bin/muso}"
CATALOG_ENV="${MERGE_LANDING_CATALOG_ENV:-prod}"
CATALOG_BATCH_SIZE="${MERGE_LANDING_CATALOG_BATCH_SIZE:-40}"
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
[ -x "$CATALOG_CMD" ] || { log "ERROR: catalog command is not executable: $CATALOG_CMD"; exit 2; }

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
for one_file in filter(None, merges_file.split(":")):
  try:
    with open(one_file) as f:
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
#   $1 candidates_json  $2 catalog_json  $3 state_file  $4 payload_out  $5 persist(0|1)
# catalog_json is the live admin profile-list response. A requested-direction
# landing requires loser.merged.mergedToId == survivor AND loser.deleted != null.
# A direction flip requires the inverse. Missing, active, or mismatched records
# remain unresolved and alert after MIN_AGE_HOURS.
#
# Alerts only on stuck pairs not already in the state set; previously-alerted
# pairs that have since landed get a ✅ all-clear and leave the set. Writes a
# Slack payload to payload_out (only if new stuck pairs or resolutions), advances
# the alerted-set in state_file (persist=1), and prints the block to stdout.
# ──────────────────────────────────────────────────────────────
decide_and_alert() {
  CANDIDATES_JSON="$1" CATALOG_JSON="$2" STATE_FILE="$3" PAYLOAD_OUT="$4" PERSIST="$5" \
  SLACK_CHANNEL="$SLACK_CHANNEL" NOW_EPOCH="${NOW_EPOCH_FOR_AGE:-0}" \
  python3 - <<'PYEOF'
import json, os, re

cand_path  = os.environ["CANDIDATES_JSON"]
catalog_path = os.environ["CATALOG_JSON"]
state_file = os.environ["STATE_FILE"]
payload_out= os.environ["PAYLOAD_OUT"]
persist    = os.environ.get("PERSIST", "1") == "1"
channel    = os.environ["SLACK_CHANNEL"]
now        = int(os.environ.get("NOW_EPOCH", "0"))

with open(cand_path) as f:
    candidates = json.load(f)

# catalog state: id -> (merged_to_id, is_deleted_bool). includeDeleted=true is
# mandatory, so a merged loser remains present. Absence is unresolved, not proof
# of landing.
with open(catalog_path) as f:
    response = json.load(f)
items = response.get("data", {}).get("items", [])
catalog = {}
for item in items:
    if not isinstance(item, dict) or not item.get("id"):
        continue
    merged = item.get("merged") or {}
    catalog[str(item["id"])] = (
        str(merged.get("mergedToId") or ""),
        item.get("deleted") is not None,
    )

# A merge id that is not a well-formed UUID can never match a catalog row, so
# the pair would alert on every tick forever. Observed live 2026-07-27: loser
# `652996f-d521-48bb-97b0-dec38cdd508a` (35 chars, 7 hex in group 1) had been
# re-alerting for ~1310h while all 12 well-formed siblings of the same bulk
# call landed correctly — a request-layer typo the admin API accepted with a 200.
UUID_RE = re.compile(
    r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)

# Verdicts that mean "the dedup intent is satisfied, stop paging humans".
RESOLVED = frozenset({"landed", "collapsed"})


def classify(survivor, loser):
    """landed | collapsed | partial | invalid | stuck.

    Split out of the original boolean is_stuck() on 2026-07-27: it returned
    True for three materially different states, so an operator staring at a
    page could not tell "never processed" (safe to re-fire once verified) from
    "half folded" (a re-fire can DAMAGE the survivor) from "malformed id"
    (will never land, no amount of re-firing helps).
    """
    if loser not in catalog:
        # includeDeleted=true should return it, so absence is unresolved — EXCEPT
        # when the id is malformed, which can never match a row at all. Checked
        # here rather than up front: presence in the catalog is itself proof the
        # id is usable, whatever its shape, and the every-tick self-test uses
        # short synthetic ids on purpose.
        if not UUID_RE.match(loser):
            return "invalid"
        return "stuck"
    l_merged, l_deleted = catalog[loser]
    if l_merged == survivor and l_deleted:
        return "landed"  # exact requested-direction landing
    # Loser is still active & unmerged. Before calling it a drop, check the
    # FLIPPED direction: the backend sometimes canonicalises the OTHER profile
    # as the survivor (e.g. by popularity/credits), so the nominal LOSER
    # survives and the nominal SURVIVOR is the one folded away. If the survivor
    # merged INTO this loser, the duplicate pair collapsed into one entity — the
    # dedup intent is satisfied, so it is landed, not a drop. (Verified live
    # 2026-07-03: merge 0c242160→99813f55 landed reversed — 99813f55.merged_to_id
    # == 0c242160 — yet the nominal loser 0c242160 read active and false-flagged.)
    s = catalog.get(survivor)
    if s is not None and s[0] == loser and s[1]:
        return "landed"
    if l_merged and l_deleted:
        # The loser folded into some THIRD profile, not the requested survivor.
        if s is not None and s[0] == l_merged and s[1]:
            # Survivor went to that same canonical → the whole group collapsed
            # into one entity. Dedup intent satisfied. (Live 2026-07-27: losers
            # 210ebd26/4c2ad26b AND recorded survivor c1f6b21d all carry
            # mergedToId=4e675b56 after a superseding merge 16 min later — yet
            # this alerted every tick for 326h because the old classifier had
            # no case for collapse onto a third canonical.)
            return "collapsed"
        # Survivor untouched → PARTIALLY FOLDED. Never auto-resolve and never
        # re-fire. (Live 2026-07-27: 695575be/8ce80ba2 folded into d9d61f4a —
        # a co-loser of the same request — while requested survivor 451c4bbc
        # received nothing.)
        return "partial"
    return "stuck"  # active or missing → requested pair never processed

# previously-alerted survivor:loser keys
try:
    with open(state_file) as f:
        alerted = set(json.load(f))
except Exception:
    alerted = set()

new_alerts  = []  # (survivor, loser, requester, age_hours) — never processed
new_partial = []  # half-folded — re-firing these can damage the survivor
new_invalid = []  # malformed id — can never land, fix at the request layer
resolved    = []  # previously-alerted pairs whose loser has since landed
new_alerted = set(alerted)
for c in candidates:
    verdict = classify(c["survivor"], c["loser"])
    age_h = (now - c["ts"]) / 3600 if now else 0
    row = (c["survivor"], c["loser"], c.get("requester", ""), age_h)
    if verdict in RESOLVED:
        if c["key"] in alerted:
            # The async fold completed late — post a ✅ all-clear so #clio_devops
            # isn't left telling humans to hand off a merge that already landed,
            # and drop the pair from the alerted set.
            resolved.append(row)
            new_alerted.discard(c["key"])
        continue
    if c["key"] in alerted:
        continue  # already paged; stay deduped until it resolves
    if verdict == "partial":
        new_partial.append(row)
    elif verdict == "invalid":
        new_invalid.append(row)
    else:
        new_alerts.append(row)
    new_alerted.add(c["key"])

# Resolution must be driven by the ALERTED set, not just the candidate scan:
# an alerted pair whose audit-log line is gone (log rotated/pruned) would
# otherwise sit in the state forever — never ✅'d, and permanently deduped if
# it ever re-sticks. The bash caller queries both endpoints too, so a positive
# exact-merge observation can still resolve it. Request age is unknown without
# the log line, so the bullet shows "?".
candidate_keys = {c["key"] for c in candidates}
for key in sorted(alerted - candidate_keys):
    survivor, _, loser = key.partition(":")
    if loser and classify(survivor, loser) in RESOLVED:
        resolved.append((survivor, loser, "", None))
        new_alerted.discard(key)

if not new_alerts and not new_partial and not new_invalid and not resolved:
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
                   "These merges returned HTTP 200 but the current catalog does not show the exact "
                   "requested (or direction-flipped) merge after the processing grace period. Check "
                   "the worker retry/dead-letter evidence, then *verify + re-fire* "
                   "— do NOT blind re-merge, a re-fire against partially-folded state can damage "
                   "the survivor; verify the pair's current state first.",
                   "stuck", "≥")
if new_partial:
    lines += block(new_partial,
                   f":warning: *Profile merge(s) PARTIALLY FOLDED — {len(new_partial)}*",
                   "The loser folded into a DIFFERENT profile than the one requested, and the "
                   "requested survivor received nothing. *Do NOT re-fire* — `merge` is not "
                   "idempotent and a re-fire against half-folded state can damage the survivor. "
                   "Hand to the catalog team (Aron / Oleg) for a manual reconciliation.",
                   "partially folded", "≥")
if new_invalid:
    lines += block(new_invalid,
                   f":no_entry: *Profile merge(s) with a MALFORMED id — {len(new_invalid)}*",
                   "The requested id is not a well-formed UUID, so this merge can never match a "
                   "catalog row and will never land no matter how often it is re-fired. Fix the "
                   "request at source; no catalog action is possible.",
                   "unlandable", "≥")
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
# query_catalog — batch-read the current Mongo-backed profile state through the
# existing authenticated admin API. $1 is a newline-delimited id file; $2 is
# the caller's EXIT-trapped temporary directory. Prints the API JSON response
# to stdout.
# ──────────────────────────────────────────────────────────────
query_catalog() {
  local ids_file="$1" temp_parent="$2" query_tmp batch_file response_file count id
  local -a args
  case "$CATALOG_BATCH_SIZE" in
    ''|*[!0-9]*|0) echo "invalid catalog batch size: $CATALOG_BATCH_SIZE" >&2; return 1 ;;
  esac
  [ -s "$ids_file" ] || return 1
  query_tmp="$(mktemp -d "$temp_parent/catalog-query.XXXXXX")" || return 1
  if ! split -l "$CATALOG_BATCH_SIZE" "$ids_file" "$query_tmp/ids-"; then
    rm -rf "$query_tmp"
    return 1
  fi

  for batch_file in "$query_tmp"/ids-*; do
    count="$(grep -c . "$batch_file" || true)"
    [ "$count" -gt 0 ] || continue
    args=(--env "$CATALOG_ENV" --json api GET /admin/profile
          --query includeDeleted=true --query "limit=$count")
    while IFS= read -r id; do
      [ -n "$id" ] && args+=(--query "ids=$id")
    done < "$batch_file"
    response_file="$query_tmp/response-$(basename "$batch_file").json"
    if ! "$CATALOG_CMD" "${args[@]}" > "$response_file"; then
      rm -rf "$query_tmp"
      return 1
    fi
  done

  # Collapse the bounded responses back into the single shape consumed by the
  # pure classifier. Invalid/empty batch JSON fails the whole read closed.
  if ! CATALOG_BATCH_DIR="$query_tmp" python3 - <<'PYEOF'
import glob, json, os, sys
items_by_id = {}
try:
    paths = sorted(glob.glob(os.path.join(os.environ["CATALOG_BATCH_DIR"], "response-*.json")))
    if not paths:
        raise ValueError("no catalog batch responses")
    for path in paths:
        with open(path) as f:
            batch = json.load(f)
        items = batch["data"]["items"]
        if not isinstance(items, list):
            raise ValueError(f"{path}: data.items is not a list")
        for item in items:
            if not isinstance(item, dict) or not item.get("id"):
                raise ValueError(f"{path}: item missing id")
            items_by_id[str(item["id"])] = item
except Exception as exc:
    print(f"invalid catalog batch response: {exc}", file=sys.stderr)
    raise SystemExit(1)
print(json.dumps({"data": {"totalCount": len(items_by_id), "items": list(items_by_id.values())}}))
PYEOF
  then
    rm -rf "$query_tmp"
    return 1
  fi
  rm -rf "$query_tmp"
}

# ──────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────
# alert_query_failure — the detector is BLIND (catalog query failed). Nothing
# monitors this cron.d job's exit code (cron-health-watchdog only reads
# openclaw cron JSONL, not /etc/cron.d exits), so a silent exit-0 here would let
# an admin API outage hide the very incident class this watchdog exists to surface.
# Page #clio_devops, deduped to once per QUERY_FAIL_COOLDOWN_HOURS so a
# sustained outage pages once, not every 30-min tick. Best-effort: never aborts
# the (already-failing) run.
# ──────────────────────────────────────────────────────────────
alert_query_failure() {
  local text marker now last payload
  text=":warning: *merge-landing-watchdog is BLIND* — the live catalog profile API query failed, so profile-merge landing can't be verified this tick. Check the admin API / industry-api path."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would page ${SLACK_CHANNEL}: BLIND (${text})."
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
# canned live-catalog response — never touches the API, real state, or Slack.
# ──────────────────────────────────────────────────────────────
_self_test() {
  local td out
  td="$(mktemp -d)"
  trap 'rm -rf "$td"' RETURN
  # Candidate pairs: L1 stuck, L2 landed-never-alerted, L3 landed-after-alerted.
  # L5 is a DIRECTION-FLIP: its survivor S5 merged INTO
  # L5, so the pair collapsed → landed → must NOT be flagged.
  printf '%s' '[{"key":"S:L1","survivor":"S","loser":"L1","requester":"jan@muso.ai","ts":1000},{"key":"S:L2","survivor":"S","loser":"L2","requester":"jan@muso.ai","ts":1000},{"key":"S:L3","survivor":"S","loser":"L3","requester":"jan@muso.ai","ts":1000},{"key":"S5:L5","survivor":"S5","loser":"L5","requester":"jan@muso.ai","ts":1000}]' > "$td/cands.json"
  # Catalog: L1 active+unmerged (STUCK), L2/L3 merged into S (landed), S active,
  # L5 active but S5 merged INTO L5 (direction-flip landing).
  printf '%s' '{"data":{"items":[{"id":"L1","merged":null,"deleted":null},{"id":"L2","merged":{"mergedToId":"S"},"deleted":{"date":"2026-01-01"}},{"id":"L3","merged":{"mergedToId":"S"},"deleted":{"date":"2026-01-01"}},{"id":"S","merged":null,"deleted":null},{"id":"L5","merged":null,"deleted":null},{"id":"S5","merged":{"mergedToId":"L5"},"deleted":{"date":"2026-01-01"}}]}}' > "$td/catalog.json"
  printf '%s\n' '["S:L3"]' > "$td/state.json"
  out="$(NOW_EPOCH_FOR_AGE=8200 \
        decide_and_alert "$td/cands.json" "$td/catalog.json" "$td/state.json" "$td/payload.json" 0 2>/dev/null || true)"
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
  if printf '%s' "$out" | grep -q "L5"; then
    echo "$LOGPREFIX SELF-TEST FAIL: detector flagged direction-flip loser L5 (survivor merged into it = landed)" >&2
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

_any_feed=0
IFS=':' read -ra _feed_paths <<< "$MERGES_FILE"
for _feed in "${_feed_paths[@]}"; do
  [ -f "$_feed" ] && { _any_feed=1; break; }
done
if [ "$_any_feed" -eq 0 ]; then
  log "SKIP: merge audit log not found: $MERGES_FILE"
  exit 0
fi

# Single-run lock so overlapping ticks never double-post.
if [ "$DRY_RUN" -eq 0 ]; then
  exec 9>"$LOCKFILE"
  flock -n 9 || { log "SKIP: another merge-landing-watchdog run holds $LOCKFILE"; exit 0; }
fi

NOW_EPOCH="${MERGE_LANDING_NOW_EPOCH:-$(date -u +%s)}"
RUN_TMP_DIR="$(mktemp -d)"
CANDIDATES_FILE="$RUN_TMP_DIR/candidates.json"
IDS_FILE="$RUN_TMP_DIR/ids.txt"
CATALOG_FILE="$RUN_TMP_DIR/catalog.json"
PAYLOAD_FILE="$RUN_TMP_DIR/payload.json"
trap 'rm -rf "$RUN_TMP_DIR"' EXIT

# Phase 1: which losers are aged-enough to check? select_candidates writes the
# candidate pairs to CANDIDATES_FILE and prints their loser ids. We then union
# in BOTH endpoints (loser AND survivor) of already-alerted pairs so a pair
# whose audit-log line has been rotated away can still be observed (and
# ✅-resolved). loser_ids gates the "any work?" check; all_ids (losers +
# survivors) is what we query — the survivor row is needed to detect a
# direction-flipped landing (survivor merged INTO the nominal loser).
loser_ids="$(select_candidates "$MERGES_FILE" "$MIN_AGE_HOURS" "$NOW_EPOCH" "$CANDIDATES_FILE")"
alerted_ids="$(STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os
try:
    with open(os.environ["STATE_FILE"]) as f:
        keys = json.load(f)
except Exception:
    keys = []
for k in keys:
    survivor, _, loser = str(k).partition(":")
    for x in (survivor, loser):
        if x:
            print(x)
PYEOF
)"
loser_ids="$(printf '%s\n%s\n' "$loser_ids" "$alerted_ids" | grep -v '^$' | sort -u || true)"
if [ -z "$loser_ids" ]; then
  log "OK: no merges older than ${MIN_AGE_HOURS}h to verify."
  exit 0
fi
# Survivors of the aged candidates (for the flip check) — union with the losers.
cand_survivors="$(python3 -c "import json,sys;[print(c['survivor']) for c in json.load(open('$CANDIDATES_FILE')) if c.get('survivor')]" 2>/dev/null || true)"
all_ids="$(printf '%s\n%s\n' "$loser_ids" "$cand_survivors" | grep -v '^$' | sort -u || true)"

# Phase 2: ask the live catalog API for every loser AND survivor.
printf '%s\n' "$all_ids" > "$IDS_FILE"
if ! query_catalog "$IDS_FILE" "$RUN_TMP_DIR" > "$CATALOG_FILE"; then
  log "WARN: live catalog API query failed — detector is BLIND this tick."
  alert_query_failure
  exit 1   # fail loud: a query failure must surface, not masquerade as healthy
fi
# Phase 3: decide + alert. Export NOW so decide_and_alert can report the
# stuck-duration in the alert. In a real run we DEFER advancing the dedupe
# state (persist=0): decide_and_alert stages it to "${STATE_FILE}.pending" and
# we promote it only after Slack confirms delivery, so an undelivered page is
# retried next tick rather than silently marked "already alerted". In --dry-run
# we persist immediately (persist=1) — a faithful dedupe rehearsal, no post.
export NOW_EPOCH_FOR_AGE="$NOW_EPOCH"
if ! alert_block="$(decide_and_alert "$CANDIDATES_FILE" "$CATALOG_FILE" "$STATE_FILE" "$PAYLOAD_FILE" "$DRY_RUN")"; then
  log "WARN: detector classification failed — detector is BLIND this tick."
  alert_query_failure
  exit 1
fi

# The detector is fully healthy only after both the live response and its
# classification succeed. Clear the BLIND marker now so a future failure pages
# promptly without re-paging every tick during the current failure.
rm -f "${STATE_FILE}.query_fail"

if [ -z "$alert_block" ]; then
  log "OK: no aged merge is unresolved in the live catalog."
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

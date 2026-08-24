#!/usr/bin/env bash
# fastlane.sh — deterministic wrapper for Jan's "@Ops fastlane <profile>"
# requests. Fastlane is a PROFILE ANALYTICS BOOTSTRAP, not credit
# verification: it fires POST /admin/analytics/<profileId>/fast-lane (which
# creates a profile_analytics_stats_history row, enqueues publishProfileFastLane
# Kafka work, and invalidates the /profile/:id Redis cache), then reads back the
# profile's current stream/track counts so the operator gets the numbers Jan
# always asks for ("what's the expected stream count after the fastlane?").
#
# The --lane plus superset ALSO re-discovers the catalog across every platform
# and force-rescrapes every existing stat link on every source before it
# recomputes the cubes (POST /admin/analytics/<profileId>/fast-lane-plus, or the
# per-user POST /admin/user/<userId>/fast-lane-plus which fans out over every
# profile a user owns). Use plus when tracks/credits are MISSING; plain fastlane
# only recomputes from data already in the catalog and can't heal missing rows.
#
# Why a wrapper instead of free-form agent calls: the ops agent repeatedly
# misrouted "fastlane" to the lobster credit-verification pipeline
# (dispatch-cv-batch.sh) because the only recipe was soft memory. This wrapper
# is the single deterministic code path the agent runs for a fastlane request.
#
# Usage:
#   fastlane.sh [--lane plain|plus] [--scope profile|user] \
#               "<ids>" "<thread_ts>" <requester> [<mode>] [<trigger_source>]
#
# Flags (optional, must precede the positionals):
#   --lane   plain (default) | plus. plus = recalc + full rescrape/rediscovery.
#   --scope  profile (default) | user. user is only valid with --lane plus and
#            treats each id as a userId (fans out over all owned profiles, cap
#            200 server-side).
#
# Args:
#   ids             One or more UUIDs and/or credits.muso.ai/profile/<uuid> URLs,
#                   comma- or whitespace-separated. UUIDs are extracted,
#                   lowercased, and de-duplicated (order preserved). REQUIRED.
#                   profile UUIDs for profile scope; user UUIDs for user scope.
#   thread_ts       Slack thread timestamp (for the operator's context; the agent
#                   posts this wrapper's stdout into that thread). "" if none.
#   requester       Slack ID (U...) or email of the human who asked. REQUIRED —
#                   passed to muso-admin-api.sh --requester for the audit trail.
#   mode            real (default) | dry. dry sets OPS_DRY_RUN=1 so the POST is
#                   short-circuited and logged but never hits prod.
#   trigger_source  Backend triggerSource label. Default is lane/scope-aware:
#                   admin_fast_lane_jan_batch (plain), admin_fast_lane_plus
#                   (plus/profile), admin_fast_lane_plus_user (plus/user).
#
# Stdout: a Slack-ready report (the agent relays it verbatim into the thread).
# Exit:   0 whenever a report was produced (per-profile failures are shown IN the
#         report, never as a non-zero exit — a trailing tool-error suppresses
#         Slack delivery on this fleet, so we fail soft and visible). 2 only on a
#         usage error (no UUIDs / no requester) where there is nothing to report.

set -uo pipefail

# --- overridable paths (production defaults; tests redirect these) ----------
ADMIN_API="${FASTLANE_ADMIN_API:-/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh}"
TRINO="${FASTLANE_TRINO:-/opt/hydra/scripts/trino-query.sh}"
# The cube read is best-effort AND now runs BEFORE the admin POST, so an
# unbounded Trino stall would hold the fire hostage: the wrapper would time out
# at the agent and the fastlane would never be issued at all. Bound it — a
# timed-out read is simply an unmeasured baseline (null), never a blocked fire.
#
# TWO bounds, because per-read alone is not enough: profile scope takes an
# arbitrary list of ids, so N profiles against a stalled Trino would still cost
# N x TRINO_TIMEOUT and blow the agent's exec timeout — the later POSTs never
# fire and no report is printed at all. TRINO_BATCH_BUDGET caps what the whole
# batch may spend on baselines; past it, later profiles get a null baseline and
# their fire goes out on time.
TRINO_TIMEOUT="${FASTLANE_TRINO_TIMEOUT:-30}"
TRINO_BATCH_BUDGET="${FASTLANE_TRINO_BATCH_BUDGET:-60}"
# Validate BEFORE either value reaches an arithmetic context: (( )) evaluates a
# variable's VALUE recursively, so a non-numeric override silently becomes 0 and
# a crafted one would run a command substitution.
#
# The per-read timeout must be strictly POSITIVE. GNU `timeout 0` means "no
# limit", so a 0 — whether passed deliberately or produced by a non-numeric
# override — would silently DISABLE the very bound it looks like it sets, and
# one hung read would again mean no POST and no report at all.
#
# The batch budget MAY be 0, and that asymmetry is deliberate: there 0 means
# "spend nothing on baselines", which tightens the bound (every profile takes a
# null baseline and fires immediately) instead of removing it.
[[ "$TRINO_TIMEOUT" =~ ^[0-9]+$ ]] && (( TRINO_TIMEOUT > 0 )) || TRINO_TIMEOUT=30
[[ "$TRINO_BATCH_BUDGET" =~ ^[0-9]+$ ]] || TRINO_BATCH_BUDGET=60
AUDIT_PATH="${FASTLANE_AUDIT_PATH:-/var/log/openclaw/fastlane-apply.jsonl}"

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

usage() {
  echo "Usage: fastlane.sh [--lane plain|plus] [--scope profile|user] \"<ids>\" \"<thread_ts>\" <requester> [real|dry] [<trigger_source>]" >&2
}

# --- leading flags (must precede positionals) -------------------------------
LANE="plain"
SCOPE="profile"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)  [[ $# -ge 2 ]] || { echo "ERROR: --lane needs a value" >&2; usage; exit 2; }; LANE="$2"; shift 2 ;;
    --scope) [[ $# -ge 2 ]] || { echo "ERROR: --scope needs a value" >&2; usage; exit 2; }; SCOPE="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "ERROR: unknown flag: '$1'" >&2; usage; exit 2 ;;
    *) break ;;
  esac
done

case "$LANE" in plain|plus) ;; *) echo "ERROR: --lane must be 'plain' or 'plus' (got: '$LANE')" >&2; usage; exit 2 ;; esac
case "$SCOPE" in profile|user) ;; *) echo "ERROR: --scope must be 'profile' or 'user' (got: '$SCOPE')" >&2; usage; exit 2 ;; esac
if [[ "$SCOPE" == "user" && "$LANE" != "plus" ]]; then
  echo "ERROR: --scope user requires --lane plus (no plain per-user lane)" >&2
  usage; exit 2
fi

# --- args -------------------------------------------------------------------
RAW_IDS="${1:-}"
THREAD_TS="${2:-}"   # carried for context; agent relays stdout into this thread
REQUESTER="${3:-}"
MODE_RAW="${4:-real}"

# trigger_source default is lane/scope-aware unless the caller passes arg 5.
if [[ -n "${5:-}" ]]; then
  TRIGGER_SOURCE="$5"
else
  case "${LANE}:${SCOPE}" in
    plus:user)    TRIGGER_SOURCE="admin_fast_lane_plus_user" ;;
    plus:profile) TRIGGER_SOURCE="admin_fast_lane_plus" ;;
    *)            TRIGGER_SOURCE="admin_fast_lane_jan_batch" ;;
  esac
fi

case "$(printf %s "$MODE_RAW" | tr '[:upper:]' '[:lower:]')" in
  ""|real) MODE="real" ;;
  dry)     MODE="dry"  ;;
  *) echo "ERROR: mode must be 'real' or 'dry' (got: '$MODE_RAW')" >&2; usage; exit 2 ;;
esac

# Endpoint for the current (lane, scope) and a given id.
endpoint_for() {
  case "${LANE}:${SCOPE}" in
    plain:profile) printf '/admin/analytics/%s/fast-lane' "$1" ;;
    plus:profile)  printf '/admin/analytics/%s/fast-lane-plus' "$1" ;;
    plus:user)     printf '/admin/user/%s/fast-lane-plus' "$1" ;;
  esac
}

if [[ -z "${REQUESTER// /}" ]]; then
  echo "ERROR: requester (Slack ID or email) is required" >&2
  usage
  exit 2
fi

# Extract + lowercase + de-dupe UUIDs, preserving first-seen order.
mapfile -t PROFILE_IDS < <(printf '%s\n' "$RAW_IDS" \
  | grep -oiE "$UUID_RE" \
  | tr '[:upper:]' '[:lower:]' \
  | awk '!seen[$0]++')

if [[ "${#PROFILE_IDS[@]}" -eq 0 ]]; then
  echo "ERROR: no profile UUID found in input: '$RAW_IDS'" >&2
  echo "Provide a profile UUID or a credits.muso.ai/profile/<uuid> URL." >&2
  exit 2
fi

# dry mode → short-circuit every admin-API write (GET/trino still real).
if [[ "$MODE" == "dry" ]]; then
  export OPS_DRY_RUN=1
fi

audit() {
  # Best-effort JSONL audit; never fails the run.
  local mkdir_target; mkdir_target="$(dirname "$AUDIT_PATH")"
  mkdir -p "$mkdir_target" 2>/dev/null || true
  printf '%s\n' "$1" >> "$AUDIT_PATH" 2>/dev/null || \
    echo "WARN: could not append fastlane audit to $AUDIT_PATH" >&2
}

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Read current analytics for a profile from the live OLAP cube (replaces the frozen
# postgresql_core.public.profile_v3_lifetime, dead 2026-06-06). ce_streams @ period='all'
# is the muso.ai profile-page lifetime headline, recomputed continuously from track_daily.
# Echoes "creditcount|trackswithdata|streams|spotifystreams|youtubestreams"
# or empty string on any failure (readback is best-effort, never blocks the fire).
# read_lifetime <profile_id> [seconds] — seconds bounds THIS read (default
# TRINO_TIMEOUT). Never called with 0: GNU `timeout 0` means "no limit".
read_lifetime() {
  local pid="$1" budget="${2:-$TRINO_TIMEOUT}" csv line
  csv="$(printf "SELECT profile_credits_count, tracks_count, ce_streams, ce_spotify_streams, ce_youtube_streams FROM postgresql_olap.public.cube_analytics_profile_view WHERE period='all' AND profile_id='%s'" "$pid" \
    | timeout "$budget" "$TRINO" 2>/dev/null)" || return 0
  # Trino CSV quotes every field and emits no header; take the first data row.
  line="$(printf '%s\n' "$csv" | grep -m1 . || true)"
  [[ -n "$line" ]] || return 0
  printf '%s' "$line" | tr -d '"' | tr ',' '|'
}

# --- header -----------------------------------------------------------------
case "${LANE}:${SCOPE}" in
  plain:profile) TITLE="Fastlane — profile analytics bootstrap"; UNIT="Profiles" ;;
  plus:profile)  TITLE="Fastlane+ — full-freshness (recalc + rescrape)"; UNIT="Profiles" ;;
  plus:user)     TITLE="Fastlane+ (user) — full-freshness across owned profiles"; UNIT="Users" ;;
esac
REPORT=":rocket: *${TITLE}*
Mode: \`${MODE}\` | ${UNIT}: ${#PROFILE_IDS[@]} | Requester: \`${REQUESTER}\` | trigger: \`${TRIGGER_SOURCE}\`"
[[ "$LANE" == "plus" ]] && REPORT+="
_Full rescrape across all sources: new catalog/tracks land in minutes–tens of minutes (scrape-bound); cubes recompute ~1–5 min after the refresh message processes._"
[[ "$MODE" == "dry" ]] && REPORT+="
_dry-run: no writes; the would-be POST is logged to the dry-run audit._"

any_ok=0
any_baseline=0
# Batch-wide ceiling on time spent reading baselines (see TRINO_BATCH_BUDGET).
baseline_deadline=$(( $(date +%s) + TRINO_BATCH_BUDGET ))

for pid in "${PROFILE_IDS[@]}"; do
  ep="$(endpoint_for "$pid")"

  # BASELINE, read BEFORE the fire. The POST is fire-and-forget: the scrape and
  # cube refresh happen async in the backend, and cubes recompute ~1-5 min after
  # the refresh message is processed. A cube read taken AFTER the POST is
  # therefore still the pre-run value — but racily so, and rendered bare under an
  # "enqueued" bullet it reads as this run's result. That is how "recalculation
  # returned success" became evidence a correction had landed when it had not
  # (W34 ops review: l1lroldyy, Sleiman Damien). Reading first makes the
  # "before this run" label exact instead of approximate.
  # Bounded per read AND across the batch precisely so this cannot delay or
  # prevent the POST below, however many profiles the batch carries.
  baseline=""
  if [[ "$SCOPE" != "user" && "$MODE" != "dry" ]]; then
    baseline_left=$(( baseline_deadline - $(date +%s) ))
    if (( baseline_left > 0 )); then
      baseline="$(read_lifetime "$pid" \
        "$(( baseline_left < TRINO_TIMEOUT ? baseline_left : TRINO_TIMEOUT ))")"
    fi
  fi
  # "not measured" must stay distinguishable from a measured zero — a failed
  # cube read is null in the audit, never 0.
  baseline_json="null"
  if [[ -n "$baseline" ]]; then
    IFS='|' read -r b_cc b_twd b_streams b_sp b_yt <<<"$baseline"
    baseline_json="$(jq -nc \
      --arg cc "$b_cc" --arg twd "$b_twd" --arg s "$b_streams" \
      --arg sp "$b_sp" --arg yt "$b_yt" \
      '{credits:(($cc|tonumber?) // null), tracks:(($twd|tonumber?) // null),
        streams:(($s|tonumber?) // null), spotify_streams:(($sp|tonumber?) // null),
        youtube_streams:(($yt|tonumber?) // null)}')" || baseline_json="null"
  fi

  body="$(jq -nc --arg t "$TRIGGER_SOURCE" '{triggerSource:$t}')"
  out="$(bash "$ADMIN_API" --requester "$REQUESTER" call POST "$ep" "$body" 2>&1)"
  rc=$?

  http_status="$(printf '%s' "$out" | jq -r '.http_status // empty' 2>/dev/null)"
  result="$(printf '%s' "$out" | jq -r '.body.result // empty' 2>/dev/null)"
  # `| values` (not `// empty`) so a literal false is preserved, not swallowed —
  # `discovered=false`/`refreshed=false` is the "queue send failed" signal.
  bootstrapped="$(printf '%s' "$out" | jq -r '.body.data.bootstrapped | values' 2>/dev/null)"
  discovered="$(printf '%s' "$out" | jq -r '.body.data.discovered | values' 2>/dev/null)"
  refreshed="$(printf '%s' "$out" | jq -r '.body.data.refreshed | values' 2>/dev/null)"
  is_dry="$(printf '%s' "$out" | jq -r '.dryRun // false' 2>/dev/null)"

  ok="false"
  if [[ "$rc" -eq 0 && ( "$http_status" == "200" || "$http_status" == "201" ) ]]; then
    ok="true"; any_ok=1
  fi

  audit "$(jq -nc \
    --arg ts "$(ts_now)" --arg requester "$REQUESTER" --arg pid "$pid" \
    --arg trigger "$TRIGGER_SOURCE" --arg mode "$MODE" \
    --arg lane "$LANE" --arg scope "$SCOPE" --arg endpoint "POST ${ep}" \
    --arg http "$http_status" --arg result "$result" \
    --arg bootstrapped "$bootstrapped" --arg discovered "$discovered" --arg refreshed "$refreshed" \
    --arg dry "$is_dry" --arg ok "$ok" --argjson baseline "$baseline_json" \
    '{ts:$ts, agent:"operations", action:"fast_lane_multi_profile", requester:$requester,
       profile_id:$pid, lane:$lane, scope:$scope, endpoint:$endpoint,
       trigger_source:$trigger, mode:$mode,
       http_status:($http|tonumber? // null), result:$result,
       bootstrapped:($bootstrapped=="true"), discovered:($discovered=="true"),
       refreshed:($refreshed=="true"), dry_run:($dry=="true"), success:($ok=="true"),
       baseline_before:$baseline}')"

  if [[ "$ok" == "true" ]]; then
    if [[ "$is_dry" == "true" ]]; then
      REPORT+="
• \`${pid}\` — :large_yellow_circle: dry-run (would enqueue ${LANE}; no write)"
    elif [[ "$SCOPE" == "user" ]]; then
      # Per-user response is a per-profile union; count defensively (shape isn't
      # fully pinned), and skip the cube readback (we don't hold the fanned-out ids).
      processed="$(printf '%s' "$out" | jq -r '(.body.data.results // .body.data.profiles // .body.data // empty) | if type=="array" then length else empty end' 2>/dev/null)"
      detail="HTTP ${http_status}"
      [[ -n "$processed" ]] && detail="${processed} profiles processed, ${detail}"
      REPORT+="
• \`${pid}\` — :white_check_mark: enqueued (${detail})"
    else
      detail="HTTP ${http_status}"
      if [[ "$LANE" == "plus" ]]; then
        [[ -n "$refreshed" ]] && detail="refreshed=${refreshed}, ${detail}"
        [[ -n "$discovered" ]] && detail="discovered=${discovered}, ${detail}"
      fi
      [[ -n "$bootstrapped" ]] && detail="bootstrapped=${bootstrapped}, ${detail}"
      REPORT+="
• \`${pid}\` — :white_check_mark: enqueued (${detail})"
      if [[ "$LANE" == "plus" && ( "$discovered" == "false" || "$refreshed" == "false" ) ]]; then
        REPORT+="
   :warning: a queue send failed (discovered=${discovered:-?}, refreshed=${refreshed:-?}) — logged + Sentry backend-side; safe to re-fire (idempotent)."
      fi
      if [[ -n "$baseline" ]]; then
        IFS='|' read -r cc twd streams sp yt <<<"$baseline"
        any_baseline=1
        REPORT+="
   _baseline, before this run_ — streams=${streams:-?} · spotify=${sp:-?} · youtube=${yt:-?} · credits=${cc:-?} · tracks=${twd:-?}"
      fi
    fi
  else
    msg="$(printf '%s' "$out" | jq -r '.body.message // .body.error // empty' 2>/dev/null)"
    [[ -z "$msg" ]] && msg="$(printf '%s' "$out" | head -c 200)"
    REPORT+="
• \`${pid}\` — :x: not enqueued (HTTP ${http_status:-error}): ${msg}"
  fi
done

if [[ "$LANE" == "plus" ]]; then
  REPORT+="

_Idempotent — re-firing is safe. \`discovered=false\`/\`refreshed=false\` above = a queue send failed; retry. Profiles over ~25K credits (catalog orgs) are skipped by design._"
else
  REPORT+="

_Analytics refresh is async (~130s per profile). Re-check the dashboard shortly. Profiles over ~25K credits (catalog orgs) are skipped by design._"
fi

if [[ "$any_baseline" == "1" ]]; then
  REPORT+="

:warning: _The cube figures above are the state **before** this run and do not reflect this run — the refresh is async. Re-read the cube once it recomputes to see the effect. And note a fastlane/recalculate merges with \`GREATEST\`, so it can only ever RAISE a number: **it cannot apply a downward correction.** If credits were removed and the total should DROP, re-firing this will never do it — that needs an authoritative stats correction from data-platform._"
fi

printf '%s\n' "$REPORT"
exit 0

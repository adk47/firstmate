#!/usr/bin/env bash
# fastlane.sh — deterministic wrapper for Jan's "@Ops fastlane <profile>"
# requests. Fastlane is a PROFILE ANALYTICS BOOTSTRAP, not credit
# verification: it fires POST /admin/analytics/<profileId>/fast-lane (which
# creates a profile_analytics_stats_history row, enqueues publishProfileFastLane
# Kafka work, and invalidates the /profile/:id Redis cache), then reads back the
# profile's current stream/track counts so the operator gets the numbers Jan
# always asks for ("what's the expected stream count after the fastlane?").
#
# Why a wrapper instead of free-form agent calls: the ops agent repeatedly
# misrouted "fastlane" to the lobster credit-verification pipeline
# (dispatch-cv-batch.sh) because the only recipe was soft memory. This wrapper
# is the single deterministic code path the agent runs for a fastlane request.
#
# Usage:
#   fastlane.sh "<profile_ids>" "<thread_ts>" <requester> [<mode>] [<trigger_source>]
#
# Args:
#   profile_ids     One or more profile UUIDs and/or credits.muso.ai/profile/<uuid>
#                   URLs, comma- or whitespace-separated. UUIDs are extracted,
#                   lowercased, and de-duplicated (order preserved). REQUIRED.
#   thread_ts       Slack thread timestamp (for the operator's context; the agent
#                   posts this wrapper's stdout into that thread). "" if none.
#   requester       Slack ID (U...) or email of the human who asked. REQUIRED —
#                   passed to muso-admin-api.sh --requester for the audit trail.
#   mode            real (default) | dry. dry sets OPS_DRY_RUN=1 so the POST is
#                   short-circuited and logged but never hits prod.
#   trigger_source  Backend triggerSource label. Default admin_fast_lane_jan_batch.
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
AUDIT_PATH="${FASTLANE_AUDIT_PATH:-/var/log/openclaw/fastlane-apply.jsonl}"

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

usage() {
  echo "Usage: fastlane.sh \"<profile_ids>\" \"<thread_ts>\" <requester> [real|dry] [<trigger_source>]" >&2
}

# --- args -------------------------------------------------------------------
RAW_IDS="${1:-}"
THREAD_TS="${2:-}"   # carried for context; agent relays stdout into this thread
REQUESTER="${3:-}"
MODE_RAW="${4:-real}"
TRIGGER_SOURCE="${5:-admin_fast_lane_jan_batch}"

case "$(printf %s "$MODE_RAW" | tr '[:upper:]' '[:lower:]')" in
  ""|real) MODE="real" ;;
  dry)     MODE="dry"  ;;
  *) echo "ERROR: mode must be 'real' or 'dry' (got: '$MODE_RAW')" >&2; usage; exit 2 ;;
esac

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
read_lifetime() {
  local pid="$1" csv line
  csv="$(printf "SELECT profile_credits_count, tracks_count, ce_streams, ce_spotify_streams, ce_youtube_streams FROM postgresql_olap.public.cube_analytics_profile_view WHERE period='all' AND profile_id='%s'" "$pid" \
    | "$TRINO" 2>/dev/null)" || return 0
  # Trino CSV quotes every field and emits no header; take the first data row.
  line="$(printf '%s\n' "$csv" | grep -m1 . || true)"
  [[ -n "$line" ]] || return 0
  printf '%s' "$line" | tr -d '"' | tr ',' '|'
}

# --- header -----------------------------------------------------------------
REPORT=":rocket: *Fastlane — profile analytics bootstrap*
Mode: \`${MODE}\` | Profiles: ${#PROFILE_IDS[@]} | Requester: \`${REQUESTER}\` | trigger: \`${TRIGGER_SOURCE}\`"
[[ "$MODE" == "dry" ]] && REPORT+="
_dry-run: no writes; the would-be POST is logged to the dry-run audit._"

any_ok=0

for pid in "${PROFILE_IDS[@]}"; do
  body="$(jq -nc --arg t "$TRIGGER_SOURCE" '{triggerSource:$t}')"
  out="$(bash "$ADMIN_API" --requester "$REQUESTER" call POST "/admin/analytics/${pid}/fast-lane" "$body" 2>&1)"
  rc=$?

  http_status="$(printf '%s' "$out" | jq -r '.http_status // empty' 2>/dev/null)"
  result="$(printf '%s' "$out" | jq -r '.body.result // empty' 2>/dev/null)"
  bootstrapped="$(printf '%s' "$out" | jq -r '.body.data.bootstrapped // empty' 2>/dev/null)"
  is_dry="$(printf '%s' "$out" | jq -r '.dryRun // false' 2>/dev/null)"

  ok="false"
  if [[ "$rc" -eq 0 && ( "$http_status" == "200" || "$http_status" == "201" ) ]]; then
    ok="true"; any_ok=1
  fi

  audit "$(jq -nc \
    --arg ts "$(ts_now)" --arg requester "$REQUESTER" --arg pid "$pid" \
    --arg trigger "$TRIGGER_SOURCE" --arg mode "$MODE" \
    --arg endpoint "POST /admin/analytics/${pid}/fast-lane" \
    --arg http "$http_status" --arg result "$result" \
    --arg bootstrapped "$bootstrapped" --arg dry "$is_dry" --arg ok "$ok" \
    '{ts:$ts, agent:"operations", action:"fast_lane_multi_profile", requester:$requester,
       profile_id:$pid, endpoint:$endpoint, trigger_source:$trigger, mode:$mode,
       http_status:($http|tonumber? // null), result:$result,
       bootstrapped:($bootstrapped=="true"), dry_run:($dry=="true"), success:($ok=="true")}')"

  if [[ "$ok" == "true" ]]; then
    if [[ "$is_dry" == "true" ]]; then
      REPORT+="
• \`${pid}\` — :large_yellow_circle: dry-run (would enqueue fastlane; no write)"
    else
      detail="HTTP ${http_status}"
      [[ -n "$bootstrapped" ]] && detail="bootstrapped=${bootstrapped}, ${detail}"
      REPORT+="
• \`${pid}\` — :white_check_mark: enqueued (${detail})"
      life="$(read_lifetime "$pid")"
      if [[ -n "$life" ]]; then
        IFS='|' read -r cc twd streams sp yt <<<"$life"
        REPORT+="
   streams=${streams:-?} · spotify=${sp:-?} · youtube=${yt:-?} · credits=${cc:-?} · tracks=${twd:-?}"
      fi
    fi
  else
    msg="$(printf '%s' "$out" | jq -r '.body.message // .body.error // empty' 2>/dev/null)"
    [[ -z "$msg" ]] && msg="$(printf '%s' "$out" | head -c 200)"
    REPORT+="
• \`${pid}\` — :x: not enqueued (HTTP ${http_status:-error}): ${msg}"
  fi
done

REPORT+="

_Analytics refresh is async (~130s per profile). Re-check the dashboard shortly. Profiles over ~25K credits (catalog orgs) are skipped by design._"

printf '%s\n' "$REPORT"
exit 0

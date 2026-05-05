#!/usr/bin/env bash
# dispatch-investigations.sh — emit a per-profile spawn manifest for B3.
#
# Reads the runlog's profile_group_fetched events and emits a JSON manifest
# the main agent uses to drive parallel `agent()` calls (max 10 in flight,
# round-robin for larger batches per feedback_credit_subagent_cap.md).
#
# This script does NOT spawn subagents itself — it can't, openclaw spawn is
# an in-agent tool call. It assembles the prompts + per-profile output paths
# so the agent can iterate and call agent(template=..., env=...) one at a
# time (or pooled in batches of 10).
#
# Usage:
#   dispatch-investigations.sh --run-id <id>
#
# Env (required):
#   OPS_RUNLOG_DIR   — base dir for runlogs
#   OPS_RUN_DIR      — derived dir for per-run state (default: $OPS_RUNLOG_DIR/<day>)
#   SKILL_DIR        — credit-verification skill dir
#
# Stdout: JSON object {pool_size, total_profiles, profiles:[{profile_id, cr_ids, prompt_path, out_path, env: {...}}, ...]}
# Exit codes:
#   0 = manifest written
#   2 = invalid args / env
#   3 = no profile_group_fetched events found in runlog (nothing to dispatch)

set -euo pipefail

RUN_ID=""
POOL_SIZE="${OPS_INVESTIGATION_POOL_SIZE:-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2 ;;
    --pool-size) POOL_SIZE="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_ID"          ]] || { echo "ERROR: --run-id required"          >&2; exit 2; }
[[ -n "${OPS_RUNLOG_DIR:-}" ]] || { echo "ERROR: OPS_RUNLOG_DIR not set" >&2; exit 2; }
[[ -n "${SKILL_DIR:-}"   ]] || { echo "ERROR: SKILL_DIR not set"         >&2; exit 2; }

DAY="${RUN_ID:0:4}-${RUN_ID:4:2}-${RUN_ID:6:2}"
RUNLOG="${OPS_RUNLOG_DIR}/${DAY}/${RUN_ID}.jsonl"
[[ -f "$RUNLOG" ]] || { echo "ERROR: runlog not found at $RUNLOG" >&2; exit 2; }

OPS_RUN_DIR="${OPS_RUN_DIR:-${OPS_RUNLOG_DIR}/${DAY}}"
INVEST_DIR="${OPS_RUN_DIR}/investigations/${RUN_ID}"
PROMPT_DIR="${OPS_RUN_DIR}/prompts/${RUN_ID}"
mkdir -p "$INVEST_DIR" "$PROMPT_DIR"

TEMPLATE="${SKILL_DIR}/templates/investigate-profile.md"
[[ -f "$TEMPLATE" ]] || { echo "ERROR: template missing: $TEMPLATE" >&2; exit 2; }

# Extract distinct profile groups from the runlog. Schema (from SKILL.md B2):
#   {event: "profile_group_fetched", profile_id, cr_ids:[...], count, ...optional credited_name/track_title/role/risk_breakdown}
groups_json=$(jq -s -c '
  [.[] | select(.event == "profile_group_fetched")]
  | unique_by(.profile_id)
' "$RUNLOG" 2>/dev/null || echo "[]")

total=$(echo "$groups_json" | jq 'length')
if (( total == 0 )); then
  echo "ERROR: no profile_group_fetched events in $RUNLOG — nothing to dispatch" >&2
  exit 3
fi

# Render one prompt file per profile group + plan the JSON manifest.
manifest=$(echo "$groups_json" | jq -c \
  --arg template_path "$TEMPLATE" \
  --arg invest_dir "$INVEST_DIR" \
  --arg prompt_dir "$PROMPT_DIR" \
  --arg run_id "$RUN_ID" \
  --arg run_dir "$OPS_RUN_DIR" \
  --argjson pool "$POOL_SIZE" '
  {
    pool_size: $pool,
    total_profiles: length,
    profiles: [
      .[] |
        # First non-null external ID across this profiles credits, by source.
        # Each subagent investigates the profile as a whole; the first credit
        # carrying a given ID is enough to anchor that platforms direct URL.
        # Field names match the SKILL B2 grouping schema (admin API verified
        # 2026-05-01): spotify_track_id (NOT spotify_id), isrc nested under
        # metadata, spotify_artist_ids as array, etc.
        ((.credits // []) | map(select(.spotify_track_id != null)) | (first.spotify_track_id // "")) as $spotify_track_id |
        ((.credits // []) | map(.spotify_artist_ids // []) | flatten | unique | (.[0] // ""))        as $spotify_artist_id |
        ((.credits // []) | map(select(.isrc != null))             | (first.isrc // ""))             as $isrc |
        ((.credits // []) | map(select(.track_id != null))         | (first.track_id // ""))         as $track_id |
        ((.credits // []) | map(select(.spotify_track_title != null)) | (first.spotify_track_title // "")) as $spotify_title |
        # Future-proof: API does not return these today, but if it ever does,
        # plumbing is ready.
        ((.credits // []) | map(select(.apple_music_id != null)) | (first.apple_music_id // "")) as $apple_id |
        ((.credits // []) | map(select(.musicbrainz_id != null)) | (first.musicbrainz_id // "")) as $mbid |
        ((.credits // []) | map(select(.tidal_id != null))       | (first.tidal_id // ""))       as $tidal_id |
        ((.credits // []) | map(select(.discogs_id != null))     | (first.discogs_id // ""))     as $discogs_id |
        {
          profile_id: .profile_id,
          cr_ids: (.cr_ids // []),
          credits: (.credits // []),
          credited_name: (.credited_name // .profile_name // ""),
          track_title:   (.track_title   // $spotify_title // ""),
          role:          (.role          // ((.credits // [])[0].roles // [] | join(", "))),
          risk_breakdown: (.risk_breakdown // {}),
          prompt_path: ($prompt_dir + "/" + .profile_id + ".md"),
          out_path:    ($invest_dir + "/" + .profile_id + ".json"),
          env: {
            PROFILE_ID:           .profile_id,
            CR_IDS:               ((.cr_ids // []) | join(",")),
            CREDITED_NAME:        (.credited_name // .profile_name // ""),
            TRACK_TITLE:          (.track_title   // $spotify_title // ""),
            ROLE:                 (.role          // ((.credits // [])[0].roles // [] | join(", "))),
            # PR #236 Phase 2 (verified 2026-05-01): per-credit external IDs,
            # first non-null across the profiles credits. Empty when API did
            # not return them. build-search-url.sh emits direct entity URLs
            # when these are set, falls back to encoded search URLs when empty.
            SPOTIFY_TRACK_ID:     $spotify_track_id,
            SPOTIFY_ARTIST_ID:    $spotify_artist_id,
            ISRC:                 $isrc,
            TRACK_ID:             $track_id,
            APPLE_MUSIC_ID:       $apple_id,
            MUSICBRAINZ_ID:       $mbid,
            TIDAL_ID:             $tidal_id,
            DISCOGS_ID:           $discogs_id,
            # Profile-level signals (used by Step 3 risk-steering table)
            PROFILE_NAME:         (.profile_name // ""),
            PROFILE_SPOTIFY_ID:   (.profile_spotify_id // ""),
            PROFILE_CREDIT_COUNT: ((.profile_credit_count // 0) | tostring),
            PROFILE_POPULARITY:   ((.profile_popularity // 0) | tostring),
            CREDITS_JSON:         ((.credits // []) | tostring),
            RISK_BREAKDOWN_JSON:  ((.risk_breakdown // {}) | tostring),
            INVESTIGATION_OUT_FILE: ($invest_dir + "/" + .profile_id + ".json"),
            OPS_RUN_ID:           $run_id,
            OPS_RUN_DIR:          $run_dir
          }
        }
    ]
  }
')

# Write a per-profile prompt file: template content + a header section binding
# the inputs. Subagents read this single file as their initial prompt.
echo "$manifest" | jq -r '.profiles[] | [.profile_id, .prompt_path, (.env | tostring)] | @tsv' \
| while IFS=$'\t' read -r pid prompt_path env_json; do
    {
      printf '<!-- Spawn config for profile %s — emitted by dispatch-investigations.sh -->\n' "$pid"
      printf '<!-- ENV: %s -->\n\n' "$env_json"
      cat "$TEMPLATE"
    } > "$prompt_path"
  done

# Emit the manifest on stdout. The agent consumes this to drive its agent() calls.
echo "$manifest"

#!/usr/bin/env bash
# post-progress-tick.sh — post a per-profile "X of Y processed" tick to the
# parent batch thread, after a profile's verdict / action_attempted /
# escalation_posted events have landed in the runlog.
#
# Why this exists: the user wants visible activity during a batch run, not
# just a single message at the end. Pairs with post-batch-announce.sh
# (start) and post-batch-summary.sh (end). All three reply in-thread on the
# same parent ts.
#
# The agent calls this script ONCE per profile, after writing that profile's
# decisions to the runlog. The script:
#   - Computes cumulative {processed, total} from the runlog (count of
#     distinct decision profile_ids vs. count of profile_group_fetched ids).
#   - Throttles: skips if the previous progress event landed within
#     CV_PROGRESS_TICK_THROTTLE_SECONDS (default 5s), to avoid Slack spam
#     when profiles complete back-to-back. Throttle exits rc=0.
#   - Writes EXACTLY ONE runlog event per invocation: `progress` (when the
#     Slack tick was posted) OR `progress_throttled` (when skipped) — never
#     both. Both event types are metadata and bypass the cookie-cutter and
#     per-profile-evidence gates per runlog.sh whitelist.
#   - On the post path: sends the tick line via openclaw CLI with
#     --reply-to "$PARENT_MSG_TS".
#
# Counting note: downstream consumers that want "messages actually posted to
# Slack" should count `progress` events only. Consumers that want "all
# per-profile invocations regardless of delivery" should count both.
#
# Usage:
#   post-progress-tick.sh <RUN_ID> <PROFILE_ID> [<CREDITED_NAME>]
#
# Env (matches post-batch-summary.sh / post-batch-announce.sh shape):
#   OPS_RUNLOG_DIR                              required
#   OPS_PARENT_MSG_TS                           required (parent thread ts)
#   OPS_CREDIT_VERIFICATION_CHANNEL_ID          optional, default C0APB2CMM7C
#   OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID  required when OPS_DRY_RUN=1
#   OPS_OPENCLAW_PROFILE                        optional, default "main"
#   OPS_OPENCLAW_ACCOUNT                        optional, default "operations"
#   CV_PROGRESS_TICK_THROTTLE_SECONDS           optional, default 5
#
# Exit codes:
#   0   tick posted, or throttled (still rc=0 — throttling is not an error)
#   2   missing env / arg
#   5   runlog not found
#   10  openclaw message send failed
#
# Flags:
#   --dry-run-cli   print the would-be payload, don't post.
#   --force         skip throttle (always post).

set -euo pipefail

DRY_RUN_CLI=0
FORCE=0
_positional=()
for _arg in "$@"; do
    case "$_arg" in
        --dry-run-cli) DRY_RUN_CLI=1 ;;
        --force)       FORCE=1 ;;
        *)             _positional+=("$_arg") ;;
    esac
done
set -- "${_positional[@]:-}"
unset _positional _arg

RUN_ID="${1:-}"
PROFILE_ID="${2:-}"
CREDITED_NAME="${3:-}"

if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID (arg 1) is required" >&2
    exit 2
fi
if [[ -z "$PROFILE_ID" ]]; then
    echo "ERROR: PROFILE_ID (arg 2) is required" >&2
    exit 2
fi
if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi
PARENT_MSG_TS="${OPS_PARENT_MSG_TS:-}"
if [[ -z "$PARENT_MSG_TS" ]]; then
    echo "ERROR: OPS_PARENT_MSG_TS is required" >&2
    exit 2
fi

day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
runlog_path="${OPS_RUNLOG_DIR}/${day_iso}/${RUN_ID}.jsonl"
if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog not found: $runlog_path" >&2
    exit 5
fi

CV_PROGRESS_TICK_THROTTLE_SECONDS="${CV_PROGRESS_TICK_THROTTLE_SECONDS:-5}"

# --- Compute cumulative progress from runlog -------------------------------
progress_summary=$(jq -s -c \
    --arg pid "$PROFILE_ID" \
    '
    . as $events
    | ([ $events[] | select(.event=="profile_group_fetched") | .profile_id // empty | select(. != "") ] | unique) as $fetched
    | ([ $events[]
         | select(.event=="verdict" or .event=="action_attempted" or .event=="escalation_posted")
         | .profile_id // empty
         | select(. != "")
       ] | unique) as $decisioned
    | (last($events[] | select(.event=="progress")) // null) as $last_progress
    | {
        total: ($fetched | length),
        processed: ($decisioned | length),
        is_decisioned: ($decisioned | index($pid) != null),
        last_progress_ts: ($last_progress.ts // null)
      }
    ' "$runlog_path")

total=$(jq -r '.total' <<<"$progress_summary")
processed=$(jq -r '.processed' <<<"$progress_summary")
is_decisioned=$(jq -r '.is_decisioned' <<<"$progress_summary")
last_progress_ts=$(jq -r '.last_progress_ts' <<<"$progress_summary")

# Refuse to post a tick for a profile whose decisions haven't landed yet —
# avoids advertising "✓" before any verdict is written.
if [[ "$is_decisioned" != "true" ]]; then
    echo "ERROR: profile $PROFILE_ID has no decision events yet — refusing to post a progress tick that would mislead." >&2
    exit 2
fi

# --- Throttle ---------------------------------------------------------------
should_post=1
throttle_remaining=0
if [[ "$FORCE" -eq 0 && "$last_progress_ts" != "null" && -n "$last_progress_ts" ]]; then
    # Cross-platform date diff (BSD vs GNU). Try GNU first, fall back to BSD.
    # NOTE: BSD `date -j -f` parses the timestamp in LOCAL TIME by default,
    # even when the format string ends with `Z` (the Z is literal). Use `-u`
    # to force UTC interpretation; otherwise the epoch is off by the local
    # tz offset and the throttle window is misjudged by hours.
    last_epoch=$(date -u -d "$last_progress_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_progress_ts" +%s 2>/dev/null || echo 0)
    now_epoch=$(date -u +%s)
    delta=$(( now_epoch - last_epoch ))
    if (( delta < CV_PROGRESS_TICK_THROTTLE_SECONDS )); then
        should_post=0
        throttle_remaining=$(( CV_PROGRESS_TICK_THROTTLE_SECONDS - delta ))
    fi
fi

now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [[ "$should_post" -eq 0 ]]; then
    # Write a progress_throttled event so we can see the skip in forensics.
    jq -n -c \
        --arg rid "$RUN_ID" --arg ts "$now_iso" --arg pid "$PROFILE_ID" \
        --argjson processed "$processed" --argjson total "$total" \
        --argjson remaining "$throttle_remaining" \
        '{event:"progress_throttled", run_id:$rid, ts:$ts,
          profile_id:$pid, processed:$processed, total:$total,
          throttle_remaining_seconds:$remaining}' >> "$runlog_path"
    echo "POST_PROGRESS_TICK_THROTTLED: ${processed}/${total} (next in ${throttle_remaining}s)"
    exit 0
fi

# --- Compose ----------------------------------------------------------------
display_name="${CREDITED_NAME:-$PROFILE_ID}"
tick_text="✓ ${display_name} — ${processed}/${total} profiles processed"

# --- Channel routing --------------------------------------------------------
case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
        if [[ -z "${OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID:-}" ]]; then
            echo "ERROR: OPS_DRY_RUN=1 but OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID is unset" >&2
            exit 2
        fi
        target_channel="$OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"
        ;;
    *)
        target_channel="${OPS_CREDIT_VERIFICATION_CHANNEL_ID:-C0APB2CMM7C}"
        ;;
esac

OPS_OPENCLAW_PROFILE="${OPS_OPENCLAW_PROFILE:-main}"
OPS_OPENCLAW_ACCOUNT="${OPS_OPENCLAW_ACCOUNT:-operations}"

# --- Test/preview mode ------------------------------------------------------
if [[ "$DRY_RUN_CLI" -eq 1 ]]; then
    echo "POST_PROGRESS_TICK_OK: target=$target_channel reply_to=$PARENT_MSG_TS"
    echo "----- BODY -----"
    printf '%s\n' "$tick_text"
    jq -n -c \
        --arg rid "$RUN_ID" --arg ts "$now_iso" --arg pid "$PROFILE_ID" \
        --arg name "$display_name" \
        --argjson processed "$processed" --argjson total "$total" \
        '{event:"progress", run_id:$rid, ts:$ts,
          profile_id:$pid, credited_name:$name,
          processed:$processed, total:$total, dry_run_cli:true}' >> "$runlog_path"
    exit 0
fi

# --- Send via openclaw CLI --------------------------------------------------
if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw CLI not found on PATH" >&2
    exit 10
fi

extract_openclaw_json() {
    awk '/^[[:space:]]*\{/{p=1} p'
}

resp=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" message send \
    --account "$OPS_OPENCLAW_ACCOUNT" \
    --channel slack \
    --target "$target_channel" \
    --reply-to "$PARENT_MSG_TS" \
    --message "$tick_text" \
    --json 2>&1) || {
    echo "ERROR: openclaw message send failed:" >&2
    echo "$resp" >&2
    exit 10
}

tick_msg_id=$(printf '%s\n' "$resp" | extract_openclaw_json | jq -r '.messageId // .ts // .id // .message.ts // empty' 2>/dev/null || true)

jq -n -c \
    --arg rid "$RUN_ID" --arg ts "$now_iso" --arg pid "$PROFILE_ID" \
    --arg name "$display_name" --arg tid "$tick_msg_id" \
    --argjson processed "$processed" --argjson total "$total" \
    '{event:"progress", run_id:$rid, ts:$ts,
      profile_id:$pid, credited_name:$name,
      processed:$processed, total:$total,
      tick_msg_ts:(if $tid == "" then null else $tid end)}' >> "$runlog_path"

echo "POST_PROGRESS_TICK_OK: ${processed}/${total} tick_msg_ts=${tick_msg_id:-<unparsed>}"
exit 0

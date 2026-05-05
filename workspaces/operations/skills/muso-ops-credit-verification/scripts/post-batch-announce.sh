#!/usr/bin/env bash
# post-batch-announce.sh — post the in-thread "we're starting a batch"
# announcement to #credit-verification, immediately after fetch-queue.sh
# returns and before B2 (per-profile investigation) begins.
#
# Why this exists: today the user invokes `(Ops) run credit verification
# batch (fetch_size=50)` and waits 8+ minutes in silence before seeing one
# parent message at the end. This script posts a brief "starting" reply
# in the same thread so the user sees activity right away. Pairs with
# post-progress-tick.sh (per-profile ticks) and post-batch-summary.sh
# (final). All three target the same parent thread via --reply-to.
#
# Implementation parallels post-batch-summary.sh's openclaw CLI call shape:
#   - same OPS_OPENCLAW_PROFILE / OPS_OPENCLAW_ACCOUNT envs
#   - same dryRun → channel routing
#   - same "Config warnings:" stdout-pollution hardening (extract_openclaw_json)
#   - same script_invoked / script_exited breadcrumbs
#   - writes a `batch_announced` runlog event so the post-time audit can
#     verify the announcement actually went out (planned: enforce its
#     presence in browser-evidence-audit.sh).
#
# Usage:
#   post-batch-announce.sh <RUN_ID> [<PARENT_MSG_TS>]
#
# Env:
#   OPS_RUNLOG_DIR                              required
#   OPS_QUEUE_JSON_PATH                         optional (default /tmp/${RUN_ID}.queue.json)
#   OPS_PARENT_MSG_TS                           parent thread ts (or arg 2)
#   OPS_CREDIT_VERIFICATION_CHANNEL_ID          optional, default C0APB2CMM7C
#   OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID  required when OPS_DRY_RUN=1
#   OPS_OPENCLAW_PROFILE                        optional, default "main"
#   OPS_OPENCLAW_ACCOUNT                        optional, default "operations"
#
# Exit codes:
#   0   announcement posted (or --dry-run-cli preview)
#   2   missing env / arg / queue file / parent ts
#   5   runlog not found
#   10  openclaw message send failed
#
# Flags:
#   --dry-run-cli   print the would-be payload, don't actually post.

set -euo pipefail

DRY_RUN_CLI=0
_positional=()
for _arg in "$@"; do
    case "$_arg" in
        --dry-run-cli) DRY_RUN_CLI=1 ;;
        *)             _positional+=("$_arg") ;;
    esac
done
set -- "${_positional[@]:-}"
unset _positional _arg

RUN_ID="${1:-}"
PARENT_MSG_TS="${2:-${OPS_PARENT_MSG_TS:-}}"

if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID (arg 1) is required" >&2
    exit 2
fi
if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi
if [[ -z "$PARENT_MSG_TS" ]]; then
    echo "ERROR: parent thread ts is required (arg 2 or OPS_PARENT_MSG_TS)" >&2
    exit 2
fi

day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
runlog_path="${OPS_RUNLOG_DIR}/${day_iso}/${RUN_ID}.jsonl"

if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog not found: $runlog_path" >&2
    exit 5
fi

QUEUE_JSON_PATH="${OPS_QUEUE_JSON_PATH:-/tmp/${RUN_ID}.queue.json}"
if [[ ! -r "$QUEUE_JSON_PATH" ]]; then
    echo "ERROR: queue JSON not found at $QUEUE_JSON_PATH (set OPS_QUEUE_JSON_PATH)" >&2
    exit 2
fi

# Diagnostic breadcrumb
_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n -c --arg rid "$RUN_ID" --arg ts "$_now" --arg dr "$DRY_RUN_CLI" \
    '{event:"script_invoked", script:"post-batch-announce.sh", dry_run_cli:($dr|tonumber), run_id:$rid, ts:$ts}' \
    >> "$runlog_path"
_emit_exit() {
    local rc="$1" reason="${2:-}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n -c --arg rid "$RUN_ID" --arg ts "$now" --argjson rc "$rc" --arg reason "$reason" \
        '{event:"script_exited", script:"post-batch-announce.sh", rc:$rc, reason:$reason, run_id:$rid, ts:$ts}' \
        >> "$runlog_path" 2>/dev/null || true
}
trap '_emit_exit "$?" ""' EXIT

# --- Idempotency gate ------------------------------------------------------
# A previous successful invocation already announced. Re-posting would
# duplicate the in-thread "Starting…" Slack message and write a second
# batch_announced runlog event (which the audit treats as benign — count > 0
# is fine — but doubled Slack noise is user-visible).
#
# Detect by scanning the runlog for any prior batch_announced event with the
# same run_id. If present, write a batch_announce_skipped event citing the
# original announce_msg_ts and exit 0 without sending. Bats covers this.
existing_announce=$(jq -s -c '
    [.[] | select(.event=="batch_announced") | {ts, announce_msg_ts: (.announce_msg_ts // null)}] | (last // null)
' "$runlog_path")
if [[ -n "$existing_announce" && "$existing_announce" != "null" ]]; then
    prior_ts=$(jq -r '.ts // ""' <<<"$existing_announce")
    prior_msg_ts=$(jq -r '.announce_msg_ts // ""' <<<"$existing_announce")
    jq -n -c --arg rid "$RUN_ID" --arg ts "$_now" \
        --arg prior_ts "$prior_ts" --arg prior_msg_ts "$prior_msg_ts" \
        '{event:"batch_announce_skipped", script:"post-batch-announce.sh",
          run_id:$rid, ts:$ts, reason:"already_announced",
          prior_announce_ts:$prior_ts,
          prior_announce_msg_ts:(if $prior_msg_ts == "" then null else $prior_msg_ts end)}' \
        >> "$runlog_path"
    echo "POST_BATCH_ANNOUNCE_SKIPPED: prior announce at $prior_ts (msg_ts=${prior_msg_ts:-<unknown>})"
    exit 0
fi

# --- Read queue + group by profile -----------------------------------------
# fetch-queue.sh emits {queue_depth, items, fetch_size}. Items already carry
# {profile_id, credited_name, ...}. Group by profile_id, take the first
# credited_name (collapsed roles are agent-side; we just need a name list).
queue_summary=$(jq -c '
    # fetch-queue.sh emits raw admin-API items. The credited name lives at
    # .profile.name (verified against live API 2026-05-01, see SKILL.md B2
    # field reference). Top-level .credited_name / .profile_name are reserved
    # for the post-B2 enriched envelope written into profile_group_fetched
    # events, NOT the raw items consumed here. Tier of fallbacks:
    #   .profile.name        — primary, what the user sees on muso.ai
    #   .credited_name       — enriched envelope (some test fixtures)
    #   .profile_name        — legacy
    #   "(unnamed)"          — last resort, surfaces field-name drift
    (.queue_depth // 0) as $total
    | (.items // []) as $items
    | ($items | length) as $fetched
    | ($items | group_by(.profileId // .profile_id // "")) as $groups
    | {
        queue_depth: $total,
        fetch_size: (.fetch_size // $fetched),
        items_in_run: $fetched,
        profile_count: ($groups | length),
        profile_names: [
            $groups[]
            | (.[0].profile.name // .[0].credited_name // .[0].profile_name // "(unnamed)")
        ]
    }
' "$QUEUE_JSON_PATH")

queue_depth=$(jq -r '.queue_depth' <<<"$queue_summary")
fetch_size=$(jq -r '.fetch_size' <<<"$queue_summary")
items_in_run=$(jq -r '.items_in_run' <<<"$queue_summary")
profile_count=$(jq -r '.profile_count' <<<"$queue_summary")
# Truncate profile name list to keep the message short
profile_names_str=$(jq -r '.profile_names | (if length > 6 then (.[0:6] | join(", ")) + " (and " + (length - 6 | tostring) + " more)" else join(", ") end)' <<<"$queue_summary")

# --- Compose -----------------------------------------------------------------
announce_text=$(cat <<EOF
🔍 Starting credit verification batch
• Unverified queue depth: ${queue_depth}
• This run: ${items_in_run} credits across ${profile_count} profile groups
• Profiles: ${profile_names_str}
• Run ID: \`${RUN_ID}\`
EOF
)

# --- Choose channel ----------------------------------------------------------
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

# --- Test/preview mode -------------------------------------------------------
if [[ "$DRY_RUN_CLI" -eq 1 ]]; then
    echo "POST_BATCH_ANNOUNCE_OK: target=$target_channel reply_to=$PARENT_MSG_TS"
    echo "----- BODY -----"
    printf '%s\n' "$announce_text"
    # Also write the runlog event so tests / forensics see the announce shape
    jq -n -c \
        --arg rid "$RUN_ID" --arg ts "$_now" --arg pts "$PARENT_MSG_TS" \
        --argjson qd "$queue_depth" --argjson fs "$fetch_size" \
        --argjson pc "$profile_count" \
        '{event:"batch_announced", run_id:$rid, ts:$ts,
          queue_depth:$qd, fetch_size:$fs, profile_count:$pc,
          parent_msg_ts:$pts, dry_run_cli:true}' >> "$runlog_path"
    exit 0
fi

# --- Send via openclaw CLI ---------------------------------------------------
if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw CLI not found on PATH" >&2
    exit 10
fi

extract_openclaw_json() {
    awk '/^[[:space:]]*\{/{p=1} p'
}
record_openclaw_warning() {
    local resp="$1"
    if printf '%s\n' "$resp" | grep -q '^Config warnings:'; then
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq -n -c --arg rid "$RUN_ID" --arg ts "$now" \
            '{event:"script_warning", script:"post-batch-announce.sh", source:"openclaw_cli_config_warnings", run_id:$rid, ts:$ts}' \
            >> "$runlog_path" 2>/dev/null || true
    fi
}

resp=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" message send \
    --account "$OPS_OPENCLAW_ACCOUNT" \
    --channel slack \
    --target "$target_channel" \
    --reply-to "$PARENT_MSG_TS" \
    --message "$announce_text" \
    --json 2>&1) || {
    echo "ERROR: openclaw message send failed:" >&2
    echo "$resp" >&2
    exit 10
}
record_openclaw_warning "$resp"

announce_msg_id=$(printf '%s\n' "$resp" | extract_openclaw_json | jq -r '.messageId // .ts // .id // .message.ts // empty' 2>/dev/null || true)

# Authoritative runlog event
jq -n -c \
    --arg rid "$RUN_ID" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg pts "$PARENT_MSG_TS" \
    --arg amid "$announce_msg_id" \
    --argjson qd "$queue_depth" --argjson fs "$fetch_size" \
    --argjson pc "$profile_count" \
    '{event:"batch_announced", run_id:$rid, ts:$ts,
      queue_depth:$qd, fetch_size:$fs, profile_count:$pc,
      parent_msg_ts:$pts, announce_msg_ts:(if $amid == "" then null else $amid end)}' \
    >> "$runlog_path"

echo "POST_BATCH_ANNOUNCE_OK: parent_thread=$PARENT_MSG_TS announce_msg_ts=${announce_msg_id:-<unparsed>}"
exit 0

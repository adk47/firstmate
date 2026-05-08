#!/usr/bin/env bash
# post-batch-summary.sh — sanctioned, mechanical entry point for posting
# the [HEARTBEAT-BATCH] parent summary + thread reply to the
# #credit-verification channel.
#
# Why this exists: the 2026-04-28 15:13 / 15:26 UTC dry-runs showed gpt-5.5
# posting hand-composed "Queue fetch succeeded — no writes" messages after
# only running B0+B1, never reaching B6. Hot-patching SKILL.md with prose
# rules ("Proceed directly to B2", "do NOT post any Slack summary at this
# point") did not change behavior — the model reused its cached bash
# template. Per memory feedback_llm_instruction_insufficient, the fix has
# to be mechanical.
#
# This script is the only sanctioned path to post the parent + thread
# summary. It reads the runlog truth floor, refuses to post if required
# events are missing, composes the message via render-slack-summary.sh
# (already truth-floor-only), and posts via the openclaw message CLI
# directly — bypassing the agent's MCP message tool entirely. The
# enforcer plugin's before_tool_call hook on the MCP message tool blocks
# any direct attempts to post a [HEARTBEAT-BATCH] message that didn't
# come through this script.
#
# Usage:
#   post-batch-summary.sh <RUN_ID>
#
# Env:
#   OPS_RUNLOG_DIR                          required
#   OPS_CREDIT_VERIFICATION_CHANNEL_ID      optional, default C0APB2CMM7C
#   OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID  required when run is dry-run
#   OPS_OPENCLAW_PROFILE                    optional, default "main"
#
# Exit codes:
#   0   parent + thread posted successfully (or `--dry-run` test mode)
#   2   missing env / missing arg
#   5   runlog not found
#   6   no run_finished event in runlog (B6 hasn't run yet — refuse)
#   7   in-flight shape detected: queue_depth_at_start > 0 AND
#       action_attempted == 0 (Failure 1 shape — refuse)
#   10  openclaw message send failed, or parent response lacked a thread id
#
# Flags:
#   --dry-run-cli   print the payload that would be sent and exit 0,
#                   skip the actual openclaw message send. Used by tests
#                   and by callers that want to validate without posting.

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

if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID (arg 1) is required" >&2
    exit 2
fi
if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER_SCRIPT="$SCRIPT_DIR/render-slack-summary.sh"
if [[ ! -x "$RENDER_SCRIPT" && ! -r "$RENDER_SCRIPT" ]]; then
    echo "ERROR: render-slack-summary.sh not found at $RENDER_SCRIPT" >&2
    exit 2
fi

day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
runlog_path="${OPS_RUNLOG_DIR}/${day_iso}/${RUN_ID}.jsonl"

if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog not found: $runlog_path" >&2
    exit 5
fi

# Diagnostic breadcrumb: prove this script ran, with what flags, in the runlog.
# Written via direct append (NOT runlog.sh) to bypass cookie-cutter / browser
# gates — this is metadata, not a decision event. If the agent skips
# post-batch-summary.sh, the runlog won't have this trail and the next
# audit can detect the bypass.
_pbs_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n -c --arg rid "$RUN_ID" --arg ts "$_pbs_now" --arg dr "$DRY_RUN_CLI" \
    '{event:"script_invoked", script:"post-batch-summary.sh", dry_run_cli:($dr|tonumber), run_id:$rid, ts:$ts}' \
    >> "$runlog_path"
_pbs_emit_exit() {
    local rc="$1" reason="${2:-}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n -c --arg rid "$RUN_ID" --arg ts "$now" --argjson rc "$rc" --arg reason "$reason" \
        '{event:"script_exited", script:"post-batch-summary.sh", rc:$rc, reason:$reason, run_id:$rid, ts:$ts}' \
        >> "$runlog_path" 2>/dev/null || true
}
trap '_pbs_emit_exit "$?" ""' EXIT

# --- Refusal gate 1: no run_finished event ----------------------------------
# render-slack-summary.sh would also exit 6 in this case, but we want the
# error path to be ours so callers can distinguish "post-batch-summary
# refused" from "render template error". Same exit code (6) for clarity.
if ! grep -q '"event":"run_finished"' "$runlog_path"; then
    echo "ERROR: post-batch-summary refusing — no run_finished event in $runlog_path. Run compute-run-summary.sh --final first (B6)." >&2
    exit 6
fi

# --- Refusal gate 2: in-flight shape (Failure 1) ----------------------------
# A run with non-empty queue but zero action_attempted events is the exact
# shape gpt-5.5 produced when it bailed at B1: fetched the queue, never
# processed any profile, then tried to post "Queue fetch succeeded — no
# writes". Refuse cleanly here so a stray run_finished (e.g. premature
# autofill that slipped past the lockfile guard) still can't unlock the
# Slack post.
attempts=$(grep -c '"event":"action_attempted"' "$runlog_path" 2>/dev/null || true)
attempts="${attempts:-0}"
qdepth=$(jq -s -r 'first(.[] | select(.event=="run_started_queue") | .queue_depth_at_start // 0) // 0' "$runlog_path" 2>/dev/null || echo 0)
if [[ "$attempts" -eq 0 && "$qdepth" -gt 0 ]]; then
    echo "ERROR: post-batch-summary refusing — queue_depth_at_start=$qdepth but action_attempted=0; this is the Failure 1 shape (B1-only run with no B2-B5 work). Slack summary suppressed." >&2
    exit 7
fi

# --- Refusal gate 3: browser evidence audit --------------------------------
# The append-time runlog gates can be bypassed if an agent rewrites the JSONL
# directly and reruns this poster. Re-derive the decision profile set from the
# runlog and cross-check it against actual browser profile anchors in the
# session log. This catches the 2026-05-04 failure where one profile/Spotify
# browse was mutated into "Escalated: 50".
AUDIT_SCRIPT="$SCRIPT_DIR/browser-evidence-audit.sh"
if [[ ! -r "$AUDIT_SCRIPT" ]]; then
    echo "ERROR: post-batch-summary refusing — browser evidence audit script missing at $AUDIT_SCRIPT. Slack summary suppressed." >&2
    exit 11
fi
set +e
audit_out=$(bash "$AUDIT_SCRIPT" --assert "$RUN_ID" 2>&1)
audit_rc=$?
set -e
if [[ "$audit_rc" -ne 0 ]]; then
    echo "ERROR: post-batch-summary refusing — browser evidence audit failed. Slack summary suppressed." >&2
    printf '%s\n' "$audit_out" >&2
    exit 11
fi

# --- Compose --------------------------------------------------------------
# render-slack-summary.sh emits "<parent>\n===THREAD===\n<thread>". Split
# on the literal sentinel.
rendered=$(bash "$RENDER_SCRIPT" "$RUN_ID")
if ! grep -q '^===THREAD===$' <<<"$rendered"; then
    echo "ERROR: render-slack-summary output lacks ===THREAD=== sentinel; cannot split parent/thread." >&2
    echo "----- rendered output -----" >&2
    printf '%s\n' "$rendered" >&2
    exit 10
fi

parent_text=$(awk 'BEGIN{p=1} /^===THREAD===$/{p=0; next} p{print}' <<<"$rendered")
thread_text=$(awk 'BEGIN{p=0} /^===THREAD===$/{p=1; next} p{print}' <<<"$rendered")

# Strip trailing blank lines from parent (the sentinel typically has a
# blank line above it in the renderer template).
parent_text="$(printf '%s' "$parent_text" | sed -e :a -e '/^$/{$d;N;ba' -e '}')"

# --- Choose channel -------------------------------------------------------
# If the runlog says dryRun: true, route to the dry-run channel — the only
# place the agent should ever post during a dry-run. Otherwise the prod
# channel.
dry_run_flag=$(jq -s -r 'first(.[] | select(.event == "run_finished") | .dryRun // false) // false' "$runlog_path" 2>/dev/null || echo false)
if [[ "$dry_run_flag" == "true" ]]; then
    if [[ -z "${OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID:-}" ]]; then
        echo "ERROR: dry-run summary requested but OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID is not set." >&2
        exit 2
    fi
    target_channel="$OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID"
else
    target_channel="${OPS_CREDIT_VERIFICATION_CHANNEL_ID:-C0APB2CMM7C}"
fi

OPS_OPENCLAW_PROFILE="${OPS_OPENCLAW_PROFILE:-main}"
# 2026-04-30: --account is REQUIRED for slack sends. Without it openclaw
# can't determine which account binding owns C0APB2CMM7C and returns
# channel_not_found. Run 20260430-111343-1605a8 surfaced this — the agent's
# escalation said "post-batch-summary.sh failed with channel_not_found via
# CLI after successful run; fallback summary posted manually". The "fallback"
# was a hand-composed [HEARTBEAT-BATCH] summary, which the enforcer plugin
# correctly blocked. Net effect: every batch's Slack summary has been silently
# broken on the canonical path and falling back to escalation.
OPS_OPENCLAW_ACCOUNT="${OPS_OPENCLAW_ACCOUNT:-operations}"

# --- Test/preview mode ----------------------------------------------------
if [[ "$DRY_RUN_CLI" -eq 1 ]]; then
    echo "POST_BATCH_SUMMARY_OK: target=$target_channel (dryRun=$dry_run_flag)"
    echo "----- PARENT -----"
    printf '%s\n' "$parent_text"
    echo "----- THREAD -----"
    printf '%s\n' "$thread_text"
    exit 0
fi

# --- Send via openclaw CLI ------------------------------------------------
# Parent first, capture the message id from --json output, then post the
# thread reply with --reply-to.
if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw CLI not found on PATH; cannot post." >&2
    exit 10
fi

# --- openclaw --json stdout extraction ------------------------------------
# Run 20260504-124537-3fd64c (rc=10): openclaw CLI prepends "Config warnings:
# …" lines to its --json stdout when the intercom + openclaw-gmail plugin
# manifests are missing channelConfigs metadata. Plain `jq` on the whole
# stdout chokes on the prelude, the parent message id can't be extracted,
# the thread reply is refused, and the agent falls back to the gateway
# auto-reply path — which bypasses the gate entirely.
#
# Strip non-JSON prelude before parsing. `awk '/^[[:space:]]*{/{p=1} p'`
# captures from the first JSON-opening line onward, which works whether the
# JSON is single-line or pretty-printed across multiple lines.
extract_openclaw_json() {
    awk '/^[[:space:]]*\{/{p=1} p'
}

# Detect whether stdout had a non-JSON prelude (a "Config warnings:" line is
# the known case). When it does, write a script_warning runlog event so the
# upstream issue is observable from the runlog alone — keeps fix B (manifest
# channelConfigs) honest.
record_openclaw_warning() {
    local resp="$1" stage="$2"
    if printf '%s\n' "$resp" | grep -q '^Config warnings:'; then
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq -n -c --arg rid "$RUN_ID" --arg ts "$now" --arg stage "$stage" \
            '{event:"script_warning", script:"post-batch-summary.sh", stage:$stage, source:"openclaw_cli_config_warnings", run_id:$rid, ts:$ts}' \
            >> "$runlog_path" 2>/dev/null || true
    fi
}

parent_resp=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" message send \
    --account "$OPS_OPENCLAW_ACCOUNT" \
    --channel slack \
    --target "$target_channel" \
    --message "$parent_text" \
    --json 2>&1) || {
    echo "ERROR: openclaw message send (parent) failed:" >&2
    echo "$parent_resp" >&2
    exit 10
}
record_openclaw_warning "$parent_resp" "parent"

# Slack message id (ts) for threading. Different openclaw versions emit
# slightly different JSON shapes — try a few common fields.
parent_msg_id=$(printf '%s\n' "$parent_resp" | extract_openclaw_json | jq -r '.messageId // .ts // .id // .message.ts // .payload.result.messageId // .payload.messageId // .result.messageId // empty' 2>/dev/null || true)
if [[ -z "$parent_msg_id" ]]; then
    echo "ERROR: parent posted but couldn't extract message id/ts from response; refusing to send thread reply without --reply-to. Response was:" >&2
    echo "$parent_resp" >&2
    exit 10
fi

thread_resp_args=(--account "$OPS_OPENCLAW_ACCOUNT" --channel slack --target "$target_channel" --message "$thread_text")
thread_resp_args+=(--reply-to "$parent_msg_id")
thread_resp=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" message send "${thread_resp_args[@]}" --json 2>&1) || {
    echo "ERROR: openclaw message send (thread) failed:" >&2
    echo "$thread_resp" >&2
    exit 10
}
record_openclaw_warning "$thread_resp" "thread"

# Direct success marker for lockfile.sh's R4-3 renderer-missing detector.
# The session-log heuristic was written when the canonical path went
# through the agent's MCP message tool; it now goes through the openclaw
# CLI from a bash subshell and leaves no toolCall to find — every healthy
# run looked like a bypass. This event is the unambiguous signal that the
# canonical path completed both the parent and thread sends. Fail-OPEN:
# both Slack sends already succeeded, so a runlog write failure must not
# turn this into a non-zero exit.
_pbs_done_now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq -n -c \
    --arg rid "$RUN_ID" \
    --arg ts "$_pbs_done_now" \
    --arg pmid "$parent_msg_id" \
    --arg ch "$target_channel" \
    --argjson dr "$dry_run_flag" \
    '{event:"summary_posted_canonical", script:"post-batch-summary.sh",
      run_id:$rid, ts:$ts, parent_msg_id:$pmid, channel:$ch, dry_run:$dr}' \
    >> "$runlog_path" 2>/dev/null || true

echo "POST_BATCH_SUMMARY_OK: parent=$parent_msg_id channel=$target_channel"
exit 0

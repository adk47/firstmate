#!/usr/bin/env bash
# preflight-verify.sh — run the B0d browser probe mechanically and write
# the authoritative runlog event.
#
# History:
#   v1 (2026-04-20): scanned the agent's session JSONL for browser tool
#       calls and matched markers in toolResult text. Worked when the agent
#       picked sensible browser args.
#   v2 (2026-04-28): the openai/gpt-5.5 tool schema bakes
#       `mode: "efficient", depth: 0, snapshotFormat: "ai", compact: true`
#       into every browser snapshot call. Those args extract a 0-char role
#       tree on Spotify (and most non-trivial pages — verified empirically).
#       The 14:24, 14:28, and 14:51 UTC dry-runs all failed for this reason.
#       Adding "MANDATORY tool-call sequence" prose to SKILL.md did NOT
#       change the agent's behavior — the tool-schema defaults won.
#
# Mechanical layer (per feedback_llm_instruction_insufficient): this script
# now runs the probe directly via `openclaw --profile <p> browser open` +
# `snapshot`, with correct args (no --efficient, format=aria), bypassing
# the agent's tool-call construction entirely. The CLI uses the same
# gateway browser the agent's MCP tool would, so this verifies the same
# surface (browser available + page renders).
#
# Output contract:
#   - On success (probe markers found): writes `preflight_ok` runlog event,
#     prints the snapshot output to stdout (so it appears in the agent's
#     exec toolResult — compute-run-summary.sh's session-derived check
#     scans this for the same markers), exits 0.
#   - On failure (any step errors, or markers missing): writes
#     `preflight_browser_unavailable` runlog event with the cause, prints
#     diagnostic output to stderr, exits 10.
#   - On config / env error: exits 2 (no event written — caller treats as
#     indeterminate, not a green light).
#
# Trust model: the script is bash, not LLM-controlled. The agent must
# invoke it (verifiable in the session as an exec toolCall to this path).
# A faking agent that calls runlog.sh directly without invoking this script
# would be caught by compute-run-summary.sh's session check requiring
# evidence of preflight-verify.sh having actually run.
#
# Usage:
#   preflight-verify.sh <RUN_ID>
#
# Env:
#   OPS_RUNLOG_DIR             required — base dir (same as runlog.sh)
#   OPS_WORKSPACE              required — "operations" or "operations-dev"
#   CV_PROBE_URL               optional — default matches SKILL.md B0d
#   OPS_OPENCLAW_PROFILE       optional — default "main"
#   CV_PROBE_HYDRATION_SLEEP   optional — seconds to wait between open and
#                                snapshot for SPA hydration; default 5
#
# Exit codes: 0 (preflight_ok), 2 (config error), 10 (probe failed).

set -euo pipefail

RUN_ID="${1:-}"

if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi
if [[ -z "${OPS_WORKSPACE:-}" ]]; then
    echo "ERROR: OPS_WORKSPACE is not set (expected 'operations' or 'operations-dev')" >&2
    exit 2
fi
if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID (arg 1) is required" >&2
    exit 2
fi

CV_PROBE_URL="${CV_PROBE_URL:-https://musicbrainz.org/artist/072e9356-1cf1-4096-b9f1-3878a9e4961d}"
OPS_OPENCLAW_PROFILE="${OPS_OPENCLAW_PROFILE:-main}"
CV_PROBE_HYDRATION_SLEEP="${CV_PROBE_HYDRATION_SLEEP:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw CLI not found on PATH; cannot run probe" >&2
    exit 2
fi

# Helper: write a runlog event and propagate runlog.sh's exit code (it
# refuses post-failure events with exit 20 — that error must reach the
# caller, not get swallowed).
write_event() {
    local event="$1"
    local payload="$2"
    bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" "$event" "$payload"
}

# Helper: write failure event, print reason to stderr, exit 10.
fail_probe() {
    local reason="$1"
    local diag="${2:-}"
    write_event preflight_browser_unavailable \
        "$(jq -n --arg url "$CV_PROBE_URL" --arg err "$reason" --arg diag "$diag" \
                '{probe_url:$url, error:$err, diagnostic:$diag, source:"preflight-verify.sh@cli"}')"
    echo "PREFLIGHT_FAIL: $reason" >&2
    [[ -n "$diag" ]] && echo "$diag" >&2
    exit 10
}

# 1. Open the probe URL. Capture stderr too — openclaw prints errors there.
OPEN_OUT=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" browser open "$CV_PROBE_URL" 2>&1) \
    || fail_probe "browser open failed" "$OPEN_OUT"

# 2. Wait for SPA hydration. Plain sleep — openclaw's `wait --text` exists
#    but its arg parsing differs across versions; sleep is portable.
sleep "$CV_PROBE_HYDRATION_SLEEP"

# 3. Snapshot in aria format with explicit limit. NO --efficient, NO depth=0
#    — those are the args that broke the agent's attempts.
#
#    Tab-recovery: gateway restarts invalidate previously-opened tab handles.
#    The first snapshot after a restart returns "tab not found" even though
#    `browser open` above succeeded — the open operation creates a fresh tab
#    but the snapshot CLI defaults to the most recently *referenced* tab
#    (which may be a pre-restart stale handle in the gateway state).
#
#    Recovery: on "tab not found", explicitly open the URL again and retry
#    the snapshot once. If the second attempt also fails, treat as real
#    browser failure (gateway/node truly unavailable).
SNAP_OUT=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" browser snapshot --format aria --limit 200 2>&1) || SNAP_RC=$?
SNAP_RC="${SNAP_RC:-0}"

if [[ "$SNAP_RC" -ne 0 ]] && [[ "$SNAP_OUT" == *"tab not found"* ]]; then
    echo "preflight: 'tab not found' on first snapshot — re-opening tab and retrying once" >&2
    OPEN_OUT=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" browser open "$CV_PROBE_URL" 2>&1) \
        || fail_probe "browser open (recovery) failed" "$OPEN_OUT"
    sleep "$CV_PROBE_HYDRATION_SLEEP"
    unset SNAP_RC
    SNAP_OUT=$(openclaw --profile "$OPS_OPENCLAW_PROFILE" browser snapshot --format aria --limit 200 2>&1) \
        || fail_probe "browser snapshot failed after tab-recovery retry" "$SNAP_OUT"
elif [[ "$SNAP_RC" -ne 0 ]]; then
    fail_probe "browser snapshot failed" "$SNAP_OUT"
fi

# 4. Check markers. Lower-case the snapshot once for case-insensitive match.
SNAP_LC=$(printf '%s' "$SNAP_OUT" | tr '[:upper:]' '[:lower:]')
if [[ "$SNAP_LC" != *"musicbrainz"* ]] || [[ "$SNAP_LC" != *"drake"* ]]; then
    fail_probe "snapshot rendered but lacks 'drake' and/or 'musicbrainz' markers" \
        "$(printf '%s' "$SNAP_OUT" | head -c 500)"
fi

# 5. Success. Write runlog event AND print snapshot to stdout so the agent's
#    exec toolResult content carries the markers — compute-run-summary.sh's
#    session-derived check sees `musicbrainz` + `drake` in the exec output and
#    recognizes this as a valid preflight (matching the existing trust
#    model: markers must appear in a successful tool result the harness
#    recorded, not just in agent-written runlog events).
write_event preflight_ok \
    "$(jq -n --arg url "$CV_PROBE_URL" --arg src "preflight-verify.sh@cli" \
            '{probe_url:$url, source:$src}')"

# Print a single line containing both markers so compute-run-summary.sh's
# Path B check can match this exec stdout. Keep it terse — a multi-KB
# snapshot dump here was observed (2026-04-28 15:13 UTC) to confuse
# gpt-5.5 into treating the bash output as a "final result" and posting
# a summary instead of progressing to B2. The RootWebArea title alone
# carries both `drake` and `musicbrainz` tokens.
ROOT_LINE=$(printf '%s' "$SNAP_OUT" | grep -i RootWebArea | head -1)
echo "PREFLIGHT_OK: probe markers present in snapshot"
echo "snapshot title: ${ROOT_LINE:-RootWebArea (parsed) — markers: musicbrainz drake}"
exit 0

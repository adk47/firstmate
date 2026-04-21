#!/usr/bin/env bash
# preflight-verify.sh — derive the B0d preflight outcome from the active
# openclaw session JSONL and write the authoritative runlog event.
#
# SKILL.md B0d used to let the agent hand-write `preflight_ok` directly after
# its browser attempt. That opened two failure classes:
#   1. Agent substitutes web_fetch for the browser probe and writes
#      preflight_ok anyway (13:26 UTC 2026-04-20 incident b8b0e5).
#   2. Agent skips the probe entirely and writes preflight_ok anyway.
#
# This helper replaces that step. It runs the same `probe_opened &&
# probe_rendered` derivation compute-run-summary.sh uses at B6, so the result
# is consistent with the post-hoc ungrounded invariant — but catches the
# failure BEFORE any credit-touching work starts, not after.
#
# Usage:
#   preflight-verify.sh <RUN_ID>
#
# Env:
#   OPS_RUNLOG_DIR             required — base dir (same as runlog.sh)
#   OPS_WORKSPACE              required — "operations" or "operations-dev";
#                              scopes session-log discovery
#   CV_PROBE_URL               optional — default matches SKILL.md B0d
#   CV_SESSION_LOG_OVERRIDE    optional — absolute path to JSONL; used by tests
#   CV_SESSION_MAX_AGE_MIN     optional — default 10, mirrors session-evidence.sh
#
# Exit codes:
#   0   preflight verified — writes preflight_ok event
#   2   missing env / required arg
#   3   no session log found (B0d cannot verify without one)
#   10  probe failed — writes preflight_browser_unavailable event
#
# Output (stdout): one-line JSON summary with { preflight_ok, probe_opened,
# probe_rendered, reason, session_log }. Callers can inspect this for
# logging; the runlog event is the authoritative record.

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

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_PROBE_URL="${CV_PROBE_URL:-https://open.spotify.com/artist/3TVXtAsR1Inumwj472S9r4}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Session-log discovery — identical idiom to compute-run-summary.sh so the
# two helpers always look at the same file. Workspace-scoped to avoid racing
# with the peer agent on the other profile.
if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
else
    session_log=$(
        find /root/.openclaw-main/agents /root/.openclaw-dev/agents \
            -maxdepth 4 -type f -name "*.jsonl" \
            -path "*/agents/${OPS_WORKSPACE}/sessions/*" \
            -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
fi

if [[ -z "$session_log" ]] || [[ ! -f "$session_log" ]]; then
    echo "ERROR: no active session log found (workspace=${OPS_WORKSPACE}, mtime <${CV_SESSION_MAX_AGE_MIN}m)" >&2
    exit 3
fi

# Derive probe_opened and probe_rendered separately — matches the semantics
# in compute-run-summary.sh lines 194-212. The openclaw browser tool emits
# multiple calls per page load, so targeting the probe URL and rendering the
# markers can appear on different calls; requiring both ensures the actual
# page was fetched.
result=$(jq -R -n \
    --arg probe "$CV_PROBE_URL" '
    [inputs | fromjson? // empty | select(type == "object")] as $lines
    |
    # Walk lines in order, recording each toolResult against the most recent
    # preceding toolCall with the same id (same approach as compute-run-
    # summary.sh — openclaw reuses toolCallId across turns).
    (reduce ($lines[]) as $line
        ({calls: {}, pairs: []};
         ($line.message?.content // []) as $contents
         | (reduce ($contents[] | select(.type == "toolCall")) as $tc
              (.; .calls[$tc.id] = {name: $tc.name, args: $tc.arguments}))
         | if ($line.message?.role == "toolResult") then
               (.calls[$line.message.toolCallId] // null) as $call
               | if $call != null then
                     .pairs += [{
                         name: $call.name,
                         url: ($call.args?.url // ""),
                         is_error: ($line.message.isError // false),
                         text: (($line.message.content // []) | map(.text // "") | join("\n"))
                     }]
                 else . end
           else . end
        )
    ).pairs as $pairs
    |
    # probe_opened: ≥1 successful browser call targeting the probe URL
    # (trailing slash and query-string variants tolerated).
    (
        [ $pairs[]
          | select(.name == "browser")
          | select((.url == $probe)
                   or (.url == ($probe + "/"))
                   or (.url | startswith($probe + "?")))
          | select(.is_error | not)
        ] | length > 0
    ) as $probe_opened
    |
    # probe_rendered: ≥1 successful browser toolResult whose text contains
    # BOTH "spotify" and "drake" (case-insensitive).
    (
        [ $pairs[]
          | select(.name == "browser")
          | select(.is_error | not)
          | select((.text | ascii_downcase) | (contains("spotify") and contains("drake")))
        ] | length > 0
    ) as $probe_rendered
    |
    {probe_opened: $probe_opened, probe_rendered: $probe_rendered,
     preflight_ok: ($probe_opened and $probe_rendered)}
' "$session_log")

PREFLIGHT_OK=$(echo "$result" | jq -r '.preflight_ok')
PROBE_OPENED=$(echo "$result" | jq -r '.probe_opened')
PROBE_RENDERED=$(echo "$result" | jq -r '.probe_rendered')

if [[ "$PREFLIGHT_OK" == "true" ]]; then
    bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" preflight_ok \
        "$(jq -n --arg url "$CV_PROBE_URL" --arg log "$session_log" \
                '{probe_url:$url, session_log:$log}')"
    jq -n -c --argjson r "$result" --arg log "$session_log" \
        '$r + {session_log:$log, reason:"probe opened and rendered markers"}'
    exit 0
fi

# Compose a short, machine-readable reason for the failure event.
if [[ "$PROBE_OPENED" != "true" && "$PROBE_RENDERED" != "true" ]]; then
    reason="no successful browser probe of the Drake URL in this session"
elif [[ "$PROBE_OPENED" != "true" ]]; then
    reason="browser rendered drake+spotify markers, but none of the opens targeted the probe URL"
else
    reason="browser opened the probe URL, but rendered text lacks 'drake' and/or 'spotify' markers (possible Cloudflare challenge)"
fi

bash "$SCRIPT_DIR/runlog.sh" event "$RUN_ID" preflight_browser_unavailable \
    "$(jq -n --arg url "$CV_PROBE_URL" --arg err "$reason" --arg log "$session_log" \
            '{probe_url:$url, error:$err, session_log:$log}')"

jq -n -c --argjson r "$result" --arg log "$session_log" --arg reason "$reason" \
    '$r + {session_log:$log, reason:$reason}'
exit 10

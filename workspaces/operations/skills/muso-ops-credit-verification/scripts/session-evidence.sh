#!/usr/bin/env bash
# session-evidence.sh — emit a JSON evidence block derived from the active
# openclaw session's actual browser tool calls. Used by credit-verification
# escalation templates so the agent cannot cite Tier 1 URLs it never loaded.
#
# Mirrors the session-log discovery + jq pipeline in muso-admin-api.sh's
# credit_approve_gate, but outputs evidence instead of enforcing a threshold.
#
# Output shape (always valid JSON; stable for template embedding):
#   {
#     "browser_loads": [{"url": "...", "host": "...", "ok": true}, ...],
#     "browser_errors": [{"url": "...", "host": "...", "ok": false, "reason": "..."}, ...],
#     "count_ok": N,
#     "count_err": M,
#     "session_log": "/path/..."  // or null if none found
#   }
#
# `browser_loads` is deduped by URL; each URL appears at most once.
# `ok` means: toolResult was not flagged isError AND had non-empty text content.
# The helper does NOT interpret content — Cloudflare challenges that return a
# benign 200 will count as "ok". Semantic quality is the agent's responsibility
# when composing the escalation body; this helper only prevents citing URLs
# that were never actually attempted.
#
# Env:
#   CV_SESSION_MAX_AGE_MIN   optional — default 10. Same semantics as the
#                            approve-gate's window. Keep the two in lock-step.
#   CV_SESSION_LOG_OVERRIDE  optional — absolute path to a specific JSONL to
#                            read instead of running find. Used by bats tests
#                            and any manual-debug workflow.
#
# Exit codes: 0 always (this is a read-only reporter; failures emit an empty
# block rather than surfacing an error, because a missing session log is a
# legitimate state the agent needs to act on — "no evidence" is evidence.)

set -euo pipefail

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"

emit_empty() {
    # Printable to be pasted verbatim into Slack fenced blocks.
    printf '{"browser_loads":[],"browser_errors":[],"count_ok":0,"count_err":0,"session_log":null}\n'
    exit 0
}

if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
else
    # Portable GNU/BSD mtime discovery — same idiom used by the approve-gate.
    session_log=$(
        find /root/.openclaw-main/agents /root/.openclaw-dev/agents \
            -maxdepth 3 -type f -name "*.jsonl" -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
fi

if [[ -z "$session_log" ]] || [[ ! -f "$session_log" ]]; then
    emit_empty
fi

# Parse JSONL: build toolCall index, pair with toolResult, filter to browser.
# Treat toolResult as "ok" when isError is not true AND content text is
# non-empty. Everything else is an error record with the best-guess reason.
jq -R -n --arg log_path "$session_log" '
    [inputs | fromjson? // empty | select(type == "object")] as $lines
    |
    # toolCallId → {name, url}
    (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
        ({}; . + {($tc.id): {name: $tc.name, url: ($tc.arguments.url // "")}})
    ) as $calls
    |
    # Pair each toolResult with its originating toolCall; filter to browser only.
    [
        $lines[]
        | .message | select(.role == "toolResult")
        | . as $tr
        | ($calls[$tr.toolCallId] // null) as $call
        | select($call != null and $call.name == "browser")
        | ($call.url // "") as $url
        | ($url | capture("^https?://(?:www\\.)?(?<host>[^/]+)")? | .host // null) as $host
        | (($tr.isError // false) | not) as $not_err
        | (($tr.content // []) | map(.text // "") | join(" ") | length > 0) as $has_text
        | ($not_err and $has_text) as $ok
        | if $ok then
            {url: $url, host: $host, ok: true}
          else
            {url: $url, host: $host, ok: false,
             reason: (
                if ($tr.isError // false) then "toolResult.isError=true"
                elif (($tr.content // []) | length == 0) then "no content returned"
                else "empty content text"
                end)}
          end
    ] as $records
    |
    {
        browser_loads: ($records | map(select(.ok == true)) | unique_by(.url)),
        browser_errors: ($records | map(select(.ok == false))),
        count_ok: ($records | map(select(.ok == true)) | map(.url) | unique | length),
        count_err: ($records | map(select(.ok == false)) | length),
        session_log: $log_path
    }
' "$session_log"

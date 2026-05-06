#!/usr/bin/env bash
# session-evidence.sh — read the active openclaw session log to either:
#   (default)              emit a JSON evidence block of browser loads, or
#   --check-tier1-webfetch exit 1 + stderr list if any web_fetch call in the
#                          session targeted a Tier-1 host (contamination check).
#
# R3-3 extension: both modes honor $CV_SESSION_RUN_STARTED_TS. When set, only
# session-log lines with .timestamp >= run_started_ts are considered. This
# scopes evidence (and contamination checks) to the current batch run, so past
# web_fetch calls or past stale browser loads can't taint a new run. Channel-
# keyed openclaw sessions persist across runs; this filter removes the
# cross-contamination vector at the gate layer. When unset, scan is unbounded
# by time (backward-compatible with ad-hoc / single-run use).
#
# Used by:
#   - credit-verification wrappers (batch-verify-profile.sh pre-flight)
#   - muso-ops-credit-verification SKILL.md B0d.5 (session hygiene gate)
#   - escalation templates (as evidence for Slack posts)
#
# Output shape (evidence mode, always valid JSON):
#   {
#     "browser_loads": [{"url": "...", "host": "...", "ok": true}, ...],
#     "browser_errors": [{"url": "...", "host": "...", "ok": false, "reason": "..."}, ...],
#     "count_ok": N,
#     "count_err": M,
#     "session_log": "/path/..."  // or null if none found
#   }
#
# Exit codes:
#   0   evidence mode: always (missing session log emits empty block, never errors).
#   0/1 tier1 mode: 0 = clean session, 1 = Tier-1 web_fetch detected.
#   2   unknown argument.
#
# Env:
#   CV_SESSION_MAX_AGE_MIN      default 10; matches enforce_credit_approve_gate.
#   CV_SESSION_LOG_OVERRIDE     absolute path for bats / manual-debug.
#   CV_SESSION_RUN_STARTED_TS   ISO-8601 timestamp; filter lines with .timestamp >= this.
#   CV_TIER1_HOSTS              regex alternation; kept in lockstep with
#                               muso-admin-api.sh:378 — single source of truth is
#                               muso-admin-api.sh, this is a consumer default.

set -euo pipefail

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
# Same Tier-1 list as enforce_credit_approve_gate. When adding/removing, update
# both places OR set CV_TIER1_HOSTS in the environment for both callers.
CV_TIER1_HOSTS="${CV_TIER1_HOSTS:-music\\.apple\\.com|musicbrainz\\.org|discogs\\.com|allmusic\\.com}"

MODE="evidence"
for arg in "$@"; do
    case "$arg" in
        --check-tier1-webfetch) MODE="tier1_check" ;;
        -h|--help)
            cat <<EOF
Usage: session-evidence.sh [--check-tier1-webfetch]

  (no args)               Emit JSON block of browser loads and errors.
  --check-tier1-webfetch  Exit 1 + stderr listing if any web_fetch in the
                          session targeted a Tier-1 host; exit 0 when clean.

Env:
  CV_SESSION_MAX_AGE_MIN=10      mtime window for session-log discovery
  CV_SESSION_LOG_OVERRIDE=<path> override discovery (bats, manual debug)
  CV_SESSION_RUN_STARTED_TS=<ts> filter lines to .timestamp >= this value
EOF
            exit 0
            ;;
        *) echo "session-evidence.sh: unknown arg '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

emit_empty_evidence() {
    printf '{"browser_loads":[],"browser_errors":[],"count_ok":0,"count_err":0,"session_log":null}\n'
}

# Resolve session log path.
if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
else
    # Portable GNU/BSD mtime discovery — same idiom as the approve-gate.
    session_log=$(
        find /root/.openclaw-main/agents \
            -maxdepth 3 -type f -name "*.jsonl" -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
fi

if [[ -z "$session_log" ]] || [[ ! -f "$session_log" ]]; then
    if [[ "$MODE" == "tier1_check" ]]; then
        # No session log = no contamination possible. Caller should decide
        # whether missing-session-log is itself a fatal condition (the gate
        # does treat it as such, but this helper is about contamination only).
        exit 0
    fi
    emit_empty_evidence
    exit 0
fi

run_started_ts="${CV_SESSION_RUN_STARTED_TS:-}"

if [[ "$MODE" == "tier1_check" ]]; then
    # Enumerate distinct Tier-1 hostnames reached via web_fetch. Mirrors the
    # approve-gate's pipeline so drift is structurally bounded — the gate and
    # this helper must agree on what counts as contamination.
    #
    # R4-1: only count web_fetch calls whose toolResult indicates actual data
    # was returned. A plugin-blocked call (muso-credit-verification-enforcer's
    # block-web-fetch-tier1 hook) leaves a toolCall row in the JSONL but the
    # toolResult has details.status=error and no real content. 404/timeout
    # errors get the same pass: no data returned = no contamination. Pair
    # toolCall → toolResult by toolCallId so the gate + this helper agree.
    offending=$(
        jq -R -r -n \
            --arg hosts "$CV_TIER1_HOSTS" \
            --arg run_started_ts "$run_started_ts" '
            ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
            |
            [inputs | fromjson? // empty | select(type == "object")
             | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
            |
            (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
                ({}; . + {($tc.id): {name: $tc.name, url: ($tc.arguments.url // "")}})
            ) as $calls
            |
            [
                $lines[]
                | .message | select(.role == "toolResult")
                | . as $tr
                | ($calls[$tr.toolCallId] // null) as $call
                | select($call != null and $call.name == "web_fetch")
                | ($call.url // "") | select(. != "")
                | capture("^https?://(?:www\\.)?(?<host>[^/]+)")
                | .host
                | select($t1[.] // false)
                | . as $host
                | ($tr.isError // false) as $is_err
                | (($tr.details // {}) | (.status // "")) as $detail_status
                | (($tr.content // []) | map(.text // "") | join(" ") | length > 0) as $has_text
                | select($is_err | not)
                | select($detail_status != "error")
                | select($has_text)
                | $host
            ]
            | unique | .[]
        ' "$session_log" 2>/dev/null
    )
    if [[ -n "$offending" ]]; then
        {
            echo "session-evidence: Tier-1 web_fetch contamination detected in session log ${session_log}:"
            while IFS= read -r host; do
                [[ -n "$host" ]] && echo "  - ${host}"
            done <<< "$offending"
            cat <<'EOF'

Tier 1 pages (Apple Music / MusicBrainz / Discogs / AllMusic)
are JS-rendered — web_fetch returns the raw HTML shell, not the data the
browser tool sees. Every Tier 1 load for credit verification MUST go through
the `browser` tool. Rotate the session (start a new topic) before running
this batch — or, if running under a scoped gate, set CV_SESSION_RUN_STARTED_TS
so only the current run's activity is considered.
EOF
        } >&2
        exit 1
    fi
    exit 0
fi

# Evidence mode: build toolCall index, pair with toolResult, filter to browser,
# and classify each as ok/err. All within the (possibly run-scoped) $lines view.
jq -R -n --arg log_path "$session_log" --arg run_started_ts "$run_started_ts" '
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
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

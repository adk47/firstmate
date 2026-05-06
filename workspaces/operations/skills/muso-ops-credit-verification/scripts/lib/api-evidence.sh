#!/usr/bin/env bash
# api-evidence.sh — shared per-profile evidence helpers for the API-driven
# credit-verification path. Designed to live ALONGSIDE lib/browser-evidence.sh
# during the transition; the gate selects between them via CV_EVIDENCE_MODE.
#
# Why this exists: the browser path has been Cloudflare-broken on search
# engines and intermittently on Tier-1 hosts since 2026-04. We have API
# helpers (musicbrainz-isrc-lookup.sh, spotify-track-lookup.sh,
# discogs-isrc-lookup.sh) that return deterministic JSON with an
# `evidence_excerpt` populated when name_match is true. This library
# counts those helper invocations as evidence sources, plus AllMusic
# browser fallback (no public API), plus eventual web_search citation
# domains once openclaw's local web_search is dropped from the operations
# agent's tool list.
#
# Evidence-source semantics:
#   "API helper hit" = a bash toolCall whose command invoked one of the
#                      known helper scripts AND whose toolResult text
#                      contains the gate's --evidence-excerpt
#                      (case-insensitive). Sources counted by helper name:
#                        musicbrainz-isrc-lookup.sh  -> source="musicbrainz"
#                        spotify-track-lookup.sh     -> source="spotify"
#                        discogs-isrc-lookup.sh      -> source="discogs"
#
#   "AllMusic browser fallback" = a browser toolCall to allmusic.com whose
#                      toolResult text contains the gate's excerpt. Kept as
#                      the long-tail fallback because AllMusic has no
#                      public API.
#
#   "web_search citation" = STUB for now (returns 0). Filled in once the
#                      openclaw operations agent stops carrying the local
#                      web_search tool and OpenRouter native search becomes
#                      the only path. See plan
#                      /Users/nick/.claude/plans/remove-the-browser-partitioned-shell.md
#                      step 1.
#
# Public functions (all stdout-only; no side effects):
#   resolve_run_started_ts                -> ISO8601 of first run_started event, or empty
#   resolve_session_log                   -> path to most recent agent session JSONL, or empty
#   count_profile_api_evidence            -> distinct API helper sources matching excerpt
#   count_profile_allmusic_fallback       -> 1 if AllMusic browser load matches excerpt, else 0
#   count_profile_citation_domains        -> STUB (returns 0 until web_search is the path)
#   count_profile_evidence_sources        -> sum of all three (the value gate compares
#                                            against CV_REQUIRED_LOADS)
#
# All functions take EXCERPT as first arg and (optionally) profile_id as
# second arg. profile_id is currently unused — the excerpt is per-credit and
# already binds the search to one claim. Kept in the signature for future
# per-profile scoping (mirrors browser-evidence.sh).
#
# Env (read-only):
#   OPS_RUNLOG_DIR              required for resolve_run_started_ts
#   CV_SESSION_LOG_OVERRIDE     test override for the session log path
#   CV_SESSION_MAX_AGE_MIN      default 10; how far back to scan agent sessions
#   CV_API_HELPER_PATTERNS      OPTIONAL pipe-separated regex of helper script
#                               basenames. Default catches the three known.
#   CV_FALLBACK_BROWSER_HOSTS_REGEX  OPTIONAL regex for browser fallback hosts.
#                                    Default: ^allmusic\.com$

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"

# Default helper-script basename regex. Matches the canonical names emitted
# by `bash workspaces/operations/skills/muso-ops-credit-verification/scripts/<name>`
# OR by direct invocation like `./<name>`. Pipe-separated; the bash command
# is matched as a substring.
CV_API_HELPER_PATTERNS="${CV_API_HELPER_PATTERNS:-musicbrainz-isrc-lookup\.sh|spotify-track-lookup\.sh|discogs-isrc-lookup\.sh}"

# Browser fallback for hosts with no public API. AllMusic only by default;
# can be widened to other captcha-free non-API hosts via env.
CV_FALLBACK_BROWSER_HOSTS_REGEX="${CV_FALLBACK_BROWSER_HOSTS_REGEX:-^allmusic\\.com$}"

# Resolve the ISO8601 timestamp of the current run's run_started event, or
# empty when no scope is active. Identical to browser-evidence.sh — kept
# duplicated rather than sourced because both libs may be loaded together
# under CV_EVIDENCE_MODE=both and we don't want a sourcing order dependency.
resolve_run_started_ts() {
    [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
    local latest_idx runlog_path
    latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
    [[ -f "$latest_idx" ]] || return 0
    runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
    [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
    jq -s -r 'first(.[] | select(.event == "run_started") | .ts) // empty' "$runlog_path" 2>/dev/null | head -1
}

# Resolve the most-recently-modified agent session JSONL on the main gateway.
# Excludes *.trajectory.jsonl per browser-evidence.sh:91-96. Identical to
# that lib's resolver; duplicated for the same no-source-order reason.
resolve_session_log() {
    if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
        echo "$CV_SESSION_LOG_OVERRIDE"
        return
    fi
    find /root/.openclaw-main/agents \
        -maxdepth 3 -type f -name "*.jsonl" ! -name "*.trajectory.jsonl" \
        -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
    | while IFS= read -r f; do
        mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
        [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
      done \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# Count distinct API-helper sources whose toolResult text contains $1
# (case-insensitive) within the current run window.
#
# A source is identified by the helper script name. Two musicbrainz hits
# count as 1 source. The gate compares the SUM (api + allmusic + citations)
# against CV_REQUIRED_LOADS, so distinct sources is the right semantic.
#
# Args:
#   $1 evidence_excerpt (required, non-empty, case-insensitive matching)
#   $2 profile_id (optional, kept for signature compat; not used today)
# Stdout: a single integer (0 if anything is missing/unresolvable).
count_profile_api_evidence() {
    local excerpt="$1"
    [[ -n "$excerpt" ]] || { echo 0; return 0; }

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -r -n \
        --arg excerpt "$(printf '%s' "$excerpt" | tr '[:upper:]' '[:lower:]')" \
        --arg helper_re "$CV_API_HELPER_PATTERNS" \
        --arg run_started_ts "$run_started_ts" \
    '
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    # Index bash toolCalls by id -> {command, helper_source}.
    # helper_source is one of "musicbrainz", "spotify", "discogs", "" (none).
    # We extract the source name from the matched basename so multiple
    # invocations of the same helper collapse to the same source bucket.
    (reduce ($lines[] | .message.content[]?
             | select(.type == "toolCall" and .name == "bash")) as $tc
        ({};
            ($tc.arguments.command // "" | tostring) as $cmd
            | ($cmd | ascii_downcase) as $cmd_lc
            |
            (if ($cmd_lc | test("musicbrainz-isrc-lookup\\.sh"))
                then "musicbrainz"
             elif ($cmd_lc | test("spotify-track-lookup\\.sh"))
                then "spotify"
             elif ($cmd_lc | test("discogs-isrc-lookup\\.sh"))
                then "discogs"
             else "" end) as $src
            | . + {($tc.id): {command: $cmd, source: $src}}
        )
    ) as $calls
    |
    [
        $lines[]
        | .message | select(.role == "toolResult")
        | . as $tr
        | ($calls[$tr.toolCallId] // null) as $call
        | select($call != null and ($call.source // "") != "")
        | (($tr.isError // false) | not) as $not_err
        | (($tr.content // []) | map(.text // "") | join(" ") | ascii_downcase) as $text_lc
        | select($not_err and ($text_lc | length) > 0)
        | select($text_lc | contains($excerpt))
        | $call.source
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# Count AllMusic (or other CV_FALLBACK_BROWSER_HOSTS_REGEX-matching) browser
# loads in the run window whose toolResult text contains $1. Returns 0 or 1
# (collapses multiple loads of the same host to one source).
#
# Args: same as count_profile_api_evidence.
count_profile_allmusic_fallback() {
    local excerpt="$1"
    [[ -n "$excerpt" ]] || { echo 0; return 0; }

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -r -n \
        --arg excerpt "$(printf '%s' "$excerpt" | tr '[:upper:]' '[:lower:]')" \
        --arg fallback_re "$CV_FALLBACK_BROWSER_HOSTS_REGEX" \
        --arg run_started_ts "$run_started_ts" \
    '
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
        | select($call != null and $call.name == "browser")
        | ($call.url // "") as $url
        | select($url != "")
        | (try ($url | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host) catch "") as $host
        | select($host != "" and ($host | test($fallback_re)))
        | (($tr.isError // false) | not) as $not_err
        | (($tr.content // []) | map(.text // "") | join(" ") | ascii_downcase) as $text_lc
        | select($not_err and ($text_lc | length) > 0)
        | select($text_lc | contains($excerpt))
        | $host
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# STUB. Returns 0 until web_search becomes the path (i.e., until openclaw
# drops its local web_search tool from the operations agent's tool list,
# leaving OpenRouter native search via the openrouter plugin as the only
# route — at which point this should count distinct citation hostnames in
# the assistant message stream that reference the excerpt).
#
# Why a stub: today every web_search call is plugin-blocked by the
# muso-credit-verification-enforcer's redirect-web-search hook, and
# OpenRouter native search is not yet enabled in the operations profile
# config, so there are no citations to count. Counting them as 0 fails
# closed (the gate still requires CV_REQUIRED_LOADS sources from the API
# + AllMusic paths). Lift to real implementation in step 4 of the
# remove-browser plan.
count_profile_citation_domains() {
    local _excerpt="${1:-}"
    local _pid="${2:-}"
    echo 0
}

# Sum of (api_evidence + allmusic_fallback + citation_domains) — the value
# the gate compares against CV_REQUIRED_LOADS. This is the api-mode
# replacement for browser-evidence.sh::count_profile_browser_loads.
#
# Args:
#   $1 evidence_excerpt (required, non-empty)
#   $2 profile_id (optional, signature compat)
count_profile_evidence_sources() {
    local excerpt="$1"
    local pid="${2:-}"
    [[ -n "$excerpt" ]] || { echo 0; return 0; }

    local api_n allmusic_n cite_n
    api_n=$(count_profile_api_evidence "$excerpt" "$pid")
    allmusic_n=$(count_profile_allmusic_fallback "$excerpt" "$pid")
    cite_n=$(count_profile_citation_domains "$excerpt" "$pid")

    # Defensive: each function returns "0" on any failure, so arithmetic is safe.
    echo $(( api_n + allmusic_n + cite_n ))
}

#!/usr/bin/env bash
# browser-evidence.sh — shared per-profile browser-evidence helpers.
#
# Sourced by runlog.sh (verdict + escalation_posted + action_attempted gate)
# and batch-verify-profile.sh (browse-required pre-flight). Single source of
# truth for: where the active session log lives, how to scope to the current
# run window, and what counts as a successful per-profile browser load.
#
# Gate semantics (2026-05-04 refactor — see plan
# /Users/nick/.claude/plans/i-launched-a-test-iridescent-mist.md):
#
#   A browser load counts as per-profile evidence for <profile_id> when ALL:
#     1. the toolCall is `browser` with non-empty url
#     2. the URL host is one of the Tier-1 set (music.apple.com,
#        musicbrainz.org, discogs.com, allmusic.com). Spotify is NOT in
#        this set: the credits dialog is login-gated for headless browsers
#        and returns no role data even with the click sequence applied.
#     3. the toolResult is not isError and has non-empty text
#     4. the response text contains CV_PROFILE_CREDITED_NAME (case-insensitive)
#     5. the response text contains CV_PROFILE_TRACK_TITLE OR at least one
#        token from CV_PROFILE_ROLES (case-insensitive substring)
#
#   The function returns the number of *distinct Tier-1 hosts* that satisfy
#   1-5 for this profile in the current run window. The threshold (consumers
#   compare against CV_REQUIRED_LOADS / 1) is unchanged.
#
# Why this shape: the previous gate accepted "URL contains profile_id" which
# coupled per-profile evidence to muso's own website (muso.ai/profile/<uuid>).
# Both subdomains have strong bot protection; loads 404 or hit captchas. The
# anchor adds zero verification value — it's a structural anti-fabrication
# token. The new rule proves the agent loaded a Tier-1 page that demonstrably
# carries this credit's claim. To pass it the agent has to actually have
# Tier-1 response text mentioning the credited person's name and either the
# track title or the role.
#
# Public functions (all stdout-only; no side effects):
#   resolve_run_started_ts            -> ISO8601 of first run_started event, or empty
#   resolve_session_log               -> path to most recent agent session JSONL, or empty
#   count_profile_browser_loads PID   -> integer count of distinct Tier-1 hosts
#                                        whose response text proves the claim
#                                        for PID in the run window
#   count_profile_tier1_attempts PID  -> integer count of distinct Tier-1 hosts
#                                        the agent ATTEMPTED to load for PID in
#                                        the run window (URL or response text
#                                        mentions credited_name or track_title;
#                                        no claim-match required). Used by the
#                                        tier1_unreachable bypass gate.
#   count_profile_web_searches PID    -> integer count of search-engine browser
#                                        loads (duckduckgo / bing / google) in
#                                        the run window whose `?q=` query
#                                        mentions credited_name or track_title
#                                        for PID. Used by the tier1_unreachable
#                                        bypass gate to enforce SKILL.md step 1b.
#                                        web_search is plugin-blocked in CV
#                                        sessions (it returns nothing useful),
#                                        so the gate counts the sanctioned
#                                        browser-search alternative instead.
#
# Env (read-only):
#   OPS_RUNLOG_DIR              required for resolve_run_started_ts
#   CV_SESSION_LOG_OVERRIDE     test override for the session log path
#   CV_SESSION_MAX_AGE_MIN      default 10; how far back to scan agent sessions
#   CV_PROFILE_CREDITED_NAME    REQUIRED for count to be non-zero (the credited
#                               person's name from profile_group_fetched)
#   CV_PROFILE_TRACK_TITLE      OPTIONAL; either this OR a role token must
#                               appear in the response text
#   CV_PROFILE_ROLES            OPTIONAL; comma-separated role list (e.g.
#                               "songwriter,producer"). Tokens are matched
#                               independently — any single match satisfies
#                               the role-or-track requirement.
#   CV_TIER1_HOSTS_REGEX        OPTIONAL override of the Tier-1 host regex.

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_TIER1_HOSTS_REGEX="${CV_TIER1_HOSTS_REGEX:-^(music\\.apple\\.com|musicbrainz\\.org|discogs\\.com|allmusic\\.com)$}"

resolve_run_started_ts() {
    [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
    local latest_idx runlog_path
    latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
    [[ -f "$latest_idx" ]] || return 0
    runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
    [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
    jq -s -r 'first(.[] | select(.event == "run_started") | .ts) // empty' "$runlog_path" 2>/dev/null | head -1
}

resolve_session_log() {
    if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
        echo "$CV_SESSION_LOG_OVERRIDE"
        return
    fi
    # Exclude *.trajectory.jsonl — those are run-summary metadata files
    # (schemaVersion 1 with .data wrappers) emitted alongside the real
    # message-stream .jsonl. They have a more recent mtime than the message
    # log so the most-recently-modified heuristic picks them by default
    # and the audit/gate find no toolCalls. Verified on hydra 2026-05-04
    # with run 20260504-151755-7964e0.
    find /root/.openclaw-main/agents /root/.openclaw-dev/agents \
        -maxdepth 3 -type f -name "*.jsonl" ! -name "*.trajectory.jsonl" \
        -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
    | while IFS= read -r f; do
        mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
        [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
      done \
    | sort -rn | head -1 | cut -d' ' -f2-
}

# Count distinct Tier-1 hosts in the current run window whose successful
# browser snapshot proves the claim for $1. See file header for the full rule.
#
# Args: $1 profile_id (required, non-empty)
# Stdout: a single integer (0 if anything is missing/unresolvable, including
#         CV_PROFILE_CREDITED_NAME unset — fail closed).
count_profile_browser_loads() {
    local profile_id="$1"
    [[ -n "$profile_id" ]] || { echo 0; return 0; }

    local credited_name="${CV_PROFILE_CREDITED_NAME:-}"
    local track_title="${CV_PROFILE_TRACK_TITLE:-}"
    local roles="${CV_PROFILE_ROLES:-}"

    # Fail closed without the credited name — we can't prove the claim is
    # at the credit context without the person's name to match on.
    if [[ -z "$credited_name" ]]; then
        echo 0
        return 0
    fi

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -n \
        --arg credited_name "$credited_name" \
        --arg track_title "$track_title" \
        --arg roles "$roles" \
        --arg run_started_ts "$run_started_ts" \
        --arg tier1_re "$CV_TIER1_HOSTS_REGEX" \
    '
    ($credited_name | ascii_downcase) as $name_lc
    | ($track_title  | ascii_downcase) as $track_lc
    | [$roles | split(",") | .[] | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(length > 0)] as $role_tokens
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
        | select($call != null and $call.name == "browser")
        | ($call.url // "") as $url
        | select($url != "")
        | (try ($url | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host) catch "") as $host
        | select($host != "" and ($host | test($tier1_re)))
        | (($tr.isError // false) | not) as $not_err
        | (($tr.content // []) | map(.text // "") | join(" ") | ascii_downcase) as $text_lc
        | select($not_err and ($text_lc | length) > 0)
        | select($text_lc | contains($name_lc))
        | select(
            ($track_lc != "" and ($text_lc | contains($track_lc)))
            or ([$role_tokens[] | . as $tok | $text_lc | contains($tok)] | any)
          )
        | $host
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# Count distinct Tier-1 hosts the agent attempted to load for this profile in
# the current run window. "Attempted" means: load is to a Tier-1 host, did
# not error, returned non-empty text, AND the URL OR response text mentions
# the credited_name OR track_title (case-insensitive). Claim-match is NOT
# required — this is the "did the agent actually try?" counter, not the
# "did the page confirm?" counter.
#
# Used by the tier1_unreachable bypass gate to refuse single-host give-ups.
#
# Args: $1 profile_id (required, non-empty)
# Stdout: a single integer (0 if anything is missing/unresolvable, including
#         CV_PROFILE_CREDITED_NAME unset — fail closed).
count_profile_tier1_attempts() {
    local profile_id="$1"
    [[ -n "$profile_id" ]] || { echo 0; return 0; }

    local credited_name="${CV_PROFILE_CREDITED_NAME:-}"
    local track_title="${CV_PROFILE_TRACK_TITLE:-}"

    if [[ -z "$credited_name" ]]; then
        echo 0
        return 0
    fi

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -n \
        --arg credited_name "$credited_name" \
        --arg track_title "$track_title" \
        --arg run_started_ts "$run_started_ts" \
        --arg tier1_re "$CV_TIER1_HOSTS_REGEX" \
    '
    ($credited_name | ascii_downcase) as $name_lc
    | ($track_title  | ascii_downcase) as $track_lc
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
        | select($call != null and $call.name == "browser")
        | ($call.url // "") as $url
        | select($url != "")
        | (try ($url | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host) catch "") as $host
        | select($host != "" and ($host | test($tier1_re)))
        | (($tr.isError // false) | not) as $not_err
        | (($tr.content // []) | map(.text // "") | join(" ") | ascii_downcase) as $text_lc
        | select($not_err and ($text_lc | length) > 0)
        | ($url | ascii_downcase | gsub("%20"; " ") | gsub("\\+"; " ")) as $url_lc
        | select(
            ($url_lc | contains($name_lc))
            or ($text_lc | contains($name_lc))
            or ($track_lc != "" and ($url_lc | contains($track_lc)))
            or ($track_lc != "" and ($text_lc | contains($track_lc)))
          )
        | $host
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# Count sanctioned search-engine browser loads in the current run window whose
# `?q=` query mentions the credited_name or track_title (case-insensitive
# substring). Recognized search-engine hosts:
#   - duckduckgo.com (path: /, query: q)
#   - www.bing.com (path: /search, query: q)
#   - www.google.com (path: /search, query: q)
#
# Why browser, not web_search: the muso-credit-verification-enforcer plugin
# blocks `web_search` in CV sessions because the gateway's DuckDuckGo backend
# is bot-detected and returns no useful results (GH issue #107). The SKILL
# directs agents to load search-engine URLs via the `browser` tool instead.
# This gate counts those sanctioned browser loads to enforce SKILL.md step 1b
# (a corroboration search must be attempted before invoking the bypass).
#
# The toolResult does NOT need to be successful — what matters is that the
# agent attempted the search; if it failed (captcha, network), that is itself
# evidence of an honest tier1_unreachable.
#
# Args: $1 profile_id (required for diagnostics; not used in the count itself
#       since the search isn't profile-scoped — query content is the binding).
# Stdout: a single integer (0 if anything is missing/unresolvable).
count_profile_web_searches() {
    local profile_id="$1"
    [[ -n "$profile_id" ]] || { echo 0; return 0; }

    local credited_name="${CV_PROFILE_CREDITED_NAME:-}"
    local track_title="${CV_PROFILE_TRACK_TITLE:-}"

    if [[ -z "$credited_name" ]]; then
        echo 0
        return 0
    fi

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -n \
        --arg credited_name "$credited_name" \
        --arg track_title "$track_title" \
        --arg run_started_ts "$run_started_ts" \
    '
    ($credited_name | ascii_downcase) as $name_lc
    | ($track_title  | ascii_downcase) as $track_lc
    |
    # Decode a percent-encoded query string. Supports common percent-encoded
    # bytes that appear in real search URLs (space, comma, quotes, slash,
    # plus, ampersand). `+` -> space is a search-URL convention. Unknown
    # %XX sequences are passed through unchanged so the substring match still
    # has a chance to land.
    def url_decode:
        gsub("\\+"; " ")
        | gsub("%20"; " ") | gsub("%2[Cc]"; ",") | gsub("%2[Ff]"; "/")
        | gsub("%26"; "&") | gsub("%3[Dd]"; "=") | gsub("%22"; "\"")
        | gsub("%27"; "'\''");
    # Extract the value of the `q=` parameter from a URL query string.
    # Returns "" if absent. Last-wins if duplicated (matches browser semantics).
    def q_param($url):
        ((try ($url | capture("\\?(?<qs>[^#]*)").qs) catch null) // "") as $qs
        | if $qs == "" then ""
          else (($qs | split("&") | map(select(startswith("q=")) | .[2:]) | last) // "")
          end;
    # Normalize host (lowercase, strip leading www.). Returns "" on parse fail.
    def search_host($url):
        ((try ($url | capture("^https?://(?<h>[^/?#]+)").h) catch null) // "") as $raw
        | ($raw | ascii_downcase | sub("^www\\."; "")) as $h
        | if ($h == "duckduckgo.com" or $h == "bing.com" or $h == "google.com")
          then $h else "" end;
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    [
        $lines[] | .message.content[]?
        | select(.type == "toolCall" and .name == "browser")
        | ((.arguments.url // "") | tostring) as $url
        | select($url | length > 0)
        | select(search_host($url) != "")
        | (q_param($url) | url_decode | ascii_downcase) as $q
        | select($q | length > 0)
        | select(($q | contains($name_lc)) or ($track_lc != "" and ($q | contains($track_lc))))
        | 1
    ] | length
    ' "$session_log" 2>/dev/null || echo 0
}

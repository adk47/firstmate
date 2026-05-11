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
# counts those helper invocations as evidence sources, plus distinct
# citation domains in OpenRouter native web_search responses. Browser is
# not a sanctioned source under api-mode; see the AllMusic-removal note
# below.
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
#   "web_search citation" = an assistant message in the run window
#                      whose content text contains the gate's excerpt
#                      AND carries one or more citation URLs (either
#                      inline `https://...` references or a structured
#                      `citations[]` array). Each distinct hostname
#                      counts as 1 source. Hostnames lowercased and
#                      `www.` stripped to dedupe.
#
#   AllMusic browser fallback was removed 2026-05-07 — AllMusic was
#   observed offline ("being updated") during the cutover test, and we
#   pivoted to native web_search exclusively for non-API evidence.
#
# Public functions (all stdout-only; no side effects):
#   resolve_run_started_ts                -> ISO8601 of first run_started event, or empty
#   resolve_session_log                   -> path to most recent agent session JSONL, or empty
#   count_profile_api_evidence            -> distinct API helper sources matching excerpt
#   count_profile_citation_domains        -> distinct citation hostnames in run-window assistant messages whose text contains EXCERPT
#   count_profile_evidence_sources        -> sum of api_evidence + citation_domains (the
#                                            value gate compares against CV_REQUIRED_LOADS)
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

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"

# Substring matching across the two evidence streams (helper JSON, assistant
# prose) uses a `cv_normalize` jq function defined inline in each query
# below. Both the agent-supplied excerpt and the haystack are normalized:
#   - lowercased
#   - en-dash (U+2013) / em-dash (U+2014) / ascii hyphen → single space
#   - runs of whitespace collapsed to one space
#
# Why: helpers emit `<name> – <role>` (en-dash, see musicbrainz-isrc-lookup.sh
# line 280) but the agent's Tier-2 citation prose uses natural language. A
# single --evidence-excerpt like "Bram Fidder mastering" must substring-match
# both the helper text and the prose; without normalization the en-dash form
# never aligns, and the canonical "MB(1) + Tier-2(1) = 2" quorum collapses
# to 1. See PR #263 review.

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
# count as 1 source. The gate compares the SUM (api + citations) against
# CV_REQUIRED_LOADS, so distinct sources is the right semantic.
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
        --arg excerpt_raw "$excerpt" \
        --arg run_started_ts "$run_started_ts" \
    '
    def cv_normalize:
        ascii_downcase
        | gsub("[–—-]"; " ")
        | gsub("\\s+"; " ")
        | sub("^ "; "") | sub(" $"; "");

    ($excerpt_raw | cv_normalize) as $excerpt
    |
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    # Index shell toolCalls by id -> {command, helper_source}.
    # The OpenClaw shell tool is named "exec" in the live runtime; "bash" is
    # accepted too as a defensive alias (some test fixtures used it before
    # the live tool name was confirmed 2026-05-07 from session JSONL).
    # helper_source is one of "musicbrainz", "spotify", "discogs", "" (none).
    # We extract the source name from the matched basename so multiple
    # invocations of the same helper collapse to the same source bucket.
    (reduce ($lines[] | .message.content[]?
             | select(.type == "toolCall" and (.name == "exec" or .name == "bash"))) as $tc
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
        | (($tr.content // []) | map(.text // "") | join(" ") | cv_normalize) as $text
        | select($not_err and ($text | length) > 0)
        | select($text | contains($excerpt))
        | $call.source
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# [removed 2026-05-07] count_profile_allmusic_fallback used to count AllMusic
# browser loads as a corner-case third source. Removed when AllMusic was
# observed offline mid-test.

# Count Tier-1 API helper INVOCATIONS for a given credited_name in the run
# window, regardless of response content. This is the "did the agent
# actually try?" signal — distinct from count_profile_api_evidence, which
# additionally requires the response to contain the excerpt.
#
# Used by the --decision flag --flag-reason no_tier1_match path in
# batch-verify-profile.sh to permit UVN when the agent has demonstrably
# attempted Tier-1 (the helper was called with the credited_name) and
# the response did NOT confirm a match. Without this counter, the only
# evidence-source signal counts only SUCCESSFUL matches, which by
# definition will be 0 for any genuine no_tier1_match credit.
#
# Args:
#   $1 credited_name (required, non-empty)
# Stdout: integer count of distinct Tier-1 helper invocations
#         whose command args include this credited_name (0 if missing).
count_profile_tier1_attempts_for_name() {
    local credited_name="$1"
    [[ -n "$credited_name" ]] || { echo 0; return 0; }

    local session_log run_started_ts
    session_log=$(resolve_session_log)
    run_started_ts=$(resolve_run_started_ts)

    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        echo 0
        return 0
    fi

    jq -R -r -n \
        --arg name_raw "$credited_name" \
        --arg run_started_ts "$run_started_ts" \
    '
    # Lower-case + dash-fold the name so "Pau Romero" matches the literal
    # --credited-name value in the command after we apply the same
    # transform to it. We DO NOT collapse hyphens to spaces on the command
    # itself, because that would destroy the helper script name (the
    # regex needs "musicbrainz-isrc-lookup.sh" intact).
    def normalize_name:
        ascii_downcase
        | gsub("[–—]"; "-")
        | gsub("\\s+"; " ")
        | sub("^ "; "") | sub(" $"; "");

    ($name_raw | normalize_name) as $name
    |
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    [
        $lines[] | .message.content[]?
        | select(.type == "toolCall" and (.name == "exec" or .name == "bash"))
        | (.arguments.command // "" | tostring) as $cmd_raw
        | ($cmd_raw | ascii_downcase) as $cmd_lc
        | select($cmd_lc | test("musicbrainz-isrc-lookup\\.sh|spotify-track-lookup\\.sh|discogs-isrc-lookup\\.sh"))
        | select($cmd_lc | gsub("[–—]"; "-") | contains($name))
        | 1
    ] | length
    ' "$session_log" 2>/dev/null || echo 0
}

# Count distinct citation domains in assistant messages within the run
# window where (a) a citation URL is present in the message content and
# (b) the message text in proximity to that URL contains the excerpt
# (case-insensitive).
#
# Citation extraction handles two shapes that OpenRouter native web search
# emits depending on the upstream model:
#
#   1. Inline URL citations (gpt-5+, gemini): URLs embedded in the
#      assistant text content, often as `[caption](https://...)` or as
#      bare https URLs adjacent to the cited claim.
#   2. Structured citations field (claude-4+ when configured): a
#      top-level `citations: [{url, title, ...}]` array on the message
#      object, OR per-content-block `citations: [...]` on text blocks.
#
# Both shapes are pulled. Hostnames are lowercased and stripped of a
# leading `www.` so `www.allmusic.com` and `allmusic.com` collapse to
# one source.
#
# Excerpt-proximity: we require the excerpt to appear ANYWHERE in the
# assistant message that carries the citation. Per-URL substring scoping
# would be more precise but is hard to express in jq without false
# negatives — the message-level scope is the documented Tier-2 evidence
# rule (see docs/credit-verification/design.md:247-249) and is robust to
# both citation shapes.
#
# Args:
#   $1 evidence_excerpt (required, non-empty, case-insensitive matching)
#   $2 profile_id (optional, signature compat; not used today)
# Stdout: a single integer (distinct citation hostnames; 0 if anything
#         is missing/unresolvable).
count_profile_citation_domains() {
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
        --arg excerpt_raw "$excerpt" \
        --arg run_started_ts "$run_started_ts" \
    '
    # See header comment for the cv_normalize contract — must mirror the
    # definition in count_profile_api_evidence so both streams use identical
    # normalization for the substring check.
    def cv_normalize:
        ascii_downcase
        | gsub("[–—-]"; " ")
        | gsub("\\s+"; " ")
        | sub("^ "; "") | sub(" $"; "");

    # URL extractor: finds bare https URLs and Markdown-link URLs in text.
    # Trailing punctuation is stripped because URLs at end-of-sentence
    # commonly have a trailing comma / period / paren / bracket / quote.
    def extract_urls($text):
        ($text | [scan("https?://[^\\s<>\"\\)\\]]+")] | map(rtrimstr(".") | rtrimstr(",") | rtrimstr(";")));

    # Hostname normalize: lowercase, strip leading www.
    def normhost($url):
        ((try ($url | capture("^https?://(?<h>[^/?#]+)").h) catch null) // "")
        | ascii_downcase | sub("^www\\."; "");

    ($excerpt_raw | cv_normalize) as $excerpt
    |
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    [
        $lines[]
        | .message | select(.role == "assistant")
        | . as $msg
        # Collapse all text content + every "title" / annotation field
        # OpenRouter routes through to a single haystack we can
        # substring-search for the excerpt (after cv_normalize).
        | (
            ([$msg.content[]? | (.text // "")] | join(" "))
            + " "
            + ([$msg.content[]?.citations[]? // empty | (.title // "") + " " + (.url // "")] | join(" "))
            + " "
            + ([$msg.citations[]? // empty | (.title // "") + " " + (.url // "")] | join(" "))
          ) as $hay
        | ($hay | cv_normalize) as $hay_norm
        | select($hay_norm | contains($excerpt))
        |
        # Now collect URLs from all the same shapes.
        (
            ([$msg.content[]? | extract_urls(.text // "") | .[]?])
            + ([$msg.content[]?.citations[]? // empty | .url // empty])
            + ([$msg.citations[]? // empty | .url // empty])
        ) as $urls
        | $urls[]
        | select(length > 0)
        | normhost(.)
        | select(length > 0)
    ] | unique | length
    ' "$session_log" 2>/dev/null || echo 0
}

# Sum of (api_evidence + citation_domains) — the value the gate compares
# against CV_REQUIRED_LOADS. This is the api-mode replacement for
# browser-evidence.sh::count_profile_browser_loads.
#
# AllMusic browser fallback was removed 2026-05-07 (see header); under
# api-mode browser is not a sanctioned source. Rollback via
# CV_EVIDENCE_MODE=browser still uses lib/browser-evidence.sh.
#
# Args:
#   $1 evidence_excerpt (required, non-empty)
#   $2 profile_id (optional, signature compat)
count_profile_evidence_sources() {
    local excerpt="$1"
    local pid="${2:-}"
    [[ -n "$excerpt" ]] || { echo 0; return 0; }

    local api_n cite_n
    api_n=$(count_profile_api_evidence "$excerpt" "$pid")
    cite_n=$(count_profile_citation_domains "$excerpt" "$pid")

    # Defensive: each function returns "0" on any failure, so arithmetic is safe.
    echo $(( api_n + cite_n ))
}

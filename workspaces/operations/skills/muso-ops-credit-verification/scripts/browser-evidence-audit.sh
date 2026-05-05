#!/usr/bin/env bash
# browser-evidence-audit.sh — cross-check runlog decisions against actual
# browser activity recorded in the OpenClaw session JSONL, and refuse runs
# whose own runlog math doesn't add up.
#
# This is a read-side trust floor for the May 4, 2026 failure class: the
# agent rewrote runlog JSONL rows into synthetic action/escalation events,
# then reran post-batch-summary.sh. Append-time gates cannot catch history
# rewrites. This audit derives browser coverage from the session log and
# refuses summaries where decision profile_ids exceed browsed profile_ids.
#
# Three runlog-only checks were added 2026-05-04 after run
# 20260504-103236-97741c1 surfaced failure shapes the original anchor check
# could not reach: only 1 of 11 fetched profiles got verdicts (the other 10
# silently disappeared), the 28 verdicts shared byte-identical reason text
# referencing a track unrelated to 27 of them, and run_finished.fetched=50
# did not equal Σ buckets (28). The new checks are:
#
#   - coverage:        every profile_id in profile_group_fetched must have
#                      at least one decision event (verdict / action_attempted
#                      / escalation_posted) with the same profile_id
#   - reconciliation:  run_finished.fetched must equal approved +
#                      verification_needed + escalated + skipped_idempotent +
#                      skipped_cap
#   - cookie-cutter:   no verdict.reason string may be shared by more than
#                      CV_AUDIT_COOKIE_CUTTER_THRESHOLD (default 3) verdicts
#
# Anchor semantics (2026-05-04 refactor): the `browser_anchor_*` fields used
# to count profiles whose URL contained `/profile/<uuid>` (the muso website
# anchor). Per the plan in
# /Users/nick/.claude/plans/i-launched-a-test-iridescent-mist.md the muso
# anchor was dropped — both subdomains have strong bot protection, so the
# anchor failed structurally. The fields keep their names for backward
# compatibility but their semantics switched: a profile is now "anchored"
# when ≥1 Tier-1 browser load (music.apple.com /
# musicbrainz.org / discogs.com / allmusic.com) in the run window has
# response text containing the credited person's name AND either the
# track title or a role token (resolved per profile from
# profile_group_fetched events). Same anti-fabrication property; the agent
# can't synthesize matching response text.
#
# tidal.com was demoted from Tier 1 to Tier 2 on 2026-05-04 — its credit
# pages are less reliably populated than the rest, so it can support but
# not satisfy the Tier-1 quorum.
#
# Usage:
#   browser-evidence-audit.sh [--assert] <RUN_ID>
#
# Env:
#   OPS_RUNLOG_DIR                       required
#   CV_SESSION_LOG_OVERRIDE              optional absolute path for tests/manual debug
#   CV_SESSION_MAX_AGE_MIN               default 10
#   CV_AUDIT_COOKIE_CUTTER_THRESHOLD     default 3
#
# Exit codes:
#   0   audit computed; with --assert, all checks passed
#   1   --assert found a check failure (anchors / coverage / reconciliation /
#       cookie-cutter / decision-without-profile_id)
#   2   missing env/args
#   3   no session log found (only when decisions exist; runlog-only failures
#       are still reported with exit 1)
#   5   runlog not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSERT=0
if [[ "${1:-}" == "--assert" ]]; then
    ASSERT=1
    shift
fi

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
    echo "ERROR: RUN_ID is required" >&2
    exit 2
fi
if [[ -z "${OPS_RUNLOG_DIR:-}" ]]; then
    echo "ERROR: OPS_RUNLOG_DIR is not set" >&2
    exit 2
fi

CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_AUDIT_COOKIE_CUTTER_THRESHOLD="${CV_AUDIT_COOKIE_CUTTER_THRESHOLD:-3}"

day_short="${RUN_ID:0:8}"
day_iso="${day_short:0:4}-${day_short:4:2}-${day_short:6:2}"
runlog_path="${OPS_RUNLOG_DIR}/${day_iso}/${RUN_ID}.jsonl"
if [[ ! -f "$runlog_path" ]]; then
    echo "ERROR: runlog not found: $runlog_path" >&2
    exit 5
fi

run_started_ts=$(jq -s -r 'first(.[] | select(.event == "run_started") | .ts) // empty' "$runlog_path" 2>/dev/null || true)
decision_total=$(jq -s -r '[.[] | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted")] | length' "$runlog_path" 2>/dev/null || echo 0)
decision_events_without_profile_id=$(jq -s -r '[.[] | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted") | select((.profile_id // "") == "")] | length' "$runlog_path" 2>/dev/null || echo 0)
fetched_total=$(jq -s -r '[.[] | select(.event == "profile_group_fetched")] | length' "$runlog_path" 2>/dev/null || echo 0)

# --- Runlog-only checks (no session log required) -------------------------
# These run regardless of whether decisions exist, because the May 4 failure
# included silently-dropped fetched profiles (decisions=0 for those).
runlog_audit=$(jq -s -c \
    --arg run_id "$RUN_ID" \
    --argjson cookie_cutter_threshold "$CV_AUDIT_COOKIE_CUTTER_THRESHOLD" \
    '
    . as $events
    |
    ([ $events[] | select(.event == "profile_group_fetched") | .profile_id // empty | select(. != "") ] | unique) as $fetched_profiles
    |
    ([ $events[]
       | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted")
       | .profile_id // empty
       | select(. != "")
     ] | unique) as $decision_profiles_local
    |
    ($fetched_profiles - $decision_profiles_local) as $uncovered_fetched_profiles
    |
    # last() not first(): compute-run-summary.sh can fire twice per run when
    # the agent re-runs --final after escalation_posted events land. Run
    # 20260504-124537-3fd64c had two run_finished events: first {fetched:50,
    # escalated:0} (premature, fired before escalations were written), second
    # {fetched:50, escalated:50} (correct). first() picked the stale one;
    # last() picks the truth-of-record. The reconciliation gate must read the
    # newest counts.
    (last($events[] | select(.event == "run_finished")) // null) as $rf
    |
    (if $rf == null then null
     else
        ($rf.fetched // 0) as $f
        | (($rf.approved // 0) + ($rf.verification_needed // 0) + ($rf.escalated // 0) + ($rf.skipped_idempotent // 0) + ($rf.skipped_cap // 0)) as $sum
        | {
            fetched: $f,
            approved: ($rf.approved // 0),
            verification_needed: ($rf.verification_needed // 0),
            escalated: ($rf.escalated // 0),
            skipped_idempotent: ($rf.skipped_idempotent // 0),
            skipped_cap: ($rf.skipped_cap // 0),
            sum_buckets: $sum,
            mismatch: ($f - $sum)
          }
     end) as $reconciliation
    |
    # Match append-time runlog gate: verdict + escalation_posted + action_attempted.
    # Narrower scope here would let a direct file rewrite of action_attempted /
    # escalation_posted rows pass the audit silently.
    ([ $events[]
       | select(.event == "verdict" or .event == "escalation_posted" or .event == "action_attempted")
       | {event: .event, reason: (.reason // "")}
       | select(.reason != "")
     ]
     | group_by([.event, .reason])
     | map({event: .[0].event, reason: .[0].reason, count: length})
     | map(select(.count >= $cookie_cutter_threshold))
     | sort_by(-.count)) as $cookie_cutter
    |
    # Announce-required check: when there are any fetched profiles, we expect
    # post-batch-announce.sh to have run and written exactly one batch_announced
    # event. Missing = the agent skipped the in-thread "starting" message
    # entirely (the C.1 UX). Fails closed only when there were fetches AND no
    # announce; empty/dry-runs without fetches do not trigger the check.
    ([ $events[] | select(.event == "batch_announced") ] | length) as $announce_count
    |
    {
        fetched_profiles: $fetched_profiles,
        fetched_profile_count: ($fetched_profiles | length),
        uncovered_fetched_profiles: $uncovered_fetched_profiles,
        uncovered_fetched_profile_count: ($uncovered_fetched_profiles | length),
        reconciliation: $reconciliation,
        cookie_cutter_reasons: $cookie_cutter,
        cookie_cutter_count: ($cookie_cutter | length),
        cookie_cutter_threshold: $cookie_cutter_threshold,
        announce_count: $announce_count,
        announce_missing: (($fetched_profiles | length) > 0 and $announce_count == 0),
        runlog_ok: (
            ($uncovered_fetched_profiles | length) == 0
            and ($cookie_cutter | length) == 0
            and ($reconciliation == null or $reconciliation.mismatch == 0)
            and (($fetched_profiles | length) == 0 or $announce_count > 0)
        )
    }
    ' "$runlog_path"
)

if [[ "$decision_total" -eq 0 && "$fetched_total" -eq 0 ]]; then
    # No decisions and no fetches — but the runlog can still carry a
    # forged run_finished with non-zero buckets (reconciliation mismatch)
    # or rewritten cookie-cutter event rows. Honor the runlog-only audit
    # result instead of hardcoding ok:true.
    audit_json=$(jq -n -c \
        --arg run_id "$RUN_ID" \
        --arg runlog_path "$runlog_path" \
        --argjson runlog_audit "$runlog_audit" \
        '{
            run_id:$run_id,
            runlog_path:$runlog_path,
            session_log:null,
            run_started_ts:null,
            decision_profiles:[],
            decision_profile_count:0,
            decision_events_without_profile_id:0,
            browser_anchor_profiles:[],
            browser_anchor_profile_count:0,
            tier1_hosts_by_profile:{},
            missing_anchor_profiles:[],
            missing_anchor_profile_count:0,
            fetched_profiles:$runlog_audit.fetched_profiles,
            fetched_profile_count:$runlog_audit.fetched_profile_count,
            uncovered_fetched_profiles:$runlog_audit.uncovered_fetched_profiles,
            uncovered_fetched_profile_count:$runlog_audit.uncovered_fetched_profile_count,
            reconciliation:$runlog_audit.reconciliation,
            cookie_cutter_reasons:$runlog_audit.cookie_cutter_reasons,
            cookie_cutter_count:$runlog_audit.cookie_cutter_count,
            cookie_cutter_threshold:$runlog_audit.cookie_cutter_threshold,
            announce_count:$runlog_audit.announce_count,
            announce_missing:$runlog_audit.announce_missing,
            ok:$runlog_audit.runlog_ok
        }')
    printf '%s\n' "$audit_json"
    if [[ "$ASSERT" -eq 1 ]]; then
        ok=$(jq -r '.ok' <<<"$audit_json")
        if [[ "$ok" != "true" ]]; then
            uncovered=$(jq -r '.uncovered_fetched_profile_count' <<<"$audit_json")
            cookie=$(jq -r '.cookie_cutter_count' <<<"$audit_json")
            rec_mismatch=$(jq -r '(.reconciliation // {}).mismatch // 0' <<<"$audit_json")
            announce_missing=$(jq -r '.announce_missing' <<<"$audit_json")
            echo "ERROR: browser evidence audit failed (empty-run path) — ${uncovered} fetched profile(s) without any decision; ${cookie} cookie-cutter reason group(s) at threshold ≥${CV_AUDIT_COOKIE_CUTTER_THRESHOLD}; reconciliation mismatch=${rec_mismatch}; announce_missing=${announce_missing}" >&2
            exit 1
        fi
    fi
    exit 0
fi

if [[ "$decision_events_without_profile_id" -gt 0 && "$ASSERT" -eq 1 ]]; then
    jq -n -c \
        --arg run_id "$RUN_ID" \
        --arg runlog_path "$runlog_path" \
        --argjson no_pid "$decision_events_without_profile_id" \
        --argjson runlog_audit "$runlog_audit" \
        '{
            run_id:$run_id,
            runlog_path:$runlog_path,
            session_log:null,
            run_started_ts:null,
            decision_profiles:[],
            decision_profile_count:0,
            decision_events_without_profile_id:$no_pid,
            browser_anchor_profiles:[],
            browser_anchor_profile_count:0,
            tier1_hosts_by_profile:{},
            missing_anchor_profiles:[],
            missing_anchor_profile_count:0,
            fetched_profiles:$runlog_audit.fetched_profiles,
            fetched_profile_count:$runlog_audit.fetched_profile_count,
            uncovered_fetched_profiles:$runlog_audit.uncovered_fetched_profiles,
            uncovered_fetched_profile_count:$runlog_audit.uncovered_fetched_profile_count,
            reconciliation:$runlog_audit.reconciliation,
            cookie_cutter_reasons:$runlog_audit.cookie_cutter_reasons,
            cookie_cutter_count:$runlog_audit.cookie_cutter_count,
            cookie_cutter_threshold:$runlog_audit.cookie_cutter_threshold,
            announce_count:$runlog_audit.announce_count,
            announce_missing:$runlog_audit.announce_missing,
            ok:false
        }'
    echo "ERROR: browser evidence audit failed — 0 decision profile(s) lack browser anchors; ${decision_events_without_profile_id} decision event(s) lack profile_id" >&2
    exit 1
fi

if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
    session_log="$CV_SESSION_LOG_OVERRIDE"
else
    # Scope session-log discovery to the workspace this script lives in.
    # Without scoping, a concurrent or stale jsonl in the OTHER tree (ops vs
    # ops-dev) can win the most-recently-modified contest and become the
    # "evidence" for a run that didn't produce it — false-pass / false-fail.
    #
    # Tree detection: prefer CV_AUDIT_INVOKED_FROM (set by the operations-dev
    # delegating wrapper before exec'ing this canonical script — its own
    # SCRIPT_DIR is overwritten by our line above). Fall back to SCRIPT_DIR
    # for direct invocations.
    _cv_origin="${CV_AUDIT_INVOKED_FROM:-$SCRIPT_DIR}"
    case "$_cv_origin" in
        */workspaces/operations-dev/*) session_search_root="/root/.openclaw-dev/agents/operations-dev/sessions" ;;
        */workspaces/operations/*)     session_search_root="/root/.openclaw-main/agents/operations/sessions" ;;
        *) session_search_root="/root/.openclaw-main/agents/operations/sessions" ;;
    esac
    session_log=$(
        find "$session_search_root" \
            -maxdepth 2 -type f -name "*.jsonl" ! -name "*.trajectory.jsonl" \
            -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
fi

if [[ -z "$session_log" || ! -f "$session_log" ]]; then
    echo "ERROR: no session log found for browser evidence audit" >&2
    exit 3
fi

audit_json=$(
    jq -R -c -n \
        --slurpfile runlog "$runlog_path" \
        --arg run_id "$RUN_ID" \
        --arg runlog_path "$runlog_path" \
        --arg session_log "$session_log" \
        --arg run_started_ts "$run_started_ts" \
        --argjson runlog_audit "$runlog_audit" '
        def normhost:
            try (capture("^https?://(?:www\\.)?(?<host>[^/]+)").host) catch "";

        def tier1_host($url):
            ($url | normhost) as $h
            | if ($h == "music.apple.com"
                  or $h == "musicbrainz.org"
                  or $h == "discogs.com"
                  or $h == "allmusic.com") then $h else "" end;

        ($runlog // []) as $events
        |
        ([ $events[]
           | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted")
           | .profile_id // empty
           | select(. != "")
         ] | unique) as $decision_profiles
        |
        ([ $events[]
           | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted")
           | select((.profile_id // "") == "")
         ] | length) as $decision_events_without_profile_id
        |
        # Build claim metadata per profile_id from profile_group_fetched events
        # (latest wins). The anchor check requires this — without claim
        # metadata for a profile, no Tier-1 load can prove the claim.
        (reduce ($events[] | select(.event == "profile_group_fetched") | select((.profile_id // "") != "")) as $e
            ({}; . + {($e.profile_id): {
                credited_name: ($e.credited_name // ""),
                track_title:   ($e.track_title   // ""),
                roles:         ($e.role          // ($e.roles // ""))
            }})
        ) as $profile_meta
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
            | (($tr.isError // false) | not) as $not_err
            | (($tr.content // []) | map(.text // "") | join(" ") | ascii_downcase) as $text_lc
            | select($not_err and ($text_lc | length) > 0)
            | {url:$url, host:($url | normhost), tier1_host:tier1_host($url), text_lc:$text_lc}
            | select(.tier1_host != "")
        ] as $tier1_loads
        |
        # For each Tier-1 load, find every profile whose claim it proves:
        #   text contains credited_name AND (text contains track_title
        #   OR text contains any role token).
        # Same rule as the runlog gate (lib/browser-evidence.sh) — keep them
        # in lockstep.
        [
            $tier1_loads[] as $load
            | ($profile_meta | to_entries[]) as $pm
            | $pm.key as $pid
            | $pm.value as $meta
            | ($meta.credited_name | ascii_downcase) as $name_lc
            | select($name_lc != "" and ($load.text_lc | contains($name_lc)))
            | ($meta.track_title | ascii_downcase) as $track_lc
            | ([$meta.roles | split(",") | .[] | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(length > 0)]) as $role_tokens
            | select(
                ($track_lc != "" and ($load.text_lc | contains($track_lc)))
                or ([$role_tokens[] | . as $tok | $load.text_lc | contains($tok)] | any)
              )
            | {pid: $pid, host: $load.tier1_host}
        ] as $matched
        |
        ($matched
         | group_by(.pid)
         | map({key: .[0].pid, value: ([.[].host] | unique)})
         | from_entries
        ) as $tier1_by_profile
        |
        # Per-profile Tier-1 attempt counts (any successful browser open with
        # attribution: URL or response text mentions credited_name or
        # track_title). Same definition as count_profile_tier1_attempts in
        # lib/browser-evidence.sh — kept inline here for the audit one-shot
        # pass over $lines / $tier1_loads.
        [
            $tier1_loads[] as $load
            | ($profile_meta | to_entries[]) as $pm
            | $pm.key as $pid
            | $pm.value as $meta
            | ($meta.credited_name | ascii_downcase) as $name_lc
            | ($meta.track_title  | ascii_downcase) as $track_lc
            | ($load.url | ascii_downcase | gsub("%20"; " ") | gsub("\\+"; " ")) as $url_lc
            | select($name_lc != "" and (
                ($url_lc | contains($name_lc))
                or ($load.text_lc | contains($name_lc))
                or ($track_lc != "" and ($url_lc | contains($track_lc)))
                or ($track_lc != "" and ($load.text_lc | contains($track_lc)))
              ))
            | {pid: $pid, host: $load.tier1_host}
        ] as $tier1_attempts
        |
        ($tier1_attempts
         | group_by(.pid)
         | map({key: .[0].pid, value: ([.[].host] | unique | length)})
         | from_entries
        ) as $tier1_attempts_by_profile
        |
        # Per-profile sanctioned-search-engine browser-load count. web_search
        # is plugin-blocked in CV sessions (DuckDuckGo backend bot-detected,
        # GH issue #107); the SKILL directs agents to load search-engine URLs
        # via `browser` instead. Recognized hosts: duckduckgo.com / bing.com
        # / google.com (with optional www. prefix). The `?q=` query (URL-
        # decoded) must mention credited_name or track_title.
        # Same semantic definition as count_profile_web_searches in
        # lib/browser-evidence.sh — keep in lockstep.
        [
            $lines[] | .message.content[]?
            | select(.type == "toolCall" and .name == "browser")
            | ((.arguments.url // "") | tostring) as $url
            | select(($url | length) > 0)
            | (((try ($url | capture("^https?://(?<h>[^/?#]+)").h) catch null) // "")
                | ascii_downcase | sub("^www\\."; "")) as $host
            | select($host == "duckduckgo.com" or $host == "bing.com" or $host == "google.com")
            | (((try ($url | capture("\\?(?<qs>[^#]*)").qs) catch null) // "") as $qs
               | if $qs == "" then ""
                 else (($qs | split("&") | map(select(startswith("q=")) | .[2:]) | last) // "")
                 end
              ) as $q_raw
            | ($q_raw
                | gsub("\\+"; " ")
                | gsub("%20"; " ") | gsub("%2[Cc]"; ",") | gsub("%2[Ff]"; "/")
                | gsub("%26"; "&") | gsub("%3[Dd]"; "=") | gsub("%22"; "\"")
                | gsub("%27"; "'\''")
                | ascii_downcase
              ) as $q
            | select(($q | length) > 0)
            | ($profile_meta | to_entries[]) as $pm
            | $pm.value.credited_name as $cn
            | ($cn | ascii_downcase) as $cn_lc
            | $pm.value.track_title as $tt
            | ($tt | ascii_downcase) as $tt_lc
            | select($cn_lc != "")
            | select(($q | contains($cn_lc)) or ($tt_lc != "" and ($q | contains($tt_lc))))
            | $pm.key
        ] as $web_search_pids
        |
        ($web_search_pids
         | group_by(.)
         | map({key: .[0], value: length})
         | from_entries
        ) as $web_searches_by_profile
        |
        # tier1_unreachable bypass parity: a profile whose decisions all
        # carry "tier1_unreachable" in .reason is anchored without needing
        # Tier-1 claim-match — BUT only when the bypass preconditions are
        # actually met (≥2 distinct Tier-1 attempts AND ≥1 web_search call
        # mentioning credited_name or track_title). 2026-05-04 17:44 lesson:
        # bypass label without effort had been a free pass; the gate now
        # mirrors the runlog write-time gate.
        ([ $events[]
           | select(.event == "verdict" or .event == "action_attempted" or .event == "escalation_posted")
           | select((.profile_id // "") != "")
           | {pid:.profile_id, bypassed:(((.reason // "") | contains("tier1_unreachable")))}
         ]
         | group_by(.pid)
         | map({pid: .[0].pid, all_bypassed: (all(.[]; .bypassed))})
         | map(select(.all_bypassed))
         | map(.pid)
         | map(select(
             (($tier1_attempts_by_profile[.] // 0) >= 2)
             and (($web_searches_by_profile[.] // 0) >= 1)
           ))
        ) as $bypass_anchored_profiles
        |
        (($tier1_by_profile | keys) + $bypass_anchored_profiles | unique) as $anchor_profiles
        |
        ($decision_profiles - $anchor_profiles) as $missing_anchor_profiles
        |
        {
            run_id: $run_id,
            runlog_path: $runlog_path,
            session_log: $session_log,
            run_started_ts: ($run_started_ts | if . == "" then null else . end),
            decision_profiles: $decision_profiles,
            decision_profile_count: ($decision_profiles | length),
            decision_events_without_profile_id: $decision_events_without_profile_id,
            browser_anchor_profiles: $anchor_profiles,
            browser_anchor_profile_count: ($anchor_profiles | length),
            tier1_hosts_by_profile: $tier1_by_profile,
            tier1_attempts_by_profile: $tier1_attempts_by_profile,
            web_searches_by_profile: $web_searches_by_profile,
            bypass_anchored_profiles: $bypass_anchored_profiles,
            missing_anchor_profiles: $missing_anchor_profiles,
            missing_anchor_profile_count: ($missing_anchor_profiles | length),
            fetched_profiles: $runlog_audit.fetched_profiles,
            fetched_profile_count: $runlog_audit.fetched_profile_count,
            uncovered_fetched_profiles: $runlog_audit.uncovered_fetched_profiles,
            uncovered_fetched_profile_count: $runlog_audit.uncovered_fetched_profile_count,
            reconciliation: $runlog_audit.reconciliation,
            cookie_cutter_reasons: $runlog_audit.cookie_cutter_reasons,
            cookie_cutter_count: $runlog_audit.cookie_cutter_count,
            cookie_cutter_threshold: $runlog_audit.cookie_cutter_threshold,
            announce_count: $runlog_audit.announce_count,
            announce_missing: $runlog_audit.announce_missing,
            ok: (
                ($missing_anchor_profiles | length) == 0
                and $decision_events_without_profile_id == 0
                and $runlog_audit.runlog_ok
            )
        }
    ' "$session_log"
)

printf '%s\n' "$audit_json"

if [[ "$ASSERT" -eq 1 ]]; then
    ok=$(jq -r '.ok' <<<"$audit_json")
    if [[ "$ok" != "true" ]]; then
        missing=$(jq -r '.missing_anchor_profile_count' <<<"$audit_json")
        no_pid=$(jq -r '.decision_events_without_profile_id' <<<"$audit_json")
        uncovered=$(jq -r '.uncovered_fetched_profile_count' <<<"$audit_json")
        cookie=$(jq -r '.cookie_cutter_count' <<<"$audit_json")
        rec_mismatch=$(jq -r '(.reconciliation // {}).mismatch // 0' <<<"$audit_json")
        announce_missing=$(jq -r '.announce_missing' <<<"$audit_json")
        echo "ERROR: browser evidence audit failed — ${missing} decision profile(s) lack browser anchors; ${no_pid} decision event(s) lack profile_id; ${uncovered} fetched profile(s) without any decision; ${cookie} cookie-cutter reason group(s) at threshold ≥${CV_AUDIT_COOKIE_CUTTER_THRESHOLD}; reconciliation mismatch=${rec_mismatch}; announce_missing=${announce_missing}" >&2
        exit 1
    fi
fi

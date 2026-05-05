#!/usr/bin/env bash
# batch-verify-profile.sh — per-profile evidence pre-flight + decision dispatcher.
#
# Why this exists (R3, 2026-04-23):
#   R1 + R2 made silent failures impossible at the truth-floor layer, but the
#   first clean dry-run (12:57 UTC) still saw the gate block 100% of approves.
#   Root cause: agent loaded artist-level Tier-1 pages for 2 artists and then
#   tried to approve 102 credits across 30 profiles. The gate correctly
#   refused because per-profile evidence was missing for 28 of 30 profiles.
#
#   This wrapper narrows the agent's surface to a single atomic per-profile
#   call: "I have evidence E for profile P, please approve/flag ids I". It
#   pre-flights the exact same evidence check the gate runs, and if the bar
#   isn't met it exits 3 WITH REMEDIATION TEXT telling the agent which pages
#   to load next. Round-tripping through the admin API (and then the gate) is
#   replaced by a local filesystem read — fast, noisy-on-failure, unambiguous.
#
#   The approve path delegates to batch-approve-credits.sh (unchanged). The
#   flag path delegates to batch-flag-credits.sh (UVN isn't gated). The
#   wrapper is additive — it does not weaken the gate, and the gate remains
#   the last line of defense against any path that skips this pre-flight.
#
# Usage:
#   batch-verify-profile.sh \
#       --profile-id <spotify_artist_id_or_stable_key> \
#       --credited-name "<person's name from inbound message>" \
#       --track-title  "<track from inbound message>" \
#       --role         "<role(s), comma-separated, from inbound message>" \
#       --evidence-excerpt "<literal substring, 8-200 chars>" \
#       --ids "<id1>,<id2>,..." \
#       --decision approve|flag \
#       [--reason "<short text, required for --decision flag>"]
#
# Contract:
#   * --requester is REFUSED (autonomous batch only — same policy as the two
#     delegate wrappers).
#   * --credited-name / --track-title / --role are REQUIRED for every decision.
#     They come from the inbound message Step 1 fields (Profile, Track, Roles).
#     The dispatcher uses them to validate the excerpt structurally:
#       approve: excerpt must contain credited_name AND (track_title OR any role token)
#       flag:    excerpt must contain (track_title OR any role token) AND must NOT contain credited_name
#     This proves the claim mechanically — the credited person is at the credit
#     context (approve) or verifiably absent from it (flag, proving the negative).
#   * Both approve AND flag now run: browse-required → structural excerpt rule →
#     quorum (>=2 distinct Tier-1 hosts). Approve also runs the
#     contamination check. Flag was at >=1 quorum until 2026-04-30; raised to
#     >=2 to match approve.
#   * Exit 0 on delegate success. Exit 1 on delegate failure (gate rejection,
#     HTTP error). Exit 2 on argument validation failure. Exit 3 on
#     pre-flight failure (missing evidence OR Tier-1 web_fetch contamination).
#     Exit 5 on missing per-profile browse. Exit 6 on excerpt that doesn't
#     prove the claim (structural rule failed).
#   * Stdout: one compact JSON summary line describing the outcome. Per-HTTP
#     truth lives in .results.jsonl (PR #158 truth-floor); this stdout is a
#     convenience for the caller's own logging.
#   * Stderr: pre-flight failures print actionable remediation; delegate
#     stderr is forwarded verbatim.

set -euo pipefail

# Pre-flight + gate constants — keep in lockstep with enforce_credit_approve_gate
# in muso-admin-api.sh. When changing any of these, update both places.
CV_REQUIRED_LOADS="${CV_REQUIRED_LOADS:-2}"
CV_EVIDENCE_EXCERPT_MIN="${CV_EVIDENCE_EXCERPT_MIN:-8}"
CV_EVIDENCE_EXCERPT_MAX="${CV_EVIDENCE_EXCERPT_MAX:-200}"
CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_TIER1_HOSTS="${CV_TIER1_HOSTS:-music\\.apple\\.com|musicbrainz\\.org|discogs\\.com|allmusic\\.com}"

# Browse-required prerequisite (added 2026-04-30 after run 20260430-130332-c1f8f9
# escalated 500/500 with exactly 1 browser call across the entire run). At
# least 1 successful browser load in the current run window must have a URL
# containing $PROFILE_ID — this forces real per-profile browser activity
# before any per-credit decision can be dispatched. Bypassable for tests via
# CV_REQUIRED_PROFILE_BROWSE=0; default 1.
CV_REQUIRED_PROFILE_BROWSE="${CV_REQUIRED_PROFILE_BROWSE:-1}"

# Delegate scripts. Overridable for tests so they can stub a mock admin-api.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_EVIDENCE_SH="${SESSION_EVIDENCE_SH:-$SCRIPT_DIR/session-evidence.sh}"
BATCH_APPROVE_SH="${BATCH_APPROVE_SH:-$SCRIPT_DIR/batch-approve-credits.sh}"
BATCH_FLAG_SH="${BATCH_FLAG_SH:-$SCRIPT_DIR/batch-flag-credits.sh}"

# Closed-list flag reasons (added 2026-04-30, tightened later same day after
# run 20260430-111343-1605a8 leaked 460 credits). Forces the agent to
# categorize why a UVN flag was applied instead of typing free-form prose.
#
# NO BYPASS REASONS. The earlier draft had `evidence_quorum_failed` and
# `human_review_requested` skip the snapshot-match gate for source-outage
# scenarios. Within minutes of going live the agent used those as a universal
# escape hatch — 460 credits flagged with `evidence_quorum_failed` and exactly
# 1 browser call across the entire run. The "source outages" scenario was
# theoretical; in practice the agent should ESCALATE (existing code path) when
# it can't reach evidence quorum, not silently flag every credit.
#
# All flag reasons now require the same proof-of-grounding rule: the
# --evidence-excerpt must appear verbatim on >=1 Tier-1 browser snapshot in
# the current run window. Same shape as approve (which requires >=2), just
# lighter. Removed bypass reasons entirely so there is no escape from the gate.
FLAG_REASONS_REGEX="^(name_mismatch|popularity_anomaly|no_tier1_match|metadata_inconsistent)$"

# Placeholder-excerpt deny-list (added 2026-04-30 after run 20260430-081740-585500
# flagged 10 credits with --evidence-excerpt "batch conservative review" — a
# decorative string the agent typed because the flag path had no evidence gate).
# Compared case-insensitively after trim. The browser-snapshot match below is
# the real defense; this list catches obvious shapes early so the agent gets a
# clearer error than "0 hosts matched". Token-count / all-lowercase heuristics
# were considered + dropped — false-positive on real artist names like
# "Pau Romero".
PLACEHOLDER_EXCERPTS=(
    "batch conservative review"
    "conservative review"
    "no evidence"
    "n/a"
    "default"
    "tbd"
    "placeholder"
    "unknown"
    "placeholder text"
)

PROFILE_ID=""
CREDITED_NAME=""
TRACK_TITLE=""
ROLE=""
EVIDENCE_EXCERPT=""
IDS_RAW=""
DECISION=""
REASON=""
FLAG_REASON=""

usage() {
    cat >&2 <<EOF
Usage:
  batch-verify-profile.sh \\
      --profile-id <profile_id> \\
      --credited-name "<name>" \\
      --track-title  "<track title>" \\
      --role         "<role[,role2,...]>" \\
      --evidence-excerpt "<literal substring>" \\
      --ids "<id1>,<id2>,..." \\
      --decision approve|flag \\
      [--reason "<short text>"] \\
      [--flag-reason <enum>]

Required for all decisions:
  --profile-id         The profile UUID whose credits are being processed.
  --credited-name      Person's name from the inbound message ("Profile:" field).
                       Used to validate the excerpt structurally.
  --track-title        Track title from the inbound message ("Track:" field).
  --role               Role(s) from the inbound message ("Roles:" field).
                       Comma-separated for multi-role claims.
  --evidence-excerpt   A literal substring (>=${CV_EVIDENCE_EXCERPT_MIN},
                       <=${CV_EVIDENCE_EXCERPT_MAX} chars) that should appear
                       verbatim on a Tier-1 browser snapshot in the current
                       session. Approve and flag both need >=${CV_REQUIRED_LOADS}
                       distinct Tier-1 hosts. The excerpt must also pass the
                       structural rule:
                         approve: contains credited_name AND (track_title OR role)
                         flag:    contains (track_title OR role) AND NOT credited_name
                       (proves the claim is at the credit context for approve,
                        or verifiably absent from it for flag).

  --ids                Comma-separated list of credit-request IDs.
  --decision           'approve' or 'flag'. Both run browse-required, structural
                       excerpt validation, and the >=${CV_REQUIRED_LOADS}-Tier-1 quorum.

Required for --decision flag:
  --reason             Short prose string. Forwarded to stderr for the
                       agent transcript / audit. Not sent to the backend.
  --flag-reason        Closed-list enum. One of:
                         name_mismatch          credited name not on Tier-1
                         popularity_anomaly     listener counts conflict
                         no_tier1_match         neither MB/AllMusic/Discogs match
                         metadata_inconsistent  title/release date conflict
                       No bypass values — every flag must pass browse-required,
                       the structural rule, and the >=${CV_REQUIRED_LOADS}-Tier-1 quorum.

Forbidden:
  --requester          Autonomous-batch only. For human-authorized overrides
                       call muso-admin-api.sh directly (muso-ops-admin/SKILL.md).

Exit codes:
  0   delegate success
  1   delegate failure (gate rejection post-pre-flight, HTTP error, etc.)
  2   argument validation failure
  3   pre-flight failure — evidence quorum not met OR Tier-1 web_fetch in session
  5   pre-flight failure — no per-profile browser load in current run window
  6   pre-flight failure — excerpt does not prove the claim (structural rule)

Stdout (one compact JSON line):
  {"profile_id":"...","decision":"approve|flag","ids":[...],
   "pre_flight":"ok|missing_evidence|web_fetch_tier1|placeholder_excerpt|missing_flag_evidence|missing_profile_browse|excerpt_does_not_prove_claim",
   "delegate_exit":N, "flag_reason":"...", "credited_name":"...", "track_title":"...", "role":"..."}

When pre_flight != "ok", stderr prints actionable remediation text:
which Tier-1 pages to browse next, and the exact retry command.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile-id)        PROFILE_ID="${2:-}";        shift 2 ;;
        --credited-name)     CREDITED_NAME="${2:-}";     shift 2 ;;
        --track-title)       TRACK_TITLE="${2:-}";       shift 2 ;;
        --role)              ROLE="${2:-}";              shift 2 ;;
        --evidence-excerpt)  EVIDENCE_EXCERPT="${2:-}";  shift 2 ;;
        --ids)               IDS_RAW="${2:-}";           shift 2 ;;
        --decision)          DECISION="${2:-}";          shift 2 ;;
        --reason)            REASON="${2:-}";            shift 2 ;;
        --flag-reason)       FLAG_REASON="${2:-}";       shift 2 ;;
        --requester)
            echo "ERROR: --requester is forbidden in batch-verify-profile.sh." >&2
            echo "       Autonomous-batch only. Use muso-admin-api.sh directly for human overrides." >&2
            exit 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

# --- Argument validation (no side effects yet) ---

if [[ -z "$PROFILE_ID" ]]; then
    echo "ERROR: --profile-id is required." >&2
    exit 2
fi
if [[ -z "$EVIDENCE_EXCERPT" ]]; then
    echo "ERROR: --evidence-excerpt is required." >&2
    exit 2
fi
if (( ${#EVIDENCE_EXCERPT} < CV_EVIDENCE_EXCERPT_MIN )); then
    echo "ERROR: --evidence-excerpt must be >=${CV_EVIDENCE_EXCERPT_MIN} chars (got ${#EVIDENCE_EXCERPT})." >&2
    exit 2
fi
if (( ${#EVIDENCE_EXCERPT} > CV_EVIDENCE_EXCERPT_MAX )); then
    echo "ERROR: --evidence-excerpt must be <=${CV_EVIDENCE_EXCERPT_MAX} chars (got ${#EVIDENCE_EXCERPT})." >&2
    exit 2
fi
if [[ -z "$IDS_RAW" ]]; then
    echo "ERROR: --ids is required." >&2
    exit 2
fi
if [[ -z "$DECISION" ]]; then
    echo "ERROR: --decision is required (approve|flag)." >&2
    exit 2
fi
# Claim-metadata args (added PR #233). Validated after the existing args so
# pre-existing test patterns and arg-validation errors (missing profile-id,
# missing evidence-excerpt, length bounds, missing ids/decision) still surface
# their original error rather than being shadowed by the new fields.
if [[ -z "$CREDITED_NAME" ]]; then
    echo "ERROR: --credited-name is required (the person's name from the inbound message 'Profile:' field)." >&2
    exit 2
fi
if [[ -z "$TRACK_TITLE" ]]; then
    echo "ERROR: --track-title is required (the track from the inbound message 'Track:' field)." >&2
    exit 2
fi
if [[ -z "$ROLE" ]]; then
    echo "ERROR: --role is required (role(s) from the inbound message 'Roles:' field; comma-separated for multi-role)." >&2
    exit 2
fi
case "$DECISION" in
    approve|flag) ;;
    *) echo "ERROR: --decision must be 'approve' or 'flag' (got '$DECISION')." >&2; exit 2 ;;
esac
if [[ "$DECISION" == "flag" && -z "$REASON" ]]; then
    echo "ERROR: --reason is required for --decision flag." >&2
    exit 2
fi
if [[ "$DECISION" == "flag" && -z "$FLAG_REASON" ]]; then
    echo "ERROR: --flag-reason is required for --decision flag." >&2
    echo "       Pick one of: name_mismatch, popularity_anomaly, no_tier1_match, metadata_inconsistent." >&2
    echo "       If sources are unreachable or a human asked for the flag, ESCALATE via" >&2
    echo "       the existing escalation path (Step 5) rather than bulk-flagging." >&2
    exit 2
fi
if [[ "$DECISION" == "flag" ]] && ! [[ "$FLAG_REASON" =~ $FLAG_REASONS_REGEX ]]; then
    echo "ERROR: --flag-reason '$FLAG_REASON' is not a valid enum value." >&2
    echo "       Pick one of: name_mismatch, popularity_anomaly, no_tier1_match, metadata_inconsistent." >&2
    echo "       (evidence_quorum_failed / human_review_requested were removed 2026-04-30 after" >&2
    echo "        the run 20260430-111343-1605a8 incident — they're no longer accepted.)" >&2
    exit 2
fi

# --- Placeholder-excerpt deny-list (applies to BOTH approve and flag) ---
# Cheap shape check before any session scan. Catches obvious decorative
# strings the agent might type when it gives up on real evidence gathering.
excerpt_lower="$(printf '%s' "$EVIDENCE_EXCERPT" | tr '[:upper:]' '[:lower:]')"
excerpt_lower_trimmed="${excerpt_lower#"${excerpt_lower%%[![:space:]]*}"}"
excerpt_lower_trimmed="${excerpt_lower_trimmed%"${excerpt_lower_trimmed##*[![:space:]]}"}"
for ph in "${PLACEHOLDER_EXCERPTS[@]}"; do
    if [[ "$excerpt_lower_trimmed" == "$ph" ]]; then
        cat >&2 <<EOF
ERROR: --evidence-excerpt '${EVIDENCE_EXCERPT}' matches the placeholder deny-list.
       Pick a literal substring you actually saw in a Tier-1 browser snapshot
       (artist name as rendered, role string, track title, etc.) — typically
       8-50 chars copied from the page, not a generic descriptor.
EOF
        exit 2
    fi
done

# IDs-as-JSON-array for the summary (uses same trim logic as delegates).
ids_json=$(
    jq -n -c --arg raw "$IDS_RAW" \
        '$raw | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
)

emit_summary() {
    # args: pre_flight delegate_exit(maybe "null")
    # flag_reason is included only on flag decisions; null on approve.
    # credited_name / track_title / role echo back the claim metadata so the
    # caller's logging captures what was being verified.
    local pre_flight="$1" delegate_exit="$2"
    jq -n -c \
        --arg profile_id "$PROFILE_ID" \
        --arg decision "$DECISION" \
        --argjson ids "$ids_json" \
        --arg pre_flight "$pre_flight" \
        --argjson delegate_exit "$delegate_exit" \
        --arg flag_reason "$FLAG_REASON" \
        --arg credited_name "$CREDITED_NAME" \
        --arg track_title "$TRACK_TITLE" \
        --arg role "$ROLE" \
        '{profile_id:$profile_id, decision:$decision, ids:$ids,
          pre_flight:$pre_flight, delegate_exit:$delegate_exit,
          flag_reason: (if $flag_reason == "" then null else $flag_reason end),
          credited_name:$credited_name, track_title:$track_title, role:$role}'
}

# Truth-floor write for pre-flight rejections. When pre-flight fails we
# short-circuit before muso-admin-api.sh runs, so its own truth floor never
# sees the attempt. Write a row here with outcome=rejected_pre_flight so
# compute-run-summary.sh can reconcile pre-flight refusals as a distinct
# category from gate rejections — the agent's failing step (insufficient
# evidence gathering) is distinct from the gate catching it on a later run.
#
# Schema matches write_credit_request_result in muso-admin-api.sh byte-for-
# byte, plus one extra field `pre_flight` carrying the reason. Keep both
# writers in lockstep if schema evolves.
# args: reason ("missing_evidence", "web_fetch_tier1", or "missing_flag_evidence")
write_pre_flight_rejection() {
    local reason="$1"
    # Both approve and flag can now hit pre-flight (flag added 2026-04-30 with
    # the snapshot-match gate). Bypass-reason flags (evidence_quorum_failed,
    # human_review_requested) skip the snapshot scan and never call this
    # function; the row's intended_status reflects the decision.
    case "$DECISION" in
        approve|flag) ;;
        *) return 0 ;;
    esac
    local intended_status="approved"
    [[ "$DECISION" == "flag" ]] && intended_status="user_verification_needed"

    # RUN_ID resolution — same pattern as write_credit_request_result.
    local run_id="${OPS_RUN_ID:-${RUN_ID:-}}"
    if [[ -z "$run_id" && -n "${OPS_RUNLOG_DIR:-}" && -f "${OPS_RUNLOG_DIR}/latest.txt" ]]; then
        local latest_path latest_base
        latest_path=$(cat "${OPS_RUNLOG_DIR}/latest.txt" 2>/dev/null || true)
        if [[ -n "$latest_path" ]]; then
            latest_base=$(basename "$latest_path" .jsonl)
            if [[ "$latest_base" =~ ^[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]]; then
                run_id="$latest_base"
            fi
        fi
    fi

    local today results_path
    today="$(date -u +%Y-%m-%d)"
    results_path="${CV_RESULTS_PATH:-/var/log/openclaw/credit-batch-runs/${today}/${run_id:-unknown}.results.jsonl}"

    local results_dir
    results_dir="$(dirname "$results_path")"
    mkdir -p "$results_dir" 2>/dev/null || {
        echo "WARN: could not create $results_dir; pre-flight rejection line LOST for profile ${PROFILE_ID}" >&2
        return 0
    }

    local ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line=$(jq -n -c \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --argjson request_ids "$ids_json" \
        --arg outcome "rejected_pre_flight" \
        --arg pre_flight "$reason" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg evidence_excerpt "$EVIDENCE_EXCERPT" \
        --arg profile_id "$PROFILE_ID" \
        --arg intended_status "$intended_status" \
        --arg flag_reason "$FLAG_REASON" \
        --arg credited_name "$CREDITED_NAME" \
        --arg track_title "$TRACK_TITLE" \
        --arg role "$ROLE" \
        '{
            ts: $ts,
            run_id: (if $run_id == "" then null else $run_id end),
            method: "PUT",
            path: "/admin/credit-requests",
            request_ids: $request_ids,
            intended_status: $intended_status,
            outcome: $outcome,
            http_status: null,
            error: null,
            pre_flight: $pre_flight,
            evidence_excerpt: $evidence_excerpt,
            profile_id: $profile_id,
            credited_name: (if $credited_name == "" then null else $credited_name end),
            track_title: (if $track_title == "" then null else $track_title end),
            role: (if $role == "" then null else $role end),
            flag_reason: (if $flag_reason == "" then null else $flag_reason end),
            requester: (if $requester == "" then null else $requester end)
         }' 2>/dev/null) || {
        echo "WARN: jq failed to build pre-flight rejection line for profile ${PROFILE_ID}" >&2
        return 0
    }
    printf '%s\n' "$line" >> "$results_path" 2>/dev/null || {
        echo "WARN: could not append to $results_path; pre-flight line LOST for profile ${PROFILE_ID}" >&2
    }
}

# --- Shared helpers used by both flag-evidence + approve paths ---
# resolve_run_started_ts, resolve_session_log, and count_profile_browser_loads
# are sourced from lib/browser-evidence.sh — single source of truth. The
# library's gate logic must match the runlog.sh write-time gate exactly,
# which is why both call into the same helpers.
# shellcheck source=lib/browser-evidence.sh
. "$SCRIPT_DIR/lib/browser-evidence.sh"

# --- Structural excerpt validator (claim-proving rule) ---
# This is a pure check on EVIDENCE_EXCERPT vs the claim metadata
# (CREDITED_NAME / TRACK_TITLE / ROLE). It does NOT scan the session log —
# that's the quorum check's job. The structural rule is the layer that proves
# the excerpt is meaningful (proves the claim for approve, or proves the
# verifiable absence for flag) before we even ask "did this excerpt appear on
# enough Tier-1 hosts?".
#
# Approve rule:
#   excerpt MUST contain credited_name (case-insensitive substring)
#   AND MUST contain at least one of (track_title, any role token)
#
# Flag rule (inverted — proves the negative):
#   excerpt MUST contain at least one of (track_title, any role token)
#   AND MUST NOT contain credited_name
#   (If the credited person IS on the page, flag is wrong — agent should
#    approve or escalate instead.)
#
# Args: $1 mode ("approve" or "flag")
# Stdout: compact JSON {valid:bool, missing:[...], unexpected:[...]}
#   missing:    fields the rule required but the excerpt lacks
#   unexpected: fields the rule required absent but the excerpt contains
validate_excerpt_structure() {
    local mode="$1"
    jq -n -c \
        --arg mode "$mode" \
        --arg excerpt "$(printf '%s' "$EVIDENCE_EXCERPT" | tr '[:upper:]' '[:lower:]')" \
        --arg name "$(printf '%s' "$CREDITED_NAME" | tr '[:upper:]' '[:lower:]')" \
        --arg track "$(printf '%s' "$TRACK_TITLE" | tr '[:upper:]' '[:lower:]')" \
        --arg role "$(printf '%s' "$ROLE" | tr '[:upper:]' '[:lower:]')" '
        ($role | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $role_tokens
        |
        # name and at least one context arg are guaranteed non-empty by CLI validation
        ($excerpt | contains($name)) as $has_name
        |
        # has_context: track contains, OR any role token contains. Bind each
        # token via `. as $tok` so the inner `$excerpt | contains($tok)` pipe
        # references the iterator value explicitly — `.` would get rebound to
        # $excerpt by the pipe and contains($excerpt) is trivially true.
        (($track != "" and ($excerpt | contains($track)))
         or ([$role_tokens[] | select(. != "") | . as $tok | $excerpt | contains($tok)] | any)) as $has_context
        |
        if $mode == "approve" then
            {
                valid: ($has_name and $has_context),
                missing: ([
                    (if $has_name    then empty else "credited_name" end),
                    (if $has_context then empty else "track_or_role" end)
                ]),
                unexpected: []
            }
        elif $mode == "flag" then
            {
                valid: ($has_context and ($has_name | not)),
                missing: ([
                    (if $has_context then empty else "track_or_role" end)
                ]),
                unexpected: ([
                    (if $has_name    then "credited_name" else empty end)
                ])
            }
        else
            {valid: false, missing: ["unknown_mode"], unexpected: []}
        end
        '
}

# Count distinct Tier-1 hostnames whose successful browser snapshot in the
# current run window contains EVIDENCE_EXCERPT verbatim (case-insensitive).
# Emits a JSON object {matched_count, matched_hosts}; on no session log,
# returns 0 matches (same semantics the gate uses).
#
# Args: $1 session_log path (may be empty/non-existent)
#       $2 run_started_ts (may be empty — unbounded window)
#
# Stdout: a single compact JSON line.
count_excerpt_matches() {
    local session_log="$1" run_started_ts="$2"
    if [[ -z "$session_log" || ! -f "$session_log" ]]; then
        printf '%s\n' '{"matched_count":0,"matched_hosts":[]}'
        return 0
    fi
    jq -R -n \
        --arg excerpt "$(echo "$EVIDENCE_EXCERPT" | tr '[:upper:]' '[:lower:]')" \
        --arg hosts "$CV_TIER1_HOSTS" \
        --arg run_started_ts "$run_started_ts" \
    '
    ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
    |
    [inputs | fromjson? // empty | select(type == "object")
     | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
    |
    (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
        ({}; . + {($tc.id): {name: $tc.name, url: $tc.arguments.url}})
    ) as $calls
    |
    [
        $lines[]
        | .message | select(.role == "toolResult")
        | . as $tr
        | $calls[.toolCallId] // empty
        | select(.name == "browser")
        | (.url // "") | select(. != "")
        | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host
        | select($t1[.] // false)
        | . as $host
        | $tr.content
        | map(.text // "") | join(" ") | ascii_downcase
        | select(contains($excerpt))
        | $host
    ] | unique as $matched_hosts
    |
    {matched_count: ($matched_hosts | length), matched_hosts: $matched_hosts}
    ' "$session_log" 2>/dev/null || printf '%s\n' '{"matched_count":0,"matched_hosts":[]}'
}

# --- Browse-required gate (BOTH approve and flag) ---
# Why this exists: run 20260430-130332-c1f8f9 escalated 500/500 with exactly
# 1 browser call across the entire run; run 20260430-111343-1605a8 flagged
# 460/460 the same way. The agent reads the queue once, applies a template
# decision per credit, and never browses per profile.
#
# count_profile_browser_loads (sourced from lib/browser-evidence.sh) returns
# the number of distinct Tier-1 hosts whose response text proves the claim
# for this profile. We pass the claim metadata via env vars; the helper
# enforces (Tier-1 host) AND (response text contains credited_name) AND
# (response text contains track_title OR any role token).
#
# Bypassable for tests via CV_REQUIRED_PROFILE_BROWSE=0. Default 1.
#
# Why exit 5 (distinct from exit 3): post-batch reconciliation wants to
# bucket "agent never produced Tier-1 evidence for THIS profile" separately
# from "agent browsed but excerpt didn't reach quorum" — they require
# different remediation guidance.
if [[ "${CV_REQUIRED_PROFILE_BROWSE:-1}" != "0" ]]; then
    pb_run_started_ts="$(resolve_run_started_ts)"
    export CV_SESSION_RUN_STARTED_TS="$pb_run_started_ts"
    export CV_PROFILE_CREDITED_NAME="$CREDITED_NAME"
    export CV_PROFILE_TRACK_TITLE="$TRACK_TITLE"
    export CV_PROFILE_ROLES="$ROLE"
    pb_count="$(count_profile_browser_loads "$PROFILE_ID")"
    pb_count="${pb_count:-0}"
    if (( pb_count < 1 )); then
        cat >&2 <<EOF
ERROR: batch-verify-profile: --decision ${DECISION} requires at least 1
Tier-1 browser snapshot whose response text proves the claim for profile
'${PROFILE_ID}' in the current run window, but 0 were found.

Resolved claim:
  credited_name: '${CREDITED_NAME}'
  track_title:   '${TRACK_TITLE}'
  role:          '${ROLE}'

Load Tier-1 pages (music.apple.com / musicbrainz.org / discogs.com /
allmusic.com) and capture verbatim excerpts that include the credited
name AND either the track title or a role token. Suggested next browser
calls:
  browser(https://musicbrainz.org/search?query=...&type=artist)
  browser(https://www.allmusic.com/search/all?q=...)

The 'BORDERLINE / conservative batch review' template is NOT a substitute
for actual Tier-1 evidence. Every per-credit decision must be grounded in
a Tier-1 browser snapshot proving the claim is at the credit context.

If sources are unreachable, ESCALATE via the existing Step 5 path with
real evidence about why you can't reach them; do NOT bulk-flag or bulk-
escalate without per-profile Tier-1 evidence.
EOF
        write_pre_flight_rejection "missing_profile_browse"
        emit_summary "missing_profile_browse" "null"
        exit 5
    fi
fi

# --- Flag path: structural rule + raised quorum (>=2 Tier-1) + reason enum ---
# As of this PR, flag matches approve in rigor:
#   1. Browse-required (already enforced above for both decisions, exit 5)
#   2. Structural excerpt rule (inverted): excerpt must contain track/role
#      AND must NOT contain credited_name. Proves verified absence — if the
#      person IS on the page, flag is the wrong decision.
#   3. Quorum: excerpt appears on >= CV_REQUIRED_LOADS distinct Tier-1 hosts
#      (raised from >=1 in earlier iterations).
# No bypass — every flag requires real per-profile browser evidence. If the
# agent can't reach the gate (sources down, queue too noisy, etc.) it must
# ESCALATE (existing Step 5 path), not bulk-flag.

if [[ "$DECISION" == "flag" ]]; then
    # Step 2: structural rule (inverted for flag).
    flag_struct=$(validate_excerpt_structure "flag")
    if [[ "$(printf '%s' "$flag_struct" | jq -r '.valid')" != "true" ]]; then
        unexpected=$(printf '%s' "$flag_struct" | jq -r '.unexpected | join(", ")')
        missing=$(printf '%s' "$flag_struct" | jq -r '.missing | join(", ")')
        cat >&2 <<EOF
ERROR: batch-verify-profile: --decision flag excerpt does not prove the claim.

Excerpt: '${EVIDENCE_EXCERPT}'
Claim:   credited_name='${CREDITED_NAME}', track_title='${TRACK_TITLE}', role='${ROLE}'

Flag rule (inverted — proving the credited person is NOT in the credit area):
  excerpt MUST contain at least one of (track_title, any role token)
  excerpt MUST NOT contain credited_name

EOF
        if [[ -n "$unexpected" ]]; then
            cat >&2 <<EOF
Unexpected (excerpt should NOT contain): ${unexpected}
The credited person's name appears in your excerpt — that means they ARE in
the rendered text, which contradicts the flag verdict. If they're in the
credit list, you should APPROVE; if they're elsewhere on the page but not
credited as ${ROLE}, your excerpt should be drawn from the credit area
specifically (so the absence is verifiable).

EOF
        fi
        if [[ -n "$missing" ]]; then
            cat >&2 <<EOF
Missing (excerpt must contain at least one of): ${missing}
You need a literal substring proving you SAW the credit area on a Tier-1
page (e.g., "Songwriters: Lennon, McCartney" or "Producer: ..."). Without
that, "name absent" can't be distinguished from "wrong page loaded".

EOF
        fi
        cat >&2 <<EOF
Suggested recovery: load the Tier-1 page's credit section, copy a substring
that includes the role/track title BUT not '${CREDITED_NAME}', then retry.

If you genuinely cannot reach Tier-1 sources, ESCALATE via Step 5 instead
of bulk-flagging.
EOF
        write_pre_flight_rejection "excerpt_does_not_prove_claim"
        emit_summary "excerpt_does_not_prove_claim" "null"
        exit 6
    fi

    # Step 3: quorum (resolve run scoping; same approach as approve path).
    run_started_ts="$(resolve_run_started_ts)"
    export CV_SESSION_RUN_STARTED_TS="$run_started_ts"
    flag_session_log="$(resolve_session_log)"
    flag_match_json="$(count_excerpt_matches "$flag_session_log" "$run_started_ts")"
    flag_match_count=$(printf '%s' "$flag_match_json" | jq -r '.matched_count')
    flag_match_count="${flag_match_count:-0}"

    if (( flag_match_count < CV_REQUIRED_LOADS )); then
        missing=$(( CV_REQUIRED_LOADS - flag_match_count ))
        matched_hosts_block=""
        while IFS= read -r h; do
            [[ -n "$h" ]] && matched_hosts_block+="  - ${h}"$'\n'
        done < <(printf '%s' "$flag_match_json" | jq -r '.matched_hosts[]?')
        if [[ -z "$matched_hosts_block" ]]; then
            matched_hosts_block="  (none)"$'\n'
        fi
        excerpt_enc=$(printf '%s' "$EVIDENCE_EXCERPT" | jq -sRr @uri)
        cat >&2 <<EOF
ERROR: batch-verify-profile: --decision flag requires the excerpt
'${EVIDENCE_EXCERPT}' to appear on >=${CV_REQUIRED_LOADS} distinct Tier-1
browser snapshots in the current run window, but only ${flag_match_count}
matched.

Currently matching:
${matched_hosts_block}
Load ${missing} more distinct Tier-1 page(s) containing the excerpt before
retrying. Suggested next calls:
  browser(https://musicbrainz.org/search?query=${excerpt_enc}&type=artist)
  browser(https://www.allmusic.com/search/all?q=${excerpt_enc})
  browser(https://www.discogs.com/search/?q=${excerpt_enc}&type=artist)

If you can't reach Tier-1 sources (rate-limited, blocked, etc.) or a human
asked you to flag this profile, ESCALATE via the existing Step 5 escalation
path. Do NOT bulk-flag without evidence.
EOF
        write_pre_flight_rejection "missing_flag_evidence"
        emit_summary "missing_flag_evidence" "null"
        exit 3
    fi

    delegate_rc=0
    bash "$BATCH_FLAG_SH" \
        --profile-id "$PROFILE_ID" \
        --credited-name "$CREDITED_NAME" \
        --track-title "$TRACK_TITLE" \
        --role "$ROLE" \
        --reason "$REASON" \
        --flag-reason "$FLAG_REASON" \
        --ids "$IDS_RAW" >/dev/null || delegate_rc=$?
    emit_summary "ok" "$delegate_rc"
    exit "$delegate_rc"
fi

# --- Approve path: structural rule + contamination + quorum before delegation ---

# 1. Structural rule first (cheap, no session scan).
approve_struct=$(validate_excerpt_structure "approve")
if [[ "$(printf '%s' "$approve_struct" | jq -r '.valid')" != "true" ]]; then
    missing=$(printf '%s' "$approve_struct" | jq -r '.missing | join(", ")')
    cat >&2 <<EOF
ERROR: batch-verify-profile: --decision approve excerpt does not prove the claim.

Excerpt: '${EVIDENCE_EXCERPT}'
Claim:   credited_name='${CREDITED_NAME}', track_title='${TRACK_TITLE}', role='${ROLE}'

Approve rule: excerpt MUST contain credited_name AND at least one of
              (track_title, any role token).

Missing from your excerpt: ${missing}

Recovery: load the credit area of a Tier-1 page (MusicBrainz recording-
level credits, AllMusic credits panel, Discogs release tracklist) and copy a
substring that includes BOTH the credited person's name AND either the role
or the track title. Examples of valid approve excerpts:
  "Pau Romero, songwriter"             (name + role)
  "Pau Romero — Yellow Submarine"      (name + track)
  "Songwriter: Pau Romero"             (role + name)

If Tier-1 pages do not show the person at the credit context, downgrade to
flag (with an inverted excerpt proving absence) or escalate via Step 5.
EOF
    write_pre_flight_rejection "excerpt_does_not_prove_claim"
    emit_summary "excerpt_does_not_prove_claim" "null"
    exit 6
fi

run_started_ts="$(resolve_run_started_ts)"
export CV_SESSION_RUN_STARTED_TS="$run_started_ts"

# 2. Contamination check — Tier-1 web_fetch detected in current run window?
# session-evidence.sh --check-tier1-webfetch honors CV_SESSION_RUN_STARTED_TS,
# so only within-run contamination counts.
cf_rc=0
cf_stderr_file="$(mktemp)"
bash "$SESSION_EVIDENCE_SH" --check-tier1-webfetch 2>"$cf_stderr_file" || cf_rc=$?
if [[ $cf_rc -ne 0 ]]; then
    cat "$cf_stderr_file" >&2
    rm -f "$cf_stderr_file"
    write_pre_flight_rejection "web_fetch_tier1"
    emit_summary "web_fetch_tier1" "null"
    exit 3
fi
rm -f "$cf_stderr_file"

# 3. Evidence quorum: shared helper count_excerpt_matches (defined above).
# Mirrors enforce_credit_approve_gate — when count >= CV_REQUIRED_LOADS the
# delegate is allowed; otherwise we emit remediation text naming which
# Tier-1 hosts are currently matching.
session_log="$(resolve_session_log)"
matched_json="$(count_excerpt_matches "$session_log" "$run_started_ts")"
matched_count=$(printf '%s' "$matched_json" | jq -r '.matched_count')
matched_count="${matched_count:-0}"

if (( matched_count < CV_REQUIRED_LOADS )); then
    # Render remediation. List the hosts currently matching, suggest the next
    # browser calls to reach quorum. Agent can copy-paste the browser() calls.
    missing=$(( CV_REQUIRED_LOADS - matched_count ))
    matched_hosts_block=""
    while IFS= read -r h; do
        [[ -n "$h" ]] && matched_hosts_block+="  - ${h}"$'\n'
    done < <(printf '%s' "$matched_json" | jq -r '.matched_hosts[]?')
    if [[ -z "$matched_hosts_block" ]]; then
        matched_hosts_block="  (none)"$'\n'
    fi

    # URL-encode the excerpt for the query-string suggestions. jq @uri is the
    # least-surprise option across GNU/BSD shells.
    excerpt_enc=$(printf '%s' "$EVIDENCE_EXCERPT" | jq -sRr @uri)

    cat >&2 <<EOF
ERROR: batch-verify-profile: evidence excerpt '${EVIDENCE_EXCERPT}' found on ${matched_count}/${CV_REQUIRED_LOADS} required Tier-1 hostnames.

Currently matching:
${matched_hosts_block}
Load ${missing} more distinct Tier-1 page(s) containing '${EVIDENCE_EXCERPT}' before retrying. Suggested next browser calls:
  browser(https://musicbrainz.org/search?query=${excerpt_enc}&type=artist)
  browser(https://www.allmusic.com/search/all?q=${excerpt_enc})
  browser(https://www.discogs.com/search/?q=${excerpt_enc}&type=artist)

After loading, re-run:
  batch-verify-profile.sh --profile-id '${PROFILE_ID}' --evidence-excerpt '${EVIDENCE_EXCERPT}' --ids '${IDS_RAW}' --decision approve

If Tier 1 pages genuinely do not confirm these credits, downgrade to flag
(user_verification_needed) with --decision flag --reason "<short reason>".
EOF
    write_pre_flight_rejection "missing_evidence"
    emit_summary "missing_evidence" "null"
    exit 3
fi

# --- Pre-flight passed — delegate approve ---

delegate_rc=0
bash "$BATCH_APPROVE_SH" \
    --profile-id "$PROFILE_ID" \
    --credited-name "$CREDITED_NAME" \
    --track-title "$TRACK_TITLE" \
    --role "$ROLE" \
    --evidence-excerpt "$EVIDENCE_EXCERPT" \
    --ids "$IDS_RAW" >/dev/null || delegate_rc=$?

emit_summary "ok" "$delegate_rc"
exit "$delegate_rc"

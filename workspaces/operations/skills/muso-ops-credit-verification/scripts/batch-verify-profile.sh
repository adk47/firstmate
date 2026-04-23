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
#       --evidence-excerpt "<literal substring, 8-200 chars>" \
#       --ids "<id1>,<id2>,..." \
#       --decision approve|flag \
#       [--reason "<short text, required for --decision flag>"]
#
# Contract:
#   * --requester is REFUSED (autonomous batch only — same policy as the two
#     delegate wrappers).
#   * --decision approve runs the session-contamination check AND the
#     evidence quorum check before delegating. --decision flag skips those
#     (UVN writes aren't gated) but still propagates exit codes.
#   * Exit 0 on delegate success. Exit 1 on delegate failure (gate rejection,
#     HTTP error). Exit 2 on argument validation failure. Exit 3 on
#     pre-flight failure (missing evidence OR Tier-1 web_fetch contamination).
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
CV_TIER1_HOSTS="${CV_TIER1_HOSTS:-open\\.spotify\\.com|music\\.apple\\.com|musicbrainz\\.org|discogs\\.com|allmusic\\.com|tidal\\.com}"

# Delegate scripts. Overridable for tests so they can stub a mock admin-api.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_EVIDENCE_SH="${SESSION_EVIDENCE_SH:-$SCRIPT_DIR/session-evidence.sh}"
BATCH_APPROVE_SH="${BATCH_APPROVE_SH:-$SCRIPT_DIR/batch-approve-credits.sh}"
BATCH_FLAG_SH="${BATCH_FLAG_SH:-$SCRIPT_DIR/batch-flag-credits.sh}"

PROFILE_ID=""
EVIDENCE_EXCERPT=""
IDS_RAW=""
DECISION=""
REASON=""

usage() {
    cat >&2 <<EOF
Usage:
  batch-verify-profile.sh \\
      --profile-id <profile_id> \\
      --evidence-excerpt "<literal substring>" \\
      --ids "<id1>,<id2>,..." \\
      --decision approve|flag \\
      [--reason "<short text>"]

Required for all decisions:
  --profile-id         The profile UUID whose credits are being processed.
  --evidence-excerpt   A literal substring (>=${CV_EVIDENCE_EXCERPT_MIN},
                       <=${CV_EVIDENCE_EXCERPT_MAX} chars) that should appear
                       on >=${CV_REQUIRED_LOADS} Tier-1 pages for approve.
                       For flag, used only for bookkeeping.
  --ids                Comma-separated list of credit-request IDs.
  --decision           'approve' (evidence-gated) or 'flag' (UVN, ungated).

Required for --decision flag:
  --reason             Short string for the 'reason' field on each PATCH.

Forbidden:
  --requester          Autonomous-batch only. For human-authorized overrides
                       call muso-admin-api.sh directly (muso-ops-admin/SKILL.md).

Exit codes:
  0   delegate success
  1   delegate failure (gate rejection post-pre-flight, HTTP error, etc.)
  2   argument validation failure
  3   pre-flight failure — evidence quorum not met OR Tier-1 web_fetch in session

Stdout (one compact JSON line):
  {"profile_id":"...","decision":"approve|flag","ids":[...],
   "pre_flight":"ok|missing_evidence|web_fetch_tier1","delegate_exit":N}

When pre_flight != "ok", stderr prints actionable remediation text:
which Tier-1 pages to browse next, and the exact retry command.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile-id)        PROFILE_ID="${2:-}";        shift 2 ;;
        --evidence-excerpt)  EVIDENCE_EXCERPT="${2:-}";  shift 2 ;;
        --ids)               IDS_RAW="${2:-}";           shift 2 ;;
        --decision)          DECISION="${2:-}";          shift 2 ;;
        --reason)            REASON="${2:-}";            shift 2 ;;
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
case "$DECISION" in
    approve|flag) ;;
    *) echo "ERROR: --decision must be 'approve' or 'flag' (got '$DECISION')." >&2; exit 2 ;;
esac
if [[ "$DECISION" == "flag" && -z "$REASON" ]]; then
    echo "ERROR: --reason is required for --decision flag." >&2
    exit 2
fi

# IDs-as-JSON-array for the summary (uses same trim logic as delegates).
ids_json=$(
    jq -n -c --arg raw "$IDS_RAW" \
        '$raw | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
)

emit_summary() {
    # args: pre_flight delegate_exit(maybe "null")
    local pre_flight="$1" delegate_exit="$2"
    jq -n -c \
        --arg profile_id "$PROFILE_ID" \
        --arg decision "$DECISION" \
        --argjson ids "$ids_json" \
        --arg pre_flight "$pre_flight" \
        --argjson delegate_exit "$delegate_exit" \
        '{profile_id:$profile_id, decision:$decision, ids:$ids,
          pre_flight:$pre_flight, delegate_exit:$delegate_exit}'
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
# args: reason ("missing_evidence" or "web_fetch_tier1")
write_pre_flight_rejection() {
    local reason="$1"
    # Only approve path ever fails pre-flight; flag path returns early.
    [[ "$DECISION" == "approve" ]] || return 0

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
        '{
            ts: $ts,
            run_id: (if $run_id == "" then null else $run_id end),
            method: "PUT",
            path: "/admin/credit-requests",
            request_ids: $request_ids,
            intended_status: "approved",
            outcome: $outcome,
            http_status: null,
            error: null,
            pre_flight: $pre_flight,
            evidence_excerpt: $evidence_excerpt,
            profile_id: $profile_id,
            requester: (if $requester == "" then null else $requester end)
         }' 2>/dev/null) || {
        echo "WARN: jq failed to build pre-flight rejection line for profile ${PROFILE_ID}" >&2
        return 0
    }
    printf '%s\n' "$line" >> "$results_path" 2>/dev/null || {
        echo "WARN: could not append to $results_path; pre-flight line LOST for profile ${PROFILE_ID}" >&2
    }
}

# --- Flag path: no evidence gate, delegate directly ---

if [[ "$DECISION" == "flag" ]]; then
    delegate_rc=0
    bash "$BATCH_FLAG_SH" \
        --profile-id "$PROFILE_ID" \
        --reason "$REASON" \
        --ids "$IDS_RAW" >/dev/null || delegate_rc=$?
    emit_summary "ok" "$delegate_rc"
    exit "$delegate_rc"
fi

# --- Approve path: contamination check + evidence quorum before delegation ---

# R3-3: scope the session-log scan to the current run. Reads OPS_RUNLOG_DIR/
# latest.txt → runlog → first run_started event's .ts. Logic mirrors
# resolve_run_started_ts() in muso-admin-api.sh — keep them in lockstep.
resolve_run_started_ts() {
    [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
    local latest_idx runlog_path
    latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
    [[ -f "$latest_idx" ]] || return 0
    runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
    [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
    jq -s -r 'first(.[] | select(.event == "run_started") | .ts) // empty' "$runlog_path" 2>/dev/null | head -1
}

run_started_ts="$(resolve_run_started_ts)"
export CV_SESSION_RUN_STARTED_TS="$run_started_ts"

# 1. Contamination check — Tier-1 web_fetch detected in current run window?
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

# 2. Resolve session log path for the evidence-quorum jq pipeline. Mirrors
# session-evidence.sh / muso-admin-api.sh's discovery (portable GNU/BSD).
resolve_session_log() {
    if [[ -n "${CV_SESSION_LOG_OVERRIDE:-}" ]]; then
        echo "$CV_SESSION_LOG_OVERRIDE"
        return
    fi
    find /root/.openclaw-main/agents /root/.openclaw-dev/agents \
        -maxdepth 3 -type f -name "*.jsonl" -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
    | while IFS= read -r f; do
        mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
        [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
      done \
    | sort -rn | head -1 | cut -d' ' -f2-
}

session_log="$(resolve_session_log)"

# --- Evidence quorum check (mirrors enforce_credit_approve_gate) ---
#
# Emits a JSON object with {matched_count, matched_hosts} so the wrapper can
# both decide the outcome and render remediation text naming which Tier-1
# hosts are currently matching. When no session log is available the wrapper
# treats it as zero matches — same semantics as the gate.
matched_json='{"matched_count":0,"matched_hosts":[]}'
if [[ -n "$session_log" && -f "$session_log" ]]; then
    matched_json=$(
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
        ' "$session_log" 2>/dev/null || echo '{"matched_count":0,"matched_hosts":[]}'
    )
fi

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
  browser(https://open.spotify.com/artist/${PROFILE_ID})
  browser(https://www.allmusic.com/search/all?q=${excerpt_enc})
  browser(https://musicbrainz.org/search?query=${excerpt_enc}&type=artist)

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
    --evidence-excerpt "$EVIDENCE_EXCERPT" \
    --ids "$IDS_RAW" >/dev/null || delegate_rc=$?

emit_summary "ok" "$delegate_rc"
exit "$delegate_rc"

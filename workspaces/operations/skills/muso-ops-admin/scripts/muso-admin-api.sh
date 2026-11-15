#!/usr/bin/env bash
# Reviewed baseline: deploy overwrites - 2026-11-12 (deploy-drift-1890, firstmate 006): node-8 carried a
# 2603-line copy (sha256 129d14ce4f8a621c8e2246368c3184dcfb482a497df8f9decacff36c66352ca9) whose 173
# live-only lines were ALL code this repo had already deleted: the TIER2_GODMODE allowlist, PROFILE_AUDIT_ID,
# FRAUD_UVN_ATTEMPT_PATH, resolve_run_header_dryrun() (the 2026-04-23 OPS_DRY_RUN incident guard) and the
# R3-3 run_started gate. Nothing on the box was newer than main, so the repo is the truth and the deploy
# overwrites it. Backup of the live copy: node-8 /var/backups/hydra-drift-1890/muso-admin-api.sh.20261112T1046Z
# muso-admin-api.sh — Core admin API wrapper for all Muso ops skills
# Usage: bash muso-admin-api.sh [--requester email] <command> [options]
#
# Commands:
#   login                              Get/refresh admin JWT token (cached 23h)
#   call <METHOD> <path> [json-body]   Make an authenticated admin API call
#   upload [POST|PUT] <path> <file> [fields...]   Multipart upload with auth (default POST)
#   resolve-email <slack_id>           Resolve Slack ID to muso.ai email
#
# Global Options:
#   --requester <email|slack_id>  Email or Slack ID of the human who initiated this action.
#                                 If a Slack ID (U...) is passed, it's resolved to email.
#                                 Sent as 'Requester' header for backend audit trail.
#                                 Also sends 'Service: clio' header.
#
# Requires: MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD in env
# Base URL: https://api.muso.ai/api/v3 (routes use /admin/* prefix)

set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required but not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ADMIN_TOKEN_CACHE_PATH override exists so tests can redirect the cache out
# of the production scripts directory; production calls leave it unset.
TOKEN_CACHE="${ADMIN_TOKEN_CACHE_PATH:-$SCRIPT_DIR/.admin-token-cache}"
TOKEN_MAX_AGE=82800  # 23 hours in seconds
REQUESTER_EMAIL=""   # Set via --requester flag
EVIDENCE_EXCERPT=""  # Set via --evidence-excerpt flag (required for autonomous credit approves)
PROFILE_AUDIT_ID=""  # Set via --profile-audit-id flag (Tier-0 profile-audit evidence path: dispatcher passes the profile_id behind the receipt so the gate can re-fetch + re-verify)
CONFIRMED_BY=""      # Set via --confirmed-by flag (required for tier-2 writes — see enforce_tier2_approval_gate)
APPROVAL_MSG_ID=""   # Set via --approval-msg-id flag (Slack message ID/ts of the in-thread approval — for audit)
APPROVAL_AUTHOR_ID="" # Set via --approval-author-id flag (Slack user id of the approval message author — for audit, optional)
APPROVAL_CHANNEL=""  # Set via --approval-channel flag (Slack channel id the approval message is in — for audit, optional)

# Tier-2 enforcement state. Persisted to disk so the reverse-direction guard
# fires across separate shell invocations (each agent exec is a new shell).
# /var/log/muso-ops is hydra's canonical location; tests can override with
# MUSO_OPS_STATE_DIR. Created lazily on first write.
MUSO_OPS_STATE_DIR="${MUSO_OPS_STATE_DIR:-/var/log/muso-ops}"
RECENT_MERGES_PATH="${RECENT_MERGES_PATH:-${MUSO_OPS_STATE_DIR}/recent-merges.jsonl}"
TIER2_AUDIT_PATH="${TIER2_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/tier2-audit.jsonl}"
CREDIT_REJECT_AUDIT_PATH="${CREDIT_REJECT_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/credit-reject-audit.jsonl}"
FRAUD_UVN_ATTEMPT_PATH="${CV_FRAUD_ATTEMPT_PATH:-${MUSO_OPS_STATE_DIR}/fraud-uvn-attempts.jsonl}"
TIER2_APPROVERS_PATH="${TIER2_APPROVERS_PATH:-${SCRIPT_DIR}/../config/tier2-approvers.txt}"
TIER2_ENDPOINTS_PATH="${TIER2_ENDPOINTS_PATH:-${SCRIPT_DIR}/../config/tier2-endpoints.txt}"
TIER2_GODMODE_PATH="${TIER2_GODMODE_PATH:-${SCRIPT_DIR}/../config/tier2-godmode-allowlist.txt}"
# Reverse-direction guard window. A second merge that points the OTHER way
# within this many seconds is the 2026-04-29 incident pattern; refuse it.
TIER2_REVERSE_WINDOW_SECS="${TIER2_REVERSE_WINDOW_SECS:-300}"

# --- Bulk destructive-operation gate (incident 2026-05-26) ---
# On 2026-05-26 the ops agent autonomously issued ~285 DELETE
# /admin/track/:id/analytics-sources calls in one run off a vague "fix it",
# wiping the only Spotify analytics link on 10 tracks and collapsing a
# profile's lifetime stream count. This gate caps the blast radius: once
# BULK_DESTRUCTIVE_THRESHOLD destructive DELETEs land within
# BULK_DESTRUCTIVE_WINDOW_SECS, every further destructive DELETE is refused
# unless an explicit human DECISION NAMING THOSE ROWS (--confirmed-by +
# --approval-msg-id) is supplied. It need not come from a SECOND human: when the
# requester is on the tier-2 approver list AND enumerated the exact targets,
# their own request message is that decision. Requester identity alone still
# does NOT bypass the gate — the agent auto-stamps --requester with whoever is
# in-thread, so by itself it is not evidence that a human chose these rows.
BULK_DESTRUCTIVE_PATH="${BULK_DESTRUCTIVE_PATH:-${MUSO_OPS_STATE_DIR}/destructive-ops.jsonl}"
BULK_DESTRUCTIVE_AUDIT_PATH="${BULK_DESTRUCTIVE_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/bulk-destructive-audit.jsonl}"
BULK_DESTRUCTIVE_RESULTS_PATH="${BULK_DESTRUCTIVE_RESULTS_PATH:-${MUSO_OPS_STATE_DIR}/destructive-ops-results.jsonl}"
BULK_DESTRUCTIVE_THRESHOLD="${BULK_DESTRUCTIVE_THRESHOLD:-10}"
BULK_DESTRUCTIVE_WINDOW_SECS="${BULK_DESTRUCTIVE_WINDOW_SECS:-900}"
BULK_DESTRUCTIVE_EXCLUDE_PATH="${BULK_DESTRUCTIVE_EXCLUDE_PATH:-${SCRIPT_DIR}/../config/bulk-destructive-exclude.txt}"
if ! [[ "$BULK_DESTRUCTIVE_THRESHOLD" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: BULK_DESTRUCTIVE_THRESHOLD must be a positive integer (got '${BULK_DESTRUCTIVE_THRESHOLD}')" >&2
    exit 1
fi
if ! [[ "$BULK_DESTRUCTIVE_WINDOW_SECS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: BULK_DESTRUCTIVE_WINDOW_SECS must be a positive integer (got '${BULK_DESTRUCTIVE_WINDOW_SECS}')" >&2
    exit 1
fi

# --- Dry-run mode (issue #145) ---
# OPS_DRY_RUN=1 short-circuits every WRITE (anything that isn't GET/HEAD) in
# cmd_call, and all of cmd_upload, with a synthetic 200 response. GET/HEAD
# still hit the real API so the caller can read state. Every would-be write
# is appended to OPS_DRY_RUN_AUDIT_PATH as JSONL for later review. The
# credit-approve gate runs BEFORE the short-circuit so a broken batch still
# fails visibly — the whole point is "what would have happened, gate included".
#
# The method check is fail-closed (deny-list) rather than fail-open
# (PUT|POST|PATCH|DELETE allow-list) — lower-case `put`, typos, and future
# verbs the admin API might add all get intercepted instead of silently
# hitting prod. Only GET/HEAD (case-insensitive) pass through.
case "$(printf %s "${OPS_DRY_RUN:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)        OPS_DRY_RUN=1 ;;
    0|false|no|off|"")    OPS_DRY_RUN=0 ;;
    *)
        # Unrecognized value — treat as false, but warn loudly. Silent
        # fallthrough is the footgun that lets `OPS_DRY_RUN=enable` produce
        # real writes when the user thinks they're in dry-run.
        echo "WARN: OPS_DRY_RUN='${OPS_DRY_RUN}' not recognized; treating as false. Use 1|true|yes|on to enable." >&2
        OPS_DRY_RUN=0
        ;;
esac
OPS_DRY_RUN_AUDIT_PATH="${OPS_DRY_RUN_AUDIT_PATH:-/tmp/ops-dry-run-audit.jsonl}"
# Tracks whether the last write_dry_run_audit call succeeded. Read by
# emit_dry_run_response to surface audit failure in the synthetic envelope.
DRY_RUN_AUDIT_FAILED=0

is_dry_run_mode() {
    [[ "$OPS_DRY_RUN" == "1" ]]
}

# Resolve whether the active batch runlog's header says this run is a dry-run.
# Returns "true", "false", or empty string (unknown / no active run). Used by
# the dry-run config-mismatch guard (R2-1) to detect the 2026-04-23 09:02 UTC
# incident shape: agent set OPS_DRY_RUN=1 in B0 but failed to re-export it in
# a later exec shell; 12 UVN PATCHes hit the real admin API because OPS_DRY_RUN
# was empty in that specific shell. The runlog header is the filesystem source
# of truth — it persists across exec shells and reflects the mode the run WAS
# initialized in.
#
# Resolution chain mirrors write_credit_request_result: OPS_RUNLOG_DIR env →
# latest.txt → grep first run_header event's dryRun field.
resolve_run_header_dryrun() {
    [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
    local latest_idx runlog_path
    latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
    [[ -f "$latest_idx" ]] || return 0
    runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
    [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
    # First run_header event's dryRun value. If multiple run_headers (shouldn't
    # happen — one per run), use the first. jq -s slurps; we take head -1 to
    # bound work on a large runlog.
    jq -s -r 'first(.[] | select(.event == "run_header") | .dryRun) // empty' "$runlog_path" 2>/dev/null | head -1
}

# R3-3: return the current run's run_started.ts (ISO-8601 string). The gate
# uses this to scope its session-log scan — past browser loads and past
# web_fetch calls are excluded so channel-keyed session persistence (openclaw
# writes all turns in a channel to one file) can't bleed yesterday's
# contamination into today's run. Empty output = no scope, caller falls back
# to the mtime-only window. Resolution chain mirrors resolve_run_header_dryrun.
resolve_run_started_ts() {
    [[ -n "${OPS_RUNLOG_DIR:-}" ]] || return 0
    local latest_idx runlog_path
    latest_idx="${OPS_RUNLOG_DIR}/latest.txt"
    [[ -f "$latest_idx" ]] || return 0
    runlog_path=$(cat "$latest_idx" 2>/dev/null || true)
    [[ -n "$runlog_path" && -f "$runlog_path" ]] || return 0
    # runlog.sh event always stamps .ts on every event; first run_started is
    # the canonical "batch work begins" anchor.
    jq -s -r 'first(.[] | select(.event == "run_started") | .ts) // empty' "$runlog_path" 2>/dev/null | head -1
}

# Append a JSONL audit line for a would-be write. Uses jq -n for consistency
# with runlog.sh / compute-run-summary.sh; arg-passing avoids shell
# interpolation of the body entirely. On any failure to write, emits a loud
# stderr warning and sets DRY_RUN_AUDIT_FAILED=1 — callers (emit_dry_run_response)
# surface that flag so the caller never mistakes "audit lost" for "audited".
write_dry_run_audit() {
    local method="$1" path="$2" body="${3:-}" kind="${4:-call}"
    local audit_dir ts run_id
    audit_dir="$(dirname "$OPS_DRY_RUN_AUDIT_PATH")"
    if ! mkdir -p "$audit_dir" 2>/dev/null; then
        echo "WARN: could not create audit dir ${audit_dir}; dry-run audit line LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_id="${OPS_RUN_ID:-${RUN_ID:-}}"
    # Filesystem fallback (issue #152). SKILL.md B0c sets OPS_RUN_ID in its
    # shell, but every subsequent exec tool call is a fresh shell — the export
    # doesn't propagate, so audit lines from per-call bash blocks would land
    # with run_id=null even though a run is active. Read OPS_RUNLOG_DIR/
    # latest.txt (written by runlog.sh init) as the filesystem source of truth
    # and extract the run_id from its filename. Only accept a filename that
    # matches the canonical run_id shape to avoid stuffing garbage into the
    # audit trail if latest.txt ever gets clobbered.
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
    # Upload kind stores the local file path in its own field; call kind puts
    # the JSON body string in body. This disambiguates uploads vs JSON writes
    # for post-run review — a path in `body` would otherwise look malformed.
    local body_arg file_path_arg
    if [[ "$kind" == "upload" ]]; then
        body_arg=""
        file_path_arg="$body"
    else
        body_arg="$body"
        file_path_arg=""
    fi
    local line
    if ! line=$(jq -n -c \
        --arg ts "$ts" \
        --arg kind "$kind" \
        --arg method "$method" \
        --arg path "$path" \
        --arg body "$body_arg" \
        --arg file_path "$file_path_arg" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg run_id "$run_id" \
        '{
            ts:$ts, kind:$kind, method:$method, path:$path,
            body:      (if $body      == "" then null else $body      end),
            file_path: (if $file_path == "" then null else $file_path end),
            requester: (if $requester == "" then null else $requester end),
            run_id:    (if $run_id    == "" then null else $run_id    end)
         }' 2>/dev/null); then
        echo "WARN: jq failed to build audit line; dry-run audit LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
    if ! printf '%s\n' "$line" >> "$OPS_DRY_RUN_AUDIT_PATH" 2>/dev/null; then
        echo "WARN: could not append to ${OPS_DRY_RUN_AUDIT_PATH}; dry-run audit LOST for ${method} ${path}" >&2
        DRY_RUN_AUDIT_FAILED=1
        return 0
    fi
}

# Synthetic response used for every intercepted write. body is null (NOT a
# stand-in {ok:true} payload) so consumers that expect real-API shape —
# .body.items, .body.data.id — fail loudly instead of silently reading null
# from a lying stand-in. The top-level `dryRun` key is the authoritative
# branch signal. dryRun_audit_failed surfaces lost audit lines so callers
# can detect them in the same envelope.
emit_dry_run_response() {
    local audit_failed="${DRY_RUN_AUDIT_FAILED:-0}"
    if [[ "$audit_failed" == "1" ]]; then
        printf '%s\n' '{"http_status":200,"dryRun":true,"dryRun_audit_failed":true,"body":null,"wouldHaveExecuted":true}'
    else
        printf '%s\n' '{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}'
    fi
}

# --- Credit-request results log (truth floor) ---
# Authoritative per-HTTP-call JSONL for every write to /admin/credit-requests*
# regardless of caller or redirections. Designed so a caller that wraps us in
# `> /dev/null 2>&1` cannot hide what actually happened — truth lives on disk.
#
# Downstream (compute-run-summary.sh) reads this file as the source of truth
# for approved/rejected/uvn totals. It is written in BOTH dry-run and prod.
#
# Outcome values:
#   rejected_by_gate    — enforce_credit_approve_gate returned 1
#   dry_run_intercept   — OPS_DRY_RUN=1 write short-circuit fired
#   ok                  — real API returned 2xx
#   http_error          — real API returned non-2xx
#   transport_error     — curl failed before an HTTP response was available
#
# Failure mode: if we can't write the line, emit a LOUD stderr warning but
# never break the main call. Same philosophy as write_dry_run_audit.
#
# CV_RESULTS_PATH overrides the default path (useful for tests).
write_credit_request_result() {
    local method="$1" path="$2" body="${3:-}"
    local outcome="$4" http_status="${5:-}" error="${6:-}"
    local transport_attempts="${7:-}" transport_retry_exits="${8:-[]}"

    # Scope: only credit-request writes.
    [[ "$path" == /admin/credit-requests* ]] || return 0
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in PUT|PATCH) ;; *) return 0 ;; esac

    # RUN_ID resolution (env first, then OPS_RUNLOG_DIR/latest.txt — same
    # pattern as write_dry_run_audit per #152).
    local run_id
    run_id="${OPS_RUN_ID:-${RUN_ID:-}}"
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

    # Resolve target path. CV_RESULTS_PATH explicitly wins; otherwise derive
    # from today's UTC date + run_id.
    local results_path today
    today="$(date -u +%Y-%m-%d)"
    results_path="${CV_RESULTS_PATH:-/var/log/openclaw/credit-batch-runs/${today}/${run_id:-unknown}.results.jsonl}"

    local results_dir
    results_dir="$(dirname "$results_path")"
    if ! mkdir -p "$results_dir" 2>/dev/null; then
        echo "WARN: could not create results dir ${results_dir}; results line LOST for ${method_uc} ${path}" >&2
        return 0
    fi

    # Extract request_ids + intended_status from the invocation shape:
    #   PUT  /admin/credit-requests         body: {"requestIds":[...], "status":"..."}
    #   PATCH /admin/credit-requests/<id>   body: {"status":"..."}
    # If parsing fails, record an empty array rather than guessing.
    local request_ids intended_status
    if [[ "$method_uc" == "PUT" ]]; then
        request_ids=$(printf '%s' "$body" | jq -c '.requestIds // []' 2>/dev/null)
        [[ -z "$request_ids" ]] && request_ids='[]'
    else
        local id
        id="${path#/admin/credit-requests/}"
        id="${id%%\?*}"  # strip query string if present
        if [[ -n "$id" && "$id" != "$path" ]]; then
            request_ids=$(jq -n -c --arg id "$id" '[$id]')
        else
            request_ids='[]'
        fi
    fi
    intended_status=$(printf '%s' "$body" | jq -r '.status // ""' 2>/dev/null || echo '')

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local line
    # OPS_FLAG_REASON (added 2026-04-30) — set by batch-flag-credits.sh before
    # calling, propagates the closed-list enum into the truth-floor row so
    # compute-run-summary.sh + auditors can categorize UVN actions without
    # parsing back through the agent transcript. Null on approve / non-flag.
    #
    # OPS_CREDITED_NAME / OPS_TRACK_TITLE / OPS_ROLE — set by both delegates;
    # carries the claim metadata the dispatcher validated structurally against
    # the excerpt. Lets post-batch auditing answer "what was being verified?"
    # without parsing back through the inbound message.
    if ! line=$(printf '%s' "$error" | jq -Rsc \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --arg method "$method_uc" \
        --arg path "$path" \
        --argjson request_ids "$request_ids" \
        --arg intended_status "$intended_status" \
        --arg outcome "$outcome" \
        --arg http_status "$http_status" \
        --arg transport_attempts "$transport_attempts" \
        --argjson transport_retry_exits "$transport_retry_exits" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg flag_reason "${OPS_FLAG_REASON:-}" \
        --arg credited_name "${OPS_CREDITED_NAME:-}" \
        --arg track_title "${OPS_TRACK_TITLE:-}" \
        --arg role "${OPS_ROLE:-}" \
        '. as $error | {
            ts:$ts,
            run_id:    (if $run_id    == "" then null else $run_id    end),
            method:$method,
            path:$path,
            request_ids:$request_ids,
            intended_status: (if $intended_status == "" then null else $intended_status end),
            outcome:$outcome,
            http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end),
            error:     (if $error     == "" then null else $error     end),
            transport_attempts: (if $transport_attempts == "" then null else ($transport_attempts | tonumber) end),
            transport_retry_exits:$transport_retry_exits,
            flag_reason: (if $flag_reason == "" then null else $flag_reason end),
            credited_name: (if $credited_name == "" then null else $credited_name end),
            track_title: (if $track_title == "" then null else $track_title end),
            role: (if $role == "" then null else $role end),
            requester: (if $requester == "" then null else $requester end)
         }' 2>/dev/null); then
        echo "WARN: jq failed to build results line; results line LOST for ${method_uc} ${path}" >&2
        return 0
    fi
    if ! printf '%s\n' "$line" >> "$results_path" 2>/dev/null; then
        echo "WARN: could not append to ${results_path}; results line LOST for ${method_uc} ${path}" >&2
        return 0
    fi
}

# Per-row truth floor for the BULK credit-request PUT.
#
# The backend has reported per-row outcomes since 2026-07-27 (core-backend
# #9226/#9227): a 200 can still name rows it refused, and a 409 is the "some
# rows were refused" answer whose `updatedIds` really did persist. Classifying
# the whole `requestIds` array from the HTTP code alone therefore writes a
# truth floor that is wrong in BOTH directions — and compute-run-summary.sh
# sums `request_ids | length` per outcome, so a partially successful 409
# reconciles as zero landed and can trip `run_finished_silent_failure` while
# apply-verdicts.sh (which does read the per-row report) calls those same rows
# landed. Same response, two contradictory operator-facing stories.
#
# So: when the response is attributable, split the ledger into one `ok` row for
# the ids the backend named and one `http_error` row for the rest. When it is
# NOT attributable — a 200/409 whose body carries no usable `updatedIds` — the
# write may well have landed but we cannot say for WHICH rows, which is a
# different problem from a clean transport failure: record it as
# `unattributable_response` rather than inferring success from a missing field.
# `landed` in compute-run-summary.sh does not include that outcome, so those
# rows show up as attempted-but-not-landed and surface loudly.
#
# Returns 0 when it wrote the ledger, 1 when the caller must fall back to
# whole-array classification (any non-bulk-PUT, or a status we cannot read a
# row report from).
write_credit_request_result_per_row() {
    local method="$1" path="$2" body="${3:-}" http_status="$4" response_body="${5:-}"
    # Transport telemetry travels with every row this writer emits, so the
    # bulk-PUT path keeps the preconnect-retry evidence the whole-array
    # classification used to carry.
    local transport_attempts="${6:-}" transport_retry_exits="${7:-[]}"

    [[ "$path" == /admin/credit-requests* ]] || return 1
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "PUT" ]] || return 1
    [[ "$http_status" == "200" || "$http_status" == "409" ]] || return 1

    local attempted
    attempted=$(printf '%s' "$body" | jq -c 'select((.requestIds | type) == "array") | .requestIds' 2>/dev/null || true)
    [[ -n "$attempted" ]] || return 1
    [[ "$(printf '%s' "$attempted" | jq 'length')" -gt 0 ]] || return 1

    local intended_status
    intended_status=$(printf '%s' "$body" | jq -r '.status // ""' 2>/dev/null || echo '')

    # A success nests the report under .data; the error handler spreads it
    # across the top level. Both shapes, same field. (Mirrors the parse in
    # apply-verdicts.sh — the two must never disagree about what
    # "attributable" means.)
    local updated
    updated=$(printf '%s' "$response_body" | jq -c '
        (if type == "object" then (if has("data") then .data else . end) else null end)
        | select(type == "object" and (.updatedIds | type) == "array")
        | .updatedIds' 2>/dev/null || true)

    if [[ -z "$updated" ]]; then
        write_credit_request_result "$method" "$path" "$body" \
            "unattributable_response" "$http_status" "$response_body" \
            "$transport_attempts" "$transport_retry_exits"
        return 0
    fi

    local landed refused
    # Intersection in $attempted order; `-` is safe here because ids are unique.
    landed=$(jq -nc --argjson a "$attempted" --argjson u "$updated" '$a - ($a - $u)')
    refused=$(jq -nc --argjson a "$attempted" --argjson u "$updated" '$a - $u')

    if [[ "$(printf '%s' "$landed" | jq 'length')" -gt 0 ]]; then
        write_credit_request_result "$method" "$path" \
            "$(jq -nc --argjson ids "$landed" --arg st "$intended_status" '{requestIds:$ids, status:$st}')" \
            "ok" "$http_status" "" \
            "$transport_attempts" "$transport_retry_exits"
    fi
    if [[ "$(printf '%s' "$refused" | jq 'length')" -gt 0 ]]; then
        write_credit_request_result "$method" "$path" \
            "$(jq -nc --argjson ids "$refused" --arg st "$intended_status" '{requestIds:$ids, status:$st}')" \
            "http_error" "$http_status" "$response_body" \
            "$transport_attempts" "$transport_retry_exits"
    fi
    return 0
}

# Persist fraud routing BEFORE the HTTP request. Fraud-routed rows use the
# ordinary user_verification_needed DB status, so a timeout or post-commit 5xx
# would otherwise erase the only durable fact that automation must never
# reverse. Failure to write this marker refuses the API call.
record_fraud_uvn_attempt() {
    local method="$1" path="$2" body="${3:-}"
    [[ "${OPS_FLAG_REASON:-}" == "fraud_multifactor" ]] || return 0
    [[ "$path" == /admin/credit-requests* ]] || return 0

    local method_uc intended_status request_ids
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in PUT|PATCH) ;; *) return 0 ;; esac
    intended_status=$(printf '%s' "$body" | jq -r '.status // ""' 2>/dev/null || true)
    [[ "$intended_status" == "user_verification_needed" ]] || return 0

    if [[ "$method_uc" == "PUT" ]]; then
        request_ids=$(printf '%s' "$body" | jq -ce '
            .requestIds
            | select(type == "array" and length > 0)
            | select(all(.[]; type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")))
        ' 2>/dev/null) || {
            echo "ERROR: refusing fraud UVN write with missing or invalid requestIds" >&2
            return 1
        }
    else
        local request_id
        request_id="${path#/admin/credit-requests/}"
        request_id="${request_id%%\?*}"
        if [[ ! "$request_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "ERROR: refusing fraud UVN write with invalid request ID" >&2
            return 1
        fi
        request_ids=$(jq -n -c --arg id "$request_id" '[$id]') || return 1
    fi

    local line
    line=$(jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg run_id "${OPS_RUN_ID:-${RUN_ID:-}}" \
        --arg method "$method_uc" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --argjson request_ids "$request_ids" \
        '{
            ts:$ts,
            run_id:(if $run_id == "" then null else $run_id end),
            method:$method,
            path:$path,
            request_ids:$request_ids,
            intended_status:"user_verification_needed",
            outcome:"attempt_started",
            flag_reason:"fraud_multifactor",
            requester:(if $requester == "" then null else $requester end)
        }' 2>/dev/null) || {
            echo "ERROR: could not build durable fraud UVN attempt marker" >&2
            return 1
        }

    if ! mkdir -p "$(dirname "$FRAUD_UVN_ATTEMPT_PATH")" 2>/dev/null \
       || ! { exec 7>"${FRAUD_UVN_ATTEMPT_PATH}.lock"; } 2>/dev/null \
       || ! flock -w 10 7; then
        echo "ERROR: durable fraud UVN attempt marker unavailable at ${FRAUD_UVN_ATTEMPT_PATH}; refusing API write" >&2
        return 1
    fi
    # A successful write(2) is not durable enough for this guard: a host crash
    # after the remote commit could discard page cache and recreate an unmarked
    # fraud UVN. fsync both the file and parent directory before curl is allowed.
    if ! python3 -c '
import os
import sys

path, line = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
try:
    payload = (line + "\n").encode("utf-8")
    written = os.write(fd, payload)
    if written != len(payload):
        raise OSError(f"short fraud marker write: {written}/{len(payload)}")
    os.fsync(fd)
finally:
    os.close(fd)
dir_fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
' "$FRAUD_UVN_ATTEMPT_PATH" "$line"; then
        flock -u 7 || true
        exec 7>&-
        echo "ERROR: fraud UVN marker fsync failed at ${FRAUD_UVN_ATTEMPT_PATH}; refusing API write" >&2
        return 1
    fi
    flock -u 7
    exec 7>&-
    return 0
}

# --- Slack ID → Email mapping ---
# Maps Slack user IDs to muso.ai emails for the Requester header.
# The backend uses this to know which human initiated admin actions.
# Using case statement (bash 3.2 on macOS doesn't support declare -A).

resolve_slack_to_email() {
    local input="$1"
    # If it already looks like an email, return as-is
    if [[ "$input" == *@* ]]; then
        echo "$input"
        return 0
    fi
    # Synthetic identities (bot self-identifies as 'clio' in count-approvals
    # and elsewhere). Recognize them explicitly so they don't trip the
    # unknown-input return-1 path below — which under `set -e` would silently
    # exit the caller's command-substitution and abort the script.
    case "$input" in
        clio)
            echo "clio"
            return 0
            ;;
    esac
    # Resolve Slack ID to email
    case "$input" in
        U7RP6HKUZ)   echo "aaron@muso.ai" ;;   # Aaron Kaufman (CEO)
        U038BM16T7W) echo "jan@muso.ai" ;;     # Jan Delmo (Head of Operations) — NOT jay@
        U0AL36NADEY) echo "nick@muso.ai" ;;    # Nicholas Sollazzo (Chief Agent Officer)
        U0A8CCTTAAG) echo "liza@muso.ai" ;;    # Liza Basco (Accountant)
        U03LP8YHLPK) echo "mariia@muso.ai" ;;  # Mariia Bubley (Head of Product / UI & UX)
        U02N2NP3H7F) echo "artem@muso.ai" ;;   # Artem (Mobile Developer)
        U0AV9C7CFRQ) echo "faith@muso.ai" ;;   # Faith Undie (Community & Social Media)
        U02S7C96CGN) echo "f@muso.ai" ;;       # McLaren Amberti (Sales Ops) — NOT mclaren@, single letter f
        *)
            # Unknown Slack ID — return as-is
            echo "$input"
            return 1
            ;;
    esac
    return 0
}

# --- Helpers ---

die() { echo "ERROR: $*" >&2; exit 1; }

# Per-automation admin identity. An automation sets MUSO_ADMIN_IDENTITY in its
# own process (credit-trust-decide: credit-decider = agent-credit-decider@muso.ai,
# uvn-under30: uvn-cron = agent-uvn-cron@muso.ai; core-backend binds each
# automation's grant to that account, T12 / core #10595) and
# logs in with that identity's credentials, read from
# $MUSO_ADMIN_IDENTITY_DIR/<identity>.env, with a token cache of its own. The
# file is PARSED (MUSO_ADMIN_EMAIL= / MUSO_ADMIN_PASSWORD= lines), never
# sourced, so nothing in it executes. There is no fallback: an unknown
# identity or a missing/incomplete file fails before any request.
# The directory is the one H-DevOps' sync-credit-agent-creds-from-vault.sh
# provisions from Vault (contract: H-DevOps #4131,
# data/security-backlog-s2/credit-agent-accounts.md).
MUSO_ADMIN_IDENTITY_DIR="${MUSO_ADMIN_IDENTITY_DIR:-/etc/openclaw/agents}"
load_admin_identity() {
    local identity="${MUSO_ADMIN_IDENTITY:-}"
    [[ -n "$identity" ]] || return 0
    case "$identity" in
        # fable = agent-fable@muso.ai: the L12 executor's APPROVALS only (core binds fable-decider approvals to
        # Fable's own account; the decider's account writes the anchor records, so the two never coincide).
        # scale-drain = agent-scale-drain@muso.ai: the verification drain's precedent approvals only (core binds
        # verification-scale-drain to that account and to no other; core-backend #11378 / #11379).
        credit-decider|uvn-cron|fable|scale-drain) ;;
        *) die "MUSO_ADMIN_IDENTITY '$identity' is not a known automation identity (credit-decider, uvn-cron, fable, scale-drain)" ;;
    esac
    local file="$MUSO_ADMIN_IDENTITY_DIR/$identity.env"
    [[ -f "$file" && -r "$file" ]] || die "admin identity '$identity': $file is missing or unreadable (no fallback)"
    local line key value email="" password=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || die "admin identity '$identity': malformed line in $file"
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        case "$key" in
            MUSO_ADMIN_EMAIL) email="$value" ;;
            MUSO_ADMIN_PASSWORD) password="$value" ;;
        esac
    done < "$file"
    [[ -n "$email" && -n "$password" ]] || die "admin identity '$identity': $file needs MUSO_ADMIN_EMAIL and MUSO_ADMIN_PASSWORD"
    MUSO_ADMIN_EMAIL="$email"
    MUSO_ADMIN_PASSWORD="$password"
    TOKEN_CACHE="${TOKEN_CACHE}.${identity}"
}

check_env() {
    [[ -n "${MUSO_API_URL:-}" ]] || die "MUSO_API_URL not set"
    [[ -n "${MUSO_ADMIN_EMAIL:-}" ]] || die "MUSO_ADMIN_EMAIL not set"
    [[ -n "${MUSO_ADMIN_PASSWORD:-}" ]] || die "MUSO_ADMIN_PASSWORD not set"
}

# Run curl with the opt-in pre-connect retry policy used by the Lobster bulk
# PUT path. Results are returned through CURL_RETRY_* globals so callers can
# preserve curl's exit code and emit their own domain-specific envelope.
CURL_RETRY_RESPONSE=""
CURL_RETRY_RC=0
CURL_RETRY_ATTEMPTS=0
CURL_RETRY_EXITS='[]'
run_curl_with_preconnect_retry() {
    local max_preconnect_retries="${MUSO_ADMIN_PRECONNECT_RETRIES:-0}"
    local retry_delay_seconds="${MUSO_ADMIN_RETRY_DELAY_SECONDS:-2}"

    CURL_RETRY_RESPONSE=""
    CURL_RETRY_RC=0
    CURL_RETRY_ATTEMPTS=0
    CURL_RETRY_EXITS='[]'

    if ! [[ "$max_preconnect_retries" =~ ^[01]$ ]]; then
        echo "muso-admin-api: MUSO_ADMIN_PRECONNECT_RETRIES must be 0 or 1" >&2
        CURL_RETRY_RC=2
        return 2
    fi
    if ! [[ "$retry_delay_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "muso-admin-api: MUSO_ADMIN_RETRY_DELAY_SECONDS must be a non-negative number" >&2
        CURL_RETRY_RC=2
        return 2
    fi

    while true; do
        CURL_RETRY_ATTEMPTS=$((CURL_RETRY_ATTEMPTS + 1))
        if CURL_RETRY_RESPONSE=$("$@"); then
            CURL_RETRY_RC=0
            return 0
        else
            CURL_RETRY_RC=$?
        fi

        case "$CURL_RETRY_RC" in
            5|6|7)
                if (( CURL_RETRY_ATTEMPTS <= max_preconnect_retries )); then
                    CURL_RETRY_EXITS=$(jq -nc \
                        --argjson exits "$CURL_RETRY_EXITS" \
                        --argjson rc "$CURL_RETRY_RC" \
                        '$exits + [$rc]')
                    if [[ "$retry_delay_seconds" != "0" ]]; then
                        sleep "$retry_delay_seconds"
                    fi
                    continue
                fi
                ;;
        esac
        return "$CURL_RETRY_RC"
    done
}

is_curl_transport_exit() {
    case "$1" in
        5|6|7|18|28|35|52|55|56|60) return 0 ;;
        *) return 1 ;;
    esac
}

get_token() {
    # A batch resolves the token ONCE (call-batch sets TOKEN_MEMO); every item in the
    # batch reuses it instead of re-reading the cache or logging in per request.
    if [[ -n "${TOKEN_MEMO:-}" ]]; then
        printf '%s\n' "$TOKEN_MEMO"
        return 0
    fi
    # Return cached token if fresh
    if [[ -f "$TOKEN_CACHE" ]]; then
        local cached_time
        cached_time=$(head -1 "$TOKEN_CACHE")
        local now
        now=$(date +%s)
        if (( now - cached_time < TOKEN_MAX_AGE )); then
            tail -1 "$TOKEN_CACHE"
            return 0
        fi
    fi

    # Login and cache
    local resp login_rc
    if run_curl_with_preconnect_retry curl -sf -X POST "${MUSO_API_URL}/admin/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${MUSO_ADMIN_EMAIL}\",\"password\":\"${MUSO_ADMIN_PASSWORD}\"}"; then
        resp="$CURL_RETRY_RESPONSE"
    else
        login_rc="$CURL_RETRY_RC"
        echo "ERROR: Login failed: curl_exit_${login_rc}" >&2
        if is_curl_transport_exit "$login_rc"; then
            jq -nc \
                --argjson rc "$login_rc" \
                --argjson attempts "$CURL_RETRY_ATTEMPTS" \
                --argjson retry_exits "$CURL_RETRY_EXITS" \
                '{http_status:null, body:null,
                  transport_error:{stage:"login", curl_exit:$rc, attempts:$attempts, retry_exits:$retry_exits}}'
        fi
        return "$login_rc"
    fi

    local token
    token=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('authentication',{}).get('accessToken','') or d.get('data',{}).get('user',{}).get('accessToken','') or d.get('token',''))")
    [[ -n "$token" ]] || die "No token in login response"

    echo "$(date +%s)" > "$TOKEN_CACHE"
    echo "$token" >> "$TOKEN_CACHE"
    chmod 600 "$TOKEN_CACHE"
    echo "$token"
}

# --- Commands ---

cmd_login() {
    check_env
    local token token_rc
    if token=$(get_token); then
        token_rc=0
    else
        token_rc=$?
    fi
    if (( token_rc != 0 )); then
        [[ -n "$token" ]] && printf '%s\n' "$token"
        return "$token_rc"
    fi
    echo "OK: Token acquired (${#token} chars). Cached at $TOKEN_CACHE"
}

# --- Credit approve gate (deterministic, session-log-based) ---
# Blocks autonomous PUT /admin/credit-requests status=approved unless the active
# openclaw session log shows >=CV_REQUIRED_LOADS distinct Tier 1 pages that were:
#   (a) loaded via the `browser` tool (NOT web_fetch/web_search/anything else), and
#   (b) whose `toolResult.content[0].text` contains --evidence-excerpt as a
#       literal substring (case-insensitive).
# Bypassed for human-initiated approves (--requester set to non-clio identity).
#
# This exists because openclaw's before_tool_call plugin hook does NOT fire
# reliably on exec calls in YOLO mode (tools.exec.security=full, ask=off).
# The bash layer sees 100% of admin API traffic; plugins do not.

# Hosts that count toward the >=CV_REQUIRED_LOADS browse-quorum for an approve.
# Must match lib/browser-evidence.sh:67 in muso-ops-credit-verification — the
# dispatcher already filters by that regex, so this gate is a backstop and
# strictly cannot count more hosts than the dispatcher does.
CV_TIER1_HOSTS='music\.apple\.com|musicbrainz\.org|discogs\.com|allmusic\.com'
# Hosts where web_fetch is JS-shell-only and substituting it for browser
# always produces empty/wrong evidence — every Tier-1 web_fetch refuses the
# approve. Superset of CV_TIER1_HOSTS: Tidal's track/album SPAs are also
# JS-rendered, even though Tidal is Tier-2 for the browse-quorum (it's only
# used as a backend album-credits URL, not as a free-form quorum host).
CV_TIER1_WEBFETCH_BLOCKED='music\.apple\.com|musicbrainz\.org|discogs\.com|allmusic\.com|tidal\.com'
CV_REQUIRED_LOADS="${CV_REQUIRED_LOADS:-2}"
if ! [[ "$CV_REQUIRED_LOADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "FATAL: CV_REQUIRED_LOADS must be a positive integer (got '${CV_REQUIRED_LOADS}')" >&2
    exit 1
fi
CV_SESSION_MAX_AGE_MIN="${CV_SESSION_MAX_AGE_MIN:-10}"
CV_EVIDENCE_EXCERPT_MIN="${CV_EVIDENCE_EXCERPT_MIN:-8}"
CV_EVIDENCE_EXCERPT_MAX="${CV_EVIDENCE_EXCERPT_MAX:-200}"

# Evidence mode: which library decides whether the excerpt is grounded.
#   api     (default) — count distinct API-helper sources + AllMusic browser
#                       fallback (+ stubbed web_search citations) via
#                       lib/api-evidence.sh. The post-Cloudflare default.
#   browser           — count distinct Tier-1 browser loads via the legacy
#                       lib/browser-evidence.sh path. Kept as an emergency
#                       rollback knob; flip via env if api-mode misfires.
#   both              — accept on EITHER library reaching CV_REQUIRED_LOADS.
#                       Useful for one validation cycle when transitioning;
#                       not a steady-state mode.
CV_EVIDENCE_MODE="${CV_EVIDENCE_MODE:-api}"
case "$CV_EVIDENCE_MODE" in
    api|browser|both) ;;
    *)
        echo "FATAL: CV_EVIDENCE_MODE must be one of api|browser|both (got '${CV_EVIDENCE_MODE}')" >&2
        exit 1
        ;;
esac

# --- Tier-0 thresholds (must mirror profile-audit.sh defaults) -------------
# Defense-in-depth: even if profile-audit.sh is compromised or its receipt
# forged, the gate independently re-fetches the same admin-API surfaces and
# recomputes the 8 gates from live data. Threshold env-var names are shared
# so a single override flips both producer + verifier in lock-step.
CV_TIER0_MIN_BATCH="${CV_TIER0_MIN_BATCH:-20}"
CV_TIER0_MIN_CC="${CV_TIER0_MIN_CC:-100}"
CV_TIER0_MIN_POP="${CV_TIER0_MIN_POP:-50}"
CV_TIER0_MIN_INDUSTRY="${CV_TIER0_MIN_INDUSTRY:-0.70}"
CV_TIER0_MIN_ONLY_VEL="${CV_TIER0_MIN_ONLY_VEL:-0.70}"
CV_TIER0_MIN_ARTIST_OVERLAP="${CV_TIER0_MIN_ARTIST_OVERLAP:-0.40}"
CV_TIER0_MIN_LABEL_OVERLAP="${CV_TIER0_MIN_LABEL_OVERLAP:-0.30}"
# Popularity drifts (e.g. Spotify recomputes daily). Allow a ±5% delta
# between the receipt's recorded value and the live re-fetch before
# rejecting on cc/pop mismatch.
CV_TIER0_POP_TOLERANCE_FRAC="${CV_TIER0_POP_TOLERANCE_FRAC:-0.05}"

# Emit a tier0_* runlog event. Best-effort; mirrors profile-audit.sh.
# Disables CV verdict + cookie-cutter gates inside runlog.sh because tier0
# events are upstream of the browser path and intentionally repetitive.
_tier0_emit_event() {
    local name="$1" payload="$2"
    if [[ -z "${OPS_RUNLOG_DIR:-}" || -z "${OPS_RUN_ID:-}" ]]; then
        return 0
    fi
    local runlog_sh="${RUNLOG_SH:-}"
    if [[ -z "$runlog_sh" ]]; then
        # Same workspace layout as profile-audit.sh
        runlog_sh="${SCRIPT_DIR}/../../muso-ops-credit-verification/scripts/runlog.sh"
    fi
    if [[ ! -x "$runlog_sh" && ! -f "$runlog_sh" ]]; then
        return 0
    fi
    CV_DISABLE_VERDICT_GATE=1 CV_DISABLE_COOKIE_CUTTER_GATE=1 \
        bash "$runlog_sh" event "$OPS_RUN_ID" "$name" "$payload" \
        >/dev/null 2>&1 || true
}

# Parse `profile_audit:k=v,k=v,...` receipts. Echo a JSON object on success;
# return 1 on parse failure (no `profile_audit:` prefix or no kv pairs).
_tier0_parse_receipt() {
    local excerpt="$1"
    [[ "$excerpt" == profile_audit:* ]] || return 1
    local payload="${excerpt#profile_audit:}"
    [[ -n "$payload" ]] || return 1
    printf '%s' "$payload" | jq -R -s -c '
        split(",")
        | map(select(length > 0))
        | map(split("=") | select(length == 2) | {(.[0]): .[1]})
        | add // {}'
}

# Tier-0 evidence path: receipt looks like
#   profile_audit:cc=694,pop=68,batch=50,industry=0.96,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.56,lbl=0.46
# Re-runs the 8 gates against LIVE admin-API data and accepts only if all
# 8 still pass. Returns 0 on accept, 1 on reject (with stderr explanation +
# tier0_audit_rejected_by_gate runlog event).
_tier0_audit_recompute_gate() {
    local excerpt="$1"
    local pid="${PROFILE_AUDIT_ID:-}"
    local admin_api_script="${ADMIN_API_SCRIPT:-${BASH_SOURCE[0]}}"

    if [[ -z "$pid" ]]; then
        echo "credit_approve_gate: profile_audit: receipt requires --profile-audit-id <profile_id> so the gate can re-verify against live data." >&2
        _tier0_emit_event tier0_audit_rejected_by_gate \
            "$(jq -n -c --arg r "$excerpt" '{reason:"missing_profile_audit_id", receipt:$r}')"
        return 1
    fi

    local kv
    kv="$(_tier0_parse_receipt "$excerpt")" || {
        echo "credit_approve_gate: malformed profile_audit: receipt (no parsable k=v pairs)." >&2
        _tier0_emit_event tier0_audit_rejected_by_gate \
            "$(jq -n -c --arg r "$excerpt" --arg pid "$pid" \
                '{profile_id:$pid, reason:"malformed_receipt", receipt:$r}')"
        return 1
    }

    # Pull receipt-claimed values used for receipt-vs-live cross-check.
    # Only cc + pop are cross-checked (cc exact, pop within tolerance).
    # The other receipt fields (batch/industry/only_vel/art/lbl/br_max/roles_ok)
    # are informational; the gate re-runs all 8 gates on live data, so the
    # live recompute is authoritative for those.
    local r_cc r_pop
    r_cc="$(jq -r '.cc // ""' <<<"$kv")"
    r_pop="$(jq -r '.pop // ""' <<<"$kv")"

    _t0_reject() {
        local reason="$1" extra_json="${2:-{\}}"
        echo "credit_approve_gate: tier0_audit_rejected_by_gate.${reason} for profile $pid" >&2
        _tier0_emit_event tier0_audit_rejected_by_gate \
            "$(jq -n -c \
                --arg pid "$pid" \
                --arg r "$excerpt" \
                --arg reason "$reason" \
                --argjson extra "$extra_json" \
                '{profile_id:$pid, receipt:$r, reason:$reason} + $extra')"
        return 1
    }

    # --- Step 1: live profile (uses cc + pop from a credit row, same as
    # the audit script). Pull the unverified queue.
    local unv_resp unv_http
    unv_resp=$(bash "$admin_api_script" call GET "/admin/credit-requests?profilesIds=$pid&status=unverified&limit=1000" 2>/dev/null) || {
        _t0_reject "admin_api_unverified_failed"; return 1; }
    unv_http=$(jq -r '.http_status // "unknown"' <<<"$unv_resp" 2>/dev/null || echo unknown)
    if [[ "$unv_http" != "200" ]]; then
        _t0_reject "profile_not_found_or_admin_error" \
            "$(jq -n -c --arg s "$unv_http" '{http_status:$s}')"
        return 1
    fi

    local unv_items unv_count
    unv_items=$(jq -c '.body.data.items // []' <<<"$unv_resp")
    unv_count=$(jq 'length' <<<"$unv_items")

    # G0: minimum batch size
    if (( unv_count < CV_TIER0_MIN_BATCH )); then
        _t0_reject "g0_low_volume" \
            "$(jq -n -c --argjson n "$unv_count" --argjson min "$CV_TIER0_MIN_BATCH" \
                '{unverified_count:$n, min_batch:$min}')"
        return 1
    fi

    # Pull live cc + pop (fail-closed if both null)
    local live_cc live_pop
    live_cc=$(jq -r '.[0].profile.creditCount // 0' <<<"$unv_items")
    live_pop=$(jq -r '.[0].profile.popularity // 0' <<<"$unv_items")
    live_cc=${live_cc:-0}
    live_pop=${live_pop:-0}

    # Receipt-vs-live cross-check (defense-in-depth: forged receipt detection).
    # cc must match exactly; pop allowed to drift within tolerance.
    if [[ -n "$r_cc" ]] && [[ "$r_cc" != "$live_cc" ]]; then
        _t0_reject "cc_mismatch" \
            "$(jq -n -c --arg rcc "$r_cc" --argjson lcc "$live_cc" \
                '{receipt_cc:$rcc, live_cc:$lcc}')"
        return 1
    fi
    if [[ -n "$r_pop" ]]; then
        # |live_pop - r_pop| / max(r_pop, 1) <= tolerance
        local pop_ok
        pop_ok=$(awk -v r="$r_pop" -v l="$live_pop" -v tol="$CV_TIER0_POP_TOLERANCE_FRAC" 'BEGIN{
            denom = (r > 0) ? r : 1;
            d = (l - r); if (d < 0) d = -d;
            print (d / denom <= tol) ? "1" : "0";
        }')
        if [[ "$pop_ok" != "1" ]]; then
            _t0_reject "pop_mismatch" \
                "$(jq -n -c --arg rpop "$r_pop" --argjson lpop "$live_pop" --arg tol "$CV_TIER0_POP_TOLERANCE_FRAC" \
                    '{receipt_pop:$rpop, live_pop:$lpop, tolerance_frac:$tol}')"
            return 1
        fi
    fi

    # G1 / G2: live cc + pop thresholds
    if (( live_cc < CV_TIER0_MIN_CC )); then
        _t0_reject "g1_creditCount" \
            "$(jq -n -c --argjson lcc "$live_cc" --argjson min "$CV_TIER0_MIN_CC" \
                '{live_cc:$lcc, threshold:$min}')"
        return 1
    fi
    if (( live_pop < CV_TIER0_MIN_POP )); then
        _t0_reject "g2_popularity" \
            "$(jq -n -c --argjson lpop "$live_pop" --argjson min "$CV_TIER0_MIN_POP" \
                '{live_pop:$lpop, threshold:$min}')"
        return 1
    fi

    # Compute facts on unverified
    local facts_unv
    facts_unv=$(jq -c '
        def only_velocity:
            (.verificationData.rule_risk_percent // {}) as $r
            | (($r.reject_high_velocity_profile // 0) > 0)
              and
              ([
                  $r | to_entries[]
                  | select(.key | startswith("reject_"))
                  | select(.key != "reject_high_velocity_profile")
                  | select((.value // 0) > 0)
              ] | length == 0);
        def role_set: (.credits // []) | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""));
        {
            count: length,
            industry_count: ([.[] | select((.metadata.source // "") == "industry")] | length),
            only_velocity_count: ([.[] | select(only_velocity)] | length),
            max_breadth: ([.[] | (.credits // []) | length] | max // 0),
            roles_set: ([.[] | role_set[]] | unique),
            labels_per_credit: [.[] | (.metadata.label // "" | ascii_downcase | gsub("^\\s+|\\s+$"; ""))],
            artists_per_credit: [.[] | (.spotifyTrackArtists // []) | map(.name // "" | ascii_downcase | gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))]
        }' <<<"$unv_items")

    local industry_frac only_vel_frac unv_max_breadth
    industry_frac=$(jq -r 'if .count == 0 then 0 else (.industry_count / .count) end' <<<"$facts_unv")
    only_vel_frac=$(jq -r 'if .count == 0 then 0 else (.only_velocity_count / .count) end' <<<"$facts_unv")
    unv_max_breadth=$(jq -r '.max_breadth' <<<"$facts_unv")

    # Float-compare helper (bash arithmetic is integer only)
    _t0_fcmp() {
        awk -v l="$1" -v r="$3" -v op="$2" 'BEGIN{
            if (op==">=") exit (l >= r) ? 0 : 1;
            if (op==">")  exit (l >  r) ? 0 : 1;
            exit 2;
        }'
    }

    # G3 / G4
    if ! _t0_fcmp "$industry_frac" ">=" "$CV_TIER0_MIN_INDUSTRY"; then
        _t0_reject "g3_industry_fraction" \
            "$(jq -n -c --arg actual "$industry_frac" --arg t "$CV_TIER0_MIN_INDUSTRY" \
                '{actual:$actual, threshold:$t}')"
        return 1
    fi
    if ! _t0_fcmp "$only_vel_frac" ">=" "$CV_TIER0_MIN_ONLY_VEL"; then
        _t0_reject "g4_only_velocity_fraction" \
            "$(jq -n -c --arg actual "$only_vel_frac" --arg t "$CV_TIER0_MIN_ONLY_VEL" \
                '{actual:$actual, threshold:$t}')"
        return 1
    fi

    # Approved corpus
    local ap_resp ap_http ap_items ap_count
    ap_resp=$(bash "$admin_api_script" call GET "/admin/credit-requests?profilesIds=$pid&status=approved&limit=1000" 2>/dev/null) || {
        _t0_reject "admin_api_approved_failed"; return 1; }
    ap_http=$(jq -r '.http_status // "unknown"' <<<"$ap_resp" 2>/dev/null || echo unknown)
    if [[ "$ap_http" != "200" ]]; then
        _t0_reject "approved_corpus_admin_error" \
            "$(jq -n -c --arg s "$ap_http" '{http_status:$s}')"
        return 1
    fi
    ap_items=$(jq -c '.body.data.items // []' <<<"$ap_resp")
    ap_count=$(jq 'length' <<<"$ap_items")

    if (( ap_count == 0 )); then
        _t0_reject "no_approved_corpus" "$(jq -n -c '{}')"
        return 1
    fi

    local facts_ap
    facts_ap=$(jq -c '
        def role_set: (.credits // []) | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""));
        {
            count: length,
            max_breadth: ([.[] | (.credits // []) | length] | max // 0),
            roles_set: ([.[] | role_set[]] | unique),
            labels: ([.[] | .metadata.label // empty] | map(ascii_downcase) | unique),
            artist_names: ([.[] | (.spotifyTrackArtists // [])[] | .name // "" | ascii_downcase | gsub("^\\s+|\\s+$"; "")] | map(select(. != "")) | unique)
        }' <<<"$ap_items")

    local ap_max_breadth allow_breadth
    ap_max_breadth=$(jq -r '.max_breadth' <<<"$facts_ap")
    allow_breadth=$(( ap_max_breadth + 1 ))

    # G5: profile-relative breadth
    if (( unv_max_breadth > allow_breadth )); then
        _t0_reject "g5_breadth" \
            "$(jq -n -c --argjson u "$unv_max_breadth" --argjson a "$ap_max_breadth" \
                '{unv_max_breadth:$u, ap_max_breadth:$a}')"
        return 1
    fi

    # G6: roles ⊆ approved roles
    local roles_ok
    roles_ok=$(jq -n -c \
        --argjson unv "$facts_unv" \
        --argjson ap "$facts_ap" '
        ($unv.roles_set - $ap.roles_set) as $extra
        | {ok: ($extra | length == 0), extra: $extra}')
    if [[ "$(jq -r '.ok' <<<"$roles_ok")" != "true" ]]; then
        local extras
        extras=$(jq -c '.extra' <<<"$roles_ok")
        _t0_reject "g6_role_subset" \
            "$(jq -n -c --argjson e "$extras" '{extra_roles:$e}')"
        return 1
    fi

    # G7: artist overlap
    local artist_overlap
    artist_overlap=$(jq -n -r \
        --argjson unv "$facts_unv" \
        --argjson ap "$facts_ap" '
        ($ap.artist_names) as $set
        | ($unv.artists_per_credit) as $per
        | if ($per | length) == 0 then 0
          else
              ([$per[] | select(any(.[]; . as $n | $set | index($n) != null))] | length) / ($per | length)
          end')
    if ! _t0_fcmp "$artist_overlap" ">=" "$CV_TIER0_MIN_ARTIST_OVERLAP"; then
        _t0_reject "g7_artist_overlap" \
            "$(jq -n -c --arg actual "$artist_overlap" --arg t "$CV_TIER0_MIN_ARTIST_OVERLAP" \
                '{actual:$actual, threshold:$t}')"
        return 1
    fi

    # G8: label overlap
    local label_overlap
    label_overlap=$(jq -n -r \
        --argjson unv "$facts_unv" \
        --argjson ap "$facts_ap" '
        ($ap.labels | map(select(. != null and . != ""))) as $labelset
        | ($unv.labels_per_credit) as $per
        | if ($per | length) == 0 then 0
          else
              ([$per[] | . as $cur | select($cur != "" and ($labelset | index($cur) != null))] | length) / ($per | length)
          end')
    if ! _t0_fcmp "$label_overlap" ">=" "$CV_TIER0_MIN_LABEL_OVERLAP"; then
        _t0_reject "g8_label_overlap" \
            "$(jq -n -c --arg actual "$label_overlap" --arg t "$CV_TIER0_MIN_LABEL_OVERLAP" \
                '{actual:$actual, threshold:$t}')"
        return 1
    fi

    # All 8 gates passed live. Note: profile-audit.sh already emits
    # tier0_audit_passed when it produced the receipt, so to avoid event-name
    # collision the gate emits tier0_audit_verified — "the gate independently
    # re-verified the receipt against live data and agreed."
    _tier0_emit_event tier0_audit_verified \
        "$(jq -n -c \
            --arg pid "$pid" \
            --arg r "$excerpt" \
            --argjson lcc "$live_cc" \
            --argjson lpop "$live_pop" \
            --argjson batch "$unv_count" \
            --arg industry "$industry_frac" \
            --arg only_vel "$only_vel_frac" \
            --argjson unv_breadth "$unv_max_breadth" \
            --argjson ap_breadth "$ap_max_breadth" \
            --arg art "$artist_overlap" \
            --arg lbl "$label_overlap" \
            '{profile_id:$pid, receipt:$r, live_cc:$lcc, live_pop:$lpop, batch:$batch,
              industry:$industry, only_velocity:$only_vel,
              unverified_max_breadth:$unv_breadth, approved_max_breadth:$ap_breadth,
              artist_overlap:$art, label_overlap:$lbl}')"
    echo "credit_approve_gate: tier0_audit_verified for profile $pid (8/8 gates pass live)" >&2
    return 0
}

is_uvn_popularity_cron_approval() {
    local method="$1" path="$2" body="$3"

    # Standing authorization for the deterministic under-30 cron. Keep this
    # narrower than the ordinary approve surface: the dedicated service
    # identity must opt in, use the conditional endpoint, transition only
    # UVN -> approved, and submit one unique UUID batch no larger than the
    # cron's own 50-row chunk. Any near miss falls through to the normal
    # evidence gate below.
    [[ "${UVN_POPULARITY_CRON:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "uvn-popularity-cron@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1

    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "approved"
        and .expectedStatus == "user_verification_needed"
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 50
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1
}

# Standing authorization for the trust-yet-verify decider (credit-review.py
# decide --mode apply, cron credit-trust-decide-15m; captain 2026-10-15 ~22:12Z
# "i want AI live now ... trust yet verify approach"). Same narrow shape as the
# UVN cron above, for the unverified -> approved transition, PLUS a write-
# boundary re-check of the registry: if policies/credit-approval-automation.json
# does not carry credit-trust-decide approved:true with approved_by and
# approval_ref, nothing is approved even when the cron is enabled. The server
# (agentApprovalGuard) still refuses any row with a validator conflict.
CREDIT_APPROVAL_REGISTRY="${CREDIT_APPROVAL_REGISTRY:-${HYDRA_ROOT:-/opt/hydra}/policies/credit-approval-automation.json}"
is_credit_trust_decide_approval() {
    local method="$1" path="$2" body="$3"
    [[ "${CREDIT_TRUST_DECIDE:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "credit-trust-decide@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1
    jq -e '.automations["credit-trust-decide"]
           | .approved == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$CREDIT_APPROVAL_REGISTRY" >/dev/null 2>&1 || {
        echo "credit_approve_gate: credit-trust-decide is not approved in $CREDIT_APPROVAL_REGISTRY - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "approved"
        and .expectedStatus == "unverified"
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 50
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1
}

# Standing authorization for credit-trust-score-approve (credit-review.py
# score-approve --mode apply; captain 2026-10-20 ~11:30Z "approve low risk
# credits"; Fable rulings ruling-score-approve-band-b-2026-10-20.md and steer 31,
# 2026-10-22). Its OWN requester, env flag and registry row, never the
# decider's. It executes the IDP validator's own APPROVE verdict, so its rows wait in
# user_verification_needed (the decider branch above refuses that expected
# status on purpose). core-backend binds the grant to X-Credit-Automation-Id
# credit-trust-score-approve on the decider's account (agentApprovalGuard
# AUTOMATION_APPROVAL_SCOPES) and re-checks every row; this branch only lets the
# exact conditional batch shape past the browser-evidence gate.
is_credit_trust_score_approval() {
    local method="$1" path="$2" body="$3"
    [[ "${CREDIT_TRUST_SCORE_APPROVE:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "credit-trust-score-approve@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1
    jq -e '.automations["credit-trust-score-approve"]
           | .approved == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$CREDIT_APPROVAL_REGISTRY" >/dev/null 2>&1 || {
        echo "credit_approve_gate: credit-trust-score-approve is not approved in $CREDIT_APPROVAL_REGISTRY - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "approved"
        and (.expectedStatus == "user_verification_needed" or .expectedStatus == "unverified")
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 50
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1
}

# The L12 executor's APPROVALS (executor PR 2; core FABLE_RULED scope #11010/#11011): the one agent shape past
# this gate for a validator-declined row. Fable's own login (MUSO_ADMIN_IDENTITY=fable = agent-fable@muso.ai),
# fable-decider requester + header, PUT conditional-status approved from unverified / user_verification_needed /
# rejected, <= 50 unique ids, a Fable ruling id, the registry entry approved with apply_enabled true, the kill file
# absent, and the same
# boundary re-check as the closes (verify_batch on a clean env, with the approve tray's guards). Core then admits
# only rows with a server-held anchor set (the UPDATE pins it); nothing here can widen that.
is_fable_decider_approval() {
    local method="$1" path="$2" body="$3"
    [[ "${FABLE_DECIDER:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "fable-decider@hydra-ops" ]] || return 1
    [[ "${MUSO_ADMIN_IDENTITY:-}" == "fable" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1
    if _fable_decider_killed; then
        return 1
    fi
    [[ "${FABLE_RULING_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:\|-]{2,120}$ ]] || {
        echo "fable_decider: FABLE_RULING_ID missing or malformed - refusing" >&2
        return 1
    }
    jq -e '.automations["fable-decider"]
           | .approved == true
             and .apply_enabled == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$CREDIT_APPROVAL_REGISTRY" >/dev/null 2>&1 || {
        echo "fable_decider: fable-decider is not approved with apply_enabled true in $CREDIT_APPROVAL_REGISTRY - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "approved"
        and (.expectedStatus == "unverified" or .expectedStatus == "user_verification_needed"
             or .expectedStatus == "rejected")
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 50
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1 || return 1
    [[ -n "${FABLE_DECIDER_RUN_ID:-}" && -n "${FABLE_DECIDER_TRAY:-}" ]] || {
        echo "fable_decider: FABLE_DECIDER_RUN_ID / FABLE_DECIDER_TRAY missing - refusing" >&2
        return 1
    }
    if ! fable_decider_verify_batch "$body"; then
        echo "fable_decider: boundary re-check refused the approval batch" >&2
        return 1
    fi
    return 0
}

# The verification scale drain's approve predicate (2026-11-11).
#
# The drain (scripts/credit_review/scale_drain.py) approves off a deterministic SQL
# ladder, not browser evidence, so the Tier-1 quorum checks below cannot be satisfied by
# it. It gets its OWN narrow predicate rather than the blanket
# CV_APPROVE_GATE_DISABLED bypass: that variable skips EVERY evidence requirement and
# must not be set by an agent, and a second bypass caller is exactly what we do not do.
#
# What this predicate checks, all of it, before returning 0:
#   * SCALE_DRAIN=1 and the drain's own requester identity (no other caller can borrow it)
#   * the kill file /etc/hydra/scale-drain.disabled
#   * the registry entry verification-scale-drain is approved, with approved_by and
#     approval_ref recorded (policies/credit-approval-automation.json)
#   * the body is exactly {requestIds, status:"approved"} with exactly ONE UUID (one
#     digest carries one anchor, so a second id would be a write nothing verified)
#   * the evidence excerpt is a well-formed drain digest naming an AUTO-APPROVABLE rule
#     and a row-specific anchor: drain-signal:<precedent|proof_verdict>;<reason>;v<n>;<anchor>,
#     where the anchor is the precedent request id (a UUID) or the proof id (a sha256
#     hex digest - scripts/credit_verify/proof/store.py:37). Both formats are accepted.
#     A digest naming ask/expired/duplicate is refused, so the drain can never approve a
#     row its ladder did not decide on evidence.
# The verifier and its interpreter path are derived from THIS FILE's location, never from
# the environment. HYDRA_ROOT and CREDIT_PROOF_STORE are caller-controlled: a caller who
# can invoke the wrapper can set them, so honouring them here would let a caller point the
# gate at a substitute verifier or a SQLite file it wrote itself. Walking up from the
# wrapper's own directory is not forgeable - you cannot invoke a different wrapper without
# invoking a different script, and the script you invoke is the one enforcing the gate.
#
# The walk starts from the wrapper's RESOLVED path. A symlink to the deployed wrapper,
# made in a tree the caller owns, has the caller's path in BASH_SOURCE: walking up from
# that found the caller's verifier and the caller's registry beside it.
scale_drain_root() {
    local self dir
    self="$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null)" || return 1
    dir="$(dirname "$self")"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/scripts/credit_review/verify_anchor.py" ]]; then
            printf '%s' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# The approval registry both drain predicates read: the deployed policy file, found from
# the wrapper's own location exactly as the verifier is. It was read from
# CREDIT_APPROVAL_REGISTRY / HYDRA_ROOT, so a caller could point the gate at an
# `approved: true` file it had written itself and "the captain recorded this decision"
# meant "the caller says so" (QA review 5 of hydra#1883).
#
# A caller value naming any OTHER file is REFUSED, not ignored: a redirect attempt must
# not read as a clean run. A value that resolves to the pinned file is not a redirect -
# this wrapper's other predicates still default that variable to the same deployed path.
# Prints the pinned path.
scale_drain_registry() {
    local root pinned claimed
    root="$(scale_drain_root)" || {
        echo "scale_drain: the deployed tree cannot be located from the wrapper - refusing" >&2
        return 1
    }
    pinned="$root/policies/credit-approval-automation.json"
    claimed="${CREDIT_APPROVAL_REGISTRY:-}"
    if [[ -z "$claimed" && -n "${HYDRA_ROOT:-}" ]]; then
        claimed="$HYDRA_ROOT/policies/credit-approval-automation.json"
    fi
    if [[ -n "$claimed" && "$(realpath -m -- "$claimed" 2>/dev/null)" != "$(realpath -m -- "$pinned" 2>/dev/null)" ]]; then
        echo "scale_drain: the approval registry is pinned to $pinned and cannot be redirected (CREDIT_APPROVAL_REGISTRY/HYDRA_ROOT name $claimed) - refusing" >&2
        return 1
    fi
    printf '%s' "$pinned"
}

# The drain's execution identity: a token file only the drain's own user can read. BOTH
# drain write paths present it - an approval as well as a duplicate close. SCALE_DRAIN,
# REQUESTER_EMAIL and EVIDENCE_EXCERPT are things a caller simply asserts, so without
# this the approve exception was open to anyone who could invoke the wrapper and name a
# real approved same-claim anchor (QA review 5 of hydra#1883).
#
# This RAISES THE BAR from "can invoke the wrapper" to "can read that file". It does not
# make either path non-forgeable, and it is not claimed to: any process running as the
# file's owner (root on node-8) can read it (captain decision, 2026-11-11).
#
# The token lives at ONE path, and the caller does not get to name another. With a
# caller-selected SCALE_DRAIN_TOKEN_FILE the checks below proved only that the caller
# could write a mode-600 file and read it back, which any caller can, so the identity
# was whatever the caller said it was (QA review 4 of hydra#1883). /etc/hydra is
# writable by root alone, so a token that matches this file is one only root placed.
# An override is REFUSED rather than ignored: an attempt to redirect the gate must not
# read as a clean run.
scale_drain_token_ok() {
    local what="$1"
    local drain_token_file="/etc/hydra/scale-drain.token"
    if [[ -n "${SCALE_DRAIN_TOKEN_FILE+set}" ]]; then
        echo "scale_drain: SCALE_DRAIN_TOKEN_FILE is set, but the token path is pinned to $drain_token_file and cannot be redirected - refusing" >&2
        return 1
    fi
    if [[ ! -f "$drain_token_file" ]]; then
        echo "scale_drain: $drain_token_file is missing - refusing ($what needs the root-only token)" >&2
        return 1
    fi
    # The bar is "only the drain's own identity can read this file", so the owner must be
    # the EFFECTIVE user (root in production) and nobody else may read it. Requiring
    # literally root would be stricter than the bar and would make the path untestable
    # outside root.
    local drain_mode drain_owner drain_euid
    drain_mode="$(stat -c '%a' "$drain_token_file" 2>/dev/null)" || drain_mode=""
    drain_owner="$(stat -c '%u' "$drain_token_file" 2>/dev/null)" || drain_owner=""
    drain_euid="$(id -u)"
    if [[ "$drain_mode" != "600" || "$drain_owner" != "$drain_euid" ]]; then
        echo "scale_drain: $drain_token_file must be mode 600 owned by the drain's user (uid $drain_euid; is ${drain_mode:-?}/uid ${drain_owner:-?}) - refusing" >&2
        return 1
    fi
    if [[ -z "${SCALE_DRAIN_TOKEN:-}" ]] || [[ "$(cat "$drain_token_file" 2>/dev/null)" != "${SCALE_DRAIN_TOKEN}" ]]; then
        echo "scale_drain: SCALE_DRAIN_TOKEN does not match $drain_token_file - refusing" >&2
        return 1
    fi
    return 0
}

is_scale_drain_approval() {
    local method="$1" path="$2" body="$3"
    [[ "${SCALE_DRAIN:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "scale-drain@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests" ]] || return 1
    if [[ -e /etc/hydra/scale-drain.disabled ]]; then
        echo "scale_drain: /etc/hydra/scale-drain.disabled is present - refusing" >&2
        return 1
    fi
    # An approval is the drain's most consequential write. The verified anchor below is
    # the per-row control; this is the per-caller one (see scale_drain_token_ok).
    scale_drain_token_ok "an approval" || return 1
    local registry
    registry="$(scale_drain_registry)" || return 1
    jq -e '.automations["verification-scale-drain"]
           | .approved == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$registry" >/dev/null 2>&1 || {
        echo "scale_drain: verification-scale-drain is not approved in $registry - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["requestIds", "status"])
        and .status == "approved"
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 50
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1 || return 1
    # The evidence is CHECKED, not skipped: the digest must name an auto-approvable rule
    # and carry the row-specific anchor the ladder decided on.
    if [[ ! "${EVIDENCE_EXCERPT:-}" =~ ^drain-signal:(precedent|proof_verdict)\;[a-z_]+\;v[0-9]+\;([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-f]{64})\;([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|-)$ ]]; then
        echo "scale_drain: --evidence-excerpt must be drain-signal:<precedent|proof_verdict>;<reason>;v<n>;<anchor>;<profile> - refusing" >&2
        return 1
    fi
    # A digest is a CLAIM; the anchor is a FACT. Verify it against a source the caller
    # does not control before the write lands (QA review of hydra#1883, 2026-11-11):
    #   precedent     -> one admin-API GET for the claimant's profile; the anchor must be
    #                    approved and match this request on claimant, track and roles.
    #   proof_verdict -> the root-owned proof store; the newest verdict must be a decision
    #                    and must name this request.
    # One request per call, because one digest carries one anchor. A batch would need N
    # anchors and N verifications, and the drain writes one row at a time.
    local drain_ids drain_rule drain_anchor drain_profile drain_root drain_verifier
    drain_ids="$(printf '%s' "$body" | jq -r '.requestIds | length' 2>/dev/null)" || return 1
    [[ "$drain_ids" == "1" ]] || {
        echo "scale_drain: exactly one requestId per call (one digest carries one anchor) - refusing" >&2
        return 1
    }
    IFS=';' read -r drain_rule _ _ drain_anchor drain_profile <<< "${EVIDENCE_EXCERPT#drain-signal:}"
    drain_root="$(scale_drain_root)" || drain_root=""
    drain_verifier="${drain_root:-/nonexistent}/scripts/credit_review/verify_anchor.py"
    if [[ ! -f "$drain_verifier" ]]; then
        echo "scale_drain: anchor verifier $drain_verifier is missing - refusing (an unverifiable approve is not an approve)" >&2
        return 1
    fi
    # python3 -I: the verifier takes nothing from the caller's Python environment. It
    # loads its one sibling module from its own directory, so it needs no PYTHONPATH -
    # and an inherited one would sit ahead of the standard library on sys.path, where a
    # caller's json.py or subprocess.py answers instead of the admin API.
    if ! python3 -I "$drain_verifier" \
            --rule "$drain_rule" --anchor "$drain_anchor" \
            --request-id "$(printf '%s' "$body" | jq -r '.requestIds[0]')" \
            --profile-id "$drain_profile"; then
        echo "scale_drain: anchor verification failed - refusing the approve" >&2
        return 1
    fi
    return 0
}

enforce_credit_approve_gate() {
    local method="$1" path="$2" body="$3"

    # Gate covers PUT (batch approve: PUT /admin/credit-requests with
    # "requestIds":[...]) AND PATCH (single-credit approve: PATCH
    # /admin/credit-requests/<id>). The 2026-04-22 live dry-run test showed
    # the bot using PATCH for every individual approve, which under the old
    # PUT-only check bypassed the browser-evidence gate entirely. Normalize
    # method case defensively: `patch` / `Patch` must gate the same as `PATCH`.
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in
        PUT|PATCH) ;;
        *) return 0 ;;
    esac
    # Match both /admin/credit-requests and /admin/credit-requests/<id>
    [[ "$path" == /admin/credit-requests* ]] || return 0
    # Detect the approve STRUCTURALLY, the way core-backend's JSON.parse does —
    # not by literal bytes. A body that parses to status:"approved" via a \uXXXX
    # escape or an inter-token newline slips a line-oriented grep, and a miss
    # here `return 0`s past the ENTIRE evidence requirement (fail-open: an
    # autonomous approve with no browser grounding). jq normalizes both; the
    # literal grep is kept as a belt-and-suspenders backstop for any
    # jq/JSON.parse divergence. Gate if EITHER sees an approve — never less than
    # the old grep-only behavior. Mirrors enforce_credit_reject_gate.
    local status_val
    status_val="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
    if [[ "$status_val" != "approved" ]] \
        && ! echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"approved"'; then
        return 0
    fi

    if is_uvn_popularity_cron_approval "$method" "$path" "$body"; then
        return 0
    fi
    if is_credit_trust_decide_approval "$method" "$path" "$body"; then
        return 0
    fi
    if is_credit_trust_score_approval "$method" "$path" "$body"; then
        return 0
    fi
    if is_fable_decider_approval "$method" "$path" "$body"; then
        return 0
    fi

    # Human override for per-credit verification: allow ONLY when --requester
    # resolves to Jan or Aaron — the humans authorized to approve individual
    # credits after reviewing them in an escalation thread. Other identities
    # (Nick triggering a batch, etc.) do NOT constitute per-credit verification.
    # The agent should NOT pass --requester on autonomous batch approves.
    case "${REQUESTER_EMAIL:-}" in
        jan@muso.ai|aaron@muso.ai)
            return 0
            ;;
    esac

    # LIVE PRODUCTION BYPASS — do NOT remove, and do not read this as a placeholder.
    #
    # Exactly one caller sets it:
    #   muso-ops-credit-verification/scripts/lobster-mvp/apply-verdicts.sh
    # when it applies an `approved` verdict, driven by
    #   pipelines/verify-credit-batch-mvp.lobster  (4-hourly credit-verification cron).
    #
    # Why it exists: that path approves off ALGORITHMIC signals, not browser
    # evidence, and passes a signal digest as --evidence-excerpt
    # (`lobster-signal:approve_owning_track=100;total_risk<80;…`). The checks
    # below all presuppose a human-driven browser session — Tier-1 quorum,
    # session-log freshness, excerpt-to-tool-result matching — so they cannot be
    # satisfied by a pipeline and would refuse every batch approval.
    #
    # This comment previously said "currently none — placeholder for future",
    # which was false on every clause and nearly got the variable deleted during
    # the #873 review. Deleting it breaks autonomous credit approval on a cron
    # nobody is watching. Setting it skips EVERY evidence requirement below, so
    # it is not an operator knob and must not be set by hand or by an agent.
    if is_scale_drain_approval "$method" "$path" "$body"; then
        return 0
    fi

    if [[ "${CV_APPROVE_GATE_DISABLED:-0}" == "1" ]]; then
        return 0
    fi

    # --evidence-excerpt is MANDATORY for autonomous approves. Missing or too-short
    # excerpts fail fast so the agent gets a clear "what to do" message.
    local excerpt="${EVIDENCE_EXCERPT:-}"
    if [[ -z "$excerpt" ]]; then
        cat >&2 <<EOF
credit_approve_gate: --evidence-excerpt is required for autonomous approves.
Both verbs are gated:
    # Batch (PUT):
    muso-admin-api.sh --evidence-excerpt "<literal substring>" \\
        call PUT /admin/credit-requests '{"requestIds":["<cr_id>"],"status":"approved"}'
    # Single credit (PATCH):
    muso-admin-api.sh --evidence-excerpt "<literal substring>" \\
        call PATCH /admin/credit-requests/<cr_id> '{"status":"approved"}'
The excerpt must be a short substring (>=${CV_EVIDENCE_EXCERPT_MIN} chars) that literally appears on >=${CV_REQUIRED_LOADS} distinct Tier 1 pages you loaded via the \`browser\` tool in this session. Good examples: the artist's name as rendered on MusicBrainz, the role string as it appears on AllMusic credits, a track title as it appears on Apple Music or Discogs.
EOF
        return 1
    fi
    if (( ${#excerpt} < CV_EVIDENCE_EXCERPT_MIN )); then
        echo "credit_approve_gate: --evidence-excerpt must be >=${CV_EVIDENCE_EXCERPT_MIN} chars (got ${#excerpt}). Use a more specific substring." >&2
        return 1
    fi
    if (( ${#excerpt} > CV_EVIDENCE_EXCERPT_MAX )); then
        echo "credit_approve_gate: --evidence-excerpt must be <=${CV_EVIDENCE_EXCERPT_MAX} chars (got ${#excerpt}). Use a shorter substring." >&2
        return 1
    fi

    # --- Tier-0 profile-audit evidence path ---------------------------------
    # If excerpt is a `profile_audit:...` receipt, hand off to the recompute
    # gate. Tier-0 doesn't have browser snapshots to grep, so this branch
    # never falls through to the browser-evidence logic below — it terminates
    # the gate with accept (return 0) or reject (return 1).
    #
    # Defense-in-depth: the gate re-fetches the same admin-API surfaces
    # profile-audit.sh used and recomputes all 8 gates from live data. Even
    # if the receipt is forged or the audit script is compromised, the gate
    # is the source of truth for "should this approve."
    if [[ "$excerpt" == profile_audit:* ]]; then
        if _tier0_audit_recompute_gate "$excerpt"; then
            return 0
        else
            return 1
        fi
    fi

    # Locate the most-recently modified openclaw session log on the main
    # gateway (the operations workspace).
    # Portable across GNU/BSD: find filters by age; stat resolves mtime for sort.
    local session_log
    session_log=$(
        find /root/.openclaw-main/agents \
            -maxdepth 3 -type f -name "*.jsonl" -mmin "-${CV_SESSION_MAX_AGE_MIN}" 2>/dev/null \
        | while IFS= read -r f; do
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            [[ -n "$mtime" ]] && printf '%s %s\n' "$mtime" "$f"
          done \
        | sort -rn | head -1 | cut -d' ' -f2-
    )
    if [[ -z "$session_log" ]]; then
        echo "credit_approve_gate: no active openclaw session log (mtime <${CV_SESSION_MAX_AGE_MIN} min) found; refusing autonomous approve." >&2
        return 1
    fi

    # CV_EVIDENCE_MODE dispatch: api (default) | browser (legacy rollback) | both.
    # Under api/both, source lib/api-evidence.sh and check for >=CV_REQUIRED_LOADS
    # distinct evidence sources matching the excerpt. Under api, that's the
    # whole gate — return immediately. Under both, success short-circuits;
    # failure falls through to the browser-evidence pipeline below. Under
    # browser, skip this block entirely.
    if [[ "$CV_EVIDENCE_MODE" == "api" || "$CV_EVIDENCE_MODE" == "both" ]]; then
        # CV_API_EVIDENCE_LIB lets tests redirect; production resolves via
        # SCRIPT_DIR — the workspaces/operations/skills/muso-ops-admin script
        # is one workspace-skill hop away from credit-verification.
        local api_evidence_lib="${CV_API_EVIDENCE_LIB:-${SCRIPT_DIR}/../../muso-ops-credit-verification/scripts/lib/api-evidence.sh}"
        if [[ ! -f "$api_evidence_lib" ]]; then
            echo "credit_approve_gate: CV_EVIDENCE_MODE=${CV_EVIDENCE_MODE} but lib/api-evidence.sh not found at $api_evidence_lib" >&2
            return 1
        fi
        # Source in a sub-shell so the lib's globals don't leak. The lib reads
        # $CV_SESSION_LOG_OVERRIDE (we set it to the resolved session_log so
        # both libs scan the exact same file the gate already chose) and
        # writes a single integer to stdout.
        local api_count
        api_count=$(
            CV_SESSION_LOG_OVERRIDE="$session_log" \
            CV_SESSION_MAX_AGE_MIN="$CV_SESSION_MAX_AGE_MIN" \
            bash -c "source '$api_evidence_lib'; count_profile_evidence_sources \"\$1\"" _ "$excerpt"
        )
        api_count="${api_count:-0}"
        if (( api_count >= CV_REQUIRED_LOADS )); then
            return 0
        fi
        if [[ "$CV_EVIDENCE_MODE" == "api" ]]; then
            cat >&2 <<EOF
credit_approve_gate: insufficient api-evidence — found ${api_count}/${CV_REQUIRED_LOADS} distinct evidence sources for --evidence-excerpt "${excerpt}" in this session.
Sources counted under CV_EVIDENCE_MODE=api:
  * API-helper invocations (musicbrainz-isrc-lookup.sh, spotify-track-lookup.sh,
    discogs-isrc-lookup.sh) whose toolResult JSON contains the excerpt.
    Each helper script counts as ONE source — two MusicBrainz hits don't
    double-count.
  * Tier-2 native web_search citations: each distinct hostname in an
    assistant message that mentions the excerpt counts as ONE source
    (www. stripped, hostnames lowercased).
Browser is NOT a sanctioned source under api-mode (AllMusic fallback was
removed 2026-05-07). If Tier-1 API helpers and Tier-2 web_search don't
sum to ${CV_REQUIRED_LOADS} for this credit, downgrade the verdict to
UNVERIFIABLE — NEEDS REVIEW and escalate to Jan (<@U038BM16T7W>).
For emergency rollback to the legacy browser-only quorum, set
CV_EVIDENCE_MODE=browser in the gateway env.
Session log checked: ${session_log}
EOF
            return 1
        fi
        # CV_EVIDENCE_MODE=both: api count fell short; fall through to browser path.
    fi

    if [[ "$CV_EVIDENCE_MODE" == "api" ]]; then
        # Defensive — should be unreachable; the api block above already returned.
        return 0
    fi

    # R3-3: scope the session-log scan to the current batch run. openclaw
    # channel-keys sessions — one file persists across runs/restarts/days —
    # so a web_fetch yesterday would still block today's approves without
    # this filter. resolve_run_started_ts reads the current run's
    # run_started.ts from the runlog; both jq pipelines below pass it and
    # filter `$lines` accordingly. Empty value = no scope (backward-compat
    # for ad-hoc or non-batch runs, which is what the old behavior was).
    local run_started_ts
    run_started_ts="$(resolve_run_started_ts)"

    # Tier 1 substitution block: Tier 1 hosts are JS-rendered. Using
    # web_fetch on them returns the non-rendered HTML, which is a different
    # (and often wrong) data surface than what the browser tool sees.
    # Multiple real incidents (2026-04-16, 2026-04-20, 2026-04-22) featured
    # web_fetch substituting for browser on these hosts. The plugin
    # block-web-fetch-tier1 hook was the primary defense until 2026-05-07
    # when it was deleted as part of the api-mode cutover; this bash check
    # is now the sole enforcement under both api-mode (default) and the
    # browser-mode rollback path.
    #
    # R4-1: only count web_fetch calls whose toolResult indicates actual data
    # was returned. A plugin-blocked call leaves a toolCall row in the
    # session JSONL but the toolResult has details.status=error + a
    # plugin-block payload — no Tier-1 data leaked. Counting such blocked
    # calls as contamination is a false positive that rejects every approve
    # for the rest of the run (the 2026-04-23 14:20 UTC dry-run blocked
    # all 475 approves on exactly this bug). 404s, timeouts, and other
    # errored web_fetches get the same pass: no data returned = no risk.
    local tier1_webfetch_hosts
    tier1_webfetch_hosts=$(
        jq -R -r -n \
            --arg hosts "$CV_TIER1_WEBFETCH_BLOCKED" \
            --arg run_started_ts "$run_started_ts" '
            ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
            |
            [inputs | fromjson? // empty | select(type == "object")
             | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
            |
            # toolCallId → {name, url} for all toolCalls in scope. Same
            # pattern as the evidence-excerpt check below.
            (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
                ({}; . + {($tc.id): {name: $tc.name, url: ($tc.arguments.url // "")}})
            ) as $calls
            |
            # For each toolResult, check if the originating toolCall was
            # web_fetch to a Tier 1 host AND the result indicates success
            # (non-error, non-empty content). Only such calls could have
            # leaked Tier-1 data.
            [
                $lines[]
                | .message | select(.role == "toolResult")
                | . as $tr
                | ($calls[$tr.toolCallId] // null) as $call
                | select($call != null and $call.name == "web_fetch")
                | ($call.url // "") | select(. != "")
                | capture("^https?://(?:www\\.)?(?<host>[^/]+)").host
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
        ' "$session_log" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
    )
    if [[ -n "$tier1_webfetch_hosts" ]]; then
        cat >&2 <<EOF
credit_approve_gate: web_fetch call(s) to Tier 1 host(s) detected in this session: ${tier1_webfetch_hosts}.
Tier 1 pages (Apple Music / MusicBrainz / Discogs / AllMusic / Tidal)
are JS-rendered — web_fetch returns the raw HTML shell, not the data the
browser tool sees. Every Tier 1 load for credit verification MUST go through
the \`browser\` tool. Reload the relevant page(s) via \`browser\` and retry.
(This check is a backstop — web_fetch should not even be callable; if you
reached this error, something is misconfigured upstream.)
EOF
        return 1
    fi

    # Content-matched evidence count. Forward scan:
    #  1. Track toolCall blocks (tool_use): record toolCallId -> {name, url}
    #  2. On toolResult blocks: if the toolCall was `browser` AND its URL is
    #     Tier 1 AND the toolResult.content text contains --evidence-excerpt
    #     (case-insensitive), count the URL's HOSTNAME as "grounded evidence".
    # Distinct HOSTNAMES required, not distinct URLs — two loads of
    # musicbrainz.org still count as 1 toward the bar.
    # Per-approve freshness is enforced by the excerpt changing per cr_id:
    # different credit → different artist/role → different excerpt string →
    # different browser results required. No reset-on-approve marker needed
    # (and real session logs escape those markers inside JSON strings anyway).
    local count
    count=$(
        jq -R -r -n \
            --arg excerpt "$(echo "$excerpt" | tr '[:upper:]' '[:lower:]')" \
            --arg hosts "$CV_TIER1_HOSTS" \
            --arg run_started_ts "$run_started_ts" \
        '
        # Build tier-1 host lookup: unescape "\." -> ".", index as object keys
        ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
        |
        # Slurp all JSONL lines as raw text (-R), parse each, skip malformed.
        # R3-3: filter by timestamp when run_started_ts is set. Untimestamped
        # lines are excluded under scope — openclaw writes .timestamp on every
        # real line, so absence is either a fixture or a pre-scope artefact.
        [inputs | fromjson? // empty | select(type == "object")
         | select($run_started_ts == "" or ((.timestamp // "") >= $run_started_ts))] as $lines
        |
        # Index toolCall entries: id -> {name, url}
        (reduce ($lines[] | .message.content[]? | select(.type == "toolCall")) as $tc
            ({}; . + {($tc.id): {name: $tc.name, url: $tc.arguments.url}})
        ) as $calls
        |
        # Scan toolResult entries, join via toolCallId, filter, dedup
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
        ]
        | unique | length
        ' "$session_log" 2>/dev/null || echo 0
    )
    count="${count:-0}"

    if (( count < CV_REQUIRED_LOADS )); then
        cat >&2 <<EOF
credit_approve_gate: insufficient grounded evidence — found ${count}/${CV_REQUIRED_LOADS} distinct Tier 1 pages where --evidence-excerpt "${excerpt}" appears in the browser result.
Requirements:
  * Load >=${CV_REQUIRED_LOADS} DIFFERENT Tier 1 hostnames via the \`browser\` tool
    (music.apple.com, musicbrainz.org, discogs.com, allmusic.com).
    Tidal counts as Tier-2 (supporting evidence only) — it does not contribute
    to the quorum even though web_fetch on tidal.com refuses the approve.
  * Each browser result must literally contain the excerpt string.
  * web_fetch / web_search loads do NOT count. Use \`browser\` only.
If the excerpt is too broad or too narrow, try one that appears verbatim in the
rendered page text (e.g. the artist name as shown on MusicBrainz, or a role
string as rendered on AllMusic credits).
If Tier 1 pages genuinely don't confirm the credit, downgrade the verdict to
UNVERIFIABLE — NEEDS REVIEW and escalate to Jan (<@U038BM16T7W>).
Session log checked: ${session_log}
EOF
        return 1
    fi

    return 0
}

# --- fable-decider closes (L12; captain 2026-10-28 21:3xZ/21:4xZ, approval_ref captain-1028-213x) ---
# The ONE agent path past the reject gate below: the L12 executor (scripts/credit-fable-execute.py) closing
# Fable-ruled rows. Deliberately NOT a tier2-approvers entry: that list also authorizes profile merges and
# bulk destructive DELETEs; this grants exactly one shape and nothing else:
#   FABLE_DECIDER=1 + requester fable-decider@hydra-ops + PUT conditional-status
#   + status "rejected" from unverified | user_verification_needed (never touches an approved row)
#   + <=100 unique UUIDs + a Fable ruling id in FABLE_RULING_ID
#   + the registry entry approved (approved_by + approval_ref) + kill file absent.
# Any near miss falls through to the human-confirmation requirement unchanged.
# [key=fable-trays] (Fable switch-on-plan row 4, firstmate 751): the file is named for the per-item TRAY input that is
# off, not the executor (the executor stays live on coded output). The legacy path is still honoured: a rename that has
# not reached node-8 yet must never open this refusal.
FABLE_DECIDER_KILL_FILE="${FABLE_DECIDER_KILL_FILE:-/etc/hydra/fable-trays.disabled}"
FABLE_DECIDER_KILL_FILE_LEGACY="${FABLE_DECIDER_KILL_FILE_LEGACY:-/etc/hydra/fable-decider.disabled}"
_fable_decider_killed() {
    [[ -e "$FABLE_DECIDER_KILL_FILE" ]] && { echo "fable_decider: kill file $FABLE_DECIDER_KILL_FILE present - refusing" >&2; return 0; }
    [[ -e "$FABLE_DECIDER_KILL_FILE_LEGACY" ]] && { echo "fable_decider: kill file $FABLE_DECIDER_KILL_FILE_LEGACY present (deprecated name; rename to $FABLE_DECIDER_KILL_FILE) - refusing" >&2; return 0; }
    return 1
}
is_fable_decider_close() {
    local method="$1" path="$2" body="$3"
    [[ "${FABLE_DECIDER:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "fable-decider@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1
    if _fable_decider_killed; then
        return 1
    fi
    [[ "${FABLE_RULING_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:\|-]{2,120}$ ]] || {
        echo "fable_decider: FABLE_RULING_ID missing or malformed - refusing" >&2
        return 1
    }
    jq -e '.automations["fable-decider"]
           | .approved == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$CREDIT_APPROVAL_REGISTRY" >/dev/null 2>&1 || {
        echo "fable_decider: fable-decider is not approved in $CREDIT_APPROVAL_REGISTRY - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "rejected"
        and (.expectedStatus == "unverified" or .expectedStatus == "user_verification_needed")
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and ($ids | length) <= 100
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
            and (($ids | map(ascii_downcase) | unique | length) == ($ids | length))
        )
    ' >/dev/null 2>&1 || return 1
    # Boundary re-check (QA #1475): the flags above are caller-settable, so the wrapper itself re-runs the
    # executor's per-batch checks on a CLEAN environment (no caller env reaches it): the tray names every id under
    # this ruling, each id has a fresh reservation from this run, the tray's daily cap holds, and every row guard
    # passes on fresh facts + the account gate. The verifier path is fixed relative to THIS file, never from env.
    [[ -n "${FABLE_DECIDER_RUN_ID:-}" && -n "${FABLE_DECIDER_TRAY:-}" ]] || {
        echo "fable_decider: FABLE_DECIDER_RUN_ID / FABLE_DECIDER_TRAY missing - refusing" >&2
        return 1
    }
    if ! fable_decider_verify_batch "$body"; then
        echo "fable_decider: boundary re-check refused the batch" >&2
        return 1
    fi
    return 0
}

# The boundary re-check itself: the executor's own verify_batch, run in a CLEAN environment (env -i: a fixed
# PATH and HOME only), so no caller-set variable can redirect the tray loader, registry, audit file, Trino or the
# account gate to a path of the caller's choosing. The verifier path is fixed relative to THIS file.
fable_decider_verify_batch() {
    local body="$1" verifier ids expected status
    verifier="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." 2>/dev/null && pwd)/scripts/credit-fable-execute.py"
    [[ -f "$verifier" ]] || { echo "fable_decider: verifier $verifier missing - refusing" >&2; return 1; }
    ids="$(printf '%s' "$body" | jq -r '.requestIds | join(",")')"
    expected="$(printf '%s' "$body" | jq -r '.expectedStatus')"
    status="$(printf '%s' "$body" | jq -r '.status')"
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
        python3 "$verifier" --verify-batch --tray "$FABLE_DECIDER_TRAY" --ruling "$FABLE_RULING_ID" \
        --run-id "$FABLE_DECIDER_RUN_ID" --expected "$expected" --status "$status" --ids "$ids" >&2
}

# --- Credit reject gate (incident 2026-07-22) ---
# Rejection of a credit request is NEVER autonomous. core-backend's
# updateStatus.js transition matrix has no rejected->user_verification_needed
# path (the only exit from `rejected` is `approved`), so an agent mistake is
# irreversible for the customer's verification flow: on 2026-07-22 the Ops
# agent rejected 28 UVN requests during Jan's ClickUp sweep and Jan's "move
# them back to verification needed" correction silently no-oped (hollow 200).
# Doctrine now matches the customer-facing rule (Caroline never rejects):
# approve, or keep in user_verification_needed and ask for more proof. A hard
# reject requires an explicit per-batch human decision, evidenced the same way
# as bulk-destructive DELETEs: --confirmed-by <tier-2 approver> +
# --approval-msg-id. Deliberately NO env off-switch and NO dry-run skip — the
# actor this gate restrains controls its own env, and a dry-run preview of an
# unauthorized reject should fail loudly too.
# is_scale_drain_duplicate_close -> 0 when this is the verification scale drain closing a
# DUPLICATE of an already-decided request. A duplicate close is NOT a new decision: the
# original decision stands and the customer's outcome is unchanged, so it does not need a
# tier-2 approver the way a refusal does (captain decision 2026-11-11). It is still a
# reject at the API, so it is audited exactly like one, with the ORIGINAL request id as
# the approval reference - that id is the whole justification, and the gate refuses a
# digest that does not name one.
#
#   * SCALE_DRAIN=1, requester scale-drain@hydra-ops, PUT conditional-status
#   * the kill file is absent and the registry entry is approved
#   * the body is {expectedStatus, requestIds, status:"rejected"} with exactly ONE UUID
#   * the evidence excerpt is drain-dup:<original-uuid>;<reason>;v<n>
is_scale_drain_duplicate_close() {
    local method="$1" path="$2" body="$3"
    [[ "${SCALE_DRAIN:-0}" == "1" ]] || return 1
    [[ "${REQUESTER_EMAIL:-}" == "scale-drain@hydra-ops" ]] || return 1
    [[ "$method" == "PUT" ]] || return 1
    [[ "$path" == "/admin/credit-requests/conditional-status" ]] || return 1
    if [[ -e /etc/hydra/scale-drain.disabled ]]; then
        echo "scale_drain: /etc/hydra/scale-drain.disabled is present - refusing" >&2
        return 1
    fi
    # A duplicate close is NOT an approval: it is gated on the drain's execution identity
    # (see scale_drain_token_ok) and, below, on a verified original.
    scale_drain_token_ok "a duplicate close" || return 1
    local registry
    registry="$(scale_drain_registry)" || return 1
    jq -e '.automations["verification-scale-drain"]
           | .approved == true
             and ((.approved_by // "") | tostring | length > 0)
             and ((.approval_ref // "") | tostring | length > 0)' \
        "$registry" >/dev/null 2>&1 || {
        echo "scale_drain: verification-scale-drain is not approved in $registry - refusing" >&2
        return 1
    }
    printf '%s' "$body" | jq -e '
        type == "object"
        and ((keys | sort) == ["expectedStatus", "requestIds", "status"])
        and .status == "rejected"
        and (.expectedStatus == "unverified" or .expectedStatus == "user_verification_needed")
        and (
            .requestIds as $ids
            | ($ids | type) == "array"
            and ($ids | length) > 0
            and all($ids[];
                type == "string"
                and length == 36
                and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            )
        )
    ' >/dev/null 2>&1 || return 1
    # ONE request per close. The digest names one original and the verifier below checks
    # one target against it, so every further id in the body would be rejected on the
    # strength of a check that never looked at it: a valid duplicate first and an
    # unrelated pending request second closed both (QA review 6 of hydra#1883). The drain
    # writes one row per call; a batch is not this path.
    local dup_ids
    dup_ids="$(printf '%s' "$body" | jq -r '.requestIds | length' 2>/dev/null)" || return 1
    if [[ "$dup_ids" != "1" ]]; then
        echo "scale_drain: exactly one requestId per duplicate close (one digest names one original) - refusing" >&2
        return 1
    fi
    # The evidence is CHECKED: the digest must name the decided ORIGINAL this row
    # duplicates. Without it there is no standing decision and no autonomous close.
    local dup_re='^drain-dup:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\;[a-z_]+\;v[0-9]+\;([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|-)$'
    if [[ ! "${EVIDENCE_EXCERPT:-}" =~ $dup_re ]]; then
        echo "scale_drain: --evidence-excerpt must be drain-dup:<original-request-uuid>;<reason>;v<n>;<profile-uuid> - refusing" >&2
        return 1
    fi
    local dup_original="${BASH_REMATCH[1]}" dup_profile="${BASH_REMATCH[2]}"
    # ...and the claim is VERIFIED, not trusted: the named original must be a DECIDED
    # request for the same claimant, track and roles. The token alone let a caller close an
    # unrelated pending request as a "duplicate" (QA review 2 of hydra#1883).
    local dup_root dup_verifier
    dup_root="$(scale_drain_root)" || dup_root=""
    dup_verifier="${dup_root:-/nonexistent}/scripts/credit_review/verify_anchor.py"
    if [[ ! -f "$dup_verifier" ]]; then
        echo "scale_drain: anchor verifier $dup_verifier is missing - refusing (an unverifiable close is not a close)" >&2
        return 1
    fi
    local dup_target
    dup_target="$(printf '%s' "$body" | jq -r '.requestIds[0]')" || return 1
    # python3 -I, as on the approve path: no caller PYTHONPATH, no working directory.
    if ! python3 -I "$dup_verifier" \
            --rule duplicate --anchor "$dup_original" --request-id "$dup_target" \
            --profile-id "$dup_profile"; then
        echo "scale_drain: duplicate verification failed for $dup_target -> $dup_original - refusing" >&2
        return 1
    fi
    return 0
}

enforce_credit_reject_gate() {
    local method="$1" path="$2" body="$3"

    # Same verb/path detection style as enforce_credit_approve_gate: both PUT
    # (bulk, collection endpoint) and PATCH (single credit) are gated.
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    case "$method_uc" in
        PUT|PATCH) ;;
        *) return 0 ;;
    esac
    [[ "$path" == /admin/credit-requests* ]] || return 0
    # Detect the reject STRUCTURALLY, the way core-backend's JSON.parse does —
    # not by literal bytes. A body that parses to status:"rejected" via a \uXXXX
    # escape or an inter-token newline slips a line-oriented literal grep, yet
    # the backend still honors it (and reject is a ONE-WAY DOOR). jq normalizes
    # both; the literal grep is kept as a belt-and-suspenders backstop for any
    # jq/JSON.parse divergence. Gate if EITHER sees a reject — never less than
    # the old grep-only behavior.
    local status_val
    status_val="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
    if [[ "$status_val" != "rejected" ]] \
        && ! echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"rejected"'; then
        return 0
    fi

    # The registered L12 executor (is_fable_decider_close above): audited like a human reject, with the
    # Fable ruling id as the approval reference. Audit failure refuses, as below.
    if is_fable_decider_close "$method" "$path" "$body"; then
        if ! mkdir -p "$(dirname "$CREDIT_REJECT_AUDIT_PATH")" 2>/dev/null \
            || ! jq -n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg method "$method" --arg path "$path" \
                --arg requester "${REQUESTER_EMAIL:-}" --arg ruling "$FABLE_RULING_ID" \
                --argjson n "$(printf '%s' "$body" | jq '.requestIds | length')" \
                '{ts:$ts, gate:"credit_reject", method:$method, path:$path, requester:$requester,
                  confirmed_by:"fable-decider", approval_msg_id:$ruling, automation:"fable-decider", rows:$n}' \
                >> "$CREDIT_REJECT_AUDIT_PATH"; then
            echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: fable-decider close not audited - refusing." >&2
            return 1
        fi
        return 0
    fi

    # The verification scale drain closing a DUPLICATE of an already-decided request.
    # Deduplication is not a new decision, so it does not need a tier-2 approver - but it
    # is audited like one, with the original request id as the approval reference.
    if is_scale_drain_duplicate_close "$method" "$path" "$body"; then
        if ! mkdir -p "$(dirname "$CREDIT_REJECT_AUDIT_PATH")" 2>/dev/null \
            || ! jq -n -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg method "$method" --arg path "$path" \
                --arg requester "${REQUESTER_EMAIL:-}" --arg original "${EVIDENCE_EXCERPT}" \
                --argjson n "$(printf '%s' "$body" | jq '.requestIds | length')" \
                '{ts:$ts, gate:"credit_reject", method:$method, path:$path, requester:$requester,
                  confirmed_by:"scale-drain-duplicate-close", approval_msg_id:$original,
                  automation:"verification-scale-drain", rows:$n}' \
                >> "$CREDIT_REJECT_AUDIT_PATH"; then
            echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: scale-drain duplicate close not audited - refusing." >&2
            return 1
        fi
        return 0
    fi

    # Requester identity is auto-stamped from whoever is in-thread — it is not
    # evidence a human decided to reject, so it does NOT bypass this gate.
    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
MUSO_CREDIT_REJECT_APPROVAL_REQUIRED: ${method} ${path} would set credit-request status=rejected.
Rejection is a one-way door: the backend has no rejected->user_verification_needed
transition (only rejected->approved), so a wrong reject cannot be undone.
Do NOT reject autonomously. Instead:
  * leave the request in user_verification_needed and ask for more proof, or
  * escalate to Jan (<@U038BM16T7W>) in-thread with your evidence and rationale.
A hard reject requires an explicit human decision:
  bash $0 --requester <slack_id> --confirmed-by <jan|aaron|nick> --approval-msg-id <slack_ts> \\
    call ${method} "${path}" '<body>'
EOF
        return 1
    fi

    if ! is_tier2_approver "$CONFIRMED_BY"; then
        cat >&2 <<EOF
MUSO_CREDIT_REJECT_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
        return 1
    fi

    if [[ -z "$APPROVAL_MSG_ID" ]]; then
        echo "MUSO_CREDIT_REJECT_APPROVAL_REQUIRED: --approval-msg-id <slack_msg_ts> is required alongside --confirmed-by for credit-request rejections (audit trail)." >&2
        return 1
    fi

    # Audit BEFORE allowing — fail-closed, same rationale as the tier-2 gate:
    # "rejected, no record of who decided it" is worse than a retryable error.
    if ! mkdir -p "$(dirname "$CREDIT_REJECT_AUDIT_PATH")" 2>/dev/null; then
        echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: cannot create $(dirname "$CREDIT_REJECT_AUDIT_PATH") — refusing the reject to preserve the audit trail." >&2
        return 1
    fi
    local ts audit_rc=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --arg method "$method" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{ts:$ts, gate:"credit_reject", method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id}' \
        >> "$CREDIT_REJECT_AUDIT_PATH" || audit_rc=$?
    if (( audit_rc != 0 )); then
        echo "MUSO_CREDIT_REJECT_AUDIT_UNWRITABLE: append to $CREDIT_REJECT_AUDIT_PATH failed (rc=$audit_rc) — refusing the reject to preserve the audit trail." >&2
        return 1
    fi
    return 0
}

# --- Tier-2 approval gate (incident 2026-04-29) ---
# See skills-all/muso-ops-admin/scripts/muso-admin-api.sh for the canonical
# version + design notes. This block is mirrored here because workspaces/operations
# ships its own wrapper copy (drift to be cleaned up separately).

is_tier2_endpoint() {
    local method="$1" path="$2"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    # Strip any query string before matching (mirror is_bulk_destructive_op).
    path="${path%%\?*}"
    # One trailing slash is the same route (the claim-verify pace gate accepts
    # /verify/), so it must not step around the approval requirement.
    [[ "$path" == */ && "$path" != "/" ]] && path="${path%/}"
    [[ -f "$TIER2_ENDPOINTS_PATH" ]] || return 1
    # A ":param" segment matches EXACTLY ONE path segment, so
    # "DELETE /admin/user/:id" gates "/admin/user/123" but NOT the sub-resource
    # "/admin/user/123/image" — over-matching would wrongly gate the
    # credit-removal endpoint and break remove_credits. Param-less entries stay
    # EXACT string matches.
    local restore_extglob=0
    shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
    local rc=1
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line## }"
        line="${line%% }"
        [[ -z "$line" ]] && continue
        local m p pattern
        m="$(printf %s "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')"
        p="$(printf %s "$line" | awk '{print $2}')"
        [[ "$m" == "$method_uc" ]] || continue
        # ":word" -> one non-slash segment; literal entries are left unchanged.
        pattern="$(printf %s "$p" | sed -E 's#:[A-Za-z_][A-Za-z0-9_]*#+([!/])#g')"
        # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
        if [[ "$path" == $pattern ]]; then
            rc=0
            break
        fi
    done < "$TIER2_ENDPOINTS_PATH"
    (( restore_extglob )) && shopt -u extglob
    return "$rc"
}

is_tier2_approver() {
    local handle="$1"
    [[ -n "$handle" ]] || return 1
    [[ -f "$TIER2_APPROVERS_PATH" ]] || return 1
    local handle_lc
    handle_lc="$(printf %s "$handle" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line## }"
        line="${line%% }"
        [[ -z "$line" ]] && continue
        local approver_lc
        approver_lc="$(printf %s "$line" | tr '[:upper:]' '[:lower:]')"
        [[ "$handle_lc" == "$approver_lc" ]] && return 0
    done < "$TIER2_APPROVERS_PATH"
    return 1
}

# Self-approving requesters for tier-2 writes. Anyone whose --requester
# resolves to a value in tier2-godmode-allowlist.txt may execute tier-2
# writes WITHOUT --confirmed-by/--approval-msg-id. The audit row still
# fires (with bypass=god_mode_self_approve) so writes remain traceable.
# Fail-closed when the file is missing — bypass is opt-in.
is_tier2_godmode_requester() {
    local handle="$1"
    [[ -n "$handle" ]] || return 1
    [[ -f "$TIER2_GODMODE_PATH" ]] || return 1
    local handle_lc
    handle_lc="$(printf %s "$handle" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        line="${line%%#*}"
        # Trim ALL surrounding whitespace incl. tabs and \r — IDE-saved
        # files commonly carry trailing spaces or CRLF, and a fragile trim
        # silently locks self-approving requesters out of god-mode.
        line="$(printf %s "$line" | tr -d '[:space:]\r')"
        [[ -z "$line" ]] && continue
        local entry_lc
        entry_lc="$(printf %s "$line" | tr '[:upper:]' '[:lower:]')"
        [[ "$handle_lc" == "$entry_lc" ]] && return 0
    done < "$TIER2_GODMODE_PATH"
    return 1
}

# The highest-blast-radius admin writes: irreversible account/track deletion
# and paid-subscription create. God-mode admins (aaron/jan/nick) retain access
# to these, but — unlike every other tier-2 write — they may NOT self-approve
# off a bare auto-stamped --requester: enforce_tier2_approval_gate requires an
# explicit --approval-msg-id for these so the ops agent can't silently execute
# one (policy 2026-06-15). Patterns mirror the tier2-endpoints.txt entries; a
# ":param" segment is matched as exactly one path segment (extglob +([!/])).
is_godmode_approval_required_endpoint() {
    local method="$1" path="$2"
    path="${path%%\?*}"
    # One trailing slash is the same route as is_tier2_endpoint treats it.
    [[ "$path" == */ && "$path" != "/" ]] && path="${path%/}"
    local method_uc; method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    local restore_extglob=0
    shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
    local rc=1 entry em ep
    for entry in "DELETE /admin/user/+([!/])" "DELETE /admin/track/+([!/])" "POST /admin/subscription" "POST /admin/claiming/+([!/])/verify"; do
        em="${entry%% *}"; ep="${entry#* }"
        # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
        if [[ "$method_uc" == "$em" && "$path" == $ep ]]; then
            rc=0; break
        fi
    done
    (( restore_extglob )) && shopt -u extglob
    return "$rc"
}

# Removals: whole-track deletion (a Catalog/IDP tombstone of the track and EVERY served credit on
# it), credit removal from a profile, and the profile soft-delete (DELETE /admin/profile/:id).
# God-mode self-approve NEVER covers these (firstmate 122,
# incident 2026-10-20 14:05Z: a bare "hide track from public" was self-approved into two track
# DELETEs). Core refuses agent removals anyway (403 credit_removal_agent_refused); refusing here
# stops the attempt itself. A removal needs a recorded reason (DSP-removal or different-profile
# proof + a label check) and goes through the guarded named-human path, not this wrapper's
# self-approve. A ":param" segment matches exactly one path segment.
#
# The profile soft-delete is here because it is a ONE-WAY tombstone: it takes the profile AND
# every credit served on it (2026-10-22..11-04: 24 DELETEs on a staff request tombstoned 23
# profiles and 717 served credits, with no list entry and no inverse). Profile hides are not
# available to the agent: the request goes on the GDPR register (scripts/gdpr-pipeline.py),
# which prepares the reversible hide PRs for a named human to merge.
is_removal_endpoint() {
    local method="$1" path="$2"
    local method_uc; method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "DELETE" ]] || return 1
    local base="${MUSO_API_URL:-}"
    base="${base#*://}"
    if [[ "$base" == */* ]]; then base="/${base#*/}"; else base=""; fi
    base="$(normalize_admin_path "$base")"
    [[ "$base" == "/" ]] && base=""
    base="${base%/}"
    local restore_extglob=0
    shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
    local rc=1 ep route
    for route in "$(normalize_admin_path "$path")" "$(normalize_admin_path "${base}${path}")"; do
        if [[ -n "$base" && "$route" == "$base"/* ]]; then
            route="${route#"$base"}"
        fi
        for ep in "/admin/track/+([!/])" "/admin/track/+([!/])/profile/+([!/])/credits" "/admin/profile/+([!/])"; do
            # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
            if [[ "$route" == $ep ]]; then rc=0; break 2; fi
        done
    done
    (( restore_extglob )) && shopt -u extglob
    return "$rc"
}

refuse_removal_self_approve() {
    cat >&2 <<EOM
MUSO_REMOVAL_NO_SELF_APPROVE: ${1} ${2} is a removal (whole-track tombstone, a credit removed from a profile, or the profile soft-delete). God-mode self-approve never covers removals, and core refuses agent removals (credit_removal_agent_refused). Do not retry through another wrapper or identity.
Instead: read the entity back and tell the requester what removal would do (the track + its N credits, or the profile + its N served credits). Ask for the reason if none is recorded (DSP-removal proof or different-profile proof, plus a label check). Profile hides are not available to the agent; the request goes on the GDPR register for identity verification (verified claim or matching ID) and a person-approved takedown -- file it with scripts/ops_intake/hide.py, which prepares the reversible hide-list PR a person merges. Never this endpoint. A recorded removal goes to a named human from their own login.
EOM
}

# Removal gate (QA #1299 @a3bc2731, firstmate 122): a removal never goes out through this
# wrapper, whatever the requester, the bulk count or the approval flags. The refusal sits
# BEFORE the tier-2 and bulk gates because neither reaches a lone credit removal below the
# bulk threshold. Core refuses agent removals anyway (credit_removal_agent_refused); this
# stops the attempt itself. Dry-run still shows the call (no write).
enforce_removal_gate() {
    local method="$1" path="$2"
    is_removal_endpoint "$method" "$path" || return 0
    is_dry_run_mode && return 0
    refuse_removal_self_approve "$method" "$path"
    return 1
}


# --- Claim-verify pace gate (2026-10-11) ---
# POST /admin/claiming/:id/verify makes the claimant the verified owner of a
# profile. Since 09-01, 2,424 claim verifies went out at a 0.44 s median gap (a
# loop, not per-claim review). Besides the tier-2 approval this endpoint now
# needs, at most one claim verify per CLAIM_VERIFY_MIN_INTERVAL seconds goes out
# host-wide. The state file is shared with scripts/muso-prewrite-hook.sh, so the
# muso CLI and this wrapper draw on one budget. Skipped in dry-run (no write).
# Pinned, no env override (an env-chosen path would hand each caller a fresh stamp
# and defeat the host-wide budget). Same literal as scripts/muso-prewrite-hook.sh.
CLAIM_VERIFY_LAST="/var/lib/hydra/claim-verify.last"
enforce_claim_verify_pace_gate() {
    local method="$1" path="${2%%\?*}"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "POST" ]] || return 0
    [[ "$path" =~ ^/admin/claiming/[^/]+/verify/?$ ]] || return 0
    if is_dry_run_mode; then
        return 0
    fi
    local state="$CLAIM_VERIFY_LAST"
    local min="${CLAIM_VERIFY_MIN_INTERVAL:-20}"
    [[ "$min" =~ ^[0-9]+$ ]] && (( min >= 20 )) || min=20
    if ! mkdir -p "$(dirname "$state")" 2>/dev/null || ! { exec 7>>"$state.lock"; } 2>/dev/null; then
        echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: cannot open $state — refusing the claim verify (fail closed)." >&2
        return 1
    fi
    # The lock makes the gate host-wide; without flock, refuse (fail closed).
    if ! command -v flock >/dev/null 2>&1; then
        echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: flock is unavailable, so concurrent claim verifies cannot be serialized — refusing the claim verify." >&2
        return 1
    fi
    if ! flock -w 5 7; then
        echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: pace lock busy — refusing the claim verify." >&2
        return 1
    fi
    local now last
    now="$(date +%s)"
    # Absent file = first use. An existing stamp that is empty, truncated or unreadable
    # must not read as "long ago": refuse until a root operator clears it.
    last=0
    if [ -e "$state" ]; then
        if ! last="$(cat "$state" 2>/dev/null)" || [[ ! "$last" =~ ^(0|[1-9][0-9]{0,14})$ ]]; then
            echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: the claim-verify timestamp in $state is unreadable or malformed — refusing the claim verify (fail closed). Clear $state as root." >&2
            return 1
        fi
    fi
    # A future stamp (clock stepped back) must not reset to 0 and pass: refuse.
    if (( last > now )); then
        echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: the claim-verify timestamp in $state is $((last - now))s in the future (host clock may have stepped backward) — refusing the claim verify (fail closed). Check the host clock, then clear $state as root." >&2
        return 1
    fi
    if (( now - last < min )); then
        echo "MUSO_CLAIM_VERIFY_TOO_FAST: claim verifies are limited to one per ${min}s host-wide (last $((now - last))s ago). Review each claim individually before verifying it; do not retry in a loop." >&2
        return 1
    fi
    # The stamp is the next caller's gate: an unrecorded verify is refused.
    if ! { printf '%s\n' "$now" > "$state"; } 2>/dev/null; then
        echo "MUSO_CLAIM_VERIFY_PACE_UNAVAILABLE: cannot record the claim-verify timestamp at $state — refusing the claim verify." >&2
        return 1
    fi
    return 0
}

enforce_tier2_approval_gate() {
    local method="$1" path="$2"

    # Fail-closed if the endpoint allowlist file is missing. Without it,
    # is_tier2_endpoint cannot decide scope and would silently pass every
    # call through. The file ships in the repo (config/tier2-endpoints.txt);
    # absence here means a packaging or rsync regression.
    if [[ ! -f "$TIER2_ENDPOINTS_PATH" ]]; then
        echo "MUSO_TIER2_CONFIG_MISSING: TIER2_ENDPOINTS_PATH (${TIER2_ENDPOINTS_PATH}) is missing — refusing every write until the tier-2 allowlist is restored." >&2
        return 1
    fi

    is_tier2_endpoint "$method" "$path" || return 0
    if is_dry_run_mode; then
        return 0
    fi

    # God-mode bypass: a requester on the god-mode allowlist self-authorizes
    # (no --confirmed-by needed). Audit row still records who+when with
    # bypass=god_mode_self_approve. Match against email or raw flag value so
    # both `--requester jan@muso.ai` and `--requester U038BM16T7W` (resolved to
    # email upstream) work.
    #
    # EXCEPTION (policy 2026-06-15): for the highest-blast-radius endpoints —
    # account/track deletion and paid-subscription create — god-mode admins
    # KEEP access but may NOT self-approve off a bare auto-stamped --requester:
    # an explicit --approval-msg-id (a real in-thread human OK) is required, so
    # the ops agent can never silently execute one just because a god-mode admin
    # happens to be in-thread. See is_godmode_approval_required_endpoint.
    if is_tier2_godmode_requester "${REQUESTER_EMAIL:-}"; then
        if is_removal_endpoint "$method" "$path"; then
            refuse_removal_self_approve "$method" "$path"
            return 1
        fi
        if is_godmode_approval_required_endpoint "$method" "$path" && [[ -z "$APPROVAL_MSG_ID" ]]; then
            cat >&2 <<EOF
MUSO_TIER2_GODMODE_APPROVAL_MSG_REQUIRED: ${method} ${path} is a high-blast-radius write (account/track deletion or subscription create). God-mode self-approve still applies for '${REQUESTER_EMAIL:-}', but you MUST pass --approval-msg-id <slack_msg_ts> proving an explicit in-thread decision — the ops agent must not execute one of these off an auto-stamped --requester alone.
EOF
            return 1
        fi
        if ! mkdir -p "$(dirname "$TIER2_AUDIT_PATH")" 2>/dev/null; then
            echo "MUSO_TIER2_AUDIT_UNWRITABLE: cannot create $(dirname "$TIER2_AUDIT_PATH") — refusing tier-2 write to preserve audit trail." >&2
            return 1
        fi
        local gm_ts gm_rc=0 gm_msgid="${APPROVAL_MSG_ID:-god-mode}"
        gm_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        jq -n -c \
            --arg ts "$gm_ts" \
            --arg method "$method" \
            --arg path "$path" \
            --arg requester "${REQUESTER_EMAIL:-}" \
            --arg approval_msg_id "$gm_msgid" \
            '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$requester, approval_msg_id:$approval_msg_id, bypass:"god_mode_self_approve"}' \
            >> "$TIER2_AUDIT_PATH" || gm_rc=$?
        if (( gm_rc != 0 )); then
            echo "MUSO_TIER2_AUDIT_UNWRITABLE: append to $TIER2_AUDIT_PATH failed (rc=$gm_rc) — refusing tier-2 write to preserve audit trail." >&2
            return 1
        fi
        return 0
    fi

    if [[ -z "$CONFIRMED_BY" ]]; then
        cat >&2 <<EOF
MUSO_TIER2_APPROVAL_REQUIRED: ${method} ${path} is a tier-2 admin write.
Pass --confirmed-by <handle> with explicit in-thread approval from one of:
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (approver allowlist file missing: ${TIER2_APPROVERS_PATH})")

Also pass --approval-msg-id <slack_msg_ts> so the audit trail can link back to the approval.

Example:
  bash $0 --requester <slack_id> --confirmed-by aaron --approval-msg-id 1777474838.796239 \\
    call ${method} "${path}" '<body>'

This gate exists because of incident 2026-04-29 (profile merge). See muso-ops-profiles/SKILL.md "Merge Profiles" stop-rule.
EOF
        return 1
    fi
    if ! is_tier2_approver "$CONFIRMED_BY"; then
        cat >&2 <<EOF
MUSO_TIER2_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the tier-2 approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
        return 1
    fi
    if [[ -z "$APPROVAL_MSG_ID" ]]; then
        echo "MUSO_TIER2_APPROVAL_REQUIRED: --approval-msg-id <slack_msg_ts> is required alongside --confirmed-by for tier-2 writes (audit trail)." >&2
        return 1
    fi
    # Audit the approval BEFORE executing. Fail-closed if we can't write —
    # the audit trail is the entire authorization story for tier-2 writes.
    if ! mkdir -p "$(dirname "$TIER2_AUDIT_PATH")" 2>/dev/null; then
        echo "MUSO_TIER2_AUDIT_UNWRITABLE: cannot create $(dirname "$TIER2_AUDIT_PATH") — refusing tier-2 write to preserve audit trail. Fix the directory permissions and retry." >&2
        return 1
    fi
    local ts audit_rc=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --arg method "$method" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id}' \
        >> "$TIER2_AUDIT_PATH" || audit_rc=$?
    if (( audit_rc != 0 )); then
        echo "MUSO_TIER2_AUDIT_UNWRITABLE: append to $TIER2_AUDIT_PATH failed (rc=$audit_rc) — refusing tier-2 write to preserve audit trail." >&2
        return 1
    fi
    return 0
}

merge_body_extract_ids() {
    local body="$1"
    local into ids
    into=$(printf '%s' "$body" | jq -r '.mergeInto // empty' 2>/dev/null) || return 1
    ids=$(printf '%s' "$body" | jq -r '(.profilesIds // []) | join(",")' 2>/dev/null) || return 1
    [[ -n "$into" && -n "$ids" ]] || return 1
    printf 'INTO=%s\nIDS=%s\n' "$into" "$ids"
}

enforce_merge_reverse_direction_guard() {
    local method="$1" path="$2" body="$3"
    [[ "$path" == "/admin/profiles/merge" ]] || return 0
    is_dry_run_mode && return 0

    # Malformed body on a tier-2 merge is a fail-closed condition.
    local extracted into ids
    if ! extracted=$(merge_body_extract_ids "$body"); then
        echo "MUSO_MERGE_BODY_UNPARSEABLE: refusing /admin/profiles/merge — body did not parse as {mergeInto: <id>, profilesIds: [<id>, ...]}." >&2
        return 1
    fi
    into=$(printf '%s' "$extracted" | sed -n 's/^INTO=//p')
    ids=$(printf '%s' "$extracted" | sed -n 's/^IDS=//p')

    # First run: state file doesn't exist yet — record_merge_call will
    # create it on the first 2xx.
    [[ -f "$RECENT_MERGES_PATH" ]] || return 0

    # Window cutoff in epoch seconds. `date +%s` is POSIX and portable.
    local cutoff_epoch=$(( $(date +%s) - TIER2_REVERSE_WINDOW_SECS ))
    local conflict
    conflict=$(
        jq -R -r -n \
            --arg into "$into" \
            --arg ids_csv "$ids" \
            --argjson cutoff "$cutoff_epoch" \
        '
        ($ids_csv | split(",")) as $new_ids
        |
        [inputs | fromjson? // empty | select(type == "object")]
        | map(select((.epoch // 0) >= $cutoff))
        | map(. as $entry | select(
              (($entry.profilesIds // []) | index($into))
              or
              ([$entry.mergeInto // ""] | inside($new_ids))
              or
              ($new_ids | any(. as $i | ($entry.profilesIds // []) | index($i)))
          ))
        | .[0] // empty
        | tojson
        ' "$RECENT_MERGES_PATH" 2>/dev/null
    )
    if [[ -n "$conflict" ]]; then
        cat >&2 <<EOF
MUSO_MERGE_OVERLAPPING_IDS_BLOCKED: refusing /admin/profiles/merge.

A recent merge (within ${TIER2_REVERSE_WINDOW_SECS}s) has overlapping IDs with this call:
  new: mergeInto=${into}, profilesIds=[${ids}]
  prior conflicting entry: ${conflict}

The guard fires on either of these patterns:
  - Reverse direction (mergeInto/profilesIds swapped) — the call shape that
    caused production damage on 2026-04-29 (workspace/claim/playlist moved
    off the intended survivor).
  - Same-direction retry after the prior call completed — the prior merge
    may not yet be fully observable (async industry pipeline), and re-issuing
    is rarely the correct answer.

In both cases: do NOT retry, do NOT flip the direction. See muso-ops-profiles/SKILL.md "Merge Profiles" STOP-rule. Escalate to Aaron in the same Slack thread and wait.

If you genuinely need to issue this call (e.g. legitimate corrective merge after a wait), you must:
  1. Wait until ${TIER2_REVERSE_WINDOW_SECS}s have passed since the prior merge, OR
  2. Manually clear the relevant entries from ${RECENT_MERGES_PATH} after explicit Aaron approval.
EOF
        return 1
    fi
    return 0
}

# normalize_admin_path PATH -> canonical, lower-cased path on stdout.
#
# The raw $path is concatenated straight into the curl URL, so ANY spelling that
# reaches the same API route but slips a gate's match is a live bypass, not a
# cosmetic near-miss. curl itself resolves dot-segments and drops the fragment
# before the request leaves the machine, and Express routes case-insensitively by
# default -- so /ADMIN/profile/ENRICHBYURL, /admin/profile/./enrichByUrl,
# /admin/profile/x/../enrichByUrl and ...#frag all hit the SAME handler as the
# canonical spelling while failing a literal match. Normalizing can only ever
# make MORE paths match, so it cannot widen what gets through.
#
# NOTE: the older gates (is_tier2_endpoint, is_bulk_destructive_op) strip only the
# query string and so remain exposed to these same spellings. Widening them is out
# of scope here; see the PR description.
normalize_admin_path() {
    local p="$1" out="" seg rest
    p="${p%%#*}"
    p="${p%%\?*}"
    p="$(printf %s "$p" | tr '[:upper:]' '[:lower:]')"
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    # RFC 3986 5.2.4 remove_dot_segments, in FULL. An earlier cut handled only
    # "/./" and "/seg/../" -- both of which require a FOLLOWING slash -- so the
    # boundary forms "/admin/profile/enrichByUrl/." and "/../admin/profile/
    # enrichByUrl" stayed non-canonical here and sailed past the case statement.
    # Verified on the wire: curl sends the first as ".../enrichByUrl/" and the
    # second as the exact canonical path, so both reached the live route with no
    # profileId. Anything short of the whole algorithm leaves such a spelling.
    while [[ -n "$p" ]]; do
        case "$p" in
            ../*)  p="${p#../}" ;;
            ./*)   p="${p#./}" ;;
            /./*)  p="/${p#/./}" ;;
            /.)    p="/" ;;
            /../*) p="/${p#/../}"; out="${out%/*}" ;;
            /..)   p="/"; out="${out%/*}" ;;
            .|..)  p="" ;;
            *)
                if [[ "$p" == /* ]]; then
                    rest="${p:1}"
                    if [[ "$rest" == */* ]]; then seg="/${rest%%/*}"; p="/${rest#*/}"
                    else seg="/${rest}"; p=""; fi
                else
                    if [[ "$p" == */* ]]; then seg="${p%%/*}"; p="/${p#*/}"
                    else seg="$p"; p=""; fi
                fi
                out="${out}${seg}" ;;
        esac
    done
    p="$out"
    while [[ "$p" == */ ]]; do p="${p%/}"; done
    printf %s "$p"
}

# enforce_profile_enrich_link_gate METHOD PATH BODY -> 0 allow / 1 block.
#
# Incident 2026-08-05 (THIRD recurrence). Ops created profile ylsvoid
# (15bb7a07-...), fired a Spotify capture, got back
# {accepted:true, captureId:"156ae094-..."}, and the source never attached.
# It never could have: nothing in that request named the profile.
#
# A capture binds to a muso profile through exactly ONE value —
# extra_data.profile_id. core-backend's enrichByUrl.js threads `profileId`
# into it; IDP reads it at base_raw_processor.py:129
# (artist.muso_profile_id) and consumes it at sync_profile.py:318-323.
# When it is absent, the match cascade (sync_profile.py:486-504:
# raw_id -> exact spotify link -> IPI -> _sync_new) has NO name-matching
# rung, so the scrape falls through to _sync_new and mints a SEPARATE
# profile. The operator's profile stays empty forever.
#
# `accepted:true` is NOT evidence of linkage. The HTTP capture path uses
# force_send_to_queue (capture_helper.py:94-121), which means only
# "produced to Kafka". So the standard "200 = queued, wait and re-check"
# doctrine — correct for a LINKED capture — can never resolve an unlinked
# one. That is precisely why this was escalated three times.
#
# Two shapes are refused:
#   POST /admin/profile/enrichByUrl        with no profileId in the body
#   POST /admin/artist/<spotifyId>/enrich  (carries no profile ref AT ALL)
#
# Override for a genuinely standalone catalog capture (enriching a source
# entity with no muso profile to attach to): MUSO_ENRICH_STANDALONE=1.
enforce_profile_enrich_link_gate() {
    local method="$1" path="$2" body="$3"

    # Normalize method case defensively — `post` must gate the same as `POST`
    # (same reasoning as enforce_credit_approve_gate).
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "POST" ]] || return 0

    # Normalize BEFORE matching -- see normalize_admin_path for why a literal
    # match on $path is a live bypass (query string, fragment, case, dot
    # segments, repeated/trailing slashes all reach the same route).
    local norm_path
    norm_path="$(normalize_admin_path "$path")"

    # Only these two routes dispatch a profile-scoped capture. Patterns MUST be
    # lower-case: normalize_admin_path lower-cases what it returns, so a
    # camelCase pattern here would never match anything.
    case "$norm_path" in
        /admin/artist/*/enrich|/admin/profile/enrichbyurl) ;;
        *) return 0 ;;
    esac

    # Explicit opt-in for a standalone capture. Checked AFTER the route match
    # so the variable can never widen the gate to unrelated routes.
    if [[ "${MUSO_ENRICH_STANDALONE:-0}" == "1" ]]; then
        return 0
    fi

    # This route has no profileId parameter at all — there is no body shape
    # that makes it attach, so it is refused outright rather than inspected.
    if [[ "$norm_path" == /admin/artist/*/enrich ]]; then
        cat >&2 <<EOF
MUSO_ENRICH_CANNOT_LINK: refusing POST ${path}.

This route takes ONLY a spotify artist id (core-backend enrichSpotify.js) and
sends no profile reference, so the capture can never attach to a muso profile.
It will answer {accepted:true, captureId:...} and then silently mint a SEPARATE
standalone profile. Waiting and re-checking will NEVER make the source appear.

To attach a source to an existing profile, use the route that carries the link:
    bash \$0 call POST /admin/profile/enrichByUrl \\
        '{"enrichmentUrl":"https://open.spotify.com/artist/<id>","profileId":"<profile_id>"}'

If you genuinely want a standalone catalog capture with no profile to attach
to, re-run with MUSO_ENRICH_STANDALONE=1.
EOF
        return 1
    fi

    # /admin/profile/enrichByUrl — the link is only present if the body
    # actually carries profileId. Parse it the way core-backend's JSON.parse
    # does rather than by literal bytes: a line-oriented grep is fooled by
    # \uXXXX escapes and inter-token newlines, and a miss here would let the
    # unlinkable call through (fail-open on the exact defect being gated).
    #
    # Fail CLOSED on an empty or unparseable body: we would rather refuse a
    # body we cannot read than skip the link check on it. (`jq -e .` exits 4
    # on empty input and 5 on invalid JSON; both are non-zero, verified.)
    if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        cat >&2 <<EOF
MUSO_ENRICH_BODY_UNPARSEABLE: refusing POST ${path} — body did not parse as
JSON, so the required profileId link could not be verified.

    bash \$0 call POST /admin/profile/enrichByUrl \\
        '{"enrichmentUrl":"https://open.spotify.com/artist/<id>","profileId":"<profile_id>"}'
EOF
        return 1
    fi

    # A PRESENT profileId is not automatically a USABLE one, and the check must
    # never round-trip the VALUE through the shell. `$(jq -r .profileId)` strips
    # every trailing newline byte (command substitution does), so
    # {"profileId":"<uuid>\n"} became a bare UUID inside the gate and passed,
    # while the unchanged body still decoded to UUID+newline for core-backend and
    # matched no profile — the silent non-attachment again. So jq classifies the
    # value and returns only a short verdict TOKEN; nothing the shell can mangle.
    #
    # Two traps this encodes:
    #   - jq/Oniguruma `$` matches BEFORE a trailing newline (verified: test()
    #     with ^...$ returns true for "<uuid>\n"). \A and \z are the real anchors,
    #     and the length==36 check makes it belt-and-braces.
    #   - trimming and validating the trimmed copy blesses a value the API never
    #     sees; the body goes to curl byte-for-byte, so padding must be REFUSED,
    #     not silently cleaned.
    local verdict profile_id_display profile_id_fixed
    verdict="$(printf '%s' "$body" | jq -r '
        def trimmed: gsub("^\\s+|\\s+$"; "");
        if (.profileId|type) == "null" then "missing"
        elif (.profileId|type) != "string" then "nottype:" + (.profileId|type)
        elif (.profileId|trimmed) == "" then "missing"
        elif .profileId != (.profileId|trimmed) then "whitespace"
        elif (.profileId|length) != 36 then "malformed"
        elif (.profileId|test("\\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\z")|not) then "malformed"
        else "ok" end' 2>/dev/null || true)"
    # Display copy only — JSON-encoded so a newline or tab is visible as \n / \t
    # in the refusal instead of wrecking the message. Never used for the verdict.
    profile_id_display="$(printf '%s' "$body" | jq -c '.profileId // ""' 2>/dev/null || true)"
    # The corrected value to send back to the operator. Safe through command
    # substitution BY CONSTRUCTION: it is the trimmed form, so it has no trailing
    # whitespace left for the shell to strip. Display/advice only, never a verdict.
    profile_id_fixed="$(printf '%s' "$body" | jq -r '(.profileId // "") | gsub("^\\s+|\\s+$"; "")' 2>/dev/null || true)"

    case "$verdict" in
        ok) return 0 ;;
        missing)
            cat >&2 <<EOF
MUSO_ENRICH_MISSING_PROFILE_ID: refusing POST ${path} — no usable profileId in the body.

Without profileId the capture carries no extra_data.profile_id, so it cannot
bind to any profile. It will answer {accepted:true, captureId:...} and then
mint a SEPARATE standalone profile; the profile you meant to fill stays empty.
Re-checking later will NEVER show the source — this is not an async delay.

Add the profile the source belongs to:
    bash \$0 call POST /admin/profile/enrichByUrl \\
        '{"enrichmentUrl":"<source-url>","profileId":"<profile_id>"}'

If you genuinely want a standalone catalog capture with no profile to attach
to, re-run with MUSO_ENRICH_STANDALONE=1.
EOF
            return 1 ;;
        nottype:*)
            cat >&2 <<EOF
MUSO_ENRICH_PROFILE_ID_NOT_A_STRING: refusing POST ${path} — profileId is a
JSON ${verdict#nottype:}, not a string.

Only a string profile id can resolve to a profile. A number/bool/array/object
is dispatched happily by the API and then matches nothing, which lands you in
exactly the silent non-attachment this gate exists to prevent.
EOF
            return 1 ;;
        whitespace)
            cat >&2 <<EOF
MUSO_ENRICH_PROFILE_ID_HAS_WHITESPACE: refusing POST ${path} — profileId
carries surrounding whitespace (${profile_id_display}).

The request body is sent to the API byte-for-byte, so the padding travels with
it and the value matches no profile. Note a trailing newline counts and is easy
to introduce with \$(cat file) or a heredoc. Send the bare 36-character id:

    "profileId":"${profile_id_fixed}"
EOF
            return 1 ;;
        *)
            cat >&2 <<EOF
MUSO_ENRICH_PROFILE_ID_MALFORMED: refusing POST ${path} — profileId
${profile_id_display} is not a UUID.

Muso profile ids are UUIDs (e.g. 15bb7a07-7249-4405-a37a-7255d1cb9321). A
non-UUID id is accepted by the API and then matches no profile, so the captured
source attaches to nothing exactly as if you had passed none at all.
EOF
            return 1 ;;
    esac
}

record_merge_call() {
    local method="$1" path="$2" body="$3" http_code="$4"
    [[ "$path" == "/admin/profiles/merge" ]] || return 0
    # Match any 2xx so a future 201/204 contract change doesn't silently
    # leave the merge unrecorded and disable the reverse-direction guard.
    [[ "$http_code" =~ ^2[0-9][0-9]$ ]] || return 0
    is_dry_run_mode && return 0
    local extracted into ids_csv
    extracted=$(merge_body_extract_ids "$body") || return 0
    into=$(printf '%s' "$extracted" | sed -n 's/^INTO=//p')
    ids_csv=$(printf '%s' "$extracted" | sed -n 's/^IDS=//p')
    mkdir -p "$(dirname "$RECENT_MERGES_PATH")" 2>/dev/null || return 0
    local epoch ts
    epoch=$(date +%s)
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --argjson epoch "$epoch" \
        --arg method "$method" \
        --arg path "$path" \
        --arg mergeInto "$into" \
        --arg ids_csv "$ids_csv" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$CONFIRMED_BY" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        '{
            ts:$ts, epoch:$epoch, method:$method, path:$path,
            mergeInto:$mergeInto,
            profilesIds:($ids_csv | split(",")),
            requester:$requester,
            confirmed_by:$confirmed_by,
            approval_msg_id:$approval_msg_id
        }' \
        >> "$RECENT_MERGES_PATH" 2>/dev/null || true
}

# --- Bulk destructive-operation gate helpers (incident 2026-05-26) ---

# is_bulk_destructive_op METHOD PATH -> 0 if this call counts toward the
# destructive-delete budget, 1 if it should be ignored.
#
# Scope: the DELETE verb only. POSTs are excluded by design — claim
# reject/revert run 50+ per legitimate fraud sweep, and merge/unmerge are
# already tier-2 gated per-call. A small DENY-LIST of harmless/regenerable
# DELETE path globs is excluded (see $BULK_DESTRUCTIVE_EXCLUDE_PATH).
#
# Deliberately FAIL-OPEN-TO-COUNTING: a missing exclude file means EVERYTHING
# counts. This is the opposite of is_tier2_endpoint (which fails closed-to-not-
# tier2) and is intentional — the 2026-05-26 incident was an endpoint on no
# list at all, so the safe default here is "count it".
is_bulk_destructive_op() {
    local method="$1" path="$2"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ "$method_uc" == "DELETE" ]] || return 1
    # Strip any query string before matching the deny-list globs.
    path="${path%%\?*}"
    if [[ -f "$BULK_DESTRUCTIVE_EXCLUDE_PATH" ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line## }"
            line="${line%% }"
            [[ -z "$line" ]] && continue
            # Glob match: RHS intentionally unquoted so `*` is active.
            # shellcheck disable=SC2053
            if [[ "$path" == $line ]]; then
                return 1
            fi
        done < "$BULK_DESTRUCTIVE_EXCLUDE_PATH"
    fi
    return 0
}

# count_recent_destructive_ops -> prints the count of recorded destructive
# DELETEs within the last BULK_DESTRUCTIVE_WINDOW_SECS. Window-only (NOT
# per-run): a simple "N in the last X minutes" rate limit is both simpler and
# strictly safer than per-run scoping (per-run resets the counter every run
# and is more permissive). jq -R -n + inputs idiom mirrors the reverse guard.
count_recent_destructive_ops() {
    [[ -f "$BULK_DESTRUCTIVE_PATH" ]] || { echo 0; return 0; }
    local cutoff_epoch=$(( $(date +%s) - BULK_DESTRUCTIVE_WINDOW_SECS ))
    jq -R -r -n \
        --argjson cutoff "$cutoff_epoch" \
        '[inputs | fromjson? // empty | select(type == "object")]
         | map(select((.epoch // 0) >= $cutoff))
         | length' \
        "$BULK_DESTRUCTIVE_PATH" 2>/dev/null || echo 0
}

# write_bulk_destructive_audit METHOD PATH CONFIRMED_BY COUNT [BYPASS]
#   -> 0 written / 1 unwritable (caller MUST refuse the write).
#
# Audits an approved bulk-destructive write BEFORE it executes. Fail-closed:
# "deleted en masse, no record of who approved it" is the worse failure mode.
# Extracted so the two approval paths below (second-approver and god-mode
# self-approve) cannot drift apart — a divergence here loses the audit trail
# on one path only, which is the kind of hole nobody notices until it matters.
write_bulk_destructive_audit() {
    local method="$1" path="$2" confirmed_by="$3" count="$4" bypass="${5:-}" godmode_path="${6:-}"

    if ! mkdir -p "$(dirname "$BULK_DESTRUCTIVE_AUDIT_PATH")" 2>/dev/null; then
        echo "MUSO_BULK_DESTRUCTIVE_AUDIT_UNWRITABLE: cannot create $(dirname "$BULK_DESTRUCTIVE_AUDIT_PATH") — refusing bulk-destructive write to preserve audit trail." >&2
        return 1
    fi
    local ts audit_rc=0
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n -c \
        --arg ts "$ts" \
        --arg method "$method" \
        --arg path "$path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg confirmed_by "$confirmed_by" \
        --arg approval_msg_id "$APPROVAL_MSG_ID" \
        --argjson count_at_trip "$count" \
        --argjson threshold "$BULK_DESTRUCTIVE_THRESHOLD" \
        --argjson window_secs "$BULK_DESTRUCTIVE_WINDOW_SECS" \
        --arg approval_author_id "$APPROVAL_AUTHOR_ID" \
        --arg approval_channel "$APPROVAL_CHANNEL" \
        --arg bypass "$bypass" \
        --arg godmode_path "$godmode_path" \
        '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id, count_at_trip:$count_at_trip, threshold:$threshold, window_secs:$window_secs, approval_author_id:$approval_author_id, approval_channel:$approval_channel}
         + (if $bypass == "" then {} else {bypass:$bypass} end)
         + (if $godmode_path == "" then {} else {godmode_allowlist:$godmode_path} end)' \
        >> "$BULK_DESTRUCTIVE_AUDIT_PATH" || audit_rc=$?
    if (( audit_rc != 0 )); then
        echo "MUSO_BULK_DESTRUCTIVE_AUDIT_UNWRITABLE: append to $BULK_DESTRUCTIVE_AUDIT_PATH failed (rc=$audit_rc) — refusing bulk-destructive write to preserve audit trail." >&2
        return 1
    fi
    return 0
}

# enforce_bulk_destructive_gate METHOD PATH -> 0 allow / 1 block.
# Runs in cmd_call after the merge guard, before the dry-run short-circuit.
enforce_bulk_destructive_gate() {
    local method="$1" path="$2"
    is_bulk_destructive_op "$method" "$path" || return 0
    is_dry_run_mode && return 0

    local count audit_confirmed_by="" audit_bypass="" audit_godmode_path=""
    count="$(count_recent_destructive_ops)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count >= BULK_DESTRUCTIVE_THRESHOLD )); then
        # Threshold reached. Two ways past it, and only two.
        #
        # (1) GOD-MODE SELF-APPROVE (policy 2026-08-26). Aaron, Jan and Nick are
        # co-equal on the operations surface and Jan owns it, so paging one of
        # them to authorize what another already asked for is pure delay, not
        # safety. They clear this gate themselves. What is still required is the
        # AUDIT ANCHOR — --approval-msg-id, the ts of their own request message —
        # so "who said delete these rows" stays answerable afterwards.
        #
        # This does NOT reopen incident 2026-05-26: that was 285 DELETEs off a
        # VAGUE request ("sources aren't capturing, fix it"), and vagueness has
        # no message to cite. Volume was never the problem. Anyone off the
        # god-mode list is unchanged and still needs a real second approver, so
        # the blast-radius cap stands for the whole rest of the org.
        if is_tier2_godmode_requester "${REQUESTER_EMAIL:-}"; then
            if is_removal_endpoint "$method" "$path"; then
                refuse_removal_self_approve "$method" "$path"
                return 1
            fi
            if [[ -z "$APPROVAL_MSG_ID" ]]; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_MSG_REQUIRED: ${count} destructive DELETE(s) in the last ${BULK_DESTRUCTIVE_WINDOW_SECS}s have reached the bulk threshold (${BULK_DESTRUCTIVE_THRESHOLD}).

'${REQUESTER_EMAIL:-}' is on the god-mode allowlist and clears this gate alone. You do not need anyone else. Re-issue the SAME call with:
    --approval-msg-id <slack_ts of THEIR request message>

That timestamp is the audit anchor — it records which message authorized deleting these rows. Take it from the request you are already acting on; do not ask for a new one and do not wait.

Two things this does not cover: if the request never named what to delete, read the rows back and post the list first (you cannot cite a decision that was not made). If a DIFFERENT set of rows comes up later, that is a new decision and needs its own message.
EOF
                return 1
            fi
            # PROVENANCE. Nothing here authenticates: every flag is a string the
            # caller supplies, and that is equally true of the --confirmed-by path
            # below (on the pre-2026-08-26 gate, `--confirmed-by jan
            # --approval-msg-id x` was accepted just the same). What this branch
            # must not do is make forging CHEAPER: --requester is auto-stamped
            # from whoever is in-thread, so if the msg-id were any non-empty
            # string, self-approval would cost the agent nothing deliberate.
            #
            # So require a citation that is checkable AFTER the fact:
            #   - a real Slack ts shape, not a placeholder;
            #   - the Slack id of the message AUTHOR, which must itself be an
            #     allowlisted identity.
            # Someone reading the audit row can then open that exact message and
            # see whether it named these rows. Authenticating the citation
            # against Slack at call time is the real fix and belongs in its own
            # change -- it has to cover BOTH approval paths, not just this one.
            if [[ ! "$APPROVAL_MSG_ID" =~ ^[0-9]{10}\.[0-9]{6}$ ]]; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_MSG_INVALID: --approval-msg-id '${APPROVAL_MSG_ID}' is not a Slack message timestamp.
Expected the ts of THEIR request message, e.g. 1787416248.722279 (10 digits, a dot, 6 digits). Copy it from the message you are acting on; do not invent one and do not pass a placeholder.
EOF
                return 1
            fi
            if [[ -z "$APPROVAL_AUTHOR_ID" ]]; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_REQUIRED: self-approval also needs --approval-author-id <Uxxxxxxxx>, the Slack id of whoever WROTE the message you are citing.
Without it the audit row records only a timestamp and a handle you typed, which is indistinguishable from one you inferred. Pass the author id from the same message as --approval-msg-id. You still do not need anyone else's approval.
EOF
                return 1
            fi
            # Must be a Slack UID, not an email. resolve_slack_to_email echoes
            # an unrecognised input straight back, so without this shape check
            # `--approval-author-id jan@muso.ai` would sail through the
            # allowlist match below and the flag would prove nothing beyond what
            # --requester already claims. The point of naming an author is to
            # name a Slack IDENTITY that can be looked up in the cited thread.
            if [[ ! "$APPROVAL_AUTHOR_ID" =~ ^U[A-Z0-9]{6,}$ ]]; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_INVALID: --approval-author-id '${APPROVAL_AUTHOR_ID}' is not a Slack user id.
Pass the Uxxxxxxxx id of whoever wrote the message you are citing (an email is not accepted here — the id is what makes the row checkable against the thread).
EOF
                return 1
            fi
            local _author_email
            _author_email="$(resolve_slack_to_email "$APPROVAL_AUTHOR_ID" 2>/dev/null || true)"
            if ! is_tier2_godmode_requester "$_author_email"; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_SELF_APPROVE_AUTHOR_INVALID: --approval-author-id '${APPROVAL_AUTHOR_ID}' does not resolve to a god-mode identity.
Self-approval means the cited message was written by someone who can authorize this. Cite a message authored by an allowlisted requester, or use --confirmed-by <approver> --approval-msg-id <ts> instead.
EOF
                return 1
            fi

            # A god-mode requester does not NEED --confirmed-by, but if the
            # caller supplied one it must still be a real approver. Skipping the
            # check would let `--confirmed-by <not-an-approver>` through (it was
            # refused before this branch existed) and then quietly attribute the
            # approval to the requester instead — an audit row naming someone the
            # caller never did. Validate it, and record what was actually named.
            if [[ -n "$CONFIRMED_BY" ]]; then
                if ! is_tier2_approver "$CONFIRMED_BY"; then
                    cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the tier-2 approver allowlist.
'${REQUESTER_EMAIL:-}' is on the god-mode allowlist and does not need --confirmed-by at all — drop the flag, or name a real approver from $TIER2_APPROVERS_PATH.
EOF
                    return 1
                fi
                audit_confirmed_by="$CONFIRMED_BY"
            else
                # Their own message IS the decision.
                audit_confirmed_by="${REQUESTER_EMAIL:-}"
            fi
            audit_bypass="god_mode_self_approve"
            # Record WHICH allowlist granted this. TIER2_GODMODE_PATH is an env
            # override (every path/threshold in this wrapper is — see the note in
            # check-no-canonical-godmode-allowlist.sh), so a caller who controls
            # the environment can point it anywhere. That cannot be closed here,
            # but it can be made VISIBLE: an audit row naming a foreign allowlist
            # is evidence, where a bare bypass flag would look routine.
            audit_godmode_path="$TIER2_GODMODE_PATH"
        # (2) EXPLICIT SECOND APPROVER, for everyone else. Unchanged by the
        # 2026-08-26 policy: off the god-mode list, --requester is attribution,
        # never authorization, and an --approval-msg-id alone is not a skeleton
        # key. This is the branch that still holds the 2026-05-26 blast-radius
        # cap for the rest of the org.
        else
            if [[ -z "$CONFIRMED_BY" ]]; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED: ${count} destructive DELETE(s) in the last ${BULK_DESTRUCTIVE_WINDOW_SECS}s have reached the bulk threshold (${BULK_DESTRUCTIVE_THRESHOLD}).
This is the 2026-05-26 incident class (285 analytics-source DELETEs off one vague request). STOP autonomous deletion now.

To proceed you must have an EXPLICIT in-thread human decision to delete this many records, then pass BOTH:
    --confirmed-by <handle>   (one of: $(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | tr '\n' ' '))
    --approval-msg-id <slack_ts>

'${REQUESTER_EMAIL:-<no --requester>}' is not on the god-mode allowlist, so this call needs an approver's decision that NAMES the rows being deleted.

If the person who asked is on the approver list above AND enumerated the exact targets (a list of ids/titles, or "all N of X" where you have already read and posted those N), their own request message IS that decision: pass their handle and the timestamp of THAT message. You do not need to find a second human, and you should not page anyone.

That decision covers the target set it enumerated and ONLY that set — finishing an approved batch is not a new decision, but a different set of rows is. If the request was vague, or the requester is not on the list above, stop and get an explicit "yes, delete those N" before continuing.
EOF
                return 1
            fi
            if ! is_tier2_approver "$CONFIRMED_BY"; then
                cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_INVALID: --confirmed-by '${CONFIRMED_BY}' is not in the tier-2 approver allowlist.
Allowed approvers (from $TIER2_APPROVERS_PATH):
$(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | sed 's/^/  - /' || echo "  (file missing)")
EOF
                return 1
            fi
            if [[ -z "$APPROVAL_MSG_ID" ]]; then
                echo "MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED: --approval-msg-id <slack_ts> is required alongside --confirmed-by for bulk-destructive writes (audit trail)." >&2
                return 1
            fi
            audit_confirmed_by="$CONFIRMED_BY"
        fi

        # ONE audit call for every path that gets past the threshold — a new
        # approval branch cannot forget it. Fail-closed: no audit, no DELETE.
        write_bulk_destructive_audit \
            "$method" "$path" "$audit_confirmed_by" "$count" "$audit_bypass" \
            "$audit_godmode_path" || return 1
    fi

    # Record this attempt BEFORE the DELETE is issued, and FAIL CLOSED if it
    # cannot be persisted. Otherwise an unwritable state dir leaves the counter
    # at 0 forever and silently disables the gate — unlimited deletes with no
    # threshold (QA, PR #390). Runs for BOTH under-threshold and approved calls.
    if ! record_destructive_op "$method" "$path"; then
        echo "MUSO_BULK_DESTRUCTIVE_COUNTER_UNWRITABLE: cannot persist the destructive-op counter (${BULK_DESTRUCTIVE_PATH}) — refusing the DELETE. The gate must record this call to bound the blast radius; fix the state dir (MUSO_OPS_STATE_DIR=${MUSO_OPS_STATE_DIR}) and retry." >&2
        return 1
    fi
    return 0
}

# record_destructive_op METHOD PATH -> 0 recorded (or no-op), 1 could-not-persist.
# Records the destructive DELETE ATTEMPT to the rolling counter. FAIL-CLOSED: a
# write failure returns non-zero so the caller (enforce_bulk_destructive_gate)
# refuses the DELETE rather than letting the counter sit at 0 forever and
# silently disable the guard (QA, PR #390). Called from the gate BEFORE the curl
# — counting the attempt (not only a 2xx) lands the record before the
# irreversible call and over-counts toward safety.
record_destructive_op() {
    local method="$1" path="$2"
    is_bulk_destructive_op "$method" "$path" || return 0
    is_dry_run_mode && return 0
    local _path="${path%%\?*}"
    mkdir -p "$(dirname "$BULK_DESTRUCTIVE_PATH")" 2>/dev/null || return 1
    local epoch ts line
    epoch=$(date +%s)
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    line=$(jq -n -c \
        --arg ts "$ts" \
        --argjson epoch "$epoch" \
        --arg method "$method" \
        --arg path "$_path" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        '{ts:$ts, epoch:$epoch, method:$method, path:$path, requester:$requester}' 2>/dev/null) || return 1
    printf '%s\n' "$line" >> "$BULK_DESTRUCTIVE_PATH" 2>/dev/null || return 1
    # Remember the row's correlation key (epoch + path) for the outcome ledger.
    DESTRUCTIVE_OP_EPOCH="$epoch"
    DESTRUCTIVE_OP_PATH="$_path"
    return 0
}

# write_destructive_op_result OUTCOME HTTP_STATUS -> always 0.
# Post-call companion to record_destructive_op: one row in
# destructive-ops-results.jsonl per counter row, keyed by the same (epoch, path)
# pair, saying whether the DELETE landed. Kept OUT of destructive-ops.jsonl on
# purpose — count_recent_destructive_ops reads that file, and a changed row
# shape there would skew the blast-radius gate. No-op unless this call wrote a
# counter row. Failure mode matches write_dry_run_audit: LOUD stderr warning,
# never break the call (the DELETE has already happened; refusing now helps no one).
# OUTCOME: ok | http_error | transport_error (sent, delivery ambiguous) |
# not_sent (login or retry config failed, DELETE definitely never left). HTTP_STATUS empty -> null.
DESTRUCTIVE_OP_EPOCH=""
DESTRUCTIVE_OP_PATH=""
write_destructive_op_result() {
    local outcome="$1" http_status="${2:-}"
    [[ -n "$DESTRUCTIVE_OP_EPOCH" ]] || return 0
    local ts line
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! line=$(jq -n -c \
        --arg ts "$ts" \
        --argjson epoch "$DESTRUCTIVE_OP_EPOCH" \
        --arg method "$CALL_METHOD_FOR_RESULT" \
        --arg path "$DESTRUCTIVE_OP_PATH" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg http_status "$http_status" \
        --arg outcome "$outcome" \
        '{ts:$ts, epoch:$epoch, method:$method, path:$path, requester:$requester,
          http_status:($http_status | tonumber? // null), outcome:$outcome}' 2>/dev/null); then
        echo "MUSO_DESTRUCTIVE_OUTCOME_UNWRITABLE: could not build the outcome row for ${CALL_METHOD_FOR_RESULT} ${DESTRUCTIVE_OP_PATH} (${outcome}); the call itself proceeded." >&2
        DESTRUCTIVE_OP_EPOCH=""
        return 0
    fi
    if ! { mkdir -p "$(dirname "$BULK_DESTRUCTIVE_RESULTS_PATH")" \
            && printf '%s\n' "$line" >> "$BULK_DESTRUCTIVE_RESULTS_PATH"; } 2>/dev/null; then
        echo "MUSO_DESTRUCTIVE_OUTCOME_UNWRITABLE: could not append to ${BULK_DESTRUCTIVE_RESULTS_PATH}; outcome row LOST for ${CALL_METHOD_FOR_RESULT} ${DESTRUCTIVE_OP_PATH} (${outcome}, status ${http_status:-none}); the call itself proceeded." >&2
    fi
    DESTRUCTIVE_OP_EPOCH=""   # exactly one outcome row per counter row
    return 0
}

# --- Codex model-health gate (incident 2026-06-08) ---
# A silent codex auth-permanent / refresh-token-race degradation drops the WHOLE fleet
# onto a weak fallback model (openrouter/openai/gpt-5.4-mini) that the agent CANNOT
# perceive — openclaw's `Model Fallback:` banner is built on the delivery path and is
# never injected into the prompt (memory reference_agent_cannot_see_own_fallback_state).
# On 2026-06-08 that degraded model misrouted a track-metadata fix into the credit-
# verification batch and fabricated a ticket + human handoff. SOUL doctrine alone can't
# stop this (the agent can't read its own model state), so this is the mechanical guard:
# refuse state-changing WRITES while codex is degraded, returning a hard error in the
# tool RESULT — the one signal the agent CAN see — so it reports "couldn't complete,
# deferring" instead of acting on bad judgment. READS (GET/HEAD) pass through untouched
# so the agent can still investigate while degraded.
#
# Shares the exact probe the Stripe money-path uses (scripts/lib/codex-health.sh ->
# codex_health_gate), so admin writes can never drift to a weaker check than refunds.
# FAIL-CLOSED: an unreadable journal or a missing lib refuses the write. Self-skips in
# dry-run (no prod mutation) only — there is deliberately NO caller-settable bypass
# (matching the Stripe money-path gate), so the degraded model this guards against
# cannot disable it by setting a per-command env var when it invokes the tool.
CODEX_HEALTH_LIB="${CODEX_HEALTH_LIB:-/opt/hydra/scripts/lib/codex-health.sh}"
CODEX_HEALTH_GATEWAY_UNIT="${OPENCLAW_GATEWAY_UNIT:-openclaw-gateway-main}"
CODEX_HEALTH_WINDOW_MIN="${CODEX_HEALTH_WINDOW_MIN:-5}"

enforce_codex_health_gate() {
    local method="$1"
    # Reads always allowed — only state-changing writes are gated.
    local method_lc
    method_lc="$(printf %s "$method" | tr '[:upper:]' '[:lower:]')"
    case "$method_lc" in
        get|head) return 0 ;;
    esac
    # Dry-run never touches prod; skip (consistent with every other gate here).
    is_dry_run_mode && return 0

    # Missing lib = packaging/rsync regression → fail closed rather than skip the check.
    if [[ ! -r "$CODEX_HEALTH_LIB" ]]; then
        echo "MUSO_CODEX_HEALTH_LIB_MISSING: cannot read codex-health lib at ${CODEX_HEALTH_LIB} — refusing the ${method} write (model health unverifiable). Restore scripts/lib/codex-health.sh on the host." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$CODEX_HEALTH_LIB"

    local reason rc=0
    reason="$(codex_health_gate "$CODEX_HEALTH_GATEWAY_UNIT" "$CODEX_HEALTH_WINDOW_MIN" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        cat >&2 <<EOF
MUSO_CODEX_DEGRADED: refusing ${method} write — ${reason}.
The agent may be on a weak fallback model it cannot perceive (openclaw's
\`Model Fallback:\` banner is delivery-only, never in the prompt). A degraded
model must not issue admin writes. The write did NOT execute.
Report plainly that it did not complete and defer to a human — @-mention Nick
(<@U0AL36NADEY>). Reads are still available. Retry once codex health is
confirmed (\`openclaw --profile main agents list\`).
EOF
        return 1
    fi
    return 0
}

# Admin list bounds (firstmate 066-070, incident 2026-10-19 05:38-05:50Z): an ad-hoc
# count script paged GET /admin/credit-requests?status=approved&limit=500&page=1..800 as the
# shared operations identity; core's list is OFFSET-paged, so deep pages are O(offset) and
# site p99 went 0.28 -> 0.98s. Bulk questions go to Trino (or a profile/track-filtered read).
# For the credit-request list endpoints, every identity through this wrapper:
#   - limit above ADMIN_LIST_MAX_LIMIT (200) without profilesIds/trackId is refused;
#   - an offset ((page-1)*limit) above ADMIN_LIST_MAX_OFFSET (20000) without a filter is refused;
#   - list calls are paced to at most ADMIN_LIST_MAX_PER_SEC (2) per second per identity
#     (= core's planned 120/min agent budget), across processes, via a per-identity state file.
# The query is read the way core reads it (qs + parseInt): percent- and '+'-decoded, route
# case-insensitive with repeated/trailing slashes collapsed, leading zeros and trailing junk
# ignored like parseInt. A duplicated or bracketed limit/page/profilesIds/trackId (qs turns it
# into an array or object) is refused as ambiguous. Pacing fails CLOSED: if its state cannot be
# locked, read or written, the call is refused (QA + Fable on hydra#1270).
ADMIN_LIST_MAX_LIMIT="${ADMIN_LIST_MAX_LIMIT:-200}"
ADMIN_LIST_MAX_OFFSET="${ADMIN_LIST_MAX_OFFSET:-20000}"
ADMIN_LIST_MAX_PER_SEC="${ADMIN_LIST_MAX_PER_SEC:-2}"
ADMIN_LIST_LOCK_TRIES="${ADMIN_LIST_LOCK_TRIES:-100}"  # x 0.3s before a busy pacing lock refuses

admin_list_urldecode() { # percent- and '+'-decode, backslashes kept literal
    local s="${1//\\/\\\\}"
    s="${s//+/ }"
    printf '%b' "${s//%/\\x}"
}

# parseInt as core applies it: optional leading whitespace and sign, then digits; anything
# after is ignored. Prints the integer, "NaN", or "HUGE" (more than 9 digits).
admin_list_parseint() {
    local v="$1" sign="" digits
    v="${v#"${v%%[![:space:]]*}"}"
    case "$v" in -*) sign="-"; v="${v#-}" ;; +*) v="${v#+}" ;; esac
    digits="${v%%[!0-9]*}"
    [[ -n "$digits" ]] || { printf 'NaN'; return 0; }
    digits="${digits#"${digits%%[!0]*}"}"
    [[ -n "$digits" ]] || digits=0
    (( ${#digits} > 9 )) && { printf 'HUGE'; return 0; }
    printf '%s%s' "$sign" "$digits"
}

admin_list_refuse() { echo "muso-admin-api: refusing ${ADMIN_LIST_METHOD:-GET} $1: $2" >&2; return 2; }

enforce_admin_list_bounds() {
    local method="$1" path="$2" upper
    upper="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    # HEAD is a read too, and core serves it through the GET list handler (same
    # unfiltered OFFSET query, body discarded), so it is bounded and paced like GET.
    [[ "$upper" == "GET" || "$upper" == "HEAD" ]] || return 0
    local ADMIN_LIST_METHOD="$upper"
    local raw_route="${path%%\?*}" query="" route
    [[ "$path" == *\?* ]] && query="${path#*\?}"
    query="${query%%#*}"
    route="$(admin_list_urldecode "$raw_route" | tr '[:upper:]' '[:lower:]')"
    while [[ "$route" == *//* ]]; do route="${route//\/\//\/}"; done
    route="${route%/}"
    case "$route" in
        */admin/credit-requests|*/admin/credit-requests/profiles) ;;
        *) return 0 ;;
    esac
    local kv key val name limit_raw="" page_raw="" profiles="" track="" seen=" "
    local IFS='&'
    for kv in $query; do
        [[ -n "$kv" ]] || continue
        key="$(admin_list_urldecode "${kv%%=*}")"
        if [[ "$kv" == *=* ]]; then val="$(admin_list_urldecode "${kv#*=}")"; else val=""; fi
        for name in limit page profilesIds trackId; do
            if [[ "$key" == "$name" ]]; then
                [[ "$seen" == *" $name "* ]] && { unset IFS; admin_list_refuse "$route" "'$name' appears more than once (ambiguous)"; return 2; }
                seen="$seen$name "
                case "$name" in
                    limit) limit_raw="$val" ;; page) page_raw="$val" ;;
                    profilesIds) profiles="$val" ;; trackId) track="$val" ;;
                esac
            elif [[ "$key" == "${name}["* || "$key" == "${name}."* ]]; then
                unset IFS; admin_list_refuse "$route" "'$key' (bracket/dot form of '$name' is ambiguous)"; return 2
            fi
        done
    done
    unset IFS
    local limit page filtered=0
    limit="$(admin_list_parseint "$limit_raw")"
    page="$(admin_list_parseint "$page_raw")"
    [[ "$limit" == "HUGE" ]] && { admin_list_refuse "$route" "limit is out of range"; return 2; }
    [[ "$limit" == "NaN" || "$limit" == "0" ]] && limit=10
    (( limit < 0 )) && { admin_list_refuse "$route" "negative limit"; return 2; }
    [[ "$page" == "HUGE" ]] && { admin_list_refuse "$route" "page is out of range"; return 2; }
    [[ "$page" == "NaN" ]] && page=1
    (( page < 1 )) && page=1
    profiles="${profiles//[[:space:],]/}"; track="${track//[[:space:]]/}"
    # Only the plain list applies profilesIds/trackId (core list.js). /profiles ignores both
    # and always runs the unfiltered grouped query, so it is never "filtered" (QA r2).
    if [[ "$route" == */admin/credit-requests ]] && [[ -n "$profiles" || -n "$track" ]]; then
        filtered=1
    fi
    if (( ! filtered )) && (( limit > ADMIN_LIST_MAX_LIMIT )); then
        admin_list_refuse "$route" "limit=$limit and no profilesIds/trackId (max $ADMIN_LIST_MAX_LIMIT). For a bulk count or export use Trino, not the admin list API."; return 2
    fi
    if (( ! filtered )) && (( (page - 1) * limit > ADMIN_LIST_MAX_OFFSET )); then
        admin_list_refuse "$route" "page=$page (offset $(( (page - 1) * limit )) > $ADMIN_LIST_MAX_OFFSET) with no profilesIds/trackId: deep unfiltered paging is O(offset) on core. Use an updatedAt window, a filter, or Trino."; return 2
    fi
    admin_list_pace
}

# At most ADMIN_LIST_MAX_PER_SEC list calls per second per identity, across processes.
# Fails CLOSED: any state/lock error refuses the call (rc 2).
admin_list_pace() {
    local ident="${MUSO_ADMIN_IDENTITY:-default}" state lockdir now sec cnt waited=0 rc=0
    state="${MUSO_OPS_STATE_DIR}/admin-list-pace.${ident//[^A-Za-z0-9_.-]/_}"
    lockdir="$state.lockdir"
    mkdir -p "$MUSO_OPS_STATE_DIR" 2>/dev/null && [[ -w "$MUSO_OPS_STATE_DIR" ]] || {
        echo "muso-admin-api: refusing list call: pacing state dir $MUSO_OPS_STATE_DIR is not writable" >&2; return 2; }
    # mkdir is atomic everywhere (no flock on macOS). A lock older than 60s is stale.
    until mkdir "$lockdir" 2>/dev/null; do
        if [[ -d "$lockdir" ]] && [[ -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
            rmdir "$lockdir" 2>/dev/null; continue
        fi
        (( waited++ >= ADMIN_LIST_LOCK_TRIES )) && { echo "muso-admin-api: refusing list call: pacing lock $lockdir is busy" >&2; return 2; }
        sleep 0.3
    done
    while :; do
        now="$(date +%s)"
        if [[ -e "$state" ]]; then
            if ! read -r sec cnt < "$state" 2>/dev/null; then sec=""; fi
            [[ "$sec" =~ ^[0-9]+$ && "$cnt" =~ ^[0-9]+$ ]] || {
                if [[ -s "$state" ]]; then
                    echo "muso-admin-api: refusing list call: pacing state $state is unreadable or corrupt" >&2
                    rmdir "$lockdir" 2>/dev/null; return 2
                fi
                sec=0; cnt=0; }
        else
            sec=0; cnt=0
        fi
        if [[ "$sec" == "$now" ]] && (( cnt >= ADMIN_LIST_MAX_PER_SEC )); then sleep 0.3; continue; fi
        if [[ "$sec" == "$now" ]]; then cnt=$((cnt + 1)); else cnt=1; fi
        if ! { printf '%s %s\n' "$now" "$cnt" > "$state.tmp" && mv -f "$state.tmp" "$state"; } 2>/dev/null; then
            echo "muso-admin-api: refusing list call: pacing state $state cannot be written" >&2; rc=2
        fi
        break
    done
    rmdir "$lockdir" 2>/dev/null
    return $rc
}

cmd_call() {
    check_env
    local method="${1:?Usage: call <METHOD> <path> [json-body]}"
    local path="${2:?Usage: call <METHOD> <path> [json-body]}"
    local body="${3:-}"

    # Misplaced-flag guard (incident 2026-06-30). Global flags (--requester /
    # --confirmed-by / --approval-msg-id / --profile-audit-id) MUST precede the
    # `call` subcommand. If one is left AFTER the path it lands here as the
    # positional JSON body; the API then 400s on a body-parse failure that
    # core-backend masks behind a generic "Unavailable service" message — which
    # reads as a phantom service outage (a one-char typo cost hours of false
    # alarm). A real JSON body never starts with "--", so this is unambiguous.
    # Fail loud instead of POSTing a malformed body. (See dispatcher-arg-validation.)
    case "$body" in
        --*)
            cat >&2 <<EOF
muso-admin-api: refusing — request body looks like a misplaced flag: '${body}'
  Global flags go BEFORE the command. Did you mean:
    bash $0 ${body} <value> call ${method} ${path}
EOF
            return 2
            ;;
    esac

    # Trailing-flag guard (2026-11-13). The same mistake one slot further right: a
    # global flag left AFTER the json body is never parsed (the dispatcher stops at the
    # command), so the call ran as if the flag had not been passed at all. For an approve
    # that meant the gate answered "--evidence-excerpt is required" to a caller that HAD
    # passed --evidence-excerpt - 62 rows of exactly that are in the credit-review ledger,
    # each one read as "the caller sent no evidence". Nothing after the body is ever
    # read, so a flag there is always a mistake: refuse it and name it.
    local extra
    for extra in "${@:4}"; do
        case "$extra" in
            --*)
                cat >&2 <<EOF
muso-admin-api: refusing — '${extra}' comes after the request body and was NOT read
  Global flags go BEFORE the command (nothing after the body is parsed). Did you mean:
    bash $0 ${extra} <value> call ${method} ${path} '<json-body>'
EOF
                return 2
                ;;
        esac
    done

    # Admin list bounds (incident 2026-10-19): refuse unfiltered big/deep credit-request
    # list pulls and pace list calls per identity. Reads only; never touches writes.
    if ! enforce_admin_list_bounds "$method" "$path"; then
        return 2
    fi

    # Codex model-health gate (incident 2026-06-08). Refuse WRITES while the fleet is
    # silently degraded onto a weak fallback model the agent can't perceive; READS pass
    # through. Runs first so a degraded model is stopped before any other gate logic.
    if ! enforce_codex_health_gate "$method"; then
        return 1
    fi

    # Credit approve gate — deterministic, runs in bash below openclaw's hook layer.
    if ! enforce_credit_approve_gate "$method" "$path" "$body"; then
        # Truth floor (PR 1): log the gate rejection to the credit-request
        # results.jsonl so compute-run-summary.sh sees it in dry-run and prod.
        # Scoped inside the helper to credit-request writes only, so this is
        # a no-op for any other path.
        write_credit_request_result "$method" "$path" "$body" "rejected_by_gate" "" "evidence-excerpt missing, too short/long, no fresh session log, Tier 1 web_fetch substitution, or insufficient grounded evidence — see stderr above"
        return 1
    fi

    # Credit reject gate (incident 2026-07-22). Rejection is never autonomous —
    # requires --confirmed-by + --approval-msg-id. Runs even in dry-run. Same
    # truth-floor logging as the approve gate so compute-run-summary.sh sees
    # the refusal.
    if ! enforce_credit_reject_gate "$method" "$path" "$body"; then
        write_credit_request_result "$method" "$path" "$body" "rejected_by_gate" "" "status=rejected without --confirmed-by <approver> + --approval-msg-id — rejection is never autonomous; keep the request in user_verification_needed or escalate to Jan"
        return 1
    fi

    # Removal gate (firstmate 122): removals never go out through this wrapper.
    if ! enforce_removal_gate "$method" "$path"; then
        return 1
    fi

    # Tier-2 approval gate (incident 2026-04-29). Skipped in dry-run mode.
    if ! enforce_tier2_approval_gate "$method" "$path"; then
        return 1
    fi

    # Claim-verify pace gate (2026-10-11): one claim verify per 20s host-wide.
    if ! enforce_claim_verify_pace_gate "$method" "$path"; then
        return 1
    fi

    # Reverse-direction guard for /admin/profiles/merge (incident 2026-04-29).
    if ! enforce_merge_reverse_direction_guard "$method" "$path" "$body"; then
        return 1
    fi

    # Profile-enrich link gate (incident 2026-08-05, third recurrence). Refuses
    # a profile capture that carries no profileId — it would be "accepted" and
    # then attach to nothing. Runs even in dry-run: the defect is the request
    # SHAPE, so a dry-run must not report success for a call that can never work.
    if ! enforce_profile_enrich_link_gate "$method" "$path" "$body"; then
        return 1
    fi

    # Bulk destructive-operation gate (incident 2026-05-26). Caps the blast
    # radius of mass DELETEs. God-mode requesters self-approve with
    # --approval-msg-id (policy 2026-08-26); everyone else needs an approver's
    # --confirmed-by. Self-skips in dry-run.
    DESTRUCTIVE_OP_EPOCH=""
    CALL_METHOD_FOR_RESULT="$method"
    if ! enforce_bulk_destructive_gate "$method" "$path"; then
        return 1
    fi

    # Dry-run config-mismatch guard (R2-1 — 2026-04-23 incident class).
    # The 09:02 UTC dry-run had 12 UVN PATCHes hit the real admin API because
    # OPS_DRY_RUN=1 was set in B0's shell but NOT re-exported in a later exec.
    # Each exec tool call is a fresh shell; env doesn't propagate across them.
    # When the runlog header says "this run is a dry-run" but the current
    # shell's OPS_DRY_RUN is unset, refuse the write rather than leak to prod.
    #
    # Scoped to /admin/credit-requests writes (PUT/PATCH) — matches the truth
    # floor's scope. Other admin APIs can still be called directly; this guard
    # is specifically about the credit-verification batch path.
    if ! is_dry_run_mode; then
        local _method_uc_for_guard
        _method_uc_for_guard="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
        if [[ "$path" == /admin/credit-requests* ]] \
            && { [[ "$_method_uc_for_guard" == "PUT" ]] || [[ "$_method_uc_for_guard" == "PATCH" ]]; }; then
            local header_dryrun
            header_dryrun="$(resolve_run_header_dryrun)"
            if [[ "$header_dryrun" == "true" ]]; then
                local latest_runlog
                latest_runlog="$(cat "${OPS_RUNLOG_DIR}/latest.txt" 2>/dev/null || echo unknown)"
                cat >&2 <<EOF
ERROR: run_header says dryRun:true but OPS_DRY_RUN env is unset in this shell — refusing to write to real admin API.
This prevents the 2026-04-23 incident class where a later exec shell missed OPS_DRY_RUN=1 and leaked 12 UVN PATCHes to prod.
Export OPS_DRY_RUN=1 in every exec that makes /admin/credit-requests writes:
    export OPS_DRY_RUN=1
Runlog: ${latest_runlog}
EOF
                write_credit_request_result "$method" "$path" "$body" "dry_run_config_mismatch" "" "runlog.dryRun=true but OPS_DRY_RUN env unset in this shell — would have leaked to prod"
                return 1
            fi
        fi
    fi

    # Dry-run short-circuit (issue #145). Gate ran above, so a broken batch
    # still fails loudly. Fail-CLOSED method check: anything that isn't a
    # pure read (GET/HEAD, case-insensitive) is intercepted. This prevents
    # lower-case `put`, typos, and future verbs from bypassing dry-run.
    if is_dry_run_mode; then
        local method_lc
        method_lc="$(printf %s "$method" | tr '[:upper:]' '[:lower:]')"
        case "$method_lc" in
            get|head)
                : # read — fall through to real API
                ;;
            *)
                DRY_RUN_AUDIT_FAILED=0
                write_dry_run_audit "$method" "$path" "$body" "call"
                write_credit_request_result "$method" "$path" "$body" "dry_run_intercept" "200" ""
                emit_dry_run_response
                return 0
                ;;
        esac
    fi

    # This marker is deliberately after the dry-run short-circuit and before
    # token acquisition/curl. A real fraud-routing PUT cannot start unless its
    # target IDs are already durably excluded from future approval automation.
    if ! record_fraud_uvn_attempt "$method" "$path" "$body"; then
        return 1
    fi

    local token token_rc token_json token_transport_exit token_attempts token_retry_exits
    if token=$(get_token); then
        token_rc=0
    else
        token_rc=$?
    fi
    if (( token_rc != 0 )); then
        token_json=$(printf '%s\n' "$token" | jq -Rrc 'fromjson? // empty' | tail -1)
        token_transport_exit=$(echo "$token_json" | jq -r '.transport_error.curl_exit // empty' 2>/dev/null || true)
        if [[ "$token_transport_exit" =~ ^[0-9]+$ ]]; then
            token_attempts=$(echo "$token_json" | jq -r '.transport_error.attempts // 1')
            token_retry_exits=$(echo "$token_json" | jq -c '.transport_error.retry_exits // []')
            write_credit_request_result "$method" "$path" "$body" \
                "transport_error" "" "login_curl_exit_${token_transport_exit}" \
                "$token_attempts" "$token_retry_exits"
            printf '%s\n' "$token_json"
        fi
        write_destructive_op_result "not_sent" ""
        return "$token_rc"
    fi

    local -a curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "Service: clio"
    )

    # Add Requester header if set (audit trail — tells backend which human initiated this)
    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    # core-backend binds the credit-trust-decide grant to this header on the
    # decider's own account, agent-credit-decider@muso.ai (T12, core #10595;
    # identity credit-decider, never agent-hydra-main@). Only the decider's
    # own calls ever carry it.
    if [[ "${CREDIT_TRUST_DECIDE:-0}" == "1" && "$REQUESTER_EMAIL" == "credit-trust-decide@hydra-ops" ]]; then
        curl_args+=(-H "X-Credit-Automation-Id: credit-trust-decide")
    fi
    # The L12 executor: its own automation id on the decider account (closes only; see is_fable_decider_close).
    if [[ "${FABLE_DECIDER:-0}" == "1" && "$REQUESTER_EMAIL" == "fable-decider@hydra-ops" ]]; then
        curl_args+=(-H "X-Credit-Automation-Id: fable-decider")
    fi
    # The DSP verifier's anchor upload (credit-anchors-push.py): its own id on the decider account; core admits
    # POST /admin/credit-anchors ONLY under this id (resolveAnchorWriter), and only on that one route.
    if [[ "${DSP_ANCHOR_WRITER:-0}" == "1" && "$REQUESTER_EMAIL" == "dsp-evidence-verifier@hydra-ops" \
          && "$path" == "/admin/credit-anchors" ]]; then
        curl_args+=(-H "X-Credit-Automation-Id: dsp-evidence-verifier")
    fi
    # Same contract for score-approve: its own id on the same decider account.
    if [[ "${CREDIT_TRUST_SCORE_APPROVE:-0}" == "1" && "$REQUESTER_EMAIL" == "credit-trust-score-approve@hydra-ops" ]]; then
        curl_args+=(-H "X-Credit-Automation-Id: credit-trust-score-approve")
    fi
    # The verification drain's approve: its own id, and ONLY on its own account (identity scale-drain =
    # agent-scale-drain@muso.ai) and on the one approve route. core judges the precedent itself
    # (agentApprovalGuard precedent scope); this header is the claim, never the proof. Sent under any other
    # login it would name an account core does not bind, so it is not sent at all.
    if [[ "${SCALE_DRAIN:-0}" == "1" && "$REQUESTER_EMAIL" == "scale-drain@hydra-ops" \
          && "${MUSO_ADMIN_IDENTITY:-}" == "scale-drain" \
          && "$method" == "PUT" && "$path" == "/admin/credit-requests" ]]; then
        curl_args+=(-H "X-Credit-Automation-Id: verification-scale-drain")
    fi

    # Actor headers (audit trail — approver + Slack ts of the in-thread approval);
    # blank or whitespace-only counts as absent, never as a valid approver
    if [[ "$CONFIRMED_BY" =~ [^[:space:]] ]]; then
        curl_args+=(-H "Approved-By: $CONFIRMED_BY")
    fi
    if [[ "$APPROVAL_MSG_ID" =~ [^[:space:]] ]]; then
        curl_args+=(-H "Request-Ref: $APPROVAL_MSG_ID")
    fi

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    # Retries are opt-in because this wrapper serves non-idempotent endpoints
    # too. Only curl failures that prove no connection was established are
    # repeated. Timeouts and resets remain delivery-ambiguous and are surfaced
    # without retry.
    local response="" curl_rc=0 transport_attempts=0 transport_retry_exits='[]'
    if run_curl_with_preconnect_retry curl "${curl_args[@]}"; then
        response="$CURL_RETRY_RESPONSE"
    else
        curl_rc="$CURL_RETRY_RC"
        transport_attempts="$CURL_RETRY_ATTEMPTS"
        transport_retry_exits="$CURL_RETRY_EXITS"

        # Invalid retry configuration failed before curl ran; surface the
        # configuration error without misclassifying it as transport.
        if (( transport_attempts == 0 )); then
            write_destructive_op_result "not_sent" ""
            return "$curl_rc"
        fi

        write_credit_request_result "$method" "$path" "$body" \
            "transport_error" "" "curl_exit_${curl_rc}" \
            "$transport_attempts" "$transport_retry_exits"
        write_destructive_op_result "transport_error" ""
        jq -nc \
            --argjson rc "$curl_rc" \
            --argjson attempts "$transport_attempts" \
            --argjson retry_exits "$transport_retry_exits" \
            '{http_status:null, body:null,
              transport_error:{curl_exit:$rc, attempts:$attempts, retry_exits:$retry_exits}}'
        return "$curl_rc"
    fi
    transport_attempts="$CURL_RETRY_ATTEMPTS"
    transport_retry_exits="$CURL_RETRY_EXITS"

    # Extract HTTP status code (last line) and body (everything else)
    local http_code
    http_code=$(echo "$response" | tail -1)
    local response_body
    response_body=$(echo "$response" | sed '$d')

    # Truth floor. A bulk credit-request PUT carries a per-row report, so it is
    # attributed row by row (see write_credit_request_result_per_row); every
    # other call classifies 2xx as `ok`, non-2xx as `http_error`. The helpers
    # self-scope to credit-request writes, so non-credit-request paths are
    # a no-op. HTTP body is included in the error field for post-mortem.
    if ! write_credit_request_result_per_row "$method" "$path" "$body" "$http_code" "$response_body" \
            "$transport_attempts" "$transport_retry_exits"; then
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            write_credit_request_result "$method" "$path" "$body" "ok" "$http_code" "" \
                "$transport_attempts" "$transport_retry_exits"
        else
            write_credit_request_result "$method" "$path" "$body" "http_error" "$http_code" "$response_body" \
                "$transport_attempts" "$transport_retry_exits"
        fi
    fi

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        write_destructive_op_result "ok" "$http_code"
    else
        write_destructive_op_result "http_error" "$http_code"
    fi

    # Record successful merges for the reverse-direction guard.
    record_merge_call "$method" "$path" "$body" "$http_code"

    # Output a parseable envelope even when the response body is empty or is
    # not JSON. transport_* fields let the caller distinguish a clean first
    # attempt from a recovered pre-connect failure. Stream the body over stdin:
    # putting a large API response in --arg/--argjson crosses Linux's per-arg
    # limit before jq can start.
    if [[ -n "$response_body" ]] && printf '%s' "$response_body" | jq -es \
            'length == 1 and .[0] != null and .[0] != false' >/dev/null 2>&1; then
        printf '%s' "$response_body" | jq -cs \
            --arg http "$http_code" \
            --argjson attempts "$transport_attempts" \
            --argjson retry_exits "$transport_retry_exits" \
            '{http_status:($http | tonumber? // $http), body:.[0],
              transport_attempts:$attempts, transport_retry_exits:$retry_exits}'
    else
        printf '%s' "$response_body" | jq -Rsc \
            --arg http "$http_code" \
            --argjson attempts "$transport_attempts" \
            --argjson retry_exits "$transport_retry_exits" \
            '{http_status:($http | tonumber? // $http), raw:.,
              transport_attempts:$attempts, transport_retry_exits:$retry_exits}'
    fi
}

cmd_upload() {
    check_env
    local method="POST"
    case "${1:-}" in
        POST|PUT) method="$1"; shift ;;
        /*) ;;
        *) die "Unsupported upload method: ${1:-<empty>} (expected POST or PUT)" ;;
    esac

    local path="${1:?Usage: upload [POST|PUT] <path> <file> [field=value...]}"
    local file="${2:?Usage: upload [POST|PUT] <path> <file> [field=value...]}"
    shift 2

    [[ -f "$file" ]] || die "File not found: $file"

    # Codex model-health gate — uploads are always writes. Refuse while the
    # fleet is degraded; self-skips in dry-run.
    if ! enforce_codex_health_gate "$method"; then
        return 1
    fi

    # cmd_upload reaches curl on its own path, so a gate wired only into cmd_call
    # does not cover it. Wire the enrich-link gate in here too, or `upload` is a
    # standing hole in the very promise this gate makes. (The OTHER gates --
    # tier-2, merge-reverse, bulk-destructive -- are still absent from this
    # function; that is pre-existing and flagged separately, not fixed here.)
    if ! enforce_profile_enrich_link_gate "$method" "$path" ""; then
        return 1
    fi

    # Uploads are always writes — short-circuit unconditionally in dry-run.
    if is_dry_run_mode; then
        DRY_RUN_AUDIT_FAILED=0
        write_dry_run_audit "$method" "$path" "$file" "upload"
        emit_dry_run_response
        return 0
    fi

    local token token_rc
    if token=$(get_token); then
        token_rc=0
    else
        token_rc=$?
    fi
    if (( token_rc != 0 )); then
        [[ -n "$token" ]] && printf '%s\n' "$token"
        return "$token_rc"
    fi

    local -a curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Service: clio"
    )

    # Add Requester header if set
    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    # Actor headers (audit trail — approver + Slack ts of the in-thread approval);
    # blank or whitespace-only counts as absent, never as a valid approver
    if [[ "$CONFIRMED_BY" =~ [^[:space:]] ]]; then
        curl_args+=(-H "Approved-By: $CONFIRMED_BY")
    fi
    if [[ "$APPROVAL_MSG_ID" =~ [^[:space:]] ]]; then
        curl_args+=(-H "Request-Ref: $APPROVAL_MSG_ID")
    fi

    curl_args+=(-F "file=@$file")

    for field in "$@"; do
        curl_args+=(-F "$field")
    done

    local response
    response=$(curl "${curl_args[@]}")

    local http_code
    http_code=$(echo "$response" | tail -1)
    local response_body
    response_body=$(echo "$response" | sed '$d')

    echo "{\"http_status\": $http_code, \"body\": $response_body}" 2>/dev/null \
        || echo "{\"http_status\": $http_code, \"raw\": $(echo "$response_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
}

# --- Batched calls (the scale drain's hoist) --------------------------------
#
# The measured ceiling this removes: three round trips per user (token resolve, account
# resolve, route) at 1.4 minutes per user end to end, which caps even perfect batching
# near 1,000/day. `call-batch` is ONE process, ONE token resolve, N requests, and the
# SAME gate chain every single `call` already runs - a batch client that spoke HTTP
# directly would be faster and would also bypass the credit-approve, reject, removal,
# tier-2, pace, merge-reverse, enrich-link and bulk-destructive gates.
#
# Reads run in a bounded pool (the decision pass is read-only and safe to run wide).
# WRITES are strictly serial: the destructive-op counters and the pace gate are shared
# state, and a concurrent write batch would race them. That is the plan's "parallelise
# the read, keep the write ordered" enforced here rather than trusted to callers.
#
# Input:  one JSON object per line on stdin:
#           {"id": <opaque>, "method": "GET", "path": "/admin/...", "body": <optional>}
# Output: one JSON object per line on stdout, in input order:
#           {"id": <opaque>, "http_status": <int|null>, "body": <parsed|null>,
#            "rc": <int>, "error": <string|null>}
# A per-item failure is reported on that item's line; it never aborts the batch, because
# one bad row must not cost the other 92,860.
cmd_call_batch() {
    check_env
    local pool=8
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pool) pool="${2:?--pool needs a number}"; shift 2 ;;
            *) die "call-batch: unknown argument: $1" ;;
        esac
    done
    [[ "$pool" =~ ^[0-9]+$ ]] && (( pool >= 1 )) || die "call-batch: --pool must be a positive integer"

    local workdir
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/admin-call-batch.XXXXXX") || die "call-batch: cannot create a work dir"

    # ONE token resolve for the whole batch. get_token memoises TOKEN_MEMO, so every
    # cmd_call below reuses this value instead of re-reading the cache or logging in.
    TOKEN_MEMO=$(get_token) || { rm -rf "$workdir"; die "call-batch: token resolve failed"; }
    export TOKEN_MEMO

    # Split the input into one file per item and classify read vs write. python3 is
    # already a hard dependency of this script (the login response is parsed with it).
    # The batch is spooled to a file FIRST: a `python3 - <<'PY'` heredoc consumes stdin
    # for the script itself, so it cannot also read the batch from stdin.
    cat > "$workdir/input.jsonl"
    local plan
    plan=$(python3 - "$workdir" <<'PY'
import json, os, sys
workdir = sys.argv[1]
n = 0
for line in open(os.path.join(workdir, "input.jsonl"), encoding="utf-8"):
    if not line.strip():
        continue
    n += 1
    try:
        item = json.loads(line)
    except ValueError as exc:
        print(f"call-batch: bad JSON on line {n}: {exc}", file=sys.stderr)
        sys.exit(2)
    idx = f"{n:06d}"
    with open(os.path.join(workdir, idx + ".json"), "w", encoding="utf-8") as fh:
        json.dump(item, fh)
    method = str(item.get("method") or "GET").upper()
    kind = "read" if method in ("GET", "HEAD") else "write"
    print(f"{idx}\t{kind}\t{method}\t{item.get('path') or ''}")
PY
    ) || { rm -rf "$workdir"; die "call-batch: could not parse the batch input"; }

    local -a read_idx=() write_idx=()
    local idx kind method path
    while IFS=$'\t' read -r idx kind method path; do
        [[ -z "$idx" ]] && continue
        if [[ "$kind" == "read" ]]; then read_idx+=("$idx"); else write_idx+=("$idx"); fi
    done <<< "$plan"

    _call_batch_one() {   # $1 = index
        local i="$1" m p b rc=0 out
        m=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("method") or "GET")' "$workdir/$i.json")
        p=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("path") or "")' "$workdir/$i.json")
        b=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); b=d.get("body"); print(b if isinstance(b,str) else (json.dumps(b) if b is not None else ""))' "$workdir/$i.json")
        out=$(cmd_call "$m" "$p" "$b" 2>"$workdir/$i.err") || rc=$?
        printf '%s' "$out" > "$workdir/$i.out"
        printf '%s' "$rc" > "$workdir/$i.rc"
    }

    local running=0
    if (( ${#read_idx[@]} )); then
        for idx in "${read_idx[@]}"; do
            _call_batch_one "$idx" &
            running=$((running + 1))
            if (( running >= pool )); then
                wait -n 2>/dev/null || true
                running=$((running - 1))
            fi
        done
        wait 2>/dev/null || true
    fi
    if (( ${#write_idx[@]} )); then
        for idx in "${write_idx[@]}"; do
            _call_batch_one "$idx"
        done
    fi

    python3 - "$workdir" <<'PY'
import json, os, sys
workdir = sys.argv[1]
for name in sorted(os.listdir(workdir)):
    if not name.endswith(".out"):
        continue
    idx = name[:-4]
    raw = open(os.path.join(workdir, name), encoding="utf-8").read().strip()
    rc_path = os.path.join(workdir, idx + ".rc")
    rc = int(open(rc_path, encoding="utf-8").read().strip() or 0) if os.path.exists(rc_path) else 0
    item = json.load(open(os.path.join(workdir, idx + ".json"), encoding="utf-8"))
    status, body = None, None
    if raw:
        try:
            env = json.loads(raw.splitlines()[-1])
            status = env.get("http_status")
            body = env.get("body")
        except (ValueError, IndexError):
            body = raw[:2000]
    err = ""
    err_path = os.path.join(workdir, idx + ".err")
    if os.path.exists(err_path):
        err = open(err_path, encoding="utf-8").read().strip()[:500]
    print(json.dumps({"id": item.get("id"), "http_status": status, "body": body,
                      "rc": rc, "error": err or None}, sort_keys=True))
PY
    local rc=$?
    rm -rf "$workdir"
    return "$rc"
}

# --- Main ---

# Source-safe guard: if this file is `source`d (e.g. by bats tests), skip the
# CLI dispatcher and only expose the function definitions. Executed directly,
# the dispatcher runs normally.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0 2>/dev/null || true
fi

# Parse global options before command.
# Both --requester and --evidence-excerpt can appear in any order before the command.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --requester)
            # Defense in depth: if resolve_slack_to_email returns 1 (unknown
            # input), fall back to using the raw value. Without the `||`
            # fallback, `set -e` aborts the script silently here on any
            # unrecognized identity. The downstream gate handles arbitrary
            # string values fine (only jan@/aaron@ bypass).
            REQUESTER_EMAIL=$(resolve_slack_to_email "$2") || REQUESTER_EMAIL="$2"
            shift 2
            ;;
        --evidence-excerpt)
            EVIDENCE_EXCERPT="$2"
            export EVIDENCE_EXCERPT  # enforce_credit_approve_gate reads it from env
            shift 2
            ;;
        --profile-audit-id)
            PROFILE_AUDIT_ID="$2"
            export PROFILE_AUDIT_ID  # enforce_credit_approve_gate reads it from env
            shift 2
            ;;
        --confirmed-by)
            CONFIRMED_BY="$2"
            shift 2
            ;;
        --approval-msg-id)
            APPROVAL_MSG_ID="$2"
            shift 2
            ;;
        --approval-author-id)
            APPROVAL_AUTHOR_ID="$2"
            shift 2
            ;;
        --approval-channel)
            APPROVAL_CHANNEL="$2"
            shift 2
            ;;
        *) break ;;
    esac
done

command="${1:-help}"
shift || true

case "$command" in
    login|call|upload) load_admin_identity ;;
esac

case "$command" in
    login)          cmd_login "$@" ;;
    call)           cmd_call "$@" ;;
    call-batch)     cmd_call_batch "$@" ;;
    upload)         cmd_upload "$@" ;;
    resolve-email)  resolve_slack_to_email "${1:?Usage: resolve-email <slack_id>}" ;;
    help)           head -14 "$0" | tail -13 | sed 's/^# //' | sed 's/^#//' ;;
    *)              die "Unknown command: $command" ;;
esac

#!/usr/bin/env bash
# muso-admin-api.sh — Core admin API wrapper for all Muso ops skills
# Usage: bash muso-admin-api.sh [--requester email] <command> [options]
#
# Commands:
#   login                              Get/refresh admin JWT token (cached 23h)
#   call <METHOD> <path> [json-body]   Make an authenticated admin API call
#   upload <path> <file> [fields...]   Multipart upload with auth
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
#
# Failure mode: if we can't write the line, emit a LOUD stderr warning but
# never break the main call. Same philosophy as write_dry_run_audit.
#
# CV_RESULTS_PATH overrides the default path (useful for tests).
write_credit_request_result() {
    local method="$1" path="$2" body="${3:-}"
    local outcome="$4" http_status="${5:-}" error="${6:-}"

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
    if ! line=$(jq -n -c \
        --arg ts "$ts" \
        --arg run_id "$run_id" \
        --arg method "$method_uc" \
        --arg path "$path" \
        --argjson request_ids "$request_ids" \
        --arg intended_status "$intended_status" \
        --arg outcome "$outcome" \
        --arg http_status "$http_status" \
        --arg error "$error" \
        --arg requester "${REQUESTER_EMAIL:-}" \
        --arg flag_reason "${OPS_FLAG_REASON:-}" \
        --arg credited_name "${OPS_CREDITED_NAME:-}" \
        --arg track_title "${OPS_TRACK_TITLE:-}" \
        --arg role "${OPS_ROLE:-}" \
        '{
            ts:$ts,
            run_id:    (if $run_id    == "" then null else $run_id    end),
            method:$method,
            path:$path,
            request_ids:$request_ids,
            intended_status: (if $intended_status == "" then null else $intended_status end),
            outcome:$outcome,
            http_status: (if $http_status == "" then null else ($http_status | tonumber? // $http_status) end),
            error:     (if $error     == "" then null else $error     end),
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
            "unattributable_response" "$http_status" "$response_body"
        return 0
    fi

    local landed refused
    # Intersection in $attempted order; `-` is safe here because ids are unique.
    landed=$(jq -nc --argjson a "$attempted" --argjson u "$updated" '$a - ($a - $u)')
    refused=$(jq -nc --argjson a "$attempted" --argjson u "$updated" '$a - $u')

    if [[ "$(printf '%s' "$landed" | jq 'length')" -gt 0 ]]; then
        write_credit_request_result "$method" "$path" \
            "$(jq -nc --argjson ids "$landed" --arg st "$intended_status" '{requestIds:$ids, status:$st}')" \
            "ok" "$http_status" ""
    fi
    if [[ "$(printf '%s' "$refused" | jq 'length')" -gt 0 ]]; then
        write_credit_request_result "$method" "$path" \
            "$(jq -nc --argjson ids "$refused" --arg st "$intended_status" '{requestIds:$ids, status:$st}')" \
            "http_error" "$http_status" "$response_body"
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
        U03TYGJF1N3) echo "serhii@muso.ai" ;;  # Serhii Ostapchuk (CTO)
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

check_env() {
    [[ -n "${MUSO_API_URL:-}" ]] || die "MUSO_API_URL not set"
    [[ -n "${MUSO_ADMIN_EMAIL:-}" ]] || die "MUSO_ADMIN_EMAIL not set"
    [[ -n "${MUSO_ADMIN_PASSWORD:-}" ]] || die "MUSO_ADMIN_PASSWORD not set"
}

get_token() {
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
    local resp
    resp=$(curl -sf -X POST "${MUSO_API_URL}/admin/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${MUSO_ADMIN_EMAIL}\",\"password\":\"${MUSO_ADMIN_PASSWORD}\"}" 2>&1) \
        || die "Login failed: $resp"

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
    local token
    token=$(get_token)
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

    # Allow opt-out for explicitly non-CV admin scripts that need to approve credits
    # (currently none — placeholder for future).
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
    local method_uc; method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    local restore_extglob=0
    shopt -q extglob || { shopt -s extglob; restore_extglob=1; }
    local rc=1 entry em ep
    for entry in "DELETE /admin/user/+([!/])" "DELETE /admin/track/+([!/])" "POST /admin/subscription"; do
        em="${entry%% *}"; ep="${entry#* }"
        # shellcheck disable=SC2053  # RHS unquoted so the extglob pattern is active.
        if [[ "$method_uc" == "$em" && "$path" == $ep ]]; then
            rc=0; break
        fi
    done
    (( restore_extglob )) && shopt -u extglob
    return "$rc"
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

# enforce_bulk_destructive_gate METHOD PATH -> 0 allow / 1 block.
# Runs in cmd_call after the merge guard, before the dry-run short-circuit.
enforce_bulk_destructive_gate() {
    local method="$1" path="$2"
    is_bulk_destructive_op "$method" "$path" || return 0
    is_dry_run_mode && return 0

    local count
    count="$(count_recent_destructive_ops)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( count >= BULK_DESTRUCTIVE_THRESHOLD )); then
        # Threshold reached. Require an EXPLICIT second approval REGARDLESS of
        # requester — god-mode intentionally does NOT bypass this gate (do not
        # call is_tier2_godmode_requester here; that omission is the point).
        if [[ -z "$CONFIRMED_BY" ]]; then
            cat >&2 <<EOF
MUSO_BULK_DESTRUCTIVE_APPROVAL_REQUIRED: ${count} destructive DELETE(s) in the last ${BULK_DESTRUCTIVE_WINDOW_SECS}s have reached the bulk threshold (${BULK_DESTRUCTIVE_THRESHOLD}).
This is the 2026-05-26 incident class (285 analytics-source DELETEs off one vague request). STOP autonomous deletion now.

To proceed you must have an EXPLICIT in-thread human decision to delete this many records, then pass BOTH:
    --confirmed-by <handle>   (one of: $(cat "$TIER2_APPROVERS_PATH" 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' | tr '\n' ' '))
    --approval-msg-id <slack_ts>

God-mode (--requester on the allowlist) does NOT bypass this gate. What satisfies it is an explicit human decision that NAMES the rows being deleted.

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

        # Audit the approved bulk-destructive write BEFORE executing. Fail-closed
        # if the audit can't be written — "deleted en masse, no record of who
        # approved it" is the worse failure mode.
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
            --arg confirmed_by "$CONFIRMED_BY" \
            --arg approval_msg_id "$APPROVAL_MSG_ID" \
            --argjson count_at_trip "$count" \
            --argjson threshold "$BULK_DESTRUCTIVE_THRESHOLD" \
            --argjson window_secs "$BULK_DESTRUCTIVE_WINDOW_SECS" \
            --arg approval_author_id "$APPROVAL_AUTHOR_ID" \
            --arg approval_channel "$APPROVAL_CHANNEL" \
            '{ts:$ts, method:$method, path:$path, requester:$requester, confirmed_by:$confirmed_by, approval_msg_id:$approval_msg_id, count_at_trip:$count_at_trip, threshold:$threshold, window_secs:$window_secs, approval_author_id:$approval_author_id, approval_channel:$approval_channel}' \
            >> "$BULK_DESTRUCTIVE_AUDIT_PATH" || audit_rc=$?
        if (( audit_rc != 0 )); then
            echo "MUSO_BULK_DESTRUCTIVE_AUDIT_UNWRITABLE: append to $BULK_DESTRUCTIVE_AUDIT_PATH failed (rc=$audit_rc) — refusing bulk-destructive write to preserve audit trail." >&2
            return 1
        fi
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

    # Tier-2 approval gate (incident 2026-04-29). Skipped in dry-run mode.
    if ! enforce_tier2_approval_gate "$method" "$path"; then
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
    # radius of mass DELETEs; god-mode does NOT bypass it. Self-skips in dry-run.
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

    local token
    token=$(get_token)

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

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    local response
    response=$(curl "${curl_args[@]}")

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
    if ! write_credit_request_result_per_row "$method" "$path" "$body" "$http_code" "$response_body"; then
        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            write_credit_request_result "$method" "$path" "$body" "ok" "$http_code" ""
        else
            write_credit_request_result "$method" "$path" "$body" "http_error" "$http_code" "$response_body"
        fi
    fi

    # Record successful merges for the reverse-direction guard.
    record_merge_call "$method" "$path" "$body" "$http_code"

    # Output JSON with status
    echo "{\"http_status\": $http_code, \"body\": $response_body}" 2>/dev/null \
        || echo "{\"http_status\": $http_code, \"raw\": $(echo "$response_body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
}

cmd_upload() {
    check_env
    local path="${1:?Usage: upload <path> <file> [field=value...]}"
    local file="${2:?Usage: upload <path> <file> [field=value...]}"
    shift 2

    [[ -f "$file" ]] || die "File not found: $file"

    # Codex model-health gate — uploads are always writes (POST). Refuse while the
    # fleet is degraded; self-skips in dry-run.
    if ! enforce_codex_health_gate "POST"; then
        return 1
    fi

    # cmd_upload reaches curl on its own path, so a gate wired only into cmd_call
    # does not cover it. Wire the enrich-link gate in here too, or `upload` is a
    # standing hole in the very promise this gate makes. (The OTHER gates --
    # tier-2, merge-reverse, bulk-destructive -- are still absent from this
    # function; that is pre-existing and flagged separately, not fixed here.)
    if ! enforce_profile_enrich_link_gate "POST" "$path" ""; then
        return 1
    fi

    # Uploads are always writes — short-circuit unconditionally in dry-run.
    if is_dry_run_mode; then
        DRY_RUN_AUDIT_FAILED=0
        write_dry_run_audit "POST" "$path" "$file" "upload"
        emit_dry_run_response
        return 0
    fi

    local token
    token=$(get_token)

    local -a curl_args=(
        -s -w "\n%{http_code}"
        -X POST
        "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Service: clio"
    )

    # Add Requester header if set
    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
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
    login)          cmd_login "$@" ;;
    call)           cmd_call "$@" ;;
    upload)         cmd_upload "$@" ;;
    resolve-email)  resolve_slack_to_email "${1:?Usage: resolve-email <slack_id>}" ;;
    help)           head -14 "$0" | tail -13 | sed 's/^# //' | sed 's/^#//' ;;
    *)              die "Unknown command: $command" ;;
esac

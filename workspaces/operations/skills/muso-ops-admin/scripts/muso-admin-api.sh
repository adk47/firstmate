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
CONFIRMED_BY=""      # Set via --confirmed-by flag (required for tier-2 writes — see enforce_tier2_approval_gate)
APPROVAL_MSG_ID=""   # Set via --approval-msg-id flag (Slack message ID/ts of the in-thread approval — for audit)

# Tier-2 enforcement state. Persisted to disk so the reverse-direction guard
# fires across separate shell invocations (each agent exec is a new shell).
# /var/log/muso-ops is hydra's canonical location; tests can override with
# MUSO_OPS_STATE_DIR. Created lazily on first write.
MUSO_OPS_STATE_DIR="${MUSO_OPS_STATE_DIR:-/var/log/muso-ops}"
RECENT_MERGES_PATH="${RECENT_MERGES_PATH:-${MUSO_OPS_STATE_DIR}/recent-merges.jsonl}"
TIER2_AUDIT_PATH="${TIER2_AUDIT_PATH:-${MUSO_OPS_STATE_DIR}/tier2-audit.jsonl}"
TIER2_APPROVERS_PATH="${TIER2_APPROVERS_PATH:-${SCRIPT_DIR}/../config/tier2-approvers.txt}"
TIER2_ENDPOINTS_PATH="${TIER2_ENDPOINTS_PATH:-${SCRIPT_DIR}/../config/tier2-endpoints.txt}"
# Reverse-direction guard window. A second merge that points the OTHER way
# within this many seconds is the 2026-04-29 incident pattern; refuse it.
TIER2_REVERSE_WINDOW_SECS="${TIER2_REVERSE_WINDOW_SECS:-300}"

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
    # Resolve Slack ID to email
    case "$input" in
        U7RP6HKUZ)  echo "aaron@muso.ai" ;;
        U07NF5A77E2) echo "fede@muso.ai" ;;
        U03TYGJF1N3) echo "serhii@muso.ai" ;;
        U038BM16T7W) echo "jan@muso.ai" ;;
        U0302FZQGCB) echo "andrey@muso.ai" ;;
        U02S7TJ7QHY) echo "oleg@muso.ai" ;;
        U0AL36NADEY) echo "nick@muso.ai" ;;
        U0A8CCTTAAG) echo "liza@muso.ai" ;;
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
    echo "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"approved"' || return 0

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
    # web_fetch substituting for browser on these hosts. Primary defense is
    # the `muso-credit-verification-enforcer` plugin's block-web-fetch-tier1
    # hook, which returns an error-shaped toolResult for any such call. This
    # bash-layer check is the backstop — if the plugin hook misses a call,
    # the approve still refuses.
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

# --- Tier-2 approval gate (incident 2026-04-29) ---
# See skills-all/muso-ops-admin/scripts/muso-admin-api.sh for the canonical
# version + design notes. This block is mirrored here because workspaces/operations
# ships its own wrapper copy (drift to be cleaned up separately).

is_tier2_endpoint() {
    local method="$1" path="$2"
    local method_uc
    method_uc="$(printf %s "$method" | tr '[:lower:]' '[:upper:]')"
    [[ -f "$TIER2_ENDPOINTS_PATH" ]] || return 1
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line## }"
        line="${line%% }"
        [[ -z "$line" ]] && continue
        local m p
        m="$(printf %s "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')"
        p="$(printf %s "$line" | awk '{print $2}')"
        if [[ "$m" == "$method_uc" && "$path" == "$p" ]]; then
            return 0
        fi
    done < "$TIER2_ENDPOINTS_PATH"
    return 1
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

cmd_call() {
    check_env
    local method="${1:?Usage: call <METHOD> <path> [json-body]}"
    local path="${2:?Usage: call <METHOD> <path> [json-body]}"
    local body="${3:-}"

    # Credit approve gate — deterministic, runs in bash below openclaw's hook layer.
    if ! enforce_credit_approve_gate "$method" "$path" "$body"; then
        # Truth floor (PR 1): log the gate rejection to the credit-request
        # results.jsonl so compute-run-summary.sh sees it in dry-run and prod.
        # Scoped inside the helper to credit-request writes only, so this is
        # a no-op for any other path.
        write_credit_request_result "$method" "$path" "$body" "rejected_by_gate" "" "evidence-excerpt missing, too short/long, no fresh session log, Tier 1 web_fetch substitution, or insufficient grounded evidence — see stderr above"
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

    # Truth floor: classify 2xx as `ok`, non-2xx as `http_error`. The helper
    # self-scopes to credit-request writes, so non-credit-request paths are
    # a no-op. HTTP body is included in the error field for post-mortem.
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        write_credit_request_result "$method" "$path" "$body" "ok" "$http_code" ""
    else
        write_credit_request_result "$method" "$path" "$body" "http_error" "$http_code" "$response_body"
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
            REQUESTER_EMAIL=$(resolve_slack_to_email "$2")
            shift 2
            ;;
        --evidence-excerpt)
            EVIDENCE_EXCERPT="$2"
            export EVIDENCE_EXCERPT  # enforce_credit_approve_gate reads it from env
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

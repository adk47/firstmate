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
TOKEN_CACHE="$SCRIPT_DIR/.admin-token-cache"
TOKEN_MAX_AGE=82800  # 23 hours in seconds
REQUESTER_EMAIL=""   # Set via --requester flag
EVIDENCE_EXCERPT=""  # Set via --evidence-excerpt flag (required for autonomous credit approves)

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

CV_TIER1_HOSTS='open\.spotify\.com|music\.apple\.com|musicbrainz\.org|discogs\.com|allmusic\.com|tidal\.com'
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

    [[ "$method" == "PUT" ]] || return 0
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
Invoke like:
    muso-admin-api.sh call PUT "/admin/credit-requests" \\
        --evidence-excerpt "<literal string you saw on a Tier 1 page>" \\
        '{"requestIds":["<cr_id>"],"status":"approved"}'
The excerpt must be a short substring (>=${CV_EVIDENCE_EXCERPT_MIN} chars) that literally appears on >=${CV_REQUIRED_LOADS} distinct Tier 1 pages you loaded via the \`browser\` tool in this session. Good examples: the artist's name as rendered on MusicBrainz, the role string as it appears on AllMusic credits, a track title from Spotify.
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

    # Locate the most-recently modified openclaw session log (any profile).
    # Portable across GNU/BSD: find filters by age; stat resolves mtime for sort.
    local session_log
    session_log=$(
        find /root/.openclaw-main/agents /root/.openclaw-dev/agents \
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
        '
        # Build tier-1 host lookup: unescape "\." -> ".", index as object keys
        ($hosts | split("|") | map(gsub("\\\\."; ".")) | map({(.): true}) | add) as $t1
        |
        # Slurp all JSONL lines as raw text (-R), parse each, skip malformed
        [inputs | fromjson? // empty | select(type == "object")] as $lines
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
    (open.spotify.com, music.apple.com, musicbrainz.org, discogs.com, allmusic.com, tidal.com).
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

cmd_call() {
    check_env
    local method="${1:?Usage: call <METHOD> <path> [json-body]}"
    local path="${2:?Usage: call <METHOD> <path> [json-body]}"
    local body="${3:-}"

    # Credit approve gate — deterministic, runs in bash below openclaw's hook layer.
    if ! enforce_credit_approve_gate "$method" "$path" "$body"; then
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

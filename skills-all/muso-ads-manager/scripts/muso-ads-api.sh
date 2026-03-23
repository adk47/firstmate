#!/usr/bin/env bash
# muso-ads-api.sh — Wrapper for Muso Ads admin API operations
# Usage: bash muso-ads-api.sh [--requester email] <command> [options]
#
# Commands:
#   login                         Get admin JWT token (cached 23h)
#   create                        Create a new ad (interactive, reads JSON from stdin)
#   list [--all]                  List active ads (--all includes inactive)
#   get <slug-or-id>              Get ad details by slug or DB id
#   update <id> <json-body>       Update ad fields (direct DB via API if available)
#   toggle <id> <true|false>      Toggle isActive flag
#   events <slug> [--days N]      Get event stats for an ad
#   upload-image <file-path>      Upload image to S3, returns URL
#
# Global Options:
#   --requester <email>   Email of the human who initiated this action (audit trail)
#
# Requires: MUSO_API_URL, MUSO_ADMIN_EMAIL, MUSO_ADMIN_PASSWORD in env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_CACHE="$SCRIPT_DIR/.ads-token-cache"
TOKEN_MAX_AGE=82800  # 23 hours in seconds
REQUESTER_EMAIL=""   # Set via --requester flag

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
    resp=$(curl -sf -X POST "${MUSO_API_URL}/w/admin/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"${MUSO_ADMIN_EMAIL}\",\"password\":\"${MUSO_ADMIN_PASSWORD}\"}" 2>&1) \
        || die "Login failed: $resp"

    local token
    token=$(echo "$resp" | jq -r '.data.user.token // empty')
    [[ -n "$token" ]] || die "No token in login response: $resp"

    echo "$(date +%s)" > "$TOKEN_CACHE"
    echo "$token" >> "$TOKEN_CACHE"
    chmod 600 "$TOKEN_CACHE"
    echo "$token"
}

auth_header() {
    local token
    token=$(get_token)
    echo "Authorization: Bearer $token"
}

api_call() {
    local method="$1" path="$2"
    shift 2
    local token
    token=$(get_token)

    local -a curl_args=(
        -sf -X "$method" "${MUSO_API_URL}${path}"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "Service: clio"
    )

    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    curl "${curl_args[@]}" "$@"
}

# --- Commands ---

cmd_login() {
    check_env
    local token
    token=$(get_token)
    echo "Token acquired (${#token} chars). Cached at $TOKEN_CACHE"
}

cmd_create() {
    check_env
    # Expects multipart form data: logo file, media file, and JSON fields
    # Usage: bash muso-ads-api.sh create \
    #   --logo /path/to/logo.png \
    #   --media /path/to/banner.jpg \
    #   --field advertiserName="Sweetwater" \
    #   --field callToActionLabel="Shop Now" \
    #   --field adHeadline="40% off headphones" \
    #   [... more --field key=value]

    local logo="" media=""
    local -a fields=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --logo) logo="$2"; shift 2 ;;
            --media) media="$2"; shift 2 ;;
            --field) fields+=("$2"); shift 2 ;;
            *) die "Unknown create arg: $1" ;;
        esac
    done

    [[ -n "$logo" ]] || die "Missing --logo <file>"
    [[ -n "$media" ]] || die "Missing --media <file>"
    [[ -f "$logo" ]] || die "Logo file not found: $logo"
    [[ -f "$media" ]] || die "Media file not found: $media"

    local token
    token=$(get_token)

    local -a curl_args=(
        -X POST "${MUSO_API_URL}/w/admin/ads"
        -H "Authorization: Bearer $token"
        -H "Service: clio"
        -F "advertiserLogo=@$logo"
        -F "primaryMedia=@$media"
    )

    if [[ -n "$REQUESTER_EMAIL" ]]; then
        curl_args+=(-H "Requester: $REQUESTER_EMAIL")
    fi

    for f in "${fields[@]}"; do
        curl_args+=(-F "$f")
    done

    curl -sf "${curl_args[@]}"
}

cmd_list() {
    check_env
    local show_all=false
    [[ "${1:-}" == "--all" ]] && show_all=true

    # Use the user-facing list endpoint since admin has no list endpoint
    local resp
    resp=$(api_call GET "/c/v4/amp?placementType=NEWS_FEED,PERSONALIZED_FOR_YOU,MARKETPLACE_ITEM,SPONSORED_TILE,FEATURED_BOOST&limit=100")
    echo "$resp" | jq '.'
}

cmd_get() {
    check_env
    local id="${1:?Usage: get <slug-or-id>}"
    # Try the user-facing endpoint
    local resp
    resp=$(api_call GET "/c/v4/amp?limit=100")
    echo "$resp" | jq --arg id "$id" '.data.ads[]? | select(.id == $id or .slug == $id)'
}

cmd_events() {
    check_env
    local slug="${1:?Usage: events <slug> [--days N]}"
    shift
    local days=7
    [[ "${1:-}" == "--days" ]] && days="${2:-7}"
    echo "Event stats for ad '$slug' (last ${days} days):"
    echo "(Requires Athena query against ad_events table — use Athena skill for detailed analytics)"
}

cmd_help() {
    head -12 "$0" | tail -11 | sed 's/^# //' | sed 's/^#//'
}

# --- Main ---

# Parse global options before command
while [[ $# -gt 0 ]]; do
    case "$1" in
        --requester) REQUESTER_EMAIL="$2"; shift 2 ;;
        *) break ;;
    esac
done

command="${1:-help}"
shift || true

case "$command" in
    login)  cmd_login "$@" ;;
    create) cmd_create "$@" ;;
    list)   cmd_list "$@" ;;
    get)    cmd_get "$@" ;;
    events) cmd_events "$@" ;;
    help)   cmd_help ;;
    *)      die "Unknown command: $command. Run with 'help' for usage." ;;
esac
